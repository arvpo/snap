import CoreGraphics

@MainActor
protocol OverlaySession: AnyObject {
    func show(_ capturedDisplay: CapturedDisplay)
    func close()
}

@MainActor
protocol EditorSession: AnyObject {
    func show()
    func close()
}

extension SelectionOverlayController: OverlaySession {}
extension AnnotationWindowController: EditorSession {}

@MainActor
struct CaptureSessionFactories {
    var makeOverlay: (
        _ onSelection: @escaping (CGImage) -> Void,
        _ onCancel: @escaping () -> Void,
        _ onFailure: @escaping (Error) -> Void
    ) -> OverlaySession

    var makeEditor: (
        _ image: CGImage,
        _ onFinished: @escaping () -> Void
    ) -> EditorSession

    static func live(clipboardService: ClipboardServicing) -> CaptureSessionFactories {
        CaptureSessionFactories(
            makeOverlay: { onSelection, onCancel, onFailure in
                SelectionOverlayController(
                    onSelection: onSelection,
                    onCancel: onCancel,
                    onFailure: onFailure
                )
            },
            makeEditor: { image, onFinished in
                AnnotationWindowController(
                    baseImage: image,
                    clipboardService: clipboardService,
                    onFinished: onFinished
                )
            }
        )
    }
}

/// Owns the overlay and editor for one coordinator. AppDelegate talks to
/// this instead of creating windows itself, so cancel and failure paths
/// can be tested without AppKit.
@MainActor
final class CaptureSessionPresenter {
    private let coordinator: CaptureCoordinator
    private let factories: CaptureSessionFactories

    private(set) var overlay: OverlaySession?
    private(set) var editor: EditorSession?

    var onPermissionDenied: (() -> Void)?
    var onCaptureFailed: ((Error) -> Void)?

    init(coordinator: CaptureCoordinator, factories: CaptureSessionFactories) {
        self.coordinator = coordinator
        self.factories = factories
    }

    func bind() {
        coordinator.onCapturedDisplay = { [weak self] capturedDisplay in
            self?.presentOverlay(capturedDisplay)
        }
        coordinator.onSelectionCompleted = { [weak self] image in
            self?.presentEditor(image)
        }
        coordinator.onSessionEnded = { [weak self] in
            self?.dismissAll()
        }
        coordinator.onPermissionDenied = { [weak self] in
            self?.dismissAll()
            self?.onPermissionDenied?()
        }
        coordinator.onCaptureFailed = { [weak self] error in
            self?.dismissAll()
            self?.onCaptureFailed?(error)
        }
    }

    func handleCaptureRequest() {
        coordinator.handleCaptureRequest()
    }

    func dismissAll() {
        dismissOverlay()
        dismissEditor()
    }

    private func presentOverlay(_ capturedDisplay: CapturedDisplay) {
        guard overlay == nil else { return }
        let controller = factories.makeOverlay(
            { [weak self] image in
                self?.coordinator.selectionCompleted(with: image)
            },
            { [weak self] in
                self?.coordinator.cancel()
            },
            { [weak self] error in
                self?.onCaptureFailed?(error)
                self?.coordinator.cancel()
            }
        )
        overlay = controller
        controller.show(capturedDisplay)
        CaptureSignposts.shared.end(.snapshotToOverlay)
    }

    private func presentEditor(_ image: CGImage) {
        dismissOverlay()
        guard editor == nil else { return }
        let controller = factories.makeEditor(image) { [weak self] in
            self?.editor = nil
            self?.coordinator.finish()
        }
        editor = controller
        controller.show()
    }

    private func dismissOverlay() {
        overlay?.close()
        overlay = nil
    }

    private func dismissEditor() {
        editor?.close()
        editor = nil
    }
}
