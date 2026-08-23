import AppKit
import os

public enum SnapApp {
    public static func run() {
        MainActor.assumeIsolated {
            let appDelegate = AppDelegate()
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.delegate = appDelegate
            withExtendedLifetime(appDelegate) {
                application.run()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = CaptureCoordinator()
    private let clipboardService = ClipboardService()
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var selectionOverlay: SelectionOverlayController?
    private var annotationEditor: AnnotationWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        coordinator.onCapturedDisplay = { [weak self] capturedDisplay in
            self?.presentSelectionOverlay(capturedDisplay)
        }
        coordinator.onSelectionCompleted = { [weak self] image in
            Logger.app.info("Copied \(image.width, privacy: .public) × \(image.height, privacy: .public) selection")
            self?.presentAnnotationEditor(for: image)
        }
        coordinator.onSessionEnded = { [weak self] in
            self?.dismissSelectionOverlay()
            self?.dismissAnnotationEditor()
        }
        coordinator.onPermissionDenied = { [weak self] in
            self?.showScreenRecordingAccessAlert()
        }
        coordinator.onCaptureFailed = { [weak self] error in
            self?.showCaptureFailedAlert(error)
        }

        installStatusItem()
        hotKey = GlobalHotKey { [weak self] in
            self?.coordinator.handleCaptureRequest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        hotKey = nil
        coordinator.cancel()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snap")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Snap"
            if button.image == nil {
                button.title = "Snap"
            }
        }

        let menu = NSMenu()
        let captureItem = NSMenuItem(
            title: "Capture",
            action: #selector(captureFromMenu(_:)),
            keyEquivalent: "x"
        )
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Snap",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        item.menu = menu
        statusItem = item
    }

    @objc
    private func captureFromMenu(_ sender: Any?) {
        coordinator.handleCaptureRequest()
    }

    private func presentSelectionOverlay(_ capturedDisplay: CapturedDisplay) {
        guard selectionOverlay == nil else { return }
        let controller = SelectionOverlayController(
            onSelection: { [weak self] image in
                self?.coordinator.selectionCompleted(with: image)
            },
            onCancel: { [weak self] in
                self?.coordinator.cancel()
            },
            onFailure: { [weak self] error in
                self?.showCaptureFailedAlert(error)
                self?.coordinator.cancel()
            }
        )
        controller.show(capturedDisplay)
        selectionOverlay = controller
        Logger.app.info("Captured display \(capturedDisplay.displayID, privacy: .public)")
    }

    private func dismissSelectionOverlay() {
        selectionOverlay?.close()
        selectionOverlay = nil
        Logger.app.info("Capture session returned to idle")
    }

    private func presentAnnotationEditor(for image: CGImage) {
        guard annotationEditor == nil else { return }
        let controller = AnnotationWindowController(
            baseImage: image,
            clipboardService: clipboardService,
            onFinished: { [weak self] in
                self?.annotationEditor = nil
                self?.coordinator.finish()
            }
        )
        annotationEditor = controller
        controller.show()
    }

    private func dismissAnnotationEditor() {
        annotationEditor?.close()
        annotationEditor = nil
    }

    private func showScreenRecordingAccessAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording access is required"
        alert.informativeText = """
        Open System Settings → Privacy & Security → Screen Recording, enable Snap, then capture again.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCaptureFailedAlert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snap could not capture the display"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private extension Logger {
    static let app = Logger(subsystem: "com.stradeon.Snap", category: "app")
}
