from pathlib import Path
import os, subprocess, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_nx2_build import fragment_inputs, fragment_output_types
source = '''#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float4 a [[user(locn1)]]; };
vertex float4 vsmissing(uint i [[vertex_id]]) { return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); }
vertex V vspresent(uint i [[vertex_id]]) { V v; v.p=float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); v.a=float4(0.25,0.5,0.75,0.875); return v; }
struct main0_out { float4 color0 [[color(0)]]; float4 color1 [[color(1)]]; };
struct main0_in { float4 attr [[user(locn1)]]; };
fragment main0_out main0(main0_in in [[stage_in]]) {
    main0_out out = {};
    out.color0 = as_type<float4>(uint4(0x3f800000,0x80000000,0xbf000000,0x4aabc123));
    out.color1 = in.attr;
    return out;
}
'''
source, inputs = fragment_inputs(source)
source, colors = fragment_output_types(source)
assert inputs == 2 and colors == 3
with tempfile.TemporaryDirectory(prefix='nx2-interfaces-') as directory:
    p = Path(directory) / 'fixture.metal'; p.write_text(source)
    subprocess.run([str(Path(__file__).with_name('t_nx2_interfaces')), str(p)], check=True,
                   env=dict(os.environ, MTL_DEBUG_LAYER='1'))
