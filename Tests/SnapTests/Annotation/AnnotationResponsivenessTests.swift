import AppKit
import CoreGraphics
import Foundation
@testable import SnapCore

private actor WorkGate {
    private var open = false
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        arrival?.resume()
        arrival = nil
        if !open { await withCheckedContinuation { release = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func resume() {
        open = true
        release?.resume()
        release = nil
    }
}

private actor WorkLog {
    var renders: [Int] = []
    var encodes: [Int] = []
    func rendered(_ width: Int) { renders.append(width) }
    func encoded(_ width: Int) { encodes.append(width) }
}

@MainActor
private final class ResponsiveClipboard: ClipboardServicing {
    var widths: [Int] = []
    var fail = false
    func publishPNG(_ data: Data) throws {
        if fail { throw ClipboardError.pasteboardWriteFailed }
        widths.append(try decodedClipboardImage(data).width)
    }
}

@MainActor
private final class ResponsiveCapture: ScreenCaptureServicing {
    func hasScreenRecordingAccess() -> Bool { true }
    func requestScreenRecordingAccess() -> Bool { true }
    func captureDisplayAtPointer() async throws -> CapturedDisplay { makeTestCapturedDisplay() }
}

@MainActor
private func beginSelection(_ coordinator: CaptureCoordinator) async throws {
    coordinator.handleCaptureRequest()
    try await waitUntil { coordinator.state == .selecting }
}

// Locking allows worker callbacks to report ownership without retaining the image
// or data being measured. Data's deallocator proves the final task released it.
private final class BufferProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var image: CGImage?
    private var pngs = 0
    func record(_ image: CGImage) {
        lock.lock(); defer { lock.unlock() }
        self.image = image
    }
    func payload() -> Data {
        lock.lock(); pngs += 1; lock.unlock()
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 16)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: 1024)
        return Data(bytesNoCopy: bytes, count: 1024, deallocator: .custom { [self] pointer, _ in
            pointer.deallocate()
            lock.lock(); pngs -= 1; lock.unlock()
        })
    }
    var empty: Bool {
        lock.lock(); defer { lock.unlock() }
        return image == nil && pngs == 0
    }
}

@MainActor
private final class DiscardClipboard: ClipboardServicing {
    var calls = 0
    func publishPNG(_ data: Data) throws { calls += 1 }
}

