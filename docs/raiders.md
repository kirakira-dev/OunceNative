# Splatoon Raiders on macOS

The development profile is `0400380020056000`, using update `v65536`, SDK 21.4.4, and NVN 231.39. Module IDs are recorded in `dm/games/0400380020056000/game.tsv`. The base build is identified, but runtime testing uses the update.

The tested route covers native boot, menus, character creation, save reload, the airship conversations, the first island, and Piel Coast on Erpp Island. Virtual motion input completes the aiming tutorial. The Piel Coast test exercises movement, swimming, crate destruction, shard collection, enemy damage, life loss, recovery, and the companion bot with an isolated save. The local package currently contains 9,991 translated shader programs, including 1,273 fragments with alpha-test support. It combines 2,168 observed programs with 7,823 archive programs that compile without external resource facts. The archive scan found 20,036 unique programs in 698 BNSH containers; 1,809 overlaps with retained captures match byte for byte. Coverage remains incomplete: 157 older-log keys still have no library, although the scan recovered the bytes for 151 of them. The broader archive preflight also rejects programs needing resource facts or unsupported compiler operations.

The renderer fixes the opening scene's black output, swapped half-texture components, missing player skin, and command-list corruption. A later black-frame failure was traced to a full conditional-render table: dropped timestamp reports let repeated clears erase the scene. Dynamic report tracking fixes that reproduced failure. Alternating dark terrain and sky were separately traced to premature reuse of a cached command list's overflow storage; reclamation now follows actual command writes. Consecutive first-island captures preserve the lighting after this fix. Adding the missing Piel Coast programs removes the reproduced black patches on props and enemies. Alpha-reference commands are now recorded and replayed, and fragments implement all eight alpha comparisons before color/depth exports. Later areas, including Piel Coast's bright fog and pale terrain, still need checking against console output. Audio produces nonzero output, but listening and synchronization checks remain incomplete.

Handheld remains the default. The app presents at 3840 x 2160 with selectable upscaling and scene resolution. The latest six-minute normal-power test uses a 720p scene, 1080p HUD, and Bicubic 4K output; its later island section averages about 58.5 FPS on the tested M4. It reaches 60 FPS with slower frames under sustained load, so a locked 60 is not established. See [rendering and performance](performance.md) for measurements and limits.

## Resolution

Open Settings (Command-comma) → General. **Output resolution** selects the window/display size or a fixed 4K drawable. **Handheld scene** selects 1080p (original), 900p, or 720p (faster); the HUD remains 1080p before final presentation scaling. **Upscaling** selects MetalFX, Bicubic, or Bilinear. These settings apply after restarting. This provides upscaled 4K output, not native 4K scene rendering. The scene setting applies only in handheld mode.

The equivalent environment settings are `DM_OUTPUT_RES=3840x2160`, `DM_SCENE_HEIGHT=720`, `DM_OPMODE=0`, and `DM_UPSCALER=bicubic`; `DM_UPSCALER=metalfx` selects MetalFX instead. The bundled overlays are generated locally from the owner's dump and do not modify it. Optional `DM_GAME_UPSCALER=metalfx` also replaces the identified game's spatial reconstruction filter in compatible dispatches; it uses MetalFX rather than matching that neural filter pixel for pixel.

The macOS package defaults to `DM_PRESENT_LINK=0`, acquiring drawables directly with layer vsync enabled. This avoids the repeated picture freezes observed when display-link callbacks stopped while the game continued. Display-link mode remains available through `DM_PRESENT_LINK=1` for diagnostics.

## Controls

The default keyboard controls are WASD to move, IJKL for the right stick, Z to confirm, X to jump, O to fire, Q for ZL, and V for Y. Click the game to capture the mouse for virtual gyro aiming, then move it to look, left-click to fire, and right-click to swim. Escape releases the pointer; Command-Shift-M toggles capture. Opening Settings or switching away also releases it. Without capture, right-button dragging still aims. Option plus an arrow key adjusts the same motion input in small steps. Keyboard and controller button mappings are available in the app's settings with Command-comma. Physical controller motion sensors are not connected yet.

## Music

Open Settings (Command-comma) → General → **Music**. The switch applies immediately and persists across launches; `DM_MUSIC=0` also starts with music muted. Sound controls all audio separately and still requires a restart.

The v65536 hooks mute the final volume of eight music groups: background, scene-transition, cutscene, world and minigame music, plus musical jingles and fanfares. Dialogue, ambience, weapon effects and ordinary UI sounds keep their own mix. Music playback continues silently, so enabling it restores the current playback position and game-controlled fades. The setting requires the matching patched main module with both music observation gates.

## Mods

Open **Mods** in the macOS menu bar while the game is active. The menu contains Player Flight / Noclip (Command-Shift-F), Swim Everywhere (Command-Shift-S), Infinite Ink (Command-Shift-I), Rapid Fire (Command-Shift-R), Weapon Switcher, Disable All Mods (Command-Shift-0), and Mod Controls. Mods start disabled unless explicitly requested through `DM_RAIDERS_MODS=ink,rapid,fly,swim`.

Flight moves the player relative to the live camera: forward follows both its yaw and pitch, and sideways follows its right vector. R ascends, L descends, and left-stick click boosts. Mouse gyro and the right stick control the camera while flying. Default keys are WASD, U/E for ascent/descent, F for boost, and IJKL for camera movement. Disabling flight returns movement to the game. Infinite Ink refills both reserves; Rapid Fire removes the shooter's repeat delay in its active firing check. Other weapon types are not covered by the rapid-fire hook.

