import CoreGraphics
@testable import SnapCore

@MainActor
func registerAnnotationBuilderTests() {
    test("reverse drag standardizes a rectangle the same as a forward drag") {
        let forward = AnnotationBuilder.makeAnnotation(
            for: .rectangle,
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 40, y: 30)
        )
        let reverse = AnnotationBuilder.makeAnnotation(
            for: .rectangle,
            from: CGPoint(x: 40, y: 30),
            to: CGPoint(x: 10, y: 10)
        )

        try expectEqual(forward, .rectangle(RectangleAnnotation(rect: CGRect(x: 10, y: 10, width: 30, height: 20))))
        try expectEqual(forward, reverse)
    }

    test("reverse drag standardizes a privacy block the same as a forward drag") {
        let forward = AnnotationBuilder.makeAnnotation(
            for: .privacyBlock,
            from: CGPoint(x: 5, y: 50),
            to: CGPoint(x: 25, y: 20)
        )
        let reverse = AnnotationBuilder.makeAnnotation(
            for: .privacyBlock,
            from: CGPoint(x: 25, y: 20),
            to: CGPoint(x: 5, y: 50)
        )

        try expectEqual(forward, reverse)
        try expectEqual(forward, .privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 5, y: 20, width: 20, height: 30))))
    }

    test("reverse arrow drag keeps direction, unlike rectangle tools") {
        let value = AnnotationBuilder.makeAnnotation(
            for: .arrow,
            from: CGPoint(x: 50, y: 50),
            to: CGPoint(x: 10, y: 10)
        )

        try expectEqual(value, .arrow(ArrowAnnotation(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 10, y: 10))))
    }

    test("rectangle below minimum size is rejected") {
        let value = AnnotationBuilder.makeAnnotation(
            for: .rectangle,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 1, y: 1)
        )
        try expect(value == nil)
    }

    test("arrow below minimum size is rejected") {
        let value = AnnotationBuilder.makeAnnotation(
            for: .arrow,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 1, y: 0)
        )
        try expect(value == nil)
    }

    test("a zero minimum size still allows a live preview of a tiny drag") {
        let value = AnnotationBuilder.makeAnnotation(
            for: .rectangle,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 1, y: 1),
            minimumSize: 0
        )
        try expect(value != nil)
    }
}
