import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import SnapCore

private func encodePNG(_ image: CGImage) throws -> Int {
    try autoreleasepool {
        let encodedPNG = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedPNG,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardError.encoderCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardError.encodingFailed
        }
        return encodedPNG.length
    }
}

@MainActor
func registerPerformanceProbeTests() {
    test("ordinary-region crop and PNG encode stay under the clipboard budget") {
        let source = makeTestCGImage(width: 1920, height: 1080)
        let region = CGRect(x: 200, y: 180, width: 800, height: 600)

        let cropStarted = ContinuousClock.now
        let cropped = try SelectionCropper.deepCopy(source, pixelRect: region)
        let cropMs = milliseconds(from: cropStarted.duration(to: .now))

        let encodeStarted = ContinuousClock.now
        let byteCount = try encodePNG(cropped)
        let encodeMs = milliseconds(from: encodeStarted.duration(to: .now))
        let totalMs = cropMs + encodeMs

        print(
            String(
                format: "probe mouse-up-to-clipboard: crop %.2f ms, encode %.2f ms, total %.2f ms, png %d bytes",
                cropMs,
                encodeMs,
                totalMs,
                byteCount
            )
        )

        try expect(cropped.width == 800)
        try expect(cropped.height == 600)
        try expect(byteCount > 0)
        try expect(totalMs >= 0)
        try expect(totalMs < 50, "ordinary 800×600 crop+encode exceeded 50 ms: \(totalMs)")
    }

    test("annotation render and PNG encode stay under the clipboard budget") {
        let base = makeTestCGImage(width: 800, height: 600)
        let annotations: [AnnotationValue] = [
            .arrow(ArrowAnnotation(start: CGPoint(x: 40, y: 40), end: CGPoint(x: 240, y: 160))),
            .rectangle(RectangleAnnotation(rect: CGRect(x: 300, y: 200, width: 180, height: 90))),
            .privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 520, y: 80, width: 120, height: 70))),
        ]

        let renderStarted = ContinuousClock.now
        let rendered = try ImageRenderer.render(baseImage: base, annotations: annotations)
        let renderMs = milliseconds(from: renderStarted.duration(to: .now))

        let encodeStarted = ContinuousClock.now
        let byteCount = try encodePNG(rendered)
        let encodeMs = milliseconds(from: encodeStarted.duration(to: .now))
        let totalMs = renderMs + encodeMs

        print(
            String(
                format: "probe annotation-mouse-up-to-clipboard: render %.2f ms, encode %.2f ms, total %.2f ms, png %d bytes",
                renderMs,
                encodeMs,
                totalMs,
                byteCount
            )
        )

        try expect(rendered.width == 800)
        try expect(rendered.height == 600)
        try expect(byteCount > 0)
        try expect(totalMs >= 0)
        try expect(totalMs < 50, "ordinary annotated 800×600 render+encode exceeded 50 ms: \(totalMs)")
    }

    test("hotkey-to-snapshot signpost records a duration on a successful stub capture") {
        CaptureSignposts.shared.reset()
        let coordinator = CaptureCoordinator(
            captureService: SignpostCaptureService(),
            clipboardService: SignpostClipboardService()
        )
        coordinator.handleCaptureRequest()
        try await waitUntil { coordinator.state == .selecting }

        let duration = CaptureSignposts.shared.lastDurationsMilliseconds[.hotkeyToSnapshot]
        try expect(duration != nil, "hotkey-to-snapshot interval did not complete")
        try expect((duration ?? -1) >= 0)
        coordinator.cancel()
    }
}

@MainActor
private final class SignpostCaptureService: ScreenCaptureServicing {
    func hasScreenRecordingAccess() -> Bool { true }
    func requestScreenRecordingAccess() -> Bool { true }
    func captureDisplayAtPointer() async throws -> CapturedDisplay {
        makeTestCapturedDisplay()
    }
}

@MainActor
private final class SignpostClipboardService: ClipboardServicing {
    func writePNG(_ image: CGImage) throws {}
}
