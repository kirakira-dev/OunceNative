# PokeDinner patches

Based on [PokeDinner](https://git.eden-emu.dev/Franseven/PokeDinner-a-Eglantine-Fork) commit `1dd40d86df4bca1b68700091fe5ddb71a13162b2`.

`nx2-compiler.patch` adds the offline NX2 compiler, Ampere instruction fixes, native root constants, and regression tests for quad gradients and half-precision texture component order. `reference-tools.patch` adds opt-in shader facts, frame capture, and CPU probes used to compare the native runtime with the emulator.

These patches use GPL-3.0-or-later, matching PokeDinner. They are built separately from the native runtime.

## Build the offline compiler

From the ouncenative root, choose an external source folder:

```sh
export POKEDINNER="$HOME/Dev/pokedinner"
git clone https://git.eden-emu.dev/Franseven/PokeDinner-a-Eglantine-Fork.git "$POKEDINNER"
git -C "$POKEDINNER" checkout 1dd40d86df4bca1b68700091fe5ddb71a13162b2
git -C "$POKEDINNER" apply "$PWD/patches/pokedinner/nx2-compiler.patch"
cmake -S "$POKEDINNER" -B "$POKEDINNER/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DENABLE_QT=OFF -DENABLE_WEB_SERVICE=OFF -DYUZU_ROOM=OFF \
  -DYUZU_TESTS=OFF -DENABLE_WERROR=OFF
cmake --build "$POKEDINNER/build" --target nx2-offline
```

The compiler is written to `build/bin/nx2-offline`. Apply `reference-tools.patch` only if you need the emulator capture tools. Both patches apply to the same pinned source revision.

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
