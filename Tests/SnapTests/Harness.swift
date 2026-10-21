import CoreGraphics
import Foundation
import ImageIO
@testable import SnapCore

public struct ExpectationError: Error, CustomStringConvertible {
    public let message: String
    public let file: String
    public let line: Int

    public var description: String {
        "\(file):\(line): \(message)"
    }
}

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "",
    file: String = #fileID,
    line: Int = #line
) throws {
    guard condition() else {
        let detail = message()
        throw ExpectationError(
            message: detail.isEmpty ? "expectation failed" : detail,
            file: file,
            line: line
        )
    }
}

func expectEqual<Value: Equatable>(
    _ lhs: Value,
    _ rhs: Value,
    file: String = #fileID,
    line: Int = #line
) throws {
    try expect(lhs == rhs, "\(lhs) is not equal to \(rhs)", file: file, line: line)
}

struct RegisteredTest {
    let name: String
    let body: () async throws -> Void
}

@MainActor
enum TestCatalog {
    static var tests: [RegisteredTest] = []
}

@MainActor
func test(_ name: String, body: @escaping () async throws -> Void) {
    TestCatalog.tests.append(RegisteredTest(name: name, body: body))
}

@MainActor
private func runAllTests() async -> Int32 {
    registerCaptureCoordinatorTests()
    registerCaptureIntegrationTests()
    registerCaptureSessionPresenterTests()
    registerSessionLifetimeTests()
    registerPerformanceProbeTests()
    registerScreenGeometryTests()
    registerSelectionTests()
    registerGlobalHotKeyTests()
    registerAnnotationBuilderTests()
    registerAnnotationDocumentTests()
    registerAnnotationEditingTests()
    registerAnnotationTextEditingTests()
    registerAnnotationSelectionTests()
    registerAnnotationLayoutTests()
    registerAnnotationToolbarTests()
    registerImageRendererTests()
    registerAnnotationRenderPipelineTests()
    registerAnnotationResponsivenessTests()
    registerAnnotationWorkflowTests()
    registerAnnotationPerformanceTests()

    // An opt-in live run must fail clearly when TCC access is unavailable;
    // never count synthetic captures as a passing real-capture check.
    if ProcessInfo.processInfo.environment["SNAP_LIVE_CAPTURE_CHECK"] == "1" {
        registerLiveAnnotationWorkflowTests()
    }

    if let filter = ProcessInfo.processInfo.environment["SNAP_TEST_FILTER"] {
        TestCatalog.tests = TestCatalog.tests.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        guard !TestCatalog.tests.isEmpty else {
            print("No tests match SNAP_TEST_FILTER=\(filter)")
            return EXIT_FAILURE
        }
    }

    var failed = 0
    for item in TestCatalog.tests {
        do {
            try await item.body()
            print("ok   \(item.name)")
        } catch {
            failed += 1
            print("fail \(item.name): \(error)")
        }
    }

    let total = TestCatalog.tests.count
    print("\(total - failed) passed, \(failed) failed, \(total) total")
    return failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE
}

/// Entry point invoked by the SwiftPM-generated test runner.
public func __swiftPMEntryPoint() async -> Never {
    let status = await runAllTests()
    // leaks --atExit reports its own findings, not the child exit status.
    // Preserve functional failures (and detect crashes with a missing marker).
    if let resultPath = ProcessInfo.processInfo.environment["SNAP_TEST_RESULT_PATH"] {
        do {
            try String(status).write(toFile: resultPath, atomically: true, encoding: .utf8)
        } catch {
            print("Could not record test exit status: \(error)")
            exit(EXIT_FAILURE)
        }
    }
    exit(status)
}

func makeTestCGImage(width: Int = 8, height: Int = 8) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

func makeTestCapturedDisplay(
    displayID: CGDirectDisplayID = 1,
    appKitFrame: CGRect = CGRect(x: 0, y: 0, width: 8, height: 8),
    backingScale: CGFloat = 1,
    image: CGImage? = nil
) -> CapturedDisplay {
    let resolvedImage = image ?? makeTestCGImage(
        width: max(1, Int((appKitFrame.width * backingScale).rounded())),
        height: max(1, Int((appKitFrame.height * backingScale).rounded()))
    )
    return CapturedDisplay(
        displayID: displayID,
        appKitFrame: appKitFrame,
        backingScale: backingScale,
        image: resolvedImage
    )
}

@MainActor
func waitUntil(
    timeout: Duration = .milliseconds(800),
    file: String = #fileID,
    line: Int = #line,
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ExpectationError(message: "timed out waiting for condition", file: file, line: line)
}

@MainActor
func pumpMainLoop(_ iterations: Int = 8) async {
    for _ in 0..<iterations {
        await Task.yield()
        spinMainRunLoop()
    }
}

private func spinMainRunLoop(seconds: TimeInterval = 0.01) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

func expectLifetimeZero(file: String = #fileID, line: Int = #line) throws {
    for kind in SessionLifetime.Kind.allCases {
        let count = SessionLifetime.count(of: kind)
        try expect(
            count == 0,
            "\(kind.rawValue) still live: \(count)",
            file: file,
            line: line
        )
    }
}

func decodedClipboardImage(_ data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ClipboardError.encodingFailed
    }
    return try ImageRenderer.render(baseImage: image, annotations: [])
}
