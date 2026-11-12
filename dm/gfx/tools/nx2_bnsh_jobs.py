#!/usr/bin/env python3
"""Select extracted NX2 programs that compile without external resource facts.

The compiler must reject missing facts; this tool never supplies placeholder
texture types, formats, descriptor handles, or runtime constant values. Sampled
numeric formats can optionally be deferred to the native runtime's descriptors.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import subprocess


def make_job(root, key, record):
    capture = root / 'capture'
    control_path, code_path = capture / (key + '.ctl'), capture / (key + '.code')
    control, code = control_path.read_bytes(), code_path.read_bytes()
    c1_size, = struct.unpack_from('<I', control, 0x3c)
    c1_path = capture / (key + '.c1')
    c1 = c1_path.read_bytes() if c1_size else b''
    digest = hashlib.sha256(control + code + c1).hexdigest()
    if len(c1) != c1_size or digest != record['sha256'] or digest[:16] != key:
        raise ValueError('archive capture integrity mismatch: ' + key)
    stage, = struct.unpack_from('<H', control, 0x56)
    if stage != record['first']['stage']:
        raise ValueError('archive stage mismatch: ' + key)
    if stage not in (0, 1, 5):
        return None
    job = dict(key=key, control=str(control_path), code=str(code_path),
               cbuf={}, textures={}, root_constants={}, native_root_tables=True,
               facts_source=str(root / 'index.json') + '#no-external-resource-facts')
    if c1_size:
        job['c1'] = str(c1_path)
    if stage == 5:
        local, crs, unmapped = struct.unpack_from('<3I', control, 0x68)
        if unmapped or local + crs >= 1 << 20:
            raise ValueError('unverified compute local memory: ' + key)
        job.update(local=list(struct.unpack_from('<3I', control, 0x58)),
                   shared=struct.unpack_from('<I', control, 0x64)[0],
                   local_memory=local + crs)
    return job


def select_ready(jobs, report):
    expected = {job['key'] for job in jobs}
    if len(expected) != len(jobs) or len(report) != len(expected):
        raise ValueError('incomplete or duplicate compiler report')
    results = {row['key']: row for row in report}
    if set(results) != expected or any(row.get('status') not in ('ok', 'error') for row in report):
        raise ValueError('compiler report does not match requested jobs')
    return [job for job in jobs if results[job['key']]['status'] == 'ok']


def select_jobs(root, programs, exclude):
    jobs, unsupported, excluded = [], [], 0
    for key, record in sorted(programs.items()):
        if key in exclude:
            excluded += 1
            continue
        job = make_job(root, key, record)
        if job is None:
            unsupported.append(dict(key=key, stage=record['first']['stage'],
                                    source=record['first'].get('source')))
        else:
            jobs.append(job)
    return jobs, unsupported, excluded


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('extracted', type=Path, help='nx2_bnsh_extract.py output directory')
    ap.add_argument('compiler', type=Path, help='strict nx2-offline compiler')
    ap.add_argument('output', type=Path, help='new output directory')
    ap.add_argument('--exclude-map', type=Path, help='skip keys already in a shader_map.tsv')
    ap.add_argument('--runtime-texture-formats', action='store_true',
                    help='defer sampled numeric formats to the native Metal binding transform')
    args = ap.parse_args()
    root = args.extracted.resolve()
    index = json.loads((root / 'index.json').read_text())
    if index['errors']:
        raise ValueError('archive extraction reported errors; review them first')
    exclude = set()
    if args.exclude_map:
        for line in args.exclude_map.read_text().splitlines():
            fields = line.split('\t')
            if len(fields) >= 4 and len(fields[3]) == 16:
                exclude.add(fields[3])
    jobs, unsupported, excluded = select_jobs(root, index['programs'], exclude)
    if args.runtime_texture_formats:
        for job in jobs:
            job['defer_sampled_texture_formats'] = True
    args.output.mkdir(parents=True, exist_ok=False)
    source = args.output / 'all-jobs.json'
    source.write_text(json.dumps(jobs, indent=2))
    (args.output / 'unsupported-stages.json').write_text(json.dumps(unsupported, indent=2))
    with (args.output / 'compiler.log').open('w') as log:
        result = subprocess.run([str(args.compiler.resolve()), str(source), str(args.output / 'spirv')],
                                stdout=log, stderr=subprocess.STDOUT)
    if result.returncode not in (0, 1):
        raise RuntimeError('compiler terminated unexpectedly; see compiler.log')
    report = [json.loads(line) for line in
              (args.output / 'spirv/compile-report.jsonl').read_text().splitlines()]
    ready = select_ready(jobs, report)
    (args.output / 'ready-jobs.json').write_text(json.dumps(ready, indent=2))
    summary = dict(archive_programs=len(index['programs']), excluded=excluded,
                   unsupported_stages=Counter(row['stage'] for row in unsupported),
                   requested=len(jobs), ready=len(ready),
                   rejected=Counter(row['error'] for row in report if row['status'] == 'error'),
                   compiler_sha256=hashlib.sha256(args.compiler.read_bytes()).hexdigest(),
                   index_sha256=hashlib.sha256((root / 'index.json').read_bytes()).hexdigest())
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
