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
    /// Per-stream byte bound. Standard output is captured; standard error is
    /// discarded after counting. Either stream crossing the bound terminates
    /// the child before more bytes enter the async drain queue.
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
    private(set) var standardOutput: Data
    let standardErrorByteCount: Int

    init(exitCode: Int32, standardOutput: Data, standardErrorByteCount: Int) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardErrorByteCount = standardErrorByteCount
    }

    mutating func discardStandardOutput() {
        standardOutput.resetBytes(
            in: standardOutput.startIndex..<standardOutput.endIndex
        )
        standardOutput.removeAll(keepingCapacity: false)
    }
}

enum CLIExecutionError: Error, Equatable, Sendable {
    case executableNotAbsolute
    case invalidArguments
    case invalidTimeout
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

enum CLIProcessMode: Sendable {
    case standard
    /// The only admitted 1Password authentication mode: authorization remains
    /// in the user-installed desktop app and no session/token enters this app.
    case onePasswordDesktopAuthorization

    fileprivate var environmentOverlay: [String: String] {
        switch self {
        case .standard:
            return [:]
        case .onePasswordDesktopAuthorization:
            return ["OP_BIOMETRIC_UNLOCK_ENABLED": "true"]
        }
    }
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

    /// A closed mode enum is the only way to add a child environment entry.
    /// Callers cannot turn a token or user-authored value into an overlay.
    private let mode: CLIProcessMode

    init(mode: CLIProcessMode = .standard) {
        self.mode = mode
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
        if let home = ProcessInfo.processInfo.environment["HOME"],
           home.hasPrefix("/"),
           home.utf8.count <= 4_096,
           home.unicodeScalars.allSatisfy({
               !CharacterSet.controlCharacters.contains($0)
           }) {
            environment["HOME"] = home
        }
        return environment
    }

    /// The exact environment this executor gives its children: the base
    /// allowlist with the provider's fixed switches merged over it.
    func childEnvironment() -> [String: String] {
        Self.environment().merging(mode.environmentOverlay) { _, overlay in overlay }
    }

    func execute(
        _ invocation: CLIInvocation,
        executableURL: URL
    ) async throws -> CLIExecution {
        guard executableURL.isFileURL,
              executableURL.host == nil || executableURL.host == "localhost",
              executableURL.query == nil,
              executableURL.fragment == nil,
              executableURL.path.hasPrefix("/"),
              executableURL.path.utf8.count <= 4_096,
              executableURL.path.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CLIExecutionError.executableNotAbsolute
        }
        guard invocation.arguments.count <= 64,
              invocation.arguments.allSatisfy({ argument in
                  argument.utf8.count <= 4_096
                      && argument.unicodeScalars.allSatisfy {
                          !CharacterSet.controlCharacters.contains($0)
                      }
              }),
              invocation.arguments.reduce(0, { $0 + $1.utf8.count }) <= 32 * 1024 else {
            throw CLIExecutionError.invalidArguments
        }
        guard invocation.timeout > .zero,
              invocation.timeout <= .seconds(300) else {
            throw CLIExecutionError.invalidTimeout
        }
        guard invocation.outputLimit > 0,
              invocation.outputLimit <= 64 * 1024 * 1024 else {
            throw CLIExecutionError.invalidOutputLimit
        }

