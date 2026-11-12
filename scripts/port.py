#!/usr/bin/env python3
"""Build native macOS apps from profiled Switch / Switch 2 game dumps."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

import build_ipa_from_nsp as common
import mac_bundle as bundle

REPO = bundle.REPO


def resolve(path):
    return path.expanduser().resolve() if path else None


def describe(args):
    profile = bundle.game.load(args.profile)
    version = args.version or profile.get('package')
    if version not in profile.builds():
        raise bundle.BundleError(f'unknown version {version} for {profile.id}')
    graphics, system = profile.get('graphics', 'nvn'), profile.get('platform', 'nx')
    if graphics not in ('nvn', 'vulkan') or system not in ('nx', 'nx2'):
        raise bundle.BundleError(f'unsupported profile platform/graphics: {system}/{graphics}')
    work = resolve(args.work)
    if work.is_relative_to(REPO):
        raise bundle.BundleError('keep the game work directory outside the source repository')
    extracted = resolve(args.extracted) or work / 'data' / version
    output = args.output.expanduser().absolute() if args.output else work / ((args.name or profile.get('name')) + '.app')
    if output.suffix != '.app':
        raise bundle.BundleError('output must end in .app')
    if args.nsp_dir and not args.keys:
        raise bundle.BundleError('--nsp-dir requires --keys')
    if args.nx2_jobs and (system != 'nx2' or not args.compiler or not args.compiler_source):
        raise bundle.BundleError('--nx2-jobs requires an nx2 profile, --compiler and --compiler-source')
    if system == 'nx2' and not args.shaders and not args.nx2_jobs:
        raise bundle.BundleError('NX2 needs --shaders <b-chain directory> or '
                                 '--nx2-jobs <jobs.json> --compiler <nx2-offline> --compiler-source <fork>')
    if args.shaders and args.nx2_jobs:
        raise bundle.BundleError('choose either an existing shader package or NX2 jobs')
    stages = ['snapshot profile']
    if args.nsp_dir:
        stages += ['extract registered NSP versions and DLC']
    if not args.patched:
        stages += ['verify NSO build IDs', 'rewrite ARM64 modules']
    if not args.shaders:
        stages += ['translate and compile shaders']
    stages += ['build native Mac host', 'prepare font', 'validate inputs', 'package and verify signature']
    return profile, {
        'profile': profile.id, 'profile_directory': str(profile.dir),
        'platform': system, 'graphics': graphics, 'version': version,
        'work': str(work), 'extracted': str(extracted), 'output': str(output),
        'stages': stages, 'requires_gameplay_validation': True,
    }


def shader_sources(args, profile, version, extracted):
    sources = {version: extracted}
    for item in args.shader_source:
        name, sep, path = item.partition('=')
        if not sep or name not in profile.builds():
            raise bundle.BundleError(f'--shader-source expects registered-version=directory: {item}')
        sources[name] = Path(path).expanduser().resolve()
    for name in profile.words('shader_versions'):
        if name not in sources:
            candidate = resolve(args.work) / 'data' / name
            if not candidate.is_dir():
                raise bundle.BundleError(f'missing shader source {name}; give --shader-source {name}=<extraction>')
            sources[name] = candidate
    return sources


def compile_shaders(args, profile, sources, patched, work, logs, env):
    shader = work / 'shader'
    if profile.get('platform', 'nx') == 'nx2':
        def keys():
            return {fields[3] for line in profile.table('shader_map.tsv').read_text().splitlines()
                    if not line.startswith(('#', 'package\t'))
                    and len(fields := line.split('\t')) >= 4}
        expected = keys()
        command = [sys.executable, REPO / 'dm/gfx/tools/dmsh_nx2_build.py',
                   resolve(args.nx2_jobs), resolve(args.compiler), resolve(args.compiler_source),
                   shader, '--workers', str(args.workers)]
        common.run(command, logs / 'nx2-shaders.log', env=env)
        result = shader / ('b-' + bundle.chain_of(profile))
        rejected = json.loads((result / 'rejected.json').read_text())
        removed = sorted(expected - keys())
        (logs / 'nx2-coverage.json').write_text(json.dumps({
            'previous_keys': len(expected), 'removed_keys': removed,
            'rejected_jobs': rejected}, indent=2) + '\n')
        if rejected and not args.allow_incomplete_shaders:
            raise bundle.BundleError(f'{len(rejected)} NX2 jobs rejected; see {result / "rejected.json"}')
        if removed and not args.allow_incomplete_shaders:
            raise bundle.BundleError(f'NX2 jobs omit {len(removed)} previously known shader keys; '
                                     'supply the complete job set or use a merged --shaders package')
        return result
    version = args.version or profile.get('package')
    if profile.get('graphics', 'nvn') == 'vulkan':
        source = sources[version]
        roots = [source / 'RomFS']
        if profile.get('shader_vk_capture', 'off') == 'on':
            roots.append(common.capture_vk(REPO, source, patched, work, env, logs, profile))
        common.run([sys.executable, REPO / 'dm/gfx/tools/vk_shaders.py', *roots, shader],
                   logs / 'vulkan-shaders.log', env=env)
        return shader / 'vk'
    if profile.get('shader_glslc_capture', 'off') == 'on':
        common.capture_glslc(REPO, sources, version, patched, work, env, logs, profile)
    needed = profile.words('shader_versions')
    common.split_shaders(sys.executable, REPO, [sources[v] / 'RomFS' for v in needed],
                         [sources[v] / 'ExeFS/main' for v in needed], shader / 'pkg',
                         env, logs, profile)
    common.run([sys.executable, REPO / 'dm/gfx/tools/dmsh_chain.py', '--header'],
               logs / 'shader-chain.log', env=env)
    common.run([sys.executable, REPO / 'dm/gfx/tools/dmsh_build.py', shader / 'pkg', shader / 'cache'],
               logs / 'mac-shaders.log', env=env)
    result = shader / 'cache' / ('b-' + bundle.chain_of(profile))
    common.run([sys.executable, REPO / 'dm/gfx/tools/c1_guard.py', result, profile.table('c1_full.tsv')],
               logs / 'shader-c1.log', env=env)
    return result


def build(args):
    original, plan = describe(args)
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise bundle.BundleError('native Mac builds require an Apple Silicon Mac')
    for tool in ('make', 'clang', 'codesign', 'xcrun'):
        if not shutil.which(tool):
            raise bundle.BundleError(f'missing build tool: {tool}')
    work, extracted, output = map(Path, (plan['work'], plan['extracted'], plan['output']))
    if output.exists() and not args.replace:
        raise bundle.BundleError(f'output already exists: {output}; use --replace to retain a backup')
    # Validate input paths before any expensive compilation.
    if args.shaders:
        bundle.require(resolve(args.shaders), True)
    if args.patched:
        bundle.require(resolve(args.patched), True)
    if not args.nsp_dir:
        bundle.require(extracted / 'RomFS', True)
        if not args.patched:
            bundle.require(extracted / 'ExeFS', True)
    run_dir = work / 'builds' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    logs = run_dir / 'logs'
    logs.mkdir(parents=True)
    status = {**plan, 'status': 'building', 'run_directory': str(run_dir)}
    def stage(name):
        status['stage'] = name
        (run_dir / 'status.json').write_text(json.dumps(status, indent=2) + '\n')
        print(name, flush=True)
    try:
        stage('Snapshot profile')
        profile_dir = run_dir / 'profile' / original.id
        shutil.copytree(original.dir, profile_dir)
        profile = bundle.game.load(str(profile_dir))
        env = dict(os.environ, DM_GAME=str(profile_dir), DM_ROOT=str(work), WORK=str(work / 'tmp'),
                   DM_GAMES_DIR=str(profile_dir.parent))
        (work / 'tmp').mkdir(exist_ok=True)
        # A package build must not accidentally inherit diagnostic shader dumps
        # or iOS compiler output locations from the caller's shell.
        for key in ('IOSOUT', 'DM_NVN_FACTDUMP', 'DM_NVN_CODEDUMP'):
            env.pop(key, None)
        sources, aoc = {plan['version']: extracted}, resolve(args.aoc)
        if args.nsp_dir:
            stage('Extract NSPs')
            keys = bundle.require(resolve(args.keys))
            app, family = common.scan_nsps(resolve(args.nsp_dir))
            if app != original.title_id:
                raise bundle.BundleError('NSP title ID does not match the selected profile')
            versions = [plan['version']]
            if not args.shaders and plan['platform'] == 'nx':
                versions = list(dict.fromkeys(profile.words('shader_versions') + versions))
            picks = common.pick_nsps(family, versions)
            nx = common.build_nx_extract(REPO, work, logs, env)
            sources = {}
            for version, (base, update) in picks.items():
                sources[version] = common.extract(nx, keys, work / 'data', version,
                                                  base, update, None, logs, profile)
            extracted = sources[plan['version']]
            aoc = common.extract_aoc(nx, keys, work, app, family, logs) or aoc
        patched = resolve(args.patched)
        if not patched:
            stage('Verify and rewrite ARM64 modules')
            common.check_build(extracted, plan['version'], profile)
            patched = run_dir / 'patched'
            common.rewrite(sys.executable, REPO, extracted / 'ExeFS', patched, env, logs, profile)
        shaders = resolve(args.shaders)
        if not shaders:
            stage('Compile Metal shaders')
            if not args.nsp_dir and plan['platform'] == 'nx':
                sources = shader_sources(args, profile, plan['version'], extracted)
            for version, source in sources.items():
                common.check_build(source, version, profile)
            shaders = compile_shaders(args, profile, sources, patched, work, logs, env)
        stage('Build native Mac host')
        host = run_dir / 'host/dmhost'
        common.build_mac_host(REPO, host, env, logs, profile)
        stage('Prepare font')
        font = resolve(args.font) or work / 'build/font/nintendo_ext.ttf'
        if not font.exists():
            if args.font:
                raise bundle.BundleError(f'font not found: {font}')
            font.parent.mkdir(parents=True, exist_ok=True)
            common.run([sys.executable, REPO / 'dm/tools/make_ext_font.py', font], logs / 'font.log', env=env)
        icon = resolve(args.icon)
        if not icon and (extracted / 'icon.jpg').is_file():
            icon = extracted / 'icon.jpg'
        stage('Validate and package app')
        result = bundle.package(profile, plan['version'], host, patched, extracted / 'RomFS', shaders,
                                font, output, name=args.name, bundle_id=args.bundle_id, icon=icon, aoc=aoc,
                                replace=args.replace, allow_incomplete=args.allow_incomplete_shaders)
        status.update(status='complete', result=result)
        (work / 'last-build.json').write_text(json.dumps(status, indent=2) + '\n')
        print(f'Built {output}\nBuild report: {work / "last-build.json"}', flush=True)
    except BaseException as error:
        status.update(status='failed', error=str(error))
        raise
    finally:
        (run_dir / 'status.json').write_text(json.dumps(status, indent=2) + '\n')


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest='command', required=True)
    commands.add_parser('profiles', help='list available profiles; this is not a compatibility guarantee')
    for name in ('plan', 'build'):
        p = commands.add_parser(name, help='show build stages without writing files' if name == 'plan' else 'build and package a native Mac app')
        p.add_argument('--profile', required=True, help='title ID or external profile directory')
        p.add_argument('--work', type=Path, required=True, help='game work directory outside the repository')
        source = p.add_mutually_exclusive_group()
        source.add_argument('--extracted', type=Path, help='directory containing ExeFS and RomFS (default: WORK/data/VERSION)')
        source.add_argument('--nsp-dir', type=Path, help='folder containing one game\'s NSPs')
        p.add_argument('--keys', type=Path, help='prod.keys for NSP extraction')
        p.add_argument('--version', help='registered version; defaults to profile package')
        p.add_argument('--patched', type=Path, help='reuse verified rewritten modules, including local mod cuts')
        p.add_argument('--shaders', type=Path, help='existing b-chain directory, or vk directory for Vulkan')
        p.add_argument('--shader-source', action='append', default=[], metavar='VERSION=DIR', help='additional extracted version for NX1 shader compilation')
        p.add_argument('--nx2-jobs', type=Path, help='NX2 jobs with proven shader resource facts')
        p.add_argument('--compiler', type=Path, help='patched nx2-offline compiler')
        p.add_argument('--compiler-source', type=Path, help='matching patched compiler source checkout')
        p.add_argument('--workers', type=int, choices=range(1, 9), default=4)
        p.add_argument('--font', type=Path, help='existing nintendo_ext.ttf; otherwise generated when missing')
        p.add_argument('--icon', type=Path)
        p.add_argument('--aoc', type=Path, help='DLC root containing numeric index directories')
        p.add_argument('--name', help='app display name and Application Support folder name')
        p.add_argument('--bundle-id')
        p.add_argument('-o', '--output', type=Path)
        p.add_argument('--replace', action='store_true', help='retain the existing output as a backup before replacement')
        p.add_argument('--allow-incomplete-shaders', action='store_true', help='diagnostic builds only; records missing or rejected shaders')
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    if args.command == 'profiles':
        print(json.dumps([{'id': g.id, 'name': g.get('name'), 'platform': g.get('platform', 'nx'),
                           'graphics': g.get('graphics', 'nvn'), 'versions': list(g.builds()),
                           'directory': str(g.dir)} for g in bundle.game.all_games()], indent=2))
    elif args.command == 'plan':
        print(json.dumps(describe(args)[1], indent=2))
    else:
        build(args)


if __name__ == '__main__':
    try:
        main()
    except (bundle.BundleError, common.BuildError, OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f'[RED] {error}')
    except KeyboardInterrupt:
        sys.exit(130)
