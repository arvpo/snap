import AppKit
import CoreGraphics
@testable import SnapCore

@MainActor
private func textCanvas(scale: CGFloat = 1) -> AnnotationCanvasView {
    _ = NSApplication.shared
    let canvas = AnnotationCanvasView(baseImage: makeTestCGImage(width: 600, height: 400))
    canvas.frame = CGRect(x: 0, y: 0, width: 600 * scale, height: 400 * scale)
    canvas.currentTool = .text
    return canvas
}

private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

@MainActor
private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in canvas: NSView) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                      timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

@MainActor
private final class TextClipboard: ClipboardServicing {
    var images: [CGImage] = []
    func writePNG(_ image: CGImage) throws { images.append(image) }
}

@MainActor
func registerAnnotationTextEditingTests() {
    test("text drafts discard empty insertions and group an entire edit into one undo") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        var session = TextEditingSession.new(from: .zero, to: .zero, style: TextStyle())
        try expect(!session.commit(to: document))
        try expect(!document.canUndo)
        session.draft.text = "Hello\n世界 👩🏽‍💻"
        try expect(session.commit(to: document))
        let original = document.entries[0]
        var editing = TextEditingSession(annotationID: original.id, draft: session.draft)
        editing.draft.text += " changed"
        editing.draft.style = TextStyle(presentation: .callout, color: .blue, fontSize: 24)
        try expect(editing.commit(to: document))
        try expectEqual(document.entries[0].id, original.id)
        try expect(document.undo())
        try expectEqual(document.entries, [original])
        editing.draft.text = ""
        try expect(editing.commit(to: document))
        try expect(document.isEmpty)
        try expect(document.undo())
        try expectEqual(document.entries, [original])
    }

    test("Text click and reverse drag create natural and wrapped image-space drafts") {
        let canvas = textCanvas(scale: 0.5)
        defer { canvas.releaseResources() }
        let point = CGPoint(x: 100, y: 120)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: point, in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: point, in: canvas))
        try expectEqual(canvas.textSession?.draft.origin, CGPoint(x: 200, y: 240))
        try expect(canvas.textSession?.draft.width == nil)
        try expectEqual(canvas.textSession?.draft.style.fontSize, 36)
        canvas.endTextEditing(commit: false)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: point, in: canvas))
        let end = CGPoint(x: 30, y: 100)
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, in: canvas))
        try expectEqual(canvas.textSession?.draft.origin, CGPoint(x: 60, y: 200))
        try expectEqual(canvas.textSession?.draft.width, 140)
    }

    test("typing tool shortcut letters stays in native text and Return only commits text") {
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 600, height: 400),
                                                    clipboardService: TextClipboard(), onFinished: {})
        controller.show()
        defer { controller.close() }
        controller.selectTool(.text)
        let canvas = controller.canvasView!
        var finished = 0
        var tools = 0
        var commits: [TextEditingSession] = []
        canvas.onFinish = { finished += 1 }
        canvas.onToolSelected = { _ in tools += 1 }
        canvas.onTextCommit = { commits.append($0) }
        canvas.beginTextEditing(.new(from: .zero, to: .zero, style: TextStyle()))
        let editor = canvas.textEditor!
        canvas.keyDown(with: key(11, "b", flags: .command))
        canvas.keyDown(with: key(36, "\r"))
        for (code, letter) in [(UInt16(0), "a"), (15, "r"), (11, "b"), (17, "t"), (45, "n"), (9, "v")] {
            editor.keyDown(with: key(code, letter))
        }
        editor.keyDown(with: key(36, "\r", flags: .shift))
        editor.insertText("世界 👩🏽‍💻", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: key(36, "\r"))
        try expectEqual(commits.count, 1)
        try expectEqual(commits[0].draft.text, "arbtnv\n世界 👩🏽‍💻")
        try expectEqual(finished, 0)
        try expectEqual(tools, 0)
        try expect(canvas.textEditor == nil)
    }

    test("Escape discards native text and style edits without changing the document") {
        let canvas = textCanvas()
        defer { canvas.releaseResources() }
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        let original = TextAnnotation(origin: .zero, text: "Original")
        let id = document.commit(.text(original))
        canvas.onTextCommit = { $0.commit(to: document) }
        canvas.beginTextEditing(TextEditingSession(annotationID: id, draft: original))
        canvas.textEditor?.selectAll(nil)
        canvas.textEditor?.insertText("Replacement", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.setTextStyle(TextStyle(presentation: .callout, color: .green, fontSize: 24))
        canvas.textEditor?.keyDown(with: key(53, "\u{1b}"))
        try expectEqual(document.annotations, [.text(original)])
        try expect(canvas.textEditor == nil)
        try expect(document.undo())
        try expect(document.isEmpty)
    }

    test("native text undo never consumes document undo and is reset between edits") {
        let canvas = textCanvas()
        defer { canvas.releaseResources() }
        var documentUndos = 0
        canvas.onUndo = { documentUndos += 1 }
        canvas.beginTextEditing(.new(from: .zero, to: .zero, style: TextStyle()))
        let editor = canvas.textEditor!
        editor.insertText("Hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        try expect(editor.performKeyEquivalent(with: key(6, "z", flags: .command)))
        try expectEqual(editor.string, "")
        try expectEqual(documentUndos, 0)
        canvas.endTextEditing(commit: false)
        canvas.beginTextEditing(.new(from: .zero, to: .zero, style: TextStyle()))
        try expect(canvas.textEditor?.undoManager?.canUndo == false)
    }

    test("marked text stays in the native input method until it is accepted") {
        let canvas = textCanvas()
        defer { canvas.releaseResources() }
        var committed = false
        canvas.onTextCommit = { _ in committed = true }
        canvas.beginTextEditing(.new(from: .zero, to: .zero, style: TextStyle()))
        let editor = canvas.textEditor!
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(editor.hasMarkedText())
        editor.keyDown(with: key(36, "\r"))
        try expect(!committed, "Return during composition must not commit the annotation")
        try expect(canvas.textEditor != nil)
        editor.unmarkText()
        editor.keyDown(with: key(36, "\r"))
        try expect(committed)
    }

    test("Text tool reopens the topmost text identity and cancellation restores its value") {
        let canvas = textCanvas()
        defer { canvas.releaseResources() }
        let first = Annotation(value: .text(TextAnnotation(origin: CGPoint(x: 50, y: 100), text: "First")))
        let top = Annotation(value: .text(TextAnnotation(origin: CGPoint(x: 50, y: 100), text: "Top")))
        canvas.setAnnotations([first, top])
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 55, y: 105), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 55, y: 105), in: canvas))
        try expectEqual(canvas.textSession?.annotationID, top.id)
        try expectEqual(canvas.textEditor?.string, "Top")
        canvas.endTextEditing(commit: false)
        try expect(canvas.textSession == nil)
    }

    test("style controls use display points and native wrapping matches image-space width") {
        let canvas = textCanvas(scale: 0.5)
        defer { canvas.releaseResources() }
        canvas.beginTextEditing(.new(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 180, y: 100), style: TextStyle()))
        canvas.setTextStyle(TextStyle(presentation: .callout, color: .yellow, fontSize: 24))
        canvas.textEditor?.insertText("Long wrapped text with Unicode 日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        let draft = canvas.textSession!.draft
        try expectEqual(draft.style.fontSize, 48)
        try expectEqual(canvas.textEditor?.font?.pointSize, 24)
        try expectEqual(canvas.textEditor?.textContainer?.containerSize.width, 80)
        let layout = AnnotationLayout.text(draft)!
        try expectEqual(canvas.textEditor?.frame.minX, layout.contentRect.minX * 0.5)
        try expectEqual(canvas.textEditor?.frame.minY, layout.contentRect.minY * 0.5)
        try expect(layout.contentRect.height > draft.style.fontSize)
        try expectEqual(canvas.textEditor?.textColor, NSColor(cgColor: AnnotationColor.yellow.contrastingColor))
        try expectEqual(textCanvas().textStyle, TextStyle())
    }

    test("typing and cancel do not publish while a committed text edit publishes once") {
        let clipboard = TextClipboard()
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 600, height: 400),
                                                    clipboardService: clipboard, onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        canvas.beginTextEditing(.new(from: CGPoint(x: 30, y: 120), to: .zero, style: TextStyle()))
        canvas.textEditor?.insertText("draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        await pumpMainLoop(2)
        try expect(clipboard.images.isEmpty)
        canvas.endTextEditing(commit: false)
        try expect(clipboard.images.isEmpty)
        canvas.beginTextEditing(.new(from: CGPoint(x: 30, y: 120), to: .zero, style: TextStyle()))
        canvas.textEditor?.insertText("committed", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.endTextEditing(commit: true)
        try await waitUntil { clipboard.images.count == 1 }
        try expectEqual(controller.document.entries.count, 1)
    }

    test("Done commits active text and republishes the final image after native text copy") {
        let clipboard = TextClipboard()
        var finished = false
        let base = makeTestCGImage(width: 600, height: 400)
        let controller = AnnotationWindowController(baseImage: base, clipboardService: clipboard,
                                                    onFinished: { finished = true })
        controller.show()
        let canvas = controller.canvasView!
        canvas.beginTextEditing(.new(from: CGPoint(x: 30, y: 120), to: CGPoint(x: 250, y: 120), style: TextStyle()))
        canvas.textEditor?.insertText("Copied 日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        let draft = canvas.textSession!.draft
        canvas.endTextEditing(commit: true)
        try await waitUntil { clipboard.images.count == 1 }
        let id = controller.document.entries[0].id
        canvas.beginTextEditing(TextEditingSession(annotationID: id, draft: draft))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        canvas.textEditor?.selectAll(nil)
        let copied = canvas.textEditor!.writeSelection(to: pasteboard, types: canvas.textEditor!.writablePasteboardTypes)
        try expect(copied)
        try expectEqual(pasteboard.string(forType: .string), draft.text)
        // No further text changes: Done still has to restore the image.
        controller.finish()
        try await waitUntil { finished }
        try expectEqual(clipboard.images.count, 2)
        let expected = try ImageRenderer.render(baseImage: base, annotations: [.text(draft)])
        try expectEqual(clipboard.images.last!.dataProvider!.data! as Data, expected.dataProvider!.data! as Data)
        try expect(canvas.textEditor == nil)
    }

    test("committed canvas preview and export use identical text and callout pixels") {
        let base = makeTestCGImage(width: 400, height: 240)
        let canvas = AnnotationCanvasView(baseImage: base)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 240)
        defer { canvas.releaseResources() }
        let entries = [
            Annotation(value: .text(TextAnnotation(origin: CGPoint(x: 20, y: 30), text: "Hello 日本語\nSecond line", width: 220))),
            Annotation(value: .text(TextAnnotation(origin: CGPoint(x: 30, y: 130), text: "A callout", width: 170,
                style: TextStyle(presentation: .callout, color: .blue, fontSize: 24))))
        ]
        canvas.setAnnotations(entries)
        let context = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 1600,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 240)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let preview = context.makeImage()!
        let exported = try ImageRenderer.render(baseImage: base, annotations: entries.map(\.value))
        try expectEqual(preview.dataProvider!.data! as Data, exported.dataProvider!.data! as Data)
    }

    test("native Unicode paste is plain text and remains undoable") {
        let canvas = textCanvas()
        defer { canvas.releaseResources() }
        canvas.beginTextEditing(.new(from: .zero, to: .zero, style: TextStyle()))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        let text = "Pasted 👩🏽‍💻\n日本語 e\u{301}"
        try expect(pasteboard.setString(text, forType: .string))
        try expect(canvas.textEditor!.readSelection(from: pasteboard, type: .string))
        try expectEqual(canvas.textEditor?.string, text)
        try expect(canvas.textEditor?.isRichText == false)
        canvas.textEditor?.breakUndoCoalescing()
        canvas.textEditor?.undoManager?.undo()
        try expectEqual(canvas.textEditor?.string, "")
    }

    test("toolbar text styles preserve native focus and switching tools commits the draft") {
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 900, height: 600),
                                                    clipboardService: TextClipboard(), onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        let toolbar = canvas.superview!.subviews.compactMap { $0 as? AnnotationToolbarView }.first!
        let textButton = toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Text  (T)" }!
        textButton.performClick(nil)
        try expectEqual(canvas.currentTool, .text)
        try expectEqual(toolbar.frame.height, 48)
        canvas.beginTextEditing(.new(from: CGPoint(x: 30, y: 220), to: .zero, style: TextStyle()))
        canvas.textEditor?.insertText("Styled", replacementRange: NSRange(location: NSNotFound, length: 0))
        toolbar.toggleStylePopover()
        try expect(toolbar.stylePopover.isShown)
        let controls = toolbar.stylePopover.contentViewController!.view.subviews.compactMap { $0 as? NSPopUpButton }
        for (title, expectedColor) in zip(["Red", "Blue", "Green", "Yellow", "Black", "White"], AnnotationColor.allCases) {
            let control = controls.first { $0.itemTitles.contains(title) }!
            control.selectItem(withTitle: title)
            NSApp.sendAction(control.action!, to: control.target, from: control)
            try expectEqual(canvas.textSession?.draft.style.color, expectedColor)
        }
        for title in ["Callout", "14 pt", "18 pt", "24 pt"] {
            let control = controls.first { $0.itemTitles.contains(title) }!
            control.selectItem(withTitle: title)
            NSApp.sendAction(control.action!, to: control.target, from: control)
        }
        try expectEqual(canvas.textSession?.draft.style.presentation, .callout)
        try expectEqual(canvas.textEditor?.font?.pointSize, 24)
        toolbar.stylePopover.performClose(nil)
        try expect(canvas.window?.firstResponder === canvas.textEditor)
        try expect(controller.document.isEmpty)
        controller.selectTool(.arrow)
        try expect(canvas.textEditor == nil)
        try expectEqual(controller.document.entries.count, 1)
        try expectEqual(toolbar.frame.height, 48)
        try expect(!toolbar.stylePopover.isShown)
    }

    test("Done accepts an uncommitted draft and native editor resources are released") {
        let clipboard = TextClipboard()
        var finished = false
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 600, height: 400),
                                                    clipboardService: clipboard, onFinished: { finished = true })
        controller.show()
        weak var weakEditor: AnnotationTextView?
        autoreleasepool {
            controller.canvasView?.beginTextEditing(.new(from: CGPoint(x: 20, y: 120), to: .zero, style: TextStyle()))
            weakEditor = controller.canvasView?.textEditor
            controller.canvasView?.textEditor?.insertText("Done", replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.finish()
        }
        try await waitUntil { finished }
        await pumpMainLoop()
        try expect(!clipboard.images.isEmpty)
        try await waitUntil(timeout: .seconds(2)) { weakEditor == nil }
    }
}
