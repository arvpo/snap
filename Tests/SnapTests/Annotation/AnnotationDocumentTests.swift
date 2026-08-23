import CoreGraphics
import Foundation
@testable import SnapCore

private func testImage(width: Int = 4, height: Int = 4) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

@MainActor
func registerAnnotationDocumentTests() {
    test("new document starts empty with the arrow tool") {
        let document = AnnotationDocument(baseImage: testImage())
        try expect(document.isEmpty)
        try expectEqual(document.annotations.count, 0)
        try expect(document.currentTool == .arrow)
    }

    test("commits preserve annotation ordering") {
        let document = AnnotationDocument(baseImage: testImage())
        let first = AnnotationValue.rectangle(RectangleAnnotation(rect: CGRect(x: 0, y: 0, width: 5, height: 5)))
        let second = AnnotationValue.arrow(ArrowAnnotation(start: .zero, end: CGPoint(x: 5, y: 5)))
        let third = AnnotationValue.privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 1, y: 1, width: 2, height: 2)))

        document.commit(first)
        document.commit(second)
        document.commit(third)

        try expectEqual(document.annotations, [first, second, third])
    }

    test("undo removes only the most recent annotation") {
        let document = AnnotationDocument(baseImage: testImage())
        let first = AnnotationValue.arrow(ArrowAnnotation(start: .zero, end: CGPoint(x: 1, y: 1)))
        let second = AnnotationValue.arrow(ArrowAnnotation(start: .zero, end: CGPoint(x: 2, y: 2)))
        document.commit(first)
        document.commit(second)

        let didUndo = document.undo()

        try expect(didUndo)
        try expectEqual(document.annotations, [first])
    }

    test("undo on an empty document reports no change") {
        let document = AnnotationDocument(baseImage: testImage())
        try expect(document.undo() == false)
        try expect(document.isEmpty)
    }

    test("removeAll empties the annotation list") {
        let document = AnnotationDocument(baseImage: testImage())
        document.commit(.arrow(ArrowAnnotation(start: .zero, end: CGPoint(x: 1, y: 1))))
        document.removeAll()
        try expect(document.isEmpty)
    }
}
