import Foundation
import XCTest
@testable import VaultSquire

/// Exercises the production no-shell executor against small macOS system
/// utilities. Content capture, byte-count-only standard error, absolute-path
/// enforcement, the output bound, and the deadline are all covered without a
/// real CLI. Skips when a required utility is unavailable (non-macOS CI).
final class CLIProcessExecutorTests: XCTestCase {
    /// The base environment is an allowlist, not a filter of VaultSquire's own,
    /// so nothing the app inherited can reach a child process.
    func testTheBaseEnvironmentIsAFixedAllowlist() async {
        let environment = await CLIProcessExecutor().childEnvironment()
        XCTAssertTrue(
            Set(environment.keys).isSubset(of: ["LANG", "LC_ALL", "PATH", "HOME"]),
            "unexpected environment keys: \(Set(environment.keys))"
        )
    }

    /// A provider may pin a fixed non-secret mode switch, but the overlay can
    /// only add or pin an entry — never remove one the boundary depends on.
    func testAnOverlayAddsToTheAllowlistWithoutRemovingFromIt() async {
        let base = await CLIProcessExecutor().childEnvironment()
        let overlaid = await CLIProcessExecutor(
            environmentOverlay: ["EXAMPLE_MODE": "true", "LANG": "en_US.UTF-8"]
        ).childEnvironment()

        XCTAssertEqual(overlaid["EXAMPLE_MODE"], "true")
        XCTAssertEqual(overlaid["LANG"], "en_US.UTF-8", "an overlay entry wins over the base")
        for key in base.keys where key != "LANG" {
            XCTAssertEqual(overlaid[key], base[key], "\(key) was lost from the base environment")
        }
    }

    func testRejectsANonAbsoluteExecutable() async {
        let executor = CLIProcessExecutor()
        await XCTAssertThrowsErrorAsync(
            try await executor.execute(
                CLIInvocation(arguments: []),
                executableURL: URL(string: "https://invalid.example")!
            )
        ) { error in
            XCTAssertEqual(error as? CLIExecutionError, .executableNotAbsolute)
        }
    }

    func testCapturesStandardOutputContent() async throws {
        let executor = CLIProcessExecutor()
        let result = try await executor.execute(
            CLIInvocation(arguments: ["synthetic-output"]),
            executableURL: try macOSExecutableURL(at: "/usr/bin/printf")
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "synthetic-output")
        XCTAssertEqual(result.standardErrorByteCount, 0)
    }

    func testCountsStandardErrorWithoutReturningItsContent() async throws {
        let executor = CLIProcessExecutor()
        // sh is a fixture here, never a product path: it writes to stderr and
        // exits cleanly so only the byte count is observed.
        let result = try await executor.execute(
            CLIInvocation(arguments: ["-c", "printf ERR 1>&2"]),
            executableURL: try macOSExecutableURL(at: "/bin/sh")
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertEqual(result.standardErrorByteCount, 3)
    }

    func testReportsANonZeroExitCode() async throws {
        let executor = CLIProcessExecutor()
        let result = try await executor.execute(
            CLIInvocation(arguments: ["-c", "exit 7"]),
            executableURL: try macOSExecutableURL(at: "/bin/sh")
        )
        XCTAssertEqual(result.exitCode, 7)
    }

    func testFailsClosedWhenOutputExceedsTheBound() async throws {
        let executor = CLIProcessExecutor()
        // Resolved before the assertion: inside the autoclosure, the helper's
        // catch would swallow the XCTSkip and report a wrong-error failure
        // instead of skipping on a host without the fixture.
        let executableURL = try macOSExecutableURL(at: "/usr/bin/yes")
        await XCTAssertThrowsErrorAsync(
            try await executor.execute(
                CLIInvocation(arguments: [], timeout: .seconds(30), outputLimit: 8),
                executableURL: executableURL
            )
        ) { error in
            XCTAssertEqual(error as? CLIExecutionError, .outputLimitExceeded)
        }
    }

    func testTimesOutALongRunningChild() async throws {
        let executor = CLIProcessExecutor()
        let executableURL = try macOSExecutableURL(at: "/bin/sleep")
        await XCTAssertThrowsErrorAsync(
            try await executor.execute(
                CLIInvocation(arguments: ["2"], timeout: .milliseconds(20)),
                executableURL: executableURL
            )
        ) { error in
            XCTAssertEqual(error as? CLIExecutionError, .timedOut)
        }
    }

    func testCancellationTerminatesTheChildPromptly() async throws {
        let executor = CLIProcessExecutor()
        let executableURL = try macOSExecutableURL(at: "/bin/sleep")
        let task = Task {
            try await executor.execute(
                CLIInvocation(arguments: ["30"], timeout: .seconds(25)),
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
