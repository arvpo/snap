# Phased plan: Snap annotation and speed upgrades

> Clipboard behavior updated on 2026-10-22: capture selection and all edits stay local. Only `Cmd+C` outside native text editing or the tick (Done) button copies the final image. Return only commits active text. Earlier references below to immediate or per-edit clipboard updates describe the superseded design.

## Summary

Deliver the upgrade in **six phases**, each producing a buildable, tested checkpoint and its own local Git commit.

When execution is enabled, first save this plan as `ANNOTATION_UPGRADE_PLAN.md`, link it from the existing `PLAN.md`, and commit those documentation changes as:

`docs: add phased annotation upgrade plan`

The baseline before this upgrade was **73 passing tests**, with a clean working tree.

## Agreed behavior

- Support plain red text and filled callouts, with a six-color palette: red, blue, green, yellow, black, and white. Reset defaults each capture.
- Support movable, editable text and movable numbered markers. Number markers consecutively from 1 and automatically renumber after deletion.
- Preserve the existing arrow, rectangle, and opaque privacy-block behavior.
- Use a compact horizontal toolbar above the image, with clear selection, hover states, tooltips, and accessible controls.
- Keep annotation geometry in image coordinates, undo history as values, and clipboard updates tied to completed edits.
- Retain the current capture workflow and memory limits. Persistence, full shape editing, redo, and capture-backend changes remain outside this upgrade.

## Implementation phases

### Phase 1 — Annotation model, undo, and rendering foundation

**Work**
- Introduce stable annotation identities and value types for text, styles, and numbered markers.
- Extend document operations to insert, update, move, and delete annotations using reversible transactions.
- Keep each gesture or editing session as one undo operation; include automatic renumbering in the same transaction.
- Add shared text and marker rendering, measurement, and bounds calculations. Use Core Text for committed text and isolate new antialiasing settings from existing shapes.

**Checkpoint**
- Test ordering, identity preservation, mutation/undo, renumbering, multiline/Unicode rendering, and multi-digit marker bounds.
- Preserve existing compositor pixel tests and privacy opacity.
- Run the complete automated suite.

**Commit:** `feat: add editable annotation model and rendering`

### Phase 2 — Functional text tool and native editing

**Work**
- Add Text (`T`): click to type or drag to establish wrapping width.
- Use a native text editor with normal selection, paste, text undo, and input-method support.
- Provide plain-text/callout selection, the agreed palette, and font sizes of 14, 18, and 24 points; default to 18.
- Return commits, Shift+Return adds a newline, and Escape cancels the editing transaction. Empty new text is discarded; committing an emptied existing annotation deletes it.
- Allow the Text tool to reopen existing text. Done commits active text and ensures the final clipboard contains the annotated image, including after copying text.

**Checkpoint**
- Verify typing never activates drawing shortcuts or unexpectedly finishes the session.
- Test commit/cancel, empty text, wrapping, Unicode, clipboard publication, and preview/export agreement.
- Expose functional controls in the existing toolbar; visual refinement follows in Phase 4.

**Commit:** `feat: add text annotations and callout editing`

### Phase 3 — Numbered markers and direct manipulation

**Work**
- Add Number (`N`): each click places the next marker and leaves the tool active.
- Use a default 28-point circle with contrasting digits, a white outline, and a subtle shadow; expand for longer numbers.
- Add Select (`V`) for text and markers: selection, dragging, deletion, and text-box width adjustment.
- Double-click selected text to edit it. Moving markers preserves numbering order; deletion closes numbering gaps.
- Keep selection outlines and handles out of exported images.

**Checkpoint**
- Test repeated placement, 9→10 numbering, deletion/renumbering/undo, movement, resizing, overlapping hit targets, and image-edge behavior.
- Verify geometry on Retina displays and when the image is scaled to fit.
- Run the complete automated suite.

**Commit:** `feat: add numbered markers and annotation selection`

