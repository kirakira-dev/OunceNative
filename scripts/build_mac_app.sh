#!/bin/bash
# Package a manually built game. See docs/development.md.
# GAME=<profile> W=<work folder> [APP_NAME=...] scripts/build_mac_app.sh [out.app]
set -euo pipefail
: "${GAME:?GAME=<profile id>}" "${W:?W=<work folder>}"
REPO=$(cd "$(dirname "$0")/.." && pwd)
VER=${VER:-$(python3 "$REPO/dm/games/game.py" "$GAME" package)}
NAME=${APP_NAME:-$(python3 "$REPO/dm/games/game.py" "$GAME" name)}
OUT=${1:-$W/../$NAME.app}
CHAIN=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$REPO/dm/games/$GAME/dmsh_chain.h")
PATCHED=${PATCHED:-$W/build/patched_$VER}
ROMFS=${ROMFS:-$W/data/$VER/RomFS}
MSL=${MSL:-$W/build/cache/metal_shader_cache/b-$CHAIN}
for p in "$REPO/dm/host/dmhost" "$PATCHED/main.patched.bin" "$ROMFS" "$MSL" "$W/build/font/nintendo_ext.ttf"; do
    [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done

echo "packing $OUT"
rm -rf "$OUT"
C="$OUT/Contents"; R="$C/Resources"
mkdir -p "$C/MacOS" "$R/patched" "$R/shaders" "$R/font"
cp "$REPO/dm/host/dmhost" "$C/MacOS/dmhost"
cp -R "$PATCHED"/. "$R/patched/"
# the host reads the profile tables from <exe>/../games/<id>/ (shader_map.tsv and friends)
mkdir -p "$C/games/$GAME"; cp "$REPO/dm/games/$GAME"/*.tsv "$REPO/dm/games/$GAME"/dmsh_chain.h "$C/games/$GAME/"
cp -c -R "$MSL" "$R/shaders/b-$CHAIN"            # -c: APFS clone
cp "$W/build/font/nintendo_ext.ttf" "$R/font/"
echo "cloning the RomFS ($(du -sh "$ROMFS" | cut -f1))"
cp -c -R "$ROMFS" "$R/RomFS"
if [ "$GAME" = 0400380020056000 ]; then
    python3 "$REPO/dm/tools/raiders_resolution.py" "$ROMFS" "$R/scene-resolution"
fi

ICON=$(ls "$W/data/$VER/icon.jpg" "$W/data/v0/icon.jpg" 2>/dev/null | head -1 || true)
if [ -n "$ICON" ]; then
    S=$(mktemp -d)/AppIcon.iconset; mkdir -p "$S"
    for sz in 16 32 128 256 512; do
        sips -s format png -z $sz $sz "$ICON" --out "$S/icon_${sz}x${sz}.png" >/dev/null
        sips -s format png -z $((sz * 2)) $((sz * 2)) "$ICON" --out "$S/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$S" -o "$R/AppIcon.icns"
fi

DV=$(python3 - "$W/data/$VER/control.nacp" <<'PY' 2>/dev/null || echo 1.0
import sys; d = open(sys.argv[1], 'rb').read(); print(d[0x3060:0x3070].split(b'\0')[0].decode() or '1.0')
PY
)
python3 - "$C/Info.plist" "$GAME" "$NAME" "$DV" "$REPO" <<'PYINFO'
from pathlib import Path
import plistlib
import sys

path, profile_id, name, version, repo = sys.argv[1:]
sys.path.insert(0, str(Path(repo) / 'dm/games'))
import game
profile = game.load(profile_id)
environment = {
    'DM_ROOT': '${APP_SUPPORT}',
    'DM_ROMFS': '${RESOURCES}/RomFS',
    'DM_SAVE': '${APP_SUPPORT}/save',
    'DM_TEMP': '${APP_SUPPORT}/temp',
    'DM_MSL_DIR': '${RESOURCES}/shaders',
    'DM_FONT_DIR': '${RESOURCES}/font',
    'DM_NVN_SHMAP': '${CONTENTS}/games/' + profile_id + '/shader_map.tsv',
    'DM_SETTINGS_DIR': '${APP_SUPPORT}',
    'DM_WINDOW': '1',
    'DM_AUDIO': '1',
}
if profile_id == '0400380020056000':
    environment['DM_SCENE_OVERLAY_ROOT'] = '${RESOURCES}/scene-resolution'
    # The direct drawable path keeps presenting when macOS display-link
    # callbacks pause; the layer still synchronizes presentation to vblank.
    environment['DM_PRESENT_LINK'] = '0'
    environment['DM_PRESENT_MIN_DURATION'] = '0'
    environment['DM_PSO_WORKERS'] = '4'
    environment['DM_PSO_STARTUP_WAIT_MS'] = '120000'
info = {
    'CFBundleExecutable': 'dmhost',
    'CFBundleIdentifier': 'org.ouncenative.mac.' + profile_id.lower(),
    'CFBundleName': name,
    'CFBundleDisplayName': name,
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version,
    'CFBundleVersion': version,
    'CFBundleIconFile': 'AppIcon',
    'LSApplicationCategoryType': profile.get('app_category', 'public.app-category.adventure-games'),
    'LSMinimumSystemVersion': '26.0',
    'NSHighResolutionCapable': True,
    'GCSupportsControllerUserInteraction': True,
    'DMNativeEnvironment': environment,
    'DMNativeModuleDirectory': 'patched',
}
Path(path).write_bytes(plistlib.dumps(info))
PYINFO
codesign -s - -f --deep "$OUT" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed" >&2
echo "done: $OUT"
