# PokeDinner patches

Based on [PokeDinner](https://git.eden-emu.dev/Franseven/PokeDinner-a-Eglantine-Fork) commit `1dd40d86df4bca1b68700091fe5ddb71a13162b2`.

`nx2-compiler.patch` adds the offline NX2 compiler, Ampere instruction fixes, native root constants, and regression tests for quad gradients and half-precision texture component order. Apply `scalar-modes.patch` after it to add signed and uniform halfword-to-float conversion and direct/indexed uniform byte loads. `reference-tools.patch` adds opt-in shader facts, frame capture, and CPU probes used to compare the native runtime with the emulator.

These patches use GPL-3.0-or-later, matching PokeDinner. They are built separately from the native runtime.

## Build the offline compiler

From the ouncenative root, choose an external source folder:

```sh
export POKEDINNER="$HOME/Dev/pokedinner"
git clone https://git.eden-emu.dev/Franseven/PokeDinner-a-Eglantine-Fork.git "$POKEDINNER"
git -C "$POKEDINNER" checkout 1dd40d86df4bca1b68700091fe5ddb71a13162b2
git -C "$POKEDINNER" apply "$PWD/patches/pokedinner/nx2-compiler.patch"
git -C "$POKEDINNER" apply "$PWD/patches/pokedinner/scalar-modes.patch"
cmake -S "$POKEDINNER" -B "$POKEDINNER/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DENABLE_QT=OFF -DENABLE_WEB_SERVICE=OFF -DYUZU_ROOM=OFF \
  -DYUZU_TESTS=OFF -DENABLE_WERROR=OFF
cmake --build "$POKEDINNER/build" --target nx2-offline
```

The compiler is written to `build/bin/nx2-offline`. Apply `reference-tools.patch` only if you need the emulator capture tools. The compiler and reference-tools patches apply to the pinned source revision; the scalar patch requires the compiler patch first.

## Scalar instruction regression

On macOS with Metal, `clang++`, `spirv-val`, and `spirv-cross` available, run:

```sh
python3 patches/pokedinner/tests/test_scalar_modes.py \
  "$POKEDINNER" "$POKEDINNER/build/bin/nx2-offline"
```

This builds the standalone CPU regression, generates ten synthetic native compute programs, compiles and validates their SPIR-V, translates them to MSL, and executes them with Metal validation enabled. It checks 524,320 CPU cases and 655,360 exact GPU values, including all signed/unsigned halfword values in both register halves and regular/uniform registers, plus aligned and unaligned byte loads. Output guard bytes detect writes outside the result buffer. No game assets are required. Add `--output PATH` to retain fixtures and results. The CPU test is also registered in PokeDinner's test target when `YUZU_TESTS` is enabled.

The encodings follow [Mesa NAK's SM70 encoder](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa/+/b1fe47e94409d81924c8663f58fac97e66ab4527/src/nouveau/compiler/nak/sm70_encode.rs): I2F signedness at bit 74, source width at bits 84–85, and LDC memory type at bits 73–75. Unsupported modes remain errors. The 30 archive programs that first failed on these scalar operations now advance to other unsupported instructions; this patch alone adds no complete game shaders.

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
