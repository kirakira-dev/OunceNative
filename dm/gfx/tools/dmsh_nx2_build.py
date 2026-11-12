#!/usr/bin/env python3
"""Compile captured NX2 shaders and check their Metal resource bindings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
from dmsh_nx2_spirv import prepare as prepare_spirv, toolchain_provenance as bank_provenance

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / 'games'))
import game

STAGES = ['vertex', 'pixel', 'geometry', 'hull', 'domain', 'compute']
XC = ['--msl', '--msl-version', '20300', '--msl-argument-buffers',
      '--msl-texture-buffer-native', '--msl-pad-fragment-output']


def run(args):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def precise_helpers(src):
    """Inline precise arithmetic with Metal 3.2's scoped FP controls.

    SPIRV-Cross's older MSL output uses optnone to implement NoContraction.
    Keep its arithmetic (including explicit fma) intact, but allow inlining
    while forbidding reassociation and contraction inside these helpers.
    Other optnone helpers retain their original compiler workarounds.
    """
    pattern = (r'\[\[clang::optnone\]\] '
               r'([^\n]*\bspv(?:FAdd|FMul(?:VectorMatrix|MatrixVector|MatrixMatrix)?)'
               r'\([^\n]*\))\n\{')
    return re.sub(pattern, lambda m: 'static inline __attribute__((always_inline)) ' +
                  m[1] + '\n{\n#pragma metal fp math_mode(safe)\n'
                  '#pragma metal fp contract(off)', src)


def compute_layout(control):
    counts = list(control[0xb1:0xb9])
    if any(counts[i] for i in (3, 4, 6, 7)):
        raise ValueError('unmeasured compute sampler/surface table')
    u, s, t, im = counts[0], counts[1], counts[2], counts[5]
    roots = list(control[0xa9:0xb1])
    if any(words > 64 for words in roots):
        raise ValueError('compute root table exceeds 256 bytes')
    root_bytes = sum((words * 4 + 15) & ~15 for words in roots)
    size = struct.unpack_from('<H', control, 0xba)[0]
    if size != 16 + root_bytes + 16*(u+s) + 8*(t+im):
        raise ValueError('compute driver table size mismatch')
    return dict(ubos=u, ssbos=s, textures=t, images=im, size=size,
                root_words=roots, resource_base=16 + root_bytes)


def integer_vertex_inputs(src):
    """Preserve fetch bits for inputs consumed only through integer bitcasts."""
    entry = re.search(r'\b(?:vertex\s+main0_out|kernel\s+void)\s+main0\s*\(', src)
    if not entry:
        return src
    body = src[entry.start():]
    declarations = list(re.finditer(
        r'\b(float[234]?)\s+(\w+)\s+\[\[attribute\((\d+)\)\]\]', src[:entry.start()]))
    integer = []
    casts = ('as_type<int>(', 'as_type<uint>(')
    for declaration in declarations:
        ty, name, _ = declaration.groups()
        uses = list(re.finditer(r'\bin\.' + re.escape(name) + r'\b', body))
        count, valid = 0, True
        for use in uses:
            begin = body.rfind('\n', 0, use.start()) + 1
            end = body.find('\n', use.end())
            copy = re.fullmatch(r'\s*float\s+(_\w+)\s*=\s*in\.' +
                                re.escape(name) + r'\.[xyzw];', body[begin:end])
            if not copy:
                if body[:use.start()].endswith(casts):
                    count += 1
                    continue
                valid = False
                break
            variable = copy[1]
            for alias in list(re.finditer(r'\b' + re.escape(variable) + r'\b', body))[1:]:
                if body[:alias.start()].endswith(casts):
                    count += 1
                    continue
                begin = body.rfind('\n', 0, alias.start()) + 1
                end = body.find('\n', alias.end())
                if re.fullmatch(r'\s*[\w.\[\]]+\s*=\s*' + re.escape(variable) + r';', body[begin:end]):
                    continue
                valid = False
                break
            if not valid:
                break
        if valid and count:
            integer.append((ty, name))
    for ty, name in integer:
        # The entry's math still sees the original raw float bits. Metal's fetch
        # now supplies integer formats without a numeric integer-to-float cast.
        src = re.sub(r'\b' + ty + r'(\s+' + re.escape(name) + r'\s+\[\[attribute\()',
                     ty.replace('float', 'uint') + r'\1', src, count=1)
        src = re.sub(r'\bin\.' + re.escape(name) + r'\b',
                     f'as_type<{ty}>(in.{name})', src)
    return src


def cbuf_read_words(src, name, ty):
    """Prove direct uint4 reads in the first 1 KB, or leave the whole binding live."""
    block = re.fullmatch(r'constant (\w+)\*', ty)
    if not block or not re.search(r'\bstruct ' + re.escape(block[1]) +
                                 r'\s*\{\s*uint4 data\[\d+\];\s*\};', src):
        return None
    reads = list(re.finditer(r'\(\*\w+\.' + re.escape(name) +
                            r'\)\.data\[(\d+)u?\](?:\.([xyzw]{1,4})\b)?', src))
    if not reads or len(re.findall(r'\b' + re.escape(name) + r'\b', src)) != len(reads) + 1:
        return None
    words = set()
    for read in reads:
        if src[read.end():].startswith('.'):
            return None
        base = int(read[1]) * 4
        if base >= 256:
            return None
        words.update(base + 'xyzw'.index(c) for c in (read[2] or 'xyzw'))
    return sorted(words)


def describe(src, stage, meta, layout):
    bindings = []
    root = meta.get('native_root_table')
    if root and root != {'lowered_bank': 17, 'index': 0}:
        raise ValueError('unverified native root table mapping')
    external = re.findall(r'\[\[buffer\((\d+)\)\]\]', src)
    if any(int(index) != 0 for index in external):
        raise ValueError('unresolved Metal buffer outside the descriptor set')
    # SDK v327680 BindStorageBuffer (0x6016e8) selects the driver table
    # using 0xaef7d0, in 16-byte slots indexed by the NVN graphics stage.
    graphics_storage = {0: 0x110, 1: 0x510, 2: 0x410, 3: 0x210, 4: 0x310}.get(stage)
    driver_reads = {}
    # Generated declarations occupy single lines. Filtering the attributes first
    # avoids quadratic regex searches through very large arithmetic expressions.
    arguments = '\n'.join(line for line in src.splitlines() if '[[id(' in line)
    attributes = '\n'.join(line for line in src.splitlines() if '[[attribute(' in line)
    for m in re.finditer(r'^\s+(.+?)\s+(\w+)\s+\[\[id\((\d+)\)\]\];', arguments, re.M):
        ty, name, aid = m.groups()
        b = dict(msl_name=name, msl_type=ty, arg_id=int(aid))
        cb = re.fullmatch(r'c(\d+)', name)
        tex = re.fullmatch(r'(?:vs|fs|gs|tcs|tes)_tex2_([0-9a-f]+)(Smplr)?', name)
        tbuf = re.fullmatch(r'(?:vs|fs|gs|tcs|tes)_texbuf2_([0-9a-f]+)', name)
        ctex = re.fullmatch(r'cs_texbuf0_([0-9a-f]+)', name)
        cres = re.fullmatch(r'cs_(tex|img)0_([0-9a-f]+)(Smplr)?', name)
        sbuf = re.fullmatch(r'ssbo(\d+)', name)
        if cb and root and int(cb[1]) == root['lowered_bank']:
            b.update(kind='root_constants', reg=root['index'])
        elif cb and 3 <= int(cb[1]) < 19:
            b.update(kind='cbuf', reg=int(cb[1])-3)
            reads = cbuf_read_words(src, name, ty)
            if reads is not None:
                b['read_words'] = reads
        elif cb and int(cb[1]) == 1:
            b.update(kind='c1')
        elif cb and int(cb[1]) == 0 and layout:
            b.update(kind='drvcb', bank=0)
        elif cb and int(cb[1]) == 0 and graphics_storage is not None:
            reads = re.findall(r'\.c0\)\.data\[([^\]]+)\]', src)
            if len(reads) != len(re.findall(r'\.c0\b', src)):
                raise ValueError('unresolved graphics driver-buffer access')
            offsets = []
            for index in reads:
                if not re.fullmatch(r'\d+u?', index):
                    raise ValueError('indexed graphics driver-buffer read')
                offset = int(index.rstrip('u')) * 16
                if not graphics_storage <= offset < graphics_storage + 16 * 16:
                    raise ValueError(f'unmeasured graphics driver-buffer read {offset:#x}')
                offsets.append(offset)
            if not offsets:
                raise ValueError('unresolved graphics driver-buffer reads')
            driver_reads['0'] = sorted(set(offsets))
            b.update(kind='drvcb', bank=0)
        elif sbuf and layout:
            desc = meta['sbufs'][int(sbuf[1])]
            offset = desc['cb_offset']
            start = layout.get('resource_base', 16)
            base = start + 16*layout['ubos']
            if desc['cb_slot'] != 0 or desc['count'] != 1 or offset % 16:
                raise ValueError('unmeasured storage-buffer descriptor')
            if start <= offset < base:
                b.update(kind='ubo_ptr', reg=(offset-start)//16)
            elif base <= offset < base+16*layout['ssbos']:
                b.update(kind='sbuf', reg=(offset-base)//16)
            else:
                raise ValueError('storage-buffer offset outside compact tables')
            b['rw'] = desc['written']
        elif sbuf and graphics_storage is not None:
            desc = meta['sbufs'][int(sbuf[1])]
            offset = desc['cb_offset']
            if (desc['cb_slot'] != 0 or desc['count'] != 1 or offset % 16 or
                    not graphics_storage <= offset < graphics_storage + 16 * 16):
                raise ValueError('unmeasured graphics storage-buffer descriptor')
            b.update(kind='sbuf', reg=(offset-graphics_storage)//16, rw=desc['written'])
        elif ctex and layout:
            base = layout.get('resource_base', 16) + 16*(layout['ubos']+layout['ssbos'])
            offset = int(ctex[1], 16)
            if not (base <= offset < base+8*layout['textures']) or (offset-base) % 8:
                raise ValueError('compute texture offset outside compact table')
            b.update(kind='tbuf', reg=(offset-base)//8)
        elif cres and layout:
            image = cres[1] == 'img'
            base = layout.get('resource_base', 16) + 16*(layout['ubos']+layout['ssbos'])
            image_base = base + 8*layout['textures']
            offset = int(cres[2], 16)
            # TXQ queries an image through the texture path, using the same
            # image-table handle. SPIRV-Cross also declares an unused sampler.
            if not image and image_base <= offset < image_base+8*layout['images']:
                if (offset-image_base) % 8:
                    raise ValueError('unaligned compute image query')
                if cres[3]:
                    if len(re.findall(r'\b' + re.escape(name) + r'\b', src)) != 1:
                        raise ValueError('compute image query uses a sampler')
                    continue
                uses = re.findall(r'\b' + re.escape(name) + r'\.(\w+)\s*\(', src)
                if (not uses or any(use not in ('get_width', 'get_height', 'get_depth',
                                                'get_array_size', 'get_num_mip_levels',
                                                'get_num_samples') for use in uses) or
                        len(re.findall(r'\b' + re.escape(name) + r'\b', src)) != len(uses)+1):
                    raise ValueError('unsupported texture access to compute image')
                b.update(kind='img', reg=(offset-image_base)//8, rw=False)
                bindings.append(b)
                continue
            if image:
                base = image_base
            count = layout['images' if image else 'textures']
            if not (base <= offset < base+8*count) or (offset-base) % 8 or (image and cres[3]):
                raise ValueError('compute resource offset outside compact table')
            b.update(kind='img' if image else 'samp_tex' if cres[3] else 'tex', reg=(offset-base)//8)
            if image:
                b['rw'] = 'access::write' in ty or 'access::read_write' in ty
        elif tex or tbuf:
            offset = int((tex or tbuf)[1], 16)
            if offset < 0x20 or offset >= 0x120 or (offset-0x20) % 8:
                raise ValueError(f'unsupported texture table offset {offset:#x}')
            b.update(kind='tbuf' if tbuf else 'samp_tex' if tex[2] else 'tex', reg=(offset-0x20)//8)
        else:
            raise ValueError(f'unresolved Metal argument {name}: {ty}')
        bindings.append(b)
    if meta['images'] and not layout:
        raise ValueError('storage/image resource layout not measured')
    for texture in meta['textures']:
        if texture['cb_slot'] != (0 if layout else 2) or texture.get('secondary') or texture['count'] != 1:
            raise ValueError('unsupported texture descriptor layout')
    for image in meta['images']:
        if image['cb_slot'] != 0 or image['count'] != 1 or image['type'] == 7:
            raise ValueError('unsupported image descriptor layout')
    vertex = [dict(location=int(m[2]), msl_type=m[1]) for m in
              re.finditer(r'(\w+)\s+\w+\s+\[\[attribute\((\d+)\)\]\]', attributes)]
    return dict(route='B', entry='main0', bindings=bindings,
                vertex_inputs=vertex, drv_reads=driver_reads, drv_unfillable=[], c1='')


def vertex_fetch_inputs(src):
    """Select Metal's fetch type per pipeline, then retain the original 32-bit bits."""
    entry = re.search(r'\b(?:vertex\s+main0_out|kernel\s+void)\s+main0\s*\(', src)
    if not entry:
        raise ValueError('missing vertex entry for fetch specialization')
    prefix, body = src[:entry.start()], src[entry.start():]
    fields = list(re.finditer(r'\b((?:u?int)([234]?))\s+(\w+)\s+\[\[attribute\((\d+)\)\]\]', prefix))
    if not fields:
        return src, 0
    if '[[function_constant(' in src or not re.search(r'\bmain0_in\s+in\s+\[\[stage_in\]\]', body):
        raise ValueError('unrecognized vertex input specialization layout')
    constants, locals_, mask = [], [], 0
    for field in reversed(fields):
        ty, width, name, location = field.groups()
        loc = int(location)
        if not 0 <= loc < 32 or mask & (1 << loc):
            raise ValueError('invalid or duplicate vertex fetch location')
        mask |= 1 << loc
        stem = f'dm_fetch_{loc}'
        constants.extend([
            f'constant uint {stem}_type [[function_constant({64 + loc})]];',
            f'constant bool {stem}_f = {stem}_type == 1;',
            f'constant bool {stem}_i = {stem}_type == 2;',
            f'constant bool {stem}_u = {stem}_type == 0;',
        ])
        declaration = '\n    '.join(
            f'{kind}{width} {name}_{suffix} [[attribute({loc}), function_constant({stem}_{suffix})]];'
            for kind, suffix in [('float', 'f'), ('int', 'i'), ('uint', 'u')])
        # The original match leaves its semicolon outside the replacement.
        prefix = prefix[:field.start()] + declaration[:-1] + prefix[field.end():]
        body, count = re.subn(r'\bin\.' + re.escape(name) + r'\b', stem + '_bits', body)
        if not count:
            raise ValueError(f'unused integer input {name}')
        locals_.append(f'    {ty} {stem}_bits = {stem}_f ? as_type<{ty}>(in.{name}_f) : '
                       f'{stem}_i ? as_type<{ty}>(in.{name}_i) : as_type<{ty}>(in.{name}_u);')
    opening = body.find('{')
    if opening < 0:
        raise ValueError('vertex entry has no body')
    body = body[:opening+1] + '\n' + '\n'.join(locals_) + body[opening+1:]
    input_struct = prefix.find('struct main0_in')
    if input_struct < 0:
        raise ValueError('vertex input struct not found')
    prefix = prefix[:input_struct] + '\n'.join(constants) + '\n\n' + prefix[input_struct:]
    return prefix + body, mask