### Phase 4 — Toolbar and editor layout polish

**Work**
- Arrange Select, Arrow, Rectangle, Privacy, Text, Number, Undo, and Done in a compact rounded horizontal toolbar.
- Add consistent icons, hover/pressed/selected states, disabled Undo styling, shortcut tooltips, and accessibility labels.
- Place style controls in a contextual popover.
- Move the toolbar into editor chrome above the image. Give small crops enough surrounding space for the controls while preserving image proportions and export dimensions.
- Preserve existing shortcuts outside text editing and keep Arrow as the initial tool.

**Checkpoint**
- Check small, narrow, and large crops; keyboard focus; text-editor transitions; popover placement; and accessibility labels.
- Verify toolbar clicks cannot create annotations and editor chrome never appears in exports.
- Build and run the complete automated suite.

**Commit:** `feat: refine annotation toolbar and editor layout`

### Phase 5 — Rendering, clipboard, and interaction responsiveness

**Work**
- Separate background PNG encoding from main-actor pasteboard publication for initial crops and annotations.
- Add a guarded coordinator state while preparing the initial clipboard image; prevent canceled or obsolete sessions from publishing.
- Use one active render/encode worker and one replaceable pending snapshot. Keep generation checks and publish only the latest valid result.
- Redraw changed regions, skip annotations outside dirty bounds, and coalesce previews without encoding during typing or dragging.
- Release completed buffers and task references promptly. Finish waits for the latest required publication; cancellation invalidates output and completes cleanup.
- Show retryable clipboard errors with Retry and Close actions. Add separate render, encode, and publication timings.

**Checkpoint**
- Test rapid edit/undo bursts, worker concurrency limits, stale-result rejection, cancellation, failures, and immediate finish after editing.
- Confirm background work does not block text entry or tool selection.
- Run the complete automated suite and compare performance against the baseline.

**Commit:** `perf: streamline annotation rendering and clipboard updates`

### Phase 6 — Integration, performance validation, and documentation

**Work**
- Add focused integration and stress coverage for complete text/marker editing sessions.
- Run the full suite, release build, and packaging.
- Exercise all tools and shortcuts, mixed display scales, negative display origins, Spaces/full-screen apps, permission failures, and repeated captures.
- Measure ordinary crops and large images with 100 mixed annotations. Run 50 real capture/edit/close cycles and check memory and leaks.
- Update documentation with final controls, measurements, completed checks, and any unresolved targets.

**Checkpoint**
- Target interaction feedback within one 60 Hz frame and ordinary 800×600 commit-to-clipboard latency below 50 ms at the 95th percentile.
- Preserve existing capture latency targets.
- Require one cropped base image, at most one output buffer and one PNG, zero surviving session objects after cleanup, and memory returning within 10 MB of baseline within two seconds.
- Record unavailable manual checks or missed targets explicitly; do not describe them as passing.

**Commit:** `test: validate annotation workflows and performance`

## Commit discipline

Complete phases in order. For each phase, review the diff, pass its automated checks, update its status in the saved plan, and commit the implementation and relevant tests together. Fix regressions before starting the next phase. Final release readiness additionally requires the manual performance and memory checks.

## Progress

- **Phase 1 complete (2026-10-21):** stable annotation entries; atomic insert/update/move/delete batches; value-only undo deltas including marker renumbering; Core Text measurement, bounds, and rendering for plain text, callouts, and expanding numbered markers.
- **Verification:** all 90 tests pass (73 baseline plus 17 new tests). Coverage includes identity and ordering, grouped edits and undo, invalid/no-op transactions, renumbering through 9→10, Unicode/multiline/wrapped text, narrow frames, multi-digit marker bounds, palette contrast, image-edge clipping, off-main rendering, and preservation of shape pixels and privacy opacity. A rendered sample was visually inspected.
- **Integration boundary at phase 1:** existing tools continued using the shared renderer. Text interaction followed in phase 2; numbered-marker interaction and selection followed in phase 3. See the phase 6 status below for current integration evidence and remaining live checks.
- **Build:** release build passes. SwiftPM used temporary module/package caches and `--disable-sandbox` for this environment; release debug-symbol generation required access outside the enclosing filesystem sandbox. Existing Command Line Tools search-path warnings remain non-fatal.

