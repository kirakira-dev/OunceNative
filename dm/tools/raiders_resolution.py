#!/usr/bin/env python3
"""Build local Raiders scene-resolution overlays from the owner's RomFS.

Requires the byml Python package. Game data is written only to the requested
output directory; the source dump and the separate 1080p HUD setting stay intact.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

import byml


def build(romfs, output):
    relative = Path('Gyml/Default.game__gfx__parameter__ModuleParam.bgyml')
    source = romfs / relative
    data = source.read_bytes()
    if data[:2] != b'YB':
        raise ValueError('Expected little-endian BYML')
    original = byml.Byml(data).parse()
    handheld = original['ResolutionSetting']['Handheld']
    if handheld['FrameBufferResolution'] != 1080 or handheld['Layer3DResolution'] != 1080:
        raise ValueError('Unrecognized Raiders resolution settings; refusing to overwrite them')
    records = []
    for height in (720, 900):
        changed = copy.deepcopy(original)
        changed['ResolutionSetting']['Handheld']['Layer3DResolution'] = byml.Int(height)
        encoded = byml.Writer(changed, be=False, version=int.from_bytes(data[2:4], 'little')).get_bytes()
        if byml.Byml(encoded).parse() != changed:
            raise ValueError('Overlay BYML failed its round-trip check')
        target = output / str(height) / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(encoded)
        records.append({'scene_height': height, 'path': str(target.relative_to(output)),
                        'sha256': hashlib.sha256(encoded).hexdigest()})
    output.mkdir(parents=True, exist_ok=True)
    manifest = {'source': str(relative), 'source_sha256': hashlib.sha256(data).hexdigest(),
                'field': 'ResolutionSetting.Handheld.Layer3DResolution', 'original': 1080,
                'overlays': records}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('romfs', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.romfs, args.output), indent=2))
