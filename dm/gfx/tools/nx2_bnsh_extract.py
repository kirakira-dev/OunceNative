#!/usr/bin/env python3
"""Extract exact NX2 programs from BNSH containers in an owned resource tree.

The output has the native capture format. Resource facts are deliberately absent:
programs that need descriptor or root-constant facts still require observation.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct


def unpack(data, fmt, at):
    if at < 0 or at + struct.calcsize(fmt) > len(data):
        raise ValueError('field outside container')
    return struct.unpack_from(fmt, data, at)


def section(data, at, size):
    if at < 0 or size < 0 or at + size > len(data):
        raise ValueError('section outside container')
    return data[at:at + size]


def bnsh_programs(data):
    if data[:8] != b'BNSH\0\0\0\0' or data[0x60:0x64] != b'grsc':
        raise ValueError('invalid BNSH header')
    declared, = unpack(data, '<I', 0x1c)
    if declared != len(data):
        raise ValueError('BNSH size mismatch')
    count, table = unpack(data, '<IQ', 0x7c)
    section(data, table, count * 0x40)
    for variation in range(count):
        program, = unpack(data, '<Q', table + variation * 0x40 + 0x10)
        if not program:
            continue
        for slot, stage in enumerate((0, 3, 4, 2, 1, 5)):
            descriptor, = unpack(data, '<Q', program + 8 + 8 * slot)
            if not descriptor:
                continue
            control_at, code_at, allocated, control_size = unpack(
                data, '<QQII', descriptor + 8)
            control = section(data, control_at, control_size)
            if len(control) < 0xd8 or control[:4] != bytes.fromhex('34127698'):
                raise ValueError('invalid NX2 control header')
            own_size, = unpack(control, '<I', 0x30)
            used, c1_size, c1_offset, own_allocation = unpack(control, '<4I', 0x38)
            own_stage, = unpack(control, '<H', 0x56)
            if (own_size != control_size or own_stage != stage or
                    own_allocation != allocated or used > allocated or
                    c1_offset < used or c1_offset + c1_size > allocated):
                raise ValueError('inconsistent NX2 stage sections')
            area = section(data, code_at, allocated)
            code = area[:used]
            c1 = area[c1_offset:c1_offset + c1_size]
            if used < (0 if stage == 5 else 128) or used % 16:
                raise ValueError('invalid NX2 instruction size')
            if stage != 5:
                word, = unpack(code, '<I', 0)
                if word & 0x3ff not in (0x81, 0x82) or (word >> 10) & 15 != (1, 5, 4, 2, 3)[stage]:
                    raise ValueError('NX2 SPH and stage disagree')
            key = hashlib.sha256(control + code + c1).hexdigest()[:16]
            yield key, control, code, c1, dict(
                variation=variation, slot=slot, stage=stage,
                control_offset=control_at, code_offset=code_at,
                control_size=control_size, code_used=used,
                c1_offset=c1_offset, c1_size=c1_size, allocation=allocated)


def containers(data, source, depth=0):
    if depth > 12:
        raise ValueError('container nesting exceeds limit')
    if data[:4] == bytes.fromhex('28b52ffd'):
        import zstandard
        data = zstandard.ZstdDecompressor().decompress(data, max_output_size=1 << 30)
    if data[:4] == b'SARC':
        bom = data[6:8]
        endian = '<' if bom == b'\xff\xfe' else '>' if bom == b'\xfe\xff' else None
        if endian is None:
            raise ValueError('invalid SARC byte order')
        header, = unpack(data, endian + 'H', 4)
        size, start = unpack(data, endian + 'II', 8)
        if size != len(data) or data[header:header + 4] != b'SFAT':
            raise ValueError('invalid SARC header')
        sfat_size, count = unpack(data, endian + 'HH', header + 4)
        table = header + sfat_size
        section(data, table, count * 16)
        sfnt = table + count * 16
        if data[sfnt:sfnt + 4] != b'SFNT':
            raise ValueError('missing SARC name table')
        names = sfnt + unpack(data, endian + 'H', sfnt + 4)[0]
        for index in range(count):
            _, attr, begin, end = unpack(data, endian + '4I', table + index * 16)
            name = str(index)
            if attr >> 24:
                at = names + (attr & 0xffffff) * 4
                stop = data.find(b'\0', at, start)
                if at < names or stop < 0:
                    raise ValueError('invalid SARC member name')
                name = data[at:stop].decode('utf-8')
            yield from containers(section(data, start + begin, end - begin),
                                  source + '/' + name, depth + 1)
        return
    at = 0
    while (at := data.find(b'BNSH\0\0\0\0', at)) >= 0:
        size, = unpack(data, '<I', at + 0x1c)
        blob = section(data, at, size)
        yield source, at, blob
        at += max(size, 8)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('input', type=Path, nargs='+')
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    capture = args.output / 'capture'
    capture.mkdir(exist_ok=True)
    rows, errors, counts = {}, [], Counter()
    paths = []
    for root in args.input:
        if root.is_dir():
            paths.extend((p, str(p.relative_to(root))) for p in sorted(root.rglob('*')) if p.is_file())
        else:
            paths.append((root, root.name))
    for index, (path, label) in enumerate(paths):
        counts['files'] += 1
        try:
            data = path.read_bytes()
            for source, offset, blob in containers(data, label):
                counts['bnsh'] += 1
                for key, control, code, c1, info in bnsh_programs(blob):
                    counts['occurrences'] += 1
                    location = dict(source=source, bnsh_offset=offset, **info)
                    if key in rows:
                        rows[key]['occurrences'] += 1
                        continue
                    for suffix, content in (('.ctl', control), ('.code', code), ('.c1', c1)):
                        target = capture / (key + suffix)
                        if target.exists() and target.read_bytes() != content:
                            raise ValueError('existing capture differs: ' + key)
                        if content:
                            target.write_bytes(content)
                    rows[key] = dict(first=location, occurrences=1,
                                     sha256=hashlib.sha256(control + code + c1).hexdigest())
                    counts['stage_' + str(info['stage'])] += 1
        except Exception as error:
            errors.append(dict(source=str(path), error=str(error)))
        if (index + 1) % 1000 == 0:
            print(index + 1, 'files;', len(rows), 'programs;', len(errors), 'errors', flush=True)
    report = dict(counts=counts, programs=rows, errors=errors,
                  scope='BNSH containers, with zstd and recursive SARC; other formats are not decoded')
    (args.output / 'index.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(dict(counts=counts, programs=len(rows), errors=len(errors))))
    if errors:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
