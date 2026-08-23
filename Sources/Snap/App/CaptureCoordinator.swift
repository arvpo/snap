@MainActor
final class CaptureCoordinator {
    enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case capturing
        case selecting
        case annotating
    }

    private(set) var state: State = .idle
    private(set) var capturedDisplay: CapturedDisplay?
    private let captureService: ScreenCaptureServicing
    private var captureTask: Task<Void, Never>?

    /// Fired after leaving idle for a new session.
    var onSessionStarted: (() -> Void)?

    /// Fired after returning to idle from any busy state.
    var onSessionEnded: (() -> Void)?

    /// Fired only after ScreenCaptureKit has produced the pointer display snapshot.
    var onCapturedDisplay: ((CapturedDisplay) -> Void)?

    var onPermissionDenied: (() -> Void)?
    var onCaptureFailed: ((Error) -> Void)?

    init(captureService: ScreenCaptureServicing = ScreenCaptureService()) {
        self.captureService = captureService
    }

    /// Menu and hotkey both enter here. Requests outside idle are ignored.
    func handleCaptureRequest() {
        guard state == .idle else { return }

        if captureService.hasScreenRecordingAccess() {
            enterSession(startingAt: .capturing)
        } else {
            enterSession(startingAt: .requestingPermission)
            guard captureService.requestScreenRecordingAccess() else {
                onPermissionDenied?()
                permissionDenied()
                return
            }
            permissionGranted()
        }

        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capturedDisplay = try await captureService.captureDisplayAtPointer()
                guard !Task.isCancelled, state == .capturing else { return }
                self.capturedDisplay = capturedDisplay
                captureTask = nil
                snapshotCaptured()
                onCapturedDisplay?(capturedDisplay)
            } catch is CancellationError {
                // Session cancellation is already responsible for returning to idle.
            } catch {
                guard !Task.isCancelled else { return }
                captureTask = nil
                if case ScreenCaptureError.permissionDenied = error {
                    onPermissionDenied?()
                } else {
                    onCaptureFailed?(error)
                }
                captureFailed()
            }
        }
    }

    func beginPermissionRequest() {
        guard state == .idle else { return }
        enterSession(startingAt: .requestingPermission)
    }

    func permissionGranted() {
        guard state == .requestingPermission else { return }
        state = .capturing
    }

    func permissionDenied() {
        returnToIdle(from: .requestingPermission)
    }

    func captureFailed() {
        guard state == .requestingPermission || state == .capturing else { return }
        leaveSession()
    }

    func snapshotCaptured() {
        guard state == .capturing else { return }
        state = .selecting
    }

    func selectionCompleted() {
        guard state == .selecting else { return }
        state = .annotating
    }

    func finish() {
        guard state != .idle else { return }
        leaveSession()
    }

    func cancel() {
        guard state != .idle else { return }
        leaveSession()
    }

    private func enterSession(startingAt newState: State) {
        state = newState
        onSessionStarted?()
    }

    private func returnToIdle(from expected: State) {
        guard state == expected else { return }
        leaveSession()
    }

    private func leaveSession() {
        captureTask?.cancel()
        captureTask = nil
        capturedDisplay = nil
        state = .idle
        onSessionEnded?()
    }
}
