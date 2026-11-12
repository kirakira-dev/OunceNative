from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_nx2_textures import runtime_texture_formats

body = '''
    if (p.x < 1 || p.x >= 9 || p.y < 1 || p.y >= 7) return uint4(0xa5a5a5a5u);
    uint x = uint(p.x) - 1, op = uint(p.y) - 1;
    float2 uv = float2(float(x) + .5f, 1.5f) / float2(8, 4);
    VALUE value;
    if (op == 0) value = TEX.sample(SAMP, RECT ? uv * float2(8, 4) : uv);
    else if (op == 1) value = TEX.sample(SAMP, uv, level(0));
    else if (op == 2) value = TEX.read(uint2(x, 1));
    else if (op == 3) value = TEX.gather(SAMP, uv, int2(0), component::x);
    else if (op == 4) value = TEX.sample(SAMP, uv, gradient2d(float2(.125f, 0), float2(0, .25f)));
    else return uint4(TEX.get_width(), TEX.get_height(), TEX.get_num_mip_levels(), 0x12345678u);
    return as_type<uint4>(value);
'''
prefix = '''#include <metal_stdlib>
using namespace metal;
vertex float4 triangle(uint i [[vertex_id]]) {
    return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1);
}
struct Set {
    texture2d<float> fs_tex2_20 [[id(0)]];
    sampler fs_tex2_20Smplr [[id(1)]];
};
'''
for dimension, texture_type in enumerate(('texture2d', 'texture2d_array', 'texturecube_array')):
    operations = body
    if dimension:
        coord = 'uv' if dimension == 1 else 'float3(1.f, .25f, 2.f * uv.x - 1.f)'
        layer = 'x % 3' if dimension == 1 else 'x % 2'
        operations = operations.replace('SAMP, RECT ? uv * float2(8, 4) : uv', f'SAMP, {coord}, {layer}')
        operations = operations.replace('SAMP, uv,', f'SAMP, {coord}, {layer},')
        operations = operations.replace('TEX.read(uint2(x, 1))', f'TEX.read(uint2(x, 1), ' + ('' if dimension == 1 else '0u, ') + layer + ')')
        operations = operations.replace('0x12345678u', 'TEX.get_array_size()')
        if dimension == 2:
            operations = operations.replace(', int2(0), component::x', ', component::x')
            operations = operations.replace('gradient2d(float2(.125f, 0), float2(0, .25f))',
                                            'gradientcube(float3(0, 0, .25f), float3(0, .25f, 0))')
    source = prefix.replace('texture2d<', texture_type + '<')
    for rect in (0, 1):
        source += f'fragment uint4 main{rect}(constant Set& d [[buffer(0)]], float4 p [[position]]) {{\n'
        source += operations.replace('VALUE', 'float4').replace('TEX', 'd.fs_tex2_20').replace(
            'SAMP', 'd.fs_tex2_20Smplr').replace('RECT', str(rect)) + '}\n'
    reflection = dict(route='B', stage='pixel', bindings=[
        dict(kind='tex', reg=0, arg_id=0, msl_type=texture_type + '<float>', msl_name='fs_tex2_20'),
        dict(kind='samp_tex', reg=0, arg_id=1, msl_type='sampler', msl_name='fs_tex2_20Smplr')])
    source = runtime_texture_formats(source, reflection, 1)
    for scalar in ('float', 'uint', 'int'):
        source += f'fragment uint4 ref_{scalar}({texture_type}<{scalar}> t [[texture(0)]], sampler s [[sampler(0)]], float4 p [[position]]) {{\n'
        source += operations.replace('VALUE', scalar + '4').replace('TEX', 't').replace(
            'SAMP', 's').replace('RECT', '0') + '}\n'
    with tempfile.TemporaryDirectory(prefix='nvn-runtime-textures-') as directory:
        p = Path(directory)
        (p / 'fixture.metal').write_text(source)
        (p / 'fixture.json').write_text(json.dumps(reflection))
        subprocess.run([str(Path(__file__).with_name('t_runtime_textures')), str(p), str(dimension)],
                       check=True, env=dict(os.environ, MTL_DEBUG_LAYER='1'))
