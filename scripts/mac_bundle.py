#!/usr/bin/env python3
"""Validate and package a native Mac game, including profiles outside the repo."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'dm/games'))
import game


class BundleError(Exception):
    pass


def require(path, directory=False):
    if not (path.is_dir() if directory else path.is_file()):
        raise BundleError(f'missing {"directory" if directory else "file"}: {path}')
    return path


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(command):
    subprocess.run([str(p) for p in command], check=True)


def clone(source, target):
    # macOS cp -c fails rather than silently duplicating a large RomFS on a
    # volume without cloning. Retry using ordinary copying in that case.
    result = subprocess.run(['cp', '-cR', str(source), str(target)], capture_output=True)
    if result.returncode:
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)


def chain_of(profile):
    match = re.search(r'^#define DMSH_CHAIN "([0-9a-f]+)"$',
                      require(profile.table('dmsh_chain.h')).read_text(), re.M)
    if not match:
        raise BundleError('profile has no valid DMSH_CHAIN')
    return match[1]


def validate(profile, version, host, patched, romfs, shaders, font, allow_incomplete=False):
    """Check the inputs before creating a temporary bundle or replacing output.

    These are structural checks. Metal validation and gameplay are separate.
    """
    if not re.fullmatch(r'[0-9A-Fa-f]{16}', profile.id):
        raise BundleError('profile directory must be named with its 16-digit title ID')
    if profile.get('platform', 'nx') not in ('nx', 'nx2'):
        raise BundleError('profile platform must be nx or nx2')
    builds = profile.builds()
    if version not in builds:
        raise BundleError(f'unknown package {version}; profile has {", ".join(builds)}')
    require(host)
    if not os.access(host, os.X_OK):
        raise BundleError(f'host is not executable: {host}')
    require(romfs, True)
    marker = Path(profile.get('romfs_marker'))
    if marker.is_absolute() or '..' in marker.parts:
        raise BundleError(f'invalid profile RomFS marker: {marker}')
    require(romfs / marker)
    require(font)
    module_hashes = {}
    for module in profile.words('modules'):
        if not re.fullmatch(r'(main|sdk|subsdk\d+)', module):
            raise BundleError(f'unsupported module name: {module}')
        binary = require(patched / f'{module}.patched.bin')
        layout = require(patched / f'{module}.fixups.tsv')
        match = re.search(r'^# BUILD_ID\s+([0-9a-fA-F]{32,64})\s*$', layout.read_text(), re.M)
        expected = builds[version].get(module)
        if not match or not expected or match[1].lower() != expected.lower():
            raise BundleError(f'{module} rewritten build ID does not match {version}')
        module_hashes[module] = {'binary': digest(binary), 'layout': digest(layout)}
    chain = chain_of(profile)
    graphics = profile.get('graphics', 'nvn')
    missing = []
    if graphics == 'nvn':
        require(profile.table('c1_full.tsv'))
        keys = set()
        for line in require(profile.table('shader_map.tsv')).read_text().splitlines():
            if not line.strip() or line.startswith('#') or line.startswith('package\t'):
                continue
            fields = line.split('\t')
            if len(fields) < 4 or not re.fullmatch(r'[0-9a-f]{16}', fields[3]):
                raise BundleError(f'invalid shader-map row: {line[:100]}')
            keys.add(fields[3])
        if not keys:
            raise BundleError('profile shader map is empty; compile shaders before packaging')
        require(shaders, True)
        for key in sorted(keys):
            if not all((shaders / f'{key}_b{suffix}').is_file() for suffix in ('.metallib', '.json')):
                missing.append(key)
        if missing and not allow_incomplete:
            raise BundleError(f'{len(missing)} shader libraries missing (first: {missing[0]}); '
                              'use --allow-incomplete-shaders only for a diagnostic build')
        # NX2 reflections record the chain. A directory renamed to the correct
        # b-* name must not disguise an incompatible package.
        for reflection in shaders.glob('*_b.json'):
            item = json.loads(reflection.read_text())
            if item.get('chain', chain) != chain:
                raise BundleError(f'shader chain mismatch: {reflection}')
        shader_count = len(keys) - len(missing)
        shader_subdir = f'b-{chain}'
    elif graphics == 'vulkan':
        require(shaders / 'vk_shaders.metallib')
        require(shaders / 'vk_shaders.tsv')
        shader_count = None
        shader_subdir = 'vk'
    else:
        raise BundleError(f'unsupported graphics API: {graphics}')
    return {'profile': profile.id, 'platform': profile.get('platform', 'nx'),
            'version': version, 'graphics': graphics, 'chain': chain,
            'host_sha256': digest(host), 'modules': module_hashes,
            'shader_count': shader_count, 'missing_shader_keys': missing,
            'shader_subdir': shader_subdir}


def bundle_info(profile, name, version, bundle_id=None):
    environment = {
        'DM_ROOT': '${APP_SUPPORT}', 'DM_ROMFS': '${RESOURCES}/RomFS',
        'DM_SAVE': '${APP_SUPPORT}/save', 'DM_TEMP': '${APP_SUPPORT}/temp',
        'DM_MSL_DIR': '${RESOURCES}/shaders', 'DM_FONT_DIR': '${RESOURCES}/font',
        'DM_NVN_SHMAP': '${CONTENTS}/games/' + profile.id + '/shader_map.tsv',
        'DM_SETTINGS_DIR': '${APP_SUPPORT}', 'DM_WINDOW': '1', 'DM_AUDIO': '1',
    }
    if profile.id == '0400380020056000':
        environment.update(DM_SCENE_OVERLAY_ROOT='${RESOURCES}/scene-resolution',
                           DM_PRESENT_LINK='0', DM_PRESENT_MIN_DURATION='0',
                           DM_PSO_WORKERS='4', DM_PSO_STARTUP_WAIT_MS='120000')
    return {
        'CFBundleExecutable': 'dmhost',
        'CFBundleIdentifier': bundle_id or 'org.ouncenative.mac.' + profile.id.lower(),
        'CFBundleName': name, 'CFBundleDisplayName': name, 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': version, 'CFBundleVersion': version,
        'CFBundleIconFile': 'AppIcon',
        'LSApplicationCategoryType': profile.get('app_category', 'public.app-category.games'),
        'LSMinimumSystemVersion': '26.0', 'NSHighResolutionCapable': True,
        'GCSupportsControllerUserInteraction': True,
        'DMNativeEnvironment': environment, 'DMNativeModuleDirectory': 'patched',
    }


def make_icon(source, resources, scratch):
    iconset = scratch / 'AppIcon.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            subprocess.run(['sips', '-s', 'format', 'png', '-z', str(size * scale),
                            str(size * scale), str(source), '--out',
                            str(iconset / f'icon_{size}x{size}{suffix}.png')],
                           check=True, stdout=subprocess.DEVNULL)
    run(['iconutil', '-c', 'icns', iconset, '-o', resources / 'AppIcon.icns'])


def publish(staged, output, replace):
    backup = None
    if output.exists() or output.is_symlink():
        if not replace:
            raise BundleError(f'output already exists: {output} (use --replace to retain a backup)')
        backup = output.with_name(output.name + '.backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
        output.rename(backup)
    try:
        staged.rename(output)
    except BaseException:
        if backup is not None:
            backup.rename(output)
        raise
    return backup


def package(profile, version, host, patched, romfs, shaders, font, output, *,
            name=None, bundle_id=None, icon=None, aoc=None, replace=False,
            allow_incomplete=False, dry_run=False):
    output = output.absolute()
    name = name or profile.get('name')
    if not name.strip() or '/' in name or '\\' in name or name in ('.', '..'):
        raise BundleError('app name must be a single directory name; override it with --name')
    if output.suffix != '.app' or output.is_symlink():
        raise BundleError('output must be an .app path, not a symbolic link')
    if output.exists() and not replace:
        raise BundleError(f'output already exists: {output} (use --replace to retain a backup)')
    # Replacing a parent of an input would also move the input while packaging.
    for path in (profile.dir, host, patched, romfs, shaders, font):
        if path.resolve().is_relative_to(output.resolve()) or output.resolve().is_relative_to(path.resolve()):
            raise BundleError(f'output overlaps an input: {path}')
    report = validate(profile, version, host, patched, romfs, shaders, font, allow_incomplete)
    if icon:
        require(icon)
    if aoc:
        require(aoc, True)
    report.update(output=str(output), gameplay_validated=False)
    if dry_run:
        return report
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.ouncenative-', dir=output.parent) as temp:
        scratch = Path(temp)
        staged = scratch / output.name
        contents = staged / 'Contents'
        resources = contents / 'Resources'
        for directory in (contents / 'MacOS', resources / 'shaders', resources / 'font'):
            directory.mkdir(parents=True)
        shutil.copy2(host, contents / 'MacOS/dmhost')
        clone(patched, resources / 'patched')
        target_profile = contents / 'games' / profile.id
        target_profile.mkdir(parents=True)
        for path in sorted(profile.dir.glob('*.tsv')) + [profile.table('dmsh_chain.h')]:
            shutil.copy2(path, target_profile / path.name)
        clone(shaders, resources / 'shaders' / report['shader_subdir'])
        shutil.copy2(font, resources / 'font/nintendo_ext.ttf')
        print(f'Copying RomFS to {output}', flush=True)
        clone(romfs, resources / 'RomFS')
        if aoc:
            clone(aoc, resources / 'aoc')
        if profile.id == '0400380020056000':
            run([sys.executable, REPO / 'dm/tools/raiders_resolution.py',
                 romfs, resources / 'scene-resolution'])
        if icon:
            make_icon(icon, resources, scratch)
        info = bundle_info(profile, name,
                           profile.builds()[version]['display'], bundle_id)
        if aoc:
            info['DMNativeEnvironment']['DM_AOC_DIR'] = '${RESOURCES}/aoc'
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        report['profile_sha256'] = {p.name: digest(p) for p in sorted(target_profile.iterdir())}
        (resources / 'native-build.json').write_text(json.dumps(report, indent=2) + '\n')
        run(['codesign', '--force', '--deep', '--sign', '-', staged])
        run(['codesign', '--verify', '--deep', '--strict', staged])
        backup = publish(staged, output, replace)
        report.update(signature_verified=True, backup=str(backup) if backup else None)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--profile', required=True, help='title ID or profile directory')
    parser.add_argument('--version')
    for option in ('host', 'patched', 'romfs', 'shaders', 'font'):
        parser.add_argument('--' + option, type=Path, required=True)
    parser.add_argument('--name')
    parser.add_argument('--bundle-id')
    parser.add_argument('--icon', type=Path)
    parser.add_argument('--aoc', type=Path)
    parser.add_argument('--replace', action='store_true')
    parser.add_argument('--allow-incomplete-shaders', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    profile = game.load(args.profile)
    report = package(profile, args.version or profile.get('package'), args.host, args.patched,
                     args.romfs, args.shaders, args.font, args.output, name=args.name,
                     bundle_id=args.bundle_id, icon=args.icon, aoc=args.aoc, replace=args.replace,
                     allow_incomplete=args.allow_incomplete_shaders, dry_run=args.dry_run)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (BundleError, OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f'[RED] {error}')
