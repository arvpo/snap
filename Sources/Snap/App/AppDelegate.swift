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
    private var placeholder: Phase1PlaceholderController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        coordinator.onSessionStarted = { [weak self] in
            self?.presentPlaceholder()
        }
        coordinator.onSessionEnded = { [weak self] in
            self?.dismissPlaceholder()
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

    private func presentPlaceholder() {
        guard placeholder == nil else { return }
        let controller = Phase1PlaceholderController { [weak self] in
            self?.coordinator.cancel()
        }
        controller.show(on: screenContainingPointer())
        placeholder = controller
        Logger.app.info("Capture session started (phase 1 stub)")
    }

    private func dismissPlaceholder() {
        placeholder?.close()
        placeholder = nil
        Logger.app.info("Capture session returned to idle")
    }

    private func screenContainingPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}

/// Temporary stand-in until Phase 2 shows the frozen display overlay.
@MainActor
private final class Phase1PlaceholderController {
    private var window: OverlayWindow?
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func show(on screen: NSScreen?) {
        let size = NSSize(width: 420, height: 104)
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
        window.contentView = PlaceholderView(onCancel: onCancel)

        let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
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
        window?.contentView = nil
        window = nil
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class PlaceholderView: NSView {
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 104))
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let title = makeLabel(
            "Capture started",
            font: .systemFont(ofSize: 16, weight: .semibold),
            color: .white
        )
        let subtitle = makeLabel(
            "Phase 1 stub — press Esc to dismiss",
            font: .systemFont(ofSize: 13),
            color: NSColor.white.withAlphaComponent(0.75)
        )

        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(subtitle)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
        ])
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

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        return label
    }
}

private extension Logger {
    static let app = Logger(subsystem: "com.stradeon.Snap", category: "app")
}
