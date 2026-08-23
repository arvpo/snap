import AppKit
import QuartzCore

@MainActor
final class SelectionOverlayView: NSView {
    var onSelection: ((Selection) -> Void)?
    var onCancel: (() -> Void)?

    private let displayFrame: CGRect
    private let pixelSize: CGSize
    private let backingScale: CGFloat
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let dimensionsBackgroundLayer = CALayer()
    private let dimensionsLayer = CATextLayer()
    private var dragStart: CGPoint?

    init(frame: CGRect, capturedDisplay: CapturedDisplay) {
        self.displayFrame = capturedDisplay.appKitFrame
        self.pixelSize = capturedDisplay.pixelSize
        self.backingScale = capturedDisplay.backingScale
        super.init(frame: frame)

        wantsLayer = true
        guard let layer else { return }
        layer.contents = capturedDisplay.image
        layer.contentsGravity = .resize
        layer.contentsScale = capturedDisplay.backingScale
        layer.masksToBounds = true

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.48).cgColor
        dimLayer.fillRule = .evenOdd
        dimLayer.contentsScale = backingScale
        layer.addSublayer(dimLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.systemRed.cgColor
        borderLayer.lineWidth = 1 / backingScale
        borderLayer.contentsScale = backingScale
        layer.addSublayer(borderLayer)

        dimensionsBackgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        dimensionsBackgroundLayer.cornerRadius = 4
        dimensionsBackgroundLayer.isHidden = true
        layer.addSublayer(dimensionsBackgroundLayer)

        dimensionsLayer.alignmentMode = .center
        dimensionsLayer.foregroundColor = NSColor.white.cgColor
        dimensionsLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        dimensionsLayer.fontSize = 12
        dimensionsLayer.contentsScale = backingScale
        dimensionsLayer.isHidden = true
        layer.addSublayer(dimensionsLayer)
        SessionLifetime.retain(.overlayView)
    }

    deinit {
        SessionLifetime.release(.overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        updateLayers(for: currentSelectionRect)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = constrainedPoint(from: event)
        updateLayers(for: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let rect = ScreenGeometry.normalizedSelection(
            from: dragStart,
            to: constrainedPoint(from: event),
            constrainedTo: bounds
        )
        updateLayers(for: rect)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return }
        let localRect = ScreenGeometry.normalizedSelection(
            from: dragStart,
            to: constrainedPoint(from: event),
            constrainedTo: bounds
        )
        self.dragStart = nil

        let globalRect = localRect.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
        guard let selection = Selection(
            appKitRect: globalRect,
            displayFrame: displayFrame,
            pixelSize: pixelSize
        ) else {
            updateLayers(for: .zero)
            return
        }
        onSelection?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    func releaseCapturedImage() {
        dragStart = nil
        onSelection = nil
        onCancel = nil
        layer?.contents = nil
        dimLayer.path = nil
        borderLayer.path = nil
        dimensionsLayer.string = nil
        dimensionsLayer.isHidden = true
        dimensionsBackgroundLayer.isHidden = true
    }

    private var currentSelectionRect: CGRect {
        borderLayer.path?.boundingBoxOfPath ?? .zero
    }

    private func constrainedPoint(from event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func updateLayers(for selectionRect: CGRect) {
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if !selectionRect.isEmpty {
            dimPath.addRect(selectionRect)
        }
        dimLayer.path = dimPath
        borderLayer.path = selectionRect.isEmpty
            ? nil
            : CGPath(rect: selectionRect, transform: nil)

        let globalRect = selectionRect.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
        guard !selectionRect.isEmpty,
              let selection = Selection(
                  appKitRect: globalRect,
                  displayFrame: displayFrame,
                  pixelSize: pixelSize,
                  minimumPointSize: 0
              )
        else {
            dimensionsLayer.string = nil
            dimensionsLayer.isHidden = true
            dimensionsBackgroundLayer.isHidden = true
            return
        }

        let label = "\(selection.pixelWidth) × \(selection.pixelHeight)"
        dimensionsLayer.string = label
        let labelSize = NSSize(
            width: max(82, CGFloat(label.count) * 8 + 16),
            height: 24
        )
        let origin = labelOrigin(size: labelSize, selectionRect: selectionRect)
        dimensionsBackgroundLayer.frame = CGRect(origin: origin, size: labelSize)
        dimensionsLayer.frame = CGRect(
            x: origin.x,
            y: origin.y + 4,
            width: labelSize.width,
            height: 16
        )
        dimensionsBackgroundLayer.isHidden = false
        dimensionsLayer.isHidden = false
    }

    private func labelOrigin(size: CGSize, selectionRect: CGRect) -> CGPoint {
        let preferredBelow = selectionRect.minY - size.height - 8
        let y = preferredBelow >= bounds.minY
            ? preferredBelow
            : min(selectionRect.maxY + 8, bounds.maxY - size.height)
        let x = min(
            max(selectionRect.midX - size.width / 2, bounds.minX + 4),
            bounds.maxX - size.width - 4
        )
        return CGPoint(x: x, y: y)
    }
}
