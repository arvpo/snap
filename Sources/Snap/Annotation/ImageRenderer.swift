import CoreGraphics
import Foundation

enum ImageRenderError: LocalizedError {
    case contextCreationFailed
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            "Memory for the annotated image could not be allocated."
        case .imageCreationFailed:
            "The annotated image could not be created."
        }
    }
}

/// The single authoritative Core Graphics compositor for annotated output.
/// Used by both the clipboard render pipeline and tests, so their pixels
/// always agree. `draw(_:in:)` assumes the context it receives already
/// treats (0, 0) as the image's top-left corner with y increasing downward,
/// matching `CGImage` pixel indexing; callers are responsible for arranging
/// that before calling it.
enum ImageRenderer {
    static let arrowShaftWidth: CGFloat = 5
    static let arrowHeadLength: CGFloat = 20
    static let arrowHeadWidth: CGFloat = 16
    static let rectangleStrokeWidth: CGFloat = 4

    static let strokeColor = CGColor(red: 0.94, green: 0.11, blue: 0.15, alpha: 1)
    static let privacyColor = CGColor(gray: 0, alpha: 1)

    /// Renders the base image plus every committed annotation into one
    /// tightly sized image. Safe to call off the main thread: it touches no
    /// shared mutable state and allocates only its own local buffers.
    static func render(baseImage: CGImage, annotations: [AnnotationValue]) throws -> CGImage {
        try autoreleasepool {
            let width = baseImage.width
            let height = baseImage.height
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
                throw ImageRenderError.contextCreationFailed
            }

            context.interpolationQuality = .none
            context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            // A fresh CGContext(data:nil, ...) uses a bottom-left-origin,
            // y-up user space. Flip it here so annotation coordinates (which
            // are stored top-left-origin, y-down, matching pixel indexing)
            // land on the correct rows once read back as raw bytes.
            context.saveGState()
            context.setShouldAntialias(false)
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            for value in annotations {
                draw(value, in: context)
            }
            context.restoreGState()

            guard let image = context.makeImage() else {
                throw ImageRenderError.imageCreationFailed
            }
            return image
        }
    }

    static func draw(_ value: AnnotationValue, in context: CGContext) {
        switch value {
        case .arrow(let arrow):
            drawArrow(arrow, in: context)
        case .rectangle(let rectangle):
            drawRectangleOutline(rectangle, in: context)
        case .privacyBlock(let block):
            drawPrivacyBlock(block, in: context)
        }
    }

    private static func drawArrow(_ arrow: ArrowAnnotation, in context: CGContext) {
        let start = arrow.start
        let end = arrow.end
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return }

        let ux = dx / length
        let uy = dy / length
        let px = -uy
        let py = ux

        let headLength = min(arrowHeadLength, length * 0.6)
        let shaftEnd = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)

        context.saveGState()
        context.setStrokeColor(strokeColor)
        context.setLineWidth(arrowShaftWidth)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: shaftEnd)
        context.strokePath()

        let halfWidth = arrowHeadWidth / 2
        let leftBase = CGPoint(x: shaftEnd.x + px * halfWidth, y: shaftEnd.y + py * halfWidth)
        let rightBase = CGPoint(x: shaftEnd.x - px * halfWidth, y: shaftEnd.y - py * halfWidth)

        context.setFillColor(strokeColor)
        context.beginPath()
        context.move(to: end)
        context.addLine(to: leftBase)
        context.addLine(to: rightBase)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private static func drawRectangleOutline(_ rectangle: RectangleAnnotation, in context: CGContext) {
        let rect = rectangle.rect.standardized
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.setStrokeColor(strokeColor)
        context.setLineWidth(rectangleStrokeWidth)
        context.stroke(rect)
        context.restoreGState()
    }

    private static func drawPrivacyBlock(_ block: PrivacyBlockAnnotation, in context: CGContext) {
        let rect = block.rect.standardized
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.setFillColor(privacyColor)
        context.fill(rect)
        context.restoreGState()
    }
}
