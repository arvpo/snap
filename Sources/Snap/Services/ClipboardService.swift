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
    func publishPNG(_ data: Data) throws
}

/// ImageIO work runs on the render worker, never on the UI actor.
enum PNGEncoder {
    static func encode(_ image: CGImage) throws -> Data {
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

            return encodedPNG as Data
        }
    }
}

/// Only the eager pasteboard publication touches AppKit. No retained payload.
@MainActor
final class ClipboardService: ClipboardServicing {
    func publishPNG(_ data: Data) throws {
        try autoreleasepool {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else {
                throw ClipboardError.pasteboardWriteFailed
            }
        }
    }
}
