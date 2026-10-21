import AppKit
import CoreGraphics
import Darwin
import Foundation
@testable import SnapCore

@MainActor
private final class WorkflowClipboard: ClipboardServicing {
    let pasteboard = NSPasteboard.withUniqueName()
    var writes = 0

    func publishPNG(_ data: Data) throws {
        pasteboard.clearContents()
        try expect(pasteboard.setData(data, forType: .png))
        writes += 1
    }
}

@MainActor
private final class WorkflowCapture: ScreenCaptureServicing {
    var captures = 0
    func hasScreenRecordingAccess() -> Bool { true }
    func requestScreenRecordingAccess() -> Bool { true }
    func captureDisplayAtPointer() async throws -> CapturedDisplay {
        captures += 1
        let scale: CGFloat = captures.isMultiple(of: 2) ? 2 : 1
        return makeTestCapturedDisplay(appKitFrame: CGRect(x: -1000, y: -400, width: 900, height: 700),
                                       backingScale: scale)
    }
}

func workflowKey(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!
}

@MainActor
func workflowMouse(_ type: NSEvent.EventType, _ point: CGPoint, canvas: AnnotationCanvasView,
                   clicks: Int = 1) -> NSEvent {
    let scale = canvas.imageToViewScale
    let local = CGPoint(x: point.x * scale, y: point.y * scale)
    return NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
        eventNumber: 0, clickCount: clicks, pressure: 1)!
}

@MainActor
private func click(_ point: CGPoint, canvas: AnnotationCanvasView, clicks: Int = 1) {
    canvas.mouseDown(with: workflowMouse(.leftMouseDown, point, canvas: canvas, clicks: clicks))
    canvas.mouseUp(with: workflowMouse(.leftMouseUp, point, canvas: canvas, clicks: clicks))
}

@MainActor
private func drag(_ from: CGPoint, _ to: CGPoint, canvas: AnnotationCanvasView) {
    canvas.mouseDown(with: workflowMouse(.leftMouseDown, from, canvas: canvas))
    canvas.mouseDragged(with: workflowMouse(.leftMouseDragged, to, canvas: canvas))
    canvas.mouseUp(with: workflowMouse(.leftMouseUp, to, canvas: canvas))
}

/// Drive real controller callbacks, native text, and pointer/key handlers. Return
/// values only, so finish/teardown cannot be kept alive by a test-held view.
@MainActor
private func editWorkflow(_ editor: AnnotationWindowController) throws -> [AnnotationValue] {
    let canvas = editor.canvasView!
    try expectEqual(canvas.currentTool, .arrow)
    try expect(canvas.textStyle == TextStyle(), "styles must reset with every capture")
    for (code, letter, tool, y) in [(UInt16(0), "a", AnnotationTool.arrow, 40),
                                  (15, "r", .rectangle, 90), (11, "b", .privacyBlock, 140)] {
        canvas.keyDown(with: workflowKey(code, letter))
        try expectEqual(editor.document.currentTool, tool)
        drag(CGPoint(x: 40, y: y), CGPoint(x: 140, y: y + 30), canvas: canvas)
    }
    canvas.keyDown(with: workflowKey(17, "t"))
    drag(CGPoint(x: 40, y: 210), CGPoint(x: 400, y: 210), canvas: canvas)
    canvas.setTextStyle(TextStyle(presentation: .callout, color: .blue, fontSize: 14))
    canvas.textEditor!.insertText("Review 世界", replacementRange: NSRange(location: NSNotFound, length: 0))
    canvas.textEditor!.keyDown(with: workflowKey(36, "\r", flags: .shift))
    canvas.textEditor!.insertText("e\u{301} 👩🏽‍💻", replacementRange: NSRange(location: NSNotFound, length: 0))
    canvas.textEditor!.keyDown(with: workflowKey(36, "\r"))
    let originalText = editor.document.entries[3]
    try expectEqual(editor.document.entries.count, 4)

    canvas.keyDown(with: workflowKey(45, "n"))
    for index in 0..<10 { click(CGPoint(x: 90 + (index % 5) * 145, y: 450 + (index / 5) * 125), canvas: canvas) }
    let original = editor.document.entries
    try expectEqual(original.count, 14)
    canvas.keyDown(with: workflowKey(9, "v"))
    drag(CGPoint(x: 90, y: 450), CGPoint(x: 90, y: 400), canvas: canvas)
    try expectEqual(editor.document.entries[4].id, original[4].id)
    try expect(editor.document.entries[4].value != original[4].value)
    canvas.keyDown(with: workflowKey(6, "z", flags: .command))
    try expectEqual(editor.document.entries, original)
    click(CGPoint(x: 90, y: 450), canvas: canvas)
    canvas.keyDown(with: workflowKey(117))
    try expectEqual(editor.document.annotations.compactMap { value -> Int? in
        if case .number(let marker) = value { return marker.number }; return nil
    }, Array(1...9))
    canvas.keyDown(with: workflowKey(6, "z", flags: .command))
    try expectEqual(editor.document.entries, original)

    click(CGPoint(x: 50, y: 220), canvas: canvas)
    try expectEqual(canvas.selectedAnnotationID, originalText.id)
    let handle = AnnotationSelection.widthHandle(for: originalText.value, scale: canvas.imageToViewScale,
                                                 imageSize: CGSize(width: 800, height: 640))!
    drag(CGPoint(x: handle.midX, y: handle.midY), CGPoint(x: handle.midX + 80, y: handle.midY), canvas: canvas)
    try expect(editor.document.entries[3].value != originalText.value)
    let resized = editor.document.entries[3]
    click(CGPoint(x: 50, y: 220), canvas: canvas, clicks: 2)
    try expectEqual(canvas.textSession?.annotationID, originalText.id)
    canvas.textEditor!.selectAll(nil)
    canvas.textEditor!.insertText("Canceled", replacementRange: NSRange(location: NSNotFound, length: 0))
    canvas.textEditor!.keyDown(with: workflowKey(53, "\u{1b}"))
    try expectEqual(editor.document.entries[3], resized)
    click(CGPoint(x: 50, y: 220), canvas: canvas, clicks: 2)
    canvas.textEditor!.selectAll(nil)
    canvas.textEditor!.insertText("Final 世界 👩🏽‍💻", replacementRange: NSRange(location: NSNotFound, length: 0))
    var expected = editor.document.annotations
    expected[3] = .text(canvas.textSession!.draft)
    // Leave native text active: Done must commit it before final publication.
    return expected
}

