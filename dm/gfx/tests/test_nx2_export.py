"""Package identity, coverage, and rollback guards; no game data is required."""
import hashlib
import json
from pathlib import Path
import sqlite3
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import dmsh_nx2_export as ex

K = '0123456789abcdef'
H = 'a' * 64
MAP = 'package\tindex\tstage\tdm_ctl_sha16\tsource\n'


class ExportTests(unittest.TestCase):
    def test_bounded_bank_archive_replays_its_proof(self):
        import dmsh_nx2_bank_ranges as ranges
        from test_bank_ranges import assemble, shader_source
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source = folder/'source.spv'
            output = folder/'output.spv'
            source.write_bytes(assemble(shader_source(loop=True)))
            proof = ranges.prepare(source, output)
            original = folder/'original.sqlite'
            transformed = folder/'transformed.sqlite'
            schema = 'CREATE TABLE programs (key TEXT, sha256 TEXT, stage INTEGER, status TEXT, spirv_zlib BLOB, reflection_zlib BLOB)'
            reflection = zlib.compress(b'{}')
            for path, binary in ((original, source), (transformed, output)):
                db = sqlite3.connect(path)
                db.execute(schema)
                db.execute('INSERT INTO programs VALUES (?,?,?,?,?,?)',
                           (K, H, 5, 'ok', zlib.compress(binary.read_bytes()), reflection))
                db.commit()
                db.close()
            hashes = {str(original.resolve()): ex.sha(original)}
            record = dict(format='nx2-bounded-cbuf-v1', source_archive=str(original),
                          source_archive_sha256=hashes[str(original.resolve())], toolchain=ranges.toolchain_provenance(),
                          programs={K: proof})
            translation = {'bounded_constant_banks': json.dumps(record)}
            db = sqlite3.connect(transformed)
            try:
                ex.validate_bounded_translation(db, translation, transformed, 'ordinary', hashes)
                for changes in (dict(format='unknown'), dict(source_archive=str(transformed)),
                                dict(source_archive_sha256='0'*64), dict(toolchain={}), dict(programs={})):
                    bad = {'bounded_constant_banks': json.dumps(dict(record, **changes))}
                    with self.subTest(changes=changes), self.assertRaises(ValueError):
                        ex.validate_bounded_translation(db, bad, transformed, 'ordinary', hashes)
                bad_proof = dict(proof, output_sha256='0'*64)
                with self.assertRaisesRegex(ValueError, 'proof replay'):
                    ex.validate_bounded_translation(db, {'bounded_constant_banks': json.dumps(
                        dict(record, programs={K: bad_proof}))}, transformed, 'ordinary', hashes)
                db.execute('UPDATE programs SET spirv_zlib=?', (zlib.compress(source.read_bytes()),))
                with self.assertRaisesRegex(ValueError, 'proof replay'):
                    ex.validate_bounded_translation(db, translation, transformed, 'ordinary', hashes)
                db.execute('UPDATE programs SET sha256=?', ('b'*64,))
                with self.assertRaisesRegex(ValueError, 'source identity'):
                    ex.validate_bounded_translation(db, translation, transformed, 'ordinary', hashes)
            finally:
                db.close()

    def test_unused_image_query_sampler_keeps_its_argument_slot(self):
        source = '''struct A {
    texture2d_array<float> cs_tex0_c8 [[id(0)]];
    sampler cs_tex0_c8Smplr [[id(1)]];
};
uint query(constant A &a) { return a.cs_tex0_c8.get_width(); }
'''
        image = dict(kind='img', arg_id=0, reg=0, rw=False,
                     msl_name='cs_tex0_c8', msl_type='texture2d_array<float>')
        reflection = dict(stage='compute', bindings=[image])
        result = ex.complete_argument_bindings(reflection, ex.argument_members(source))
        self.assertEqual(result['bindings'][0], image)
        self.assertEqual(result['bindings'][1], dict(kind='unused_sampler', arg_id=1,
            msl_name='cs_tex0_c8Smplr', msl_type='sampler'))
        self.assertEqual(reflection['bindings'], [image])
        for changed in [source.replace('get_width()', 'sample(a.cs_tex0_c8Smplr, float2(0), 0).x'),
                        source.replace('sampler cs_tex0_c8Smplr', 'device uint* cs_tex0_c8Smplr'),
                        source.replace('id(1)', 'id(2)')]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                ex.complete_argument_bindings(reflection, ex.argument_members(changed))
        for bad in [dict(reflection, stage='vertex'), dict(reflection, bindings=[]),
                    dict(reflection, bindings=[dict(image, rw=True)]),
                    dict(reflection, bindings=[dict(image, msl_name='wrong')])]:
            with self.assertRaises(ValueError):
                ex.complete_argument_bindings(bad, ex.argument_members(source))
        for bad in [source.replace('id(1)', 'id(0)'), source.replace('id(1)', 'id(64)')]:
            with self.assertRaises(ValueError):
                ex.argument_members(bad)

    def archive(self, known=None, records=None):
        return types.SimpleNamespace(known=known or {K: (H, 0)}, records=records or {})

    def test_capture_keeps_nonarchive_and_overrides_overlap(self):
        extra = 'fedcba9876543210'
        record = dict(key=K, library_hash='b' * 64)
        captures = {K + '_b': record, extra + '_b': dict(key=extra, library_hash='d' * 64)}
        archive = self.archive(records={K + '_b': dict(library_hash='c' * 64)})
        known, records, overrides = ex.combine([archive], {K: ('e' * 64, 0), extra: ('f' * 64, 1)}, captures,
                                               MAP + f'capture\t0\tpixel\t{extra}\tcapture\n')
        self.assertEqual(known[K], (H, 0))
        self.assertIn(extra, known)
        self.assertIs(records[K + '_b'], record)
        self.assertFalse(overrides[0]['sources_equal'])
        with self.assertRaisesRegex(ValueError, 'drop or change'):
            ex.combine([archive], {}, {}, MAP + f'capture\t0\tpixel\t{extra}\tcapture\n')

    def test_reject_identity_conflicts(self):
        with self.assertRaisesRegex(ValueError, 'canonical shader identities'):
            ex.combine([self.archive(), self.archive({K: ('b' * 64, 0)})], {}, {}, MAP)
        with self.assertRaisesRegex(ValueError, 'stage conflicts'):
            ex.combine([self.archive()], {K: (H, 1)}, {}, MAP)
        with self.assertRaisesRegex(ValueError, 'duplicate archive variant'):
            ex.combine([self.archive(records={K + '_b': {}}), self.archive(records={K + '_b': {}})], {}, {}, MAP)

    def test_ordinary_overlay_fills_only_missing_canonical_variants(self):
        extra = 'f' * 16
        primary = self.archive({K: (H, 1), extra: ('b' * 64, 5)}, {extra + '_b': {}})
        overlay = self.archive({K: (H, 1)}, {K + '_b': {}})
        known, records, overrides = ex.combine([primary, overlay], {}, {}, MAP)
        self.assertEqual(known, primary.known)
        self.assertTrue(ex.coverage(known, records)['complete'])
        self.assertEqual(overrides, [])
        with self.assertRaisesRegex(ValueError, 'duplicate archive variant'):
            ex.combine([primary, overlay, overlay], {}, {}, MAP)
        changed = self.archive({K: ('c' * 64, 1)}, {K + '_b': {}})
        with self.assertRaisesRegex(ValueError, 'canonical shader identities'):
            ex.combine([primary, changed], {}, {}, MAP)

    def test_capture_vertex_variant_requires_its_owned_identity(self):
        extra, source = 'f' * 16, 'b' * 64
        primary = self.archive(records={K + '_b': {}, K + '_tv_b': {}})
        variant = self.archive({extra: (source, 0)}, {extra + '_tv_b': {}})
        with self.assertRaisesRegex(ValueError, 'canonical shader identities'):
            ex.combine([primary, variant], {}, {}, MAP)
        known, records, _ = ex.combine([primary, variant], {extra: (source, 0)},
                                      {extra + '_b': dict(key=extra, library_hash=H)}, MAP)
        self.assertEqual(known[extra], (source, 0))
        self.assertTrue(ex.coverage(known, records)['complete'])
        with self.assertRaisesRegex(ValueError, 'canonical shader identities'):
            ex.combine([primary, variant], {extra: ('c' * 64, 0)}, {}, MAP)

    def test_variants_cannot_count_as_other_stages(self):
        tess = dict(version=1, vertex_stride=608, patch_stride=512, control_points=3, vertex_index_type='uint32')
        reflection = dict(nx2_tessellation=tess)
        for stage, kind, suffix in [(0, 'vertex', '_tv_b'), (3, 'tess', '_th_b'), (4, 'tess', '_td3_b')]:
            self.assertEqual(ex.variant_suffix(stage, reflection, kind), suffix)
        for stage, kind in [(0, 'ordinary'), (3, 'ordinary'), (4, 'vertex'), (1, 'tess')]:
            with self.assertRaises(ValueError):
                ex.variant_suffix(stage, reflection, kind)
        tess['control_points'] = 5
        with self.assertRaises(ValueError):
            ex.variant_suffix(4, reflection, 'tess')
        known = {K: (H, 0), 'b' * 16: (H, 2), 'c' * 16: (H, 3)}
        status = ex.coverage(known, {K + '_tv_b': {}, 'c' * 16 + '_th_b': {}})
        self.assertFalse(status['complete'])
        self.assertEqual(set(status['missing']), {K + '_b', 'b' * 16 + '_gm_b'})

    def test_geometry_requires_distinct_variant_and_tracks_unresolved_semantics(self):
        geometry = dict(version=1, vertex_stride=608, input_buffer=20, primitive_buffer=21,
                        input='points', input_vertices=1, output='points', unresolved_position_default=True)
        reflection = dict(nx2_geometry=geometry)
        self.assertEqual(ex.variant_suffix(2, reflection, 'geometry'), '_gm_b')
        for stage, kind in [(0, 'geometry'), (2, 'ordinary'), (0, 'vertex')]:
            with self.assertRaises(ValueError):
                ex.variant_suffix(stage, reflection, kind)
        known = {K: (H, 2)}
        status = ex.coverage(known, {K + '_gm_b': dict(reflection=reflection)})
        self.assertEqual(status['missing_variants'], 0)
        self.assertEqual(status['unresolved'], [K + '_gm_b'])
        self.assertFalse(status['complete'])
        geometry['unresolved_position_default'] = False
        self.assertTrue(ex.coverage(known, {K + '_gm_b': dict(reflection=reflection)})['complete'])

    def test_toolchain_rejects_solver_and_math_changes(self):
        expected = dict(metal_options=ex.METAL_OPTIONS, constant_bank_toolchain={'solver': 'pinned'})
        ex.check_toolchain(expected, expected)
        for changed in [dict(expected, metal_options=['-ffast-math']), dict(expected, constant_bank_toolchain={})]:
            with self.assertRaises(ValueError):
                ex.check_toolchain(changed, expected)

    def fixture(self, root):
        translated = root / 'translated.sqlite'
        source = sqlite3.connect(translated)
        source.executescript('CREATE TABLE programs(key TEXT,sha256 TEXT,stage INTEGER,status TEXT); CREATE TABLE provenance(key TEXT,value TEXT);')
        source.execute('INSERT INTO programs VALUES (?,?,?,?)', (K, H, 0, 'ok'))
        translation = {'spirv_val_target': 'vulkan1.2'}
        source.executemany('INSERT INTO provenance VALUES (?,?)', translation.items())
        source.commit(); source.close()
        metal = root / 'metal.sqlite'
        output = sqlite3.connect(metal)
        output.executescript('CREATE TABLE programs(key TEXT,sha256 TEXT,stage INTEGER,status TEXT,error TEXT,library_hash TEXT,reflection_zlib BLOB); CREATE TABLE libraries(hash TEXT,metal_zlib BLOB,metal_size INTEGER,source_zlib BLOB); CREATE TABLE provenance(key TEXT,value TEXT);')
        src, binary = b'vertex shader source', b'MTLBfixture'
        library_hash = hashlib.sha256(src).hexdigest()
        reflection = dict(key=K, stage='vertex', route='B', archive_shader_sha256=H)
        output.execute('INSERT INTO programs VALUES (?,?,?,?,?,?,?)', (K, H, 0, 'ok', None, library_hash, zlib.compress(json.dumps(reflection).encode())))
        output.execute('INSERT INTO libraries VALUES (?,?,?,?)', (library_hash, zlib.compress(binary), len(binary), zlib.compress(src)))
        output.executemany('INSERT INTO provenance VALUES (?,?)', [(k, json.dumps(v)) for k, v in dict(input_database_sha256=ex.sha(translated), input_translation_provenance=translation).items()])
        output.commit(); output.close()
        return translated, metal, library_hash

    def test_archive_binary_and_source_validation(self):
        for corruption in ('none', 'source', 'binary_size', 'missing'):
            with self.subTest(corruption=corruption), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                translated, metal, library_hash = self.fixture(root)
                output = sqlite3.connect(metal)
                if corruption == 'source':
                    output.execute('UPDATE libraries SET source_zlib=?', (zlib.compress(b'changed'),))
                elif corruption == 'binary_size':
                    output.execute('UPDATE libraries SET metal_size=1')
                elif corruption == 'missing':
                    output.execute('DELETE FROM libraries')
                output.commit(); output.close()
                archive = ex.Archive(translated, metal, 'ordinary', {}, {})
                destination = root / 'out'; destination.mkdir()
                if corruption != 'none':
                    with self.assertRaises(ValueError):
                        ex.export_libraries(archive.records, destination, root / 'cache', '123456789abc')
                else:
                    self.assertEqual(ex.export_libraries(archive.records, destination, root / 'cache', '123456789abc'), 1)
                    exported = json.loads((destination / (K + '_b.json')).read_text())
                    self.assertEqual(exported['chain'], '123456789abc')
                    self.assertEqual(exported['library_binary_sha256'], ex.sha(destination / (K + '_b.metallib')))
                    self.assertEqual((destination / (K + '_b.metallib')).stat().st_nlink, 2)
                archive.database.close(); archive.translated.close()

    def test_capture_verifies_owned_identity_constants_and_jobs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'b-123456789abc'; directory.mkdir()
            control = bytearray(0x100); struct.pack_into('<H', control, 0x56, 1); struct.pack_into('<I', control, 0x3c, 4)
            code, c1 = b'owned-fixture', b'abcd'
            for name, data in [('control', control), ('code', code), ('c1', c1)]:
                (root / name).write_bytes(data)
            key = hashlib.sha256(control + code + c1).hexdigest()[:16]
            job = dict(key=key, control=str(root/'control'), code=str(root/'code'), c1=str(root/'c1'))
            jobs = root / 'jobs.json'; jobs.write_text(json.dumps([job]))
            provenance = dict(jobs_sha256=ex.sha(jobs), binding_sources_sha256={})
            (directory/'provenance.json').write_text(json.dumps(provenance))
            reflection = dict(key=key, stage='pixel', route='B', chain='123456789abc', compiler=provenance, c1=c1.hex())
            (directory/(key+'_b.json')).write_text(json.dumps(reflection))
            (directory/(key+'_b.metal')).write_text('source')
            (directory/(key+'_b.metallib')).write_bytes(b'MTLBfixture')
            known, records, _ = ex.read_capture(directory, jobs, {}, {})
            self.assertEqual(known[key][1], 1)
            self.assertIn(key+'_b', records)
            (root/'c1').write_bytes(b'abce')
            with self.assertRaisesRegex(ValueError, 'capture identity'):
                ex.read_capture(directory, jobs, {}, {})
            (root/'c1').write_bytes(c1)
            jobs.write_text(json.dumps([dict(job, ignored=True)]))
            with self.assertRaisesRegex(ValueError, 'job manifest'):
                ex.read_capture(directory, jobs, {}, {})

    def test_failed_export_restores_profile_and_removes_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            translated, metal, _ = self.fixture(root)
            database = sqlite3.connect(metal)
            database.execute('UPDATE libraries SET metal_size=1')
            database.commit(); database.close()
            profile = root / 'profile'; profile.mkdir()
            originals = {'game.tsv': b'name\tTest\nshader_nx2_chain\toriginal\n',
                         'shader_map.tsv': (MAP + f'ROMFS\t0\tvertex\t{K}\t{H}\n').encode(),
                         'dmsh_chain.h': b'original header', 'c1_full.tsv': b'original constants'}
            for name, contents in originals.items():
                (profile / name).write_bytes(contents)
            def header(*args):
                (profile / 'dmsh_chain.h').write_bytes(b'new header')
                return '123456789abc'
            with patch.object(sys, 'argv', ['export', str(translated), str(metal), str(root/'out')]), \
                    patch.object(ex.game, 'load', return_value=types.SimpleNamespace(table=lambda n: profile/n)), \
                    patch.object(ex, 'current_toolchain', return_value={}), patch.object(ex.builder, 'run', side_effect=header):
                with self.assertRaisesRegex(ValueError, 'invalid Metal library'):
                    ex.main()
            for name, contents in originals.items():
                self.assertEqual((profile/name).read_bytes(), contents)
            self.assertEqual(list((root/'out').glob('.nx2-export-*')), [])
            self.assertFalse((root/'out/b-123456789abc').exists())


if __name__ == '__main__':
    unittest.main()
