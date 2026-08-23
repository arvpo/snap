import AppKit

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
    private let clipboardService = ClipboardService()
    private lazy var coordinator = CaptureCoordinator(clipboardService: clipboardService)
    private var presenter: CaptureSessionPresenter?
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let presenter = CaptureSessionPresenter(
            coordinator: coordinator,
            factories: .live(clipboardService: clipboardService)
        )
        presenter.onPermissionDenied = { [weak self] in
            self?.showScreenRecordingAccessAlert()
        }
        presenter.onCaptureFailed = { [weak self] error in
            self?.showCaptureFailedAlert(error)
        }
        presenter.bind()
        self.presenter = presenter

        installStatusItem()
        hotKey = GlobalHotKey { [weak self] in
            self?.presenter?.handleCaptureRequest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        hotKey = nil
        presenter?.dismissAll()
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
        presenter?.handleCaptureRequest()
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
