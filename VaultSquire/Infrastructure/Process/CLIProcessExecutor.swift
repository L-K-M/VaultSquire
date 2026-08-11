import Darwin
import Foundation

/// One fully-formed CLI invocation. Its arguments are fixed subcommands and
/// reviewed opaque identifiers only — never a search term, secret, token,
/// user-authored field name, item content, or credential. Each provider's own
/// runner is the only constructor of its invocations, so no other path can
/// assemble an argument vector.
struct CLIInvocation: Equatable, Sendable {
    let arguments: [String]
    let timeout: Duration
    /// Upper bound on captured standard-output bytes; a larger stream is
    /// terminated mid-transfer rather than buffered.
    let outputLimit: Int

    init(arguments: [String], timeout: Duration = .seconds(20), outputLimit: Int = 4 * 1024 * 1024) {
        self.arguments = arguments
        self.timeout = timeout
        self.outputLimit = outputLimit
    }
}

/// The bounded result of one CLI run. `standardOutput` is captured content the
/// caller parses as untrusted data. `standardErrorByteCount` is a byte count
/// only: standard error is treated as secret-bearing, so its content is never
/// retained, logged, or returned.
struct CLIExecution: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardErrorByteCount: Int
}

enum CLIExecutionError: Error, Equatable, Sendable {
    case executableNotAbsolute
    case invalidOutputLimit
    case launchFailed
    case timedOut
    case outputLimitExceeded
    case cancelled
}

/// The process seam the runner drives. A conforming executor must never invoke
/// a shell, must pass arguments as an explicit vector (never a command line),
/// must bound captured output and duration, and must terminate the child on
/// cancellation. Tests substitute a fake so the runner's gating and parsing are
/// exercised without a real binary.
protocol CLIExecuting: Sendable {
    func execute(
        _ invocation: CLIInvocation,
        executableURL: URL
    ) async throws -> CLIExecution
}

