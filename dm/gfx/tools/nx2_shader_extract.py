#!/usr/bin/env python3
"""Extract and deduplicate NX2 GLSLC objects from Koei Tecmo RDB archives."""
import argparse
from collections import Counter
import hashlib
import json
import mmap
from pathlib import Path
import sqlite3
import struct
import zlib

IDRK = b'IDRK0000'
GLSLC = bytes.fromhex('91688619')
CONTROL = bytes.fromhex('34127698')
SHADER_TYPES = {0x7bcd279f, 0x20a6a0bb}


def entries(data):
    offset = 0
    while (offset := data.find(IDRK, offset)) >= 0:
        if offset + 0x38 > len(data):
            raise ValueError(f'truncated IDRK header at {offset:#x}')
        length, stored, expanded = struct.unpack_from('<QQQ', data, offset + 8)
        ktid, kind, flags = struct.unpack_from('<III', data, offset + 0x24)
        if length < 0x38 or stored > length - 0x38 or offset + length > len(data):
            raise ValueError(f'invalid IDRK bounds at {offset:#x}')
        yield offset, offset + length - stored, stored, expanded, ktid, kind, flags
        offset += length


def decompress(data, expanded, flags):
    if flags == 0:
        output = data
    elif flags in (0x100000, 0x400000):
        output = bytearray()
        offset = 0
        while offset < len(data):
            prefix = 2 if flags == 0x400000 else 4
            if len(data) - offset < prefix:
                raise ValueError('truncated compressed chunk size')
            size = int.from_bytes(data[offset:offset+prefix], 'little')
            offset += prefix
            if size == 0:
                if offset != len(data):
                    raise ValueError('data after compression terminator')
                break
            # NX2 adds an opaque eight-byte chunk tag after the u16 size.
            # zlib validates the compressed stream's Adler-32 independently.
            if flags == 0x400000:
                offset += 8
            if offset + size > len(data):
                raise ValueError('compressed chunk outside entry')
            inflater = zlib.decompressobj()
            chunk = inflater.decompress(data[offset:offset+size], expanded - len(output) + 1)
            if not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
                raise ValueError('incomplete or oversized zlib chunk')
            output.extend(chunk)
            offset += size
            if len(output) > expanded:
                raise ValueError('expanded data exceeds declared size')
        output = bytes(output)
    else:
        raise ValueError(f'unsupported RDB compression flags {flags:#x}')
    if len(output) != expanded:
        raise ValueError(f'expanded size {len(output)} != declared {expanded}')
    return output


def objects(data):
    offset = 0
    while (offset := data.find(GLSLC, offset)) >= 0:
        if offset + 0x68 > len(data):
            raise ValueError('truncated GLSLC header')
        version, = struct.unpack_from('<I', data, offset + 8)
        size, control_offset = struct.unpack_from('<II', data, offset + 0x5c)
        if version not in (0x220015, 0x220615) or size < control_offset + 0xd8 or offset + size > len(data):
            raise ValueError(f'unsupported GLSLC layout at {offset:#x}, version {version:#x}')
        control = offset + control_offset
        if data[control:control+4] != CONTROL:
            raise ValueError('missing GLSLC control section')
        control_size, = struct.unpack_from('<I', data, control + 0x30)
        used, = struct.unpack_from('<I', data, control + 0x38)
        allocated, = struct.unpack_from('<I', data, control + 0x44)
        code = control + control_size
        if control_size < 0xd8 or used > allocated or code + allocated > offset + size:
            raise ValueError('shader code outside GLSLC object')
        # The stage is the high halfword at control+0x54. Control kind 0x11
        # is also used by vertex/pixel shaders and does not mean compute.
        stage_id, = struct.unpack_from('<H', data, control + 0x56)
        stage = {0: 'vs', 1: 'ps', 2: 'gs', 3: 'hs', 4: 'ds', 5: 'cs'}.get(stage_id)
        if stage is None:
            raise ValueError(f'unknown NX2 shader stage {stage_id}')
        if stage != 'cs':
            first, = struct.unpack_from('<I', data, code)
            sph_stage = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}.get((first >> 10) & 15)
            if first & 0x3ff not in (0x81, 0x82) or sph_stage != stage:
                raise ValueError('control and SPH shader stages disagree')
        blob = data[offset:offset+size]
        yield offset, blob, stage, control_offset, control_size, used, allocated
        offset += size


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('romfs', type=Path)
    ap.add_argument('database', type=Path)
    args = ap.parse_args()
    if args.database.exists():
        ap.error('output database already exists; choose a fresh path')
    args.database.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(args.database)
    db.executescript('''
      CREATE TABLE shaders (
        sha256 TEXT PRIMARY KEY, stage TEXT NOT NULL, control_offset INTEGER NOT NULL,
        control_size INTEGER NOT NULL, code_used INTEGER NOT NULL,
        code_allocated INTEGER NOT NULL, glslc_zlib BLOB NOT NULL);
      CREATE TABLE occurrences (
        file TEXT, entry_offset INTEGER, ktid INTEGER, object_offset INTEGER,
        sha256 TEXT REFERENCES shaders(sha256));
      CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT);
    ''')
    counts = Counter()
    for path in sorted(args.romfs.rglob('*')):
        if path.suffix not in ('.fdata', '.file') or not path.is_file():
            continue
        relative = str(path.relative_to(args.romfs))
        with path.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            for offset, start, stored, expanded, ktid, kind, flags in entries(data):
                counts['entries'] += 1
                if kind not in SHADER_TYPES:
                    continue
                raw = decompress(data[start:start+stored], expanded, flags)
                counts['shader_or_system_entries'] += 1
                counts['decoded_bytes'] += len(raw)
                for at, blob, stage, control, size, used, allocated in objects(raw):
                    key = hashlib.sha256(blob).hexdigest()
                    if not db.execute('SELECT 1 FROM shaders WHERE sha256=?', (key,)).fetchone():
                        db.execute('INSERT INTO shaders VALUES (?,?,?,?,?,?,?)',
                                   (key, stage, control, size, used, allocated, zlib.compress(blob, 1)))
                        counts['unique_shaders'] += 1
                        counts['stage_' + stage] += 1
                    db.execute('INSERT INTO occurrences VALUES (?,?,?,?,?)', (relative, offset, ktid, at, key))
                    counts['shader_occurrences'] += 1
        db.commit()
        print(relative, json.dumps(counts, sort_keys=True), flush=True)
    db.execute('INSERT INTO metadata VALUES (?,?)', ('summary', json.dumps(counts, sort_keys=True)))
    db.execute('INSERT INTO metadata VALUES (?,?)', ('scope', 'IDRK shader and system types only; runtime-generated and other archive types are not covered'))
    db.commit()
    db.close()


if __name__ == '__main__':
    main()