@MainActor
func registerAnnotationWorkflowTests() {
    for scale: CGFloat in [1, 0.5, 0.25] {
        test("phase6 complete text/marker workflow exports final pixels at scale \(scale)") {
            let clipboard = WorkflowClipboard()
            defer { clipboard.pasteboard.releaseGlobally() }
            weak var weakEditor: AnnotationWindowController?
            weak var weakCanvas: AnnotationCanvasView?
            weak var weakBase: CGImage?
            var finished = 0
            do {
                let base = makeTestCGImage(width: 800, height: 640)
                weakBase = base
                let editor = AnnotationWindowController(baseImage: base, clipboardService: clipboard,
                    onFinished: { finished += 1 })
                defer { editor.close() }
                weakEditor = editor
                editor.show()
                weakCanvas = editor.canvasView
                editor.canvasView!.setFrameSize(CGSize(width: 800 * scale, height: 640 * scale))
                let expected = try editWorkflow(editor)
                clipboard.pasteboard.clearContents()
                clipboard.pasteboard.setString("native text replaced image", forType: .string)
                editor.finish()
                try await waitUntil(timeout: .seconds(5)) { finished == 1 }
                try expect(editor.canvasView == nil)
                try expect(editor.document.isEmpty)
                let image = try decodedClipboardImage(clipboard.pasteboard.data(forType: .png)!)
                let rendered = try ImageRenderer.render(baseImage: base, annotations: expected)
                try expectEqual(image.width, 800)
                try expectEqual(image.height, 640)
                try expectEqual(image.dataProvider!.data! as Data, rendered.dataProvider!.data! as Data)
                editor.finish()
                editor.cancel()
                try expectEqual(finished, 1)
            }
            await pumpMainLoop()
            try await waitUntil(timeout: .seconds(2)) {
                weakEditor == nil && weakCanvas == nil && weakBase == nil && SessionLifetime.count(of: .renderTask) == 0
                    && SessionLifetime.Kind.allCases.allSatisfy { SessionLifetime.count(of: $0) == 0 }
            }
            try expectLifetimeZero()
        }
    }

    test("phase6 fifty mixed editing sessions release every presenter, image and native editor") {
        let capture = WorkflowCapture()
        try await repeatWorkflow(capture: capture, cycles: 50)
        try expectEqual(capture.captures, 50)
    }
}

