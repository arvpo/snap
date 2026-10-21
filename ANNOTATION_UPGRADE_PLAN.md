# Phased plan: Snap annotation and speed upgrades

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
- **Integration boundary:** existing tools continue using the shared renderer. Text interaction is now implemented in phase 2; numbered-marker interaction belongs to phase 3. Phases 3–6 remain pending. Live capture/display/performance checks remain part of the later integration phase.
- **Build:** release build passes. SwiftPM used temporary module/package caches and `--disable-sandbox` for this environment; release debug-symbol generation required access outside the enclosing filesystem sandbox. Existing Command Line Tools search-path warnings remain non-fatal.

- **Phase 2 complete (2026-10-21):** Text (`T`) supports click-to-type and drag-to-wrap, native selection/paste/text undo/input-method composition, reopening existing text, plain/callout styles, the six-color palette, and 14/18/24-point sizes (default 18). Text geometry and scaled font sizes remain in image coordinates. Return commits, Shift+Return inserts a newline, and Escape cancels the draft (an active IME composition handles Escape first). Empty new drafts are discarded; empty existing text is deleted on commit. Tool changes commit active drafts. Done commits active text and republishes the final image even after native text copy.
- **Phase 2 verification:** all 104 tests pass (90 previous plus 14 new). Coverage includes draft/empty/delete/undo behavior, reverse drag and scaled coordinates, native shortcut isolation, Unicode/newlines, IME marked-text handling, text undo isolation, reopening topmost text, style/wrapping geometry, publication only on completed edits, Done after native copy, active-draft completion, native Unicode paste, editor cleanup, toolbar style/focus/tool transitions, and exact committed canvas/export pixel agreement. Native pasteboard/font tests require macOS service access outside this environment's filesystem sandbox.
- **Phase 2 build:** release build passes; existing Command Line Tools search-path warnings remain non-fatal.
- **Phase 2 manual boundary:** rendered editor preview inspected; live IME candidate selection, real capture across mixed displays, small-crop layout polish, and full performance/memory validation remain pending for later checkpoints.