- **Phase 2 complete (2026-10-21):** Text (`T`) supports click-to-type and drag-to-wrap, native selection/paste/text undo/input-method composition, reopening existing text, plain/callout styles, the six-color palette, and 14/18/24-point sizes (default 18). Text geometry and scaled font sizes remain in image coordinates. Return commits, Shift+Return inserts a newline, and Escape cancels the draft (an active IME composition handles Escape first). Empty new drafts are discarded; empty existing text is deleted on commit. Tool changes commit active drafts. Done commits active text and republishes the final image even after native text copy.
- **Phase 2 verification:** all 104 tests pass (90 previous plus 14 new). Coverage includes draft/empty/delete/undo behavior, reverse drag and scaled coordinates, native shortcut isolation, Unicode/newlines, IME marked-text handling, text undo isolation, reopening topmost text, style/wrapping geometry, publication only on completed edits, Done after native copy, active-draft completion, native Unicode paste, editor cleanup, toolbar style/focus/tool transitions, and exact committed canvas/export pixel agreement. Native pasteboard/font tests require macOS service access outside this environment's filesystem sandbox.
- **Phase 2 build:** release build passes; existing Command Line Tools search-path warnings remain non-fatal.
- **Phase 2 manual boundary:** rendered editor preview inspected; live IME candidate selection, real capture across mixed displays, small-crop layout polish, and full performance/memory validation remain pending for later checkpoints.

- **Phase 3 complete (2026-10-21):** Number (`N`) places consecutive markers and stays active, using 28-display-point circles, contrasting digits, white outlines, shadows, and expansion for longer labels. Select (`V`) selects the topmost text/marker, drags it in image coordinates, deletes with either Delete key, and adjusts text wrapping with a right-side handle. Double-clicking selected text opens native editing. Marker movement preserves numbering; deletion and automatic renumbering undo together. Each completed manipulation is one undo step and one clipboard update; previews stay outside the document. Escape cancels a gesture or clears selection. Tool switches discard incomplete gestures. Outlines and handles remain canvas-only.
- **Phase 3 verification:** all 119 tests pass (104 previous plus 15 new), including repeated placement through 9→10, identity/order preservation, deletion/renumbering/undo, movement, natural-width and callout resizing, overlap hit targets, edge clamping, gesture cancellation/no-ops, double-click editing, shortcuts/toolbar transitions, publication timing, and selection-free export pixels. Geometry is covered at 1×, 0.5× (Retina), and 0.25× (scaled-to-fit) transforms. A rendered selection/marker sample was visually inspected. Release build passes.
- **Phase 3 test runner:** the current Command Line Tools async runner can exit with status 0 before the background-render test resumes, omitting the remaining tests and final summary. Full-suite validation uses `scripts/test-appkit.sh`, which runs the unchanged test catalog inside a standalone native AppKit event loop and fails if that loop exits before the test task completes. Native pasteboard/font tests still require macOS service access outside the filesystem sandbox. The default `swift test` runner issue remains a toolchain limitation; a zero exit code without the final test summary is insufficient.
- **Phase 3 edge policy and manual boundary:** circles and text boxes stay inside the crop when they fit; oversized text can move across its visible extent, and a marker larger than a tiny crop is centered and clipped. Wrapping width is constrained to available image width; tall text and shadows can clip. Actual mixed-display captures, live input-method behavior, small-crop toolbar chrome (phase 4), and full performance/memory validation remain pending.


