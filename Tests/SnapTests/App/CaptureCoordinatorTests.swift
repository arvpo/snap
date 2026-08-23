@testable import SnapCore

@MainActor
private final class CaptureServiceStub: ScreenCaptureServicing {
    enum StubError: Error {
        case captureFailed
    }

    var hasAccess = true
    var requestResult = true
    private(set) var requestCount = 0
    private(set) var captureCount = 0

    func hasScreenRecordingAccess() -> Bool {
        hasAccess
    }

    func requestScreenRecordingAccess() -> Bool {
        requestCount += 1
        return requestResult
    }

    func captureDisplayAtPointer() async throws -> CapturedDisplay {
        captureCount += 1
        throw StubError.captureFailed
    }
}

@MainActor
func registerCaptureCoordinatorTests() {
    test("capture request from idle enters capturing") {
        let coordinator = CaptureCoordinator(captureService: CaptureServiceStub())
        var started = 0
        coordinator.onSessionStarted = { started += 1 }

        coordinator.handleCaptureRequest()

        try expectEqual(coordinator.state, .capturing)
        try expectEqual(started, 1)
    }

    test("capture request while busy is ignored") {
        let coordinator = CaptureCoordinator(captureService: CaptureServiceStub())
        var started = 0
        coordinator.onSessionStarted = { started += 1 }

        coordinator.handleCaptureRequest()
        coordinator.handleCaptureRequest()
        coordinator.snapshotCaptured()
        coordinator.handleCaptureRequest()

        try expectEqual(coordinator.state, .selecting)
        try expectEqual(started, 1)
    }

    test("cancel returns to idle and notifies once") {
        let coordinator = CaptureCoordinator(captureService: CaptureServiceStub())
        var ended = 0
        coordinator.onSessionEnded = { ended += 1 }

        coordinator.handleCaptureRequest()
        coordinator.cancel()
        coordinator.cancel()

        try expectEqual(coordinator.state, .idle)
        try expectEqual(ended, 1)
    }

    test("finish returns to idle from annotating") {
        let coordinator = CaptureCoordinator(captureService: CaptureServiceStub())
        coordinator.handleCaptureRequest()
        coordinator.snapshotCaptured()
        coordinator.selectionCompleted()

        try expectEqual(coordinator.state, .annotating)
        coordinator.finish()
        try expectEqual(coordinator.state, .idle)
    }

    test("permission denied returns to idle") {
        let coordinator = CaptureCoordinator(captureService: CaptureServiceStub())
        var started = 0
        var ended = 0
        coordinator.onSessionStarted = { started += 1 }
        coordinator.onSessionEnded = { ended += 1 }

        coordinator.beginPermissionRequest()
        try expectEqual(coordinator.state, .requestingPermission)
        coordinator.permissionDenied()

        try expectEqual(coordinator.state, .idle)
        try expectEqual(started, 1)
        try expectEqual(ended, 1)
    }

    test("permission granted advances to capturing") {
        let coordinator = CaptureCoordinator(captureService: CaptureServiceStub())
        coordinator.beginPermissionRequest()
        coordinator.permissionGranted()
        try expectEqual(coordinator.state, .capturing)
    }

    test("invalid transitions do not move state") {
        let coordinator = CaptureCoordinator(captureService: CaptureServiceStub())
        var started = 0
        var ended = 0
        coordinator.onSessionStarted = { started += 1 }
        coordinator.onSessionEnded = { ended += 1 }

        coordinator.permissionGranted()
        coordinator.permissionDenied()
        coordinator.snapshotCaptured()
        coordinator.selectionCompleted()
        coordinator.captureFailed()
        coordinator.finish()

        try expectEqual(coordinator.state, .idle)
        try expectEqual(started, 0)
        try expectEqual(ended, 0)
    }

    test("capture failed from capturing returns idle") {
        let coordinator = CaptureCoordinator(captureService: CaptureServiceStub())
        coordinator.handleCaptureRequest()
        coordinator.captureFailed()
        try expectEqual(coordinator.state, .idle)
    }

    test("denied capture request returns idle and reports once") {
        let service = CaptureServiceStub()
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

    test("one accepted request starts exactly one display capture") {
        let service = CaptureServiceStub()
        let coordinator = CaptureCoordinator(captureService: service)
        coordinator.handleCaptureRequest()
        coordinator.handleCaptureRequest()

        await Task.yield()
        await Task.yield()

        try expectEqual(service.captureCount, 1)
        try expectEqual(coordinator.state, .idle)
    }
}
