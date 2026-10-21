import CoreGraphics
import Foundation

/// Shared image-space geometry for selection. UI affordances use a view-point
/// tolerance; no selection state or transient gesture enters the document.
enum AnnotationSelection {
    static func bounds(of value: AnnotationValue) -> CGRect? {
        switch value {
        case .text(let text): return AnnotationLayout.text(text)?.backgroundRect
        case .number(let number): return AnnotationLayout.number(number).circleRect
        default: return nil
        }
    }

    static func hitTest(_ point: CGPoint, entries: [Annotation], scale: CGFloat) -> Annotation? {
        let tolerance = 4 / max(scale, 0.001)
        return entries.reversed().first { entry in
            guard let rect = bounds(of: entry.value) else { return false }
            if case .number = entry.value {
                return hypot(point.x - rect.midX, point.y - rect.midY) <= rect.width / 2 + tolerance
            }
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func widthHandle(for value: AnnotationValue, scale: CGFloat, imageSize: CGSize) -> CGRect? {
        guard case .text = value, let rect = bounds(of: value) else { return nil }
        let side = 8 / max(scale, 0.001)
        // Keep the handle reachable even for a text box ending at the crop edge.
        let x = min(max(rect.maxX, side / 2), max(side / 2, imageSize.width - side / 2))
        let y = min(max(rect.midY, side / 2), max(side / 2, imageSize.height - side / 2))
        return CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
    }

    static func moved(_ value: AnnotationValue, by offset: CGSize, imageSize: CGSize) -> AnnotationValue {
        guard let rect = bounds(of: value) else { return value }
        func delta(_ requested: CGFloat, minEdge: CGFloat, length: CGFloat, limit: CGFloat) -> CGFloat {
            // Oversized text remains draggable across its visible extent.
            let low = min(0, limit - length) - minEdge
            let high = max(0, limit - length) - minEdge
            return min(max(requested, low), high)
        }
        return value.translated(by: CGSize(
            width: delta(offset.width, minEdge: rect.minX, length: rect.width, limit: imageSize.width),
            height: delta(offset.height, minEdge: rect.minY, length: rect.height, limit: imageSize.height)
        ))
    }

    static func resized(_ text: TextAnnotation, by delta: CGFloat, scale: CGFloat, imageSize: CGSize) -> TextAnnotation {
        guard delta != 0 else { return text }
        guard let layout = AnnotationLayout.text(text) else { return text }
        var result = text
        let padding = layout.contentRect.minX - layout.backgroundRect.minX
        let available = max(1, imageSize.width - text.origin.x - 2 * padding)
        let minimum = min(available, 12 / max(scale, 0.001))
        result.width = min(available, max(minimum, layout.contentRect.width + delta))
        return result
    }

    static func marker(at point: CGPoint, number: Int, scale: CGFloat, imageSize: CGSize) -> NumberAnnotation {
        let scale = max(scale, 0.001)
        var marker = NumberAnnotation(center: point, number: number, diameter: 28 / scale, fontSize: 18 / scale)
        let radius = AnnotationLayout.number(marker).circleRect.width / 2
        func center(_ coordinate: CGFloat, limit: CGFloat) -> CGFloat {
            guard limit >= 2 * radius else { return limit / 2 }
            return min(max(coordinate, radius), limit - radius)
        }
        marker.center = CGPoint(x: center(point.x, limit: imageSize.width), y: center(point.y, limit: imageSize.height))
        return marker
    }
}
