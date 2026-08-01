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
        let executableURL = try macOSExecutableURL(at: "/usr/bin/printf")

        await XCTAssertThrowsErrorAsync(
            try await probe.run(executableURL: executableURL, outputLimit: 0)
        ) { error in
            XCTAssertEqual(error as? ProcessProbeError, .invalidOutputLimit)
        }
    }

    func testRejectsOutputLimitAboveMaximum() async throws {
        let probe = ProcessProbe()
        let executableURL = try macOSExecutableURL(at: "/usr/bin/printf")

        await XCTAssertThrowsErrorAsync(
            try await probe.run(
                executableURL: executableURL,
                outputLimit: ProcessProbe.maximumOutputLimit + 1
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

    /// Covers the wiring rather than the constant: the child must receive the
    /// allowlist and nothing else, so no `HOME`, `XDG_*`, token, or session path can
    /// reach it. `env` prints one `KEY=VALUE` line per variable, so the exact stdout
    /// byte count is a complete assertion over the child's environment without ever
    /// retaining its output.
    func testChildReceivesTheAllowlistAndNoOtherEnvironmentVariable() async throws {
        let executableURL = try macOSExecutableURL(at: "/usr/bin/env")
        let expectedBytes = ProcessProbe.allowedEnvironment
            .map { "\($0.key)=\($0.value)\n".utf8.count }
            .reduce(0, +)

        let result = try await ProcessProbe().run(executableURL: executableURL)

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.standardOutputBytes, expectedBytes)
        XCTAssertEqual(result.standardErrorBytes, 0)
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
        let executableURL = try macOSExecutableURL(at: "/usr/bin/printf")

        for _ in 0..<20 {
            await XCTAssertThrowsErrorAsync(
                try await probe.run(
                    executableURL: executableURL,
                    arguments: ["synthetic"],
                    outputLimit: 8
                )
            ) { error in
                XCTAssertEqual(error as? ProcessProbeError, .outputLimitExceeded)
            }
        }
    }

    /// `yes` never exits on its own, so reaching `.outputLimitExceeded` well inside
    /// the deadline proves the probe terminated the child. Without limit-driven
    /// termination this run would instead time out after 30 seconds.
    func testTerminatesAProducerThatWouldOtherwiseNeverExit() async throws {
        let executableURL = try macOSExecutableURL(at: "/usr/bin/yes")
        let started = ContinuousClock.now
        var thrownError: (any Error)?

        do {
            _ = try await ProcessProbe().run(
                executableURL: executableURL,
                timeout: .seconds(30),
                outputLimit: 8
            )
        } catch {
            thrownError = error
        }

        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(thrownError as? ProcessProbeError, .outputLimitExceeded)
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    /// A descendant that inherits the pipe write ends keeps the readers open after
    /// the direct child exits. The probe must give up on the readers instead of
    /// blocking forever, and must say so rather than reporting a clean result.
    func testReportsOutputThatRemainsOpenAfterTheChildExits() async throws {
        let executableURL = try macOSExecutableURL(at: "/bin/sh")
        let started = ContinuousClock.now
        var thrownError: (any Error)?

        // An adversarial fixture, not a probe code path: the probe itself never
        // invokes a shell. `sh` exits immediately while the backgrounded `sleep`
        // inherits stdout and stderr.
        do {
            _ = try await ProcessProbe().run(
                executableURL: executableURL,
                arguments: ["-c", "sleep 5 & exit 0"],
                timeout: .seconds(20)
            )
        } catch {
            thrownError = error
        }

        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(thrownError as? ProcessProbeError, .outputRemainedOpen)
        XCTAssertLessThan(elapsed, .seconds(4))
    }

    func testTerminatesAfterTimeout() async throws {
        let probe = ProcessProbe()
        let executableURL = try macOSExecutableURL(at: "/bin/sleep")

        await XCTAssertThrowsErrorAsync(
            try await probe.run(
                executableURL: executableURL,
                arguments: ["2"],
                timeout: .milliseconds(20)
            )
        ) { error in
            XCTAssertEqual(error as? ProcessProbeError, .timedOut)
        }
    }

    func testCancellationDoesNotPublishAResult() async throws {
        let probe = ProcessProbe()
        let executableURL = try macOSExecutableURL(at: "/bin/sleep")
        let task = Task {
            try await probe.run(
                executableURL: executableURL,
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

    /// Returning promptly proves cancellation terminated the child. Without
    /// cancellation-driven termination the call would block until the 25-second
    /// deadline expired.
    func testCancellationTerminatesTheChild() async throws {
        let probe = ProcessProbe()
        let executableURL = try macOSExecutableURL(at: "/bin/sleep")
        let task = Task {
            try await probe.run(
                executableURL: executableURL,
                arguments: ["30"],
                timeout: .seconds(25)
            )
        }

        try await Task.sleep(for: .milliseconds(50))

        let started = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        let elapsed = ContinuousClock.now - started

        XCTAssertLessThan(elapsed, .seconds(10))
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