@MainActor
private func repeatWorkflow(capture: ScreenCaptureServicing, cycles: Int) async throws {
    let clipboard = WorkflowClipboard()
    defer { clipboard.pasteboard.releaseGlobally() }
    let coordinator = CaptureCoordinator(captureService: capture, clipboardService: clipboard)
    let presenter = CaptureSessionPresenter(coordinator: coordinator, factories: .live(clipboardService: clipboard))
    presenter.bind()
    defer { coordinator.cancel(); presenter.dismissAll() }
    var captureFailure: Error?
    presenter.onCaptureFailed = { captureFailure = $0 }
    let initialRSS = try workflowRSS()
    var warmRSS: Double?
    for cycle in 0..<cycles {
        weak var fullDisplay: CGImage?
        weak var cropImage: CGImage?
        weak var weakEditor: AnnotationWindowController?
        weak var nativeText: AnnotationTextView?
        weak var textUndo: UndoManager?
        presenter.handleCaptureRequest()
        presenter.handleCaptureRequest() // A repeated hotkey during capture is ignored.
        try await waitUntil(timeout: .seconds(10)) { coordinator.state == .selecting || captureFailure != nil }
        if let captureFailure { throw captureFailure }
        do {
            let display = coordinator.capturedDisplay!
            fullDisplay = display.image
            let rect = CGRect(x: display.appKitFrame.minX + 20, y: display.appKitFrame.minY + 20,
                              width: 800 / display.backingScale, height: 640 / display.backingScale)
            let selection = Selection(appKitRect: rect, displayFrame: display.appKitFrame, pixelSize: display.pixelSize)!
            let crop = try SelectionCropper.deepCopy(display.image, pixelRect: selection.pixelRect)
            cropImage = crop
            coordinator.selectionCompleted(with: crop)
        }
        try await waitUntil(timeout: .seconds(5)) { coordinator.state == .annotating }
        try expect(fullDisplay == nil, "crop or overlay retained the full display")
        try expect(presenter.overlay == nil)
        do {
            let editor = presenter.editor as! AnnotationWindowController
            weakEditor = editor
            _ = try editWorkflow(editor)
            nativeText = editor.canvasView?.textEditor
            textUndo = nativeText?.undoManager
            if cycle.isMultiple(of: 2) { editor.finish() }
            else {
                // Cancel native editing before closing, without publishing the draft.
                editor.canvasView?.textEditor?.keyDown(with: workflowKey(53, "\u{1b}"))
                editor.cancel()
            }
        }
        try await waitUntil(timeout: .seconds(5)) { coordinator.state == .idle && SessionLifetime.count(of: .renderTask) == 0 }
        await pumpMainLoop(2)
        try expect(presenter.editor == nil && presenter.overlay == nil)
        try await waitUntil(timeout: .seconds(2)) {
            weakEditor == nil && nativeText == nil && textUndo == nil && cropImage == nil
                && SessionLifetime.Kind.allCases.allSatisfy { SessionLifetime.count(of: $0) == 0 }
        }
        try expectLifetimeZero()
        if cycle == 4 || cycle == cycles - 1 {
            // Let allocator/AppKit cleanup settle. This is test-process RSS,
            // not the idle budget or real-capture gate for the packaged app.
            try await Task.sleep(for: .seconds(2))
            let rss = try workflowRSS()
            if cycle == 4 { warmRSS = rss }
            if cycle == cycles - 1, let warmRSS {
                print(String(format: "probe phase6 %d cycles test-process RSS: initial %.2f MB, after 5 %.2f MB, after %d %.2f MB; warm delta %.2f MB (<10MB %@), sampled 2s after cleanup",
                    cycles, initialRSS, warmRSS, cycles, rss, rss - warmRSS, rss - warmRSS < 10 ? "MET" : "MISSED"))
            }
        }
    }
}

private func workflowRSS() throws -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    try expectEqual(result, KERN_SUCCESS)
    return Double(info.resident_size) / 1_048_576
}

@MainActor
func registerLiveAnnotationWorkflowTests() {
    test("phase6 live capture 50 cycles (requires Screen Recording permission)") {
        let capture = ScreenCaptureService()
        try expect(capture.hasScreenRecordingAccess(),
                   "UNAVAILABLE: test runner has no Screen Recording access; no real capture cycles were run")
        try await repeatWorkflow(capture: capture, cycles: 50)
        print("phase6 live: 50 ScreenCaptureKit captures and programmatic editor sessions completed; physical input/Spaces checks remain manual")
    }
}
