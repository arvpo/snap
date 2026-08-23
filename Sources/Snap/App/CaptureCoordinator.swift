/// Sole capture-session state machine.
///
/// Phase 1 only exercises idle → capturing → idle. Later phases drive permission,
/// snapshot, selection, and annotation through the same guarded transitions.
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

    /// Fired after leaving idle for a new session.
    var onSessionStarted: (() -> Void)?

    /// Fired after returning to idle from any busy state.
    var onSessionEnded: (() -> Void)?

    /// Menu and hotkey both enter here. Requests outside idle are ignored.
    func handleCaptureRequest() {
        guard state == .idle else { return }
        enterSession(startingAt: .capturing)
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
        state = .idle
        onSessionEnded?()
    }
}
