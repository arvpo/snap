import AppKit
import CoreGraphics
@testable import SnapCore

@MainActor
private final class SelectionFixture {
    let document = AnnotationDocument(baseImage: makeTestCGImage(width: 600, height: 400))
    let canvas: AnnotationCanvasView
    var publications = 0

    init(scale: CGFloat = 1) {
        _ = NSApplication.shared
        canvas = AnnotationCanvasView(baseImage: document.baseImage)
        canvas.frame = CGRect(x: 0, y: 0, width: 600 * scale, height: 400 * scale)
        canvas.onCommit = { [weak self] value in
            guard let self else { return }
            self.document.commit(value)
            self.refresh()
        }
        canvas.onUpdate = { [weak self] id, value in
            guard let self, self.document.update(id: id, value: value) else { return }
            self.refresh()
        }
        canvas.onDelete = { [weak self] id in
            guard let self, self.document.delete(id: id) else { return }
            self.refresh()
        }
        canvas.onUndo = { [weak self] in
            guard let self, self.document.undo() else { return }
            self.refresh()
        }
        canvas.onTextCommit = { [weak self] session in
            guard let self, session.commit(to: self.document) else { return }
            self.refresh()
        }
    }

    func refresh() {
        canvas.setAnnotations(document.entries)
        publications += 1
    }

    func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
        let scale = canvas.imageToViewScale
        let local = CGPoint(x: point.x * scale, y: point.y * scale)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func click(_ point: CGPoint, clicks: Int = 1) {
        canvas.mouseDown(with: event(.leftMouseDown, point, clicks: clicks))
        canvas.mouseUp(with: event(.leftMouseUp, point, clicks: clicks))
    }

    func drag(_ start: CGPoint, _ end: CGPoint) {
        canvas.mouseDown(with: event(.leftMouseDown, start))
        canvas.mouseDragged(with: event(.leftMouseDragged, end))
        canvas.mouseUp(with: event(.leftMouseUp, end))
    }
}

private func selectionKey(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!
}

@MainActor
private final class SelectionClipboard: ClipboardServicing {
    var images: [CGImage] = []
    func writePNG(_ image: CGImage) throws { images.append(image) }
}

