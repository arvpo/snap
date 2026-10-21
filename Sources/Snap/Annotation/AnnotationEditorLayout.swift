import CoreGraphics

/// Editor chrome is measured in display points; the canvas keeps the image's
/// aspect ratio and never enlarges a small crop to make room for controls.
struct AnnotationEditorLayout {
    static let toolbarSize = CGSize(width: 362, height: 48)
    static let margin: CGFloat = 16
    static let chromeHeight: CGFloat = 80
    static let minimumImageAreaHeight: CGFloat = 120

    let windowFrame: CGRect
    let canvasFrame: CGRect
    let toolbarFrame: CGRect

    init(imagePixelSize: CGSize, visibleFrame: CGRect, backingScale: CGFloat) {
        let native = CGSize(width: imagePixelSize.width / max(1, backingScale),
                            height: imagePixelSize.height / max(1, backingScale))
        let maxWidth = max(1, visibleFrame.width * 0.85 - 2 * Self.margin)
        let maxHeight = max(1, visibleFrame.height * 0.85 - Self.chromeHeight - Self.margin)
        let scale = min(1, min(maxWidth / max(1, native.width), maxHeight / max(1, native.height)))
        // Use one scale for both axes, including odd-sized Retina crops.
        let imageSize = CGSize(width: native.width * scale, height: native.height * scale)
        let width = max(Self.toolbarSize.width, imageSize.width) + 2 * Self.margin
        let imageAreaHeight = max(Self.minimumImageAreaHeight, imageSize.height)
        let height = imageAreaHeight + Self.chromeHeight + Self.margin
        windowFrame = CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
                             width: width, height: height)
        canvasFrame = CGRect(x: (width - imageSize.width) / 2,
                             y: Self.margin + (imageAreaHeight - imageSize.height) / 2,
                             width: imageSize.width, height: imageSize.height)
        toolbarFrame = CGRect(x: (width - Self.toolbarSize.width) / 2,
                              y: height - Self.margin - Self.toolbarSize.height,
                              width: Self.toolbarSize.width, height: Self.toolbarSize.height)
    }
}
