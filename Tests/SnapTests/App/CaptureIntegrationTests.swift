import CoreGraphics
@testable import SnapCore

@MainActor
private final class IntegrationCaptureService: ScreenCaptureServicing {
    var hasAccess = true
    var requestResult = true
    var captureResult: Result<CapturedDisplay, Error> = .success(makeTestCapturedDisplay())
    private(set) var requestCount = 0
    private(set) var captureCount = 0

    func hasScreenRecordingAccess() -> Bool { hasAccess }

    func requestScreenRecordingAccess() -> Bool {
        requestCount += 1
        return requestResult
    }

    func captureDisplayAtPointer() async throws -> CapturedDisplay {
        captureCount += 1
        return try captureResult.get()
    }
}

@MainActor
private final class IntegrationClipboardService: ClipboardServicing {
    private(set) var writeCount = 0
    private(set) var lastImage: CGImage?

    func writePNG(_ image: CGImage) throws {
        writeCount += 1
        lastImage = image
    }
}

@MainActor
func registerCaptureIntegrationTests() {
    test("hotkey-to-capture seam starts exactly one snapshot from idle") {
        let service = IntegrationCaptureService()
        let coordinator = CaptureCoordinator(captureService: service)
        let hotkeySeam: () -> Void = { coordinator.handleCaptureRequest() }

        hotkeySeam()
        try expectEqual(coordinator.state, .capturing)
        hotkeySeam()
        try await waitUntil { coordinator.state == .selecting }

        try expectEqual(service.captureCount, 1)
        try expectEqual(coordinator.state, .selecting)
    }

    test("capture-to-selection seam publishes the frozen display") {
        let service = IntegrationCaptureService()
        let display = makeTestCapturedDisplay(displayID: 7)
        service.captureResult = .success(display)
        let coordinator = CaptureCoordinator(captureService: service)
        var publishedID: CGDirectDisplayID?
        coordinator.onCapturedDisplay = { publishedID = $0.displayID }

        coordinator.handleCaptureRequest()
        try await waitUntil { coordinator.state == .selecting }

        try expectEqual(publishedID, 7)
        try expectEqual(coordinator.state, .selecting)
    }

    test("selection-to-editor seam writes the clipboard and enters annotating") {
        let service = IntegrationCaptureService()
        let clipboard = IntegrationClipboardService()
        let coordinator = CaptureCoordinator(
            captureService: service,
            clipboardService: clipboard
        )
        var editorImage: CGImage?
        coordinator.onSelectionCompleted = { editorImage = $0 }

        coordinator.handleCaptureRequest()
        try await waitUntil { coordinator.state == .selecting }
        let crop = makeTestCGImage(width: 4, height: 4)
        coordinator.selectionCompleted(with: crop)

        try expectEqual(coordinator.state, .annotating)
        try expectEqual(clipboard.writeCount, 1)
        try expect(editorImage === crop)
        try expect(coordinator.capturedDisplay == nil)
        try expect(coordinator.selectedImage === crop)
    }

    test("cancel from selecting leaves the clipboard untouched") {
        let service = IntegrationCaptureService()
        let clipboard = IntegrationClipboardService()
        let coordinator = CaptureCoordinator(
            captureService: service,
            clipboardService: clipboard
        )

        coordinator.handleCaptureRequest()
        try await waitUntil { coordinator.state == .selecting }
        coordinator.cancel()

        try expectEqual(coordinator.state, .idle)
        try expectEqual(clipboard.writeCount, 0)
        try expect(coordinator.capturedDisplay == nil)
        try expect(coordinator.selectedImage == nil)
    }

    test("permission failure never starts a capture") {
        let service = IntegrationCaptureService()
        service.hasAccess = false
        service.requestResult = false
        let coordinator = CaptureCoordinator(captureService: service)
        var denied = 0
        coordinator.onPermissionDenied = { denied += 1 }

        coordinator.handleCaptureRequest()

        try expectEqual(coordinator.state, .idle)
        try expectEqual(service.requestCount, 1)
        try expectEqual(service.captureCount, 0)
        try expectEqual(denied, 1)
    }

    test("repeated invocation after idle starts a second capture") {
        let service = IntegrationCaptureService()
        let coordinator = CaptureCoordinator(captureService: service)

        coordinator.handleCaptureRequest()
        try await waitUntil { coordinator.state == .selecting }
        coordinator.cancel()
        try expectEqual(coordinator.state, .idle)

        coordinator.handleCaptureRequest()
        try await waitUntil { coordinator.state == .selecting }

        try expectEqual(service.captureCount, 2)
        coordinator.cancel()
    }

    test("a completed session releases capture images before the next request") {
        let service = IntegrationCaptureService()
        let clipboard = IntegrationClipboardService()
        let coordinator = CaptureCoordinator(
            captureService: service,
            clipboardService: clipboard
        )

        coordinator.handleCaptureRequest()
        try await waitUntil { coordinator.state == .selecting }
        coordinator.selectionCompleted(with: makeTestCGImage())
        try expectEqual(coordinator.state, .annotating)
        coordinator.finish()

        try expectEqual(coordinator.state, .idle)
        try expect(coordinator.capturedDisplay == nil)
        try expect(coordinator.selectedImage == nil)

        coordinator.handleCaptureRequest()
        try await waitUntil { coordinator.state == .selecting }
        try expect(coordinator.capturedDisplay != nil)
        coordinator.cancel()
    }
}
