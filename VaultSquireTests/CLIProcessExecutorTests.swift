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

    /// Provider switches come from a closed enum, so no caller can smuggle a
    /// token or user-authored value into an arbitrary environment overlay.
    func testTheOnePasswordModeAddsOnlyItsReviewedConstant() async {
        let base = await CLIProcessExecutor().childEnvironment()
        let configured = await CLIProcessExecutor(
            mode: .onePasswordDesktopAuthorization
        ).childEnvironment()

        XCTAssertEqual(configured["OP_BIOMETRIC_UNLOCK_ENABLED"], "true")
        XCTAssertEqual(
            Set(configured.keys).subtracting(base.keys),
            Set(["OP_BIOMETRIC_UNLOCK_ENABLED"])
        )
        for key in base.keys {
            XCTAssertEqual(configured[key], base[key], "\(key) changed from the base environment")
        }
    }

    func testExecutionOutputCanBeExplicitlyDiscarded() {
        var execution = CLIExecution(
            exitCode: 0,
            standardOutput: Data("synthetic-secret".utf8),
            standardErrorByteCount: 0
        )

        execution.discardStandardOutput()

        XCTAssertTrue(execution.standardOutput.isEmpty)
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

    func testRejectsNULArgumentsBeforeLaunch() async throws {
        let executableURL = try macOSExecutableURL(at: "/usr/bin/true")
        await XCTAssertThrowsErrorAsync(
            try await CLIProcessExecutor().execute(
                CLIInvocation(arguments: ["safe\0suffix"]),
                executableURL: executableURL
            )
        ) { error in
            XCTAssertEqual(error as? CLIExecutionError, .invalidArguments)
        }
    }

    func testRejectsInvalidTimeoutAndExcessiveOutputLimit() async throws {
        let executableURL = try macOSExecutableURL(at: "/usr/bin/true")
        await XCTAssertThrowsErrorAsync(
            try await CLIProcessExecutor().execute(
                CLIInvocation(arguments: [], timeout: .zero),
                executableURL: executableURL
            )
        ) { error in
            XCTAssertEqual(error as? CLIExecutionError, .invalidTimeout)
        }
        await XCTAssertThrowsErrorAsync(
            try await CLIProcessExecutor().execute(
                CLIInvocation(arguments: [], outputLimit: 64 * 1024 * 1024 + 1),
                executableURL: executableURL
            )
        ) { error in
            XCTAssertEqual(error as? CLIExecutionError, .invalidOutputLimit)
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

    func testFailsClosedWhenStandardErrorExceedsTheSameBound() async throws {
        let executor = CLIProcessExecutor()
        let executableURL = try macOSExecutableURL(at: "/bin/sh")
        await XCTAssertThrowsErrorAsync(
            try await executor.execute(
                CLIInvocation(
                    arguments: ["-c", "while :; do printf 1234567890 1>&2; done"],
                    timeout: .seconds(30),
                    outputLimit: 8
                ),
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