def depth_entries(src):
    # The compiler flag alone does not preserve position across depth and color passes.
    src = src.replace('gl_Position [[position]]', 'gl_Position [[position, invariant]]')
    start = re.search(r'(?:\[\[\s*patch\([^\n]+\)\s*\]\]\s*)?\bvertex\s+main0_out\s+main0\s*\(', src)
    if not start:
        raise ValueError('missing vertex entry')
    body = src[start.start():]
    if 'return out;' not in body:
        raise ValueError('missing vertex output return')
    gl = body.replace('return out;',
                      'out.gl_Position.z = fma(out.gl_Position.z, 0.5, out.gl_Position.w * 0.5);\n    return out;')
    return src[:start.start()] + gl + '\n' + re.sub(r'\bmain0\s*\(', 'main0_z(', body, count=1)


def fragment_output_types(src):
    """Interpret exported register bits using the color attachment's type."""
    entry = re.search(r'\bfragment\s+main0_out\s+main0\s*\(', src)
    if not entry:
        return src, 0
    prefix, body = src[:entry.start()], src[entry.start():]
    fields = list(re.finditer(r'\b(float[234]?)\s+(\w+)\s+\[\[color\((\d+)\)\]\]', prefix))
    if not fields:
        return src, 0
    constants, locals_, exports, mask = [], [], [], 0
    for field in reversed(fields):
        ty, name, location = field.groups()
        loc = int(location)
        if loc >= 8 or mask & (1 << loc):
            raise ValueError('invalid fragment output location')
        mask |= 1 << loc
        stem = f'dm_color_{loc}'
        constants.append(f'constant uint {stem}_type [[function_constant({128 + loc})]];')
        declarations = []
        for kind, suffix, value in [('float', 'f', 0), ('uint', 'u', 1), ('int', 'i', 2)]:
            constants.append(f'constant bool {stem}_{suffix} = {stem}_type == {value};')
            output_type = ty.replace('float', kind)
            declarations.append(f'{output_type} {name}_{suffix} [[color({loc}), function_constant({stem}_{suffix})]];')
            expression = stem if kind == 'float' else f'as_type<{output_type}>({stem})'
            exports.append(f'if ({stem}_{suffix}) out.{name}_{suffix} = {expression};')
        prefix = prefix[:field.start()] + '\n    '.join(declarations)[:-1] + prefix[field.end():]
        body = re.sub(r'\bout\.' + re.escape(name) + r'\b', stem, body)
        locals_.append(f'    {ty} {stem} = {{}};')
    opening = body.find('{')
    if opening < 0 or 'return out;' not in body:
        raise ValueError('unrecognized fragment output body')
    body = body[:opening+1] + '\n' + '\n'.join(locals_) + body[opening+1:]
    body = body.replace('return out;', '\n    '.join(exports) + '\n    return out;')
    index = prefix.index('struct main0_out')
    return prefix[:index] + '\n'.join(constants) + '\n\n' + prefix[index:] + body, mask


