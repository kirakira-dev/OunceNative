#!/usr/bin/env python3
"""Combine NX2 archives into a package, preserving captured shader overrides."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / 'games'))
import game
import dmsh_nx2_build as builder
from dmsh_nx2_spirv import toolchain_provenance as bank_provenance

STAGES = builder.STAGES
HEX_KEY = re.compile(r'[0-9a-f]{16}')
HEX_SHA = re.compile(r'[0-9a-f]{64}')
METAL_OPTIONS = ['-std=metal3.2', '-c', '-fpreserve-invariance', '-fno-fast-math']


def sha(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def atomic_write(path, data):
    temporary = path.with_name(path.name + f'.tmp-{os.getpid()}')
    temporary.write_bytes(data)
    temporary.replace(path)


def read_only(path):
    connection = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
    connection.execute('BEGIN')
    return connection


def current_toolchain():
    return dict(builder_sha256=sha(HERE / 'dmsh_nx2_build.py'),
                parser_sha256=sha(HERE / 'nx2_glslc.py'),
                spirv_cross_sha256=sha(shutil.which('spirv-cross')),
                spirv_cross_options=builder.XC,
                metal_version=builder.run(['xcrun', '-sdk', 'macosx', 'metal', '--version']),
                metal_options=METAL_OPTIONS, constant_bank_toolchain=bank_provenance())


def check_toolchain(provenance, current, capture=False):
    for key, value in current.items():
        if capture and key == 'parser_sha256':
            continue  # Native-capture jobs already contain their measured compiler queries.
        if provenance.get(key) != value:
            raise ValueError(f'stale or incompatible shader toolchain: {key}')


def variant_suffix(stage, reflection, kind):
    tess = reflection.get('nx2_tessellation')
    geometry = reflection.get('nx2_geometry')
    if kind == 'ordinary':
        if stage not in (0, 1, 5) or tess or geometry:
            raise ValueError('ordinary archive contains an unsupported stage or tessellation variant')
        return '_b'
    if kind == 'geometry':
        if stage != 2 or tess or not isinstance(geometry, dict) or (
                geometry.get('version'), geometry.get('vertex_stride'), geometry.get('input_buffer'),
                geometry.get('primitive_buffer')) != (1, 608, 20, 21):
            raise ValueError('missing or incompatible geometry mesh layout')
        if (geometry.get('input'), geometry.get('input_vertices')) not in (('points', 1), ('triangles', 3)):
            raise ValueError('unsupported geometry input topology')
        if geometry.get('output') not in ('points', 'triangles'):
            raise ValueError('unsupported geometry output topology')
        return '_gm_b'
    if geometry:
        raise ValueError('geometry mesh cannot replace a tessellation variant')
    if not isinstance(tess, dict) or (tess.get('version'), tess.get('vertex_stride'),
                                     tess.get('patch_stride')) != (1, 608, 512):
        raise ValueError('missing or incompatible tessellation intermediate layout')
    if kind == 'vertex':
        if stage != 0 or tess.get('vertex_index_type') != 'uint32':
            raise ValueError('vertex-capture archive has the wrong stage or index layout')
        return '_tv_b'
    if kind != 'tess' or stage not in (3, 4) or tess.get('control_points') != 3:
        raise ValueError('only paired three-control-point hull/domain variants are supported')
    return '_th_b' if stage == 3 else '_td3_b'


def validate_reflection(reflection, key, stage):
    if reflection.get('key') != key or reflection.get('stage') != STAGES[stage]:
        raise ValueError(f'reflection identity mismatch: {key}')
    if reflection.get('route') != 'B' or reflection.get('drv_unfillable'):
        raise ValueError(f'unsupported shader resource reflection: {key}')


def argument_members(source):
    """Read declared argument IDs, including unused image-query samplers."""
    lines = '\n'.join(line for line in source.splitlines() if '[[id(' in line)
    members = {}
    for match in re.finditer(r'^\s+(.+?)\s+(\w+)\s+\[\[id\((\d+)\)\]\];', lines, re.M):
        kind, name, raw_id = match.groups()
        aid = int(raw_id)
        if aid in members or aid >= 64:
            raise ValueError('duplicate or out-of-range Metal argument ID')
        unused = (kind == 'sampler' and re.fullmatch(r'cs_tex0_[0-9a-f]+Smplr', name) and
                  len(re.findall(r'\b' + re.escape(name) + r'\b', source)) == 1)
        members[aid] = (name, kind, bool(unused))
    return members


def complete_argument_bindings(reflection, members):
    """Account for declared but provably unused TXQ sampler slots.

    The offline compiler's image-size query goes through a sampled texture;
    SPIRV-Cross retains its sampler declaration even though no sample occurs.
    Preserve every original binding and reject any other missing resource.
    """
    result = dict(reflection)
    bindings = [dict(binding) for binding in reflection.get('bindings', [])]
    by_id = {}
    for binding in bindings:
        aid = binding['arg_id']
        member = members.get(aid)
        if aid in by_id or member is None or member[:2] != (binding['msl_name'], binding['msl_type']):
            raise ValueError('reflection differs from declared Metal arguments')
        by_id[aid] = binding
    for aid, (name, kind, unused) in sorted(members.items()):
        if aid in by_id:
            continue
        image = by_id.get(aid - 1, {})
        if (not unused or reflection.get('stage') != 'compute' or image.get('kind') != 'img' or
                image.get('rw') is not False or image.get('msl_name') != name.removesuffix('Smplr')):
            raise ValueError(f'unreflected active or unsupported Metal argument: {name}')
        bindings.append(dict(kind='unused_sampler', arg_id=aid, msl_name=name, msl_type=kind))
    result['bindings'] = sorted(bindings, key=lambda binding: binding['arg_id'])
    return result


def validate_bounded_translation(database, translation, path, kind, input_hashes):
    if 'bounded_constant_banks' not in translation:
        return
    import dmsh_nx2_bank_ranges as ranges
    record = json.loads(translation['bounded_constant_banks'])
    parent_path = str(Path(record['source_archive']).resolve())
    if (kind != 'ordinary' or record.get('format') != 'nx2-bounded-cbuf-v1' or
            parent_path == str(path.resolve()) or parent_path not in input_hashes or
            record.get('source_archive_sha256') != input_hashes[parent_path] or
            record.get('toolchain') != ranges.toolchain_provenance()):
        raise ValueError('invalid bounded-bank translation provenance')
    rows = database.execute('SELECT key,sha256,stage,status,spirv_zlib,reflection_zlib FROM programs').fetchall()
    if {row[0] for row in rows} != set(record.get('programs', {})):
        raise ValueError('bounded-bank proof coverage mismatch')
    parent = read_only(Path(parent_path))
    try:
        with tempfile.TemporaryDirectory(prefix='bounded-bank-review-', dir=path.parent) as folder:
            source, output = Path(folder)/'source.spv', Path(folder)/'output.spv'
            for key, source_sha, stage, status, binary, reflection in rows:
                previous = parent.execute(
                    'SELECT sha256,stage,status,spirv_zlib,reflection_zlib FROM programs WHERE key=?', (key,)).fetchone()
                if (not previous or status != 'ok' or previous[:3] != (source_sha, stage, 'ok') or
                        previous[4] != reflection):
                    raise ValueError(f'bounded-bank source identity mismatch: {key}')
                source.write_bytes(zlib.decompress(previous[3]))
                proof = ranges.prepare(source, output)
                if proof != record['programs'][key] or output.read_bytes() != zlib.decompress(binary):
                    raise ValueError(f'bounded-bank proof replay mismatch: {key}')
    finally:
        parent.close()


class Archive:
    def __init__(self, translated_path, metal_path, kind, current, input_hashes):
        self.kind = kind
        self.translated = read_only(translated_path)
        self.database = read_only(metal_path)
        self.provenance = {key: json.loads(value) for key, value in
                           self.database.execute('SELECT key,value FROM provenance')}
        input_path = str(translated_path.resolve())
        if input_path not in input_hashes:
            input_hashes[input_path] = sha(translated_path)
        if self.provenance.get('input_database_sha256') != input_hashes[input_path]:
            raise ValueError('Metal archive was built from a different translation database')
        translation = dict(self.translated.execute('SELECT key,value FROM provenance'))
        if self.provenance.get('input_translation_provenance') != translation:
            raise ValueError('translation provenance does not match the Metal archive')
        if translation.get('spirv_val_target') != 'vulkan1.2':
            raise ValueError('translation archive has not been validated for Vulkan 1.2')
        check_toolchain(self.provenance, current)
        validate_bounded_translation(self.translated, translation, translated_path, kind, input_hashes)
        if kind in ('vertex', 'tess'):
            for field, name in (('tess_helper_sha256', 'dmsh_nx2_tess.py'),
                                ('wrapper_source_sha256', 'dmsh_nx2_msl.cpp')):
                if self.provenance.get(field) != sha(HERE / name):
                    raise ValueError(f'stale tessellation producer: {field}')
            if not HEX_SHA.fullmatch(self.provenance.get('wrapper_sha256', '')):
                raise ValueError('missing compiled tessellation wrapper provenance')
            libraries = self.provenance.get('spirv_cross_static_libraries', {})
            if not libraries or any(sha(path) != value for path, value in libraries.items()):
                raise ValueError('tessellation SPIRV-Cross libraries have changed')
        if kind == 'geometry':
            from dmsh_nx2_geometry_archive import mesh_toolchain
            for field, value in mesh_toolchain().items():
                if self.provenance.get(field) != value:
                    raise ValueError(f'stale geometry producer: {field}')
        if kind == 'tess' and self.provenance.get('domain_control_points') != 3:
            raise ValueError('unsupported domain control-point variant')
        if kind == 'vertex' and self.provenance.get('vertex_indices') != dict(
                type='uint32', base_vertex_preadded=True, draw_parameters_buffer=23,
                vertex_buffers=list(range(1, 17))):
            raise ValueError('unsupported vertex capture convention')
        self.known = {}
        self.validated = set()
        for key, source_sha, stage, status in self.translated.execute('SELECT key,sha256,stage,status FROM programs'):
            if not HEX_KEY.fullmatch(key) or not HEX_SHA.fullmatch(source_sha) or stage not in range(6):
                raise ValueError('translation archive has invalid shader identities')
            self.known[key] = (source_sha, stage)
            if status == 'ok':
                self.validated.add(key)
        if not self.known:
            raise ValueError('empty translation archive')
        self.records = {}
        snapshot = hashlib.sha256()
        for key, source_sha, stage, library_hash, reflection_blob in self.database.execute(
                "SELECT key,sha256,stage,library_hash,reflection_zlib FROM programs WHERE status='ok' ORDER BY key"):
            if self.known.get(key) != (source_sha, stage) or key not in self.validated:
                raise ValueError(f'archive shader identity or SPIR-V validation mismatch: {key}')
            if not HEX_SHA.fullmatch(library_hash or ''):
                raise ValueError(f'invalid library hash: {key}')
            reflection = json.loads(zlib.decompress(reflection_blob))
            validate_reflection(reflection, key, stage)
            if reflection.get('archive_shader_sha256') != source_sha:
                raise ValueError(f'reflection source mismatch: {key}')
            suffix = variant_suffix(stage, reflection, kind)
            name = key + suffix
            self.records[name] = dict(key=key, stage=stage, source_sha256=source_sha,
                                      library_hash=library_hash, reflection=reflection, archive=self)
            snapshot.update(digest([name, source_sha, library_hash, reflection]).encode())
        self.snapshot = dict(kind=kind, provenance=self.provenance,
                             ready_programs=len(self.records), records_sha256=snapshot.hexdigest())
        self.failures = list(self.database.execute(
            "SELECT key,stage,error FROM programs WHERE status!='ok' ORDER BY key"))

    def library(self, library_hash):
        row = self.database.execute('SELECT metal_zlib,metal_size,source_zlib FROM libraries WHERE hash=?',
                                    (library_hash,)).fetchone()
        if row is None:
            raise ValueError(f'missing library: {library_hash}')
        binary, source = zlib.decompress(row[0]), zlib.decompress(row[2])
        if len(binary) != row[1] or not binary.startswith(b'MTLB'):
            raise ValueError(f'invalid Metal library: {library_hash}')
        if hashlib.sha256(source).hexdigest() != library_hash:
            raise ValueError(f'Metal source checksum mismatch: {library_hash}')
        return binary, argument_members(source.decode())


def read_capture(directory, jobs_path, current, bindings):
    provenance = json.loads((directory / 'provenance.json').read_text())
    check_toolchain(provenance, current, capture=True)
    if provenance.get('binding_sources_sha256') != bindings:
        raise ValueError('capture package must be rebuilt for the current host bindings')
    if sha(jobs_path) != provenance.get('jobs_sha256'):
        raise ValueError('capture job manifest does not match its compiler provenance')
    chain = directory.name.removeprefix('b-')
    if not re.fullmatch(r'[0-9a-f]{12}', chain):
        raise ValueError('invalid capture package chain directory')
    records, known, identities = {}, {}, []
    for job in json.loads(jobs_path.read_text()):
        control, code = Path(job['control']).read_bytes(), Path(job['code']).read_bytes()
        stage = struct.unpack_from('<H', control, 0x56)[0]
        size = struct.unpack_from('<I', control, 0x3c)[0]
        c1 = Path(job['c1']).read_bytes() if size else b''
        if len(c1) != size:
            raise ValueError('capture constant segment length mismatch')
        source_sha = hashlib.sha256(control + code + c1).hexdigest()
        key = source_sha[:16]
        if key != job['key'] or key in known or stage not in (0, 1, 5):
            raise ValueError('invalid, duplicated or unsupported capture identity')
        name = key + '_b'
        reflection_path = directory / (name + '.json')
        reflection = json.loads(reflection_path.read_text())
        validate_reflection(reflection, key, stage)
        variant_suffix(stage, reflection, 'ordinary')
        if reflection.get('chain') != chain or reflection.get('compiler') != provenance:
            raise ValueError(f'capture reflection has inconsistent provenance: {key}')
        if reflection.get('c1', '') != c1.hex():
            raise ValueError(f'capture constants differ from owned input: {key}')
        binary_path = directory / (name + '.metallib')
        with binary_path.open('rb') as stream:
            if stream.read(4) != b'MTLB':
                raise ValueError(f'invalid captured Metal library: {key}')
        source_hash = sha(directory / (name + '.metal'))
        binary_hash = sha(binary_path)
        records[name] = dict(key=key, stage=stage, source_sha256=source_sha, library_hash=source_hash,
                             binary_path=binary_path, binary_sha256=binary_hash, reflection=reflection)
        known[key] = (source_sha, stage)
        identities.append([key, source_sha, source_hash, binary_hash, sha(reflection_path)])
    if not records or {path.stem for path in directory.glob('*_b.json')} != set(records):
        raise ValueError('capture manifest and packaged shader set differ')
    return known, records, dict(provenance=provenance, programs=len(records),
                                records_sha256=digest(identities))


def combine(archives, capture_known, captures, previous_map):
    known = dict(archives[0].known)
    for key, identity in capture_known.items():
        if key in known and known[key][1] != identity[1]:
            raise ValueError(f'capture stage conflicts with archive: {key}')
        if key not in known:
            known[key] = identity
    records = {}
    for archive in archives:
        if any(known.get(key) != identity for key, identity in archive.known.items()):
            raise ValueError('variant translation inputs differ from the canonical shader identities')
        if set(records) & set(archive.records):
            raise ValueError('duplicate archive variant')
        records.update(archive.records)
    overrides = []
    for name, record in captures.items():
        old = records.get(name)
        if old:
            overrides.append(dict(key=record['key'], archive_source_sha256=old['library_hash'],
                                  capture_source_sha256=record['library_hash'],
                                  sources_equal=old['library_hash'] == record['library_hash']))
        records[name] = record
    for line in previous_map.splitlines()[1:]:
        fields = line.split('\t')
        if len(fields) != 5 or fields[2] not in STAGES or not HEX_KEY.fullmatch(fields[3]):
            raise ValueError('invalid existing shader map')
        stage, key = STAGES.index(fields[2]), fields[3]
        if key not in known or known[key][1] != stage:
            raise ValueError(f'export would drop or change an existing shader identity: {key}')
    return known, records, overrides


def coverage(known, records):
    required = set()
    for key, (_, stage) in known.items():
        required.add(key + ({2: '_gm_b', 3: '_th_b', 4: '_td3_b'}.get(stage, '_b')))
        if stage == 0:
            required.add(key + '_tv_b')
    missing = sorted(required - set(records))
    unresolved = sorted(name for name, record in records.items()
                        if record.get('reflection', {}).get('nx2_geometry', {}).get('unresolved_position_default'))
    return dict(known_programs=len(known), required_variants=len(required),
                exported_variants=len(records), missing_variants=len(missing),
                unresolved_variants=len(unresolved), unresolved=unresolved,
                complete=not missing and not unresolved, missing=missing)


def export_libraries(records, destination, cache, chain):
    """Deduplicate by binary content; do not assume equal MSL implies equal binaries."""
    cache.mkdir(parents=True, exist_ok=True)
    binaries = {}
    for name, record in sorted(records.items()):
        identity = (id(record.get('archive')), record['library_hash'], record.get('binary_sha256'))
        if identity not in binaries:
            if 'archive' in record:
                binary, members = record['archive'].library(record['library_hash'])
                binary_hash = hashlib.sha256(binary).hexdigest()
            else:
                binary_hash = record['binary_sha256']
                binary = record['binary_path'].read_bytes()
                if hashlib.sha256(binary).hexdigest() != binary_hash:
                    raise ValueError(f'capture library changed during export: {name}')
                members = argument_members(record['binary_path'].with_suffix('.metal').read_text())
            library = cache / (binary_hash + '.metallib')
            if not library.exists() or sha(library) != binary_hash:
                atomic_write(library, binary)
            binaries[identity] = (library, binary_hash, members)
        library, binary_hash, members = binaries[identity]
        os.link(library, destination / (name + '.metallib'))
        reflection = dict(complete_argument_bindings(record['reflection'], members), chain=chain,
                          library_source_sha256=record['library_hash'], library_binary_sha256=binary_hash)
        atomic_write(destination / (name + '.json'), json.dumps(reflection, separators=(',', ':')).encode())
    return len({binary_hash for _, binary_hash, _ in binaries.values()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('translated', type=Path)
    parser.add_argument('metal', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--ordinary-overlay', nargs=2, type=Path, action='append', default=[],
                        metavar=('TRANSLATED', 'METAL'),
                        help='Add missing ordinary variants with separate compiler provenance; duplicates are rejected')
    parser.add_argument('--vertex-capture', nargs=2, type=Path, action='append', default=[], metavar=('TRANSLATED', 'METAL'))
    parser.add_argument('--tessellation', nargs=2, type=Path, metavar=('TRANSLATED', 'METAL'))
    parser.add_argument('--geometry', nargs=2, type=Path, metavar=('TRANSLATED', 'METAL'))
    parser.add_argument('--supplement', nargs=2, type=Path, metavar=('PACKAGE', 'JOBS'))
    parser.add_argument('--require-complete', action='store_true')
    args = parser.parse_args()
    profile = game.load()
    current, hashes = current_toolchain(), {}
    archives = [Archive(args.translated, args.metal, 'ordinary', current, hashes)]
    for paths in args.ordinary_overlay:
        archives.append(Archive(*paths, 'ordinary', current, hashes))
    for paths in args.vertex_capture:
        archives.append(Archive(*paths, 'vertex', current, hashes))
    if args.tessellation:
        archives.append(Archive(*args.tessellation, 'tess', current, hashes))
    if args.geometry:
        archives.append(Archive(*args.geometry, 'geometry', current, hashes))
    bindings = {name: sha(HERE.parent / 'nvn' / name)
                for name in ('nvn_refl.h', 'nvn_refl.m', 'nvn_mtl.m')}
    capture_known, captures, supplement = {}, {}, None
    if args.supplement:
        capture_known, captures, supplement = read_capture(*args.supplement, current, bindings)
    known, records, overrides = combine(archives, capture_known, captures, profile.table('shader_map.tsv').read_text())
    status = coverage(known, records)
    if args.require_complete and not status['complete']:
        raise ValueError(f'archive is incomplete: {status["missing_variants"]} required variants missing, '
                         f'{status["unresolved_variants"]} variants have unresolved semantics')
    build = dict(archives=[archive.snapshot for archive in archives], supplement=supplement,
                 exporter_sha256=sha(__file__), binding_sources_sha256=bindings)
    build_digest = digest(build)
    originals = {profile.table(name): profile.table(name).read_bytes() if profile.table(name).exists() else None
                 for name in ('game.tsv', 'shader_map.tsv', 'dmsh_chain.h', 'c1_full.tsv')}
    staging = None
    try:
        config = profile.table('game.tsv')
        text = re.sub(r'^shader_nx2_chain\t.*\n', '', config.read_text(), flags=re.M)
        config.write_text(text + f'shader_nx2_chain\t{build_digest}\n')
        ordered = sorted(known.items())
        profile.table('shader_map.tsv').write_text('package\tindex\tstage\tdm_ctl_sha16\tsource\n' + ''.join(
            f'{"capture" if key in capture_known else "ROMFS"}\t{i}\t{STAGES[stage]}\t{key}\t{source_sha}\n'
            for i, (key, (source_sha, stage)) in enumerate(ordered)))
        chain = builder.run([sys.executable, HERE / 'dmsh_chain.py', '--header']).strip()
        args.output.mkdir(parents=True, exist_ok=True)
        destination = args.output / ('b-' + chain)
        if destination.exists():
            raise ValueError(f'export destination already exists: {destination}; keep the existing immutable package')
        staging = Path(tempfile.mkdtemp(prefix='.nx2-export-', dir=args.output))
        unique = export_libraries(records, staging, args.output / 'nx2-libraries', chain)
        profile.table('c1_full.tsv').write_text(f'# chain b-{chain}\n' + ''.join(key + '\n' for key, _ in ordered))
        manifest = dict(chain=chain, **status, unique_libraries=unique, provenance=build,
                        capture_overrides=overrides,
                        failures=[dict(kind=archive.kind,
                                       input_database_sha256=archive.provenance['input_database_sha256'],
                                       programs=archive.failures) for archive in archives])
        atomic_write(staging / 'archive-manifest.json', json.dumps(manifest, indent=2).encode())
        staging.rename(destination)
        staging = None
        print(f'{len(records)} Metal variants exported; {unique} unique binaries; '
              f'{status["missing_variants"]} variants missing; chain {chain}')
    except BaseException:
        for path, contents in originals.items():
            if contents is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, contents)
        raise
    finally:
        if staging is not None:
            shutil.rmtree(staging)


if __name__ == '__main__':
    main()
