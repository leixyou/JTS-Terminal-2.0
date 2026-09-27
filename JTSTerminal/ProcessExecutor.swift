//
//  ProcessExecutor.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import Foundation
import Darwin

nonisolated struct CommandResult: Equatable, Sendable {
    let command: String
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    nonisolated var succeeded: Bool {
        exitCode == 0
    }

    nonisolated var displayText: String {
        let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (output.isEmpty, error.isEmpty) {
        case (false, false):
            return "\(output)\n\n[stderr]\n\(error)"
        case (false, true):
            return output
        case (true, false):
            return error
        case (true, true):
            return succeeded ? "Command completed with no output." : "Command failed with no output."
        }
    }
}

nonisolated enum ProcessExecutorError: LocalizedError, Sendable {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        }
    }
}

nonisolated final class ProcessExecutor: Sendable {
    static let defaultMaximumOutputBytes = 8 * 1_024 * 1_024

    private let maximumOutputBytesPerStream: Int

    init(maximumOutputBytesPerStream: Int = ProcessExecutor.defaultMaximumOutputBytes) {
        self.maximumOutputBytesPerStream = max(maximumOutputBytesPerStream, 1)
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: String? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> CommandResult {
        let cancellationState = ProcessCancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let outputCollector: ProcessPipeCollector
                let errorCollector: ProcessPipeCollector
                do {
                    outputCollector = try ProcessPipeCollector(
                        maximumBytes: maximumOutputBytesPerStream
                    )
                    errorCollector = try ProcessPipeCollector(
                        maximumBytes: maximumOutputBytesPerStream
                    )
                } catch {
                    continuation.resume(
                        throwing: ProcessExecutorError.launchFailed(
                            "无法准备命令输出管道: \(error.localizedDescription)"
                        )
                    )
                    return
                }
                let inputPipe = standardInput == nil ? nil : Pipe()
                let completionState = ProcessCompletionState()
                let command = ([executable] + arguments.map { SSHCommandBuilder.shellQuote($0) }).joined(separator: " ")

                process.executableURL = URL(fileURLWithPath: ProcessLaunchWrapper.executable)
                process.arguments = ProcessLaunchWrapper.arguments(
                    executable: executable,
                    arguments: arguments
                )
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }
                process.standardOutput = outputCollector.pipe
                process.standardError = errorCollector.pipe
                process.standardInput = inputPipe

                process.terminationHandler = { finishedProcess in
                    guard completionState.claimCompletion() else {
                        return
                    }
                    cancellationState.clear()

                    continuation.resume(
                        returning: CommandResult(
                            command: command,
                            exitCode: finishedProcess.terminationStatus,
                            standardOutput: outputCollector.finish(),
                            standardError: errorCollector.finish()
                        )
                    )
                }

                let cancelExecution: @Sendable () -> Void = {
                    guard completionState.claimCompletion() else { return }
                    ProcessTreeTerminator.terminate(process)
                    // Cancellation must not wait behind a busy pipe-drain
                    // queue. Once this completion path is claimed, the
                    // termination handler cannot consume either collector, so
                    // close them asynchronously while the cancelled task
                    // returns immediately.
                    outputCollector.discardAndCloseAsynchronously()
                    errorCollector.discardAndCloseAsynchronously()
                    continuation.resume(throwing: CancellationError())
                }

                do {
                    let didLaunch = try cancellationState.launchUnlessCancelled(
                        launch: { try process.run() },
                        cancellationAction: cancelExecution
                    )
                    guard didLaunch else {
                        cancelExecution()
                        return
                    }

                    if let timeoutSeconds, timeoutSeconds > 0 {
                        completionState.scheduleTimeout(after: timeoutSeconds) {
                            guard completionState.claimCompletion() else { return }
                            cancellationState.clear()

                            ProcessTreeTerminator.terminate(process)
                            let error = errorCollector.finish()
                            continuation.resume(
                                returning: CommandResult(
                                    command: command,
                                    exitCode: 124,
                                    standardOutput: outputCollector.finish(),
                                    standardError: [error, "Process timed out."].filter { !$0.isEmpty }.joined(separator: "\n")
                                )
                            )
                        }
                    }

                    guard !cancellationState.isCancelled else { return }
                    if let standardInput,
                       let inputPipe,
                       let data = standardInput.data(using: .utf8) {
                        inputPipe.fileHandleForWriting.write(data)
                        inputPipe.fileHandleForWriting.closeFile()
                    }
                } catch {
                    cancellationState.clear()
                    guard completionState.claimCompletion() else {
                        return
                    }
                    _ = outputCollector.finish()
                    _ = errorCollector.finish()
                    continuation.resume(
                        throwing: ProcessExecutorError.launchFailed("无法启动 \(executable): \(error.localizedDescription)")
                    )
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }
}

/// Foundation.Process does not expose posix_spawn process-group attributes.
/// This shell only forwards an argv array (never interpolated command text),
/// starts that argv in an isolated job group, and owns timeout cleanup for the
/// complete group even when the sandbox prevents libproc child enumeration.
nonisolated private enum ProcessLaunchWrapper {
    static let executable = "/bin/sh"
    private static let script = """
    set -m
    "$@" &
    child=$!
    set +m
    trap 'kill -TERM -"$child" 2>/dev/null; kill -KILL -"$child" 2>/dev/null; exit 124' TERM INT
    wait "$child"
    status=$?
    exit "$status"
    """

    static func arguments(executable: String, arguments: [String]) -> [String] {
        ["-c", script, "jts-process-wrapper", executable] + arguments
    }
}

nonisolated private final class ProcessCompletionState: @unchecked Sendable {
    private let timeoutQueue = DispatchQueue(
        label: "com.jtstools.JTSTerminal.ProcessExecutorTimeout.\(UUID().uuidString)",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var hasCompleted = false
    private var timeoutTimer: DispatchSourceTimer?

    func scheduleTimeout(
        after timeoutSeconds: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: timeoutQueue)
        timer.setEventHandler(handler: action)
        timer.schedule(deadline: .now() + timeoutSeconds)

        lock.lock()
        let shouldSchedule = !hasCompleted
        if shouldSchedule {
            timeoutTimer = timer
        }
        lock.unlock()

        if !shouldSchedule {
            timer.setEventHandler {}
            timer.cancel()
        }
        // Dispatch sources must be resumed even when cancelled while suspended.
        timer.resume()
    }

    func claimCompletion() -> Bool {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return false
        }

        hasCompleted = true
        let timer = timeoutTimer
        timeoutTimer = nil
        lock.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
        return true
    }
}