def varying_outputs(src):
    output = re.search(r'struct main0_out\s*\{(.*?)\};', src, re.S)
    return sum(1 << int(loc) for loc in re.findall(r'user\(locn(\d+)\)', output[1])) if output else 0


def fragment_alpha_test(src):
    """Apply NVN's ordered alpha comparison to color zero before exports.

    Metal has no fixed-function alpha test. As in the pinned compiler's
    AlphaTest epilogue, shaders with no color-zero export are unaffected.
    Function constants let the default ALWAYS path eliminate discard entirely.
    Run before fragment_output_types so the comparison sees the float register
    value even when the color attachment later interprets those bits as integer.
    """
    entry = re.search(r'\bfragment\s+main0_out\s+main0\s*\(', src)
    if not entry:
        return src, False
    prefix, body = src[:entry.start()], src[entry.start():]
    field = re.search(r'\bfloat4\s+(\w+)\s+\[\[color\(0\)\]\]', prefix)
    expression = f'out.{field[1]}.w' if field else None
    # Also accept a retained source already processed by fragment_output_types.
    # This permits upgrading an existing compiled package without re-extracting
    # shaders, while preserving the original register-to-attachment conversion.
    if (not expression and 'function_constant(dm_color_0_f)' in prefix and
            re.search(r'\bfloat4\s+dm_color_0\s*=', body)):
        expression = 'dm_color_0.w'
    if not expression:
        return src, False
    if 'dm_alpha_func' in src:
        raise ValueError('alpha test already generated')
    if 'return out;' not in body:
        raise ValueError('unrecognized alpha-test fragment return')
    helper = '''constant uint dm_alpha_func [[function_constant(192)]];
constant float dm_alpha_ref [[function_constant(193)]];
static inline bool dm_alpha_pass(float alpha) {
    if (dm_alpha_func == 8) return true;
    if (dm_alpha_func == 1 || isnan(alpha) || isnan(dm_alpha_ref)) return false;
    switch (dm_alpha_func) {
        case 2: return alpha < dm_alpha_ref;
        case 3: return alpha == dm_alpha_ref;
        case 4: return alpha <= dm_alpha_ref;
        case 5: return alpha > dm_alpha_ref;
        case 6: return alpha != dm_alpha_ref;
        case 7: return alpha >= dm_alpha_ref;
        default: return false;
    }
}

'''
    body = body.replace('return out;',
                        f'if (!dm_alpha_pass({expression})) discard_fragment();\n    return out;')
    return prefix + helper + body, True


