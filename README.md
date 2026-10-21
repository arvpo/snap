# Snap

A small macOS screenshot tool. Press `Cmd+Shift+X`, drag a rectangle, annotate, and the image is already on the clipboard.

It exists because Flameshot can sit at 300 MB and climb toward 3 GB. Snap captures only the monitor under the pointer, keeps one full-display buffer, copies the selected crop, then releases everything it can. After the editor closes it must retain no screenshot pixels. A leak or a rising memory line across repeated captures is a release-blocking bug.

## Status

Phases 1 through 5 of the original plan are implemented. Snap is a menu-bar app: global hotkey, pointer-display capture, region select, eager PNG clipboard, and an annotation editor. Automated tests cover mixed-display conversion, crop pixels, annotation geometry, undo, render-generation, coordinator transitions, presenter cancel/failure teardown, and 50-cycle session lifetime counters.

Local packaging stays ad-hoc signed. Developer ID, notarization, DMG, and App Store release are a later phase.

The [annotation upgrade plan](ANNOTATION_UPGRADE_PLAN.md) is tracked separately. Its first phase adds stable annotation identities, grouped undo for edits and marker renumbering, and shared Core Text rendering and bounds for text, callouts, and numbered markers. Phase 2 adds native text entry, plain text and filled callouts, six colors, and 14/18/24-point sizes (18 by default). Phase 3 adds repeated numbered-marker placement and selection, movement, deletion, and text-box width adjustment. Phase 4 moves the compact toolbar into editor chrome and adds contextual styling, keyboard focus, and accessibility. Phase 5 moves PNG encoding off the main actor, bounds background image work, redraws changed canvas regions, and provides retryable clipboard errors.

The upgrade suite currently passes all **148 tests** through `scripts/test-appkit.sh`; debug/release builds and signed app packaging pass. Phase 6 adds complete scaled editing workflows, 50 synthetic capture/edit/close cycles, and 100-annotation performance probes. See the [phase 6 validation report](PHASE6_VALIDATION.md) for measurements, reproduction commands, and the live checks still blocking release acceptance.

## What it does

- Run as a menu-bar app with no Dock icon.
- Start from `Cmd+Shift+X` or the menu-bar Capture item.
- Freeze only the display containing the mouse, then let you drag a region.
- Copy that crop to the clipboard immediately.
- Annotate with a red arrow, a red outline rectangle, an opaque black privacy block, text/callouts, or numbered markers.
- With Text selected, click to type or drag to set the wrapping width. Click existing text to edit it. The Text style popover offers plain/callout, red/blue/green/yellow/black/white, and 14/18/24-point sizes. Defaults reset each capture.
- With Number selected, click repeatedly to place markers starting at 1. Circles start at 28 display points and grow for longer labels. Moving markers preserves their order; deletion closes gaps.
- With Select selected, click text or a marker to select it, drag to move, and press Delete to remove it. Drag the right-side text handle to change wrapping width; double-click selected text to edit. Each completed gesture is one undo step. Selection outlines and handles never appear in clipboard images.
- Keep the compact toolbar above the image, with surrounding space for tiny crops. Arrow is selected initially. Text style is available while Text is selected or an existing text annotation is being edited. Tab/Shift+Tab navigates the toolbar; Undo reflects the active text or document history. Editor chrome never appears in exports.
- Recopy the clipboard after completed edits. Rapid edits replace one pending snapshot while a single render/encode worker finishes; only the newest valid result is published. Typing and drag previews never encode PNGs.
- Retry a failed clipboard update, or choose Close to cancel the session. Done waits for successful publication; Escape invalidates pending output and keeps whatever is already on the clipboard.
- `Enter` commits active text; outside text editing it finishes. Cancel selection with `Esc`. Undo with `Cmd+Z`.

No file saving, history, upload, OCR, or preferences in the first version.

## Install

Needs macOS 14+ on Apple Silicon. The release zip is arm64 only.

