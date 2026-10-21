import Foundation
import CoreGraphics
@testable import SnapCore

private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func wait() async {
        entered = true
        entryContinuation?.resume()
        entryContinuation = nil
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ClipboardServiceStub: ClipboardServicing {
    private(set) var writeCount = 0
    private(set) var writtenImages: [CGImage] = []

    func publishPNG(_ data: Data) throws {
        writeCount += 1
        writtenImages.append(try decodedClipboardImage(data))
    }
}

private func markerImage(width: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

@MainActor
func registerAnnotationRenderPipelineTests() {
    test("a completed render publishes exactly one clipboard write") {
        let clipboard = ClipboardServiceStub()
        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, render: { image, _ in image })

        let task = pipeline.scheduleRender(baseImage: markerImage(width: 3), annotations: [])
        await task.value

        try expectEqual(clipboard.writeCount, 1)
        try expectEqual(clipboard.writtenImages.first?.width, 3)
    }

    test("a stale render never overwrites a newer clipboard result") {
        let clipboard = ClipboardServiceStub()
        let gate = Gate()
        let slowImage = markerImage(width: 2)
        let fastImage = markerImage(width: 4)

        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, render: { image, _ in
            if image.width == 2 {
                await gate.wait()
            }
            return image
        })

        let staleTask = pipeline.scheduleRender(baseImage: slowImage, annotations: [])
        await gate.waitForEntry()
        let freshTask = pipeline.scheduleRender(baseImage: fastImage, annotations: [])
        let writesWhileBlocked = clipboard.writeCount
        await gate.open()
        await freshTask.value
        try expectEqual(writesWhileBlocked, 0)
        try expectEqual(clipboard.writeCount, 1)
        try expectEqual(clipboard.writtenImages.first?.width, 4)

        await staleTask.value

        try expect(clipboard.writeCount == 1, "a stale render must not overwrite the newer clipboard write")
    }

    test("invalidate discards a render already in flight") {
        let clipboard = ClipboardServiceStub()
        let gate = Gate()

        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, render: { image, _ in
            await gate.wait()
            return image
        })

        let task = pipeline.scheduleRender(baseImage: markerImage(width: 5), annotations: [])
        pipeline.invalidate()

        await gate.open()
        await task.value

        try expectEqual(clipboard.writeCount, 0)
    }

    test("awaiting the pending render guarantees the latest edit reaches the clipboard") {
        let clipboard = ClipboardServiceStub()
        let gate = Gate()
        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, render: { image, _ in
            await gate.wait()
            return image
        })

        let task = pipeline.scheduleRender(baseImage: markerImage(width: 7), annotations: [])

        // Simulates closing the editor right after a commit, before its
        // render has finished: `finish()` must not drop this edit.
        async let awaited: Bool = pipeline.awaitPendingRender()
        await gate.open()
        _ = await awaited
        await task.value

        try expectEqual(clipboard.writeCount, 1)
        try expectEqual(clipboard.writtenImages.first?.width, 7)
    }

    test("rapid undo followed by a new render leaves the clipboard on the latest state") {
        let clipboard = ClipboardServiceStub()
        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard, render: { image, _ in image })

        var lastTask = pipeline.scheduleRender(baseImage: markerImage(width: 1), annotations: [])
        for width in 2...5 {
            lastTask = pipeline.scheduleRender(baseImage: markerImage(width: width), annotations: [])
        }
        await lastTask.value

        try expectEqual(clipboard.writeCount, 1)
        try expectEqual(clipboard.writtenImages.first?.width, 5)
    }
}
