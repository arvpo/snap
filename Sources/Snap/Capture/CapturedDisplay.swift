import CoreGraphics

/// The immutable snapshot and geometry metadata for one physical display.
struct CapturedDisplay: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let appKitFrame: CGRect
    let backingScale: CGFloat
    let pixelSize: CGSize
    let image: CGImage

    init(
        displayID: CGDirectDisplayID,
        appKitFrame: CGRect,
        backingScale: CGFloat,
        image: CGImage
    ) {
        self.displayID = displayID
        self.appKitFrame = appKitFrame
        self.backingScale = backingScale
        self.pixelSize = CGSize(width: image.width, height: image.height)
        self.image = image
    }
}
