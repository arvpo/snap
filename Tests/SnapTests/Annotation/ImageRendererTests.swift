import CoreGraphics
import Foundation
@testable import SnapCore

private struct TestPixel: Equatable, CustomStringConvertible {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }
}

private let white = TestPixel(red: 255, green: 255, blue: 255, alpha: 255)
private let black = TestPixel(red: 0, green: 0, blue: 0, alpha: 255)

private func solidImage(width: Int, height: Int, pixel: TestPixel) -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for _ in 0..<(width * height) {
        bytes.append(pixel.red)
        bytes.append(pixel.green)
        bytes.append(pixel.blue)
        bytes.append(pixel.alpha)
    }

    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func pixel(in image: CGImage, x: Int, y: Int) -> TestPixel {
    let data = image.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    let offset = y * image.bytesPerRow + x * 4
    return TestPixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
}

private func isRed(_ pixel: TestPixel) -> Bool {
    pixel.red > 200 && pixel.green < 80 && pixel.blue < 80
}

@MainActor
func registerImageRendererTests() {
    test("privacy block fills exactly its own top-left image-space rectangle") {
        let base = solidImage(width: 10, height: 10, pixel: white)
        let block = AnnotationValue.privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 0, y: 0, width: 4, height: 4)))

        let rendered = try ImageRenderer.render(baseImage: base, annotations: [block])

        try expectEqual(pixel(in: rendered, x: 0, y: 0), black)
        try expectEqual(pixel(in: rendered, x: 3, y: 3), black)
        try expectEqual(pixel(in: rendered, x: 4, y: 4), white)
        try expectEqual(pixel(in: rendered, x: 9, y: 9), white)
        try expectEqual(pixel(in: rendered, x: 0, y: 9), white)
    }

    test("privacy block placed near the bottom does not affect the top") {
        let base = solidImage(width: 10, height: 10, pixel: white)
        let block = AnnotationValue.privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 2, y: 6, width: 4, height: 4)))

        let rendered = try ImageRenderer.render(baseImage: base, annotations: [block])

        try expectEqual(pixel(in: rendered, x: 3, y: 7), black)
        try expectEqual(pixel(in: rendered, x: 3, y: 1), white)
        try expectEqual(pixel(in: rendered, x: 0, y: 0), white)
    }

    test("privacy block is fully opaque") {
        let base = solidImage(width: 6, height: 6, pixel: white)
        let block = AnnotationValue.privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 0, y: 0, width: 6, height: 6)))

        let rendered = try ImageRenderer.render(baseImage: base, annotations: [block])

        try expectEqual(pixel(in: rendered, x: 2, y: 2).alpha, 255)
    }

    test("rectangle outline strokes the border but leaves the interior untouched") {
        let base = solidImage(width: 20, height: 20, pixel: white)
        let rectangle = AnnotationValue.rectangle(RectangleAnnotation(rect: CGRect(x: 4, y: 4, width: 10, height: 10)))

        let rendered = try ImageRenderer.render(baseImage: base, annotations: [rectangle])

        try expect(isRed(pixel(in: rendered, x: 4, y: 9)), "expected border pixel to be red")
        try expectEqual(pixel(in: rendered, x: 9, y: 9), white)
    }

    test("known-pixel compositor output composes multiple annotations in order") {
        let base = solidImage(width: 20, height: 20, pixel: white)
        let block = AnnotationValue.privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 0, y: 0, width: 5, height: 5)))
        let rectangle = AnnotationValue.rectangle(RectangleAnnotation(rect: CGRect(x: 10, y: 10, width: 6, height: 6)))

        let rendered = try ImageRenderer.render(baseImage: base, annotations: [block, rectangle])

        try expectEqual(pixel(in: rendered, x: 2, y: 2), black)
        try expect(isRed(pixel(in: rendered, x: 10, y: 13)), "expected rectangle border pixel to be red")
        try expectEqual(pixel(in: rendered, x: 13, y: 13), white)
    }

    test("arrowhead points at the drag end, not the drag start") {
        let base = solidImage(width: 40, height: 20, pixel: white)
        let arrow = AnnotationValue.arrow(ArrowAnnotation(start: CGPoint(x: 5, y: 10), end: CGPoint(x: 35, y: 10)))

        let rendered = try ImageRenderer.render(baseImage: base, annotations: [arrow])

        try expect(isRed(pixel(in: rendered, x: 33, y: 10)), "expected the tip near the drag end to be red")
        try expect(!isRed(pixel(in: rendered, x: 33, y: 3)), "expected pixels far from the arrow to stay untouched")
        try expectEqual(pixel(in: rendered, x: 39, y: 0), white)
    }

    test("arrow shaft keeps a consistent width along its length") {
        let base = solidImage(width: 40, height: 20, pixel: white)
        let arrow = AnnotationValue.arrow(ArrowAnnotation(start: CGPoint(x: 2, y: 10), end: CGPoint(x: 30, y: 10)))

        let rendered = try ImageRenderer.render(baseImage: base, annotations: [arrow])

        try expect(isRed(pixel(in: rendered, x: 10, y: 10)), "expected the shaft centerline to be red")
        try expect(isRed(pixel(in: rendered, x: 10, y: 9)), "expected the shaft to have measurable width")
        try expect(!isRed(pixel(in: rendered, x: 10, y: 17)), "expected pixels well outside the shaft to stay untouched")
    }

    test("render throws neither for an empty annotation list nor mutates the base image") {
        let base = solidImage(width: 4, height: 4, pixel: white)
        let rendered = try ImageRenderer.render(baseImage: base, annotations: [])

        try expectEqual(pixel(in: rendered, x: 0, y: 0), white)
        try expectEqual(pixel(in: base, x: 0, y: 0), white)
    }
}
