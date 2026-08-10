import Foundation
import XCTest
@testable import VaultSquire

/// Exercises the production no-shell executor against small macOS system
/// utilities. Content capture, byte-count-only standard error, absolute-path
/// enforcement, the output bound, and the deadline are all covered without a
/// real CLI. Skips when a required utility is unavailable (non-macOS CI).
final class ProtonCLIExecutorTests: XCTestCase {
    func testRejectsANonAbsoluteExecutable() async {
        let executor = ProtonCLIProcessExecutor()
        await XCTAssertThrowsErrorAsync(
            try await executor.execute(
                ProtonCLIInvocation(arguments: []),
                executableURL: URL(string: "https://invalid.example")!
            )
        ) { error in
            XCTAssertEqual(error as? ProtonCLIExecutionError, .executableNotAbsolute)
        }
    }

    func testCapturesStandardOutputContent() async throws {
        let executor = ProtonCLIProcessExecutor()
        let result = try await executor.execute(
            ProtonCLIInvocation(arguments: ["synthetic-output"]),
            executableURL: try macOSExecutableURL(at: "/usr/bin/printf")
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "synthetic-output")
        XCTAssertEqual(result.standardErrorByteCount, 0)
    }

    func testCountsStandardErrorWithoutReturningItsContent() async throws {
        let executor = ProtonCLIProcessExecutor()
        // sh is a fixture here, never a product path: it writes to stderr and
        // exits cleanly so only the byte count is observed.
        let result = try await executor.execute(
            ProtonCLIInvocation(arguments: ["-c", "printf ERR 1>&2"]),
            executableURL: try macOSExecutableURL(at: "/bin/sh")
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertEqual(result.standardErrorByteCount, 3)
    }

    func testReportsANonZeroExitCode() async throws {
        let executor = ProtonCLIProcessExecutor()
        let result = try await executor.execute(
            ProtonCLIInvocation(arguments: ["-c", "exit 7"]),
            executableURL: try macOSExecutableURL(at: "/bin/sh")
        )
        XCTAssertEqual(result.exitCode, 7)
    }

    func testFailsClosedWhenOutputExceedsTheBound() async throws {
        let executor = ProtonCLIProcessExecutor()
        await XCTAssertThrowsErrorAsync(
            try await executor.execute(
                ProtonCLIInvocation(arguments: [], timeout: .seconds(30), outputLimit: 8),
                executableURL: try macOSExecutableURL(at: "/usr/bin/yes")
            )
        ) { error in
            XCTAssertEqual(error as? ProtonCLIExecutionError, .outputLimitExceeded)
        }
    }

    func testTimesOutALongRunningChild() async throws {
        let executor = ProtonCLIProcessExecutor()
        await XCTAssertThrowsErrorAsync(
            try await executor.execute(
                ProtonCLIInvocation(arguments: ["2"], timeout: .milliseconds(20)),
                executableURL: try macOSExecutableURL(at: "/bin/sleep")
            )
        ) { error in
            XCTAssertEqual(error as? ProtonCLIExecutionError, .timedOut)
        }
    }

    func testCancellationTerminatesTheChildPromptly() async throws {
        let executor = ProtonCLIProcessExecutor()
        let executableURL = try macOSExecutableURL(at: "/bin/sleep")
        let task = Task {
            try await executor.execute(
                ProtonCLIInvocation(arguments: ["30"], timeout: .seconds(25)),
                executableURL: executableURL
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
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
