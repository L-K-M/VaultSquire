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
        guard outputLimit > 0 else {
            throw ProcessProbeError.invalidOutputLimit
        }

        let output = ProcessProbeOutput(limit: outputLimit)
        let execution = ProcessProbeExecution(
            executableURL: executableURL,
            arguments: arguments,
            environment: Self.allowedEnvironment,
            output: output
        )

        PerformanceTrace.record(.processProbeStarted)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            do {
                try await execution.start()
            } catch {
                await execution.stopReading()
                throw error
            }

            let timeoutTask = Task {
                try await Task.sleep(for: timeout)
                return await execution.terminateForTimeout()
            }

            let exitStatus = await execution.waitForTermination()
            timeoutTask.cancel()
            let didTimeOut = (try? await timeoutTask.value) ?? false

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
    private let output: ProcessProbeOutput

    private var cancellationRequested = false
    private var terminationStatus: Int32?
    private var terminationWaiter: CheckedContinuation<Int32, Never>?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        output: ProcessProbeOutput
    ) {
        self.output = output
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    func start() throws {
        guard !cancellationRequested else {
            throw CancellationError()
        }

        installReadHandler(
            on: standardOutput.fileHandleForReading,
            stream: .standardOutput
        )
        installReadHandler(
            on: standardError.fileHandleForReading,
            stream: .standardError
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

    func terminateForTimeout() -> Bool {
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
        process.terminationHandler = nil
    }

    private func installReadHandler(
        on fileHandle: FileHandle,
        stream: ProcessProbeStream
    ) {
        fileHandle.readabilityHandler = { [weak self, output] fileHandle in
            let byteCount = fileHandle.availableData.count
            Task {
                let exceededLimit = await output.consume(
                    byteCount: byteCount,
                    from: stream
                )
                if exceededLimit {
                    _ = await self?.terminateForTimeout()
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
