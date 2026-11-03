# Pokopia on macOS

The development profile is `0400A3A01EE4C000`, using update `v327680` and SDK 20.5.25. Other builds need their own module IDs and offsets.

## Tested so far

The November 2, 2026 build passed the tutorial and first outdoor-area checks. Its shader package has 148,866 variants and 105,036 distinct Metal libraries. The known shader map has 131,001 entries. These counts describe the extracted archive and captured programs, not every shader the game may generate at runtime.

Texture-view caching, GPU vertex fetching, and 346 prewarmed render pipelines are enabled in the tested app. A short 1080p outdoor sample reached about 59 FPS. The longer run measured 38 to 41 FPS, with background macOS activity present.

One geometry shader still has unresolved output defaults. Actual in-game geometry and tessellation coverage is incomplete. The uncovered sky also differs from the emulator reference. Full-world rendering correctness and stable 60 FPS have not been established.

## Tools

Use an Apple Silicon Mac with Xcode and the Metal compiler installed. The NX2 path uses Metal 3.2 shader features and the host includes Metal 4 support.

```sh
brew install cmake ninja zstd spirv-tools spirv-cross glslang
python3 -m venv .venv
.venv/bin/pip install lz4 capstone fonttools z3-solver
```

Keep the dump, keys, extracted files, and build caches outside the repository. The inherited [extraction guide](agents/01-extract.md) and [manual build steps](development.md) describe the native runtime setup. The old IPA script does not build a complete Pokopia package.

Build the NX2 offline compiler using [patches/pokedinner](../patches/pokedinner/README.md). The native tools are in `dm/gfx/tools`:

| Tool | Purpose |
|---|---|
| `nx2_shader_extract.py` | Extract GLSLC shader objects from RDB archives into SQLite. |
| `nx2_glslc.py` | Read resource facts from GLSLC reflection. |
| `dmsh_nx2_archive.py` | Translate the extracted archive to SPIR-V. |
| `dmsh_nx2_metal_archive.py` | Compile ordinary stages to Metal. |
| `dmsh_nx2_vertex_archive.py` | Build vertex-capture variants. |
| `dmsh_nx2_tess_archive.py` | Build hull and domain variants. |
| `dmsh_nx2_build.py` | Build shaders captured from the native host. |
| `dmsh_nx2_geometry_archive.py` | Build supported geometry programs. |
| `dmsh_nx2_export.py` | Combine archives and captures into a runtime package. |

Each command accepts `--help`. The archive runners expect `shaders-v2.sqlite` in the parent of each translation output folder unless `--shaders` is set. The build is still a multi-step process: extract, translate, compile, resolve rejected programs, export, and validate the package. Do not discard rejected shaders or substitute guessed resource types.

Use `DM_GAME=0400A3A01EE4C000` for shader tools. The exporter updates the profile's shader map, chain header, and C1 index. Build the host after exporting:

```sh
make -C dm/host GAME=0400A3A01EE4C000
```

The checked-in shader tables record the tested build. A fresh export replaces them with the tables for your compiler and inputs. Source fingerprints are part of the cache identity, so old archives may need to be rebuilt after a tool changes.

## Tests

These Python and GPU deswizzle tests use synthetic inputs:

```sh
DM_GAME=0400A3A01EE4C000 .venv/bin/python -m unittest discover -s dm/gfx/tests -p 'test_*.py'
make -C dm/gfx/tex/tests gpu-check
```

The full texture suite (`make -C dm/gfx/tex/tests run`) also needs the D2R sample pairs described in its `fetch_samples.py`. GPU tests under `dm/gfx/tests` need Metal. `t_nx2_package` checks a generated package's reflection, libraries, and entry points. A successful package load does not establish correct rendering in every scene.
