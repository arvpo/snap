import AppKit
import CoreGraphics
@testable import SnapCore

@MainActor
private final class LifetimeClipboardService: ClipboardServicing {
    func writePNG(_ image: CGImage) throws {}
}

@MainActor
private final class LifetimeCaptureService: ScreenCaptureServicing {
    func hasScreenRecordingAccess() -> Bool { true }
    func requestScreenRecordingAccess() -> Bool { true }
    func captureDisplayAtPointer() async throws -> CapturedDisplay {
        makeTestCapturedDisplay()
    }
}

@MainActor
func registerSessionLifetimeTests() {
    test("fifty capture/select/annotate/close cycles leave no session objects") {
        SessionLifetime.reset()
        CaptureSignposts.shared.reset()
        let service = LifetimeCaptureService()
        let clipboard = LifetimeClipboardService()
        let coordinator = CaptureCoordinator(
            captureService: service,
            clipboardService: clipboard
        )

        for _ in 0..<50 {
            coordinator.handleCaptureRequest()
            try await waitUntil { coordinator.state == .selecting }
            coordinator.selectionCompleted(with: makeTestCGImage())
            try expectEqual(coordinator.state, .annotating)
            coordinator.finish()
            try expectEqual(coordinator.state, .idle)
        }

        try expect(coordinator.capturedDisplay == nil)
        try expect(coordinator.selectedImage == nil)
        try expectEqual(SessionLifetime.count(of: .captureSession), 0)
        try expectEqual(SessionLifetime.count(of: .renderTask), 0)
    }

    test("overlay controller and view return to zero after close") {
        SessionLifetime.reset()
        weak var weakController: SelectionOverlayController?

        do {
            let controller = SelectionOverlayController(
                onSelection: { _ in },
                onCancel: {},
                onFailure: { _ in }
            )
            weakController = controller
            try expectEqual(SessionLifetime.count(of: .overlayController), 1)
            controller.show(makeTestCapturedDisplay())
            try expectEqual(SessionLifetime.count(of: .overlayView), 1)
            controller.close()
        }

        await pumpMainLoop()
        try expect(weakController == nil, "SelectionOverlayController survived close")
        try expectEqual(SessionLifetime.count(of: .overlayController), 0)
        try expectEqual(SessionLifetime.count(of: .overlayView), 0)
    }

    test("editor controller, document, and canvas return to zero after close") {
        SessionLifetime.reset()
        weak var weakController: AnnotationWindowController?

        do {
            let controller = AnnotationWindowController(
                baseImage: makeTestCGImage(),
                clipboardService: LifetimeClipboardService(),
                onFinished: {}
            )
            weakController = controller
            try expectEqual(SessionLifetime.count(of: .editorController), 1)
            try expectEqual(SessionLifetime.count(of: .document), 1)
            controller.show()
            try expectEqual(SessionLifetime.count(of: .canvasView), 1)
            controller.close()
        }

        await pumpMainLoop()
        try expect(weakController == nil, "AnnotationWindowController survived close")
        try expectEqual(SessionLifetime.count(of: .editorController), 0)
        try expectEqual(SessionLifetime.count(of: .document), 0)
        try expectEqual(SessionLifetime.count(of: .canvasView), 0)
    }

    test("render tasks return to zero after completion and invalidation") {
        SessionLifetime.reset()
        let clipboard = LifetimeClipboardService()
        let pipeline = AnnotationRenderPipeline(clipboardService: clipboard) { image, _ in image }

        let completed = pipeline.scheduleRender(baseImage: makeTestCGImage(), annotations: [])
        try expectEqual(SessionLifetime.count(of: .renderTask), 1)
        await completed.value
        try expectEqual(SessionLifetime.count(of: .renderTask), 0)

        let cancelled = pipeline.scheduleRender(baseImage: makeTestCGImage(), annotations: [])
        pipeline.invalidate()
        await cancelled.value
        try expectEqual(SessionLifetime.count(of: .renderTask), 0)
    }

    test("fifty overlay and editor open/close cycles leave lifetime counters at zero") {
        SessionLifetime.reset()
        let clipboard = LifetimeClipboardService()

        for _ in 0..<50 {
            let overlay = SelectionOverlayController(
                onSelection: { _ in },
                onCancel: {},
                onFailure: { _ in }
            )
            overlay.show(makeTestCapturedDisplay())
            overlay.close()

            let editor = AnnotationWindowController(
                baseImage: makeTestCGImage(),
                clipboardService: clipboard,
                onFinished: {}
            )
            editor.show()
            editor.close()
            await pumpMainLoop(2)
        }

        await pumpMainLoop(20)
        try expectEqual(SessionLifetime.count(of: .overlayController), 0)
        try expectEqual(SessionLifetime.count(of: .overlayView), 0)
        try expectEqual(SessionLifetime.count(of: .editorController), 0)
        try expectEqual(SessionLifetime.count(of: .document), 0)
        try expectEqual(SessionLifetime.count(of: .canvasView), 0)
        try expectEqual(SessionLifetime.count(of: .renderTask), 0)
        try expectEqual(SessionLifetime.count(of: .captureSession), 0)
    }
}
