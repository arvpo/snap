import CoreGraphics
import Foundation
@testable import SnapCore

@MainActor
func registerAnnotationEditingTests() {
    test("insertions preserve z-order and give equal values distinct stable identities") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        let value = AnnotationValue.text(TextAnnotation(origin: .zero, text: "Same"))
        let first = document.commit(value)
        let last = document.commit(value)
        let middle = Annotation(value: .number(NumberAnnotation(center: .zero)))
        try expect(document.apply([.insert(middle, at: 1)]))
        try expect(first != last)
        try expectEqual(document.entries.map(\.id), [first, middle.id, last])
        try expect(document.undo())
        try expectEqual(document.entries.map(\.id), [first, last])
    }

    test("editing content style and width preserves identity and undoes in one step") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        let original = AnnotationValue.text(TextAnnotation(origin: CGPoint(x: 3, y: 7), text: "First"))
        let id = document.commit(original)
        let changed = AnnotationValue.text(TextAnnotation(origin: CGPoint(x: 3, y: 7), text: "第二行\n🙂",
            width: 90, style: TextStyle(presentation: .callout, color: .blue, fontSize: 24)))
        try expect(document.update(id: id, value: changed))
        try expectEqual(document.entries, [Annotation(id: id, value: changed)])
        try expect(document.undo())
        try expectEqual(document.entries, [Annotation(id: id, value: original)])
        try expect(document.undo())
        try expect(document.isEmpty)
        try expect(!document.canUndo)
    }

    test("one gesture batch moves and edits with one undo operation") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        let id = document.commit(.text(TextAnnotation(origin: CGPoint(x: 10, y: 10), text: "Before")))
        let original = document.entries
        try expect(document.apply([
            .update(id, .text(TextAnnotation(origin: CGPoint(x: 10, y: 10), text: "After"))),
            .move(id, by: CGSize(width: 4, height: 8)),
            .move(id, by: CGSize(width: 3, height: -2)),
        ]))
        try expectEqual(document.annotations, [.text(TextAnnotation(origin: CGPoint(x: 17, y: 16), text: "After"))])
        try expect(document.undo())
        try expectEqual(document.entries, original)
    }

    test("marker deletion renumbers across shapes and undo restores all identities and numbers") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        var ids: [UUID] = []
        for number in 1...12 {
            ids.append(document.commit(.number(NumberAnnotation(center: CGPoint(x: number, y: 10), number: 99))))
            if number == 5 {
                document.commit(.privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: 0, y: 0, width: 2, height: 2))))
            }
        }
        let original = document.entries
        try expectEqual(markerNumbers(document), Array(1...12))
        try expect(document.delete(id: ids[8]))
        try expectEqual(markerNumbers(document), Array(1...11))
        try expect(document.annotation(id: ids[8]) == nil)
        try expect(document.annotation(id: ids[9])?.id == ids[9])
        try expect(document.undo())
        try expectEqual(document.entries, original)
    }

    test("moving markers preserves numbering and deletion of the last item remains undoable") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        let first = document.commit(.number(NumberAnnotation(center: CGPoint(x: 10, y: 10))))
        document.commit(.number(NumberAnnotation(center: CGPoint(x: 20, y: 20))))
        try expect(document.move(id: first, by: CGSize(width: 100, height: -10)))
        try expectEqual(markerNumbers(document), [1, 2])
        try expectEqual(document.annotations.first, .number(NumberAnnotation(center: CGPoint(x: 110, y: 0))))
        try expect(document.undo())
        try expect(document.undo())
        try expect(document.delete(id: first))
        try expect(document.isEmpty && document.canUndo)
        try expect(document.undo())
        try expectEqual(document.entries.map(\.id), [first])
    }

    test("mixed transaction undo restores exact ordering after deletes updates and insertions") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        for index in 0..<8 {
            document.commit(.text(TextAnnotation(origin: .zero, text: String(index))))
        }
        let original = document.entries
        try expect(document.apply([
            .delete(original[1].id), .delete(original[5].id),
            .move(original[3].id, by: CGSize(width: 7, height: 4)),
            .insert(Annotation(value: .number(NumberAnnotation(center: .zero))), at: 2),
            .delete(original[7].id), .insert(original[7], at: 0),
        ]))
        try expect(document.undo())
        try expectEqual(document.entries, original)
    }

    test("invalid transactions are atomic and no-op edits leave undo unchanged") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        let id = document.commit(.text(TextAnnotation(origin: .zero, text: "Keep")))
        let original = document.entries
        try expect(!document.apply([.move(id, by: CGSize(width: 3, height: 4)), .delete(UUID())]))
        try expect(!document.apply([.insert(original[0])]))
        try expect(!document.apply([.insert(Annotation(value: original[0].value), at: 20)]))
        try expect(!document.move(id: id, by: .zero))
        try expect(!document.update(id: id, value: original[0].value))
        try expect(!document.apply([]))
        try expectEqual(document.entries, original)
        try expect(document.undo())
        try expect(document.isEmpty && !document.canUndo)
    }

    test("teardown clears deleted values and undo history and a fresh session starts at one") {
        let document = AnnotationDocument(baseImage: makeTestCGImage())
        let id = document.commit(.number(NumberAnnotation(center: .zero)))
        document.delete(id: id)
        document.removeAll()
        try expect(!document.canUndo && !document.undo())
        document.commit(.number(NumberAnnotation(center: .zero, number: 45)))
        try expectEqual(markerNumbers(document), [1])
        try expectEqual(TextStyle(), TextStyle(presentation: .plain, color: .red, fontSize: 18))
    }
}

@MainActor
private func markerNumbers(_ document: AnnotationDocument) -> [Int] {
    document.annotations.compactMap {
        if case .number(let marker) = $0 { return marker.number }
        return nil
    }
}
