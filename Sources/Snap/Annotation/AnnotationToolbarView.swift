import AppKit

/// The compact floating toolbar for arrow, outline rectangle, privacy block,
/// undo, and done.
@MainActor
final class AnnotationToolbarView: NSView {
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onUndo: (() -> Void)?
    var onDone: (() -> Void)?

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var orderedButtons: [NSButton] = []
    private var separatorIndices: Set<Int> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

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
        toolButtons = [.arrow: arrowButton, .rectangle: rectangleButton, .privacyBlock: privacyButton]

        addSeparator()

        _ = addButton(symbol: "arrow.uturn.backward", tooltip: "Undo  (⌘Z)") { [weak self] in
            self?.onUndo?()
        }
        _ = addButton(symbol: "checkmark", tooltip: "Done  (Enter)") { [weak self] in
            self?.onDone?()
        }

        setSelectedTool(.arrow)
        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelectedTool(_ tool: AnnotationTool) {
        for (candidate, button) in toolButtons {
            button.contentTintColor = candidate == tool ? .systemRed : .white
        }
    }

    /// Clears every closure so the toolbar retains nothing once the editor
    /// closes.
    func releaseResources() {
        onToolSelected = nil
        onUndo = nil
        onDone = nil
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
        let y = (bounds.height - buttonSize) / 2

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
