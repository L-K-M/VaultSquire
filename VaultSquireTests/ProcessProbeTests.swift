import Foundation
import XCTest
@testable import VaultSquire

final class ProcessProbeTests: XCTestCase {
    func testRejectsNonFileURL() async {
        let probe = ProcessProbe()

        await XCTAssertThrowsErrorAsync(
            try await probe.run(executableURL: URL(string: "https://invalid.example")!)
        ) { error in
            XCTAssertEqual(error as? ProcessProbeError, .executableMustBeAbsolute)
        }
    }

    func testRejectsNonpositiveOutputLimit() async throws {
        let probe = ProcessProbe()

        await XCTAssertThrowsErrorAsync(
            try await probe.run(
                executableURL: try macOSExecutableURL(at: "/usr/bin/printf"),
                outputLimit: 0
            )
        ) { error in
            XCTAssertEqual(error as? ProcessProbeError, .invalidOutputLimit)
        }
    }

    func testUsesFixedEnvironmentAllowlist() {
        XCTAssertEqual(
            ProcessProbe.allowedEnvironment,
            [
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin"
            ]
        )
    }

    func testCountsOutputWithoutReturningContent() async throws {
        let result = try await ProcessProbe().run(
            executableURL: try macOSExecutableURL(at: "/usr/bin/printf"),
            arguments: ["synthetic"]
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.standardOutputBytes, 9)
        XCTAssertEqual(result.standardErrorBytes, 0)
    }

    func testTerminatesWhenOutputLimitIsExceeded() async throws {
        let probe = ProcessProbe()

        await XCTAssertThrowsErrorAsync(
            try await probe.run(
                executableURL: try macOSExecutableURL(at: "/usr/bin/printf"),
                arguments: ["synthetic"],
                outputLimit: 8
            )
        ) { error in
            XCTAssertEqual(error as? ProcessProbeError, .outputLimitExceeded)
        }
    }

    func testTerminatesAfterTimeout() async throws {
        let probe = ProcessProbe()

        await XCTAssertThrowsErrorAsync(
            try await probe.run(
                executableURL: try macOSExecutableURL(at: "/bin/sleep"),
                arguments: ["2"],
                timeout: .milliseconds(20)
            )
        ) { error in
            XCTAssertEqual(error as? ProcessProbeError, .timedOut)
        }
    }

    func testCancellationDoesNotPublishAResult() async throws {
        let probe = ProcessProbe()
        let task = Task {
            try await probe.run(
                executableURL: try macOSExecutableURL(at: "/bin/sleep"),
                arguments: ["2"]
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled process probe returned a result")
        } catch is CancellationError {
            // Expected cancellation path.
        } catch {
            XCTFail("Unexpected cancellation error: \(type(of: error))")
        }
    }
}

private func macOSExecutableURL(at path: String) throws -> URL {
    guard FileManager.default.isExecutableFile(atPath: path) else {
        throw XCTSkip("Required macOS test executable is unavailable: \(path)")
    }
    return URL(fileURLWithPath: path)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
