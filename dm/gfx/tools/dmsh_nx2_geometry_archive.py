#!/usr/bin/env python3
"""Compile owned GLSLC geometry programs with audited topology and mesh interfaces."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import zlib

import dmsh_nx2_build as builder
import dmsh_nx2_export as exporter
import dmsh_nx2_geometry as geometry
import nx2_glslc


def mesh_toolchain():
    return dict(geometry_helper_sha256=exporter.sha(geometry.__file__),
                geometry_producer_sha256=exporter.sha(__file__),
                glslang_sha256=exporter.sha(shutil.which('glslangValidator')),
                geometry_spirv_val_sha256=exporter.sha(shutil.which('spirv-val')),
                geometry_spirv_target='vulkan1.2',
                geometry_msl_options=geometry.MSL_OPTIONS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('shaders', type=Path)
    parser.add_argument('canonical', type=Path)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('compiler_source_tree', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    canonical = exporter.read_only(args.canonical)
    identities = {key: source_sha for key, source_sha in canonical.execute('SELECT key,sha256 FROM programs WHERE stage=2')}
    source = exporter.read_only(args.shaders)
    jobs, owned = [], {}
    for source_sha, compressed in source.execute("SELECT sha256,glslc_zlib FROM shaders WHERE stage='gs'"):
        raw = zlib.decompress(compressed)
        if hashlib.sha256(raw).hexdigest() != source_sha:
            raise ValueError('owned GLSLC archive checksum mismatch')
        shader = nx2_glslc.parse(raw)
        key = shader['key']
        if shader['stage'] != 2 or identities.get(key) != source_sha or key in owned:
            raise ValueError('geometry identity differs from the canonical owned archive')
        owned[key] = (source_sha, shader, compressed)
        jobs.append(nx2_glslc.offline_job(shader))
    if not jobs or set(owned) != set(identities):
        raise ValueError('geometry archive is empty or does not cover the canonical geometry set')
    source.close(); canonical.close()
    args.output.mkdir(parents=True, exist_ok=False)
    snapshots = args.output / 'sources'; snapshots.mkdir()
    sources = {}
    compiler_sources = ['nx2_offline.cpp', 'frontend/ampere/lower_to_maxwell.h',
                        'ir_opt/constant_propagation_pass.cpp', 'backend/spirv/spirv_emit_context.h',
                        'backend/spirv/spirv_emit_context.cpp', 'backend/spirv/emit_spirv_context_get_set.cpp',
                        'backend/spirv/emit_spirv.cpp', 'runtime_info.h']
    for relative in compiler_sources:
        path = args.compiler_source_tree / 'src/shader_recompiler' / relative
        if path.stat().st_mtime_ns > args.compiler.stat().st_mtime_ns:
            raise ValueError(f'compiler source changed after the compiler build: {relative}')
        target = snapshots / relative; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(path, target)
        sources[relative] = exporter.sha(target)
    for path in (Path(__file__), Path(builder.__file__), Path(exporter.__file__), Path(geometry.__file__),
                 Path(nx2_glslc.__file__), Path(builder.__file__).with_name('dmsh_nx2_spirv.py')):
        shutil.copy2(path, snapshots / path.name)
    frozen = snapshots / args.compiler.name; shutil.copy2(args.compiler, frozen)
    job_path = args.output / 'jobs.json'; job_path.write_text(json.dumps(jobs, indent=2))
    translated_dir = args.output / 'spirv'; translated_dir.mkdir()
    builder.run([frozen, job_path, translated_dir])
    translation_provenance = dict(format='nx2-geometry-v1', compiler_sha256=exporter.sha(frozen),
        compiler_sources_sha256=json.dumps(sources, sort_keys=True), jobs_sha256=exporter.sha(job_path),
        canonical_database_sha256=exporter.sha(args.canonical),
        fork_commit=subprocess.check_output(['git', '-C', args.compiler_source_tree, 'rev-parse', 'HEAD'], text=True).strip(),
        spirv_val_target='vulkan1.2', spirv_val_sha256=exporter.sha(shutil.which('spirv-val')))
    translated_path = args.output / 'translated.sqlite'
    translated = sqlite3.connect(translated_path)
    translated.executescript('''
        CREATE TABLE programs(key TEXT PRIMARY KEY,sha256 TEXT,stage INTEGER,status TEXT,error TEXT,spirv_zlib BLOB,reflection_zlib BLOB);
        CREATE TABLE sources(key TEXT PRIMARY KEY,glslc_zlib BLOB);
        CREATE TABLE provenance(key TEXT PRIMARY KEY,value TEXT);
    ''')
    translated.executemany('INSERT INTO provenance VALUES (?,?)', translation_provenance.items())
    for key, (source_sha, shader, compressed) in sorted(owned.items()):
        spv = translated_dir / (key + '.spv')
        builder.run(['spirv-val', '--target-env', 'vulkan1.2', spv])
        metadata = json.loads(spv.with_suffix('.json').read_text())
        mode = struct.unpack_from('<I', shader['control'], 0x58)[0]
        expected = {0: ('points', 1), 4: ('triangles', 3)}.get(mode)
        if expected is None or (metadata['geometry']['input'], metadata['geometry']['input_vertices']) != expected:
            raise ValueError('compiler geometry topology disagrees with the owned SDK declaration')
        translated.execute('INSERT INTO programs VALUES (?,?,?,?,?,?,?)',
            (key, source_sha, 2, 'ok', None, zlib.compress(spv.read_bytes(),3),
             zlib.compress(json.dumps(metadata).encode(),3)))
        translated.execute('INSERT INTO sources VALUES (?,?)', (key, compressed))
    translated.commit(); translated.close()
    current = exporter.current_toolchain()
    provenance = dict(current, **mesh_toolchain(), input_database_sha256=exporter.sha(translated_path),
                      input_translation_provenance=translation_provenance)
    output = sqlite3.connect(args.output / 'metal.sqlite')
    output.executescript('''
        CREATE TABLE programs(key TEXT PRIMARY KEY,sha256 TEXT,stage INTEGER,status TEXT,error TEXT,library_hash TEXT,reflection_zlib BLOB);
        CREATE TABLE libraries(hash TEXT PRIMARY KEY,metal_zlib BLOB,metal_size INTEGER,source_zlib BLOB);
        CREATE TABLE provenance(key TEXT PRIMARY KEY,value TEXT);
    ''')
    output.executemany('INSERT INTO provenance VALUES (?,?)', [(k,json.dumps(v)) for k,v in provenance.items()])
    for key, (source_sha, shader, _) in sorted(owned.items()):
        spv = translated_dir / (key + '.spv'); directory = args.output / 'mesh' / key
        metal, reflection = geometry.prepare(spv, json.loads(spv.with_suffix('.json').read_text()), directory)
        reflection.update(key=key, stage='geometry', archive_shader_sha256=source_sha,
                          c1=shader['c1'].hex(), facts_source='GLSLC reflection')
        exporter.variant_suffix(2, reflection, 'geometry')
        path = directory / 'shader.metal'; path.write_text(metal)
        builder.run(['xcrun','-sdk','macosx','metal',*current['metal_options'],path,'-o',path.with_suffix('.air')])
        builder.run(['xcrun','-sdk','macosx','metallib',path.with_suffix('.air'),'-o',path.with_suffix('.metallib')])
        binary = path.with_suffix('.metallib').read_bytes()
        if not binary.startswith(b'MTLB'):
            raise ValueError('invalid geometry Metal library')
        library_hash = hashlib.sha256(metal.encode()).hexdigest()
        output.execute('INSERT OR IGNORE INTO libraries VALUES (?,?,?,?)',
                       (library_hash,zlib.compress(binary,3),len(binary),zlib.compress(metal.encode(),3)))
        output.execute('INSERT INTO programs VALUES (?,?,?,?,?,?,?)',
                       (key,source_sha,2,'ok',None,library_hash,zlib.compress(json.dumps(reflection).encode(),3)))
        output.commit(); print(key,'ok',flush=True)
    if output.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
        raise ValueError('geometry archive integrity check failed')
    output.close()
    print(f'{len(owned)} geometry programs compiled; unresolved output defaults remain explicit in reflection')


if __name__ == '__main__':
    main()
