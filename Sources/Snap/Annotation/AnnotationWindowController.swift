import AppKit
import CoreGraphics

/// Owns the borderless annotation window, its canvas, and its toolbar for
/// one session. `Enter`, `Cmd+C`, and the done button all close the editor
/// and publish the final annotated image; `Esc` closes the same way
/// without rolling the clipboard back.
@MainActor
final class AnnotationWindowController {
    let document: AnnotationDocument
    private let pipeline: AnnotationRenderPipeline
    private var window: NSWindow?
    private(set) var canvasView: AnnotationCanvasView?
    private var toolbar: AnnotationToolbarView?
    private var isFinishing = false

    private var onFinished: (() -> Void)?

    init(
        baseImage: CGImage,
        clipboardService: ClipboardServicing,
        onFinished: @escaping () -> Void
    ) {
        self.document = AnnotationDocument(baseImage: baseImage)
        self.pipeline = AnnotationRenderPipeline(clipboardService: clipboardService)
        self.onFinished = onFinished
        SessionLifetime.retain(.editorController)
    }

    deinit {
        SessionLifetime.release(.editorController)
    }

    func show() {
        guard window == nil else { return }

        let pixelSize = CGSize(width: document.baseImage.width, height: document.baseImage.height)
        let windowFrame = Self.windowFrame(forImagePixelSize: pixelSize)

        let canvasView = AnnotationCanvasView(baseImage: document.baseImage)
        canvasView.frame = CGRect(origin: .zero, size: windowFrame.size)
        canvasView.currentTool = document.currentTool
        canvasView.onCommit = { [weak self] value in self?.commit(value) }
        canvasView.onTextCommit = { [weak self] session in self?.commitText(session) }
        canvasView.onTextStyleChanged = { [weak self] style in self?.toolbar?.setTextStyle(style) }
        canvasView.onUndo = { [weak self] in self?.undo() }
        canvasView.onFinish = { [weak self] in self?.finish() }
        canvasView.onCancel = { [weak self] in self?.finish() }
        canvasView.onToolSelected = { [weak self] tool in self?.selectTool(tool) }

        let toolbarSize = CGSize(width: 250, height: 44)
        let toolbar = AnnotationToolbarView(
            frame: CGRect(
                x: (windowFrame.width - toolbarSize.width) / 2,
                y: 14,
                width: toolbarSize.width,
                height: toolbarSize.height
            )
        )
        toolbar.autoresizingMask = [.minXMargin, .maxXMargin]
        toolbar.setSelectedTool(document.currentTool)
        toolbar.onToolSelected = { [weak self] tool in self?.selectTool(tool) }
        toolbar.onTextStyleChanged = { [weak self] style in self?.canvasView?.setTextStyle(style) }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onDone = { [weak self] in self?.finish() }
        canvasView.addSubview(toolbar)

        let window = AnnotationWindow(
            contentRect: windowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .transient,
        ]
        window.isReleasedWhenClosed = false
        window.contentView = canvasView
        window.setFrame(windowFrame, display: false)
        window.center()

        self.canvasView = canvasView
        self.toolbar = toolbar
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvasView)
    }

    /// Tears the session down without the "finished" callback, used when the
    /// coordinator is force-returned to idle (e.g. app termination).
    func close() {
        guard window != nil else { return }
        isFinishing = true
        tearDown()
    }

    func selectTool(_ tool: AnnotationTool) {
        canvasView?.endTextEditing(commit: true)
        document.currentTool = tool
        canvasView?.currentTool = tool
        toolbar?.setSelectedTool(tool)
        toolbar?.setFrameSize(CGSize(width: 250, height: tool == .text ? 78 : 44))
        window?.makeFirstResponder(canvasView)
    }

    private func commit(_ value: AnnotationValue) {
        document.commit(value)
        canvasView?.setAnnotations(document.entries)
        pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
    }

    private func commitText(_ session: TextEditingSession) {
        guard session.commit(to: document) else { return }
        canvasView?.setAnnotations(document.entries)
        if !isFinishing {
            pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
        }
    }

    private func undo() {
        if let editor = canvasView?.textEditor {
            editor.undoManager?.undo()
            return
        }
        guard document.undo() else { return }
        canvasView?.setAnnotations(document.entries)
        pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
    }

    /// `Enter`, `Cmd+C`, `Esc`, and the done button all land here. Hides the
    /// window immediately, commits active text, and waits for the final image
    /// publication before teardown, including when native Copy replaced it.
    func finish() {
        guard !isFinishing, window != nil else { return }
        isFinishing = true
        canvasView?.endTextEditing(commit: true)
        // Native Copy/Cut can replace the image with text even if there are no
        // document changes. Always publish a fresh final snapshot on Done.
        pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
        window?.orderOut(nil)
        let callback = onFinished

        Task { [weak self] in
            await self?.pipeline.awaitPendingRender()
            guard let self else {
                callback?()
                return
            }
            self.tearDown()
            callback?()
        }
    }

    private func tearDown() {
        pipeline.invalidate()
        canvasView?.releaseResources()
        toolbar?.releaseResources()
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()

        #if DEBUG
        weak let weakWindow = window
        weak let weakCanvas = canvasView
        weak let weakToolbar = toolbar
        #endif

        window = nil
        canvasView = nil
        toolbar = nil
        onFinished = nil
        document.removeAll()

        #if DEBUG
        DispatchQueue.main.async {
            assert(weakWindow == nil, "AnnotationWindowController leaked its window")
            assert(weakCanvas == nil, "AnnotationWindowController leaked its canvas view")
            assert(weakToolbar == nil, "AnnotationWindowController leaked its toolbar")
        }
        #endif
    }

    private static func windowFrame(forImagePixelSize pixelSize: CGSize) -> CGRect {
        guard let screen = NSScreen.main, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGRect(origin: .zero, size: pixelSize)
        }

        // `pixelSize` is in physical pixels; convert to points on this
        // screen first so a Retina capture doesn't open at 2x its natural
        // on-screen size before the 85%-of-screen fit is even applied.
        let backingScale = max(screen.backingScaleFactor, 1)
        let nativePointSize = CGSize(
            width: pixelSize.width / backingScale,
            height: pixelSize.height / backingScale
        )

        let maxSize = CGSize(
            width: screen.visibleFrame.width * 0.85,
            height: screen.visibleFrame.height * 0.85
        )
        let scale = min(1, min(maxSize.width / nativePointSize.width, maxSize.height / nativePointSize.height))
        let size = CGSize(
            width: (nativePointSize.width * scale).rounded(),
            height: (nativePointSize.height * scale).rounded()
        )
        let origin = CGPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size)
    }
}

private final class AnnotationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
