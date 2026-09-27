//
//  OrderedPTYProcess.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/28.
//

#if os(macOS) && canImport(SwiftTerm)
import Darwin
import Dispatch
import Foundation
import SwiftTerm

protocol OrderedPTYProcessDelegate: AnyObject {
    func processTerminated(_ source: OrderedPTYProcess, exitCode: Int32?)
    func dataReceived(slice: ArraySlice<UInt8>)
    func getWindowSize() -> winsize
}

enum OrderedPTYProcessEvent: Equatable {
    case output([UInt8])
    case termination(Int32?)
}

/// Serializes PTY output and process-exit observations into the only ordering
/// that is safe for terminal consumers: every byte accepted before read EOF is
/// delivered before the single termination callback.
struct OrderedPTYEventBuffer {
    private var pendingOutput: [[UInt8]] = []
    private var outputIndex = 0
    private var sawReadEOF = false
    private var sawProcessExit = false
    private var exitStatus: Int32?
    private var deliveredTermination = false
    private var isCancelled = false

    var needsDrain: Bool {
        guard !isCancelled else { return false }
        return outputIndex < pendingOutput.count
            || (sawReadEOF && sawProcessExit && !deliveredTermination)
    }

    mutating func appendOutput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty,
              !sawReadEOF,
              !deliveredTermination,
              !isCancelled else {
            return
        }
        pendingOutput.append(bytes)
    }

    mutating func recordReadEOF() {
        guard !isCancelled else { return }
        sawReadEOF = true
    }

    mutating func recordProcessExit(status: Int32?) {
        guard !isCancelled, !sawProcessExit else { return }
        sawProcessExit = true
        exitStatus = status
    }

    mutating func cancel() {
        _ = cancelAndTakePendingOutput()
    }

    mutating func cancelAndTakePendingOutput() -> [[UInt8]] {
        guard !isCancelled else { return [] }
        let acceptedOutput = Array(pendingOutput.dropFirst(outputIndex))
        isCancelled = true
        pendingOutput.removeAll(keepingCapacity: false)
        outputIndex = 0
        return acceptedOutput
    }

    mutating func drain(maximumOutputChunks: Int = .max) -> [OrderedPTYProcessEvent] {
        guard !isCancelled else { return [] }
        let limit = max(0, maximumOutputChunks)
        var events: [OrderedPTYProcessEvent] = []
        var deliveredChunks = 0

        while outputIndex < pendingOutput.count, deliveredChunks < limit {
            events.append(.output(pendingOutput[outputIndex]))
            outputIndex += 1
            deliveredChunks += 1
        }

        if outputIndex == pendingOutput.count {
            pendingOutput.removeAll(keepingCapacity: true)
            outputIndex = 0
            if sawReadEOF, sawProcessExit, !deliveredTermination {
                deliveredTermination = true
                events.append(.termination(exitStatus))
            }
        }
        return events
    }
}

/// A focused local PTY runner used with SwiftTerm's public PTY helper.
///
/// SwiftTerm 1.13 can notify `processTerminated` before output already accepted
/// by its read queue reaches the delegate. This runner retains the same forkpty
/// foundation while making EOF-and-drain ordering explicit. Its lifecycle is
/// intentionally local to JTS Terminal so a dependency update cannot silently
/// reintroduce the authentication/reconnect race.
final class OrderedPTYProcess {
    private static let maximumChunksPerDrain = 32
    private static let terminationGracePollCount = 25
    private static let terminationGracePollIntervalMicroseconds: useconds_t = 2_000
    private static let reaperQueue = DispatchQueue(
        label: "com.lljts.JTSTerminal.ordered-pty-reaper",
        // Child reaping is part of an interactive stop/deinit operation.
        // Utility work can be deferred long enough for exited children to
        // remain zombies while a busy test host or app is doing other work.
        qos: .userInitiated,
        attributes: .concurrent
    )

