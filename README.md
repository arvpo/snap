# Snap

A small macOS screenshot tool. Press `Cmd+Shift+X`, drag a rectangle, annotate, and the image is already on the clipboard.

It exists because Flameshot can sit at 300 MB and climb toward 3 GB. Snap captures only the monitor under the pointer, keeps one full-display buffer, copies the selected crop, then releases everything it can. After the editor closes it must retain no screenshot pixels. A leak or a rising memory line across repeated captures is a release-blocking bug.

## Status

Phases 1 through 4 are implemented. Snap captures the display under the pointer, presents a full-screen region selector, immediately copies a deep-copied crop to the clipboard, then opens an annotation editor with arrow, outline rectangle, and privacy block tools. Mixed-display conversion, crop pixels, annotation geometry, undo, and the render-generation guard are covered by automated tests. Integration, latency/memory measurement, and packaging polish are Phase 5.

## What it will do

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

## Latency targets

- Under 300 ms from hotkey to visible frozen overlay.
- Under 100 ms from completed snapshot to overlay.
- Under 50 ms from mouse-up to clipboard refresh for an ordinary region.

Record measured numbers here once Phase 5 exists. Do not invent them.

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

Fill this in during Phase 5. Empty cells mean the work is not done.

| Check | Target | Measured |
| --- | --- | --- |
| Idle resident memory | < 35 MB | |
| Hotkey to overlay | < 300 ms | |
| Snapshot to overlay | < 100 ms | |
| Mouse-up to clipboard | < 50 ms | |
| Memory after editor close vs baseline | within 10 MB in 2 s | |
| 50-cycle `leaks` | zero Snap-owned definite leaks | |
