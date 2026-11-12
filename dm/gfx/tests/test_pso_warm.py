from pathlib import Path
import os
import subprocess
import tempfile

source = '''#include <metal_stdlib>
using namespace metal;
vertex float4 triangle(uint i [[vertex_id]]) {
    return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1);
}
fragment float4 color() { return float4(.25, .5, .75, 1); }
kernel void compute(device uint *values [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    values[i] = 0x12340000u + i;
}
'''
with tempfile.TemporaryDirectory(prefix='nvn-pso-warm-') as directory:
    root = Path(directory)
    (root / 'fixture.metal').write_text(source)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', str(root / 'fixture.metal'),
                    '-o', str(root / 'fixture.air')], check=True)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(root / 'fixture.air'),
                    '-o', str(root / 'fixture.metallib')], check=True)
    for workers in (1, 4, 8):
        case = root / str(workers)
        case.mkdir()
        (case / 'fixture.metallib').hardlink_to(root / 'fixture.metallib')
        subprocess.run([str(Path(__file__).with_name('t_pso_warm')), str(case), str(workers)],
                       check=True, env=dict(os.environ, MTL_DEBUG_LAYER='1'))
