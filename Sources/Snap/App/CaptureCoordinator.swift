import CoreGraphics

@MainActor
final class CaptureCoordinator {
    enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case capturing
        case selecting
        case preparingClipboard
        case annotating
    }

    private(set) var state: State = .idle
    private(set) var capturedDisplay: CapturedDisplay?
    private(set) var selectedImage: CGImage?
    private let captureService: ScreenCaptureServicing
    private let clipboardPipeline: AnnotationRenderPipeline
    private var captureTask: Task<Void, Never>?
    private var sessionToken: CaptureSessionToken?

    /// Fired after leaving idle for a new session.
    var onSessionStarted: (() -> Void)?

    /// Fired after returning to idle from any busy state.
    var onSessionEnded: (() -> Void)?

    /// Fired only after ScreenCaptureKit has produced the pointer display snapshot.
    var onCapturedDisplay: ((CapturedDisplay) -> Void)?

    /// Fired after the crop is on the clipboard and the editor should open.
    var onSelectionCompleted: ((CGImage) -> Void)?

    var onPermissionDenied: (() -> Void)?
    var onCaptureFailed: ((Error) -> Void)?
    var onClipboardFailed: ((Error) -> Void)?
    var onPreparingClipboard: (() -> Void)?

    init(
        captureService: ScreenCaptureServicing = ScreenCaptureService(),
        clipboardService: ClipboardServicing = ClipboardService(),
        encode: @escaping AnnotationRenderPipeline.EncodeFunction = { try PNGEncoder.encode($0) }
    ) {
        self.captureService = captureService
        self.clipboardPipeline = AnnotationRenderPipeline(clipboardService: clipboardService,
            interval: .mouseUpToFirstClipboard, encode: encode)
        clipboardPipeline.onPublished = { [weak self] in
            guard let self, self.state == .preparingClipboard, let image = self.selectedImage else { return }
            self.state = .annotating
            self.onSelectionCompleted?(image)
        }
        clipboardPipeline.onRenderFailed = { [weak self] error in
            guard let self, self.state == .preparingClipboard else { return }
            self.onClipboardFailed?(error)
        }
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
        CaptureSignposts.shared.end(.hotkeyToSnapshot)
        CaptureSignposts.shared.begin(.snapshotToOverlay)
        state = .selecting
    }

    func selectionCompleted(with image: CGImage) {
        guard state == .selecting else { return }
        capturedDisplay = nil
        selectedImage = image
        state = .preparingClipboard
        onPreparingClipboard?()
        guard state == .preparingClipboard, selectedImage === image else { return }
        clipboardPipeline.scheduleRender(baseImage: image, annotations: [], startInterval: false)
    }

    func retryClipboard() {
        guard state == .preparingClipboard, let selectedImage else { return }
        clipboardPipeline.scheduleRender(baseImage: selectedImage, annotations: [])
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
        sessionToken = CaptureSessionToken()
        CaptureSignposts.shared.begin(.hotkeyToSnapshot)
        state = newState
        onSessionStarted?()
    }

    private func returnToIdle(from expected: State) {
        guard state == expected else { return }
        leaveSession()
    }

    private func leaveSession() {
        clipboardPipeline.invalidate()
        captureTask?.cancel()
        captureTask = nil
        capturedDisplay = nil
        selectedImage = nil
        CaptureSignposts.shared.abandonAll()
        sessionToken = nil
        state = .idle
        onSessionEnded?()
    }
}

/// Lives exactly as long as one coordinator session so a leaked busy
/// coordinator still drops the capture-session counter on deinit.
private final class CaptureSessionToken {
    init() {
        SessionLifetime.retain(.captureSession)
    }

    deinit {
        SessionLifetime.release(.captureSession)
    }
}
