#!/usr/bin/env python3
"""NX2 archive extraction: exact native keys and malformed container rejection."""
import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from nx2_bnsh_extract import bnsh_programs, containers
from nx2_bnsh_jobs import select_jobs, select_ready


def fixture(stage=0):
    data = bytearray(0x510)
    data[:8] = b'BNSH\0\0\0\0'
    struct.pack_into('<I', data, 0x1c, len(data))
    data[0x60:0x64] = b'grsc'
    struct.pack_into('<IQ', data, 0x7c, 1, 0xc0)
    struct.pack_into('<Q', data, 0xd0, 0x100)
    slot = (0, 4, 3, 1, 2, 5)[stage]
    struct.pack_into('<Q', data, 0x108 + slot * 8, 0x200)
    struct.pack_into('<QQII', data, 0x208, 0x240, 0x400, 0x110, 0xe0)
    struct.pack_into('<I', data, 0x240, 0x98761234)
    struct.pack_into('<I', data, 0x270, 0xe0)
    struct.pack_into('<4I', data, 0x278, 0x80, 0x10, 0x100, 0x110)
    struct.pack_into('<H', data, 0x296, stage)
    if stage != 5:
        struct.pack_into('<I', data, 0x400, 0x81 | ((1, 5, 4, 2, 3)[stage] << 10))
    data[0x500:] = bytes(range(16))
    return data


def sarc(member):
    data = bytearray(0x60)
    data[:4] = b'SARC'
    struct.pack_into('<HHII', data, 4, 0x14, 0xfeff, len(data) + len(member), 0x60)
    data[0x14:0x18] = b'SFAT'
    struct.pack_into('<HH', data, 0x18, 0xc, 1)
    struct.pack_into('<4I', data, 0x20, 0, 0x1000000, 0, len(member))
    data[0x30:0x34] = b'SFNT'
    struct.pack_into('<H', data, 0x34, 8)
    data[0x38:0x3f] = b'shader\0'
    return data + member


class Extraction(unittest.TestCase):
    def test_native_hash_omits_code_padding(self):
        data = fixture()
        key, control, code, c1, info = next(bnsh_programs(data))
        self.assertEqual(key, hashlib.sha256(data[0x240:0x320] + data[0x400:0x480] + data[0x500:]).hexdigest()[:16])
        self.assertEqual((len(control), len(code), len(c1)), (224, 128, 16))
        self.assertEqual(info['c1_offset'], 256)
        data[0x480:0x500] = b'\xff' * 128
        self.assertEqual(next(bnsh_programs(data))[0], key)
        data[0x500] ^= 1
        self.assertNotEqual(next(bnsh_programs(data))[0], key)

    def test_stage_mapping(self):
        for stage in range(6):
            with self.subTest(stage=stage):
                self.assertEqual(next(bnsh_programs(fixture(stage)))[4]['stage'], stage)

    def test_invalid_sections(self):
        changes = [(0x80, '<Q', 0x500), (0xd0, '<Q', 0x510),
                   (0x208, '<Q', 0x500), (0x210, '<Q', 0x500),
                   (0x218, '<I', 0x100), (0x270, '<I', 0xd8),
                   (0x278, '<I', 0x120), (0x280, '<I', 0x108),
                   (0x296, '<H', 1), (0x400, '<I', 0)]
        for offset, fmt, value in changes:
            with self.subTest(offset=offset):
                data = fixture()
                struct.pack_into(fmt, data, offset, value)
                with self.assertRaises(ValueError):
                    list(bnsh_programs(data))

    def test_nested_zstd_sarc_and_embedded_offset(self):
        import zstandard
        archive = sarc(zstandard.ZstdCompressor().compress(b'prefix__' + fixture()))
        rows = list(containers(zstandard.ZstdCompressor().compress(archive), 'root'))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:2], ('root/shader', 8))
        self.assertEqual(rows[0][2], fixture())

    def test_invalid_sarc_member_bounds(self):
        data = sarc(fixture())
        struct.pack_into('<I', data, 0x2c, len(data))
        with self.assertRaises(ValueError):
            list(containers(data, 'bad'))

    def test_truncated_bnsh_in_container(self):
        with self.assertRaises(ValueError):
            list(containers(fixture()[:-1], 'bad'))

    def test_missing_facts_are_not_selected(self):
        jobs = [{'key': 'a'}, {'key': 'b'}]
        report = [{'key': 'a', 'status': 'ok'},
                  {'key': 'b', 'status': 'error', 'error': 'texture fact required'}]
        self.assertEqual(select_ready(jobs, report), [jobs[0]])
        for invalid in (report[:1], report + report[:1],
                        [report[0], report[0]],
                        [report[0], {'key': 'b', 'status': 'unknown'}]):
            with self.assertRaises(ValueError):
                select_ready(jobs, invalid)

    def test_archive_stage_accounting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'capture').mkdir()
            programs, keys = {}, {}
            for stage in range(6):
                key, control, code, c1, info = next(bnsh_programs(fixture(stage)))
                keys[stage] = key
                for suffix, data in (('ctl', control), ('code', code), ('c1', c1)):
                    (root / 'capture' / (key + '.' + suffix)).write_bytes(data)
                programs[key] = dict(first=info, sha256=hashlib.sha256(control + code + c1).hexdigest())
            jobs, unsupported, excluded = select_jobs(root, programs, {keys[0], 'not-in-archive'})
            self.assertEqual({job['key'] for job in jobs}, {keys[1], keys[5]})
            self.assertEqual({row['key']: row['stage'] for row in unsupported},
                             {keys[stage]: stage for stage in (2, 3, 4)})
            self.assertEqual(excluded, 1)
            self.assertEqual(len(jobs) + len(unsupported) + excluded, len(programs))


if __name__ == '__main__':
    unittest.main()
