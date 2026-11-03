from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_nx2_build import cbuf_read_words


class UniformReads(unittest.TestCase):
    prefix = 'struct C { uint4 data[4096]; };\nstruct A { constant C* c3 [[id(0)]]; };\n'

    def reads(self, body):
        return cbuf_read_words(self.prefix + body, 'c3', 'constant C*')

    def test_sparse_components_and_vectors(self):
        self.assertEqual(self.reads('x=(*args.c3).data[1u].xz; y=(*args.c3).data[6];'),
                         [4, 6, 24, 25, 26, 27])

    def test_reject_unproven_uses(self):
        for body in ('x=(*args.c3).data[i].x;', 'call(args.c3);',
                     'x=(*args.c3).data[64u].x;', 'x=(*args.c3).data[1].foo;',
                     'x=(*args.c3).data[1].x; call(args.c3);'):
            with self.subTest(body=body):
                self.assertIsNone(self.reads(body))

    def test_layout_and_missing_reads(self):
        self.assertIsNone(self.reads(''))
        source = self.prefix.replace('uint4', 'uint2') + 'x=(*args.c3).data[1].x;'
        self.assertIsNone(cbuf_read_words(source, 'c3', 'constant C*'))


if __name__ == '__main__':
    unittest.main()
