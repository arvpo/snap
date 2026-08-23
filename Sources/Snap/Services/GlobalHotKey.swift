import Carbon
import Foundation
import os

enum SnapHotKey {
    static let keyCode = UInt32(kVK_ANSI_X)
    static let carbonModifiers = UInt32(cmdKey | shiftKey)
    static let identifier = UInt32(1)
    static let signature = OSType(0x534E_4150) // 'SNAP'
}

/// Registers `Cmd+Shift+X` with Carbon so the shortcut works without Accessibility permission.
final class GlobalHotKey: @unchecked Sendable {
    private let callback: @MainActor @Sendable () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(callback: @escaping @MainActor @Sendable () -> Void) {
        self.callback = callback
        install()
    }

    deinit {
        unregister()
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func install() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            GlobalHotKey.eventHandler,
            1,
            &spec,
            userData,
            &installedHandler
        )
        guard handlerStatus == noErr else {
            Logger.hotKey.error("InstallEventHandler failed: \(handlerStatus, privacy: .public)")
            return
        }
        handlerRef = installedHandler

        let hotKeyID = EventHotKeyID(signature: SnapHotKey.signature, id: SnapHotKey.identifier)
        var registeredKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            SnapHotKey.keyCode,
            SnapHotKey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredKey
        )
        guard registerStatus == noErr, let registeredKey else {
            Logger.hotKey.error(
                "RegisterEventHotKey failed: \(registerStatus, privacy: .public). Another app may own Cmd+Shift+X."
            )
            return
        }
        hotKeyRef = registeredKey
    }

    private func invokeIfMatching(_ event: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return }
        guard hotKeyID.signature == SnapHotKey.signature, hotKeyID.id == SnapHotKey.identifier else {
            return
        }
        DispatchQueue.main.async { [callback] in
            callback()
        }
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }
        Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().invokeIfMatching(event)
        return noErr
    }
}

private extension Logger {
    static let hotKey = Logger(subsystem: "com.stradeon.Snap", category: "hotkey")
}
