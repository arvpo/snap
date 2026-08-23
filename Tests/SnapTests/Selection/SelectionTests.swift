import CoreGraphics
import Foundation
@testable import SnapCore

private struct TestPixel: Equatable, CustomStringConvertible {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var description: String {
        "rgba(\(red), \(green), \(blue), \(alpha))"
    }
}

private func patternedImage(width: Int, height: Int) -> CGImage {
    var bytes: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width {
            bytes.append(UInt8(x * 40 + 10))
            bytes.append(UInt8(y * 60 + 20))
            bytes.append(UInt8(x + y + 30))
            bytes.append(255)
        }
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
    return TestPixel(
        red: bytes[offset],
        green: bytes[offset + 1],
        blue: bytes[offset + 2],
        alpha: bytes[offset + 3]
    )
}

@MainActor
func registerSelectionTests() {
    test("selection constrains its AppKit and pixel rectangles") {
        let selection = Selection(
            appKitRect: CGRect(x: -10, y: 20, width: 50, height: 30),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 200, height: 200)
        )

        try expectEqual(selection?.appKitRect, CGRect(x: 0, y: 20, width: 40, height: 30))
        try expectEqual(selection?.pixelRect, CGRect(x: 0, y: 100, width: 80, height: 60))
    }

    test("selection rejects regions below the minimum size") {
        let selection = Selection(
            appKitRect: CGRect(x: 10, y: 10, width: 1, height: 20),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 200, height: 200)
        )

        try expect(selection == nil)
    }

    test("deep crop has exact dimensions and corner pixels") {
        let source = patternedImage(width: 4, height: 3)
        let crop = try SelectionCropper.deepCopy(
            source,
            pixelRect: CGRect(x: 1, y: 1, width: 2, height: 2)
        )

        try expectEqual(crop.width, 2)
        try expectEqual(crop.height, 2)
        try expectEqual(pixel(in: crop, x: 0, y: 0), pixel(in: source, x: 1, y: 1))
        try expectEqual(pixel(in: crop, x: 1, y: 0), pixel(in: source, x: 2, y: 1))
        try expectEqual(pixel(in: crop, x: 0, y: 1), pixel(in: source, x: 1, y: 2))
        try expectEqual(pixel(in: crop, x: 1, y: 1), pixel(in: source, x: 2, y: 2))
    }

    test("deep crop rejects out-of-bounds pixels") {
        let source = patternedImage(width: 4, height: 3)
        do {
            _ = try SelectionCropper.deepCopy(
                source,
                pixelRect: CGRect(x: 3, y: 2, width: 2, height: 2)
            )
            try expect(false, "out-of-bounds crop unexpectedly succeeded")
        } catch SelectionCropError.invalidRectangle {
            // Expected.
        }
    }
}
