# PokeDinner patches

Based on [PokeDinner](https://git.eden-emu.dev/Franseven/PokeDinner-a-Eglantine-Fork) commit `1dd40d86df4bca1b68700091fe5ddb71a13162b2`.

`nx2-compiler.patch` adds the offline NX2 compiler, Ampere instruction fixes, native root constants, and regression tests for quad gradients and half-precision texture component order. Apply `scalar-modes.patch` after it to add signed and uniform halfword-to-float conversion and direct/indexed uniform byte loads, then `uniform-clamp.patch` to recognize jump-table bounds across independent integer additions. `runtime-textures.patch` lets the native Metal binding transform select sampled numeric formats from live descriptors. `reference-tools.patch` adds opt-in shader facts, frame capture, and CPU probes used to compare the native runtime with the emulator.

These patches use GPL-3.0-or-later, matching PokeDinner. They are built separately from the native runtime.

## Build the offline compiler

From the ouncenative root, choose an external source folder:

```sh
export POKEDINNER="$HOME/Dev/pokedinner"
git clone https://git.eden-emu.dev/Franseven/PokeDinner-a-Eglantine-Fork.git "$POKEDINNER"
git -C "$POKEDINNER" checkout 1dd40d86df4bca1b68700091fe5ddb71a13162b2
git -C "$POKEDINNER" apply "$PWD/patches/pokedinner/nx2-compiler.patch"
git -C "$POKEDINNER" apply "$PWD/patches/pokedinner/scalar-modes.patch"
git -C "$POKEDINNER" apply "$PWD/patches/pokedinner/uniform-clamp.patch"
git -C "$POKEDINNER" apply "$PWD/patches/pokedinner/runtime-textures.patch"
cmake -S "$POKEDINNER" -B "$POKEDINNER/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DENABLE_QT=OFF -DENABLE_WEB_SERVICE=OFF -DYUZU_ROOM=OFF \
  -DYUZU_TESTS=OFF -DENABLE_WERROR=OFF
cmake --build "$POKEDINNER/build" --target nx2-offline
```

The compiler is written to `build/bin/nx2-offline`. Apply `reference-tools.patch` only if you need the emulator capture tools. The compiler and reference-tools patches apply to the pinned source revision; apply the scalar and uniform-clamp patches in the order shown above.

## Scalar instruction regression

On macOS with Metal, `clang++`, `spirv-val`, and `spirv-cross` available, run:

```sh
python3 patches/pokedinner/tests/test_scalar_modes.py \
  "$POKEDINNER" "$POKEDINNER/build/bin/nx2-offline"
```

This builds the standalone CPU regression, generates ten synthetic native compute programs, compiles and validates their SPIR-V, translates them to MSL, and executes them with Metal validation enabled. It checks 524,320 CPU cases and 655,360 exact GPU values, including all signed/unsigned halfword values in both register halves and regular/uniform registers, plus aligned and unaligned byte loads. Output guard bytes detect writes outside the result buffer. No game assets are required. Add `--output PATH` to retain fixtures and results. The CPU test is also registered in PokeDinner's test target when `YUZU_TESTS` is enabled.

The encodings follow [Mesa NAK's SM70 encoder](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa/+/b1fe47e94409d81924c8663f58fac97e66ab4527/src/nouveau/compiler/nak/sm70_encode.rs): I2F signedness at bit 74, source width at bits 84–85, and LDC memory type at bits 73–75. Unsupported modes remain errors. The 30 archive programs that first failed on these scalar operations now advance to other unsupported instructions; this patch alone adds no complete game shaders.

## Uniform clamp regression

With the same macOS tools, run:

```sh
python3 patches/pokedinner/tests/test_uniform_clamp.py \
  "$POKEDINNER" "$POKEDINNER/build/bin/nx2-offline"
```

The patch lets the existing unsigned compare/select clamp recognition cross ordinary immediate integer additions, which cannot change uniform registers or predicates. The regression checks seven recognition cases, including intervening uniform writes and branches that must prevent recognition. Three native compute programs exercise jump-table selection, independent addition/subtraction side effects, and unsigned `UINT_MAX` clamping through SPIR-V validation and Metal execution. All 196,608 results and their side effects match, with output guard bytes intact. Twelve archive programs advance from failed indirect-branch tracking to missing resource facts; no complete game shader is added by this patch alone. `--output PATH` retains generated fixtures.

## Metal tessellation wrapper

Build this helper from the ouncenative root:

```sh
clang++ -std=c++17 -O2 dm/gfx/tools/dmsh_nx2_msl.cpp \
  -I"$(brew --prefix spirv-cross)/include" \
  -L"$(brew --prefix spirv-cross)/lib" \
  -lspirv-cross-msl -lspirv-cross-glsl -lspirv-cross-core \
  -o /tmp/nx2-msl
```

Pass the resulting path to the archive tools' `--wrapper` option.

## Runtime sampled texture formats

`nx2_bnsh_jobs.py --runtime-texture-formats` sets the offline job's `defer_sampled_texture_formats` option. It keeps sampled values as raw float-shaped registers and marks the output metadata with `deferred_sampled_texture_formats: 1`. This SPIR-V requires `dmsh_nx2_build.py`'s Metal transform; it is not a standalone float-format assumption. The transform emits float, unsigned, and signed texture arguments and selects the actual operation using the bound NVN descriptor. Integer bits remain unchanged, including values that look like floating-point NaNs. Implicit 2D fragment samples also obtain rectangle coordinate behavior from the texture or its view.

Texture dimension queries, 1D/buffer distinctions, storage image formats, and non-fragment implicit sampling still require facts or reject unsupported translation. The default compiler mode retains its captured-fact behavior. No placeholder descriptors or numeric formats are supplied to archive jobs.

The native regression runs through both Metal 4 and legacy argument encoding:

```sh
make -C dm/gfx/tests GAME=0400380020056000 t_runtime_textures
python3 dm/gfx/tests/test_runtime_textures.py
```

It checks 84 descriptor rebindings across 2D, 2D array, cube array, and 3D textures in seven numeric formats; 16,128 exact texture-operation values and 10,752 output guard words. It exercises rectangle texture/view coordinates, argument reuse, layer/face/depth selection, signed extension, and invalid reflection metadata. The compiler patch also reproduces all three modified source files from the preceding patch set. In the owned Raiders archive, this path adds 9,138 programs through SPIR-V validation and Metal compilation, including 98 of the 103 recovered programs missing from older gameplay logs; those other five still reject missing descriptor facts.
