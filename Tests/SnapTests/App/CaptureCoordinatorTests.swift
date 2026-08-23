@testable import SnapCore

@MainActor
func registerCaptureCoordinatorTests() {
    test("capture request from idle enters capturing") {
        let coordinator = CaptureCoordinator()
        var started = 0
        coordinator.onSessionStarted = { started += 1 }

        coordinator.handleCaptureRequest()

        try expectEqual(coordinator.state, .capturing)
        try expectEqual(started, 1)
    }

    test("capture request while busy is ignored") {
        let coordinator = CaptureCoordinator()
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
        let coordinator = CaptureCoordinator()
        var ended = 0
        coordinator.onSessionEnded = { ended += 1 }

        coordinator.handleCaptureRequest()
        coordinator.cancel()
        coordinator.cancel()

        try expectEqual(coordinator.state, .idle)
        try expectEqual(ended, 1)
    }

    test("finish returns to idle from annotating") {
        let coordinator = CaptureCoordinator()
        coordinator.handleCaptureRequest()
        coordinator.snapshotCaptured()
        coordinator.selectionCompleted()

        try expectEqual(coordinator.state, .annotating)
        coordinator.finish()
        try expectEqual(coordinator.state, .idle)
    }

    test("permission denied returns to idle") {
        let coordinator = CaptureCoordinator()
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
        let coordinator = CaptureCoordinator()
        coordinator.beginPermissionRequest()
        coordinator.permissionGranted()
        try expectEqual(coordinator.state, .capturing)
    }

    test("invalid transitions do not move state") {
        let coordinator = CaptureCoordinator()
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
        let coordinator = CaptureCoordinator()
        coordinator.handleCaptureRequest()
        coordinator.captureFailed()
        try expectEqual(coordinator.state, .idle)
    }
}
