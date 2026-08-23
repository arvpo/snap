import CoreGraphics

/// Holds the cropped base image, ordered annotation values, and the active
/// tool for one annotation session. Undo stores annotation values, never
/// bitmap snapshots, so it stays cheap regardless of image size.
@MainActor
final class AnnotationDocument {
    let baseImage: CGImage
    private(set) var annotations: [AnnotationValue] = []
    var currentTool: AnnotationTool = .arrow

    init(baseImage: CGImage) {
        self.baseImage = baseImage
    }

    var isEmpty: Bool { annotations.isEmpty }

    func commit(_ value: AnnotationValue) {
        annotations.append(value)
    }

    @discardableResult
    func undo() -> Bool {
        guard !annotations.isEmpty else { return false }
        annotations.removeLast()
        return true
    }

    func removeAll() {
        annotations.removeAll()
    }
}
