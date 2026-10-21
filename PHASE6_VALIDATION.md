# Annotation upgrade: phase 6 validation

Recorded **2026-10-21–22** on Apple M4, macOS 27.0.1 (26A434), Apple Swift 6.4 / Command Line Tools, arm64. Automated implementation is complete; **live release acceptance remains open**. Unavailable checks below are not passes.

Read-only display inventory found a built-in Retina screen at `(0, 0, 1470, 956)` points with 2× backing, and an N27q at `(-472, 956, 2560, 1440)` with 1× backing. This establishes that mixed scales and a negative origin are present, not that capture on either display was exercised.

## Builds and functional checks

- Previous-phase baseline: **139 passed, 0 failed**.
- Final complete catalog: **148 passed, 0 failed**, using the standalone AppKit runner. Its debug build includes the production executable and all tests.
- `make package`: release build and ad-hoc signed `dist/Snap.app` succeeded. `codesign --verify --deep --strict` and `plutil -lint` passed. Existing Command Line Tools search-path and native-build-system deprecation warnings remain non-fatal.
- Three complete editor workflows run at image-to-view scales 1, 0.5, and 0.25. Each drives Arrow/Rectangle/Privacy/Text/Number/Select through real controller callbacks and native text input, including multiline Unicode/callouts, 10 markers, movement/undo, deletion/renumbering/undo, text width adjustment, double-click editing, draft cancellation, and Done with active text. Final decoded clipboard pixels exactly match the committed renderer at unchanged dimensions; selection/chrome do not leak into exports. Weak references check controller, canvas, and base-image release.
- Fifty synthetic capture/crop/edit/close sessions use the real coordinator, presenter, overlay, editor, PNG encoder, and a unique native pasteboard. Synthetic displays alternate 1×/2× backing scales at negative origins. The test rejects repeated capture requests, checks release of the full-display image after cropping, alternates Done and cancellation, and checks reset styles, weak crop/editor/native-text/undo-manager references, and every lifetime counter after each session. Cleanup must complete within two seconds after the worker drains. This does not measure a two-second limit from physical close during a slow render.
- Existing coverage remains green for permission failures, clipping and display geometry, native input-method composition, all shortcuts and focus traversal, palette/font controls, render bursts and stale-output rejection, retryable failures, background work, dirty-region pixels, single-worker ownership, and output/PNG release after completion and cancellation.

## Performance results

These measurements use the **debug AppKit test process**, with no allocation stack logging. They measure synthetic workloads, not real screenshots or end-user input latency. Earlier phase 5 results remain in README for reference, not as a directly comparable speedup claim.

The new image is an opaque deterministic multicolor 16-pixel tile pattern. The 100 annotations comprise 20 arrows, 20 rectangles, 20 privacy blocks, 20 Unicode text annotations (10 callouts), and 20 numbered markers. Geometry scales with image dimensions. Each pipeline probe uses three warmups, then 30 samples. p95 is the nearest-rank 29th ordered sample. Total timing starts when a committed snapshot is scheduled and ends after real `NSPasteboard.general` publication. Individual stage p95s need not add to total p95.

| Workload | Total p95 | Render p95 | Encode p95 | Publication p95 | Target assessment |
| --- | ---: | ---: | ---: | ---: | --- |
| 800×600, 100 mixed annotations | 7.61 ms | 3.31 ms | 4.15 ms | 0.11 ms | Synthetic ordinary-crop <50 ms target met |
| 3840×2160, 100 mixed annotations | 88.48 ms | 19.16 ms | 68.70 ms | 0.54 ms | Measured stress case; no large-image latency limit specified |
| Existing 800×600, three-shape probe | 3.70 ms | 0.35 ms | 3.20 ms | 0.19 ms | 30 samples, two warmups, transparent synthetic base |

An earlier focused run measured 13.26 ms and 114.71 ms total p95 for the two 100-annotation sizes. Retain this variation when assessing headroom; no claim relies on one minimum result.

The drag probe uses three warmups plus 100 samples, an 800-point-wide offscreen canvas, and all 100 annotations. It times event handling plus a full CPU draw rather than waiting for the compositor. No drag preview commits an annotation or encodes a PNG.

| Image size | Handler p95, rounded | Handler + full CPU draw p95 | Assessment |
| --- | ---: | ---: | --- |
| 800×600 | <0.01 ms | 2.93 ms | CPU proxy below 16.67 ms |
| 3840×2160, scaled to fit | <0.01 ms | 5.79 ms | CPU proxy below 16.67 ms |

**The one-frame physical input-to-display target is unmeasured.** Offscreen CPU draw excludes event delivery, native text layout during typing, display refresh, and WindowServer/compositor latency. Hotkey-to-overlay <300 ms and snapshot-to-overlay <100 ms also remain unmeasured against live capture; the original targets are unchanged.

## Memory and leaks