    private weak var delegate: OrderedPTYProcessDelegate?
    private let deliveryQueue: DispatchQueue
    private let readQueue = DispatchQueue(
        label: "com.lljts.JTSTerminal.ordered-pty-read",
        qos: .userInitiated
    )
    private let writeQueue = DispatchQueue(
        label: "com.lljts.JTSTerminal.ordered-pty-write",
        qos: .userInitiated
    )
    private let lock = NSLock()

    private var eventBuffer = OrderedPTYEventBuffer()
    private var drainScheduled = false
    private var io: DispatchIO?
    private var channelCleanup: DispatchSemaphore?
    private var childMonitor: DispatchSourceProcess?
    private var controlFileDescriptor: Int32 = -1
    private var childLifecycle: ChildLifecycle?
    private var _shellPid: pid_t = 0
    private var _running = false
    private var isStopping = false
    private var isCancelled = false

    var shellPid: pid_t {
        lock.withLock { _shellPid }
    }

    var running: Bool {
        lock.withLock { _running }
    }

    init(
        delegate: OrderedPTYProcessDelegate,
        dispatchQueue: DispatchQueue = .main
    ) {
        self.delegate = delegate
        self.deliveryQueue = dispatchQueue
    }

    deinit {
        _ = cancelResources(sendSignal: true)
    }

