import AppKit
import CoreGraphics

@MainActor
final class SelectionOverlayController {
    private var capturedDisplay: CapturedDisplay?
    private var window: SelectionOverlayWindow?
    private var overlayView: SelectionOverlayView?
    private var cursorIsPushed = false
    private var isFinishing = false

    private var onSelection: ((CGImage) -> Void)?
    private var onCancel: (() -> Void)?
    private var onFailure: ((Error) -> Void)?

    init(
        onSelection: @escaping (CGImage) -> Void,
        onCancel: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.onSelection = onSelection
        self.onCancel = onCancel
        self.onFailure = onFailure
        SessionLifetime.retain(.overlayController)
    }

    deinit {
        SessionLifetime.release(.overlayController)
    }

    func show(_ capturedDisplay: CapturedDisplay) {
        guard window == nil else { return }
        self.capturedDisplay = capturedDisplay

        let localFrame = CGRect(origin: .zero, size: capturedDisplay.appKitFrame.size)
        let view = SelectionOverlayView(frame: localFrame, capturedDisplay: capturedDisplay)
        view.onSelection = { [weak self] selection in
            self?.complete(selection)
        }
        view.onCancel = { [weak self] in
            self?.cancel()
        }

        let window = SelectionOverlayWindow(
            contentRect: capturedDisplay.appKitFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .transient,
        ]
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrame(capturedDisplay.appKitFrame, display: false)

        self.overlayView = view
        self.window = window

        NSCursor.crosshair.push()
        cursorIsPushed = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func cancel() {
        guard !isFinishing, window != nil else { return }
        isFinishing = true
        let callback = onCancel
        tearDown()
        callback?()
    }

    func close() {
        guard window != nil || capturedDisplay != nil else { return }
        isFinishing = true
        tearDown()
    }

    private func complete(_ selection: Selection) {
        guard !isFinishing,
              let capturedDisplay,
              window != nil
        else {
            return
        }
        isFinishing = true
        window?.orderOut(nil)

        CaptureSignposts.shared.begin(.mouseUpToFirstClipboard)

        do {
            let croppedImage = try SelectionCropper.deepCopy(
                capturedDisplay.image,
                pixelRect: selection.pixelRect
            )
            let callback = onSelection
            tearDown()
            callback?(croppedImage)
        } catch {
            CaptureSignposts.shared.abandon(.mouseUpToFirstClipboard)
            let callback = onFailure
            tearDown()
            callback?(error)
        }
    }

    private func tearDown() {
        overlayView?.releaseCapturedImage()
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()

        #if DEBUG
        weak let weakWindow = window
        weak let weakView = overlayView
        #endif

        overlayView = nil
        window = nil
        capturedDisplay = nil

        if cursorIsPushed {
            NSCursor.pop()
            cursorIsPushed = false
        }

        onSelection = nil
        onCancel = nil
        onFailure = nil

        #if DEBUG
        DispatchQueue.main.async {
            assert(weakWindow == nil, "SelectionOverlayController leaked its window")
            assert(weakView == nil, "SelectionOverlayController leaked its overlay view")
        }
        #endif
    }
}

private final class SelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
