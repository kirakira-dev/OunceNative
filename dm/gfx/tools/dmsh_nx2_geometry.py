"""Adapt supported geometry interfaces to Metal mesh shaders.

Unwritten outputs remain unresolved; their defaults must be checked separately."""
import re
from pathlib import Path
from dmsh_nx2_build import describe, precise_helpers, run

MSL_OPTIONS = ['--msl', '--msl-version', '30200', '--msl-argument-buffers',
               '--msl-discrete-descriptor-set', '1', '--msl-decoration-binding']


def mesh_source(source, metadata):
    geometry = metadata['geometry']
    vertices = geometry['input_vertices']
    maximum = geometry['output_vertices']
    if (geometry['input'], vertices) not in (('points', 1), ('triangles', 3)):
        raise ValueError('unsupported geometry input topology')
    if geometry['invocations'] != 1 or not 1 <= maximum <= 128:
        raise ValueError('unsupported geometry invocation/output count')
    if metadata['sbufs'] or metadata['textures'] or metadata['images']:
        raise ValueError('geometry resources have not been validated')
    if metadata['cbufs'] != [dict(binding=0, slot=3, count=1)]:
        raise ValueError('geometry constant-buffer layout has not been validated')
    header = f'layout({geometry["input"]}) in;'
    if source.count(header) != 1:
        raise ValueError('geometry GLSL input declaration mismatch')
    mode = re.search(r'layout\(max_vertices = (\d+), (points|triangle_strip)\) out;', source)
    if not mode or int(mode[1]) != maximum:
        raise ValueError('geometry GLSL output declaration mismatch')
    topology = 'points' if mode[2] == 'points' else 'triangles'
    max_primitives = maximum if topology == 'points' else max(1, maximum - 2)
    source = source.replace(header, '').replace(mode[0], '')
    inputs, outputs = [], []

    def input_decl(match):
        location, name, length = int(match[1]), match[2], int(match[3])
        if location >= 32 or length != vertices or name != f'in_attr{location}':
            raise ValueError('unrecognized geometry input')
        inputs.append((location, name))
        return f'vec4 {name}[{length}];'

    def output_decl(match):
        location, name = int(match[1]), match[2]
        if location >= 32 or name != f'out_attr{location}':
            raise ValueError('unrecognized geometry output')
        outputs.append((location, name))
        return f'vec4 {name};'

    source = re.sub(r'layout\(location = (\d+)\) in vec4 (\w+)\[(\d+)\];', input_decl, source)
    source = re.sub(r'layout\(location = (\d+)(?:, stream = 0)?\) out vec4 (\w+);', output_decl, source)
    if re.search(r'layout\([^\n]*\)\s+(?:in|out)\b', source):
        raise ValueError('unrecognized geometry stage interface')
    builtins = set(re.findall(r'\bgl_\w+', source))
    output_point_size = bool(re.search(r'(?<!\.)\bgl_PointSize\s*=', source))
    if builtins - {'gl_Position', 'gl_PointSize', 'gl_Layer', 'gl_in'}:
        raise ValueError(f'unrecognized geometry builtins: {sorted(builtins)}')
    if 'gl_in' in builtins and re.search(r'gl_in\[[^\]]+\]\.(?!gl_PointSize\b)', source):
        raise ValueError('unvalidated geometry input builtin')
    for old, new in [('gl_Position', 'dmPosition'), ('gl_PointSize', 'dmPointSize'),
                     ('gl_Layer', 'dmLayer'), ('gl_in', 'dmIn')]:
        source = re.sub(r'\b' + old + r'\b', new, source)
    source = re.sub(r'EmitStreamVertex\((?:int\(0u\)|0)\);', 'dmEmit();', source)
    source = re.sub(r'EndStreamPrimitive\((?:int\(0u\)|0)\);', 'dmStripStart = dmVertexCount;', source)
    if re.search(r'\b(?:Emit\w*Vertex|End\w*Primitive)\b', source):
        raise ValueError('only geometry stream zero is supported')
    if source.count('void main()') != 1:
        raise ValueError('unrecognized geometry entry point')
    source = source.replace('void main()', 'void dmGeometryBody()')
    # FP16 arithmetic remains FP16 through glslang and SPIRV-Cross.
    source = re.sub(r'#if defined\(GL_AMD_gpu_shader_half_float\).*?#endif',
                    '#extension GL_EXT_shader_explicit_arithmetic_types_float16 : require',
                    source, flags=re.S)
    source = source.replace('#version 460', '#version 460\n#extension GL_EXT_mesh_shader : require')
    declaration_at = source.index('layout(binding = 0, std140)')
    declaration_end = source.index('void dmGeometryBody()')
    first = source[:declaration_at]
    declarations = source[declaration_at:declaration_end]
    body = source[declaration_end:]
    # Vertex-capture's canonical 608-byte layout; scalars have four-byte stride.
    wrapper = f'''
layout(local_size_x = 1) in;
layout(max_vertices = {maximum}, max_primitives = {max_primitives}, {topology}) out;
struct DmInputVertex {{
    vec4 attributes[32]; vec4 position; float pointSize; float clip[8];
    uint layer; uint viewport; uint viewportMask; float clipCopy[8];
}};
layout(set=1, binding=20, std430) readonly buffer DmInput {{ DmInputVertex values[]; }} dmInput;
layout(set=1, binding=21, std430) readonly buffer DmPrimitives {{ uvec4 values[]; }} dmPrimitives;
struct DmBuiltins {{ float dmPointSize; }};
DmBuiltins dmIn[{vertices}];
vec4 dmPosition;
float dmPointSize;
int dmLayer;
uint dmVertexCount = 0u;
uint dmPrimitiveCount = 0u;
uint dmStripStart = 0u;
vec4 dmPositions[{maximum}];
float dmPointSizes[{maximum}];
int dmLayers[{maximum}];
uvec3 dmIndices[{max_primitives}];
'''
    for location, name in outputs:
        wrapper += f'vec4 dmValues{location}[{maximum}];\n'
        wrapper += f'layout(location={location}) out vec4 dmOutput{location}[];\n'
    if 'gl_Layer' in builtins:
        wrapper += 'perprimitiveEXT out gl_MeshPerPrimitiveEXT { int gl_Layer; } gl_MeshPrimitivesEXT[];\n'
    # NVIDIA's SPH specification defines OUT past MaxOutputVertexCount as a
    # no-op. Apply the limit before touching the fixed-size mesh arrays.
    emitter = (f'\nvoid dmEmit() {{\n    if (dmVertexCount >= {maximum}u) return;\n'
               '    uint index = dmVertexCount++;\n')
    emitter += '    dmPositions[index] = dmPosition;\n'
    if output_point_size:
        emitter += '    dmPointSizes[index] = dmPointSize;\n'
    if 'gl_Layer' in builtins:
        emitter += '    dmLayers[index] = dmLayer;\n'
    for location, name in outputs:
        emitter += f'    dmValues{location}[index] = {name};\n'
    if topology == 'points':
        emitter += '    dmIndices[dmPrimitiveCount++] = uvec3(index);\n'
    else:
        emitter += '''    uint count = index - dmStripStart;
    if (count >= 2u) {
        dmIndices[dmPrimitiveCount++] = (count & 1u) == 0u ?
            uvec3(index-2u, index-1u, index) : uvec3(index-1u, index-2u, index);
    }
'''
    emitter += '}\n'
    entry = '\nvoid main() {\n    uvec4 primitive = dmPrimitives.values[gl_WorkGroupID.x];\n'
    for i in range(vertices):
        for location, name in inputs:
            entry += f'    {name}[{i}] = dmInput.values[primitive[{i}]].attributes[{location}];\n'
        if 'gl_in' in builtins:
            entry += f'    dmIn[{i}].dmPointSize = dmInput.values[primitive[{i}]].pointSize;\n'
    entry += '''    dmGeometryBody();
    SetMeshOutputsEXT(dmVertexCount, dmPrimitiveCount);
    for (uint i = 0u; i < dmVertexCount; ++i) {
        gl_MeshVerticesEXT[i].gl_Position = dmPositions[i];
'''
    # Fixed point size is supplied by the pipeline when the shader omits it.
    if output_point_size:
        entry += '        gl_MeshVerticesEXT[i].gl_PointSize = dmPointSizes[i];\n'
    for location, name in outputs:
        entry += f'        dmOutput{location}[i] = dmValues{location}[i];\n'
    entry += '    }\n    for (uint i = 0u; i < dmPrimitiveCount; ++i) {\n'
    entry += ('        gl_PrimitivePointIndicesEXT[i] = dmIndices[i].x;\n' if topology == 'points'
              else '        gl_PrimitiveTriangleIndicesEXT[i] = dmIndices[i];\n')
    if 'gl_Layer' in builtins:
        entry += '        gl_MeshPrimitivesEXT[i].gl_Layer = dmLayers[dmIndices[i].x];\n'
    entry += '    }\n}\n'
    result = first + wrapper + declarations + emitter + body + entry
    written_position = ''.join(c for c in 'xyzw' if re.search(r'dmPosition\.' + c + r'\s*=', body))
    return result, dict(version=1, input=geometry['input'], input_vertices=vertices,
                        max_vertices=maximum, max_primitives=max_primitives, output=topology,
                        vertex_stride=608, input_buffer=20, primitive_buffer=21,
                        inputs=[i for i, _ in inputs], outputs=[i for i, _ in outputs],
                        input_point_size='gl_in' in builtins, output_point_size=output_point_size,
                        layer='gl_Layer' in builtins, written_position=written_position,
                        unresolved_position_default=written_position != 'xyzw')


