#!/usr/bin/env python3
"""Build vertex-capture variants without replacing ordinary vertex shaders."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import tempfile
import zlib

import dmsh_nx2_build as builder
import dmsh_nx2_export as exporter
import dmsh_nx2_tess as tess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('jobs', type=Path)
    parser.add_argument('canonical', type=Path)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('wrapper', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--workers', type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.workers <= 16:
        raise ValueError('workers must be between 1 and 16')
    current = exporter.current_toolchain()
    bindings = {name: exporter.sha(Path(builder.__file__).parent.parent / 'nvn' / name)
                for name in ('nvn_refl.h', 'nvn_refl.m', 'nvn_mtl.m')}
    captured, records, capture = exporter.read_capture(args.package, args.jobs, current, bindings)
    if exporter.sha(args.compiler) != capture['provenance']['compiler_sha256']:
        raise ValueError('compiler differs from the ordinary capture package')
    canonical = exporter.read_only(args.canonical)
    known = {key for key, in canonical.execute('SELECT key FROM programs')}
    canonical.close()
    jobs = [job for job in json.loads(args.jobs.read_text())
            if job['key'] not in known and captured[job['key']][1] == 0]
    if not jobs:
        raise ValueError('no additional captured vertex shaders need variants')
    args.output.mkdir(parents=True, exist_ok=False)
    translated_path = args.output / 'translated.sqlite'
    metal_path = args.output / 'metal.sqlite'
    snapshot = args.output / 'sources'
    snapshot.mkdir()
    for path in (Path(__file__), Path(builder.__file__), Path(tess.__file__),
                 Path(exporter.__file__), Path(builder.__file__).with_name('dmsh_nx2_spirv.py'),
                 Path(builder.__file__).with_name('nx2_glslc.py'),
                 Path(builder.__file__).with_name('dmsh_nx2_msl.cpp'), args.wrapper):
        shutil.copy2(path, snapshot / path.name)
    wrapper = snapshot / args.wrapper.name
    selected_path = args.output / 'jobs.json'
    selected_path.write_text(json.dumps(jobs, indent=2))
    compiler_output = args.output / 'spirv'
    compiler_output.mkdir()
    builder.run([args.compiler, selected_path, compiler_output])
    translation_provenance = dict(format='nx2-native-capture-vertex-v1',
        compiler_sha256=exporter.sha(args.compiler), jobs_sha256=exporter.sha(selected_path),
        capture_package=exporter.digest(capture), capture_jobs_sha256=exporter.sha(args.jobs),
        canonical_database_sha256=exporter.sha(args.canonical),
        runner_sha256=exporter.sha(__file__), spirv_val_target='vulkan1.2',
        spirv_val_sha256=exporter.sha(shutil.which('spirv-val')))
    translated = sqlite3.connect(translated_path)
    translated.executescript('''
        CREATE TABLE programs(key TEXT PRIMARY KEY,sha256 TEXT,stage INTEGER,status TEXT,error TEXT,
                              spirv_zlib BLOB,reflection_zlib BLOB);
        CREATE TABLE provenance(key TEXT PRIMARY KEY,value TEXT);
    ''')
    translated.executemany('INSERT INTO provenance VALUES (?,?)', translation_provenance.items())
    for job in jobs:
        key = job['key']
        spv = compiler_output / (key + '.spv')
        builder.run(['spirv-val', '--target-env', 'vulkan1.2', spv])
        metadata = (compiler_output / (key + '.json')).read_bytes()
        translated.execute('INSERT INTO programs VALUES (?,?,?,?,?,?,?)',
            (key, captured[key][0], 0, 'ok', None, zlib.compress(spv.read_bytes(), 3), zlib.compress(metadata, 3)))
    translated.commit()
    translated.close()
    provenance = dict(current, runner_sha256=exporter.sha(__file__),
        exporter_sha256=exporter.sha(exporter.__file__),
        input_database_sha256=exporter.sha(translated_path),
        input_translation_provenance=translation_provenance,
        tess_helper_sha256=exporter.sha(tess.__file__),
        wrapper_sha256=exporter.sha(wrapper),
        wrapper_source_sha256=exporter.sha(Path(builder.__file__).with_name('dmsh_nx2_msl.cpp')),
        spirv_cross_static_libraries={str(p): exporter.sha(p) for p in sorted(Path('/opt/homebrew/lib').glob('libspirv-cross-*.a'))},
        vertex_indices=dict(type='uint32', base_vertex_preadded=True, draw_parameters_buffer=23,
                            vertex_buffers=list(range(1, 17))),
        capture_provenance=capture)
    output = sqlite3.connect(metal_path)
    output.executescript('''
        CREATE TABLE programs(key TEXT PRIMARY KEY,sha256 TEXT,stage INTEGER,status TEXT,error TEXT,
                              library_hash TEXT,reflection_zlib BLOB);
        CREATE TABLE libraries(hash TEXT PRIMARY KEY,metal_zlib BLOB,metal_size INTEGER,source_zlib BLOB);
        CREATE TABLE provenance(key TEXT PRIMARY KEY,value TEXT);
    ''')
    output.executemany('INSERT INTO provenance VALUES (?,?)',
                       [(key, json.dumps(value)) for key, value in provenance.items()])
    output.commit()

    def compile_job(job):
        key = job['key']
        try:
            metadata = json.loads((compiler_output / (key + '.json')).read_text())
            source, reflection = tess.prepare(compiler_output / (key + '.spv'), wrapper, 0, metadata)
            source = builder.precise_helpers(source)
            # The ordinary capture package already verified these exact owned constants.
            reflection['c1'] = records[key + '_b']['reflection'].get('c1', '')
            reflection.update(key=key, stage='vertex', facts_source=job.get('facts_source'),
                              archive_shader_sha256=captured[key][0])
            exporter.variant_suffix(0, reflection, 'vertex')
            source_hash = hashlib.sha256(source.encode()).hexdigest()
            with tempfile.TemporaryDirectory(prefix=key + '-', dir=args.output) as temporary:
                path = Path(temporary) / 'shader.metal'
                path.write_text(source)
                builder.run(['xcrun', '-sdk', 'macosx', 'metal', *current['metal_options'], path, '-o', path.with_suffix('.air')])
                builder.run(['xcrun', '-sdk', 'macosx', 'metallib', path.with_suffix('.air'), '-o', path.with_suffix('.metallib')])
                binary = path.with_suffix('.metallib').read_bytes()
                if not binary.startswith(b'MTLB'):
                    raise ValueError('invalid Metal library')
            row = (key, captured[key][0], 0, 'ok', None, source_hash,
                   zlib.compress(json.dumps(reflection, separators=(',', ':')).encode(), 3))
            library = (source_hash, zlib.compress(binary, 3), len(binary), zlib.compress(source.encode(), 3))
            return row, library
        except Exception as error:
            return (key, captured[key][0], 0, 'error', str(error), None, None), None

    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for row, library in pool.map(compile_job, jobs):
            if library:
                output.execute('INSERT OR IGNORE INTO libraries VALUES (?,?,?,?)', library)
            output.execute('INSERT INTO programs VALUES (?,?,?,?,?,?,?)', row)
            output.commit()
            print(row[0], row[3], flush=True)
            if row[3] != 'ok':
                failures.append((row[0], row[4]))
    libraries = output.execute('SELECT count(*) FROM libraries').fetchone()[0]
    assert output.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
    output.close()
    print(json.dumps(dict(translated=str(translated_path), metal=str(metal_path),
                          successful=len(jobs)-len(failures), libraries=libraries, failures=failures)), flush=True)
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
