import Foundation

/// Debug-only live-object counters for one capture session's heap.
///
/// Every kind is retained in `init` (or session start) and released in
/// `deinit` (or session end). After the editor closes, every counter must
/// be zero. Release builds compile the methods to no-ops.
enum SessionLifetime: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case captureSession
        case overlayController
        case editorController
        case document
        case overlayView
        case canvasView
        case renderTask
    }

    static func retain(_ kind: Kind) {
        #if DEBUG
        store.retain(kind)
        #endif
    }

    static func release(_ kind: Kind) {
        #if DEBUG
        store.release(kind)
        #endif
    }

    static func count(of kind: Kind) -> Int {
        #if DEBUG
        store.count(of: kind)
        #else
        0
        #endif
    }

    static func snapshot() -> [Kind: Int] {
        #if DEBUG
        store.snapshot()
        #else
        [:]
        #endif
    }

    /// Test hook so one case cannot poison the next.
    static func reset() {
        #if DEBUG
        store.reset()
        #endif
    }
}

#if DEBUG
private let store = SessionLifetimeStore()

private final class SessionLifetimeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [SessionLifetime.Kind: Int] = [:]

    func retain(_ kind: SessionLifetime.Kind) {
        lock.lock()
        counts[kind, default: 0] += 1
        lock.unlock()
    }

    func release(_ kind: SessionLifetime.Kind) {
        lock.lock()
        let next = (counts[kind] ?? 0) - 1
        counts[kind] = max(0, next)
        lock.unlock()
    }

    func count(of kind: SessionLifetime.Kind) -> Int {
        lock.lock()
        let value = counts[kind] ?? 0
        lock.unlock()
        return value
    }

    func snapshot() -> [SessionLifetime.Kind: Int] {
        lock.lock()
        let value = counts
        lock.unlock()
        return value
    }

    func reset() {
        lock.lock()
        counts.removeAll()
        lock.unlock()
    }
}
#endif
