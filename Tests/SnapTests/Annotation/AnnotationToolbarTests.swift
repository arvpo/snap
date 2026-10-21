import AppKit
@testable import SnapCore

@MainActor
private final class ToolbarClipboard: ClipboardServicing {
    var images: [CGImage] = []
    func writePNG(_ image: CGImage) throws { images.append(image) }
}

@MainActor
private func toolbar(in canvas: AnnotationCanvasView) -> AnnotationToolbarView {
    canvas.superview!.subviews.compactMap { $0 as? AnnotationToolbarView }.first!
}

@MainActor
private func button(_ label: String, in toolbar: AnnotationToolbarView) -> NSButton {
    toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }!
}

@MainActor
func registerAnnotationToolbarTests() {
    test("editor chrome fits tiny narrow and large crops without changing aspect ratio") {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: 300, width: 1920, height: 1080)] {
            for scale: CGFloat in [1, 2] {
                for pixels in [CGSize(width: 8, height: 8), CGSize(width: 31, height: 901),
                               CGSize(width: 1801, height: 21), CGSize(width: 601, height: 401),
                               CGSize(width: 6000, height: 4000)] {
                    let layout = AnnotationEditorLayout(imagePixelSize: pixels, visibleFrame: screen, backingScale: scale)
                    let bounds = CGRect(origin: .zero, size: layout.windowFrame.size)
                    try expect(screen.contains(layout.windowFrame))
                    try expect(bounds.contains(layout.canvasFrame))
                    try expect(bounds.contains(layout.toolbarFrame))
                    try expect(layout.canvasFrame.maxY < layout.toolbarFrame.minY)
                    try expect(abs(layout.canvasFrame.width / pixels.width - layout.canvasFrame.height / pixels.height) < 0.000001)
                    try expect(layout.canvasFrame.width <= pixels.width / scale)
                }
            }
        }
    }

    test("toolbar has ordered accessible controls selected Arrow and disabled empty Undo") {
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 12, height: 8),
            clipboardService: ToolbarClipboard(), onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        let tools = toolbar(in: canvas)
        let buttons = tools.subviews.compactMap { $0 as? NSButton }
        try expectEqual(buttons.map { $0.accessibilityLabel()! },
                        ["Select", "Arrow", "Rectangle", "Privacy block", "Text", "Number", "Text style", "Undo", "Done"])
        try expect(buttons.allSatisfy { $0.image != nil && $0.toolTip != nil && tools.bounds.contains($0.frame) })
        try expectEqual(button("Arrow", in: tools).state, .on)
        try expect(!button("Undo", in: tools).isEnabled)
        try expect(!button("Text style", in: tools).isEnabled)
        for label in ["Select", "Arrow", "Rectangle", "Privacy block", "Text", "Number"] {
            let control = button(label, in: tools)
            control.performClick(nil)
            try expectEqual(control.state, .on)
            try expectEqual(buttons.filter { $0.state == .on }.count, 1)
            try expect(canvas.window?.firstResponder === canvas)
        }
        try expect(controller.document.isEmpty)
    }

    test("chrome hit targets never reach the canvas and image coordinates exclude margins") {
        let clipboard = ToolbarClipboard()
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 120, height: 80),
            clipboardService: clipboard, onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        let chrome = canvas.superview!
        let tools = toolbar(in: canvas)
        try expect(canvas.subviews.isEmpty)
        for control in tools.subviews.compactMap({ $0 as? NSButton }) {
            let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: chrome)
            try expect(chrome.hitTest(point) === control)
        }
        try expect(chrome.hitTest(CGPoint(x: 3, y: 3)) === chrome)
        controller.selectTool(.number)
        let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: canvas.convert(center, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
        }
        guard case .number(let marker) = controller.document.annotations.first else { throw ExpectationError(message: "missing marker", file: #fileID, line: #line) }
        try expectEqual(marker.center, CGPoint(x: 60, y: 40))
        try await waitUntil { clipboard.images.count == 1 }
        let expected = try ImageRenderer.render(baseImage: controller.document.baseImage, annotations: controller.document.annotations)
        try expectEqual(clipboard.images[0].width, 120)
        try expectEqual(clipboard.images[0].height, 80)
        try expectEqual(clipboard.images[0].dataProvider!.data! as Data, expected.dataProvider!.data! as Data)
    }

    test("toolbar Undo tracks document history and the active native text undo stack") {
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 600, height: 400),
            clipboardService: ToolbarClipboard(), onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        let tools = toolbar(in: canvas)
        let undo = button("Undo", in: tools)
        canvas.onCommit?(.privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 0, y: 0, width: 10, height: 10))))
        try expect(undo.isEnabled)
        canvas.beginTextEditing(.new(from: .zero, to: .zero, style: TextStyle()))
        try expect(!undo.isEnabled, "empty native undo must not consume the document history")
        try expect(button("Text style", in: tools).isEnabled, "editing from Select must expose styles too")
        canvas.textEditor?.insertText("Draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.textEditor?.breakUndoCoalescing()
        await pumpMainLoop()
        try expect(undo.isEnabled)
        undo.performClick(nil)
        try expectEqual(canvas.textEditor?.string, "")
        try expect(!undo.isEnabled)
        canvas.endTextEditing(commit: false)
        try expect(undo.isEnabled)
        undo.performClick(nil)
        try expect(controller.document.isEmpty)
        try expect(!undo.isEnabled)
    }

    test("style popover preserves draft selection returns focus and closes on tool change") {
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 600, height: 400),
            clipboardService: ToolbarClipboard(), onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        let tools = toolbar(in: canvas)
        controller.selectTool(.text)
        canvas.beginTextEditing(.new(from: .zero, to: .zero, style: TextStyle()))
        canvas.textEditor?.insertText("Selected text", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.textEditor?.setSelectedRange(NSRange(location: 2, length: 4))
        tools.toggleStylePopover()
        try expect(tools.stylePopover.isShown)
        let content = tools.stylePopover.contentViewController!.view
        try expect(content.window != nil)
        let controls = content.subviews.compactMap { $0 as? NSPopUpButton }
        try expectEqual(controls.compactMap { $0.accessibilityLabel() }, ["Text presentation", "Text color", "Font size"])
        try expect(controls.allSatisfy { content.bounds.contains($0.frame) })
        let color = controls[1]
        color.selectItem(withTitle: "Blue")
        NSApp.sendAction(color.action!, to: color.target, from: color)
        try expectEqual(canvas.textSession?.draft.style.color, .blue)
        try expectEqual(canvas.textEditor?.selectedRange(), NSRange(location: 2, length: 4))
        try expect(controller.document.isEmpty)
        tools.stylePopover.performClose(nil)
        try expect(canvas.window?.firstResponder === canvas.textEditor)
        tools.toggleStylePopover()
        controller.selectTool(.arrow)
        try expect(!tools.stylePopover.isShown)
        try expectEqual(controller.document.entries.count, 1)
        try expect(canvas.window?.firstResponder === canvas)
    }

    test("toolbar keyboard focus routes shortcuts back to canvas without stealing text input") {
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 600, height: 400),
            clipboardService: ToolbarClipboard(), onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        let tools = toolbar(in: canvas)
        let select = button("Select", in: tools)
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window!.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        canvas.keyDown(with: tab)
        try expect(canvas.window?.firstResponder is NSButton, "Tab should focus a toolbar control")
        try expect(canvas.window!.makeFirstResponder(select))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window!.windowNumber, context: nil, characters: "n",
            charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        select.keyDown(with: event)
        try expectEqual(canvas.currentTool, .number)
        canvas.beginTextEditing(.new(from: .zero, to: .zero, style: TextStyle()))
        tools.keyDown(with: event)
        try expectEqual(canvas.currentTool, .number)
        try expect(canvas.textEditor != nil)
    }

    test("closing editor dismisses style popover and releases its content") {
        var controller: AnnotationWindowController? = AnnotationWindowController(baseImage: makeTestCGImage(width: 600, height: 400),
            clipboardService: ToolbarClipboard(), onFinished: {})
        controller!.show()
        controller!.selectTool(.text)
        weak var weakContent: NSView?
        weak var weakToolbar: AnnotationToolbarView?
        var dismissed = false
        autoreleasepool {
            let tools = toolbar(in: controller!.canvasView!)
            tools.toggleStylePopover()
            weakContent = tools.stylePopover.contentViewController?.view
            weakToolbar = tools
            controller!.close()
            dismissed = !tools.stylePopover.isShown
        }
        controller = nil
        try expect(dismissed)
        await pumpMainLoop()
        try await waitUntil(timeout: .seconds(2)) { weakContent == nil && weakToolbar == nil }
    }
}
