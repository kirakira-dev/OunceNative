# NX2 rendering and performance

The November 4, 2026 changes fix Raiders' conditional-clear overflow and reduce replay overhead in Raiders and Pokopia. They do not establish 4K at 60 FPS on the tested Apple M4 with 32 GB of memory.

## Resolution

| Game and mode | Observed main scene | Game output |
| --- | --- | --- |
| Raiders, docked | 2560 x 1440 | 3840 x 2160 |
| Pokopia, docked | 1920 x 1080 | 1920 x 1080, scaled to the display by the host |

Raiders retains handheld mode as its default because the docked island route still has severe stalls. The app's operation-mode setting or `DM_OPMODE=0` selects handheld mode. `DM_OPMODE=1` selects docked mode. `DM_GAME_RES` does not change Pokopia's internal resolution in this build. A 3840 x 2160 screenshot produced with `DM_NVN_SHOT_OUT` applies presentation scaling; it is not evidence of native 4K scene rendering.

## Retained changes

Conditional-render reports use a dynamic address table. The old 256-entry table lost timestamp reports after sufficiently many occlusion queries. Later conditional clears then read stale CPU values and erased an already rendered image. The regression preserves all 64 test pixels after 8,192 reports; the old implementation produces black pixels.

Read-only visibility queries can share a render pass. Writable draws, clears, resource changes, unsupported shaders, and incomplete uniform coverage still end the pass. The compiler records exact uniform words only when it can prove direct reads; unknown layouts retain the previous behavior. Each draw receives its own snapshot, and overlapping deferred updates copy their final bytes back at pass end. Visibility results survive later passes, buffer rollover, and reuse across submissions.

Pending GPU writes use an exact union of address ranges. Exceeding the old fixed table's capacity no longer makes every unrelated index buffer appear GPU-written. Shader control headers are owned by the program, including when deferred hashing happens after the caller has reused its memory.

The sampling-view cache counts each retained backing allocation once, including views of views. It holds at most 1,024 views and 256 MiB of backing storage. Eviction and pool release retain the normal in-flight lifetime guarantees. The measured Pokopia outdoor scene retained about 104 MiB after warming, avoiding repeated view creation under the old 64 MiB limit.

Query sharing and the view cache are enabled by default for NX2 profiles. `DM_NVN_QUERY_MERGE=0` and `DM_NVN_VIEW_CACHE=0` are diagnostic controls for comparisons.

## Validation and limits

The Metal query regression compares 24,585 individual results with sharing enabled, disabled, and without uniform footprints. All results match. With footprints, the complete test uses 126 passes instead of 24,602, including its final storage-copy checks. Additional tests cover 8,196 visibility reports, cumulative counts across ten submissions, 8,192 pending writes, overlapping uniform copies, shader-control reuse, texture mip contents, shared-storage accounting, cache eviction, and the memory limit.

All 43 Python graphics tests pass. Raiders' 1,274-program package passes Metal validation, including 1,800 native function loads. The package includes two additional docked variants. Existing compiled sources are reused only when identical; their hashes and updated reflection provenance are recorded.

In the profiled docked airship comparison, median GPU time fell from about 60 ms to 33 ms and median frame time from about 68 ms to 51 ms. These are scene-specific measurements with profiling overhead, not a 60 FPS claim. Pokopia's cache reduces view creation, but the outdoor scene remains limited by rendering and presentation. Background indexing and foreground capture materially affected timings during testing. Compare the same visible scene, mode, window state, and instrumentation, and exclude loading and pipeline compilation.

Pokopia's existing compiled shader package remains compatible with the new host and is retained unchanged in its local app. Its host is built against that package's matching profile. Compiler provenance describes the original compilation; the runtime update has separate build and validation records. Rebuilding a full archive with the new compiler metadata is a separate operation.

A 15-minute docked island replay reached the first-island dialogue without missing-shader or pipeline diagnostics. The active scene nevertheless took roughly 365 to 374 ms per frame in the measured section, including a long interval around the large compute shader. Its individual timestamp span does not account for the entire interval, so a precise attribution is still open. Dialogue or cached-scene frames must not be treated as gameplay throughput.

One earlier run reported four additional shader keys that were not reproduced by two capture-enabled replays. They remain unverified. Intermittent terrain shading differences, later areas, and complete console-image equivalence also remain unverified. Preserve rendering correctness when evaluating further speed changes; black frames and missing shaders are not valid performance samples.

The final installed Raiders app reaches the first-island aiming tutorial without missing-shader or pipeline diagnostics. Island samples vary from roughly 20 to 31 FPS with window state and system load; this does not establish sustained performance. The installed Pokopia app renders its outdoor tutorial at 1920 x 1080 at about 20 FPS in the foreground check. Its typed-buffer and texture-type mismatch diagnostics also occur in the old installed control build and remain unresolved. Both app updates pass signature verification and preserve the user's saves; smoke tests use isolated copies.
