import os

enum CaptureInterval: String, CaseIterable, Sendable {
    case hotkeyToSnapshot = "hotkey-to-snapshot"
    case snapshotToOverlay = "snapshot-to-overlay"
    case mouseUpToFirstClipboard = "mouse-up-to-first-clipboard"
    case annotationMouseUpToClipboard = "annotation-mouse-up-to-clipboard"
}

/// `os_signpost` intervals for the four Phase 5 latency gates.
///
/// Begin/end also record wall-clock milliseconds so Instruments is not the
/// only way to see a miss. Starting an interval that is already open closes
/// the previous one first, so a newer edit cannot leave a stale open interval.
@MainActor
final class CaptureSignposts {
    static let shared = CaptureSignposts()

    private let signposter = OSSignposter(subsystem: "com.stradeon.Snap", category: "latency")
    private var states: [CaptureInterval: OSSignpostIntervalState] = [:]
    private var starts: [CaptureInterval: ContinuousClock.Instant] = [:]

    /// Most recent completed duration per interval, in milliseconds.
    private(set) var lastDurationsMilliseconds: [CaptureInterval: Double] = [:]

    func begin(_ interval: CaptureInterval) {
        abandon(interval)
        starts[interval] = ContinuousClock.now
        states[interval] = beginSignpost(interval)
    }

    func end(_ interval: CaptureInterval) {
        if let start = starts.removeValue(forKey: interval) {
            lastDurationsMilliseconds[interval] = milliseconds(from: start.duration(to: .now))
        }
        if let state = states.removeValue(forKey: interval) {
            endSignpost(interval, state)
        }
    }

    func abandon(_ interval: CaptureInterval) {
        starts.removeValue(forKey: interval)
        if let state = states.removeValue(forKey: interval) {
            endSignpost(interval, state)
        }
    }

    func abandonAll() {
        for interval in CaptureInterval.allCases {
            abandon(interval)
        }
    }

    func reset() {
        abandonAll()
        lastDurationsMilliseconds.removeAll()
    }

    private func beginSignpost(_ interval: CaptureInterval) -> OSSignpostIntervalState {
        switch interval {
        case .hotkeyToSnapshot:
            signposter.beginInterval("hotkey-to-snapshot")
        case .snapshotToOverlay:
            signposter.beginInterval("snapshot-to-overlay")
        case .mouseUpToFirstClipboard:
            signposter.beginInterval("mouse-up-to-first-clipboard")
        case .annotationMouseUpToClipboard:
            signposter.beginInterval("annotation-mouse-up-to-clipboard")
        }
    }

    private func endSignpost(_ interval: CaptureInterval, _ state: OSSignpostIntervalState) {
        switch interval {
        case .hotkeyToSnapshot:
            signposter.endInterval("hotkey-to-snapshot", state)
        case .snapshotToOverlay:
            signposter.endInterval("snapshot-to-overlay", state)
        case .mouseUpToFirstClipboard:
            signposter.endInterval("mouse-up-to-first-clipboard", state)
        case .annotationMouseUpToClipboard:
            signposter.endInterval("annotation-mouse-up-to-clipboard", state)
        }
    }
}

func milliseconds(from duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}
