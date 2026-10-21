import CoreGraphics
import CoreText
import Foundation
@testable import SnapCore

@MainActor
func registerAnnotationLayoutTests() {
    test("Core Text lays out multiline Unicode and renders both lines upright in measured bounds") {
        let value = TextAnnotation(origin: CGPoint(x: 20, y: 20), text: "Hello Žć\n日本語 🙂 e\u{301}")
        let layout = AnnotationLayout.text(value)!
        try expectEqual(CFArrayGetCount(CTFrameGetLines(layout.frame)), 2)
        let rendered = try ImageRenderer.render(baseImage: makeTestCGImage(width: 300, height: 150), annotations: [.text(value)])
        let bounds = paintedBounds(rendered)
        try expect(!bounds.isNull)
        try expect(layout.bounds.contains(bounds))
        let midpoint = layout.contentRect.midY
        try expect(hasPaint(rendered, in: CGRect(x: 20, y: 20, width: 250, height: midpoint - 20)))
        try expect(hasPaint(rendered, in: CGRect(x: 20, y: midpoint, width: 250, height: layout.contentRect.maxY - midpoint)))
        // Lowercase 'p' descends below 'x': a baseline check catches an
        // accidentally vertically mirrored Core Text coordinate transform.
        let p = TextAnnotation(origin: CGPoint(x: 20, y: 20), text: "p")
        let x = TextAnnotation(origin: CGPoint(x: 20, y: 20), text: "x")
        let pImage = try ImageRenderer.render(baseImage: makeTestCGImage(width: 70, height: 70), annotations: [.text(p)])
        let xImage = try ImageRenderer.render(baseImage: makeTestCGImage(width: 70, height: 70), annotations: [.text(x)])
        try expect(paintedBounds(pImage).maxY > paintedBounds(xImage).maxY)
    }

    test("wrapping width and trailing newline affect measured height without losing text") {
        let text = TextAnnotation(origin: .zero, text: "One two three four five six seven eight nine")
        let natural = AnnotationLayout.text(text)!
        var wrapped = text
        wrapped.width = 65
        let layout = AnnotationLayout.text(wrapped)!
        try expectEqual(layout.contentRect.width, 65)
        try expect(layout.contentRect.height > natural.contentRect.height)
        try expectEqual(CTFrameGetVisibleStringRange(layout.frame).length, (text.text as NSString).length)
        let newline = AnnotationLayout.text(TextAnnotation(origin: .zero, text: "Line\n"))!
        let single = AnnotationLayout.text(TextAnnotation(origin: .zero, text: "Line"))!
        try expect(newline.contentRect.height > single.contentRect.height)
    }

    test("narrow text frames retain graphemes and fallback glyphs") {
        for string in ["W", "🙂", "界", "e\u{301}"] {
            let text = TextAnnotation(origin: CGPoint(x: 10, y: 10), text: string, width: 1)
            let layout = AnnotationLayout.text(text)!
            try expectEqual(CTFrameGetVisibleStringRange(layout.frame).length, (string as NSString).length)
            let image = try ImageRenderer.render(baseImage: makeTestCGImage(width: 80, height: 80), annotations: [.text(text)])
            try expect(!paintedBounds(image).isNull)
            try expect(layout.bounds.contains(paintedBounds(image)))
        }
    }

    test("empty text has no ink and callout padding shares the measured content frame") {
        let empty = AnnotationValue.text(TextAnnotation(origin: .zero, text: ""))
        try expect(AnnotationLayout.bounds(of: empty).isNull)
        let emptyImage = try ImageRenderer.render(baseImage: makeTestCGImage(width: 50, height: 50), annotations: [empty])
        try expect(paintedBounds(emptyImage).isNull)
        let text = TextAnnotation(origin: CGPoint(x: 12, y: 15), text: "Label", width: 80,
                                  style: TextStyle(presentation: .callout, color: .yellow, fontSize: 18))
        let layout = AnnotationLayout.text(text)!
        try expectEqual(layout.backgroundRect.origin, text.origin)
        try expectEqual(layout.contentRect.minX, 20)
        try expectEqual(layout.backgroundRect.width, 96)
        let image = try ImageRenderer.render(baseImage: makeTestCGImage(width: 160, height: 100), annotations: [.text(text)])
        try expect(layout.bounds.contains(paintedBounds(image)))
        let fill = rgba(image, x: 16, y: 30)
        // Device RGB color conversion varies with the display profile.
        try expect(fill[0] > 240 && fill[1] > 190 && fill[1] < 230 && fill[2] < 60 && fill[3] == 255)
        try expect(hasDarkPixel(image, in: layout.contentRect))
    }

    test("marker circles start at 28 and expand to enclose multi-digit labels") {
        var previous: CGFloat = 0
        for number in [1, 9, 10, 99, 100, 1000, 999999] {
            let marker = NumberAnnotation(center: CGPoint(x: 100, y: 100), number: number)
            let layout = AnnotationLayout.number(marker)
            if number == 1 { try expectEqual(layout.circleRect.width, 28) }
            try expectEqual(layout.circleRect.midX, 100)
            try expectEqual(layout.circleRect.midY, 100)
            try expect(layout.circleRect.width >= previous)
            let ink = CTLineGetBoundsWithOptions(layout.line, [.useGlyphPathBounds])
            try expect(hypot(ink.width, ink.height) + 6 < layout.circleRect.width)
            let image = try ImageRenderer.render(baseImage: makeTestCGImage(width: 200, height: 200), annotations: [.number(marker)])
            try expect(layout.bounds.contains(paintedBounds(image)))
            previous = layout.circleRect.width
        }
    }

    test("all palette colors render contrasting marker and callout text") {
        for color in AnnotationColor.allCases {
            let marker = NumberAnnotation(center: CGPoint(x: 35, y: 35), number: 8, color: color)
            let image = try ImageRenderer.render(baseImage: makeTestCGImage(width: 70, height: 70), annotations: [.number(marker)])
            let center = CGRect(x: 29, y: 28, width: 12, height: 14)
            if color == .white || color == .yellow {
                try expect(hasDarkPixel(image, in: center))
            } else {
                try expect(hasLightPixel(image, in: center))
            }
            let text = TextAnnotation(origin: CGPoint(x: 10, y: 10), text: "Hi",
                                      style: TextStyle(presentation: .callout, color: color))
            let label = try ImageRenderer.render(baseImage: makeTestCGImage(width: 100, height: 100), annotations: [.text(text)])
            let content = AnnotationLayout.text(text)!.contentRect
            if color == .white || color == .yellow {
                try expect(hasDarkPixel(label, in: content))
            } else {
                try expect(hasLightPixel(label, in: content))
            }
        }
    }

    test("new annotation antialiasing leaves following shapes and privacy pixels unchanged") {
        let shapes: [AnnotationValue] = [
            .rectangle(RectangleAnnotation(rect: CGRect(x: 81.25, y: 10.25, width: 30, height: 30))),
            .privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 90.25, y: 50.25, width: 20, height: 20))),
            .arrow(ArrowAnnotation(start: CGPoint(x: 85, y: 85), end: CGPoint(x: 120, y: 100))),
        ]
        let base = makeTestCGImage(width: 140, height: 120)
        let reference = try ImageRenderer.render(baseImage: base, annotations: shapes)
        let combined = try ImageRenderer.render(baseImage: base, annotations: [
            .text(TextAnnotation(origin: CGPoint(x: 2, y: 2), text: "A")),
            .number(NumberAnnotation(center: CGPoint(x: 25, y: 70))),
        ] + shapes)
        for y in 0..<120 {
            for x in 75..<140 { try expectEqual(rgba(combined, x: x, y: y), rgba(reference, x: x, y: y)) }
        }
        try expectEqual(rgba(combined, x: 100, y: 60), [0, 0, 0, 255])
    }

    test("privacy blocks cover text and markers according to annotation ordering") {
        let base = makeTestCGImage(width: 100, height: 100)
        let block = AnnotationValue.privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let content: [AnnotationValue] = [
            .text(TextAnnotation(origin: CGPoint(x: 5, y: 5), text: "Private")),
            .number(NumberAnnotation(center: CGPoint(x: 50, y: 60))),
        ]
        let covered = try ImageRenderer.render(baseImage: base, annotations: content + [block])
        for y in 0..<100 {
            for x in 0..<100 { try expectEqual(rgba(covered, x: x, y: y), [0, 0, 0, 255]) }
        }
        let above = try ImageRenderer.render(baseImage: base, annotations: [block] + content)
        try expect(hasLightPixel(above, in: CGRect(x: 40, y: 50, width: 20, height: 20)))
    }

    test("text and marker rendering works off the main actor and clips at image edges") {
        let image = try await Task.detached {
            try ImageRenderer.render(baseImage: makeTestCGImage(width: 32, height: 24), annotations: [
                .text(TextAnnotation(origin: CGPoint(x: -10, y: -4), text: "界🙂")),
                .number(NumberAnnotation(center: CGPoint(x: 31, y: 23), number: 100)),
            ])
        }.value
        try expectEqual(image.width, 32)
        try expectEqual(image.height, 24)
        try expect(!paintedBounds(image).isNull)
    }
}

