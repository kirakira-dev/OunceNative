# NX2 rendering and performance

The November 4, 2026 changes fix Raiders' conditional-clear overflow and reduce replay overhead in Raiders and Pokopia. Raiders now supports an actual 3840 x 2160 presentation drawable with selectable handheld scene resolution. The latest island test measures about 34 FPS with AC Low Power Mode enabled on the Apple M4 with 32 GB of memory; 4K at 60 FPS remains unachieved.

## Resolution

| Game and mode | Observed main scene | Game output |
| --- | --- | --- |
| Raiders, docked | 2560 x 1440 | 3840 x 2160 |
| Raiders, handheld performance setting | 1280 x 720 | 1920 x 1080 with the original HUD, then MetalFX to 3840 x 2160 |
| Pokopia, docked | 1920 x 1080 | 1920 x 1080, scaled to the display by the host |

Raiders retains handheld mode as its default because the docked island route still has severe stalls. The app's operation-mode setting or `DM_OPMODE=0` selects handheld mode. `DM_OPMODE=1` selects docked mode. `DM_GAME_RES` does not change Pokopia's internal resolution in this build. A 3840 x 2160 screenshot produced with `DM_NVN_SHOT_OUT` applies presentation scaling; it is not evidence of native 4K scene rendering.

Mac NX2 builds use MetalFX spatial scaling when the display output is larger than the valid game image. `DM_UPSCALER=linear` selects the previous bilinear path; `DM_UPSCALER=metalfx` explicitly enables MetalFX. Cropping and orientation are applied before scaling, with perceptual SDR color handling and aspect-preserving letterboxing. Unsupported devices and non-upscaled output retain the ordinary presentation path. The drawable normally follows the window's backing-pixel size. Settings → General → Output resolution → 4K, or `DM_OUTPUT_RES=3840x2160`, fixes the drawable at 4K, independently of screenshot dimensions. MetalFX writes directly to compatible drawables, avoiding the final copy; letterboxed and incompatible targets retain the intermediate output.

Raiders' handheld scene setting selects 1080p, 900p, or 720p. The lower resolutions use a local RomFS overlay generated from the owner's `ModuleParam` BYML; only `ResolutionSetting.Handheld.Layer3DResolution` changes. The source dump and the separate 1080p HUD setting remain intact. `DM_SCENE_HEIGHT=720` or `900` requires `DM_SCENE_OVERLAY_ROOT` pointing to these generated overlays; the packaged app supplies that path. This is upscaled 4K output, not native 4K geometry rendering.

`DM_GAME_UPSCALER=metalfx` optionally replaces the identified Raiders spatial reconstruction dispatch with MetalFX. The original shader expands 372 tensor operations into scalar work. The replacement accepts only the audited RGB10A2 input/output layout, complete output regions, valid crop constants, and compatible texture usage; other dispatches use the original shader. The docked island test exercises both 1707 x 960 → 2560 x 1440 and 2560 x 1440 → 3840 x 2160 reconstruction. Handheld gameplay uses the separate presentation upscaler. The replacement is not pixel-identical to the game's neural filter.

The presentation regression passes crop, orientation, sRGB, letterbox, resize, and 1080p-to-4K checks on both Metal 3 and Metal 4. Known constant regions differ by at most one byte value. The 4K Metal 4 presentation path alone measures roughly 8.5 to 9.0 ms on this M4; this includes the crop and output passes. These isolated timings exclude scene rendering. A full-screen airship replay has median frame times near 16.7 ms, with higher tail times, at a fitted 3420 x 1924 output. It is not a sustained 4K60 gameplay result.

The reported half-speed Raiders session was running an older backup application. Relaunching the updated canonical app restored normal animation and text speed, confirmed by the user. The SDK counter frequency matches the host, and deterministic test-clock mode was disabled. A separate 30 FPS probe kept the game's animation step at one, so falling below its expected 60 FPS can still slow gameplay. No simulation-clock multiplier or frame-step patch was applied.

## Retained changes

Deferred uniform snapshots cache their shared-buffer CPU addresses and maintain an exact indexed union of updated ranges. This removes repeated Objective-C buffer lookups and linear coverage scans without changing snapshot ordering or copyback. In comparable late-island windows with about 1,470 draws, submission work falls from approximately 51.2 million to 31.9 million instructions per frame. Raiders' Mac host builds with `-O2`.

Conditional-render reports use a dynamic address table. The old 256-entry table lost timestamp reports after sufficiently many occlusion queries. Later conditional clears then read stale CPU values and erased an already rendered image. The regression preserves all 64 test pixels after 8,192 reports; the old implementation produces black pixels.

Pending reports also survive submission boundaries. Starting a new submission used to clear that table before the previous GPU work completed, exposing stale CPU counter bytes to a later conditional clear. Entries now carry their publishing fence and retire after completion; an atomic completion counter publishes the callback's writes. A regression holds the GPU queue behind an event, encodes the dependent clear in a second submission, and verifies both preserved pixels and later CPU reuse of the report address. It fails before this fix and passes with Metal API validation afterward.

