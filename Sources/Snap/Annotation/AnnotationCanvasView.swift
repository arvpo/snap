import AppKit
import CoreGraphics

/// Displays the cropped base image and handles pointer interaction for the
/// active tool. Annotations are stored and previewed in image-space
/// coordinates, so resizing the window or changing display scale never
/// alters exported geometry.
@MainActor
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    var currentTool: AnnotationTool = .arrow {
        didSet {
            cancelGesture()
            if currentTool != .select { selectedAnnotationID = nil }
        }
    }
    var textStyle = TextStyle()
    var onTextCommit: ((TextEditingSession) -> Void)?
    var onEditingStateChanged: (() -> Void)?
    var onTextStyleChanged: ((TextStyle) -> Void)?
    private(set) var textSession: TextEditingSession? {
        didSet {
            invalidateTextSession(oldValue)
            invalidateTextSession(textSession)
        }
    }
    private(set) var textEditor: AnnotationTextView?
    private var entries: [Annotation] = []
    private var annotationBounds: [UUID: CGRect] = [:]
    // Useful for verifying dirty-rectangle culling without changing export rendering.
    private(set) var lastDrawnAnnotationCount = 0
    var onCommit: ((AnnotationValue) -> Void)?
    var onUpdate: ((UUID, AnnotationValue) -> Void)?
    var onDelete: ((UUID) -> Void)?
    private(set) var selectedAnnotationID: UUID? {
        didSet {
            invalidateImageRect(oldValue.flatMap { annotationBounds[$0] })
            invalidateImageRect(selectedAnnotationID.flatMap { annotationBounds[$0] })
        }
    }
    private struct Manipulation {
        let entry: Annotation
        let start: CGPoint
        let resizing: Bool
        var preview: AnnotationValue?
    }
    private var manipulation: Manipulation? {
        didSet {
            invalidateValue(oldValue.map { $0.preview ?? $0.entry.value })
            invalidateValue(manipulation.map { $0.preview ?? $0.entry.value })
        }
    }
    var onUndo: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToolSelected: ((AnnotationTool) -> Void)?

    // Not layer-backed: `draw(_:)` paints the base image and intersecting
    // annotations into AppKit's clipped backing store. Setting `layer.contents`
    // separately while also overriding `draw(_:)` would be a mistake on a
    // layer-backed view, since AppKit re-derives the layer's contents from
    // `draw(_:)` on every display pass and would silently discard it.
    private var baseImage: CGImage?
    private let imagePixelSize: CGSize
    private var previewAnnotation: AnnotationValue? {
        didSet { invalidateValue(oldValue); invalidateValue(previewAnnotation) }
    }
    private var dragStart: CGPoint?
    private var textDragRect: CGRect? {
        didSet { invalidateImageRect(oldValue); invalidateImageRect(textDragRect) }
    }

    init(baseImage: CGImage) {
        self.baseImage = baseImage
        self.imagePixelSize = CGSize(width: baseImage.width, height: baseImage.height)
        super.init(frame: .zero)
        clipsToBounds = true
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
        let oldEntries = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.id, $0.value) })
        let newEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.value) })
        var newBounds: [UUID: CGRect] = [:]
        for entry in entries {
            let unchanged = oldEntries[entry.id] == entry.value
            let rect = unchanged ? annotationBounds[entry.id] ?? AnnotationLayout.bounds(of: entry.value)
                                 : AnnotationLayout.bounds(of: entry.value)
            newBounds[entry.id] = rect
            if !unchanged {
                invalidateImageRect(annotationBounds[entry.id])
                invalidateImageRect(rect)
            }
        }
        for entry in self.entries where newEntries[entry.id] == nil {
            invalidateImageRect(annotationBounds[entry.id])
        }
        // Reordering changes overlapping pixels even when all values are equal.
        if self.entries.filter({ newEntries[$0.id] != nil }).map(\.id)
            != entries.filter({ oldEntries[$0.id] != nil }).map(\.id) {
            for entry in entries { invalidateImageRect(newBounds[entry.id]) }
        }
        self.entries = entries
        annotationBounds = newBounds
        if let selectedAnnotationID, newEntries[selectedAnnotationID] == nil {
            self.selectedAnnotationID = nil
        }
    }

    private func invalidateValue(_ value: AnnotationValue?) {
        invalidateImageRect(value.map { AnnotationLayout.bounds(of: $0) })
    }

    private func invalidateTextSession(_ session: TextEditingSession?) {
        guard let session else { return }
        if let id = session.annotationID { invalidateImageRect(annotationBounds[id]) }
        var draft = session.draft
        if draft.text.isEmpty { draft.text = "\u{200B}" }
        invalidateValue(.text(draft))
    }

    private func invalidateImageRect(_ rect: CGRect?) {
        guard let rect, !rect.isNull else { return }
        let scale = imageToViewScale
        // Includes antialias fringes, dashed selection borders and width handles.
        let viewRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                              width: rect.width * scale, height: rect.height * scale)
            .insetBy(dx: -8, dy: -8).intersection(bounds)
        if !viewRect.isNull { setNeedsDisplay(viewRect) }
        // AppKit coalesces invalidations until its next display pass. Do not
        // call display() from event handling or encode a gesture preview.
    }

    /// Clears every closure and retained pixel so the view can deinitialize
    /// with nothing left over once the editor closes.
    func releaseResources() {
        endTextEditing(commit: false)
        onTextCommit = nil
        onTextStyleChanged = nil
        onEditingStateChanged = nil
        entries = []
        annotationBounds = [:]
        onCommit = nil
        onUpdate = nil
        onDelete = nil
        selectedAnnotationID = nil
        manipulation = nil
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
        cancelGesture()
        window?.makeFirstResponder(self)
        let point = imagePoint(from: event)
        if currentTool == .select {
            if let selected = entries.first(where: { $0.id == selectedAnnotationID }),
               let handle = AnnotationSelection.widthHandle(for: selected.value, scale: imageToViewScale, imageSize: imagePixelSize),
               handle.contains(point), event.clickCount == 1 {
                manipulation = Manipulation(entry: selected, start: point, resizing: true)
                return
            }
            let hit = AnnotationSelection.hitTest(point, entries: entries, scale: imageToViewScale)
            let wasSelected = hit?.id == selectedAnnotationID
            selectedAnnotationID = hit?.id
            if let hit {
                if wasSelected, event.clickCount >= 2, case .text(let text) = hit.value {
                    beginTextEditing(TextEditingSession(annotationID: hit.id, draft: text))
                } else {
                    manipulation = Manipulation(entry: hit, start: point, resizing: false)
                }
            }
            return
        }
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
        if manipulation != nil {
            updateManipulation(to: imagePoint(from: event))
            return
        }
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
    }

    override func mouseUp(with event: NSEvent) {
        if manipulation != nil {
            updateManipulation(to: imagePoint(from: event))
            let completed = manipulation
            manipulation = nil
            if let completed, let preview = completed.preview, preview != completed.entry.value {
                onUpdate?(completed.entry.id, preview)
            }
            return
        }
        guard let dragStart else { return }
        let current = imagePoint(from: event)
        self.dragStart = nil
        textDragRect = nil
        previewAnnotation = nil

        if currentTool == .text {
            var style = textStyle
            style.fontSize /= max(imageToViewScale, 0.001)
            beginTextEditing(.new(from: dragStart, to: current, style: style))
        } else if currentTool == .number {
            let next = entries.reduce(1) { count, entry in
                if case .number = entry.value { return count + 1 }
                return count
            }
            onCommit?(.number(AnnotationSelection.marker(at: current, number: next,
                scale: imageToViewScale, imageSize: imagePixelSize)))
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
                cancelGesture()
                onUndo?()
                return
            case "c":
                // Explicitly copy the final image and close, like the tick button.
                onFinish?()
                return
            default:
                super.keyDown(with: event)
                return
            }
        }

        switch event.keyCode {
        case 48: // Tab / Shift+Tab enter the toolbar's native key-view loop.
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        case 53: // Esc
            if manipulation != nil || dragStart != nil {
                cancelGesture()
                return
            }
            if selectedAnnotationID != nil {
                selectedAnnotationID = nil
                return
            }
            onCancel?()
            return
        case 51, 117: // Delete, forward Delete
            if currentTool == .select, let selectedAnnotationID {
                cancelGesture()
                onDelete?(selectedAnnotationID)
            }
            return
        case 36, 76: // Return, keypad Enter
            // Return commits native text only; it never copies the image.
            return
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            currentTool = .select
            onToolSelected?(.select)
        case "n":
            currentTool = .number
            onToolSelected?(.number)
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
        cancelGesture()
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
        addSubview(editor)
        updateTextEditorAppearance()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        onEditingStateChanged?()
    }

    func cancelGesture() {
        manipulation = nil
        dragStart = nil
        textDragRect = nil
        previewAnnotation = nil
    }

    private func updateManipulation(to point: CGPoint) {
        guard var gesture = manipulation else { return }
        let offset = CGSize(width: point.x - gesture.start.x, height: point.y - gesture.start.y)
        // A click must not accidentally move a value or wrap natural-width text.
        let distance = gesture.resizing ? abs(offset.width) : hypot(offset.width, offset.height)
        if gesture.preview == nil, distance * imageToViewScale < 3 { return }
        if gesture.resizing, case .text(let text) = gesture.entry.value {
            gesture.preview = .text(AnnotationSelection.resized(text, by: offset.width,
                scale: imageToViewScale, imageSize: imagePixelSize))
        } else {
            gesture.preview = AnnotationSelection.moved(gesture.entry.value, by: offset, imageSize: imagePixelSize)
        }
        manipulation = gesture
    }

    func setTextStyle(_ style: TextStyle, restoreFocus: Bool = true) {
        textStyle = style
        if textSession != nil {
            var imageStyle = style
            imageStyle.fontSize /= max(imageToViewScale, 0.001)
            textSession?.draft.style = imageStyle
            updateTextEditorAppearance()
            if restoreFocus { window?.makeFirstResponder(textEditor) }
        } else if restoreFocus {
            window?.makeFirstResponder(self)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor else { return }
        textSession?.draft.text = editor.string
        onEditingStateChanged?()
        layoutTextEditor()
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
        if commit { onTextCommit?(session) }
        onEditingStateChanged?()
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
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: dirtyRect)

        if let baseImage {
            // `CGContext.draw(_:in:)` has its own fixed sense of "up" that
            // ignores the current transform's handedness, so in this
            // flipped view it draws upside down unless we counter-flip
            // just for this call. Path-based annotation drawing below has
            // no such quirk and needs no adjustment.
            context.saveGState()
            context.setBlendMode(.copy)
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(baseImage, in: CGRect(origin: .zero, size: bounds.size))
            context.restoreGState()
        }

        let scale = imageToViewScale
        guard scale > 0 else { return }

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(false)
        let dirtyImageRect = CGRect(x: dirtyRect.minX / scale, y: dirtyRect.minY / scale,
                                    width: dirtyRect.width / scale, height: dirtyRect.height / scale)
        lastDrawnAnnotationCount = 0
        for entry in entries where entry.id != textSession?.annotationID {
            let value = entry.id == manipulation?.entry.id ? manipulation?.preview ?? entry.value : entry.value
            let rect = entry.id == manipulation?.entry.id ? AnnotationLayout.bounds(of: value)
                : annotationBounds[entry.id] ?? .null
            guard rect.intersects(dirtyImageRect) else { continue }
            lastDrawnAnnotationCount += 1
            ImageRenderer.draw(value, in: context)
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
        if currentTool == .select, textSession == nil,
           let entry = entries.first(where: { $0.id == selectedAnnotationID }) {
            let value = manipulation?.preview ?? entry.value
            if let rect = AnnotationSelection.bounds(of: value) {
                context.setShouldAntialias(true)
                context.setStrokeColor(NSColor.systemBlue.cgColor)
                context.setLineWidth(1 / scale)
                context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
                context.stroke(rect.insetBy(dx: -2 / scale, dy: -2 / scale))
                if let handle = AnnotationSelection.widthHandle(for: value, scale: scale, imageSize: imagePixelSize) {
                    context.setLineDash(phase: 0, lengths: [])
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(handle)
                    context.stroke(handle)
                }
            }
        }
        context.restoreGState()
    }
}
