#!/bin/bash
# Compatibility entry point for an already-built host and shader package.
# For the full Mac build command, use scripts/port.py build --help.
set -euo pipefail
: "${GAME:?GAME=<profile id or directory>}" "${W:?W=<work folder>}"
REPO=$(cd "$(dirname "$0")/.." && pwd)
PROFILE=$(python3 "$REPO/dm/games/game.py" dir "$GAME")
VER=${VER:-$(python3 "$REPO/dm/games/game.py" "$GAME" package)}
NAME=${APP_NAME:-$(python3 "$REPO/dm/games/game.py" "$GAME" name)}
CHAIN=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$PROFILE/dmsh_chain.h")
GFX=$(python3 - "$PROFILE" "$REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[2] + '/dm/games')
import game
print(game.load(sys.argv[1]).get('graphics', 'nvn'))
PY
)
if [ "$GFX" = vulkan ]; then
    DEFAULT_MSL="$W/shader/vk"
else
    DEFAULT_MSL="$W/build/cache/metal_shader_cache/b-$CHAIN"
fi
ARGS=("${1:-$W/../$NAME.app}" --profile "$PROFILE" --version "$VER"
    --host "${HOST:-$REPO/dm/host/dmhost}" --name "$NAME"
    --patched "${PATCHED:-$W/build/patched_$VER}"
    --romfs "${ROMFS:-$W/data/$VER/RomFS}" --shaders "${MSL:-$DEFAULT_MSL}"
    --font "${FONT:-$W/build/font/nintendo_ext.ttf}")
ICON=${DM_ICON:-}
if [ -z "$ICON" ]; then
    for CANDIDATE in "$W/data/$VER/icon.jpg" "$W/data/v0/icon.jpg"; do
        if [ -f "$CANDIDATE" ]; then ICON=$CANDIDATE; break; fi
    done
fi
if [ -n "$ICON" ]; then ARGS+=(--icon "$ICON"); fi
if [ -n "${AOC:-}" ]; then ARGS+=(--aoc "$AOC"); fi
if [ "${REPLACE:-0}" = 1 ]; then ARGS+=(--replace); fi
if [ "${ALLOW_INCOMPLETE_SHADERS:-0}" = 1 ]; then ARGS+=(--allow-incomplete-shaders); fi
if [ "${DRY_RUN:-0}" = 1 ]; then ARGS+=(--dry-run); fi
exec python3 "$REPO/scripts/mac_bundle.py" "${ARGS[@]}"
