import AppKit
import CoreGraphics

/// Displays the cropped base image and handles pointer interaction for the
/// active tool. Annotations are stored and previewed in image-space
/// coordinates, so resizing the window or changing display scale never
/// alters exported geometry.
@MainActor
final class AnnotationCanvasView: NSView {
    var currentTool: AnnotationTool = .arrow
    var onCommit: ((AnnotationValue) -> Void)?
    var onUndo: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToolSelected: ((AnnotationTool) -> Void)?

    private let imagePixelSize: CGSize
    private var committedAnnotations: [AnnotationValue] = []
    private var previewAnnotation: AnnotationValue?
    private var dragStart: CGPoint?

    init(baseImage: CGImage) {
        self.imagePixelSize = CGSize(width: baseImage.width, height: baseImage.height)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.contents = baseImage
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setAnnotations(_ annotations: [AnnotationValue]) {
        committedAnnotations = annotations
        needsDisplay = true
    }

    /// Clears every closure and retained pixel so the view can deinitialize
    /// with nothing left over once the editor closes.
    func releaseResources() {
        onCommit = nil
        onUndo = nil
        onFinish = nil
        onCancel = nil
        onToolSelected = nil
        dragStart = nil
        previewAnnotation = nil
        committedAnnotations = []
        layer?.contents = nil
    }

    private var imageToViewScale: CGFloat {
        guard imagePixelSize.width > 0 else { return 1 }
        return bounds.width / imagePixelSize.width
    }

    private func imagePoint(from event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let clampedX = min(max(local.x, 0), bounds.width)
        let clampedY = min(max(local.y, 0), bounds.height)
        let scale = imageToViewScale
        guard scale > 0 else { return .zero }
        return CGPoint(x: clampedX / scale, y: clampedY / scale)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = imagePoint(from: event)
        previewAnnotation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = imagePoint(from: event)
        previewAnnotation = AnnotationBuilder.makeAnnotation(
            for: currentTool,
            from: dragStart,
            to: current,
            minimumSize: 0
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return }
        let current = imagePoint(from: event)
        self.dragStart = nil
        previewAnnotation = nil
        needsDisplay = true

        if let value = AnnotationBuilder.makeAnnotation(for: currentTool, from: dragStart, to: current) {
            onCommit?(value)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            onUndo?()
            return
        }

        switch event.keyCode {
        case 53: // Esc
            onCancel?()
            return
        case 36, 76: // Return, keypad Enter
            onFinish?()
            return
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a":
            currentTool = .arrow
            onToolSelected?(.arrow)
        case "r":
            currentTool = .rectangle
            onToolSelected?(.rectangle)
        case "b":
            currentTool = .privacyBlock
            onToolSelected?(.privacyBlock)
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = imageToViewScale
        guard scale > 0 else { return }

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        for value in committedAnnotations {
            ImageRenderer.draw(value, in: context)
        }
        if let previewAnnotation {
            ImageRenderer.draw(previewAnnotation, in: context)
        }
        context.restoreGState()
    }
}
