import AppKit

/// A nonmodal error panel keeps the event loop responsive and can be dismissed
/// during cancellation. Both actions release the panel before running callbacks.
@MainActor
final class ClipboardFailureController: NSObject {
    private var panel: NSPanel?
    private var retry: (() -> Void)?
    private var dismiss: (() -> Void)?

    func show(_ error: Error, retry: @escaping () -> Void, close: @escaping () -> Void) {
        self.close()
        self.retry = retry
        self.dismiss = close
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 180),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Snap could not update the clipboard"
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let message = NSTextField(wrappingLabelWithString: error.localizedDescription)
        message.frame = CGRect(x: 20, y: 65, width: 360, height: 95)
        panel.contentView?.addSubview(message)
        let retryButton = NSButton(title: "Retry", target: self, action: #selector(retryClicked))
        retryButton.frame = CGRect(x: 290, y: 20, width: 90, height: 32)
        retryButton.bezelStyle = .rounded
        retryButton.keyEquivalent = "\r"
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.frame = CGRect(x: 190, y: 20, width: 90, height: 32)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        panel.contentView?.addSubview(closeButton)
        panel.contentView?.addSubview(retryButton)
        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        retry = nil
        dismiss = nil
    }

    @objc private func retryClicked() {
        let callback = retry
        close()
        callback?()
    }

    @objc private func closeClicked() {
        let callback = dismiss
        close()
        callback?()
    }
}
