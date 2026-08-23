import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ClipboardError: LocalizedError {
    case encoderCreationFailed
    case encodingFailed
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .encoderCreationFailed:
            "A PNG encoder could not be created."
        case .encodingFailed:
            "The selected image could not be encoded as PNG."
        case .pasteboardWriteFailed:
            "The selected image could not be written to the clipboard."
        }
    }
}

@MainActor
protocol ClipboardServicing: AnyObject {
    func writePNG(_ image: CGImage) throws
}

/// Performs one eager write and retains no image or encoded data afterward.
@MainActor
final class ClipboardService: ClipboardServicing {
    func writePNG(_ image: CGImage) throws {
        try autoreleasepool {
            let encodedPNG = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                encodedPNG,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw ClipboardError.encoderCreationFailed
            }

            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ClipboardError.encodingFailed
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(encodedPNG as Data, forType: .png) else {
                throw ClipboardError.pasteboardWriteFailed
            }
        }
    }
}