The final normal full-suite run sampled test-process resident memory via `mach_task_basic_info`: 152.38 MB before the new 50-cycle workload, 173.64 MB after five cycles, and 185.02 MB after cycle 50. The two later samples are taken after two seconds of settling. The warmed change is **+11.38 MB: the 10 MB synthetic growth target was MISSED**. The functional test passes because references and lifetime counters return to zero; its printed RSS miss is a separate acceptance result. An earlier full run measured −4.59 MB, illustrating variation, but does not override the final miss. This is not an idle-app measurement or a per-cycle RSS trace. Test/framework caches and previous tests affect absolute RSS; no root cause for the final growth has been established. Investigate repeatability and measure the packaged app before release acceptance.

The ownership tests establish shared base-image identity, full-display release, one active render/encode worker across sessions, and release of output pixels and PNG data even while completed task handles survive. They do not count private Core Graphics/ImageIO/WindowServer allocations. Peak live memory and the two-second real-close RSS target remain release checks.

The initial synthetic 50-cycle `leaks --atExit` run exposed leaked private `NSUndoManager` allocations originating in `AnnotationTextView` initialization, despite the text views themselves being released. Eager stored-property allocation during NSTextView's chained Objective-C initialization was replaced with lazy creation. A tracked private undo-manager subclass and a focused exactly-one-manager/release test now cover that ownership gap; every repeat-session cleanup also checks this new counter and the active manager's weak reference.

After the fix, the 50-cycle leak workload completed and all tracked objects returned to zero. The diagnostic reported **416 allocations / 26,400 bytes**, grouped under three `NSXPCConnection` cycles with Apple AppIntents/LinkServices/Foundation/libdispatch stacks. There were **no reported Snap-owned or undo-manager leaks**. The tool still exited **1**; this is not a zero-leak process pass, and no exclusions were used. The OS also warned that the process was not debuggable and only read-only allocation contents were available. RSS under allocation logging changed from 121.39 MB after five cycles to 121.77 MB after 50 (+0.38 MB); these instrumented values are separate from normal performance results.

A real 50-cycle `leaks` run remains unavailable. The optional script preserves both the test catalog status and the leak tool status: `leaks --atExit` alone does not propagate the child's failing exit code, so the test harness writes a completion marker and the script rejects missing/failed markers.

The previously recorded packaged-app idle RSS miss (**37 MB vs <35 MB**, 2026-08-23) has not been superseded by a new idle measurement.

## Unavailable live checks and release checklist

Computer Use was not approved to control Snap. The opt-in ScreenCaptureKit test explicitly failed its preflight with `UNAVAILABLE: test runner has no Screen Recording access; no real capture cycles were run` (0 passed, 1 failed). It did not request permission or substitute a synthetic capture. The following remain open:

| Check | Available automated evidence | Remaining live work |
| --- | --- | --- |
| Every tool/shortcut, tiny/narrow/large crops | Actual AppKit event handlers, native controls, export pixels | Physical mouse/keyboard use; hover/pressed appearance; edge popovers; VoiceOver; live IME candidate windows |
| Mixed display scales and negative origins | Synthetic geometry plus complete scaled workflows | Capture on each real display and check pointer selection, text size, crop pixels |
| Spaces and full-screen applications | Window configuration only | Capture/edit/close in another Space and over a full-screen app |
| Permission denial, grant, and recovery | Injected coordinator/presenter failures | Deny then grant Screen Recording in the packaged app and retry |
| Capture and interaction latency | Signposts and synthetic CPU/pipeline probes | Instruments traces of real captures, physical text/drag feedback, ordinary crop p95 |
| Capture memory budget | Weak references/lifetime counters pass; final synthetic warm RSS grew 11.38 MB (miss) | Idle <35 MB; selection ≤one display buffer +35 MB; annotation ≤base +one output +one PNG +35 MB |
| Fifty real capture/edit/close cycles | Fifty synthetic sessions pass | Run real captures, sample RSS before/selection/edit/within 2 s of close, inspect leaks and growth |

## Reproduction

Run from the repository root with access to AppKit font and pasteboard services. The normal catalog does not capture the screen. Performance probes replace the general clipboard with generated images.

```bash
./scripts/test-appkit.sh
make package
codesign --verify --deep --strict dist/Snap.app
plutil -lint dist/Snap.app/Contents/Info.plist

# Only the eight phase 6 tests; a filter matching nothing fails.
SNAP_TEST_FILTER=phase6 ./scripts/test-appkit.sh

# Synthetic 50-cycle test under leaks; preserves leak-tool failure status.
SNAP_TEST_FILTER='phase6 fifty' SNAP_TEST_LEAKS=1 ./scripts/test-appkit.sh

# Opt-in: requires existing Screen Recording access for this test runner.
# Uses real ScreenCaptureKit snapshots but programmatic editor input.
SNAP_TEST_FILTER='phase6 live capture' SNAP_LIVE_CAPTURE_CHECK=1 ./scripts/test-appkit.sh
```

The runner is built in a temporary directory; macOS may not retain its TCC authorization across runs. A failure here does not prove that the installed Snap bundle lacks permission. Prefer the packaged app for the final physical-input and real-capture checks. Run `scripts/sample-memory.sh <pid>` for RSS, and after 50 real cycles run `scripts/leaks-check.sh <pid>`. Record the exact build, display layout, baseline/peak/post-close RSS, p95 sample count, and leak stacks. Any surviving Snap session, Snap-owned definite leak, unexplained rising RSS, or unmet memory target blocks release acceptance.