def prepare(spirv, metadata, directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    source = run(['spirv-cross', spirv, '--version', '460'])
    mesh, state = mesh_source(source, metadata)
    glsl = directory / 'geometry.mesh'
    intermediate = directory / 'geometry.mesh.spv'
    glsl.write_text(mesh)
    run(['glslangValidator', '-V', '--target-env', 'vulkan1.2', '-S', 'mesh', glsl, '-o', intermediate])
    run(['spirv-val', '--target-env', 'vulkan1.2', intermediate])
    msl = run(['spirv-cross', intermediate, *MSL_OPTIONS])
    reflection = describe(msl, 2, metadata, None)
    reflection['nx2_geometry'] = state
    if '[[buffer(20)]]' not in msl or '[[buffer(21)]]' not in msl:
        raise ValueError('geometry input buffer binding mismatch')
    msl = depth_entries(msl)
    reflection['entry_z'] = 'main0_z'
    return precise_helpers(msl), reflection


def depth_entries(source):
    """Apply the final raster depth conversion after geometry has emitted."""
    start = source.find('[[mesh]] void main0(')
    if start < 0 or source.count('[[mesh]] void main0(') != 1:
        raise ValueError('unrecognized Metal mesh entry point')
    body = source[start:]
    store = 'spvMesh.set_vertex(spvVI, spvV);'
    if body.count(store) != 1 or body.count('spvV.gl_Position =') != 1:
        raise ValueError('unrecognized Metal mesh position output')
    gl = body.replace(store, 'spvV.gl_Position.z = fma(spvV.gl_Position.z, 0.5, '
                      'spvV.gl_Position.w * 0.5);\n        ' + store)
    return source[:start] + gl + '\n' + body.replace('void main0(', 'void main0_z(', 1)
