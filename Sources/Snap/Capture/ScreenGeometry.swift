import CoreGraphics

enum ScreenGeometry {
    /// Returns a standardized, display-clipped rectangle for a drag in AppKit points.
    static func normalizedSelection(
        from start: CGPoint,
        to end: CGPoint,
        constrainedTo bounds: CGRect
    ) -> CGRect {
        let drag = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        return drag.intersection(bounds)
    }

    /// Converts an AppKit-global point into display-local points with a bottom-left origin.
    static func displayLocalPoint(_ point: CGPoint, displayFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - displayFrame.minX, y: point.y - displayFrame.minY)
    }

    /// Converts an AppKit-global selection to an integer image crop with a top-left origin.
    ///
    /// Fractional point edges expand outward so every pixel touched by the selection is included.
    static func imagePixelRect(
        forAppKitRect selection: CGRect,
        displayFrame: CGRect,
        pixelSize: CGSize
    ) -> CGRect {
        guard displayFrame.width > 0,
              displayFrame.height > 0,
              pixelSize.width > 0,
              pixelSize.height > 0
        else {
            return .null
        }

        let clipped = selection.standardized.intersection(displayFrame)
        guard !clipped.isNull, !clipped.isEmpty else { return .null }

        let scaleX = pixelSize.width / displayFrame.width
        let scaleY = pixelSize.height / displayFrame.height

        let minX = floor((clipped.minX - displayFrame.minX) * scaleX)
        let maxX = ceil((clipped.maxX - displayFrame.minX) * scaleX)
        let minY = floor((displayFrame.maxY - clipped.maxY) * scaleY)
        let maxY = ceil((displayFrame.maxY - clipped.minY) * scaleY)

        let imageBounds = CGRect(origin: .zero, size: pixelSize)
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).intersection(imageBounds)
    }
}