- **Phase 4 complete (2026-10-21):** Select, Arrow, Rectangle, Privacy, Text, Number, Undo, and Done sit in a compact rounded horizontal toolbar above the image, with a contextual Text style button. Shared symbol sizing, hover/pressed/selected states, keyboard focus rings, shortcut tooltips, accessibility labels, and disabled Undo styling are in place. Plain/callout, palette, and size controls live in a transient native popover, including when Select reopens text. Closing the popover restores the active editor/canvas focus and preserves text selection; tool changes commit the draft. Undo reflects the native text stack during editing and the document stack otherwise. Tab/Shift+Tab navigates controls even with system Full Keyboard Access disabled. Arrow remains the initial tool.
- **Phase 4 layout:** editor chrome and canvas are sibling views. Small crops receive surrounding space without enlargement; large crops fit the available screen area. One shared scale preserves exact aspect ratio, including odd Retina dimensions, and image-space geometry/export dimensions remain unchanged. Canvas clipping keeps native text within the image; toolbar and margin hit targets never draw annotations. Popovers, observers, and callbacks are released on teardown.
- **Phase 4 verification:** all 126 tests pass (119 previous plus 7 new), using the standalone native AppKit test runner. Coverage includes tiny/narrow/large crops, 1×/2× screens and negative origins, toolbar order/accessibility/selection, disabled Undo transitions, native text undo, popover placement within its content view, style and focus transitions, preserved text selection, Tab navigation, shortcut isolation, chrome hit testing, unchanged export pixels/dimensions, and popover cleanup. Debug and release builds pass. A rendered editor/toolbar preview was visually inspected. Existing Command Line Tools warnings remain non-fatal.
- **Phase 4 manual boundary:** live hover/pressed appearance, popover appearance and screen-edge placement, VoiceOver traversal, real mixed-display captures, and live IME behavior still need interactive validation. Computer Use inspection was unavailable because permissions were not granted; cached AppKit pop-up-button images were incomplete and are not evidence of a passing visual check. Full performance/memory validation remains in phases 5–6.


- **Phase 5 complete (2026-10-21):** PNG encoding now runs with rendering on a background worker; the main actor only publishes prepared PNG bytes. Initial crops use a guarded `preparingClipboard` state, release the captured display before encoding, ignore repeated requests, and reject canceled or obsolete results. One worker and one replaceable pending snapshot bound edit bursts; a shared worker lane also prevents overlapping output allocations across canceled and replacement sessions. Superseded renders skip encoding when possible. Completed tasks retain neither output pixels nor PNG data.
- **Phase 5 interaction and errors:** canvas invalidations cover old/new annotation, gesture, and draft bounds; cached image-space bounds cull committed annotations outside the dirty region. AppKit coalesces previews, and typing/dragging never encode. Done commits text and waits for successful final publication. Initial-copy, render, encode, and pasteboard failures offer Retry and Close. Retry regenerates the current committed snapshot; a failed Done completes only after successful Retry. Escape/Close invalidate pending output and tear down the UI without republishing. Separate `annotation-render`, `png-encode`, and `clipboard-publication` timings supplement the existing overall intervals.
- **Phase 5 verification:** all 139 tests pass (126 previous plus 13 new) using `scripts/test-appkit.sh`; debug and release builds pass. Coverage includes 100-update bursts, one active worker across sessions, pending replacement, stale failure rejection, cancellation during encoding, initial preparation and retry, all three failure stages, native typing/tool selection during encoding, immediate Done with a newer draft, Retry/Close button actions, dirty-tile pixel equality and culling, transparent-region erasure, off-main rendering/encoding, and output-buffer/PNG release even while completed task handles survive. Existing text/drag publication, geometry, privacy, and 50-cycle lifetime tests remain green.
- **Phase 5 measurements:** before changes, the existing one-shot 800×600 probes measured 8.93 ms crop+encode and 7.48 ms annotation render+encode; the final run measured 10.61 ms and 7.05 ms respectively. Those probes exclude publication and vary between runs. A new warmed pipeline probe with 30 measured samples (after two warmups), a synthetic 800×600 image and three shapes, including real pasteboard publication, measured 2.73 ms total p95; separate stage p95s were 0.28 ms render, 2.35 ms encode, and 0.09 ms publication. Warmed asynchronous timings are not a like-for-like speedup comparison with the one-shot baseline and do not establish real-capture performance.
- **Phase 5 cleanup/manual boundary:** cancellation immediately invalidates publication and drops pending/UI references. An already executing synchronous Core Graphics/ImageIO call must drain before its local buffers disappear; the next session cannot start another output allocation during that drain. Automated ownership probes pass, but the two-second RSS target, live input-to-display timing, error-panel appearance/VoiceOver, real mixed-display capture behavior, 100 mixed annotations on large images, and 50 real capture/edit/close cycles with `leaks` remain phase 6 checks. Existing Command Line Tools search-path/deprecation warnings remain non-fatal.

