import CoreGraphics
@testable import SnapCore

@MainActor
func registerScreenGeometryTests() {
    test("reverse drag is normalized and constrained") {
        let selection = ScreenGeometry.normalizedSelection(
            from: CGPoint(x: 90, y: 80),
            to: CGPoint(x: -10, y: 20),
            constrainedTo: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        try expectEqual(selection, CGRect(x: 0, y: 20, width: 90, height: 60))
    }

    test("Retina primary selection converts to top-left image pixels") {
        let pixels = ScreenGeometry.imagePixelRect(
            forAppKitRect: CGRect(x: 100, y: 200, width: 300, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            pixelSize: CGSize(width: 3_024, height: 1_964)
        )

        try expectEqual(pixels, CGRect(x: 200, y: 1_364, width: 600, height: 200))
    }

    test("non-Retina display left of primary converts independently") {
        let pixels = ScreenGeometry.imagePixelRect(
            forAppKitRect: CGRect(x: -1_820, y: 100, width: 300, height: 200),
            displayFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            pixelSize: CGSize(width: 1_920, height: 1_080)
        )

        try expectEqual(pixels, CGRect(x: 100, y: 780, width: 300, height: 200))
    }

    test("display above primary uses its own AppKit origin") {
        let pixels = ScreenGeometry.imagePixelRect(
            forAppKitRect: CGRect(x: 10, y: 1_000, width: 100, height: 50),
            displayFrame: CGRect(x: 0, y: 982, width: 1_920, height: 1_080),
            pixelSize: CGSize(width: 1_920, height: 1_080)
        )

        try expectEqual(pixels, CGRect(x: 10, y: 1_012, width: 100, height: 50))
    }

    test("out-of-bounds selection is clipped to image bounds") {
        let pixels = ScreenGeometry.imagePixelRect(
            forAppKitRect: CGRect(x: -20, y: -10, width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 50, height: 50),
            pixelSize: CGSize(width: 100, height: 100)
        )

        try expectEqual(pixels, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    test("fractional point edges expand outward to whole pixels") {
        let pixels = ScreenGeometry.imagePixelRect(
            forAppKitRect: CGRect(x: 0.25, y: 0.25, width: 1, height: 1),
            displayFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
            pixelSize: CGSize(width: 20, height: 20)
        )

        try expectEqual(pixels, CGRect(x: 0, y: 17, width: 3, height: 3))
    }

    test("display-local conversion handles negative global coordinates") {
        let local = ScreenGeometry.displayLocalPoint(
            CGPoint(x: -1_500, y: 250),
            displayFrame: CGRect(x: -1_920, y: 100, width: 1_920, height: 1_080)
        )

        try expectEqual(local, CGPoint(x: 420, y: 150))
    }
}
