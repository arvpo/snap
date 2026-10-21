import CoreGraphics
import Foundation

/// A draft never mutates the document until the entire editing session commits.
struct TextEditingSession {
    let annotationID: UUID?
    var draft: TextAnnotation

    static func new(from start: CGPoint, to end: CGPoint, style: TextStyle) -> Self {
        let wraps = abs(end.x - start.x) >= AnnotationBuilder.minimumPointSize
        return Self(annotationID: nil, draft: TextAnnotation(
            origin: wraps ? CGPoint(x: min(start.x, end.x), y: min(start.y, end.y)) : start,
            text: "", width: wraps ? abs(end.x - start.x) : nil, style: style
        ))
    }

    @MainActor
    @discardableResult
    func commit(to document: AnnotationDocument) -> Bool {
        if let annotationID {
            return draft.text.isEmpty
                ? document.delete(id: annotationID)
                : document.update(id: annotationID, value: .text(draft))
        }
        guard !draft.text.isEmpty else { return false }
        document.commit(.text(draft))
        return true
    }
}
