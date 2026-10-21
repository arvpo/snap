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
    private var undoObservers: [NSObjectProtocol] = []

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
        let screen = NSScreen.main
        let layout = AnnotationEditorLayout(imagePixelSize: pixelSize,
            visibleFrame: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768),
            backingScale: screen?.backingScaleFactor ?? 1)
        let windowFrame = layout.windowFrame
        let chrome = NSView(frame: CGRect(origin: .zero, size: windowFrame.size))
        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor

        let canvasView = AnnotationCanvasView(baseImage: document.baseImage)
        canvasView.frame = layout.canvasFrame
        chrome.addSubview(canvasView)
        canvasView.currentTool = document.currentTool
        canvasView.onCommit = { [weak self] value in self?.commit(value) }
        canvasView.onUpdate = { [weak self] id, value in
            guard let self, self.document.update(id: id, value: value) else { return }
            self.publishEdit()
        }
        canvasView.onDelete = { [weak self] id in
            guard let self, self.document.delete(id: id) else { return }
            self.publishEdit()
        }
        canvasView.onTextCommit = { [weak self] session in self?.commitText(session) }
        canvasView.onTextStyleChanged = { [weak self] style in self?.toolbar?.setTextStyle(style) }
        canvasView.onEditingStateChanged = { [weak self] in self?.updateToolbarState() }
        canvasView.onUndo = { [weak self] in self?.undo() }
        canvasView.onFinish = { [weak self] in self?.finish() }
        canvasView.onCancel = { [weak self] in self?.finish() }
        canvasView.onToolSelected = { [weak self] tool in self?.selectTool(tool) }

        let toolbar = AnnotationToolbarView(frame: layout.toolbarFrame)
        toolbar.setSelectedTool(document.currentTool)
        toolbar.onToolSelected = { [weak self] tool in self?.selectTool(tool) }
        toolbar.onTextStyleChanged = { [weak self] style in self?.canvasView?.setTextStyle(style, restoreFocus: false) }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onDone = { [weak self] in self?.finish() }
        toolbar.onPopoverClosed = { [weak self] in self?.restoreCanvasFocus() }
        toolbar.onKeyDown = { [weak canvasView] event in canvasView?.keyDown(with: event) }
        chrome.addSubview(toolbar)

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
        window.contentView = chrome
        window.setFrame(windowFrame, display: false)

        self.canvasView = canvasView
        self.toolbar = toolbar
        self.window = window

        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup,
                     .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateToolbarState() }
            })
        }
        updateToolbarState()
        window.autorecalculatesKeyViewLoop = false
        toolbar.connectKeyViewLoop(to: canvasView)
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
        updateToolbarState()
        window?.makeFirstResponder(canvasView)
    }

    private func restoreCanvasFocus() {
        guard !isFinishing, let canvasView else { return }
        window?.makeFirstResponder(canvasView.textEditor ?? canvasView)
    }

    private func updateToolbarState() {
        toolbar?.setEditingText(canvasView?.textEditor != nil)
        toolbar?.setCanUndo(canvasView?.textEditor?.undoManager?.canUndo ?? document.canUndo)
    }

    private func commit(_ value: AnnotationValue) {
        document.commit(value)
        publishEdit()
    }

    private func publishEdit() {
        canvasView?.setAnnotations(document.entries)
        updateToolbarState()
        pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
    }

    private func commitText(_ session: TextEditingSession) {
        guard session.commit(to: document) else { return }
        canvasView?.setAnnotations(document.entries)
        updateToolbarState()
        if !isFinishing {
            pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
        }
    }

    private func undo() {
        if let editor = canvasView?.textEditor {
            editor.undoManager?.undo()
            updateToolbarState()
            restoreCanvasFocus()
            return
        }
        canvasView?.cancelGesture()
        restoreCanvasFocus()
        guard document.undo() else { return }
        canvasView?.setAnnotations(document.entries)
        updateToolbarState()
        pipeline.scheduleRender(baseImage: document.baseImage, annotations: document.annotations)
    }

    /// `Enter`, `Cmd+C`, `Esc`, and the done button all land here. Hides the
    /// window immediately, commits active text, and waits for the final image
    /// publication before teardown, including when native Copy replaced it.
    func finish() {
        guard !isFinishing, window != nil else { return }
        isFinishing = true
        toolbar?.stylePopover.close()
        canvasView?.cancelGesture()
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
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers.removeAll()
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

}

private final class AnnotationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