    func startProcess(
        executable: String,
        args: [String],
        environment: [String],
        currentDirectory: String? = nil,
        configureBeforeIO: (_ masterFileDescriptor: Int32, _ childPID: pid_t) throws -> Void
    ) throws {
        guard !running else {
            throw OrderedPTYProcessError.alreadyRunning
        }
        var size = delegate?.getWindowSize() ?? winsize()
        var processArguments = args
        processArguments.insert(executable, at: 0)

        guard let launch = PseudoTerminalHelpers.fork(
            andExec: executable,
            args: processArguments,
            env: environment,
            currentDirectory: currentDirectory,
            desiredWindowSize: &size
        ) else {
            throw OrderedPTYProcessError.launchFailed
        }

        let descriptor = launch.masterFd
        let lifecycle = ChildLifecycle(pid: launch.pid)
        do {
            try configureBeforeIO(descriptor, launch.pid)
        } catch {
            Darwin.close(descriptor)
            Self.requestTerminationAndReap(lifecycle)
            throw error
        }

        let controlDescriptor = Darwin.dup(descriptor)
        guard controlDescriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            Self.requestTerminationAndReap(lifecycle)
            throw OrderedPTYProcessError.controlDescriptorFailed(reason)
        }
        let controlFlags = Darwin.fcntl(controlDescriptor, F_GETFD)
        guard controlFlags >= 0,
              Darwin.fcntl(
                controlDescriptor,
                F_SETFD,
                controlFlags | FD_CLOEXEC
              ) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(controlDescriptor)
            Darwin.close(descriptor)
            Self.requestTerminationAndReap(lifecycle)
            throw OrderedPTYProcessError.controlDescriptorFailed(reason)
        }

        let monitor = DispatchSource.makeProcessSource(
            identifier: launch.pid,
            eventMask: .exit,
            queue: deliveryQueue
        )
        let cleanup = DispatchSemaphore(value: 0)
        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: readQueue
        ) { _ in
            Darwin.close(descriptor)
            cleanup.signal()
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 128 * 1024)

        lock.withLock {
            eventBuffer = OrderedPTYEventBuffer()
            drainScheduled = false
            io = channel
            channelCleanup = cleanup
            childMonitor = monitor
            self.controlFileDescriptor = controlDescriptor
            childLifecycle = lifecycle
            _shellPid = launch.pid
            _running = true
            isStopping = false
            isCancelled = false
        }

        monitor.setEventHandler { [weak self] in
            self?.processExitObserved()
        }
        monitor.activate()
        scheduleRead(on: channel)
    }

    func send(data: ArraySlice<UInt8>) {
        let channel = lock.withLock {
            _running && !isCancelled ? io : nil
        }
        guard let channel else { return }
        data.withUnsafeBytes { bytes in
            let dispatchData = DispatchData(bytes: bytes)
            channel.write(
                offset: 0,
                data: dispatchData,
                queue: writeQueue
            ) { _, _, _ in }
        }
    }

    func updateWindowSize(_ size: inout winsize) {
        lock.lock()
        defer { lock.unlock() }
        guard _running,
              !isStopping,
              !isCancelled,
              controlFileDescriptor >= 0,
              _shellPid > 0 else {
            return
        }
        if PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: controlFileDescriptor,
            windowSize: &size
        ) == 0 {
            // The process cannot be reaped or its PID reused while the
            // normal-exit observer is waiting for this same state lock.
            _ = Darwin.kill(_shellPid, SIGWINCH)
        }
    }

    /// Stops the child and returns output already buffered but not yet
    /// delivered. Explicit stop is a bounded cancellation path: it gives the
    /// read queue up to one second to finish before returning the buffered
    /// chunks through the adapter's UTF-8 and launch-gate filters.
    func terminate() -> [[UInt8]] {
        cancelResources(sendSignal: true)
    }

    private func scheduleRead(on channel: DispatchIO) {
        channel.read(
            offset: 0,
            // One long-lived stream operation keeps `done` reserved for the
            // actual end of this DispatchIO read. A finite requested length
            // would also report `done` after satisfying that byte count even
            // while the PTY remains open.
            length: Int.max,
            queue: readQueue
        ) { [weak self, weak channel] done, data, error in
            guard let self, let channel else { return }
            self.handleRead(done: done, data: data, error: error, channel: channel)
        }
    }

    private func handleRead(
        done: Bool,
        data: DispatchData?,
        error: Int32,
        channel: DispatchIO
    ) {
        let isActiveChannel = lock.withLock {
            !isCancelled && io === channel
        }
        guard isActiveChannel else { return }

        let bytes = data.flatMap { dispatchData -> [UInt8]? in
            guard !dispatchData.isEmpty else { return nil }
            return Array(dispatchData)
        }
        if let bytes {
            enqueueOutput(bytes)
        }

        if done || error != 0 {
            recordReadEOF(channel: channel)
        }
    }

    private func enqueueOutput(_ bytes: [UInt8]) {
        let shouldSchedule = lock.withLock {
            guard !isCancelled else { return false }
            eventBuffer.appendOutput(bytes)
            return markDrainScheduledIfNeeded()
        }
        if shouldSchedule {
            scheduleDrain()
        }
    }

    private func recordReadEOF(channel: DispatchIO) {
        let result: (Bool, Bool, Int32) = lock.withLock {
            guard !isCancelled, io === channel else {
                return (false, false, -1)
            }
            eventBuffer.recordReadEOF()
            io = nil
            channelCleanup = nil
            let descriptor = controlFileDescriptor
            controlFileDescriptor = -1
            return (markDrainScheduledIfNeeded(), true, descriptor)
        }
        if result.1 {
            channel.close()
        }
        if result.2 >= 0 {
            Darwin.close(result.2)
        }
        if result.0 {
            scheduleDrain()
        }
    }

    private func processExitObserved() {
        let captured: (ChildLifecycle?, DispatchSourceProcess?) = lock.withLock {
            let monitor = childMonitor
            childMonitor = nil
            _running = false
            return (childLifecycle, monitor)
        }
        captured.1?.cancel()
        guard let lifecycle = captured.0 else {
            recordProcessExit(status: nil)
            return
        }
        guard lifecycle.claimReaper() else { return }

        // NOTE_EXIT is delivered only after the child has exited. Reap it
        // inline so a busy global queue cannot leave a zombie between the
        // kernel notification and the terminal callback. waitpid cannot block
        // here because the process source has already observed termination.
        let status = Self.waitForChild(lifecycle.pid)
        lifecycle.markReaped()
        recordProcessExit(status: status)
    }

    private func recordProcessExit(status: Int32?) {
        let shouldSchedule = lock.withLock {
            guard !isCancelled else { return false }
            childLifecycle = nil
            _shellPid = 0
            eventBuffer.recordProcessExit(status: status)
            return markDrainScheduledIfNeeded()
        }
        if shouldSchedule {
            scheduleDrain()
        }
    }

    private func markDrainScheduledIfNeeded() -> Bool {
        guard eventBuffer.needsDrain, !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    private func scheduleDrain() {
        deliveryQueue.async { [weak self] in
            self?.drainEvents()
        }
    }

    private func drainEvents() {
        let result: ([OrderedPTYProcessEvent], Bool) = lock.withLock {
            guard !isCancelled else {
                drainScheduled = false
                return ([], false)
            }
            let events = eventBuffer.drain(
                maximumOutputChunks: Self.maximumChunksPerDrain
            )
            let shouldContinue = eventBuffer.needsDrain
            if !shouldContinue {
                drainScheduled = false
            }
            return (events, shouldContinue)
        }

        for event in result.0 {
            switch event {
            case .output(let bytes):
                delegate?.dataReceived(slice: bytes[...])
            case .termination(let status):
                delegate?.processTerminated(self, exitCode: status)
            }
        }
        if result.1 {
            scheduleDrain()
        }
    }

    private func cancelResources(sendSignal: Bool) -> [[UInt8]] {
        let closing: (
            DispatchIO?,
            DispatchSemaphore?,
            DispatchSourceProcess?,
            ChildLifecycle?,
            Bool
        ) = lock.withLock {
            guard !isCancelled, !isStopping else {
                return (nil, nil, nil, nil, false)
            }
            isStopping = true
            _running = false
            let resources = (
                io,
                channelCleanup,
                childMonitor,
                childLifecycle,
                true
            )
            childMonitor = nil
            return resources
        }
        guard closing.4 else { return [] }

        closing.2?.cancel()

        // Claim the PID and deliver SIGTERM before waiting for DispatchIO
        // cleanup. The previous order could spend the entire one-second I/O
        // deadline before asking the child to exit, then enqueue waitpid at
        // utility QoS. Under load this left an already released session's
        // child visible as a zombie for seconds.
        let terminationLifecycle: ChildLifecycle?
        if sendSignal,
           let lifecycle = closing.3,
           Self.beginTermination(lifecycle) {
            terminationLifecycle = lifecycle
        } else {
            terminationLifecycle = nil
        }

        closing.0?.close(flags: .stop)
        if closing.0 != nil, let cleanup = closing.1 {
            // DispatchIO invokes its cleanup only after all outstanding I/O
            // handlers on the private read queue finish. `terminate()` may be
            // called by the MainActor, so keep this wait bounded; after the
            // deadline, explicit stop remains cancellation and may discard
            // bytes that the read handler has not buffered yet.
            _ = cleanup.wait(timeout: .now() + .seconds(1))
        }

        let captured: (
            Int32,
            ChildLifecycle?,
            [[UInt8]]
        ) = lock.withLock {
            guard !isCancelled else { return (-1, nil, []) }
            isCancelled = true
            isStopping = false
            let pendingOutput = eventBuffer.cancelAndTakePendingOutput()
            drainScheduled = false
            let resources = (
                controlFileDescriptor,
                closing.3 ?? childLifecycle,
                pendingOutput
            )
            io = nil
            channelCleanup = nil
            childMonitor = nil
            controlFileDescriptor = -1
            childLifecycle = nil
            _shellPid = 0
            _running = false
            return resources
        }

        if captured.0 >= 0 {
            Darwin.close(captured.0)
        }
        if let terminationLifecycle {
            // The I/O shutdown interval also serves as the child's graceful
            // termination window. Reap synchronously when it has already
            // exited; only a still-running child needs the background poll
            // and bounded SIGKILL fallback.
            Self.reapAfterTerminationRequest(terminationLifecycle)
        } else if sendSignal,
                  let lifecycle = captured.1,
                  !lifecycle.isReaped {
            // A lifecycle captured after the first state snapshot is unusual
            // but still must not escape without a unique waitpid owner.
            Self.requestTerminationAndReap(lifecycle)
        }
        return captured.2
    }

    private static func requestTerminationAndReap(_ lifecycle: ChildLifecycle) {
        guard beginTermination(lifecycle) else { return }
        reapAfterTerminationRequest(lifecycle)
    }

    private static func beginTermination(_ lifecycle: ChildLifecycle) -> Bool {
        guard lifecycle.pid > 0, !lifecycle.isReaped else { return false }
        // Only the unique waitpid owner may signal this numeric PID. If the
        // normal-exit path already claimed it, the child has exited and no
        // signal is needed; avoiding a check-then-kill closes the PID-reuse
        // window between waitpid and markReaped.
        guard lifecycle.claimReaper() else { return false }
        _ = Darwin.kill(lifecycle.pid, SIGTERM)
        return true
    }

    private static func reapAfterTerminationRequest(_ lifecycle: ChildLifecycle) {
        // Give a normal SIGTERM a short, strictly bounded chance to complete
        // on the caller. This keeps the common stop/deinit path deterministic
        // without turning an uncooperative child into a main-thread stall.
        for poll in 0..<terminationGracePollCount {
            if reapExitedChildIfAvailable(lifecycle) {
                return
            }
            if poll + 1 < terminationGracePollCount {
                _ = Darwin.usleep(terminationGracePollIntervalMicroseconds)
            }
        }

        reaperQueue.async {
            var status: Int32 = 0
            for _ in 0..<100 {
                let result = Darwin.waitpid(lifecycle.pid, &status, WNOHANG)
                if result == lifecycle.pid
                    || (result < 0 && errno == ECHILD) {
                    lifecycle.markReaped()
                    return
                }
                if result < 0, errno == EINTR {
                    continue
                }
                if result < 0 {
                    lifecycle.markReaped()
                    return
                }
                _ = Darwin.usleep(10_000)
            }

            _ = Darwin.kill(lifecycle.pid, SIGKILL)
            _ = waitForChild(lifecycle.pid)
            lifecycle.markReaped()
        }
    }

    private static func reapExitedChildIfAvailable(_ lifecycle: ChildLifecycle) -> Bool {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(lifecycle.pid, &status, WNOHANG)
            if result == lifecycle.pid
                || (result < 0 && errno == ECHILD) {
                lifecycle.markReaped()
                return true
            }
            if result < 0, errno == EINTR {
                continue
            }
            if result < 0 {
                lifecycle.markReaped()
                return true
            }
            return false
        }
    }

    private static func waitForChild(_ processID: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = Darwin.waitpid(processID, &status, 0)
        } while result < 0 && errno == EINTR
        return result == processID ? status : nil
    }

    private final class ChildLifecycle: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var reaperClaimed = false
        private var reaped = false

        init(pid: pid_t) {
            self.pid = pid
        }

        var isReaped: Bool {
            lock.withLock { reaped }
        }

        func claimReaper() -> Bool {
            lock.withLock {
                guard !reaperClaimed else { return false }
                reaperClaimed = true
                return true
            }
        }

        func markReaped() {
            lock.withLock {
                reaped = true
            }
        }
    }
}

private enum OrderedPTYProcessError: LocalizedError {
    case alreadyRunning
    case launchFailed
    case controlDescriptorFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The PTY process is already running."
        case .launchFailed:
            return "The ordered PTY process could not be launched."
        case .controlDescriptorFailed(let reason):
            return "Could not create the dedicated PTY control descriptor: \(reason)."
        }
    }
}
#endif
