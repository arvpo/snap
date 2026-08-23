import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case pointerDisplayUnavailable
    case shareableDisplayUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording access was denied."
        case .pointerDisplayUnavailable:
            "The display containing the pointer could not be resolved."
        case .shareableDisplayUnavailable:
            "The pointer's display is not available to ScreenCaptureKit."
        }
    }
}

@MainActor
protocol ScreenCaptureServicing: AnyObject {
    func hasScreenRecordingAccess() -> Bool
    func requestScreenRecordingAccess() -> Bool
    func captureDisplayAtPointer() async throws -> CapturedDisplay
}

@MainActor
final class ScreenCaptureService: ScreenCaptureServicing {
    func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func captureDisplayAtPointer() async throws -> CapturedDisplay {
        guard hasScreenRecordingAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        let pointer = NSEvent.mouseLocation
        guard let screen = Self.screen(containing: pointer),
              let displayID = Self.displayID(for: screen)
        else {
            throw ScreenCaptureError.pointerDisplayUnavailable
        }

        let frame = screen.frame
        let backingScale = screen.backingScaleFactor
        let pixelWidth = max(1, Int((frame.width * backingScale).rounded()))
        let pixelHeight = max(1, Int((frame.height * backingScale).rounded()))

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.shareableDisplayUnavailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return CapturedDisplay(
            displayID: displayID,
            appKitFrame: frame,
            backingScale: backingScale,
            image: image
        )
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