def fragment_inputs(src):
    """Use the compiler's (0,0,0,1) default when the prior stage omits a varying."""
    entry = re.search(r'\bfragment\s+main0_out\s+main0\s*\(', src)
    if not entry:
        return src, 0
    prefix, body = src[:entry.start()], src[entry.start():]
    inputs = re.search(r'struct main0_in\s*\{(.*?)\};', prefix, re.S)
    if not inputs:
        return src, 0
    base = inputs.start(1)
    fields = list(re.finditer(r'\b(float4)\s+(\w+)\s+\[\[user\(locn(\d+)\)([^\]]*)\]\]', inputs[1]))
    constants, locals_, mask = [], [], 0
    for field in reversed(fields):
        ty, name, location, qualifiers = field.groups()
        loc = int(location)
        if loc >= 32 or mask & (1 << loc):
            raise ValueError('invalid fragment input location')
        mask |= 1 << loc
        stem = f'dm_varying_{loc}'
        constants.append(f'constant bool {stem}_present [[function_constant({160 + loc})]];')
        declaration = f'{ty} {name} [[user(locn{loc}){qualifiers}, function_constant({stem}_present)]]'
        prefix = prefix[:base+field.start()] + declaration + prefix[base+field.end():]
        body = re.sub(r'\bin\.' + re.escape(name) + r'\b', stem, body)
        locals_.append(f'    float4 {stem} = {stem}_present ? in.{name} : float4(0, 0, 0, 1);')
    if not mask:
        return src, 0
    opening = body.find('{')
    body = body[:opening+1] + '\n' + '\n'.join(locals_) + body[opening+1:]
    index = prefix.index('struct main0_in')
    return prefix[:index] + '\n'.join(constants) + '\n\n' + prefix[index:] + body, mask


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('jobs', type=Path)
    ap.add_argument('compiler', type=Path)
    ap.add_argument('fork', type=Path)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    profile = game.load()
    if profile.get('platform', 'nx') != 'nx2':
        raise ValueError('captured NX2 shaders require an NX2 game profile')
    jobs = json.loads(args.jobs.read_text())
    selected, rejected = [], []
    for job in jobs:
        control = Path(job['control']).read_bytes()
        code = Path(job['code']).read_bytes()
        c1_size = struct.unpack_from('<I', control, 0x3c)[0]
        c1 = Path(job['c1']).read_bytes() if c1_size else b''
        if len(c1) != c1_size:
            raise ValueError('constant segment length mismatch')
        key = hashlib.sha256(control + code + c1).hexdigest()[:16]
        if key != job['key']:
            raise ValueError(f'input key mismatch {key} != {job["key"]}')
        stage = struct.unpack_from('<H', control, 0x56)[0]
        if stage not in (0, 1, 5):
            rejected.append(dict(key=key, reason='resource layout not yet supported', stage=stage))
            continue
        selected.append((job, stage))
    scratch = args.output / 'nx2-build'
    scratch.mkdir(parents=True, exist_ok=True)
    selected_file = scratch / 'jobs.json'
    selected_file.write_text(json.dumps([j for j, s in selected], indent=2))
    run([args.compiler, selected_file, scratch])
    prepared = []
    for job, stage in selected:
        key = job['key']
        meta = json.loads((scratch / (key+'.json')).read_text())
        spirv, bank_proofs = prepare_spirv(scratch / (key+'.spv'), meta)
        src = precise_helpers(run(['spirv-cross', spirv, *XC]))
        if stage == 0:
            src = integer_vertex_inputs(src)
        layout = compute_layout(Path(job['control']).read_bytes()) if stage == 5 else None
        reflection = describe(src, stage, meta, layout)
        if bank_proofs:
            reflection['nx2_constant_bank_proofs'] = bank_proofs
        c1_size = struct.unpack_from('<I', Path(job['control']).read_bytes(), 0x3c)[0]
        if c1_size:
            reflection['c1'] = Path(job['c1']).read_bytes().hex()
        if any(b['kind'] == 'c1' for b in reflection['bindings']) and not c1_size:
            raise ValueError('shader reads an absent constant segment')
        if layout:
            reflection.update(nx2_compute=layout, threadgroup_size=job['local'])
        if stage == 0:
            reflection['varying_outputs'] = varying_outputs(src)
            src, fetch_mask = vertex_fetch_inputs(src)
            if fetch_mask:
                reflection['vertex_fetch'] = dict(version=1, constant_base=64, mask=fetch_mask)
            src = depth_entries(src)
            reflection['entry_z'] = 'main0_z'
        elif stage == 1:
            src, mask = fragment_inputs(src)
            if mask:
                reflection['fragment_inputs'] = dict(version=1, constant_base=160, mask=mask)
            src, alpha = fragment_alpha_test(src)
            if alpha:
                reflection['alpha_test'] = dict(version=1, function_constant=192, reference_constant=193)
            src, mask = fragment_output_types(src)
            if mask:
                reflection['color_output_types'] = dict(version=1, constant_base=128, mask=mask)
        prepared.append((job, stage, src, reflection))
    provenance = dict(fork_commit=run(['git', '-C', args.fork, 'rev-parse', 'HEAD']).strip(),
                      compiler_sha256=sha(args.compiler),
                      compiler_source_sha256=sha(args.fork/'src/shader_recompiler/nx2_offline.cpp'),
                      binding_sources_sha256={p: sha(HERE.parent/'nvn'/p) for p in
                          ('nvn_refl.h', 'nvn_refl.m', 'nvn_mtl.m', 'nvn_raytrace.h',
                           'nvn_raytrace.m', 'nvn_raytrace_source.m', 'nvn_raytrace_scene.inc')},
                      builder_sha256=sha(__file__), spirv_cross_sha256=sha(shutil.which('spirv-cross')),
                      metal_version=run(['xcrun', '-sdk', 'macosx', 'metal', '--version']),
                      metal_options=['-std=metal3.2', '-c', '-fpreserve-invariance', '-fno-fast-math'],
                      spirv_cross_options=XC, jobs_sha256=sha(selected_file),
                      constant_bank_toolchain=bank_provenance())
    digest = hashlib.sha256(json.dumps(provenance, sort_keys=True).encode()).hexdigest()
    config = profile.table('game.tsv')
    text = re.sub(r'^shader_nx2_chain\t.*\n', '', config.read_text(), flags=re.M)
    config.write_text(text + f'shader_nx2_chain\t{digest}\n')
    profile.table('shader_map.tsv').write_text('package\tindex\tstage\tdm_ctl_sha16\tsource\n' + ''.join(
        f'{profile.get("package")}\t{i}\t{STAGES[s]}\t{j["key"]}\tnative-capture\n' for i,(j,s,src,r) in enumerate(prepared)))
    chain = run([sys.executable, HERE/'dmsh_chain.py', '--header']).strip()
    destination = args.output / ('b-' + chain)
    destination.mkdir(parents=True, exist_ok=True)
    reusable = {}
    for manifest in args.output.glob('b-*/provenance.json'):
        previous = json.loads(manifest.read_text())
        if any(previous.get(k) != provenance[k] for k in ('metal_version', 'metal_options')):
            continue
        for source in manifest.parent.glob('*_b.metal'):
            library = source.with_suffix('.metallib')
            if library.exists():
                reusable[sha(source)] = library
    reused = 0
    for job, stage, src, reflection in prepared:
        key = job['key']
        stem = destination / (key + '_b')
        msl = stem.with_suffix('.metal')
        air = stem.with_suffix('.air')
        msl.write_text(src)
        library = stem.with_suffix('.metallib')
        cached = reusable.get(hashlib.sha256(src.encode()).hexdigest())
        if cached:
            if cached != library:
                shutil.copy2(cached, library)
            reused += 1
        else:
            run(['xcrun', '-sdk', 'macosx', 'metal', *provenance['metal_options'], msl, '-o', air])
            run(['xcrun', '-sdk', 'macosx', 'metallib', air, '-o', library])
            air.unlink()
        reflection.update(chain=chain, key=key, stage=STAGES[stage],
                          library_binary_sha256=sha(library),
                          facts_source=job.get('facts_source'), compiler=provenance)
        stem.with_suffix('.json').write_text(json.dumps(reflection, indent=2))
    # Reserve each constant segment's full declared range until its dynamic indices
    # have been proven bounded; adjacent shaders must never supply out-of-range bytes.
    profile.table('c1_full.tsv').write_text(f'# chain b-{chain}\n' + ''.join(
        j['key'] + '\n' for j, s, src, r in prepared if r['c1']))
    (destination/'rejected.json').write_text(json.dumps(rejected, indent=2))
    (destination/'provenance.json').write_text(json.dumps(provenance, indent=2))
    print(f'{len(prepared)} Metal libraries built ({reused} identical compiled sources reused); '
          f'{len(rejected)} unsupported jobs; chain {chain}')


if __name__ == '__main__':
    main()
