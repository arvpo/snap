import CoreGraphics
@testable import SnapCore

@MainActor
private final class OverlayStub: OverlaySession {
    private(set) var showCount = 0
    private(set) var closeCount = 0
    private(set) var lastDisplay: CapturedDisplay?

    func show(_ capturedDisplay: CapturedDisplay) {
        showCount += 1
        lastDisplay = capturedDisplay
    }

    func close() {
        closeCount += 1
    }
}

@MainActor
private final class EditorStub: EditorSession {
    private(set) var showCount = 0
    private(set) var closeCount = 0
    var onFinished: (() -> Void)?

    func show() {
        showCount += 1
    }

    func close() {
        closeCount += 1
    }

    func finishFromUI() {
        let callback = onFinished
        onFinished = nil
        callback?()
    }
}

@MainActor
private final class PresenterCaptureService: ScreenCaptureServicing {
    var hasAccess = true
    var requestResult = true
    var captureResult: Result<CapturedDisplay, Error> = .success(makeTestCapturedDisplay())
    private(set) var captureCount = 0

    func hasScreenRecordingAccess() -> Bool { hasAccess }

    func requestScreenRecordingAccess() -> Bool { requestResult }

    func captureDisplayAtPointer() async throws -> CapturedDisplay {
        captureCount += 1
        return try captureResult.get()
    }
}

@MainActor
private final class PresenterClipboardService: ClipboardServicing {
    var writeError: Error?
    private(set) var writeCount = 0

    func writePNG(_ image: CGImage) throws {
        if let writeError { throw writeError }
        writeCount += 1
    }
}

@MainActor
private final class PresenterHarness {
    let service: PresenterCaptureService
    let clipboard: PresenterClipboardService
    let coordinator: CaptureCoordinator
    let overlay: OverlayStub
    let editor: EditorStub
    let presenter: CaptureSessionPresenter
    private(set) var permissionDeniedCount = 0
    private(set) var captureFailedCount = 0

    private init(
        service: PresenterCaptureService,
        clipboard: PresenterClipboardService,
        coordinator: CaptureCoordinator,
        overlay: OverlayStub,
        editor: EditorStub,
        presenter: CaptureSessionPresenter
    ) {
        self.service = service
        self.clipboard = clipboard
        self.coordinator = coordinator
        self.overlay = overlay
        self.editor = editor
        self.presenter = presenter
    }

    static func make(
        hasAccess: Bool = true,
        requestResult: Bool = true
    ) -> PresenterHarness {
        let service = PresenterCaptureService()
        service.hasAccess = hasAccess
        service.requestResult = requestResult
        let clipboard = PresenterClipboardService()
        let coordinator = CaptureCoordinator(
            captureService: service,
            clipboardService: clipboard
        )
        let overlay = OverlayStub()
        let editor = EditorStub()
        let factories = CaptureSessionFactories(
            makeOverlay: { _, _, _ in overlay },
            makeEditor: { _, onFinished in
                editor.onFinished = onFinished
                return editor
            }
        )
        let presenter = CaptureSessionPresenter(
            coordinator: coordinator,
            factories: factories
        )
        let harness = PresenterHarness(
            service: service,
            clipboard: clipboard,
            coordinator: coordinator,
            overlay: overlay,
            editor: editor,
            presenter: presenter
        )
        presenter.onPermissionDenied = { harness.permissionDeniedCount += 1 }
        presenter.onCaptureFailed = { _ in harness.captureFailedCount += 1 }
        presenter.bind()
        return harness
    }
}

@MainActor
func registerCaptureSessionPresenterTests() {
    test("capture-to-selection presents one overlay") {
        let harness = PresenterHarness.make()
        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .selecting }

        try expectEqual(harness.overlay.showCount, 1)
        try expectEqual(harness.editor.showCount, 0)
        try expect(harness.presenter.overlay != nil)
    }

    test("selection-to-editor closes the overlay and opens the editor") {
        let harness = PresenterHarness.make()
        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .selecting }
        harness.coordinator.selectionCompleted(with: makeTestCGImage())

        try expectEqual(harness.coordinator.state, .annotating)
        try expectEqual(harness.overlay.closeCount, 1)
        try expectEqual(harness.editor.showCount, 1)
        try expect(harness.presenter.overlay == nil)
        try expect(harness.presenter.editor != nil)
    }

    test("cancel closes the overlay and never opens the editor") {
        let harness = PresenterHarness.make()
        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .selecting }
        harness.coordinator.cancel()

        try expectEqual(harness.coordinator.state, .idle)
        try expectEqual(harness.overlay.closeCount, 1)
        try expectEqual(harness.editor.showCount, 0)
        try expect(harness.presenter.overlay == nil)
        try expect(harness.presenter.editor == nil)
    }

    test("permission failure closes every window and reports once") {
        let harness = PresenterHarness.make(hasAccess: false, requestResult: false)
        harness.presenter.handleCaptureRequest()

        try expectEqual(harness.coordinator.state, .idle)
        try expectEqual(harness.overlay.showCount, 0)
        try expectEqual(harness.editor.showCount, 0)
        try expect(harness.presenter.overlay == nil)
        try expect(harness.presenter.editor == nil)
        try expectEqual(harness.permissionDeniedCount, 1)
    }

    test("capture failure closes every window") {
        let harness = PresenterHarness.make()
        harness.service.captureResult = .failure(ScreenCaptureError.shareableDisplayUnavailable)
        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .idle }

        try expectEqual(harness.overlay.showCount, 0)
        try expect(harness.presenter.overlay == nil)
        try expect(harness.presenter.editor == nil)
        try expectEqual(harness.captureFailedCount, 1)
    }

    test("clipboard write failure never opens the editor") {
        let harness = PresenterHarness.make()
        harness.clipboard.writeError = ClipboardError.pasteboardWriteFailed
        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .selecting }
        harness.coordinator.selectionCompleted(with: makeTestCGImage())

        try expectEqual(harness.coordinator.state, .idle)
        try expectEqual(harness.editor.showCount, 0)
        try expect(harness.presenter.overlay == nil)
        try expect(harness.presenter.editor == nil)
        try expectEqual(harness.captureFailedCount, 1)
    }

    test("finishing the editor returns to idle and drops both windows") {
        let harness = PresenterHarness.make()
        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .selecting }
        harness.coordinator.selectionCompleted(with: makeTestCGImage())
        harness.editor.finishFromUI()

        try expectEqual(harness.coordinator.state, .idle)
        try expect(harness.presenter.overlay == nil)
        try expect(harness.presenter.editor == nil)
    }

    test("a second request while selecting does not create another overlay") {
        let harness = PresenterHarness.make()
        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .selecting }
        harness.presenter.handleCaptureRequest()
        await Task.yield()

        try expectEqual(harness.service.captureCount, 1)
        try expectEqual(harness.overlay.showCount, 1)
    }

    test("repeated invocation after close presents a new overlay") {
        let harness = PresenterHarness.make()
        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .selecting }
        harness.coordinator.cancel()
        try expectEqual(harness.coordinator.state, .idle)

        harness.presenter.handleCaptureRequest()
        try await waitUntil { harness.coordinator.state == .selecting }

        try expectEqual(harness.service.captureCount, 2)
        try expectEqual(harness.overlay.showCount, 2)
    }
}