private func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let data = image.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    let offset = y * image.bytesPerRow + x * 4
    return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
}

private func paintedBounds(_ image: CGImage) -> CGRect {
    var bounds = CGRect.null
    for y in 0..<image.height {
        for x in 0..<image.width where rgba(image, x: x, y: y)[3] > 0 {
            bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return bounds
}

private func containsPixel(_ image: CGImage, in rect: CGRect, matching predicate: ([UInt8]) -> Bool) -> Bool {
    for y in max(0, Int(floor(rect.minY)))..<min(image.height, Int(ceil(rect.maxY))) {
        for x in max(0, Int(floor(rect.minX)))..<min(image.width, Int(ceil(rect.maxX))) {
            if predicate(rgba(image, x: x, y: y)) { return true }
        }
    }
    return false
}

private func hasPaint(_ image: CGImage, in rect: CGRect) -> Bool {
    containsPixel(image, in: rect) { $0[3] > 0 }
}

private func hasDarkPixel(_ image: CGImage, in rect: CGRect) -> Bool {
    containsPixel(image, in: rect) { $0[0] < 50 && $0[1] < 50 && $0[2] < 50 && $0[3] > 240 }
}

private func hasLightPixel(_ image: CGImage, in rect: CGRect) -> Bool {
    containsPixel(image, in: rect) { $0[0] > 240 && $0[1] > 240 && $0[2] > 240 && $0[3] > 240 }
}
