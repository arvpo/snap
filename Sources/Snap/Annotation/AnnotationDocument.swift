import CoreGraphics
import Foundation

/// A session owns one crop and value-only undo deltas. Render snapshots expose
/// values; selection and editing use stable entries, never array positions.
@MainActor
final class AnnotationDocument {
    enum Mutation {
        case insert(Annotation, at: Int? = nil)
        case update(UUID, AnnotationValue)
        case move(UUID, by: CGSize)
        case delete(UUID)
    }

    private struct PositionedAnnotation {
        let index: Int
        let annotation: Annotation
    }

    private struct Change {
        let id: UUID
        let before: PositionedAnnotation?
    }

    let baseImage: CGImage
    private(set) var entries: [Annotation] = []
    private var undoHistory: [[Change]] = []
    var currentTool: AnnotationTool = .arrow

    init(baseImage: CGImage) {
        self.baseImage = baseImage
        SessionLifetime.retain(.document)
    }

    deinit {
        SessionLifetime.release(.document)
    }

    var annotations: [AnnotationValue] { entries.map(\.value) }
    var isEmpty: Bool { entries.isEmpty }
    var canUndo: Bool { !undoHistory.isEmpty }

    func annotation(id: UUID) -> Annotation? {
        entries.first { $0.id == id }
    }

    @discardableResult
    func commit(_ value: AnnotationValue) -> UUID {
        let entry = Annotation(value: value)
        apply([.insert(entry)])
        return entry.id
    }

    @discardableResult
    func update(id: UUID, value: AnnotationValue) -> Bool {
        apply([.update(id, value)])
    }

    @discardableResult
    func move(id: UUID, by offset: CGSize) -> Bool {
        apply([.move(id, by: offset)])
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        apply([.delete(id)])
    }

    /// Submit completed gestures/editing sessions here. All mutations and
    /// automatic renumbering form ONE undo step. Invalid batches are atomic;
    /// no-op batches do not consume undo. Keep transient previews in the UI.
    @discardableResult
    func apply(_ mutations: [Mutation]) -> Bool {
        var next = entries
        for mutation in mutations {
            switch mutation {
            case .insert(let annotation, let requestedIndex):
                let index = requestedIndex ?? next.count
                guard !next.contains(where: { $0.id == annotation.id }),
                      (0...next.count).contains(index) else { return false }
                next.insert(annotation, at: index)
            case .update(let id, let value):
                guard let index = next.firstIndex(where: { $0.id == id }) else { return false }
                next[index].value = value
            case .move(let id, let offset):
                guard let index = next.firstIndex(where: { $0.id == id }) else { return false }
                next[index].value = next[index].value.translated(by: offset)
            case .delete(let id):
                guard let index = next.firstIndex(where: { $0.id == id }) else { return false }
                next.remove(at: index)
            }
        }

        var number = 0
        for index in next.indices {
            if case .number(var marker) = next[index].value {
                number += 1
                marker.number = number
                next[index].value = .number(marker)
            }
        }
        guard next != entries else { return false }

        let before = Dictionary(uniqueKeysWithValues: entries.enumerated().map {
            ($0.element.id, PositionedAnnotation(index: $0.offset, annotation: $0.element))
        })
        let after = Dictionary(uniqueKeysWithValues: next.enumerated().map {
            ($0.element.id, PositionedAnnotation(index: $0.offset, annotation: $0.element))
        })
        let ids = Set(before.keys).union(after.keys)
        let insertedIDs = Set(mutations.compactMap { mutation -> UUID? in
            if case .insert(let entry, _) = mutation { return entry.id }
            return nil
        })
        let changes = ids.compactMap { id -> Change? in
            let old = before[id]
            let new = after[id]
            // Index shifts alone need no storage: undo reinserts/removes the
            // actual changed entries at their original positions. An explicit
            // delete/reinsert can also move an otherwise unchanged entry.
            guard old?.annotation != new?.annotation ||
                    (old?.index != new?.index && insertedIDs.contains(id)) else { return nil }
            return Change(id: id, before: old)
        }
        undoHistory.append(changes)
        entries = next
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let changes = undoHistory.popLast() else { return false }
        let changedIDs = Set(changes.map(\.id))
        entries.removeAll { changedIDs.contains($0.id) }
        for previous in changes.compactMap(\.before).sorted(by: { $0.index < $1.index }) {
            entries.insert(previous.annotation, at: previous.index)
        }
        return true
    }

    /// Session teardown clears history as well as visible annotations.
    func removeAll() {
        entries.removeAll()
        undoHistory.removeAll()
    }
}
