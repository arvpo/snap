import CoreGraphics
import Foundation

struct Selection: Equatable, Sendable {
    static let minimumPointSize: CGFloat = 2

    let appKitRect: CGRect
    let pixelRect: CGRect

    var pixelWidth: Int { Int(pixelRect.width) }
    var pixelHeight: Int { Int(pixelRect.height) }

    init?(
        appKitRect: CGRect,
        displayFrame: CGRect,
        pixelSize: CGSize,
        minimumPointSize: CGFloat = Selection.minimumPointSize
    ) {
        let constrained = appKitRect.standardized.intersection(displayFrame)
        guard !constrained.isNull,
              constrained.width >= minimumPointSize,
              constrained.height >= minimumPointSize
        else {
            return nil
        }

        let pixels = ScreenGeometry.imagePixelRect(
            forAppKitRect: constrained,
            displayFrame: displayFrame,
            pixelSize: pixelSize
        )
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else {
            return nil
        }

        self.appKitRect = constrained
        self.pixelRect = pixels
    }
}

enum SelectionCropError: LocalizedError {
    case invalidRectangle
    case cropFailed
    case contextCreationFailed
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidRectangle:
            "The selected region is empty or outside the captured display."
        case .cropFailed:
            "The selected pixels could not be read from the captured display."
        case .contextCreationFailed:
            "Memory for the selected image could not be allocated."
        case .imageCreationFailed:
            "The selected image could not be created."
        }
    }
}

enum SelectionCropper {
    /// Copies selected pixels into independent, tightly sized storage.
    static func deepCopy(_ source: CGImage, pixelRect: CGRect) throws -> CGImage {
        try autoreleasepool {
            let sourceBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let cropRect = pixelRect.integral.intersection(sourceBounds)
            guard !cropRect.isNull,
                  cropRect.width >= 1,
                  cropRect.height >= 1,
                  cropRect == pixelRect.integral
            else {
                throw SelectionCropError.invalidRectangle
            }

            guard let crop = source.cropping(to: cropRect) else {
                throw SelectionCropError.cropFailed
            }
            var borrowedCrop: CGImage? = crop

            let width = Int(cropRect.width)
            let height = Int(cropRect.height)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                throw SelectionCropError.contextCreationFailed
            }

            context.interpolationQuality = .none
            context.draw(
                borrowedCrop!,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            borrowedCrop = nil

            guard let copiedImage = context.makeImage() else {
                throw SelectionCropError.imageCreationFailed
            }
            return copiedImage
        }
    }
}