@MainActor
func registerAnnotationResponsivenessTests() {
    test("100 pending edits replace one snapshot while the active encoder drains") {
        let clipboard = ResponsiveClipboard()
        let gate = WorkGate()
        let log = WorkLog()
        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, encode: { image in
            await log.encoded(image.width)
            if image.width == 8 { await gate.pause() }
            return try PNGEncoder.encode(image)
        }, render: { image, _ in
            await log.rendered(image.width)
            return image
        })
        pipeline.scheduleRender(baseImage: makeTestCGImage(), annotations: [])
        await gate.waitForEntry()
        for width in 9...108 {
            pipeline.scheduleRender(baseImage: makeTestCGImage(width: width), annotations: [])
        }
        let pending = pipeline.hasPendingSnapshot
        let before = await log.renders
        await gate.resume()
        let published = await pipeline.awaitPendingRender()
        try expect(pending)
        try expectEqual(before, [8])
        try expectEqual(await log.renders, [8, 108])
        try expectEqual(await log.encodes, [8, 108])
        try expectEqual(clipboard.widths, [108])
        try expect(published)
        try expect(!pipeline.isWorking && !pipeline.hasPendingSnapshot)
    }

    test("invalidated sessions share one worker lane and never publish obsolete PNGs") {
        let clipboard = ResponsiveClipboard()
        let gate = WorkGate()
        let log = WorkLog()
        let old = AnnotationRenderPipeline(clipboardService: clipboard, encode: { image in
            await gate.pause()
            return try PNGEncoder.encode(image)
        })
        old.scheduleRender(baseImage: makeTestCGImage(width: 10), annotations: [])
        await gate.waitForEntry()
        old.invalidate()
        let next = AnnotationRenderPipeline(clipboardService: clipboard, render: { image, _ in
            await log.rendered(image.width)
            return image
        })
        next.scheduleRender(baseImage: makeTestCGImage(width: 20), annotations: [])
        await pumpMainLoop(2)
        let before = await log.renders
        await gate.resume()
        let oldPublished = await old.awaitPendingRender()
        let nextPublished = await next.awaitPendingRender()
        try expectEqual(before, [])
        try expect(!oldPublished && nextPublished)
        try expectEqual(clipboard.widths, [20])
        try expect(!old.isWorking && !next.isWorking)
    }

    test("superseded render failures are silent and skip obsolete encoding") {
        let clipboard = ResponsiveClipboard()
        let gate = WorkGate()
        let log = WorkLog()
        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, encode: { image in
            await log.encoded(image.width)
            return try PNGEncoder.encode(image)
        }, render: { image, _ in
            if image.width == 8 {
                await gate.pause()
                throw ImageRenderError.imageCreationFailed
            }
            return image
        })
        var failures = 0
        pipeline.onRenderFailed = { _ in failures += 1 }
        pipeline.scheduleRender(baseImage: makeTestCGImage(), annotations: [])
        await gate.waitForEntry()
        pipeline.scheduleRender(baseImage: makeTestCGImage(width: 11), annotations: [])
        await gate.resume()
        await pipeline.awaitPendingRender()
        try expectEqual(failures, 0)
        try expectEqual(await log.encodes, [11])
        try expectEqual(clipboard.widths, [11])
    }

    test("render encode and publication failures release tasks and can be retried") {
        for stage in 0...2 {
            let clipboard = ResponsiveClipboard()
            clipboard.fail = stage == 2
            let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, encode: { image in
                if stage == 1 && image.width == 8 { throw ClipboardError.encodingFailed }
                return try PNGEncoder.encode(image)
            }, render: { image, _ in
                if stage == 0 && image.width == 8 { throw ImageRenderError.contextCreationFailed }
                return image
            })
            var failures = 0
            pipeline.onRenderFailed = { _ in failures += 1 }
            pipeline.scheduleRender(baseImage: makeTestCGImage(), annotations: [])
            let failed = await pipeline.awaitPendingRender()
            try expect(!failed)
            try expectEqual(failures, 1)
            try expect(pipeline.lastError != nil && !pipeline.isWorking)
            clipboard.fail = false
            pipeline.scheduleRender(baseImage: makeTestCGImage(width: 9), annotations: [])
            let retried = await pipeline.awaitPendingRender()
            try expect(retried)
            try expect(pipeline.lastError == nil && !pipeline.hasPendingSnapshot)
            try expectEqual(clipboard.widths, [9])
        }
    }

    test("selection opens each editor immediately and ignores duplicate selections") {
        let coordinator = CaptureCoordinator(captureService: ResponsiveCapture())
        var opened: [Int] = []
        coordinator.onSelectionCompleted = { opened.append($0.width) }
        try await beginSelection(coordinator)
        coordinator.selectionCompleted(with: makeTestCGImage())
        try expectEqual(coordinator.state, .annotating)
        coordinator.handleCaptureRequest()
        coordinator.selectionCompleted(with: makeTestCGImage(width: 99))
        coordinator.cancel()
        try await beginSelection(coordinator)
        coordinator.selectionCompleted(with: makeTestCGImage(width: 12))
        try expectEqual(coordinator.state, .annotating)
        try expectEqual(opened, [8, 12])
        try expect(coordinator.capturedDisplay == nil)
        coordinator.cancel()
        try expect(coordinator.selectedImage == nil)
    }

    test("editing with a failing clipboard stays local until explicit Done") {
        let clipboard = ResponsiveClipboard()
        clipboard.fail = true
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(),
            clipboardService: clipboard, onFinished: {})
        controller.show()
        defer { controller.close() }
        controller.canvasView?.onCommit?(.number(NumberAnnotation(center: CGPoint(x: 3, y: 3))))
        await pumpMainLoop()
        try expect(controller.clipboardError == nil)
        try expectEqual(clipboard.widths, [])
        controller.finish()
        try await waitUntil { controller.clipboardError != nil }
    }

    test("edits stay local and Done waits for the final draft to encode") {
        let clipboard = ResponsiveClipboard()
        let gate = WorkGate()
        var finished = 0
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(width: 400, height: 300),
            clipboardService: clipboard, encode: { image in
                await gate.pause()
                return try PNGEncoder.encode(image)
            }, onFinished: { finished += 1 })
        controller.show()
        let canvas = controller.canvasView!
        canvas.onCommit?(.number(NumberAnnotation(center: CGPoint(x: 30, y: 30))))
        await pumpMainLoop()
        try expectEqual(clipboard.widths, [])
        controller.selectTool(.text)
        canvas.beginTextEditing(.new(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 40, y: 40), style: TextStyle()))
        canvas.textEditor?.insertText("Responsive 世界", replacementRange: NSRange(location: NSNotFound, length: 0))
        let typed = canvas.textEditor?.string
        controller.finish()
        await gate.waitForEntry()
        let before = finished
        await gate.resume()
        try await waitUntil { finished == 1 }
        try expectEqual(typed, "Responsive 世界")
        try expectEqual(before, 0)
        try expectEqual(clipboard.widths, [400])
        try expect(controller.canvasView == nil)
    }

    test("Done publication failure stays retryable and closes only after success") {
        let clipboard = ResponsiveClipboard()
        clipboard.fail = true
        var finished = 0
        let controller = AnnotationWindowController(baseImage: makeTestCGImage(), clipboardService: clipboard,
                                                    onFinished: { finished += 1 })
        controller.show()
        controller.finish()
        try await waitUntil { controller.clipboardError != nil }
        try expectEqual(finished, 0)
        try expect(controller.canvasView != nil)
        clipboard.fail = false
        let panel = NSApp.windows.first { $0.isVisible && $0.title == "Snap could not update the clipboard" }
        let retry = panel?.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Retry" }
        try expect(retry != nil)
        retry?.performClick(nil)
        try await waitUntil { finished == 1 }
        try expectEqual(clipboard.widths, [8])
        try expect(controller.canvasView == nil && controller.clipboardError == nil)
    }

    test("Close during failed Done and cancellation during encoding never publish or finish twice") {
        let clipboard = ResponsiveClipboard()
        let gate = WorkGate()
        var finished = 0
        var controller: AnnotationWindowController? = AnnotationWindowController(baseImage: makeTestCGImage(),
            clipboardService: clipboard, encode: { image in
                await gate.pause()
                return try PNGEncoder.encode(image)
            }, onFinished: { finished += 1 })
        weak let weakController = controller
        controller?.show()
        controller?.finish()
        await gate.waitForEntry()
        controller?.cancel()
        controller = nil
        let released = weakController == nil
        await gate.resume()
        try await waitUntil { SessionLifetime.count(of: .renderTask) == 0 }
        try expect(released)
        try expectEqual(finished, 1)
        try expectEqual(clipboard.widths, [])

        clipboard.fail = true
        let failedController = AnnotationWindowController(baseImage: makeTestCGImage(), clipboardService: clipboard,
                                                          onFinished: { finished += 1 })
        failedController.show()
        failedController.finish()
        try await waitUntil { failedController.clipboardError != nil }
        let panel = NSApp.windows.first { $0.isVisible && $0.title == "Snap could not update the clipboard" }
        let close = panel?.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Close" }
        try expectEqual(close?.keyEquivalent, "\u{1b}")
        close?.performClick(nil)
        try expectEqual(finished, 2)
        try expect(failedController.canvasView == nil)
    }
    test("dirty canvas tiles cull distant annotations and preserve complete export pixels") {
        let base = makeTestCGImage(width: 400, height: 240)
        let canvas = AnnotationCanvasView(baseImage: base)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 240)
        defer { canvas.releaseResources() }
        let entries = [
            Annotation(value: .text(TextAnnotation(origin: CGPoint(x: 20, y: 25), text: "Unicode 世界", width: 140))),
            Annotation(value: .number(NumberAnnotation(center: CGPoint(x: 260, y: 50), number: 100))),
            Annotation(value: .privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 210, y: 150, width: 80, height: 40)))),
            Annotation(value: .arrow(ArrowAnnotation(start: CGPoint(x: 30, y: 180), end: CGPoint(x: 130, y: 210))))
        ]
        canvas.setAnnotations(entries)
        let context = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 240)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for y in stride(from: 0, to: 240, by: 60) {
            for x in stride(from: 0, to: 400, by: 100) {
                canvas.draw(CGRect(x: x, y: y, width: 100, height: 60))
                try expect(canvas.lastDrawnAnnotationCount < entries.count)
            }
        }
        let expected = try ImageRenderer.render(baseImage: base, annotations: entries.map(\.value))
        try expectEqual(context.makeImage()!.dataProvider!.data! as Data, expected.dataProvider!.data! as Data)

        // Remove ink in one region: drawing the transparent base must erase it.
        canvas.setAnnotations(Array(entries.dropLast()))
        canvas.draw(CGRect(x: 0, y: 160, width: 150, height: 80))
        let removed = try ImageRenderer.render(baseImage: base, annotations: entries.dropLast().map(\.value))
        try expectEqual(context.makeImage()!.dataProvider!.data! as Data, removed.dataProvider!.data! as Data)
    }

    test("background render and PNG encode publish separate timings on the main actor") {
        CaptureSignposts.shared.reset()
        let pipeline = AnnotationRenderPipeline(clipboardService: ClipboardService(), encode: { image in
            try expect(!Thread.isMainThread, "PNG encoding ran on the main thread")
            return try PNGEncoder.encode(image)
        }, render: { image, annotations in
            try expect(!Thread.isMainThread, "rendering ran on the main thread")
            return try ImageRenderer.render(baseImage: image, annotations: annotations)
        })
        pipeline.scheduleRender(baseImage: makeTestCGImage(width: 80, height: 60), annotations: [])
        let published = await pipeline.awaitPendingRender()
        try expect(published)
        for interval: CaptureInterval in [.annotationRender, .pngEncode, .clipboardPublication, .annotationMouseUpToClipboard] {
            try expect((CaptureSignposts.shared.lastDurationsMilliseconds[interval] ?? -1) >= 0)
        }
    }

    test("ordinary crop pipeline records commit-to-clipboard percentiles including publication") {
        let pipeline = AnnotationRenderPipeline(clipboardService: ClipboardService())
        let base = makeTestCGImage(width: 800, height: 600)
        let annotations: [AnnotationValue] = [
            .arrow(ArrowAnnotation(start: CGPoint(x: 40, y: 40), end: CGPoint(x: 240, y: 160))),
            .rectangle(RectangleAnnotation(rect: CGRect(x: 300, y: 200, width: 180, height: 90))),
            .privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 520, y: 80, width: 120, height: 70)))
        ]
        var totals: [Double] = []
        var renders: [Double] = []
        var encodes: [Double] = []
        var publications: [Double] = []
        for iteration in 0..<32 {
            pipeline.scheduleRender(baseImage: base, annotations: annotations)
            let published = await pipeline.awaitPendingRender()
            try expect(published)
            if iteration < 2 { continue }
            let durations = CaptureSignposts.shared.lastDurationsMilliseconds
            totals.append(durations[.annotationMouseUpToClipboard]!)
            renders.append(durations[.annotationRender]!)
            encodes.append(durations[.pngEncode]!)
            publications.append(durations[.clipboardPublication]!)
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
        print(String(format: "probe phase5 pipeline (30 samples): total p95 %.2f ms, render p95 %.2f ms, encode p95 %.2f ms, publication p95 %.2f ms",
                     p95(totals), p95(renders), p95(encodes), p95(publications)))
        try expectEqual(totals.count, 30)
    }

    test("completed and canceled workers release output pixels and PNG even when task handles survive") {
        for cancel in [false, true] {
            let probe = BufferProbe()
            let gate = WorkGate()
            let clipboard = DiscardClipboard()
            let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, encode: { image in
                probe.record(image)
                let data = probe.payload()
                await gate.pause()
                return data
            }, render: { image, annotations in
                try ImageRenderer.render(baseImage: image, annotations: annotations)
            })
            let task = pipeline.scheduleRender(baseImage: makeTestCGImage(), annotations: [])
            await gate.waitForEntry()
            if cancel { pipeline.invalidate() }
            await gate.resume()
            await task.value
            try expect(probe.empty, "completed task retained an output image or PNG")
            try expect(!pipeline.isWorking && !pipeline.hasPendingSnapshot)
            try expectEqual(clipboard.calls, cancel ? 0 : 1)
            withExtendedLifetime(task) {}
        }
    }

}