/// Serializes process launch with task cancellation. Holding the lock across
/// `Process.run()` closes the narrow race where cancellation could otherwise
/// arrive after the preflight check but before the child PID existed.
nonisolated private final class ProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationAction: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func launchUnlessCancelled(
        launch: () throws -> Void,
        cancellationAction: @escaping @Sendable () -> Void
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }

        try launch()
        self.cancellationAction = cancellationAction
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = cancellationAction
        cancellationAction = nil
        lock.unlock()
        action?()
    }

    func clear() {
        lock.lock()
        cancellationAction = nil
        lock.unlock()
    }
}

/// Continuously drains a child-process pipe so neither a verbose command nor a
/// descendant holding the pipe open can deadlock ProcessExecutor completion.
nonisolated final class ProcessPipeCollector: @unchecked Sendable {
    let pipe = Pipe()

    private static let maximumEventReadOperations = 64
    private static let defaultFinalReadOperationLimit = 512

    private let queue = DispatchQueue(
        label: "com.jtstools.JTSTerminal.ProcessPipeCollector.\(UUID().uuidString)",
        qos: .userInitiated
    )
    private let source: DispatchSourceRead
    private let stopLock = NSLock()
    private let maximumBytes: Int
    private let finalReadOperationLimit: Int
    private var data = Data()
    private var discardedByteCount = 0
    private var didExhaustFinalReadBudget = false
    private var terminalReadErrorNumber: Int32?
    private var hasFinished = false
    private var stopRequested = false

    init(
        maximumBytes: Int,
        finalReadOperationLimit: Int =
            ProcessPipeCollector.defaultFinalReadOperationLimit,
        onReadSourceCancelled: (@Sendable () -> Void)? = nil
    ) throws {
        self.maximumBytes = max(maximumBytes, 1)
        self.finalReadOperationLimit = max(finalReadOperationLimit, 0)
        let readHandle = pipe.fileHandleForReading
        let descriptor = readHandle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            throw Self.currentPOSIXError()
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Self.currentPOSIXError()
        }

        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            _ = self?.drainAvailableData()
        }
        // A dispatch source may still have a handler pending after cancel().
        // Keeping the descriptor open until the cancel handler runs prevents
        // a newly opened file from reusing the number while that old handler
        // can still observe it.
        source.setCancelHandler {
            readHandle.closeFile()
            onReadSourceCancelled?()
        }
        source.resume()
    }

    deinit {
        source.setEventHandler {}
        source.cancel()
    }

    func finish() -> String {
        requestStop()
        return queue.sync {
            finishLocked()
            return collectedText()
        }
    }

    func discardAndCloseAsynchronously() {
        requestStop()
        queue.async { [self] in
            guard !hasFinished else { return }
            hasFinished = true
            source.cancel()
        }
    }

    private func finishLocked() {
        guard !hasFinished else { return }
        didExhaustFinalReadBudget = drainAvailableData(
            ignoringStopRequest: true,
            maximumReadOperations: finalReadOperationLimit
        )
        hasFinished = true
        source.cancel()
    }

    private func drainAvailableData(
        ignoringStopRequest: Bool = false,
        maximumReadOperations: Int = ProcessPipeCollector.maximumEventReadOperations
    ) -> Bool {
        guard !hasFinished else { return false }

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var readOperations = 0
        while readOperations < maximumReadOperations {
            if !ignoringStopRequest, isStopRequested {
                return false
            }
            readOperations += 1
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let remainingCapacity = maximumBytes - data.count
                if remainingCapacity > 0 {
                    let retainedCount = min(count, remainingCapacity)
                    data.append(contentsOf: buffer.prefix(retainedCount))
                    discardedByteCount += count - retainedCount
                } else {
                    // Keep draining after the retention limit so a verbose
                    // child can never block on a full pipe.
                    discardedByteCount += count
                }
                continue
            }
            if count == 0 {
                finishAfterTerminalRead()
                return false
            }
            if errno == EINTR {
                continue
            }
            if errno != EAGAIN, errno != EWOULDBLOCK {
                finishAfterTerminalRead(errorNumber: errno)
            }
            return false
        }
        return true
    }

    /// EOF is level-triggered for a dispatch read source. Cancelling it here
    /// prevents a child that closes stdout/stderr before exiting from spinning
    /// this queue indefinitely on repeated zero-byte reads.
    private func finishAfterTerminalRead(errorNumber: Int32? = nil) {
        guard !hasFinished else { return }
        terminalReadErrorNumber = errorNumber
        hasFinished = true
        source.cancel()
    }

    private var isStopRequested: Bool {
        stopLock.withLock { stopRequested }
    }

    private func requestStop() {
        stopLock.withLock {
            stopRequested = true
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func collectedText() -> String {
        let output = String(decoding: data, as: UTF8.self)
        var notices: [String] = []
        if discardedByteCount > 0 {
            notices.append(
                "[output truncated after \(maximumBytes) bytes; discarded at least \(discardedByteCount) bytes]"
            )
        }
        if didExhaustFinalReadBudget {
            notices.append(
                "[output collection stopped after the bounded final drain; additional bytes may have been discarded]"
            )
        }
        if let terminalReadErrorNumber {
            notices.append(
                "[output collection stopped after pipe read error \(terminalReadErrorNumber)]"
            )
        }
        guard !notices.isEmpty else { return output }

        let separator = output.isEmpty || output.hasSuffix("\n") ? "" : "\n"
        return output
            + separator
            + notices.joined(separator: "\n")
    }
}

/// Terminates only the process tree rooted at the Process launched above. A
/// hard kill is appropriate for descendants after the command exceeded its
/// deadline; it also releases inherited stdout/stderr descriptors held by a
/// stuck askpass helper.
nonisolated private enum ProcessTreeTerminator {
    static func terminate(_ process: Process) {
        let rootPID = process.processIdentifier
        guard rootPID > 0 else { return }

        for descendantPID in descendantProcessIdentifiers(of: rootPID).reversed() {
            _ = Darwin.kill(descendantPID, SIGKILL)
        }
        _ = Darwin.kill(rootPID, SIGTERM)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [process] in
            guard process.isRunning else { return }
            for descendantPID in descendantProcessIdentifiers(of: rootPID).reversed() {
                _ = Darwin.kill(descendantPID, SIGKILL)
            }
            _ = Darwin.kill(rootPID, SIGKILL)
        }
    }

    private static func descendantProcessIdentifiers(of rootPID: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var visited: Set<pid_t> = [rootPID]
        var pending = [rootPID]

        while let parentPID = pending.popLast() {
            for childPID in directChildProcessIdentifiers(of: parentPID)
            where childPID > 0 && visited.insert(childPID).inserted {
                result.append(childPID)
                pending.append(childPID)
            }
        }

        return result
    }

    private static func directChildProcessIdentifiers(of parentPID: pid_t) -> [pid_t] {
        // With a nil buffer libproc returns the required byte capacity; with a
        // real pid_t buffer it returns the number of PIDs written.
        let requiredBytes = proc_listchildpids(parentPID, nil, 0)
        guard requiredBytes > 0 else { return [] }

        let capacity = max(Int(requiredBytes) / MemoryLayout<pid_t>.stride, 1)
        var processIdentifiers = [pid_t](repeating: 0, count: capacity)
        let count = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parentPID, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(processIdentifiers.prefix(min(Int(count), processIdentifiers.count)))
    }
}
