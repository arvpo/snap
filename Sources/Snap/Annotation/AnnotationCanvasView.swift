import AppKit
import CoreGraphics

/// Displays the cropped base image and handles pointer interaction for the
/// active tool. Annotations are stored and previewed in image-space
/// coordinates, so resizing the window or changing display scale never
/// alters exported geometry.
@MainActor
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    var currentTool: AnnotationTool = .arrow
    var textStyle = TextStyle()
    var onTextCommit: ((TextEditingSession) -> Void)?
    var onTextStyleChanged: ((TextStyle) -> Void)?
    private(set) var textSession: TextEditingSession?
    private(set) var textEditor: AnnotationTextView?
    private var entries: [Annotation] = []
    var onCommit: ((AnnotationValue) -> Void)?
    var onUndo: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToolSelected: ((AnnotationTool) -> Void)?

    // Not layer-backed: `draw(_:)` paints the base image and every
    // annotation into one bitmap per pass. Setting `layer.contents`
    // separately while also overriding `draw(_:)` would be a mistake on a
    // layer-backed view, since AppKit re-derives the layer's contents from
    // `draw(_:)` on every display pass and would silently discard it.
    private var baseImage: CGImage?
    private let imagePixelSize: CGSize
    private var previewAnnotation: AnnotationValue?
    private var dragStart: CGPoint?
    private var textDragRect: CGRect?

    init(baseImage: CGImage) {
        self.baseImage = baseImage
        self.imagePixelSize = CGSize(width: baseImage.width, height: baseImage.height)
        super.init(frame: .zero)
        SessionLifetime.retain(.canvasView)
    }

    deinit {
        SessionLifetime.release(.canvasView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setAnnotations(_ entries: [Annotation]) {
        self.entries = entries
        needsDisplay = true
    }

    /// Clears every closure and retained pixel so the view can deinitialize
    /// with nothing left over once the editor closes.
    func releaseResources() {
        endTextEditing(commit: false)
        onTextCommit = nil
        onTextStyleChanged = nil
        entries = []
        onCommit = nil
        onUndo = nil
        onFinish = nil
        onCancel = nil
        onToolSelected = nil
        dragStart = nil
        textDragRect = nil
        previewAnnotation = nil
        baseImage = nil
        needsDisplay = true
    }

    var imageToViewScale: CGFloat {
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
        endTextEditing(commit: true)
        window?.makeFirstResponder(self)
        let point = imagePoint(from: event)
        if currentTool == .text, let entry = entries.reversed().first(where: {
            if case .text = $0.value { return AnnotationLayout.bounds(of: $0.value).contains(point) }
            return false
        }), case .text(let text) = entry.value {
            beginTextEditing(TextEditingSession(annotationID: entry.id, draft: text))
            return
        }
        dragStart = point
        previewAnnotation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = imagePoint(from: event)
        if currentTool == .text {
            textDragRect = CGRect(x: min(dragStart.x, current.x), y: min(dragStart.y, current.y),
                                  width: abs(current.x - dragStart.x),
                                  height: max(abs(current.y - dragStart.y), 18 / max(imageToViewScale, 0.001)))
        }
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
        textDragRect = nil
        previewAnnotation = nil
        needsDisplay = true

        if currentTool == .text {
            var style = textStyle
            style.fontSize /= max(imageToViewScale, 0.001)
            beginTextEditing(.new(from: dragStart, to: current, style: style))
        } else if let value = AnnotationBuilder.makeAnnotation(for: currentTool, from: dragStart, to: current) {
            onCommit?(value)
        }
    }

    override func keyDown(with event: NSEvent) {
        // NSTextView can forward an unhandled command through its responder
        // chain. Never reinterpret it as a drawing or finish shortcut.
        guard textEditor == nil else { return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                onUndo?()
                return
            case "c":
                // Same action as Enter/the done button: keep the latest
                // clipboard image and close the editor.
                onFinish?()
                return
            default:
                break
            }
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
        case "t":
            currentTool = .text
            onToolSelected?(.text)
        case "b":
            currentTool = .privacyBlock
            onToolSelected?(.privacyBlock)
        default:
            super.keyDown(with: event)
        }
    }

    func beginTextEditing(_ session: TextEditingSession) {
        endTextEditing(commit: true)
        textSession = session
        textStyle = session.draft.style
        textStyle.fontSize *= imageToViewScale
        onTextStyleChanged?(textStyle)

        let editor = AnnotationTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.usesFontPanel = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.string = session.draft.text
        editor.delegate = self
        editor.onCommit = { [weak self] in self?.endTextEditing(commit: true) }
        editor.onCancel = { [weak self] in self?.endTextEditing(commit: false) }
        textEditor = editor
        addSubview(editor, positioned: .below, relativeTo: subviews.first)
        updateTextEditorAppearance()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        needsDisplay = true
    }

    func setTextStyle(_ style: TextStyle) {
        textStyle = style
        if textSession != nil {
            var imageStyle = style
            imageStyle.fontSize /= max(imageToViewScale, 0.001)
            textSession?.draft.style = imageStyle
            updateTextEditorAppearance()
            window?.makeFirstResponder(textEditor)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor else { return }
        textSession?.draft.text = editor.string
        layoutTextEditor()
        needsDisplay = true
    }

    func endTextEditing(commit: Bool) {
        guard var session = textSession else { return }
        if let editor = textEditor {
            // Finishing via the toolbar also accepts a pending IME composition.
            if commit { editor.unmarkText() }
            session.draft.text = editor.string
            window?.makeFirstResponder(self)
            editor.releaseResources()
            editor.removeFromSuperview()
        }
        textEditor = nil
        textSession = nil
        needsDisplay = true
        if commit { onTextCommit?(session) }
    }

    private func updateTextEditorAppearance() {
        guard let editor = textEditor, let draft = textSession?.draft else { return }
        let font = NSFont.systemFont(ofSize: draft.style.fontSize * imageToViewScale)
        let cgColor = draft.style.presentation == .plain
            ? draft.style.color.cgColor : draft.style.color.contrastingColor
        let color = NSColor(cgColor: cgColor) ?? .red
        editor.font = font
        editor.textColor = color
        editor.insertionPointColor = color
        editor.typingAttributes = [.font: font, .foregroundColor: color]
        layoutTextEditor()
        needsDisplay = true
    }

    private func layoutTextEditor() {
        guard let editor = textEditor, var draft = textSession?.draft else { return }
        // Reserve a line and caret even before the first character is entered.
        if draft.text.isEmpty { draft.text = "\u{200B}" }
        guard let layout = AnnotationLayout.text(draft) else { return }
        let scale = imageToViewScale
        let content = layout.contentRect
        let width = draft.width.map { $0 * scale } ?? max(content.width * scale + 4, 40)
        editor.textContainer?.containerSize = CGSize(
            width: draft.width == nil ? 1_000_000 : width, height: 1_000_000
        )
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let usedHeight = editor.layoutManager?.usedRect(for: editor.textContainer!).height ?? 0
        editor.frame = CGRect(x: content.minX * scale, y: content.minY * scale,
                              width: width, height: max(content.height * scale, usedHeight) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let baseImage {
            // `CGContext.draw(_:in:)` has its own fixed sense of "up" that
            // ignores the current transform's handedness, so in this
            // flipped view it draws upside down unless we counter-flip
            // just for this call. Path-based annotation drawing below has
            // no such quirk and needs no adjustment.
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(baseImage, in: CGRect(origin: .zero, size: bounds.size))
            context.restoreGState()
        }

        let scale = imageToViewScale
        guard scale > 0 else { return }

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        for entry in entries where entry.id != textSession?.annotationID {
            ImageRenderer.draw(entry.value, in: context)
        }
        // The native editor draws the glyphs; use the shared layout for its
        // callout background so padding and export geometry stay identical.
        if var draft = textSession?.draft, draft.style.presentation == .callout {
            if draft.text.isEmpty { draft.text = "\u{200B}" }
            if let layout = AnnotationLayout.text(draft) {
                context.setShouldAntialias(true)
                context.setFillColor(draft.style.color.cgColor)
                let radius = max(1, layout.contentRect.minX - layout.backgroundRect.minX)
                context.addPath(CGPath(roundedRect: layout.backgroundRect, cornerWidth: radius,
                                       cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }
        if let textDragRect {
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(1 / scale)
            context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
            context.stroke(textDragRect)
        }
        if let previewAnnotation {
            ImageRenderer.draw(previewAnnotation, in: context)
        }
        context.restoreGState()
    }
}
