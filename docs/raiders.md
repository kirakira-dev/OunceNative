# Splatoon Raiders on macOS

The development profile is `0400380020056000`, using update `v65536`, SDK 21.4.4, and NVN 231.39. Module IDs are recorded in `dm/games/0400380020056000/game.tsv`. The base build is identified, but runtime testing uses the update.

The tested route covers native boot, menus, character creation, save reload, the airship conversations, and the first island. Virtual motion input completes the aiming tutorial, walking collects the first shard, and firing paints the ground. These checks also passed in the packaged app with an isolated save. The local package currently contains 1,274 translated shader programs. It is built from observed programs and does not cover the complete BFSHA archive or unseen scenes.

The renderer fixes the opening scene's black output, swapped half-texture components, missing player skin, and command-list corruption. A later black-frame failure was traced to a full conditional-render table: dropped timestamp reports let repeated clears erase the scene. Dynamic report tracking fixes that reproduced failure. Other terrain differences and later areas still need checking against console output. Audio produces nonzero output, but listening and synchronization checks remain incomplete.

Handheld remains the default. In docked mode, the observed main scene renders at 2560 x 1440 and the game outputs 3840 x 2160, but the island route still has severe stalls. The tested M4 does not sustain 60 FPS. See [rendering and performance](performance.md) for measured changes and limits.

## Controls

The default keyboard controls are WASD to move, IJKL for the right stick, Z to confirm, X to jump, O to fire, Q for ZL, and V for Y. Hold the right mouse button and drag to aim with virtual motion input. Option plus an arrow key adjusts the same motion input in small steps. Keyboard and controller button mappings are available in the app's settings with Command-comma. Physical controller motion sensors are not connected yet.

## Build from an extracted dump

Use Apple Silicon, Xcode with the Metal compiler, and the dependencies in [Pokopia setup](pokopia.md#tools). Build the separately licensed [NX2 compiler](../patches/pokedinner/README.md) first. Keep the dump, captures, shaders, saves, and build outputs outside this repository.

From the repository root, set paths for your extracted update and an external work folder:

```sh
export DM_GAME=0400380020056000
export RAIDERS_DUMP="$HOME/ROMs/Raiders"
export RAIDERS_WORK="$RAIDERS_DUMP/ouncenative-work"
export POKEDINNER="$HOME/Dev/pokedinner"
mkdir -p "$RAIDERS_WORK/build/patched_v65536" "$RAIDERS_WORK/build/font" \
  "$RAIDERS_WORK/run/save" \
  "$RAIDERS_WORK/run/temp" "$RAIDERS_WORK/shader-capture" "$RAIDERS_WORK/shader-facts"
for module in main subsdk0 sdk; do
  DM_RULESET=native python3 dm/tools/patch_nso.py \
    "$RAIDERS_DUMP/updates/65536/exefs/$module" \
    "$RAIDERS_WORK/build/patched_v65536" "$module"
done
python3 dm/tools/make_ext_font.py "$RAIDERS_WORK/build/font/nintendo_ext.ttf"
make -C dm/host GAME="$DM_GAME"
```

The tested update directory contains the complete RomFS. If your extractor produces only changed files, merge it over the base before running.

## Capture and compile shaders

Set the native host's capture directories when exploring a scene:

```sh
export DM_ROOT="$RAIDERS_WORK/run"
export DM_ROMFS="$RAIDERS_DUMP/updates/65536/romfs"
export DM_SAVE="$RAIDERS_WORK/run/save" DM_TEMP="$RAIDERS_WORK/run/temp"
export DM_FONT_DIR="$RAIDERS_WORK/build/font"
export DM_MSL_DIR="$RAIDERS_WORK/build/shader-libraries"
export DM_NVN_SHMAP="$PWD/dm/games/$DM_GAME/shader_map.tsv"
export DM_NVN_SHDUMP="$RAIDERS_WORK/shader-capture"
export DM_NVN_FACTDUMP="$RAIDERS_WORK/shader-facts"
DM_WINDOW=1 DM_AUDIO=1 DM_OPMODE=0 dm/host/dmhost "$RAIDERS_WORK/build/patched_v65536"
```

Programs without libraries cannot render correctly during capture. After stopping the host, turn the captured resource facts into compiler jobs, then build the Metal package:

```sh
python3 dm/gfx/tools/nx2_native_jobs.py \
  "$RAIDERS_WORK/shader-capture" "$RAIDERS_WORK/shader-facts" \
  "$POKEDINNER" "$RAIDERS_WORK/shader-capture/jobs.json"
python3 dm/gfx/tools/dmsh_nx2_build.py \
  "$RAIDERS_WORK/shader-capture/jobs.json" "$POKEDINNER/build/bin/nx2-offline" \
  "$POKEDINNER" "$RAIDERS_WORK/build/shader-libraries"
make -C dm/host GAME="$DM_GAME"
```

The converter validates capture hashes and rejects unknown texture formats. The builder records compiler and source fingerprints, regenerates the profile's shader map and C1 index, and reports rejected stages. Review those results before rerunning. New scenes can require additional captures and rebuilds.

## Validation

The regression tests cover retained command memory, copied command lists, compact list re-recording, graphics and compute root constants, integer color outputs, missing fragment varyings, compressed texture block rendering, packaged texture aliases, and visibility-buffer rollover. The motion test checks the 96-byte sensor ABI, sample timing, orientation, angular velocity, and gravity. The separately built compiler has a 120-case half-texture packing test; the previous packing order fails it.

To check a generated shader package against Metal:

```sh
make -C dm/gfx/tests GAME="$DM_GAME" t_nx2_package
RAIDERS_CHAIN=$(python3 dm/gfx/tools/dmsh_chain.py)
MTL_DEBUG_LAYER=1 dm/gfx/tests/t_nx2_package "$DM_MSL_DIR/b-$RAIDERS_CHAIN"
```

`DM_NVN_SHOT=1500:/tmp/raiders.png` captures a presented frame. Add `DM_NVN_SHOT_OUT=1920x1080` to apply the game's crop and display scaling. Without it, the diagnostic captures the complete swapchain texture, including unused space outside the handheld crop. A successful library validation does not establish correct rendering in every scene.

For a sampled-texture diagnostic, use `DM_NVN_TEXSAMPLE=<shader key>:<register>` with `DM_NVN_TEXDUMP=sample=250:/tmp/texture-%d.png`. This captures that binding on the first matching draw at or after frame 250. Use `*` in place of the register to capture all sampled textures for that shader.

## Package the development app

After building and validating a shader package:

```sh
RAIDERS_CHAIN=$(DM_GAME="$DM_GAME" python3 dm/gfx/tools/dmsh_chain.py)
GAME="$DM_GAME" W="$RAIDERS_WORK" APP_NAME="Splatoon Raiders" \
  ROMFS="$DM_ROMFS" MSL="$DM_MSL_DIR/b-$RAIDERS_CHAIN" \
  scripts/build_mac_app.sh "$RAIDERS_DUMP/Splatoon Raiders.app"
```

The bundle includes locally rewritten modules and compiled shaders. Its saves and settings live under `~/Library/Application Support/Splatoon Raiders`. The profile defaults to handheld resolution. `DM_OPMODE=1` in that folder's `env.txt` selects docked resolution; `DM_OPMODE=0` restores handheld resolution. The same choice is available in the app's settings.
