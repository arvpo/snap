import AppKit

/// NSTextView retains native selection, input methods and a private text undo
/// stack. No editing keystroke is forwarded to the canvas's drawing shortcuts.
@MainActor
final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private let textUndoManager = UndoManager()

    override var undoManager: UndoManager? { textUndoManager }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.modifierFlags.contains(.shift) {
                    insertNewlineIgnoringFieldEditor(nil)
                } else {
                    onCommit?()
                }
                return
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "z":
            if event.modifierFlags.contains(.shift) { undoManager?.redo() }
            else { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func releaseResources() {
        inputContext?.discardMarkedText()
        unmarkText()
        delegate = nil
        onCommit = nil
        onCancel = nil
        undoManager?.removeAllActions()
        textStorage?.setAttributedString(NSAttributedString(string: ""))
    }
}