Read-only visibility queries can share a render pass. Writable draws, clears, resource changes, unsupported shaders, and incomplete uniform coverage still end the pass. The compiler records exact uniform words only when it can prove direct reads; unknown layouts retain the previous behavior. Each draw receives its own snapshot, and overlapping deferred updates copy their final bytes back at pass end. Visibility results survive later passes, buffer rollover, and reuse across submissions.

Pending GPU writes use an exact union of address ranges. Exceeding the old fixed table's capacity no longer makes every unrelated index buffer appear GPU-written. Shader control headers are owned by the program, including when deferred hashing happens after the caller has reused its memory.

The sampling-view cache counts each retained backing allocation once, including views of views. It holds at most 1,024 views and 256 MiB of backing storage. Eviction and pool release retain the normal in-flight lifetime guarantees. The measured Pokopia outdoor scene retained about 104 MiB after warming, avoiding repeated view creation under the old 64 MiB limit.

Query sharing and the view cache are enabled by default for NX2 profiles. `DM_NVN_QUERY_MERGE=0` and `DM_NVN_VIEW_CACHE=0` are diagnostic controls for comparisons.

## Validation and limits

The latest seven-minute 4K test exits cleanly after more than 12,600 frames. For 300-frame windows at and after frame 6,000, the median of logged frame-time medians is 29.45 ms (about 34 FPS); individual window medians range from 27.76 to 30.02 ms. The corresponding GPU figure is 16.79 ms, and median CPU submission time is 17.26 ms. These are summaries of window statistics, not pooled individual-frame percentiles. AC Low Power Mode was enabled throughout, and macOS storage-management processes added background load. A normal-power 60 FPS result has not been established.

The updated query and overlapping-copy regression passes Metal validation with 24,585 query results. Range coverage also agrees with a byte-map oracle over 262,144 randomized comparisons and 8,192 disjoint writes. Presentation tests pass 28 cases across Metal 3/4, including direct output, crop, orientation, sRGB, letterboxing, resize, and 4K. The game-scaler test checks RGB10A2 colors and alpha, rejected crops, and 1280 x 720 → 1920 x 1080 output. Rendered airship and first-island images show intact geometry and textures in the inspected frames; this does not verify unseen scenes.

The Metal query regression compares 24,585 individual results with sharing enabled, disabled, and without uniform footprints. All results match. With footprints, the complete test uses 126 passes instead of 24,602, including its final storage-copy checks. Additional tests cover 8,196 visibility reports, cumulative counts across ten submissions, 8,192 pending writes, overlapping uniform copies, shader-control reuse, texture mip contents, shared-storage accounting, cache eviction, and the memory limit.

All 43 Python graphics tests pass. Raiders' updated 1,429-program package passes Metal validation, including 2,043 native function loads. Existing compiled sources are reused only when identical; their hashes and updated reflection provenance are recorded.

In the profiled docked airship comparison, median GPU time fell from about 60 ms to 33 ms and median frame time from about 68 ms to 51 ms. These are scene-specific measurements with profiling overhead, not a 60 FPS claim. Pokopia's cache reduces view creation, but the outdoor scene remains limited by rendering and presentation. Background indexing and foreground capture materially affected timings during testing. Compare the same visible scene, mode, window state, and instrumentation, and exclude loading and pipeline compilation.

Pokopia's existing compiled shader package remains compatible with the new host and is retained unchanged in its local app. Its host is built against that package's matching profile. Compiler provenance describes the original compilation; the runtime update has separate build and validation records. Rebuilding a full archive with the new compiler metadata is a separate operation.

A 15-minute docked island replay reached the first-island dialogue without missing-shader or pipeline diagnostics. The active scene nevertheless took roughly 365 to 374 ms per frame in the measured section, including a long interval around the large compute shader. Its individual timestamp span does not account for the entire interval, so a precise attribution is still open. Dialogue or cached-scene frames must not be treated as gameplay throughput.

Later captures recovered those four shader variants and two additional programs, bringing the initial corrected package to 1,280. A subsequent damage-state replay captured 149 more programs, all of which translate and load successfully in the final 1,429-program package. Their complete in-game visual coverage remains unverified. The reproduced normal/black terrain alternation came from position differences between depth and color passes. Marking vertex position invariant, alongside the existing compiler invariance option, fixes the controlled replay: consecutive terrain samples previously alternated between mean luminance 22.79 and 234.78; all four corrected samples remain at 234.78. Existing reflection bindings are unchanged. This verifies the reported alternation in that scene, not complete console-image equivalence or all later areas.

The optional hardware ray-traced ambient-occlusion mode is disabled by default. An instrumented airship sample with it enabled took about 65–66 ms per frame and 52 ms on the GPU, with a roughly 44-second first-scene compilation stall. Those results do not meet the performance target. See [Raiders options](raiders.md#experimental-ray-tracing) for its scope and limitations.

The final installed Raiders app reaches the first-island aiming tutorial without missing-shader or pipeline diagnostics. Island samples vary from roughly 20 to 31 FPS with window state and system load; this does not establish sustained performance. The installed Pokopia app renders its outdoor tutorial at 1920 x 1080 at about 20 FPS in the foreground check. Its typed-buffer and texture-type mismatch diagnostics also occur in the old installed control build and remain unresolved. Both app updates pass signature verification and preserve the user's saves; smoke tests use isolated copies.
