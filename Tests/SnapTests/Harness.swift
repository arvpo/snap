import Foundation

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
    registerScreenGeometryTests()
    registerGlobalHotKeyTests()

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
