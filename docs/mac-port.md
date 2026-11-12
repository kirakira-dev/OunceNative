# Native Mac build workflow

`scripts/port.py` builds a standalone Mac app from a game profile and your own game files. It shares the existing ARM64 rewriter, host, and shader compilers across Switch (`nx`) and Switch 2 (`nx2`) profiles. It requires Apple Silicon, macOS 26, Xcode with the Metal tools, and the dependencies of the selected shader compiler. NSP extraction also requires .NET and your own keys.

A profile describes known builds and their resource layouts. Listing a profile or successfully signing an app does not establish full gameplay compatibility. New titles still need the [survey and bring-up work](agents/README.md); this command does not infer missing shader resource types or implement missing services.

## Inspect and build

```sh
python3 scripts/port.py profiles
python3 scripts/port.py build --help
```

For extracted files and an existing shader package:

```sh
python3 scripts/port.py build \
  --profile 0400380020056000 \
  --work "/path/to/Raiders-work" \
  --extracted "/path/to/update-extraction" \
  --shaders "/path/to/shaders/b-CHAIN" \
  --name "Splatoon Raiders" \
  -o "/path/to/Splatoon Raiders.app"
```

The extraction directory contains `ExeFS/` and `RomFS/`. The command checks the NSO build IDs, rewrites the modules, builds the native host, generates the extension font if needed, and packages the result. `--version v65536` chooses a registered version; otherwise the profile's `package` value applies. `--patched /path/to/rewritten` reuses existing rewritten modules after checking their build IDs, preserving local mod cuts. `--font`, `--icon`, `--bundle-id`, and `--aoc` override their respective inputs. `--name` also selects the app's Application Support folder, so changing it starts with separate saves and settings.

Replace `build` with `plan` to print the selected profile, paths, and build stages without writing files. `plan` checks argument consistency; it does not compile or validate every input. `--profile` also accepts a directory named after the title ID. An external profile takes effect even when the repository already has a profile with that same ID.

For NSPs, replace `--extracted` with:

```sh
--nsp-dir "/path/to/one-game-NSPs" --keys "/path/to/prod.keys"
```

The folder must contain one game's base NSP and the registered update versions needed by the build. DLC in the folder is extracted and bundled. Extraction and build outputs stay under `--work`, which must be outside the source repository. The command retains extracted files for subsequent builds. Keys are used for extraction and are not included in the app or build report.

## Shader inputs

| Profile | Existing package | Compile during the build |
|---|---|---|
| Switch NVN | `--shaders /path/to/b-CHAIN` | Omit `--shaders`; extracts and translates the profile's shader versions with the existing Maxwell pipeline |
| Switch Vulkan | `--shaders /path/to/vk` | Omit `--shaders`; translates SPIR-V and captures generated shaders when the profile requires them |
| Switch 2 NVN | `--shaders /path/to/b-CHAIN` | Supply `--nx2-jobs`, `--compiler`, and `--compiler-source` |

For Switch 1 builds using extracted files, provide every version in `shader_versions`. Extra versions can be under `WORK/data/VERSION` or passed as `--shader-source VERSION=/path/to/extraction`. NSP builds extract these versions automatically. Runtime shader capture uses temporary save and working directories.

For Switch 2, use a complete job set with measured resource facts and the [patched NX2 compiler](../patches/pokedinner/README.md):

```sh
--nx2-jobs "/path/to/jobs.json" \
--compiler "/path/to/nx2-offline" \
--compiler-source "/path/to/patched-compiler-checkout" \
--workers 4
```

NX2 compilation updates only the build's profile snapshot. Rejected jobs or omission of previously known shader keys stop the build. For incremental captures, merge the new package with the existing package before passing it through `--shaders`; a small capture job set is not a replacement for all known shaders.

By default packaging requires a library and reflection file for every shader-map entry, matching module build IDs, the RomFS marker, and the extension font. `--allow-incomplete-shaders` permits a diagnostic app and records the omissions; it does not fix them. These checks do not replace Metal pipeline tests or gameplay validation.

## Outputs and replacement

Each invocation gets `WORK/builds/TIMESTAMP/` containing the exact profile snapshot, host, logs, and `status.json`. Failed builds retain their stage and error. A successful build also writes `WORK/last-build.json`; the app contains `Contents/Resources/native-build.json` with module and profile hashes and shader coverage.

The app is assembled in a temporary sibling directory and its ad-hoc signature is checked before publication. An existing output is refused unless `--replace` is passed. Replacement retains the previous app beside it as `NAME.app.backup-TIMESTAMP`. Saves and settings under Application Support are separate from app replacement.

`scripts/build_mac_app.sh` remains available for packaging an already-built host. It now supports external profiles and Vulkan packages through the same checks. Set `REPLACE=1` to keep and replace an existing app, `DRY_RUN=1` to validate without packaging, or `ALLOW_INCOMPLETE_SHADERS=1` for a diagnostic app. Its other environment variables remain supported.

## Validation

```sh
python3 -m unittest discover -s scripts/tests
```

The tests cover external profiles, missing and mismatched shaders, module build mismatches, Vulkan/DLC layout, failed signing, replacement rollback, build reports, and read-only plans. A Raiders build with a same-ID external profile was compiled, packaged with 10,019 libraries, signed, and launched to its fresh-save difficulty selection on macOS. That smoke test reused extracted assets and rewritten modules. Fresh NSP extraction, automatic Switch 1 shader compilation, and other titles still need end-to-end runs through this CLI.
