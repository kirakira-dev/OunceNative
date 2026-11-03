import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_nx2_geometry import mesh_source


SOURCE = '''#version 460
layout(points) in;
layout(max_vertices = 4, triangle_strip) out;
layout(binding = 0, std140) uniform gs_cbuf_block_3u
{
    uvec4 data[4096];
} c3;
layout(location = 0) in vec4 in_attr0[1];
layout(location = 0) out vec4 out_attr0;
void main()
{
    gl_Position.x = in_attr0[0].x;
    gl_Position.y = in_attr0[0].y;
    gl_Position.z = 0.0;
    gl_Position.w = 1.0;
    out_attr0.x = uintBitsToFloat(c3.data[0].x);
    EmitStreamVertex(int(0u));
    EndStreamPrimitive(int(0u));
}
'''
META = dict(geometry=dict(input='points', input_vertices=1, output_vertices=4, invocations=1),
            cbufs=[dict(binding=0, slot=3, count=1)], sbufs=[], textures=[], images=[])


class GeometryValidation(unittest.TestCase):
    def test_shader_body_survives_interface_lowering(self):
        mesh, state = mesh_source(SOURCE, META)
        self.assertIn('dmPosition.x = in_attr0[0].x;', mesh)
        self.assertIn('uintBitsToFloat(c3.data[0].x)', mesh)
        self.assertIn('if (dmVertexCount >= 4u) return;', mesh)
        self.assertFalse(state['unresolved_position_default'])

    def test_unwritten_position_is_not_invented(self):
        source = SOURCE.replace('    gl_Position.z = 0.0;\n', '').replace('    gl_Position.w = 1.0;\n', '')
        mesh, state = mesh_source(source, META)
        self.assertTrue(state['unresolved_position_default'])
        self.assertEqual(state['written_position'], 'xy')
        self.assertNotIn('dmPosition.w =', mesh)

    def test_mismatched_metadata_is_rejected(self):
        for field, value in [('input_vertices', 3), ('input', 'lines'),
                             ('invocations', 2), ('output_vertices', 5)]:
            with self.subTest(field=field):
                meta = copy.deepcopy(META)
                meta['geometry'][field] = value
                with self.assertRaises(ValueError):
                    mesh_source(SOURCE, meta)

    def test_unvalidated_resources_are_rejected(self):
        for field in ('textures', 'sbufs', 'images'):
            with self.subTest(field=field):
                meta = copy.deepcopy(META)
                meta[field] = [dict(binding=1)]
                with self.assertRaises(ValueError):
                    mesh_source(SOURCE, meta)
        meta = copy.deepcopy(META)
        meta['cbufs'][0]['slot'] = 4
        with self.assertRaises(ValueError):
            mesh_source(SOURCE, meta)

    def test_unvalidated_stage_operations_are_rejected(self):
        for before, after in [('int(0u)', 'int(1u)'), ('gl_Position.x', 'gl_ClipDistance[0]'),
                              ('in_attr0[1]', 'in_attr0[3]'), ('location = 0) in', 'location = 32) in')]:
            with self.subTest(after=after), self.assertRaises(ValueError):
                mesh_source(SOURCE.replace(before, after), META)


if __name__ == '__main__':
    unittest.main()
