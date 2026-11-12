#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise native TXQ masks through SPIR-V, reflection and the NVN Metal runtime."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'dm/gfx/tools'))
from dmsh_nx2_build import XC, compute_layout, describe


def fixtures(output):
    jobs = []
    for image in (0, 1):
        for mask in range(1, 16):
            key = f'{image * 15 + mask:016x}'
            control = bytearray(256)
            control[86] = 5
            control[0xb2] = control[0xb3] = control[0xb6] = 1
            struct.pack_into('<H', control, 0xba, 48)
            struct.pack_into('<3I', control, 0x58, 1, 1, 1)
            code = [
                (0x00007ab9, 0x400, 0x00000a00, 0),  # ULDC.64 UR0, c0[16].
                (0x00027919, 0, 0x00002500, 0),      # S2R R2, CTAID.X (LOD).
                (0x02037824, 16, 0x078e00ff, 0),     # IMAD R3, R2, 16, RZ.
            ]
            for reg in range(4, 8):
                code.append((0x7802 | (reg << 16), 0xa5a5a5a5, 0x00000f00, 0))
            second = 6 if mask.bit_count() > 2 else 255
            code.extend([
                (0x02047b6f, ((32 + image * 8) // 4) << 8, (mask << 8) | second, 0),
                (0x03007986, 4, 0x0810ad00, 0),      # STG.128 [UR0 + R3], R4..7.
                (0x0000794d, 0, 0x03800000, 0),      # EXIT.
            ])
            (output / (key + '.ctl')).write_bytes(control)
            (output / (key + '.code')).write_bytes(b''.join(struct.pack('<4I', *op) for op in code))
            jobs.append(dict(key=key, control=str(output / (key + '.ctl')),
                             code=str(output / (key + '.code')), local=[1, 1, 1],
                             shared=0, local_memory=0, cbuf={}, textures={}, root_constants={},
                             native_root_tables=True, defer_texture_queries=True))
    return jobs


def run(compiler, output):
    output.mkdir(parents=True, exist_ok=True)
    jobs = fixtures(output)
    path = output / 'jobs.json'
    path.write_text(json.dumps(jobs, indent=2))
    subprocess.run([str(compiler), str(path), str(output / 'spirv')], check=True)
    for job in jobs:
        key = job['key']
        spv = output / 'spirv' / (key + '.spv')
        subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(spv)], check=True)
        source = subprocess.check_output(['spirv-cross', str(spv), *XC], text=True)
        meta = json.loads(spv.with_suffix('.json').read_text())
        layout = compute_layout(Path(job['control']).read_bytes())
        reflection = describe(source, 5, meta, layout)
        reflection.update(stage='compute', nx2_compute=layout, threadgroup_size=[1, 1, 1])
        queries = [b for b in reflection['bindings'] if b['kind'] in ('tex_query', 'img_query')]
        assert len(queries) == 1 and queries[0]['reg'] == 0
        assert queries[0]['kind'] == ('img_query' if int(key, 16) > 15 else 'tex_query')
        (output / (key + '.metal')).write_text(source)
        (output / (key + '.json')).write_text(json.dumps(reflection, indent=2))
    # The default compiler mode must still require facts for these same queries.
    strict = [dict(job, defer_texture_queries=False) for job in jobs]
    path = output / 'strict-jobs.json'
    path.write_text(json.dumps(strict))
    with (output / 'strict.log').open('w') as log:
        result = subprocess.run([str(compiler), str(path), str(output / 'strict')],
                                stdout=log, stderr=subprocess.STDOUT)
    report = [json.loads(line) for line in (output / 'strict/compile-report.jsonl').read_text().splitlines()]
    assert result.returncode == 1 and len(report) == 30
    assert all(row['status'] == 'error' and 'constant-buffer fact required' in row['error'] for row in report)
    subprocess.run(['make', '-C', str(ROOT / 'dm/gfx/tests'), 'GAME=0400380020056000', 't_texture_queries'], check=True)
    subprocess.run([str(ROOT / 'dm/gfx/tests/t_texture_queries'), str(output)],
                   check=True, env=dict(os.environ, MTL_DEBUG_LAYER='1'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.output:
        run(args.compiler.resolve(), args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='nx2-texture-queries-') as temporary:
            run(args.compiler.resolve(), Path(temporary))
