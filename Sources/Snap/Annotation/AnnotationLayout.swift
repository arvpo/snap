import CoreGraphics
import CoreText
import Foundation

extension AnnotationColor {
    var cgColor: CGColor {
        switch self {
        case .red: ImageRenderer.strokeColor
        case .blue: CGColor(red: 0.08, green: 0.32, blue: 0.85, alpha: 1)
        case .green: CGColor(red: 0.08, green: 0.48, blue: 0.22, alpha: 1)
        case .yellow: CGColor(red: 1, green: 0.83, blue: 0.12, alpha: 1)
        case .black: CGColor(gray: 0, alpha: 1)
        case .white: CGColor(gray: 1, alpha: 1)
        }
    }

    var contrastingColor: CGColor {
        switch self {
        case .yellow, .white: CGColor(gray: 0, alpha: 1)
        default: CGColor(gray: 1, alpha: 1)
        }
    }
}

/// Ephemeral Core Text objects are shared by measurement and drawing, never
/// stored in the document or undo history. All rectangles use top-left image
/// coordinates. Bounds include glyph overhang, outlines, and marker shadows.
enum AnnotationLayout {
    struct Text {
        let frame: CTFrame
        let contentRect: CGRect
        let backgroundRect: CGRect
        let bounds: CGRect
    }

    struct Number {
        let line: CTLine
        let circleRect: CGRect
        let baseline: CGPoint
        let bounds: CGRect
    }

    static func text(_ annotation: TextAnnotation) -> Text? {
        guard !annotation.text.isEmpty else { return nil }
        let fontSize = positive(annotation.style.fontSize, fallback: 18)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
        let color = annotation.style.presentation == .plain
            ? annotation.style.color.cgColor : annotation.style.color.contrastingColor
        // Core Text omits an empty final paragraph from suggested heights.
        // A zero-width character reserves its line without drawing a glyph.
        let string = annotation.text.hasSuffix("\n") ? annotation.text + "\u{200B}" : annotation.text
        let attributed = attributedString(string, font: font, color: color)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let width = annotation.width.map { positive($0, fallback: 1) }
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width ?? 1_000_000, height: .greatestFiniteMagnitude), nil
        )
        let size = CGSize(width: width ?? max(1, ceil(suggested.width)),
                          height: max(ceil(fontSize), ceil(suggested.height)))
        let padding: CGFloat = annotation.style.presentation == .callout ? fontSize * 4 / 9 : 0
        let content = CGRect(x: annotation.origin.x + padding, y: annotation.origin.y + padding,
                             width: size.width, height: size.height)
        let background = CGRect(origin: annotation.origin,
                                size: CGSize(width: size.width + 2 * padding, height: size.height + 2 * padding))
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var bounds = background
        for (index, line) in lines.enumerated() {
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            if !ink.isNull {
                let rect = CGRect(x: content.minX + origins[index].x + ink.minX,
                                  y: content.maxY - origins[index].y - ink.maxY,
                                  width: ink.width, height: ink.height)
                bounds = bounds.union(rect)
            }
        }
        return Text(frame: frame, contentRect: content, backgroundRect: background,
                    bounds: bounds.insetBy(dx: -1, dy: -1))
    }

    static func number(_ annotation: NumberAnnotation) -> Number {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem,
                                                positive(annotation.fontSize, fallback: 18), nil)!
        let line = CTLineCreateWithAttributedString(attributedString(
            String(max(1, annotation.number)), font: font, color: annotation.color.contrastingColor
        ))
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        // Leave padding even at the corners of a long number inside a circle.
        let diameter = max(positive(annotation.diameter, fallback: 28),
                           ceil(hypot(ink.width, ink.height) + 8))
        let circle = CGRect(x: annotation.center.x - diameter / 2,
                            y: annotation.center.y - diameter / 2, width: diameter, height: diameter)
        return Number(line: line, circleRect: circle,
                      baseline: CGPoint(x: annotation.center.x - ink.midX,
                                        y: annotation.center.y + ink.midY),
                      bounds: circle.insetBy(dx: -6, dy: -6))
    }

    static func bounds(of value: AnnotationValue) -> CGRect {
        switch value {
        case .text(let annotation): return text(annotation)?.bounds ?? .null
        case .number(let annotation): return number(annotation).bounds
        case .privacyBlock(let annotation): return annotation.rect.standardized
        case .rectangle(let annotation):
            return annotation.rect.standardized.insetBy(dx: -ImageRenderer.rectangleStrokeWidth / 2,
                                                       dy: -ImageRenderer.rectangleStrokeWidth / 2)
        case .arrow(let annotation):
            let margin = max(ImageRenderer.arrowHeadWidth / 2, ImageRenderer.arrowShaftWidth / 2)
            return CGRect(x: min(annotation.start.x, annotation.end.x),
                          y: min(annotation.start.y, annotation.end.y),
                          width: abs(annotation.end.x - annotation.start.x),
                          height: abs(annotation.end.y - annotation.start.y)).insetBy(dx: -margin, dy: -margin)
        }
    }

    private static func positive(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : fallback
    }

    private static func attributedString(_ string: String, font: CTFont, color: CGColor) -> CFAttributedString {
        NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]) as CFAttributedString
    }
}
