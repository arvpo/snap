import CoreGraphics
import Foundation
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
    registerImageRendererTests()
    registerAnnotationRenderPipelineTests()

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
    exit(await runAllTests())
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
