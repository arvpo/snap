import AppKit

/// The floating toolbar exposes text styles while Text is selected.
@MainActor
final class AnnotationToolbarView: NSView {
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onTextStyleChanged: ((TextStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onDone: (() -> Void)?

    private var style = TextStyle()
    private let presentation = NSPopUpButton(frame: .zero, pullsDown: false)
    private let color = NSPopUpButton(frame: .zero, pullsDown: false)
    private let size = NSPopUpButton(frame: .zero, pullsDown: false)
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var orderedButtons: [NSButton] = []
    private var separatorIndices: Set<Int> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.88).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        let arrowButton = addButton(symbol: "arrow.up.right", tooltip: "Arrow  (A)") { [weak self] in
            self?.onToolSelected?(.arrow)
        }
        let rectangleButton = addButton(symbol: "rectangle", tooltip: "Rectangle  (R)") { [weak self] in
            self?.onToolSelected?(.rectangle)
        }
        let privacyButton = addButton(symbol: "rectangle.fill", tooltip: "Privacy block  (B)") { [weak self] in
            self?.onToolSelected?(.privacyBlock)
        }
        let textButton = addButton(symbol: "textformat", tooltip: "Text  (T)") { [weak self] in
            self?.onToolSelected?(.text)
        }
        toolButtons = [.text: textButton, .arrow: arrowButton, .rectangle: rectangleButton, .privacyBlock: privacyButton]

        addSeparator()

        _ = addButton(symbol: "arrow.uturn.backward", tooltip: "Undo  (⌘Z)") { [weak self] in
            self?.onUndo?()
        }
        _ = addButton(symbol: "checkmark", tooltip: "Done  (Enter)") { [weak self] in
            self?.onDone?()
        }

        presentation.addItems(withTitles: ["Plain", "Callout"])
        color.addItems(withTitles: ["Red", "Blue", "Green", "Yellow", "Black", "White"])
        size.addItems(withTitles: ["14 pt", "18 pt", "24 pt"])
        for (control, label) in [(presentation, "Text presentation"), (color, "Text color"), (size, "Font size")] {
            control.target = self
            control.action = #selector(changeStyle)
            control.font = .systemFont(ofSize: 11)
            control.setAccessibilityLabel(label)
            addSubview(control)
        }
        setTextStyle(TextStyle())
        setSelectedTool(.arrow)
        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelectedTool(_ tool: AnnotationTool) {
        for control in [presentation, color, size] { control.isHidden = tool != .text }
        for (candidate, button) in toolButtons {
            button.contentTintColor = candidate == tool ? .systemRed : .white
        }
    }

    /// Clears every closure so the toolbar retains nothing once the editor
    /// closes.
    func releaseResources() {
        onTextStyleChanged = nil
        onToolSelected = nil
        onUndo = nil
        onDone = nil
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

    override func layout() {
        super.layout()
        layoutButtons()
    }

    private func addButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.refusesFirstResponder = true
        button.imageScaling = .scaleProportionallyUpOrDown
        button.contentTintColor = .white
        button.toolTip = tooltip
        addSubview(button)
        orderedButtons.append(button)
        return button
    }

    private func addSeparator() {
        separatorIndices.insert(orderedButtons.count)
    }

    private func layoutButtons() {
        let buttonSize: CGFloat = 26
        let spacing: CGFloat = 6
        let separatorGap: CGFloat = 10
        var x: CGFloat = 8
        let y = bounds.height - 35
        presentation.frame = CGRect(x: 8, y: 7, width: 80, height: 24)
        color.frame = CGRect(x: 89, y: 7, width: 78, height: 24)
        size.frame = CGRect(x: 168, y: 7, width: 74, height: 24)

        for (index, button) in orderedButtons.enumerated() {
            if separatorIndices.contains(index) {
                x += separatorGap
            }
            button.frame = CGRect(x: x, y: y, width: buttonSize, height: buttonSize)
            x += buttonSize + spacing
        }
    }
}

/// A button that owns its own action closure instead of a target/selector
/// pair.
private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}