/// The production executor: a no-shell `Foundation.Process` with a fixed
/// environment allowlist, standard input bound to the null device, and
/// standard output captured up to a byte limit while standard error is counted
/// but discarded. It mirrors `ProcessProbe`'s proven termination and drain
/// machinery, adding bounded content capture for the JSON read contract.
///
/// This is the one process boundary every provider CLI runs through — the
/// `ProcessRunner` component ARCHITECTURE.md §4 names — so the no-shell,
/// no-secret-in-argv-or-environment, bounded, cancellable rules are enforced
/// in a single reviewed place rather than re-implemented per provider.
actor CLIProcessExecutor: CLIExecuting {
    static let terminationGracePeriod = Duration.seconds(2)
    static let drainGracePeriod = Duration.seconds(2)

    /// Extra fixed, non-secret switches merged over the base environment.
    ///
    /// This exists for documented CLI mode switches a provider must pin — such
    /// as 1Password's `OP_BIOMETRIC_UNLOCK_ENABLED`, which selects the only
    /// authentication mode VaultSquire permits. It is never a channel for a
    /// token, session, credential, search term, or any user-authored value:
    /// the environment is a prohibited channel for those, and every entry here
    /// is a compile-time constant owned by a provider's runner. It cannot
    /// remove a base entry, only add or pin one.
    private let environmentOverlay: [String: String]

    init(environmentOverlay: [String: String] = [:]) {
        self.environmentOverlay = environmentOverlay
    }

    /// A minimal environment. `HOME` is passed through unchanged so the CLI
    /// finds its own session and configuration stores; it is never relocated to
    /// a fake value, and no `XDG_*`, token, or session variable is added. The
    /// CLI is always invoked by absolute path, so `PATH` is only a fallback for
    /// any helper it may resolve.
    ///
    /// Because this is an allowlist rather than a filter of the app's own
    /// environment, a secret-bearing variable the app happened to inherit —
    /// `OP_SESSION`, `OP_SERVICE_ACCOUNT_TOKEN`, `OP_CONNECT_TOKEN` — cannot
    /// reach a child process at all.
    static func environment() -> [String: String] {
        var environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        ]
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            environment["HOME"] = home
        }
        return environment
    }

    /// The exact environment this executor gives its children: the base
    /// allowlist with the provider's fixed switches merged over it.
    func childEnvironment() -> [String: String] {
        Self.environment().merging(environmentOverlay) { _, overlay in overlay }
    }

    func execute(
        _ invocation: CLIInvocation,
        executableURL: URL
    ) async throws -> CLIExecution {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            throw CLIExecutionError.executableNotAbsolute
        }
        guard invocation.outputLimit > 0 else {
            throw CLIExecutionError.invalidOutputLimit
        }

        let collector = CLIOutputCollector(limit: invocation.outputLimit)
        let execution = CLIExecutionState(
            executableURL: executableURL,
            arguments: invocation.arguments,
            environment: childEnvironment()
        )
        let streams = await execution.chunkStreams()
        let standardOutputTask = Task {
            await Self.drain(
                streams.standardOutput, from: .standardOutput,
                into: collector, execution: execution
            )
        }
        let standardErrorTask = Task {
            await Self.drain(
                streams.standardError, from: .standardError,
                into: collector, execution: execution
            )
        }

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await execution.start()
            } catch is CancellationError {
                await execution.stopReading()
                await standardOutputTask.value
                await standardErrorTask.value
                throw CLIExecutionError.cancelled
            } catch {
                await execution.stopReading()
                await standardOutputTask.value
                await standardErrorTask.value
                throw CLIExecutionError.launchFailed
            }

            let deadlineTask = Task {
                try await Task.sleep(for: invocation.timeout)
                await execution.expireDeadline(escalatingAfter: Self.terminationGracePeriod)
            }

            let exitCode = await execution.waitForTermination()
            deadlineTask.cancel()
            _ = try? await deadlineTask.value

            let didDrainCleanly = await Self.joinDrains(
                standardOutputTask, standardErrorTask,
                execution: execution, grace: Self.drainGracePeriod
            )
            let didTimeOut = await execution.deadlineExpired

            do {
                let captured = try await collector.waitForCompletion()
                await execution.stopReading()
                try Task.checkCancellation()
                if didTimeOut {
                    throw CLIExecutionError.timedOut
                }
                // A child that outlived its readers is treated as a timeout: its
                // output is incomplete, so parsing it would be unsafe.
                if !didDrainCleanly {
                    throw CLIExecutionError.timedOut
                }
                return CLIExecution(
                    exitCode: exitCode,
                    standardOutput: captured.standardOutput,
                    standardErrorByteCount: captured.standardErrorByteCount
                )
            } catch let error as CLIExecutionError {
                await execution.stopReading()
                throw error
            } catch is CancellationError {
                await execution.stopReading()
                throw CLIExecutionError.cancelled
            }
        } onCancel: {
            Task { await execution.cancel(escalatingAfter: Self.terminationGracePeriod) }
        }
    }

    private nonisolated static func joinDrains(
        _ standardOutputTask: Task<Void, Never>,
        _ standardErrorTask: Task<Void, Never>,
        execution: CLIExecutionState,
        grace: Duration
    ) async -> Bool {
        let forceTask = Task { () -> Bool in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return false
            }
            await execution.stopReading()
            return true
        }
        await standardOutputTask.value
        await standardErrorTask.value
        forceTask.cancel()
        let didForce = await forceTask.value
        return !didForce
    }

    private nonisolated static func drain(
        _ chunks: AsyncStream<Data>,
        from stream: CLIStream,
        into collector: CLIOutputCollector,
        execution: CLIExecutionState
    ) async {
        for await chunk in chunks {
            let exceeded = await collector.consume(chunk, from: stream)
            if exceeded {
                _ = await execution.terminateIfRunning(escalatingAfter: Self.terminationGracePeriod)
            }
        }
        await collector.close(stream)
    }
}

private enum CLIStream: Hashable, Sendable {
    case standardOutput
    case standardError
}

