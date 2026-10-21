import AppKit

/// Compact editor chrome. Styles live in a transient popover, never in the canvas.
@MainActor
final class AnnotationToolbarView: NSView, NSPopoverDelegate {
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onTextStyleChanged: ((TextStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onDone: (() -> Void)?
    var onPopoverClosed: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?

    private var style = TextStyle()
    private let presentation = NSPopUpButton(frame: .zero, pullsDown: false)
    private let color = NSPopUpButton(frame: .zero, pullsDown: false)
    private let size = NSPopUpButton(frame: .zero, pullsDown: false)
    let stylePopover = NSPopover()
    private var toolButtons: [AnnotationTool: ToolbarButton] = [:]
    private var orderedButtons: [ToolbarButton] = []
    private var styleButton: ToolbarButton!
    private var undoButton: ToolbarButton!
    private var selectedTool: AnnotationTool = .arrow
    private var isEditingText = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        setAccessibilityElement(false)
        setAccessibilityLabel("Annotation tools")

        let tools: [(AnnotationTool, String, String, String)] = [
            (.select, "cursorarrow", "Select", "V"),
            (.arrow, "arrow.up.right", "Arrow", "A"),
            (.rectangle, "rectangle", "Rectangle", "R"),
            (.privacyBlock, "rectangle.fill", "Privacy block", "B"),
            (.text, "textformat", "Text", "T"),
            (.number, "1.circle", "Number", "N")
        ]
        for (tool, symbol, label, shortcut) in tools {
            toolButtons[tool] = addButton(symbol: symbol, label: label, tooltip: "\(label)  (\(shortcut))") { [weak self] in
                self?.onToolSelected?(tool)
            }
        }
        styleButton = addButton(symbol: "slider.horizontal.3", label: "Text style", tooltip: "Text style: presentation, color, and size") { [weak self] in
            self?.toggleStylePopover()
        }
        undoButton = addButton(symbol: "arrow.uturn.backward", label: "Undo", tooltip: "Undo  (⌘Z)") { [weak self] in self?.onUndo?() }
        _ = addButton(symbol: "checkmark", label: "Done", tooltip: "Copy image and close  (⌘C)") { [weak self] in self?.onDone?() }

        let content = NSView(frame: CGRect(x: 0, y: 0, width: 248, height: 152))
        presentation.addItems(withTitles: ["Plain", "Callout"])
        color.addItems(withTitles: ["Red", "Blue", "Green", "Yellow", "Black", "White"])
        size.addItems(withTitles: ["14 pt", "18 pt", "24 pt"])
        for (index, pair) in [(presentation, "Presentation"), (color, "Color"), (size, "Font size")].enumerated() {
            let (control, label) = pair
            let y = CGFloat(108 - index * 40)
            let title = NSTextField(labelWithString: label)
            title.frame = CGRect(x: 16, y: y + 4, width: 92, height: 18)
            title.font = .systemFont(ofSize: 12)
            content.addSubview(title)
            control.frame = CGRect(x: 110, y: y, width: 122, height: 26)
            control.target = self
            control.action = #selector(changeStyle)
            control.setAccessibilityLabel(label == "Font size" ? label : "Text \(label.lowercased())")
            content.addSubview(control)
        }
        let controller = NSViewController()
        controller.view = content
        stylePopover.contentViewController = controller
        stylePopover.contentSize = content.frame.size
        stylePopover.behavior = .transient
        stylePopover.animates = false
        stylePopover.delegate = self
        setTextStyle(TextStyle())
        setSelectedTool(.arrow)
        setCanUndo(false)
        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { super.keyDown(with: event) }
        else { onKeyDown?(event) }
    }

    func connectKeyViewLoop(to canvas: NSView) {
        var previous = canvas
        for button in orderedButtons {
            previous.nextKeyView = button
            previous = button
        }
        previous.nextKeyView = canvas
    }

    func setSelectedTool(_ tool: AnnotationTool) {
        selectedTool = tool
        for (candidate, button) in toolButtons { button.state = candidate == tool ? .on : .off }
        updateStyleAvailability()
    }

    func setEditingText(_ editing: Bool) {
        isEditingText = editing
        updateStyleAvailability()
    }

    func setCanUndo(_ canUndo: Bool) { undoButton.isEnabled = canUndo }

    private func updateStyleAvailability() {
        styleButton.isEnabled = selectedTool == .text || isEditingText
        if !styleButton.isEnabled { stylePopover.close() }
    }

    func toggleStylePopover() {
        guard styleButton.isEnabled else { return }
        if stylePopover.isShown { stylePopover.performClose(nil) }
        else { stylePopover.show(relativeTo: styleButton.bounds, of: styleButton, preferredEdge: .minY) }
    }

    func popoverDidClose(_ notification: Notification) { onPopoverClosed?() }

    func releaseResources() {
        onPopoverClosed = nil
        stylePopover.delegate = nil
        stylePopover.close()
        stylePopover.contentViewController = nil
        onTextStyleChanged = nil
        onToolSelected = nil
        onUndo = nil
        onDone = nil
        onKeyDown = nil
    }

    func setTextStyle(_ style: TextStyle) {
        self.style = style
        presentation.selectItem(at: style.presentation == .plain ? 0 : 1)
        color.selectItem(at: AnnotationColor.allCases.firstIndex(of: style.color) ?? 0)
        let sizes: [CGFloat] = [14, 18, 24]
        size.selectItem(at: sizes.indices.min(by: { abs(sizes[$0] - style.fontSize) < abs(sizes[$1] - style.fontSize) }) ?? 1)
    }

    @objc private func changeStyle(_ sender: NSPopUpButton) {
        style.presentation = presentation.indexOfSelectedItem == 0 ? .plain : .callout
        style.color = AnnotationColor.allCases[color.indexOfSelectedItem]
        if sender === size { style.fontSize = [14.0, 18.0, 24.0][size.indexOfSelectedItem] }
        onTextStyleChanged?(style)
    }

    override func layout() { super.layout(); layoutButtons() }

    private func addButton(symbol: String, label: String, tooltip: String, action: @escaping () -> Void) -> ToolbarButton {
        let button = ToolbarButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        button.imagePosition = .imageOnly
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.toolTip = tooltip
        button.setAccessibilityLabel(label)
        addSubview(button)
        orderedButtons.append(button)
        return button
    }

    private func layoutButtons() {
        var x: CGFloat = 8
        for (index, button) in orderedButtons.enumerated() {
            if index == 7 { x += 8 }
            button.frame = CGRect(x: x, y: 7, width: 34, height: 34)
            x += 38
        }
    }
}

/// Native button actions/accessibility with matching pointer and keyboard states.
private final class ToolbarButton: NSButton {
    private let handler: () -> Void
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isEnabled }
    // Toolbar navigation remains available even when system-wide Full Keyboard
    // Access is off. The native key-view loop still skips disabled controls.
    override var canBecomeKeyView: Bool { isEnabled && !isHidden && window != nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else { super.keyDown(with: event) }
    }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let fill: NSColor = !isEnabled ? .clear : isHighlighted ? NSColor(white: 1, alpha: 0.24)
            : selected ? .systemRed.withAlphaComponent(0.25)
            : hovered ? NSColor(white: 1, alpha: 0.10) : .clear
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        contentTintColor = !isEnabled ? NSColor(white: 1, alpha: 0.28) : selected ? .systemRed : .white
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
    @objc private func fire() { handler() }
}
