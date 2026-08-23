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
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var snapshotPreview: Phase2SnapshotController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        coordinator.onCapturedDisplay = { [weak self] capturedDisplay in
            self?.presentSnapshot(capturedDisplay)
        }
        coordinator.onSessionEnded = { [weak self] in
            self?.dismissSnapshot()
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

    private func presentSnapshot(_ capturedDisplay: CapturedDisplay) {
        guard snapshotPreview == nil else { return }
        let controller = Phase2SnapshotController { [weak self] in
            self?.coordinator.cancel()
        }
        controller.show(capturedDisplay)
        snapshotPreview = controller
        Logger.app.info("Captured display \(capturedDisplay.displayID, privacy: .public)")
    }

    private func dismissSnapshot() {
        snapshotPreview?.close()
        snapshotPreview = nil
        Logger.app.info("Capture session returned to idle")
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

/// Temporary direct-CGImage preview until Phase 3 supplies the selection overlay.
@MainActor
private final class Phase2SnapshotController {
    private var window: OverlayWindow?
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func show(_ capturedDisplay: CapturedDisplay) {
        let maximumSize = NSSize(width: 640, height: 420)
        let aspect = capturedDisplay.appKitFrame.width / capturedDisplay.appKitFrame.height
        let size: NSSize
        if aspect >= maximumSize.width / maximumSize.height {
            size = NSSize(width: maximumSize.width, height: maximumSize.width / aspect)
        } else {
            size = NSSize(width: maximumSize.height * aspect, height: maximumSize.height)
        }
        let window = OverlayWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isReleasedWhenClosed = false
        window.contentView = SnapshotPreviewView(
            frame: NSRect(origin: .zero, size: size),
            capturedDisplay: capturedDisplay,
            onCancel: onCancel
        )

        let frame = capturedDisplay.appKitFrame
        window.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            )
        )

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window?.contentView?.layer?.contents = nil
        window?.contentView?.layer?.delegate = nil
        window?.contentView = nil
        window = nil
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SnapshotPreviewView: NSView {
    private let onCancel: () -> Void

    init(frame: NSRect, capturedDisplay: CapturedDisplay, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.contents = capturedDisplay.image
        layer?.contentsGravity = .resizeAspect
        layer?.contentsScale = capturedDisplay.backingScale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onCancel()
    }
}

private extension Logger {
    static let app = Logger(subsystem: "com.stradeon.Snap", category: "app")
}
