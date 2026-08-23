import CoreGraphics

/// Wraps `ImageRenderer` with a monotonically increasing generation counter
/// so a slow earlier render can never overwrite a newer clipboard result.
/// Stateless between calls beyond that counter: it stores no image, task, or
/// pasteboard owner once a render completes.
@MainActor
final class AnnotationRenderPipeline {
    typealias RenderFunction = @Sendable (CGImage, [AnnotationValue]) async throws -> CGImage

    private let clipboardService: ClipboardServicing
    private let render: RenderFunction
    private var generation = 0
    private var currentTask: Task<Void, Never>?

    var onRenderFailed: ((Error) -> Void)?

    init(
        clipboardService: ClipboardServicing,
        render: @escaping RenderFunction = { baseImage, annotations in
            try ImageRenderer.render(baseImage: baseImage, annotations: annotations)
        }
    ) {
        self.clipboardService = clipboardService
        self.render = render
    }

    /// Schedules an off-main-thread render tagged with a fresh generation.
    /// Only a result whose generation still matches the latest call reaches
    /// the clipboard.
    @discardableResult
    func scheduleRender(baseImage: CGImage, annotations: [AnnotationValue]) -> Task<Void, Never> {
        generation += 1
        let thisGeneration = generation
        let render = render
        let box = SendableBox(image: baseImage)

        currentTask?.cancel()
        let task = Task { [weak self] in
            let outcome = await Task.detached {
                do {
                    return Result<CGImage, Error>.success(try await render(box.image, annotations))
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self, !Task.isCancelled, thisGeneration == self.generation else { return }
            switch outcome {
            case .success(let image):
                do {
                    try self.clipboardService.writePNG(image)
                } catch {
                    self.onRenderFailed?(error)
                }
            case .failure(let error):
                self.onRenderFailed?(error)
            }
        }
        currentTask = task
        return task
    }

    /// Bumps the generation and cancels any render already in flight, so
    /// nothing pending can reach the clipboard after this call.
    func invalidate() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
    }
}

/// `CGImage` is not `Sendable`; this box carries one across the actor
/// boundary into a detached render task without retaining anything beyond
/// that single call.
private final class SendableBox<Value>: @unchecked Sendable {
    let image: Value
    init(image: Value) {
        self.image = image
    }
}