Swim Everywhere uses the same camera-relative movement while holding ZL (Q or the captured right mouse button). It permits movement over dry ground and through the air; R/L and left-stick click still control height and boost. Releasing ZL restores normal movement. Flight takes priority when both toggles are enabled. The game still controls its transformation animation and tutorial restrictions.

Weapon Switcher lists 122 main-weapon variants from this build’s RSDB, matched to the executable’s numeric weapon enum. An isolated first-island sweep loaded all 122 and captured 384 additional shader programs; swim and ink-effect checks added another 35. Requests run through the game’s equipment path on the player update thread. **Game Loadout**, or **Disable All Mods**, restores the weapon held before the override for that player. `DM_RAIDERS_WEAPON=Blaster_A` requests an initial override by RSDB row name. Weapon assets load asynchronously; this is a runtime override, not an inventory unlock.

The hooks require the exact v65536 main build and verify the local player's ownership and object types before writing. Rebuild the patched main module after updating the host; the menu stays disabled if any of the four required mod observation gates are absent. All 122 variants passed an equipment-load sweep in the first island; full combat behavior for every variant and later scenes remain unverified. Flight bypasses physical movement constraints, but damage volumes and story triggers remain active, including below the ground. It does not grant invulnerability.

## Experimental ray tracing

Ray tracing is **off by default**. Set `DM_RAYTRACE=ao` in the launch environment or enable **Ray-traced ambient occlusion (experimental)** under Settings → General, then restart. `DM_RAYTRACE=off` disables it. It requires an Apple GPU with hardware ray tracing (Apple GPU family 9 or later).

This mode captures opaque triangles from the game's vertex draws, builds a Metal acceleration structure, and traces eight ambient-occlusion rays per covered pixel at half resolution. A bilateral composite applies contact shading before tone mapping and the HUD. It does not implement ray-traced reflections, global illumination, or full path tracing. Geometry culled by the game, alpha-tested surfaces, unsupported primitive layouts, and indirect draws may be absent. A primary-ray depth check rejects shading where captured geometry does not match the visible surface.

The airship replay traces about 333,000 triangles from 203 draws. It adds substantial CPU/GPU cost and shader compilation at startup; the user reported increased lag and requested it disabled. Synthetic Metal tests cover real occlusion, depth mismatch rejection, alpha preservation, orientation, instancing, and unchanged raster output. The larger island scene remains experimental and has not received equivalent visual validation.

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

### Archive coverage

The archive scanner requires the Python `zstandard` package. It extracts NX2 programs from BNSH containers, including those embedded in particle effects, layouts, zstd files, and recursive SARC archives. It validates stage declarations and section bounds, and hashes the exact control, used instructions, and C1 bytes with the same key as the runtime. It does not include allocation padding in that key.

```sh
python3 dm/gfx/tools/nx2_bnsh_extract.py "$DM_ROMFS" \
  --output "$RAIDERS_WORK/archive-shaders"
python3 dm/gfx/tools/nx2_bnsh_jobs.py "$RAIDERS_WORK/archive-shaders" \
  "$POKEDINNER/build/bin/nx2-offline" "$RAIDERS_WORK/archive-preflight" \
  --exclude-map "dm/games/$DM_GAME/shader_map.tsv"
```

The scanner also accepts additional files, such as already decompressed module images. Its index records the source container and offsets for each program. The preflight verifies those extracted bytes and supplies no external texture, descriptor, or root-constant facts. `ready-jobs.json` contains only programs accepted by the strict compiler; `summary.json` records the rejected cases. Stripped archive reflection cannot establish the missing resource types, so these rejections still require runtime captures or further verified format support.

Keep the current captured programs when incorporating archive jobs into a package, and validate the complete merged package before installing it. `dmsh_nx2_build.py --workers 6` converts and compiles independent programs concurrently; its default remains one worker. Run `python3 dm/gfx/tests/test_nx2_bnsh.py` to check the archive reader's native keys, bounds rejection, nested containers, and strict selection of successful jobs.

## Validation

The regression tests cover retained command memory, copied command lists, compact list re-recording, graphics and compute root constants, integer color outputs, missing fragment varyings, compressed texture block rendering, packaged texture aliases, and visibility-buffer rollover. The motion test checks the 96-byte sensor ABI, sample timing, orientation, angular velocity, and gravity. The separately built compiler has a 120-case half-texture packing test; the previous packing order fails it. Its [scalar instruction regression](../patches/pokedinner/README.md#scalar-instruction-regression) checks 524,320 CPU cases and 655,360 exact Metal results for halfword-to-float conversion and uniform byte loads. The scalar fixes expose later compiler limitations in 30 archive programs, so they do not yet expand complete shader coverage.

The alpha-test regression runs 96 GPU cases against 6,912 color/depth values. It checks every comparison, equality boundaries, signed zero, NaN, recorded reference changes, multiple fragment returns, and both orders of the retained-source transformations. Run it with `make -C dm/gfx/tests GAME="$DM_GAME" t_alpha_test` followed by `python3 dm/gfx/tests/test_alpha_test.py`. The November 12 package validation loads all 9,991 reflection records and 17,994 native functions under Metal validation. The archive update reaches the rendered title without error diagnostics through 14,700 reported frames. Gameplay was not repeated with this final package because UI automation timed out after closing Settings; the earlier Piel Coast checks used smaller captured packages. These checks establish the tested API and package behavior, not complete game coverage.

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

The bundle includes locally rewritten modules and compiled shaders. Packaging Raiders also requires the Python `byml` package to generate the optional 720p/900p scene overlays. Its saves and settings live under `~/Library/Application Support/Splatoon Raiders`. The profile defaults to handheld resolution. `DM_OPMODE=1` in that folder's `env.txt` selects docked resolution; `DM_OPMODE=0` restores handheld resolution. The same choice is available in the app's settings.
