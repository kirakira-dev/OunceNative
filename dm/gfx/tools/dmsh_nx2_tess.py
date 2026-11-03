"""Construct precompiled tessellation variants with a shared intermediate layout."""
import re
import struct
from pathlib import Path
from dmsh_nx2_build import describe, depth_entries, integer_vertex_inputs, run, vertex_fetch_inputs
from dmsh_nx2_spirv import prepare as prepare_spirv

VERTEX_STRIDE = 608
PATCH_STRIDE = 512
_BUILTINS = [('float4', 'gl_Position', ''), ('float', 'gl_PointSize', ''),
             ('float', 'gl_ClipDistance', '[8]'), ('uint', 'gl_Layer', ''),
             ('uint', 'gl_ViewportIndex', ''), ('uint', 'gl_ViewportMask', '[1]')]
_BUILTINS += [('float', f'gl_ClipDistance_{i}', '') for i in range(8)]


def stage_modes(spirv, stage):
    data = Path(spirv).read_bytes()
    if len(data) < 20 or len(data) % 4:
        raise ValueError('invalid SPIR-V size')
    words = struct.unpack(f'<{len(data)//4}I', data)
    if words[0] != 0x07230203:
        raise ValueError('invalid SPIR-V magic')
    entries, modes, offset = [], [], 5
    while offset < len(words):
        count, opcode = words[offset] >> 16, words[offset] & 0xffff
        if not count or offset + count > len(words):
            raise ValueError('invalid SPIR-V instruction')
        args = words[offset+1:offset+count]
        if opcode == 15:
            entries.append(args[:2])
        elif opcode == 16:
            modes.append(args)
        offset += count
    if len(entries) != 1 or entries[0][0] != {0: 0, 3: 1, 4: 2}[stage]:
        raise ValueError('SPIR-V execution model does not match the requested stage')
    return {mode[1]: tuple(mode[2:]) for mode in modes if mode[0] == entries[0][1]}


def canonical_io(source, stage):
    """Keep raw buffer fields at fixed offsets even when a stage omits locations."""
    if stage not in (0, 3, 4):
        raise ValueError('invalid tessellation pipeline stage')
    structures = []
    if stage in (3, 4):
        structures.append(('main0_in', 'in_attr', False, 'vertex_in'))
    if stage in (0, 3):
        structures.append(('main0_out', 'out_attr', False, 'vertex_out'))
    if stage == 3:
        structures.append(('main0_patchOut', 'out_patch', True, 'patch_out'))
    if stage == 4:
        structures.append(('main0_patchIn', 'in_patch', True, 'patch_in'))
    layout = dict(version=1, vertex_stride=VERTEX_STRIDE, patch_stride=PATCH_STRIDE)
    for name, prefix, patch, kind in structures:
        matches = list(re.finditer(r'\bstruct ' + name + r'\s*\{(.*?)\n\};', source, re.S))
        if not matches:
            layout[kind] = dict(present=False, locations=0, builtins=[])
            continue
        if len(matches) != 1:
            raise ValueError('duplicate intermediate structure')
        match = matches[0]
        mask, builtins, declarations_by_name = 0, [], {}
        for line in match[1].splitlines():
            line = line.strip()
            if not line:
                continue
            field = re.fullmatch(r'float4\s+' + prefix + r'(\d+);', line)
            if field:
                location = int(field[1])
                if location >= 32 or mask & (1 << location):
                    raise ValueError('invalid intermediate attribute location')
                mask |= 1 << location
                continue
            if not patch:
                compact = re.sub(r'\s+', '', line)
                builtin = next((field_name for typ, field_name, suffix in _BUILTINS
                                if compact == typ + field_name + suffix + ';'), None)
                if builtin and builtin not in builtins:
                    builtins.append(builtin)
                    continue
                array = re.fullmatch(r'spvUnsafeArray<(float|uint),\s*(8|1)>\s+(gl_ClipDistance|gl_ViewportMask);', line)
                if array and (array[1], array[2], array[3]) in (
                        ('float', '8', 'gl_ClipDistance'), ('uint', '1', 'gl_ViewportMask')):
                    if array[3] in builtins:
                        raise ValueError('duplicate intermediate builtin')
                    builtins.append(array[3])
                    declarations_by_name[array[3]] = line
                    continue
            raise ValueError(f'unsupported intermediate field: {name}: {line}')
        declarations = [f'    float4 {prefix}{i};' for i in range(32)]
        if not patch:
            declarations += ['    ' + declarations_by_name.get(field_name, f'{typ} {field_name}{suffix};')
                             for typ, field_name, suffix in _BUILTINS]
        replacement = 'struct ' + name + '\n{\n' + '\n'.join(declarations) + '\n};'
        source = source[:match.start()] + replacement + source[match.end():]
        layout[kind] = dict(present=True, locations=mask, builtins=builtins)
    return source, layout


