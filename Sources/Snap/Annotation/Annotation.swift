import CoreGraphics

enum AnnotationTool: CaseIterable, Sendable {
    case arrow
    case rectangle
    case privacyBlock
}

struct ArrowAnnotation: Equatable, Sendable {
    var start: CGPoint
    var end: CGPoint
}

struct RectangleAnnotation: Equatable, Sendable {
    var rect: CGRect
}

struct PrivacyBlockAnnotation: Equatable, Sendable {
    var rect: CGRect
}

enum AnnotationValue: Equatable, Sendable {
    case arrow(ArrowAnnotation)
    case rectangle(RectangleAnnotation)
    case privacyBlock(PrivacyBlockAnnotation)
}

/// Builds annotation values from a drag in image-space coordinates (origin
/// top-left, y increasing downward, matching `CGImage` pixel indexing).
enum AnnotationBuilder {
    static let minimumPointSize: CGFloat = 3

    /// Rectangle-shaped tools are standardized so drag direction never
    /// changes the result. The arrow keeps `start` and `end` distinct because
    /// its arrowhead must point at wherever the drag ended.
    static func makeAnnotation(
        for tool: AnnotationTool,
        from start: CGPoint,
        to end: CGPoint,
        minimumSize: CGFloat = AnnotationBuilder.minimumPointSize
    ) -> AnnotationValue? {
        switch tool {
        case .arrow:
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length >= minimumSize else { return nil }
            return .arrow(ArrowAnnotation(start: start, end: end))
        case .rectangle:
            guard let rect = standardizedRect(from: start, to: end, minimumSize: minimumSize) else {
                return nil
            }
            return .rectangle(RectangleAnnotation(rect: rect))
        case .privacyBlock:
            guard let rect = standardizedRect(from: start, to: end, minimumSize: minimumSize) else {
                return nil
            }
            return .privacyBlock(PrivacyBlockAnnotation(rect: rect))
        }
    }

    private static func standardizedRect(
        from start: CGPoint,
        to end: CGPoint,
        minimumSize: CGFloat
    ) -> CGRect? {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        guard rect.width >= minimumSize, rect.height >= minimumSize else { return nil }
        return rect
    }
}