/// Accumulates bounded standard-output content and a standard-error byte count.
/// Exceeding the standard-output limit fails the whole run closed, so partial
/// or oversize output never reaches a parser.
private actor CLIOutputCollector {
    struct Captured: Sendable {
        let standardOutput: Data
        let standardErrorByteCount: Int
    }

    private let limit: Int
    private var standardOutput = Data()
    private var standardErrorByteCount = 0
    private var closedStreams = Set<CLIStream>()
    private var terminalError: CLIExecutionError?
    private var waiter: CheckedContinuation<Captured, any Error>?

    init(limit: Int) {
        self.limit = limit
    }

    func consume(_ chunk: Data, from stream: CLIStream) -> Bool {
        guard terminalError == nil, !closedStreams.contains(stream) else {
            return false
        }
        switch stream {
        case .standardOutput:
            standardOutput.append(chunk)
            if standardOutput.count > limit {
                failForLimit()
                return true
            }
        case .standardError:
            standardErrorByteCount += chunk.count
        }
        return false
    }

    func close(_ stream: CLIStream) {
        guard terminalError == nil, !closedStreams.contains(stream) else {
            return
        }
        closedStreams.insert(stream)
        resumeIfComplete()
    }

    func waitForCompletion() async throws -> Captured {
        if let terminalError {
            throw terminalError
        }
        if closedStreams.count == 2 {
            return Captured(standardOutput: standardOutput, standardErrorByteCount: standardErrorByteCount)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    private func failForLimit() {
        terminalError = .outputLimitExceeded
        // Drop buffered plaintext immediately; the run is failing closed.
        standardOutput = Data()
        waiter?.resume(throwing: CLIExecutionError.outputLimitExceeded)
        waiter = nil
    }

    private func resumeIfComplete() {
        guard closedStreams.count == 2, let waiter else {
            return
        }
        waiter.resume(returning: Captured(
            standardOutput: standardOutput,
            standardErrorByteCount: standardErrorByteCount
        ))
        self.waiter = nil
    }
}

/// Owns the `Process`, its pipes, and its termination state. Structure and
/// termination policy mirror `ProcessProbe`; the read handlers yield `Data`
/// chunks so standard output can be captured rather than only counted.
private actor CLIExecutionState {
    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let standardOutputChunks: AsyncStream<Data>
    private let standardErrorChunks: AsyncStream<Data>
    private let standardOutputContinuation: AsyncStream<Data>.Continuation
    private let standardErrorContinuation: AsyncStream<Data>.Continuation

    private var cancellationRequested = false
    private var deadlineDidExpire = false
    private var terminationStatus: Int32?
    private var terminationWaiter: CheckedContinuation<Int32, Never>?

    init(executableURL: URL, arguments: [String], environment: [String: String]) {
        let outSequence = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let errSequence = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        standardOutputChunks = outSequence.stream
        standardErrorChunks = errSequence.stream
        standardOutputContinuation = outSequence.continuation
        standardErrorContinuation = errSequence.continuation

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    var deadlineExpired: Bool { deadlineDidExpire }

    func chunkStreams() -> (standardOutput: AsyncStream<Data>, standardError: AsyncStream<Data>) {
        (standardOutputChunks, standardErrorChunks)
    }

    func start() throws {
        guard !cancellationRequested else {
            throw CancellationError()
        }
        installReadHandler(on: standardOutput.fileHandleForReading, continuation: standardOutputContinuation)
        installReadHandler(on: standardError.fileHandleForReading, continuation: standardErrorContinuation)

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.didTerminate(status: status) }
        }

        do {
            try process.run()
            standardOutput.fileHandleForWriting.closeFile()
            standardError.fileHandleForWriting.closeFile()
        } catch {
            stopReading()
            throw error
        }
    }

    func waitForTermination() async -> Int32 {
        if let terminationStatus {
            return terminationStatus
        }
        return await withCheckedContinuation { continuation in
            terminationWaiter = continuation
        }
    }

    func expireDeadline(escalatingAfter grace: Duration) async {
        guard terminationStatus == nil else { return }
        deadlineDidExpire = true
        _ = await terminateIfRunning(escalatingAfter: grace)
    }

    func terminateIfRunning(escalatingAfter grace: Duration) async -> Bool {
        guard process.isRunning else { return false }
        process.terminate()
        await escalateIfStillRunning(after: grace)
        return true
    }

    func cancel(escalatingAfter grace: Duration) async {
        cancellationRequested = true
        _ = await terminateIfRunning(escalatingAfter: grace)
    }

    func stopReading() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        standardOutputContinuation.finish()
        standardErrorContinuation.finish()
        process.terminationHandler = nil
    }

    private func escalateIfStillRunning(after grace: Duration) async {
        let step = Duration.milliseconds(20)
        var waited = Duration.zero
        while waited < grace {
            if !process.isRunning { return }
            do {
                try await Task.sleep(for: step)
            } catch {
                return
            }
            waited += step
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    private func installReadHandler(
        on fileHandle: FileHandle,
        continuation: AsyncStream<Data>.Continuation
    ) {
        fileHandle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
    }

    private func didTerminate(status: Int32) {
        terminationStatus = status
        terminationWaiter?.resume(returning: status)
        terminationWaiter = nil
    }
}
