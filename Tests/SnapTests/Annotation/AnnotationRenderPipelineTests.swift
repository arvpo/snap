import CoreGraphics
@testable import SnapCore

private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
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

    func writePNG(_ image: CGImage) throws {
        writeCount += 1
        writtenImages.append(image)
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
        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard) { image, _ in image }

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

        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard) { image, _ in
            if image.width == 2 {
                await gate.wait()
            }
            return image
        }

        let staleTask = pipeline.scheduleRender(baseImage: slowImage, annotations: [])
        let freshTask = pipeline.scheduleRender(baseImage: fastImage, annotations: [])

        await freshTask.value
        try expectEqual(clipboard.writeCount, 1)
        try expectEqual(clipboard.writtenImages.first?.width, 4)

        await gate.open()
        await staleTask.value

        try expect(clipboard.writeCount == 1, "a stale render must not overwrite the newer clipboard write")
    }

    test("invalidate discards a render already in flight") {
        let clipboard = ClipboardServiceStub()
        let gate = Gate()

        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard) { image, _ in
            await gate.wait()
            return image
        }

        let task = pipeline.scheduleRender(baseImage: markerImage(width: 5), annotations: [])
        pipeline.invalidate()

        await gate.open()
        await task.value

        try expectEqual(clipboard.writeCount, 0)
    }

    test("rapid undo followed by a new render leaves the clipboard on the latest state") {
        let clipboard = ClipboardServiceStub()
        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard) { image, _ in image }

        var lastTask = pipeline.scheduleRender(baseImage: markerImage(width: 1), annotations: [])
        for width in 2...5 {
            lastTask = pipeline.scheduleRender(baseImage: markerImage(width: width), annotations: [])
        }
        await lastTask.value

        try expectEqual(clipboard.writeCount, 1)
        try expectEqual(clipboard.writtenImages.first?.width, 5)
    }
}
