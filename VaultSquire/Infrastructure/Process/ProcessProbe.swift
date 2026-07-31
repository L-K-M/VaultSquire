import Foundation

struct ProcessProbeResult: Equatable, Sendable {
    let exitStatus: Int32
    let standardOutputBytes: Int
    let standardErrorBytes: Int
}

enum ProcessProbeError: Error, Equatable, Sendable {
    case executableMustBeAbsolute
    case invalidOutputLimit
    case outputLimitExceeded
    case timedOut
}

actor ProcessProbe {
    static let maximumOutputLimit = 1024 * 1024
    static let allowedEnvironment = [
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin"
    ]

    func run(
        executableURL: URL,
        arguments: [String] = [],
        timeout: Duration = .seconds(5),
        outputLimit: Int = 64 * 1024
    ) async throws -> ProcessProbeResult {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/") else {
            throw ProcessProbeError.executableMustBeAbsolute
        }
        guard outputLimit > 0, outputLimit <= Self.maximumOutputLimit else {
            throw ProcessProbeError.invalidOutputLimit
        }

        let output = ProcessProbeOutput(limit: outputLimit)
        let execution = ProcessProbeExecution(
            executableURL: executableURL,
            arguments: arguments,
            environment: Self.allowedEnvironment,
            outputLimit: outputLimit
        )
        let streams = await execution.byteCountStreams()
        let standardOutputTask = Task {
            await Self.drain(
                streams.standardOutput,
                from: .standardOutput,
                into: output,
                execution: execution
            )
        }
        let standardErrorTask = Task {
            await Self.drain(
                streams.standardError,
                from: .standardError,
                into: output,
                execution: execution
            )
        }

        PerformanceTrace.record(.processProbeStarted)

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await execution.start()
            } catch {
                await execution.stopReading()
                await standardOutputTask.value
                await standardErrorTask.value
                throw error
            }

            let timeoutTask = Task {
                try await Task.sleep(for: timeout)
                return await execution.terminateIfRunning()
            }

            let exitStatus = await execution.waitForTermination()
            timeoutTask.cancel()
            let didTimeOut = (try? await timeoutTask.value) ?? false
            await standardOutputTask.value
            await standardErrorTask.value

            do {
                let byteCounts = try await output.waitForCompletion()
                await execution.stopReading()

                try Task.checkCancellation()
                if didTimeOut {
                    throw ProcessProbeError.timedOut
                }

                PerformanceTrace.record(.processProbeFinished)
                return ProcessProbeResult(
                    exitStatus: exitStatus,
                    standardOutputBytes: byteCounts.standardOutput,
                    standardErrorBytes: byteCounts.standardError
                )
            } catch {
                await execution.stopReading()
                throw error
            }
        } onCancel: {
            Task {
                await execution.cancel()
            }
        }
    }

    private nonisolated static func drain(
        _ byteCounts: AsyncStream<Int>,
        from stream: ProcessProbeStream,
        into output: ProcessProbeOutput,
        execution: ProcessProbeExecution
    ) async {
        for await byteCount in byteCounts {
            let exceededLimit = await output.consume(
                byteCount: byteCount,
                from: stream
            )
            if exceededLimit {
                _ = await execution.terminateIfRunning()
            }
        }

        _ = await output.consume(byteCount: 0, from: stream)
    }
}

private enum ProcessProbeStream: Hashable, Sendable {
    case standardError
    case standardOutput
}

private actor ProcessProbeOutput {
    typealias ByteCounts = (standardOutput: Int, standardError: Int)

    private let limit: Int
    private var standardOutputBytes = 0
    private var standardErrorBytes = 0
    private var closedStreams = Set<ProcessProbeStream>()
    private var terminalError: ProcessProbeError?
    private var waiter: CheckedContinuation<ByteCounts, any Error>?

    init(limit: Int) {
        self.limit = limit
    }

    func consume(byteCount: Int, from stream: ProcessProbeStream) -> Bool {
        guard terminalError == nil, !closedStreams.contains(stream) else {
            return false
        }

        guard byteCount > 0 else {
            closedStreams.insert(stream)
            resumeWaiterIfComplete()
            return false
        }

        switch stream {
        case .standardOutput:
            standardOutputBytes += byteCount
            if standardOutputBytes > limit {
                failForOutputLimit()
                return true
            }
        case .standardError:
            standardErrorBytes += byteCount
            if standardErrorBytes > limit {
                failForOutputLimit()
                return true
            }
        }

        return false
    }

    func waitForCompletion() async throws -> ByteCounts {
        if let terminalError {
            throw terminalError
        }
        if closedStreams.count == 2 {
            return (standardOutputBytes, standardErrorBytes)
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    private func failForOutputLimit() {
        terminalError = .outputLimitExceeded
        waiter?.resume(throwing: ProcessProbeError.outputLimitExceeded)
        waiter = nil
    }

    private func resumeWaiterIfComplete() {
        guard closedStreams.count == 2, let waiter else {
            return
        }

        waiter.resume(returning: (standardOutputBytes, standardErrorBytes))
        self.waiter = nil
    }
}

private actor ProcessProbeExecution {
    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let standardOutputBytes: AsyncStream<Int>
    private let standardErrorBytes: AsyncStream<Int>
    private let standardOutputContinuation: AsyncStream<Int>.Continuation
    private let standardErrorContinuation: AsyncStream<Int>.Continuation

    private var cancellationRequested = false
    private var terminationStatus: Int32?
    private var terminationWaiter: CheckedContinuation<Int32, Never>?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        outputLimit: Int
    ) {
        let standardOutputSequence = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingOldest(outputLimit + 1)
        )
        let standardErrorSequence = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingOldest(outputLimit + 1)
        )
        standardOutputBytes = standardOutputSequence.stream
        standardErrorBytes = standardErrorSequence.stream
        standardOutputContinuation = standardOutputSequence.continuation
        standardErrorContinuation = standardErrorSequence.continuation

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    func byteCountStreams() -> (
        standardOutput: AsyncStream<Int>,
        standardError: AsyncStream<Int>
    ) {
        (standardOutputBytes, standardErrorBytes)
    }

    func start() throws {
        guard !cancellationRequested else {
            throw CancellationError()
        }

        installReadHandler(
            on: standardOutput.fileHandleForReading,
            continuation: standardOutputContinuation
        )
        installReadHandler(
            on: standardError.fileHandleForReading,
            continuation: standardErrorContinuation
        )

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task {
                await self?.didTerminate(status: status)
            }
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

    func terminateIfRunning() -> Bool {
        guard process.isRunning else {
            return false
        }

        process.terminate()
        return true
    }

    func cancel() {
        cancellationRequested = true
        if process.isRunning {
            process.terminate()
        }
    }

    func stopReading() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        standardOutputContinuation.finish()
        standardErrorContinuation.finish()
        process.terminationHandler = nil
    }

    private func installReadHandler(
        on fileHandle: FileHandle,
        continuation: AsyncStream<Int>.Continuation
    ) {
        fileHandle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data.count)
            }
        }
    }

    private func didTerminate(status: Int32) {
        terminationStatus = status
        terminationWaiter?.resume(returning: status)
        terminationWaiter = nil
    }
}
