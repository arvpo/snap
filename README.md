# Snap

A small macOS screenshot tool. Press `Cmd+Shift+X`, drag a rectangle, annotate, and the image is already on the clipboard.

It exists because Flameshot can sit at 300 MB and climb toward 3 GB. Snap captures only the monitor under the pointer, keeps one full-display buffer, copies the selected crop, then releases everything it can. After the editor closes it must retain no screenshot pixels. A leak or a rising memory line across repeated captures is a release-blocking bug.

## Status

Phases 1 through 5 are implemented. Snap is a menu-bar app: global hotkey, pointer-display capture, region select, eager PNG clipboard, and a three-tool annotation editor. Automated tests cover mixed-display conversion, crop pixels, annotation geometry, undo, render-generation, coordinator transitions, presenter cancel/failure teardown, and 50-cycle session lifetime counters.

Local packaging stays ad-hoc signed. Developer ID, notarization, DMG, and App Store release are a later phase.

## What it does

- Run as a menu-bar app with no Dock icon.
- Start from `Cmd+Shift+X` or the menu-bar Capture item.
- Freeze only the display containing the mouse, then let you drag a region.
- Copy that crop to the clipboard immediately.
- Annotate with a red arrow, a red outline rectangle, or an opaque black privacy block.
- Recopy the clipboard after every completed annotation.
- Close with `Enter`. Cancel selection with `Esc`. Undo with `Cmd+Z`.

No file saving, history, upload, OCR, or preferences in the first version.

## Memory rules

These are not optional.

- Idle after launch settles: under 35 MB resident.
- During selection: at most one 4-byte-per-pixel buffer for the pointer’s display, plus 35 MB overhead. Unused monitors are never captured.
- During annotation: the cropped base image, at most one in-progress output buffer, one encoded PNG, plus 35 MB overhead. Undo stores vectors, not bitmaps.
- After each clipboard write: Snap retains no encoded PNG and no completed render buffer. The pasteboard process owns the copy.
- After the editor closes: Snap retains no screenshot pixels. Resident memory must return to within 10 MB of the pre-capture baseline within two seconds.
- Fifty capture/select/annotate/close cycles must not grow resident memory, must leave zero live session objects, and must show no definitely lost Snap-owned allocations under `leaks`.

A 5K display buffer is about 59 MB. That spike is allowed only while the overlay is up. It must be gone after selection or cancel.

On this machine the built-in display is 2560×1664 Retina. One 4-byte buffer is 16.3 MB, so the selection budget is 51.3 MB.

## Latency targets

- Under 300 ms from hotkey to visible frozen overlay.
- Under 100 ms from completed snapshot to overlay.
- Under 50 ms from mouse-up to clipboard refresh for an ordinary region.

Instruments: attach Snap and filter `com.stradeon.Snap` / `latency`. The intervals are `hotkey-to-snapshot`, `snapshot-to-overlay`, `mouse-up-to-first-clipboard`, and `annotation-mouse-up-to-clipboard`.

## Build

Needs macOS 14+ and Apple Command Line Tools. Full Xcode is not required for local development.

```bash
xcode-select -p
swift --version
```

```bash
swift build
swift test
./scripts/build-app.sh
open dist/Snap.app
```

`scripts/build-app.sh` is the normal launch path. It assembles `dist/Snap.app`, copies `Resources/Info.plist`, and ad-hoc signs the bundle. macOS Screen Recording permission is tied to that bundle identifier, so do not run the raw SwiftPM binary as the daily target.

Do not use `xcodebuild` for this project.

## First launch

The first capture will ask for Screen Recording access. Grant it in System Settings → Privacy & Security → Screen Recording, then trigger capture again.

If `Cmd+Shift+X` is already taken by another app, that other binding wins until it is removed. The shortcut is not configurable in the MVP.

## Keyboard

| Key | Action |
| --- | --- |
| `Cmd+Shift+X` | Start capture on the pointer’s display |
| `A` | Arrow |
| `R` | Outline rectangle |
| `B` | Privacy block |
| `Cmd+Z` | Undo |
| `Cmd+C` | Re-copy the current annotated image to the clipboard |
| `Delete` | Not implemented; selecting an existing annotation is out of scope for the MVP editor |
| `Enter` | Finish and keep the latest clipboard image |
| `Esc` | Cancel selection, or close the editor without rolling the clipboard back |

## Measurements

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
