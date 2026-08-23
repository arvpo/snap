import AppKit
import CoreGraphics

/// Owns the borderless annotation window, its canvas, and its toolbar for
/// one session. `Enter` and `Esc` both close the editor and keep whatever is
/// already on the clipboard; neither rolls the clipboard back.
@MainActor
final class AnnotationWindowController {
    private let document: AnnotationDocument
    private let pipeline: AnnotationRenderPipeline
    private var window: NSWindow?
    private var canvasView: AnnotationCanvasView?
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
    }

    func show() {
        guard window == nil else { return }

        let pixelSize = CGSize(width: document.baseImage.width, height: document.baseImage.height)
        let windowFrame = Self.windowFrame(forImagePixelSize: pixelSize)

        let canvasView = AnnotationCanvasView(baseImage: document.baseImage)
        canvasView.frame = CGRect(origin: .zero, size: windowFrame.size)
        canvasView.currentTool = document.currentTool
        canvasView.onCommit = { [weak self] value in self?.commit(value) }
        canvasView.onUndo = { [weak self] in self?.undo() }
        canvasView.onFinish = { [weak self] in self?.finish() }
        canvasView.onCancel = { [weak self] in self?.finish() }
        canvasView.onToolSelected = { [weak self] tool in self?.selectTool(tool) }

        let toolbarSize = CGSize(width: 220, height: 44)
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

    private func selectTool(_ tool: AnnotationTool) {
        document.currentTool = tool
        canvasView?.currentTool = tool
        toolbar?.setSelectedTool(tool)
    }

    private func commit(_ value: AnnotationValue) {
        document.commit(value)
        canvasView?.setAnnotations(document.annotations)
        pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
    }

    private func undo() {
        guard document.undo() else { return }
        canvasView?.setAnnotations(document.annotations)
        pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
    }

    private func finish() {
        guard !isFinishing, window != nil else { return }
        isFinishing = true
        let callback = onFinished
        tearDown()
        callback?()
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

        let maxSize = CGSize(
            width: screen.visibleFrame.width * 0.85,
            height: screen.visibleFrame.height * 0.85
        )
        let scale = min(1, min(maxSize.width / pixelSize.width, maxSize.height / pixelSize.height))
        let size = CGSize(
            width: (pixelSize.width * scale).rounded(),
            height: (pixelSize.height * scale).rounded()
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
