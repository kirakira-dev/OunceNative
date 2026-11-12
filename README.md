# ouncenative

A native Apple Silicon runtime for Nintendo Switch games, based on [nxnative](https://github.com/seedds/nxnative). This fork adds NX2 support for Pokémon Pokopia and Splatoon Raiders on macOS.

The game's ARM64 code runs on the CPU after instruction rewriting. The host implements the system calls and graphics APIs it needs. Shaders are translated ahead of time to Metal. This is **NOT** a "emnulator wrapper".

## Status

Full support for Pokopia, should be near identical to actual Ounce gameplay.

At 1080p, the latest build reached about 59 FPS in a short test and 38 to 41 FPS in a longer outdoor run. Specs: M4 Air 32GB, but in reality it only uses under 8GB in most situations. Sustained 60 FPS is still a work in progress. Geometry and tessellation coverage is incomplete, and the sky differs from the emulator reference. See [Pokopia notes](docs/pokopia.md).

This is a development project. You need your own game dump and keys.

Splatoon Raiders is very wip.

## Build

Clone:

```sh
git clone https://github.com/kirakira-dev/ouncenative.git
cd ouncenative
```

Build the Pokopia host on an Apple Silicon Mac with Xcode installed:

```sh
make -C dm/host GAME=TID_HERE (eg 0400A3A01EE4C000 for pokopia)
```

That builds the host executable. Running the game also requires extracted files, rewritten modules, and a matching shader package. Start with the [Pokopia setup notes](docs/pokopia.md). The shader compiler patches are in [patches/pokedinner](patches/pokedinner).

For a reusable Mac build command across Switch and Switch 2 profiles, see the [native Mac build workflow](docs/mac-port.md). `python3 scripts/port.py profiles` lists profiles; `plan` shows the stages and `build` produces a signed app with a build report.

The inherited iOS build scripts and game profiles are still available. See [iPhone and iPad](docs/ios.md) and [development notes](docs/development.md).

## Credits

- [nxnative](https://github.com/seedds/nxnative) and [d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile): native execution, instruction rewriting, host services, and the Metal backend, i "borrowed" a lot of code
- [PokeDinner](https://git.eden-emu.dev/Franseven/PokeDinner-a-Eglantine-Fork), Eden, and yuzu: NX2 shader translation and emulator reference.
- Ryujinx: the Maxwell shader translator and system-service reference.
- [Atmosphère](https://github.com/Atmosphere-NX/Atmosphere): Horizon kernel behavior.
- [LibHac](https://github.com/Thealexbarney/LibHac): game extraction and update layering.
- [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross): SPIR-V to Metal translation.
- deko3d: texture layout calculations.

Bundled libraries and their licenses are listed in [dm/third_party](dm/third_party/README.md).

## License

The native runtime retains its [MIT license](LICENSE). PokeDinner patches use GPL-3.0-or-later; see [their license](patches/pokedinner/LICENSE).