def vertex_draw_inputs(source):
    """Capture uses indices with the base vertex already added, plus original draw IDs."""
    parameter = 'uint3 spvDispatchBase [[grid_origin]]'
    if parameter not in source:
        if 'spvDispatchBase' in source:
            raise ValueError('unrecognized vertex dispatch origin')
        return source, False
    if source.count(parameter) != 1 or '[[buffer(23)]]' in source:
        raise ValueError('unrecognized vertex draw parameter layout')
    source = source.replace(parameter, 'constant uint4& dmDrawParams [[buffer(23)]]')
    entry = source.index('kernel void main0(')
    opening = source.index('{', entry)
    source = source[:opening+1] + '\n    uint3 spvDispatchBase = uint3(0u, dmDrawParams.y + dmDrawParams.z, 0u);' + source[opening+1:]
    for name, component in [('gl_BaseVertex', 'x'), ('gl_BaseInstance', 'y')]:
        declaration = f'uint {name} = spvDispatchBase.{component};'
        if name in source and source.count(declaration) != 1:
            raise ValueError(f'unrecognized vertex builtin: {name}')
        source = source.replace(declaration, f'uint {name} = dmDrawParams.{component};')
    return source, True


def prepare(spirv, compiler, stage, meta, control_points=None):
    if stage not in (0, 3, 4):
        raise ValueError('invalid tessellation stage')
    if stage == 4 and (not isinstance(control_points, int) or not 1 <= control_points <= 32):
        raise ValueError('domain stage requires its hull output control-point count')
    if stage != 4 and control_points is not None:
        raise ValueError('unexpected domain control-point argument')
    modes = stage_modes(spirv, stage)
    if stage in (3, 4):
        domains = {22: 'triangles', 24: 'quads', 25: 'isolines'}
        present = [name for mode, name in domains.items() if mode in modes]
        if present != [meta['tessellation']['domain']]:
            raise ValueError('SPIR-V tessellation domain is missing or disagrees with metadata')
    if stage == 3 and (len(modes.get(26, ())) != 1 or not 1 <= modes[26][0] <= 32):
        raise ValueError('invalid hull output control-point count')
    if stage == 4 and 26 in modes and modes[26] != (control_points,):
        raise ValueError('domain control-point count disagrees with its execution mode')
    options = [control_points] if stage == 4 else ['--index-u32'] if stage == 0 else []
    spirv, bank_proofs = prepare_spirv(spirv, meta)
    source = run([compiler, spirv, *options])
    if stage == 0:
        source = integer_vertex_inputs(source)
        source, draw_params = vertex_draw_inputs(source)
    reflection = describe(source, stage, meta, None)
    if bank_proofs:
        reflection['nx2_constant_bank_proofs'] = bank_proofs
    if stage == 0:
        source, mask = vertex_fetch_inputs(source)
        if mask:
            reflection['vertex_fetch'] = dict(version=1, constant_base=64, mask=mask)
    source, layout = canonical_io(source, stage)
    if stage == 0:
        layout['vertex_index_type'] = 'uint32'
        layout['draw_params'] = draw_params
    if stage in (3, 4):
        layout['state'] = meta['tessellation']
    if stage == 3:
        layout['control_points'] = modes[26][0]
    if stage == 4:
        layout['control_points'] = control_points
        source = depth_entries(source)
        reflection['entry_z'] = 'main0_z'
    reflection['nx2_tessellation'] = layout
    return source, reflection
