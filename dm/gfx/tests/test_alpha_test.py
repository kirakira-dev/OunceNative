from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_nx2_build import fragment_alpha_test, fragment_output_types

source = '''#include <metal_stdlib>
using namespace metal;
vertex float4 triangle(uint i [[vertex_id]]) {
    return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0.25, 1.0);
}
struct main0_out { float4 color0 [[color(0)]]; float4 color1 [[color(1)]]; };
fragment main0_out main0(float4 position [[position]]) {
    const uint alpha_bits[8] = {0xbf800000, 0x80000000, 0x00000000, 0x3e800000,
                                   0x3f000000, 0x3f400000, 0x3f800000, 0x7fc00000};
    main0_out out = {};
    out.color0 = float4(0.25, 0.5, 0.75, as_type<float>(alpha_bits[uint(position.x)]));
    out.color1 = float4(1, 0, 1, 1);
    if (position.x < 4) { return out; }
    return out;
}
'''
assert not fragment_alpha_test(source.replace('color(0)', 'color(2)'))[1]
with tempfile.TemporaryDirectory(prefix='nvn-alpha-') as directory:
    for retained in (False, True):
        if retained:
            transformed, colors = fragment_output_types(source)
            transformed, alpha = fragment_alpha_test(transformed)
        else:
            transformed, alpha = fragment_alpha_test(source)
            transformed, colors = fragment_output_types(transformed)
        assert alpha and colors == 3
        p = Path(directory) / f'fixture-{retained}.metal'
        p.write_text(transformed)
        subprocess.run([str(Path(__file__).with_name('t_alpha_test')), str(p)],
                       check=True, env=dict(os.environ, MTL_DEBUG_LAYER='1'))