- **Phase 6 automated implementation complete (2026-10-22); live acceptance open:** added eight focused checks for complete native text/marker workflows at 1×/0.5×/0.25×, exact final clipboard pixels, 50 synthetic sessions through the live coordinator/presenter/overlay/editor, and 100 mixed annotations on ordinary and 4K images, plus an undo-manager initialization/release regression. The runner supports focused tests, optional allocation-stack leak diagnostics, and an explicit opt-in real ScreenCaptureKit workload. Final controls, methodology, measurements, and unresolved release targets are documented in [PHASE6_VALIDATION.md](PHASE6_VALIDATION.md) and README.
- **Phase 6 verification:** prior baseline 139/139; final full suite **148/148**. Debug/release builds, `make package`, strict code-signature verification, and plist validation pass. Every synthetic cycle releases the full display after crop and all tracked session objects, crop/editor/native-text weak references after close; alternate cycles exercise Done with active text and cancellation. Cleanup checks allow the specified two-second deadline after worker drain.
- **Phase 6 measurements:** 30 measured pipeline samples after three warmups: 800×600/100 mixed annotations **7.61 ms total p95** (render 3.31, encode 4.15, publication 0.11); 3840×2160/100 mixed **88.48 ms** (19.16, 68.70, 0.54). CPU drag+full-draw p95 on an 800-point canvas: **2.93 / 5.79 ms**. Final synthetic test-process RSS after five/50 cycles, each sampled after two seconds: **173.64 / 185.02 MB**, a **+11.38 MB** change that **misses the 10 MB target** despite zero surviving tracked objects. This needs investigation before release acceptance; earlier lower growth does not override the final miss. These are debug synthetic results, not packaged-app memory or physical display latency passes; earlier focused runs and methodology are retained in the report.
- **Phase 6 unavailable checks:** Computer Use was not approved to control Snap; real-capture preflight failed because the test runner lacks Screen Recording access. **Zero real capture cycles ran.** Mixed physical displays/negative origins, Spaces/full-screen apps, permission recovery, live input/VoiceOver/IME, capture/physical interaction timings, peak/idle app RSS and the two-second real-close budget, and 50 real capture cycles with `leaks` remain release gates. The previous 37 MB idle RSS miss remains unresolved. Phase 6 does not establish final release readiness.
- **Phase 6 leak fix and diagnostics:** the synthetic `leaks` workload exposed private undo managers leaked during eager native text-view initialization. Lazy creation fixes those allocations; an undo-manager lifetime counter and exactly-one-manager regression cover the missed ownership. After the fix, 50 cycles leave all counters at zero and report no Snap-owned/undo-manager leaks. `leaks` still exits 1 for 416 allocations / 26,400 bytes under three macOS AppIntents/XPC cycles; that result remains explicitly recorded, with no exclusions. The script independently checks test completion because `leaks --atExit` does not preserve the child exit status.
