import Foundation
@testable import VaultSquire

/// Test-only executor. It returns canned executions keyed by the exact argument
/// vector and records every invocation, so the runner's gating, identifier
/// validation, command construction, and error mapping are exercised without a
/// real binary. It never leaves the test target.
actor FakeCLIExecutor: CLIExecuting {
    private var stdoutByArguments: [[String]: Data] = [:]
    private var exitCodeByArguments: [[String]: Int32] = [:]
    private var errorByArguments: [[String]: CLIExecutionError] = [:]

    private(set) var recordedArguments: [[String]] = []
    private(set) var recordedExecutableURLs: [URL] = []

    func stub(arguments: [String], stdout: Data = Data(), exitCode: Int32 = 0) {
        stdoutByArguments[arguments] = stdout
        exitCodeByArguments[arguments] = exitCode
    }

    func stub(arguments: [String], stdout: String, exitCode: Int32 = 0) {
        stub(arguments: arguments, stdout: Data(stdout.utf8), exitCode: exitCode)
    }

    func stub(arguments: [String], error: CLIExecutionError) {
        errorByArguments[arguments] = error
    }

    func execute(
        _ invocation: CLIInvocation,
        executableURL: URL
    ) async throws -> CLIExecution {
        recordedArguments.append(invocation.arguments)
        recordedExecutableURLs.append(executableURL)

        if let error = errorByArguments[invocation.arguments] {
            throw error
        }
        return CLIExecution(
            exitCode: exitCodeByArguments[invocation.arguments] ?? 0,
            standardOutput: stdoutByArguments[invocation.arguments] ?? Data(),
            standardErrorByteCount: 0
        )
    }
}
