import CoreGraphics
import Foundation
import os

/// One active render/encode worker and one replaceable pending value snapshot.
/// A completed worker returns only PNG bytes; rendered pixels never cross to
/// the main actor. Generation checks guard both successful and failed output.
@MainActor
final class AnnotationRenderPipeline {
    typealias RenderFunction = @Sendable (CGImage, [AnnotationValue]) async throws -> CGImage
    typealias EncodeFunction = @Sendable (CGImage) async throws -> Data

    private struct Snapshot: @unchecked Sendable {
        // CGImage is immutable. The box only transfers that immutable reference.
        let image: CGImage
        let annotations: [AnnotationValue]
        let generation: Int
    }
    private struct Prepared: Sendable {
        let png: Data
        let renderMilliseconds: Double
        let encodeMilliseconds: Double
    }

    private let clipboardService: ClipboardServicing
    private let render: RenderFunction
    private let encode: EncodeFunction
    private let interval: CaptureInterval
    private var generation = 0
    private var publishedGeneration: Int?
    private var pending: Snapshot?
    private var currentTask: Task<Void, Never>?
    private var worker: Task<Result<Prepared, Error>, Never>?
    private(set) var lastError: Error?
    var isWorking: Bool { currentTask != nil }
    var hasPendingSnapshot: Bool { pending != nil }

    var onRenderFailed: ((Error) -> Void)?
    var onPublished: (() -> Void)?

    init(
        clipboardService: ClipboardServicing,
        interval: CaptureInterval = .annotationMouseUpToClipboard,
        encode: @escaping EncodeFunction = { try PNGEncoder.encode($0) },
        render: @escaping RenderFunction = { baseImage, annotations in
            if annotations.isEmpty { return baseImage }
            return try ImageRenderer.render(baseImage: baseImage, annotations: annotations)
        }
    ) {
        self.clipboardService = clipboardService
        self.interval = interval
        self.render = render
        self.encode = encode
    }

    /// Calls in the same event-loop turn coalesce before work starts. Calls
    /// during work replace the sole pending snapshot, never start a second worker.
    @discardableResult
    func scheduleRender(baseImage: CGImage, annotations: [AnnotationValue],
                        startInterval: Bool = true) -> Task<Void, Never> {
        generation += 1
        lastError = nil
        pending = Snapshot(image: baseImage, annotations: annotations, generation: generation)
        worker?.cancel()
        if startInterval { CaptureSignposts.shared.begin(interval) }
        if let currentTask { return currentTask }

        let render = render
        let encode = encode
        SessionLifetime.retain(.renderTask)
        let task = Task { [weak self] in
            defer { SessionLifetime.release(.renderTask) }
            while let snapshot = self?.takePending() {
                // Also serialize a canceled editor's draining worker against
                // the next capture, so session replacement cannot double buffers.
                await ImageWorkerLane.shared.acquire()
                if self?.generation == snapshot.generation {
                    // The coordinator task captures self weakly across the await.
                    // Cancellation can release the UI/document while ImageIO drains.
                    let worker = Task.detached(priority: .userInitiated) {
                        await Self.prepare(snapshot, render: render, encode: encode)
                    }
                    self?.worker = worker
                    let result = await worker.value
                    self?.worker = nil
                    self?.complete(result, generation: snapshot.generation)
                    // All task/result/snapshot references leave scope before the
                    // next worker allocates its output buffer.
                }
                await ImageWorkerLane.shared.release()
            }
            self?.currentTask = nil
        }
        currentTask = task
        return task
    }

    private func takePending() -> Snapshot? {
        defer { pending = nil }
        return pending
    }

    nonisolated private static func prepare(_ snapshot: Snapshot, render: RenderFunction,
                                            encode: EncodeFunction) async -> Result<Prepared, Error> {
        do {
            try Task.checkCancellation()
            let signposter = OSSignposter(subsystem: "com.stradeon.Snap", category: "latency")
            let renderStart = ContinuousClock.now
            let image: CGImage
            do {
                let state = signposter.beginInterval("annotation-render")
                defer { signposter.endInterval("annotation-render", state) }
                image = try await render(snapshot.image, snapshot.annotations)
            }
            let renderMs = milliseconds(from: renderStart.duration(to: .now))
            try Task.checkCancellation()
            let encodeStart = ContinuousClock.now
            let png: Data
            do {
                let state = signposter.beginInterval("png-encode")
                defer { signposter.endInterval("png-encode", state) }
                png = try await encode(image)
            }
            try Task.checkCancellation()
            return .success(Prepared(png: png, renderMilliseconds: renderMs,
                                     encodeMilliseconds: milliseconds(from: encodeStart.duration(to: .now))))
        } catch {
            return .failure(error)
        }
    }

    private func complete(_ result: Result<Prepared, Error>, generation completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        do {
            let prepared = try result.get()
            CaptureSignposts.shared.record(.annotationRender, milliseconds: prepared.renderMilliseconds)
            CaptureSignposts.shared.record(.pngEncode, milliseconds: prepared.encodeMilliseconds)
            CaptureSignposts.shared.begin(.clipboardPublication)
            defer { CaptureSignposts.shared.end(.clipboardPublication) }
            try clipboardService.publishPNG(prepared.png)
            publishedGeneration = generation
            CaptureSignposts.shared.end(interval)
        } catch {
            lastError = error
            CaptureSignposts.shared.abandon(interval)
            onRenderFailed?(error)
            return
        }
        onPublished?()
    }

    /// A synchronous encoder cannot be interrupted mid-call. Invalidate its
    /// output immediately, drop pending values, and let the sole worker drain.
    func invalidate() {
        generation += 1
        pending = nil
        lastError = nil
        worker?.cancel()
        CaptureSignposts.shared.abandon(interval)
    }

    @discardableResult
    func awaitPendingRender() async -> Bool {
        while let currentTask { await currentTask.value }
        return publishedGeneration == generation
    }
}

private actor ImageWorkerLane {
    static let shared = ImageWorkerLane()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
