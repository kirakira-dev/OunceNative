#!/usr/bin/env python3
"""Convert native NVN shader captures and measured resource facts to NX2 jobs."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct

# NVN texture targets to Shader::TextureType in the pinned offline compiler.
TARGETS = {0: 0, 1: 2, 2: 4, 3: 1, 4: 3, 5: 2, 6: 3, 7: 8, 8: 5, 9: 6, 10: 7}


def format_map(nvn_names, compiler_formats):
    result = {}
    channels = [('R8', 'R8'), ('R16', 'R16'), ('R32', 'R32'),
                ('RG8', 'R8G8'), ('RG16', 'R16G16'), ('RG32', 'R32G32'),
                ('RGB32', 'R32G32B32'), ('RGBA8', 'A8B8G8R8'),
                ('RGBA16', 'R16G16B16A16'), ('RGBA32', 'R32G32B32A32')]
    for nvn, compiler in channels:
        for suffix, kind in [('', 'UNORM'), ('SN', 'SNORM'), ('UI', 'UINT'),
                             ('I', 'SINT'), ('F', 'FLOAT')]:
            name = compiler + '_' + kind
            if name in compiler_formats:
                result[nvn + suffix] = name
    result.update(
        RGBA8_SRGB='A8B8G8R8_SRGB', RGB10A2='A2B10G10R10_UNORM',
        R11G11B10F='B10G11R11_FLOAT', RGB9E5F='E5B9G9R9_FLOAT',
        DEPTH16='D16_UNORM', DEPTH24='X8_D24_UNORM', DEPTH32F='D32_FLOAT',
        STENCIL8='S8_UINT', DEPTH24_STENCIL8='D24_UNORM_S8_UINT',
        DEPTH32F_STENCIL8='D32_FLOAT_S8_UINT',
        RGBA_DXT1='BC1_RGBA_UNORM', RGBA_DXT3='BC2_UNORM', RGBA_DXT5='BC3_UNORM',
        RGBA_DXT1_SRGB='BC1_RGBA_SRGB', RGBA_DXT3_SRGB='BC2_SRGB',
        RGBA_DXT5_SRGB='BC3_SRGB', RGTC1_UNORM='BC4_UNORM',
        RGTC1_SNORM='BC4_SNORM', RGTC2_UNORM='BC5_UNORM', RGTC2_SNORM='BC5_SNORM',
        BPTC_UNORM='BC7_UNORM', BPTC_UNORM_SRGB='BC7_SRGB',
        BPTC_UFLOAT='BC6H_UFLOAT', BPTC_SFLOAT='BC6H_SFLOAT')
    for name in nvn_names.values():
        if name.startswith('RGBA_ASTC_'):
            dimensions = name[len('RGBA_ASTC_'):].rsplit('_', 1)
            suffix = dimensions[1] if len(dimensions) == 2 else 'UNORM'
            mapped = 'ASTC_2D_' + dimensions[0].upper() + '_' + suffix
            if mapped in compiler_formats:
                result[name] = mapped
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('capture', type=Path, help='DM_NVN_SHDUMP folder')
    ap.add_argument('facts', type=Path, help='DM_NVN_FACTDUMP folder')
    ap.add_argument('fork', type=Path, help='pinned PokeDinner source checkout')
    ap.add_argument('output', type=Path, help='output JSON job array')
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[3]
    header = (repo / 'dm/gfx/nvn/include/nvn.h').read_text()
    nvn_names = {int(value, 16): name for name, value in re.findall(
        r'NVN_FORMAT_(\w+) = (0x[0-9A-Fa-f]+)', header)}
    # GraphicsEnvironment casts Surface::PixelFormat to the shader enum.
    surface = (args.fork / 'src/video_core/surface.h').read_text()
    surface = surface.split('enum class PixelFormat')[0]
    compiler_formats = {name: index for index, name in enumerate(
        re.findall(r'PIXEL_FORMAT_ELEM\((\w+), \d', surface))}
    mapped_formats = format_map(nvn_names, compiler_formats)
    capture = args.capture.resolve()
    jobs, unmapped = [], Counter()
    for path in sorted(args.facts.glob('*.facts.json')):
        facts = json.loads(path.read_text())
        key = facts['key']
        if not re.fullmatch('[0-9a-f]{16}', key):
            raise ValueError(f'invalid shader key: {key}')
        control_path = capture / (key + '.ctl')
        code_path = control_path.with_suffix('.code')
        if not control_path.exists() or not code_path.exists():
            continue
        control = control_path.read_bytes()
        c1_size = struct.unpack_from('<I', control, 0x3c)[0]
        c1 = control_path.with_suffix('.c1').read_bytes() if c1_size else b''
        digest = hashlib.sha256(control + code_path.read_bytes() + c1).hexdigest()[:16]
        if len(c1) != c1_size or digest != key:
            raise ValueError(f'capture integrity mismatch: {key}')
        stage = struct.unpack_from('<H', control, 0x56)[0]
        if stage != facts['stage']:
            raise ValueError(f'capture stage mismatch: {key}')
        textures = {}
        for handle, texture in facts['nvn_textures'].items():
            target = texture['target']
            if target not in TARGETS:
                raise ValueError(f'unmapped NVN texture target: {target}')
            descriptor = {'type': TARGETS[target]}
            name = mapped_formats.get(nvn_names.get(texture['format']))
            if name is None:
                unmapped[texture['format']] += 1
            else:
                integer = name.endswith(('_SINT', '_UINT')) and not name.startswith(
                    ('D24', 'S8_UINT_D24', 'D32'))
                descriptor.update(format=compiler_formats[name], integer=int(integer))
            textures[handle] = descriptor
        job = dict(key=key, control=str(control_path), code=str(code_path),
                   facts_source=str(path.resolve()), cbuf=facts['cbuf'], textures=textures,
                   native_root_tables=True, root_constants=facts.get('root_constants', {}))
        if c1_size:
            job['c1'] = str(control_path.with_suffix('.c1'))
        if stage == 5:
            local_pos, local_crs, local_unmapped = struct.unpack_from('<3I', control, 0x68)
            if local_unmapped or local_pos + local_crs >= 1 << 20:
                raise ValueError(f'unmeasured compute local memory: {key}')
            job.update(local=list(struct.unpack_from('<3I', control, 0x58)),
                       shared=struct.unpack_from('<I', control, 0x64)[0],
                       local_memory=local_pos + local_crs)
            bindings = facts.get('native_compute_bindings')
            if bindings:
                base = 16 + sum((words * 4 + 15) & ~15 for words in control[0xa9:0xb1])
                base += 16 * (control[0xb1] + control[0xb2])
                expected_size = base + 8 * (control[0xb3] + control[0xb6])
                if expected_size != struct.unpack_from('<H', control, 0xba)[0]:
                    raise ValueError(f'compute driver table size mismatch: {key}')
                for index, handle in enumerate(bindings['textures'] + bindings['images']):
                    job['cbuf'][f'0:{base + 8 * index}'] = handle & 0xffffffff
                    job['cbuf'][f'0:{base + 8 * index + 4}'] = handle >> 32
        jobs.append(job)
    if unmapped:
        raise ValueError(f'unmapped NVN texture formats: {dict(unmapped)}')
    if not jobs:
        raise ValueError('no matching captured shaders and native facts')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(jobs, indent=2))
    print(len(jobs), 'jobs written to', args.output)


if __name__ == '__main__':
    main()