1. Download `Snap-0.1.0.zip` from the [latest GitHub release](https://github.com/arvpo/snap/releases/latest).
2. Unzip it and move `Snap.app` to `/Applications`.
3. Open it. The build is ad-hoc signed, so Gatekeeper will block a normal double-click. Right-click `Snap.app` → Open, or run:

```bash
xattr -cr /Applications/Snap.app
open /Applications/Snap.app
```

Snap lives in the menu bar. There is no Dock icon.

The first capture asks for Screen Recording access. Enable Snap in System Settings → Privacy & Security → Screen Recording, then press `Cmd+Shift+X` again.

If another app already owns `Cmd+Shift+X`, that binding wins. The shortcut is not configurable yet.

To build from source instead, use the Build section below.

## Memory rules

These are not optional.

- Idle after launch settles: under 35 MB resident.
- During selection: at most one 4-byte-per-pixel buffer for the pointer’s display, plus 35 MB overhead. Unused monitors are never captured.
- During annotation: the cropped base image, at most one in-progress output buffer, one encoded PNG, plus 35 MB overhead. Undo stores vectors, not bitmaps.
- After each clipboard write: Snap drops its PNG payload and completed task references; the rendered buffer has already been released by the background worker. The pasteboard process owns the copy.
- After cancellation, pending snapshots and UI references are released immediately. A synchronous Core Graphics/ImageIO call already executing must drain before its local buffers can be released; its output is invalidated and it shares a single worker lane with the next capture. After cleanup, Snap retains no screenshot pixels. Resident memory must return to within 10 MB of the pre-capture baseline within two seconds.
- Fifty capture/select/annotate/close cycles must not grow resident memory, must leave zero live session objects, and must show no definitely lost Snap-owned allocations under `leaks`.

A 5K display buffer is about 59 MB. That spike is allowed only while the overlay is up. It must be gone after selection or cancel.

The 2026-10-21 display inventory reports the built-in display at 1470×956 points with 2× backing (2940×1912 pixels), plus a 2560×1440 1× external display at a negative X origin. The built-in 4-byte pixel buffer is about 21.4 MiB; the external display is captured only when it contains the pointer. Live validation of this arrangement remains open.

## Latency targets

- Under 300 ms from hotkey to visible frozen overlay.
- Under 100 ms from completed snapshot to overlay.
- Under 50 ms from mouse-up to clipboard refresh for an ordinary region.

Instruments: attach Snap and filter `com.stradeon.Snap` / `latency`. The overall intervals are `hotkey-to-snapshot`, `snapshot-to-overlay`, `mouse-up-to-first-clipboard`, and `annotation-mouse-up-to-clipboard`. Separate `annotation-render`, `png-encode`, and `clipboard-publication` intervals distinguish background image work from main-actor pasteboard publication.

## Build

Needs macOS 14+ and Apple Command Line Tools. Full Xcode is not required for local development.

```bash
xcode-select -p
swift --version
```

```bash
swift build
swift test
make package
open dist/Snap.app
```

If `swift test` exits without the final test-count summary on current Command Line Tools, run `./scripts/test-appkit.sh`. It builds and runs the same full test catalog in a standalone AppKit event loop; phase 3 validation used this runner. Native UI tests need pasteboard and font-service access.

`make package` runs `scripts/build-app.sh`. That assembles `dist/Snap.app`, copies `Resources/Info.plist`, and ad-hoc signs the bundle. macOS Screen Recording permission is tied to that bundle identifier, so do not run the raw SwiftPM binary as the daily target.

Do not use `xcodebuild` for this project.

## Keyboard

| Key | Action |
| --- | --- |
| `Cmd+Shift+X` | Start capture on the pointer’s display |
| `A` | Arrow |
| `R` | Outline rectangle |
| `B` | Privacy block |
| `T` | Text (click to type; drag for wrapping width) |
| `N` | Number (click repeatedly to place consecutive markers) |
| `V` | Select text or markers; drag to move; use the text handle to resize width |
| `Cmd+Z` | Undo text while editing; otherwise undo a completed annotation edit |
| `Cmd+C` | Copy selected text while editing; otherwise publish the image and close |
| `Delete` / forward Delete | Remove selected text or marker; remaining markers renumber automatically |
| `Enter` / keypad Enter | Commit active text; otherwise finish and publish the image |
| `Shift+Enter` | Add a newline while editing text |
| `Esc` | Cancel active text/gesture, then clear annotation selection; otherwise cancel capture selection or close the editor |
| `Tab` / `Shift+Tab` | Move through toolbar controls outside native text editing |

Done commits active text and republishes the final image, including after text Copy/Cut. If publication fails, Retry completes Done after a successful write; Close cancels. Escape closes without waiting for a pending image write or restoring a clipboard image replaced by native text Copy/Cut. Empty new text is discarded; emptying and committing existing text deletes it. A whole text-editing session is one annotation undo step. Native text selection, plain-text paste, and text undo remain available during editing.

The toolbar and small-crop chrome are implemented. Live input-method candidate windows, VoiceOver, popover placement, and mixed-display text sizing still need manual validation.

Marker circles and moved text boxes stay within the crop when they fit. Oversized text can be moved across its visible extent, and markers larger than a tiny crop are centered and clipped. Text wrapping is limited to the available width; very tall text and marker shadows can clip at image edges. Geometry tests cover 1×, Retina (0.5×), and scaled-to-fit (0.25×) canvas transforms; real mixed-display validation remains pending.

## Measurements

Upgrade phase 6 (2026-10-22): the final 148-test run measured **7.61 ms p95** for 800×600 with 100 mixed annotations, including real pasteboard publication, and **88.48 ms p95** at 3840×2160. CPU drag-handler plus full offscreen draw p95 was 2.93 / 5.79 ms respectively; this does not measure physical input-to-display latency. Fifty synthetic sessions left no tracked session objects or weak image/editor/undo-manager references, but warmed test-process RSS grew **11.38 MB**, missing the 10 MB target. A private text undo-manager initialization leak was fixed; the subsequent leak diagnostic reported only macOS AppIntents/XPC stacks. Release build, packaging, signature, and plist checks pass. RSS investigation and live checks remain release gates. See [methodology, variation, and unresolved targets](PHASE6_VALIDATION.md).

Upgrade phase 5 measurements (2026-10-21, debug AppKit runner, synthetic 800×600 base and three shapes):

| Probe | Before phase 5 | After phase 5 |
| --- | --- | --- |
| One-shot crop + PNG encode; no publication | 8.93 ms | 10.61 ms |
| One-shot annotation render + PNG encode; no publication | 7.48 ms | 7.05 ms |
| Full background pipeline + real pasteboard publication, 30 warmed samples | not recorded | 2.73 ms p95 |
| Background render / encode / main-actor publication, separate stage p95s | not recorded | 0.28 / 2.35 / 0.09 ms |

The phase 5 pipeline probe uses two warmup iterations before the 30 samples. These warmed measurements are not directly comparable to the one-shot probes and do not prove a real-capture latency target. Phase 6 measures large synthetic images with 100 mixed annotations; real screenshot timings, physical frame-time measurements, and live memory/leak checks remain open. Automated tests verify background execution, one-worker concurrency, stale-result rejection, and release of output pixels and PNGs after success or cancellation.

Recorded 2026-08-23 on an Apple M4, built-in 2560×1664 Retina display, no external monitors. Interactive capture, selection-spike, and post-editor RSS were not taken in this session.

| Check | Target | Measured |
| --- | --- | --- |
| Idle resident memory (`ps` RSS) | < 35 MB | 37.0 MB after 8 s settle. Miss. |
| Idle `phys_footprint` | — | 11 MB |
| Hotkey to overlay | < 300 ms | not measured (needs a real ScreenCaptureKit capture; signposts are wired) |
| Snapshot to overlay | < 100 ms | not measured |
| Mouse-up to clipboard | < 50 ms | 9.4 ms crop+PNG-encode of an 800×600 region from a 1920×1080 buffer in `swift test` (debug, no pasteboard write) |
| Annotation mouse-up to clipboard | < 50 ms | 5.9 ms render+PNG-encode of 800×600 with arrow, rectangle, and privacy block in `swift test` (debug, no pasteboard write) |
| Memory after editor close vs baseline | within 10 MB in 2 s | not measured |
| 50-cycle session objects | zero live session objects | pass (`swift test` lifetime counters) |
| 50-cycle `leaks` | zero Snap-owned definite leaks | not run against a live 50-cycle GUI session. Idle `leaks` showed Foundation/XPC/libdispatch noise only, no Snap stacks. |

`ps` RSS on this OS includes a large shared-cache dirty component. `footprint` is the better idle number; RSS is what the plan named, so the 37 MB miss stays in the table.

Sample a running process, or launch `dist/Snap.app` for an idle reading:

```bash
./scripts/sample-memory.sh
./scripts/sample-memory.sh --launch
```

After fifty real capture/select/annotate/close cycles, point `leaks` at the live pid:

```bash
./scripts/leaks-check.sh
```

Treat any definitely lost allocation rooted in Snap code, any surviving session object, or monotonic RSS growth as a release blocker.

## Manual matrix still needed

These still need a human on this machine:

Computer Use was not approved to control Snap, and the opt-in real-capture test runner lacked Screen Recording access. Neither unavailable check is recorded as passing. The [phase 6 report](PHASE6_VALIDATION.md) distinguishes synthetic evidence from each live release gate.

- Single display, and pointer-based capture on every monitor
- Retina and mixed scale
- Displays with negative origins
- Spaces, and a full-screen app
- Denied then granted Screen Recording permission
- Repeated rapid captures
- Every keyboard control
- Instruments timings for hotkey-to-overlay and snapshot-to-overlay
- RSS during selection, during annotation, and within 2 s after editor close
- Fifty real capture/select/annotate/close cycles under `./scripts/leaks-check.sh`