@MainActor
func registerAnnotationSelectionTests() {
    test("Number repeatedly places 1 through 10 and stays active at Retina and fit scales") {
        for scale: CGFloat in [1, 0.5, 0.25] {
            let f = SelectionFixture(scale: scale)
            defer { f.canvas.releaseResources() }
            f.canvas.keyDown(with: selectionKey(45, "n"))
            for index in 1...10 {
                let point = CGPoint(x: 100 + index * 20, y: 150)
                f.click(point)
                guard case .number(let marker) = f.document.annotations.last! else { throw selectionFailure() }
                try expectEqual(marker.number, index)
                try expectEqual(marker.center, point)
                try expectEqual(marker.diameter * scale, 28)
                try expectEqual(marker.fontSize * scale, 18)
            }
            try expectEqual(f.canvas.currentTool, .number)
            try expectEqual(f.publications, 10)
            try expectEqual(Set(f.document.entries.map(\.id)).count, 10)
        }
    }

    test("selected marker deletion renumbers 10 to 9 and one undo restores all identities") {
        let f = SelectionFixture()
        defer { f.canvas.releaseResources() }
        f.canvas.currentTool = .number
        for index in 0..<10 { f.click(CGPoint(x: 50 + index * 45, y: 160)) }
        let original = f.document.entries
        f.canvas.keyDown(with: selectionKey(9, "v"))
        f.click(CGPoint(x: 50, y: 160))
        try expectEqual(f.canvas.selectedAnnotationID, original[0].id)
        f.canvas.keyDown(with: selectionKey(51))
        try expectEqual(f.document.entries.count, 9)
        try expectEqual(f.document.entries.map(\.id), Array(original.dropFirst()).map(\.id))
        try expectEqual(f.document.annotations.compactMap { if case .number(let n) = $0 { n.number } else { nil } }, Array(1...9))
        try expect(f.canvas.selectedAnnotationID == nil)
        f.canvas.keyDown(with: selectionKey(6, "z", flags: .command))
        try expectEqual(f.document.entries, original)
    }

    test("marker drag preserves numbering and commits only once after all preview updates") {
        let f = SelectionFixture(scale: 0.5)
        defer { f.canvas.releaseResources() }
        f.canvas.currentTool = .number
        f.click(CGPoint(x: 100, y: 150))
        f.click(CGPoint(x: 250, y: 150))
        let original = f.document.entries
        f.canvas.currentTool = .select
        f.canvas.mouseDown(with: f.event(.leftMouseDown, CGPoint(x: 100, y: 150)))
        for x in stride(from: 110, through: 200, by: 10) {
            f.canvas.mouseDragged(with: f.event(.leftMouseDragged, CGPoint(x: x, y: 200)))
            try expectEqual(f.document.entries, original)
            try expectEqual(f.publications, 2)
        }
        f.canvas.mouseUp(with: f.event(.leftMouseUp, CGPoint(x: 200, y: 200)))
        try expectEqual(f.publications, 3)
        guard case .number(let moved) = f.document.annotations[0] else { throw selectionFailure() }
        try expectEqual(moved.center, CGPoint(x: 200, y: 200))
        try expectEqual(moved.number, 1)
        try expectEqual(f.document.entries.map(\.id), original.map(\.id))
        f.canvas.keyDown(with: selectionKey(6, "z", flags: .command))
        try expectEqual(f.document.entries, original)
    }

    test("plain and callout text move in image coordinates with one reversible edit") {
        for presentation in [TextStyle.Presentation.plain, .callout] {
            let f = SelectionFixture(scale: 0.25)
            defer { f.canvas.releaseResources() }
            let text = TextAnnotation(origin: CGPoint(x: 50, y: 100), text: "Move 日本語", width: 180,
                style: TextStyle(presentation: presentation, color: .blue, fontSize: 24))
            let id = f.document.commit(.text(text))
            f.canvas.setAnnotations(f.document.entries)
            f.canvas.currentTool = .select
            f.drag(CGPoint(x: 60, y: 110), CGPoint(x: 140, y: 150))
            try expectEqual(f.document.annotation(id: id)?.value, AnnotationValue.text(text).translated(by: CGSize(width: 80, height: 40)))
            try expectEqual(f.publications, 1)
            try expect(f.document.undo())
            try expectEqual(f.document.annotation(id: id)?.value, .text(text))
        }
    }

    test("text width handle wraps natural text and resizes callouts without shifting their origin") {
        for scale: CGFloat in [1, 0.5, 0.25] {
            for presentation in [TextStyle.Presentation.plain, .callout] {
                let f = SelectionFixture(scale: scale)
                defer { f.canvas.releaseResources() }
                let text = TextAnnotation(origin: CGPoint(x: 80, y: 120), text: "Some text to wrap onto multiple lines",
                    style: TextStyle(presentation: presentation))
                let id = f.document.commit(.text(text))
                f.canvas.setAnnotations(f.document.entries)
                f.canvas.currentTool = .select
                f.click(CGPoint(x: 90, y: 130))
                let handle = AnnotationSelection.widthHandle(for: .text(text), scale: scale, imageSize: CGSize(width: 600, height: 400))!
                let start = CGPoint(x: handle.midX, y: handle.midY)
                let width = AnnotationLayout.text(text)!.contentRect.width
                f.drag(start, CGPoint(x: start.x - width + 100, y: start.y))
                guard case .text(let resized) = f.document.annotation(id: id)!.value else { throw selectionFailure() }
                try expectEqual(resized.width, 100)
                try expectEqual(resized.origin, text.origin)
                try expectEqual(resized.style, text.style)
                try expect(AnnotationLayout.text(resized)!.contentRect.height > AnnotationLayout.text(text)!.contentRect.height)
                try expectEqual(f.publications, 1)
                try expect(f.document.undo())
                try expectEqual(f.document.annotation(id: id)?.value, .text(text))
            }
        }
    }

    test("text resizing clamps width to crop and minimum while edge handles remain reachable") {
        let size = CGSize(width: 600, height: 400)
        let text = TextAnnotation(origin: CGPoint(x: 400, y: 120), text: "Resize me", width: 180,
                                  style: TextStyle(presentation: .callout))
        let narrow = AnnotationSelection.resized(text, by: -1000, scale: 0.5, imageSize: size)
        try expectEqual(narrow.width, 24)
        let wide = AnnotationSelection.resized(text, by: 1000, scale: 0.5, imageSize: size)
        try expectEqual(AnnotationLayout.text(wide)?.backgroundRect.maxX, 600)
        let handle = AnnotationSelection.widthHandle(for: .text(wide), scale: 0.5, imageSize: size)!
        try expectEqual(handle.width * 0.5, 8)
        try expectEqual(handle.maxX, 600)
        try expectEqual(AnnotationSelection.resized(text, by: 0, scale: 1, imageSize: size), text)
    }

    test("overlap hit testing picks topmost selectable item and ignores shape-only targets") {
        let text = Annotation(value: .text(TextAnnotation(origin: CGPoint(x: 80, y: 80), text: "Behind", width: 160)))
        let marker = Annotation(value: .number(NumberAnnotation(center: CGPoint(x: 100, y: 100))))
        let shape = Annotation(value: .privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 50, y: 50, width: 300, height: 300))))
        let point = CGPoint(x: 100, y: 95)
        try expectEqual(AnnotationSelection.hitTest(point, entries: [text, marker, shape], scale: 1)?.id, marker.id)
        try expectEqual(AnnotationSelection.hitTest(point, entries: [marker, text], scale: 1)?.id, text.id)
        try expect(AnnotationSelection.hitTest(point, entries: [shape], scale: 1) == nil)
        try expect(AnnotationSelection.hitTest(CGPoint(x: 116, y: 116), entries: [marker], scale: 1) == nil)
        try expectEqual(AnnotationSelection.hitTest(CGPoint(x: 120, y: 100), entries: [marker], scale: 0.5)?.id, marker.id)
    }

    test("placement and movement respect every image edge including oversized markers") {
        let size = CGSize(width: 600, height: 400)
        for point in [CGPoint.zero, CGPoint(x: 600, y: 0), CGPoint(x: 0, y: 400), CGPoint(x: 600, y: 400)] {
            let marker = AnnotationSelection.marker(at: point, number: 1000, scale: 0.5, imageSize: size)
            let bounds = AnnotationLayout.number(marker).circleRect
            try expect(bounds.minX >= 0 && bounds.minY >= 0 && bounds.maxX <= 600 && bounds.maxY <= 400)
            let moved = AnnotationSelection.moved(.number(marker), by: CGSize(width: -10000, height: 10000), imageSize: size)
            let movedBounds = AnnotationSelection.bounds(of: moved)!
            try expect(abs(movedBounds.minX) < 0.001)
            try expect(abs(movedBounds.maxY - 400) < 0.001)
        }
        let tiny = AnnotationSelection.marker(at: .zero, number: 1, scale: 1, imageSize: CGSize(width: 10, height: 8))
        try expectEqual(tiny.center, CGPoint(x: 5, y: 4))
        let oversized = AnnotationValue.text(TextAnnotation(origin: .zero, text: "Long", width: 900))
        let moved = AnnotationSelection.moved(oversized, by: CGSize(width: -10000, height: -10000), imageSize: size)
        try expectEqual(AnnotationSelection.bounds(of: moved)?.minX, -300)
        try expectEqual(AnnotationSelection.bounds(of: moved)?.minY, 0)
    }

    test("Select double click edits existing text and Escape restores its selected value") {
        let f = SelectionFixture()
        defer { f.canvas.releaseResources() }
        let text = TextAnnotation(origin: CGPoint(x: 50, y: 100), text: "Original", width: 150)
        let id = f.document.commit(.text(text))
        f.canvas.setAnnotations(f.document.entries)
        f.canvas.currentTool = .select
        f.click(CGPoint(x: 60, y: 110))
        try expect(f.canvas.textEditor == nil)
        f.click(CGPoint(x: 60, y: 110), clicks: 2)
        try expectEqual(f.canvas.textSession?.annotationID, id)
        f.canvas.textEditor?.insertText(" changed", replacementRange: NSRange(location: NSNotFound, length: 0))
        f.canvas.textEditor?.keyDown(with: selectionKey(53))
        try expectEqual(f.document.annotations, [.text(text)])
        try expectEqual(f.canvas.selectedAnnotationID, id)
        f.click(CGPoint(x: 60, y: 110), clicks: 2)
        f.canvas.textEditor?.selectAll(nil)
        f.canvas.textEditor?.insertText("Edited", replacementRange: NSRange(location: NSNotFound, length: 0))
        f.canvas.textEditor?.keyDown(with: selectionKey(36, "\r"))
        try expectEqual(f.document.entries[0].id, id)
        try expectEqual(f.publications, 1)
        try expect(f.document.undo())
        try expectEqual(f.document.annotations, [.text(text)])
    }

    test("click jitter and drag back to origin do not create document undo steps") {
        let f = SelectionFixture()
        defer { f.canvas.releaseResources() }
        f.canvas.currentTool = .number
        let point = CGPoint(x: 100, y: 150)
        f.click(point)
        let original = f.document.entries
        f.canvas.currentTool = .select
        f.drag(point, CGPoint(x: 101, y: 151))
        f.canvas.mouseDown(with: f.event(.leftMouseDown, point))
        f.canvas.mouseDragged(with: f.event(.leftMouseDragged, CGPoint(x: 150, y: 150)))
        f.canvas.mouseUp(with: f.event(.leftMouseUp, point))
        try expectEqual(f.document.entries, original)
        try expectEqual(f.publications, 1)
        try expect(f.document.undo())
        try expect(f.document.isEmpty)
    }

    test("Escape and tool changes discard gestures and empty selection clears without publication") {
        let f = SelectionFixture()
        defer { f.canvas.releaseResources() }
        f.canvas.currentTool = .number
        let point = CGPoint(x: 100, y: 150)
        f.click(point)
        let original = f.document.entries
        f.canvas.currentTool = .select
        f.canvas.mouseDown(with: f.event(.leftMouseDown, point))
        f.canvas.mouseDragged(with: f.event(.leftMouseDragged, CGPoint(x: 200, y: 200)))
        f.canvas.keyDown(with: selectionKey(53))
        f.canvas.mouseUp(with: f.event(.leftMouseUp, CGPoint(x: 200, y: 200)))
        try expectEqual(f.document.entries, original)
        f.canvas.mouseDown(with: f.event(.leftMouseDown, point))
        f.canvas.mouseDragged(with: f.event(.leftMouseDragged, CGPoint(x: 200, y: 200)))
        f.canvas.currentTool = .arrow
        f.canvas.mouseUp(with: f.event(.leftMouseUp, CGPoint(x: 200, y: 200)))
        try expect(f.canvas.selectedAnnotationID == nil)
        f.canvas.currentTool = .select
        f.click(point)
        f.click(CGPoint(x: 400, y: 300))
        try expect(f.canvas.selectedAnnotationID == nil)
        f.canvas.keyDown(with: selectionKey(117))
        try expectEqual(f.document.entries, original)
        try expectEqual(f.publications, 1)
    }

    test("Select forward delete removes text and undo restores it") {
        let f = SelectionFixture()
        defer { f.canvas.releaseResources() }
        let entry = Annotation(value: .text(TextAnnotation(origin: CGPoint(x: 50, y: 100), text: "Delete me")))
        f.document.apply([.insert(entry)])
        f.canvas.setAnnotations(f.document.entries)
        f.canvas.currentTool = .select
        f.click(CGPoint(x: 60, y: 110))
        f.canvas.keyDown(with: selectionKey(117))
        try expect(f.document.isEmpty)
        try expect(f.canvas.selectedAnnotationID == nil)
        f.canvas.keyDown(with: selectionKey(6, "z", flags: .command))
        try expectEqual(f.document.entries, [entry])
    }

    test("Number and Select toolbar controls switch tools and commit active text") {
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 900, height: 600),
            clipboardService: SelectionClipboard(), onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        let toolbar = canvas.subviews.compactMap { $0 as? AnnotationToolbarView }.first!
        canvas.beginTextEditing(.new(from: CGPoint(x: 40, y: 180), to: CGPoint(x: 40, y: 180), style: TextStyle()))
        canvas.textEditor?.insertText("Keep", replacementRange: NSRange(location: NSNotFound, length: 0))
        for (label, tool) in [("Number  (N)", AnnotationTool.number), ("Select  (V)", .select)] {
            let button = toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == label }!
            button.performClick(nil)
            try expectEqual(canvas.currentTool, tool)
            try expectEqual(controller.document.currentTool, tool)
            try expect(canvas.textEditor == nil)
        }
        try expectEqual(controller.document.entries.count, 1)
        try expect(toolbar.subviews.compactMap { $0 as? NSButton }.allSatisfy { toolbar.bounds.contains($0.frame) })
    }

    test("controller publishes only completed manipulation and export excludes selection handles") {
        let clipboard = SelectionClipboard()
        let base = makeTestCGImage(width: 900, height: 600)
        let controller = AnnotationWindowController(baseImage: base, clipboardService: clipboard, onFinished: {})
        controller.show()
        defer { controller.close() }
        let canvas = controller.canvasView!
        let text = TextAnnotation(origin: CGPoint(x: 80, y: 200), text: "Selection", width: 200)
        canvas.onCommit?(.text(text))
        try await waitUntil { clipboard.images.count == 1 }
        controller.selectTool(.select)
        @MainActor func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let local = CGPoint(x: point.x * canvas.imageToViewScale, y: point.y * canvas.imageToViewScale)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 90, y: 210)))
        canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 150, y: 260)))
        await pumpMainLoop(2)
        try expectEqual(clipboard.images.count, 1)
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 150, y: 260)))
        try await waitUntil { clipboard.images.count == 2 }
        try expect(canvas.selectedAnnotationID != nil)
        let expected = try ImageRenderer.render(baseImage: base, annotations: controller.document.annotations)
        try expectEqual(clipboard.images.last!.dataProvider!.data! as Data, expected.dataProvider!.data! as Data)
        try expectEqual(clipboard.images.last!.width, 900)
        try expectEqual(clipboard.images.last!.height, 600)
    }

    test("selection outlines and width handles are view-only and deselection restores export pixels") {
        let f = SelectionFixture()
        defer { f.canvas.releaseResources() }
        let text = TextAnnotation(origin: CGPoint(x: 50, y: 100), text: "Selected text", width: 180)
        f.document.commit(.text(text))
        f.document.commit(.number(NumberAnnotation(center: CGPoint(x: 350, y: 150))))
        f.canvas.setAnnotations(f.document.entries)
        f.canvas.currentTool = .select
        @MainActor func pixels() -> Data {
            let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: 400)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            f.canvas.draw(f.canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()!.dataProvider!.data! as Data
        }
        let exported = try ImageRenderer.render(baseImage: f.document.baseImage, annotations: f.document.annotations)
        let expected = exported.dataProvider!.data! as Data
        try expectEqual(pixels(), expected)
        f.click(CGPoint(x: 60, y: 110))
        try expect(pixels() != expected)
        f.canvas.keyDown(with: selectionKey(53))
        try expectEqual(pixels(), expected)
        f.click(CGPoint(x: 350, y: 150))
        try expect(pixels() != expected)
        f.canvas.keyDown(with: selectionKey(53))
        try expectEqual(pixels(), expected)
        try expectEqual(f.publications, 0)
    }
}

private func selectionFailure() -> ExpectationError {
    ExpectationError(message: "unexpected annotation type", file: #fileID, line: #line)
}