        let collector = CLIOutputCollector(limit: invocation.outputLimit)
        let execution = CLIExecutionState(
            executableURL: executableURL,
            arguments: invocation.arguments,
            environment: childEnvironment(),
            streamLimit: invocation.outputLimit
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
            let didExceedStreamLimit = await execution.streamLimitExceeded

            do {
                await execution.stopReading()
                if Task.isCancelled {
                    await collector.discard()
                    throw CLIExecutionError.cancelled
                }
                if didTimeOut {
                    await collector.discard()
                    throw CLIExecutionError.timedOut
                }
                if didExceedStreamLimit {
                    await collector.discard()
                    throw CLIExecutionError.outputLimitExceeded
                }
                // A child that outlived its readers is treated as a timeout: its
                // output is incomplete, so parsing it would be unsafe.
                if !didDrainCleanly {
                    await collector.discard()
                    throw CLIExecutionError.timedOut
                }
                let captured = try await collector.waitForCompletion()
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
        for await var chunk in chunks {
            let exceeded = await collector.consume(chunk, from: stream)
            if stream == .standardError {
                chunk.resetBytes(in: chunk.startIndex..<chunk.endIndex)
            }
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
            guard chunk.count <= limit - standardOutput.count else {
                failForLimit()
                return true
            }
            standardOutput.append(chunk)
        case .standardError:
            let (sum, overflow) = standardErrorByteCount.addingReportingOverflow(chunk.count)
            standardErrorByteCount = overflow ? Int.max : sum
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

    func discard() {
        standardOutput.resetBytes(in: standardOutput.startIndex..<standardOutput.endIndex)
        standardOutput = Data()
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
        standardOutput.resetBytes(in: standardOutput.startIndex..<standardOutput.endIndex)
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

/// Bounds bytes before they enter an async stream. FileHandle callbacks may
/// outrun actor consumers; applying the limit synchronously here means an
/// unbounded stream can never retain more than one invocation limit per pipe.
/// Standard error gets the same bound even though only its count is retained.
private final class CLIStreamBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var counts: [CLIStream: Int] = [:]
    private var didExceed = false

    init(limit: Int) {
        self.limit = limit
    }

    func admit(_ data: Data, from stream: CLIStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didExceed else { return false }
        let count = counts[stream, default: 0]
        guard data.count <= limit - count else {
            didExceed = true
            return false
        }
        counts[stream] = count + data.count
        return true
    }

    func markExceeded() {
        lock.lock()
        didExceed = true
        lock.unlock()
    }

    var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceed
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
    private let streamBudget: CLIStreamBudget

    private var cancellationRequested = false
    private var deadlineDidExpire = false
    private var terminationStatus: Int32?
    private var terminationWaiter: CheckedContinuation<Int32, Never>?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        streamLimit: Int
    ) {
        streamBudget = CLIStreamBudget(limit: streamLimit)
        let outSequence = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let errSequence = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
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
    var streamLimitExceeded: Bool { streamBudget.exceeded }

    func chunkStreams() -> (standardOutput: AsyncStream<Data>, standardError: AsyncStream<Data>) {
        (standardOutputChunks, standardErrorChunks)
    }

    func start() throws {
        guard !cancellationRequested else {
            throw CancellationError()
        }
        installReadHandler(
            on: standardOutput.fileHandleForReading,
            stream: .standardOutput,
            continuation: standardOutputContinuation
        )
        installReadHandler(
            on: standardError.fileHandleForReading,
            stream: .standardError,
            continuation: standardErrorContinuation
        )

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
        stream: CLIStream,
        continuation: AsyncStream<Data>.Continuation
    ) {
        let budget = streamBudget
        fileHandle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                continuation.finish()
            } else if budget.admit(data, from: stream) {
                switch continuation.yield(data) {
                case .enqueued:
                    break
                case .dropped(var dropped):
                    // Losing any byte makes JSON and stderr accounting
                    // incomplete. Mark the invocation failed and dispose of
                    // the dropped chunk before terminating the producer.
                    dropped.resetBytes(in: dropped.startIndex..<dropped.endIndex)
                    budget.markExceeded()
                    fileHandle.readabilityHandler = nil
                    continuation.finish()
                    Task {
                        _ = await self?.terminateIfRunning(
                            escalatingAfter: CLIProcessExecutor.terminationGracePeriod
                        )
                    }
                case .terminated:
                    break
                @unknown default:
                    budget.markExceeded()
                    fileHandle.readabilityHandler = nil
                    continuation.finish()
                    Task {
                        _ = await self?.terminateIfRunning(
                            escalatingAfter: CLIProcessExecutor.terminationGracePeriod
                        )
                    }
                }
            } else {
                fileHandle.readabilityHandler = nil
                continuation.finish()
                Task {
                    _ = await self?.terminateIfRunning(
                        escalatingAfter: CLIProcessExecutor.terminationGracePeriod
                    )
                }
            }
        }
    }

    private func didTerminate(status: Int32) {
        terminationStatus = status
        terminationWaiter?.resume(returning: status)
        terminationWaiter = nil
    }
}
