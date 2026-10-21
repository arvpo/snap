import CoreGraphics
import Foundation

enum AnnotationTool: CaseIterable, Sendable {
    case select
    case arrow
    case rectangle
    case privacyBlock
    case text
    case number
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
    case text(TextAnnotation)
    case number(NumberAnnotation)
}

/// Identity belongs to the document entry, so replacing geometry or style
/// never changes the identity used by selection and editing.
struct Annotation: Equatable, Identifiable, Sendable {
    let id: UUID
    var value: AnnotationValue

    init(id: UUID = UUID(), value: AnnotationValue) {
        self.id = id
        self.value = value
    }
}

enum AnnotationColor: CaseIterable, Sendable {
    case red, blue, green, yellow, black, white
}

struct TextStyle: Equatable, Sendable {
    enum Presentation: Sendable { case plain, callout }

    var presentation: Presentation = .plain
    var color: AnnotationColor = .red
    /// Sizes and geometry are in image pixels. The UI converts point sizes
    /// when creating an annotation, never while exporting it.
    var fontSize: CGFloat = 18
}

struct TextAnnotation: Equatable, Sendable {
    var origin: CGPoint
    var text: String
    /// Content width, excluding callout padding; nil means natural width.
    var width: CGFloat? = nil
    var style: TextStyle = TextStyle()
}

struct NumberAnnotation: Equatable, Sendable {
    var center: CGPoint
    var number: Int = 1
    var color: AnnotationColor = .red
    var diameter: CGFloat = 28
    var fontSize: CGFloat = 18
}

extension AnnotationValue {
    func translated(by offset: CGSize) -> AnnotationValue {
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + offset.width, y: point.y + offset.height)
        }
        switch self {
        case .arrow(var arrow):
            arrow.start = move(arrow.start)
            arrow.end = move(arrow.end)
            return .arrow(arrow)
        case .rectangle(var rectangle):
            rectangle.rect = rectangle.rect.offsetBy(dx: offset.width, dy: offset.height)
            return .rectangle(rectangle)
        case .privacyBlock(var block):
            block.rect = block.rect.offsetBy(dx: offset.width, dy: offset.height)
            return .privacyBlock(block)
        case .text(var text):
            text.origin = move(text.origin)
            return .text(text)
        case .number(var number):
            number.center = move(number.center)
            return .number(number)
        }
    }
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
        case .text, .number, .select:
            // These tools have dedicated editing/placement interactions.
            return nil
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
