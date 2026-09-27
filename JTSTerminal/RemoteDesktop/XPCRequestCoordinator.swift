#if ENABLE_RDP_2
import Foundation

nonisolated protocol XPCRequestDeadlineToken: AnyObject, Sendable {
    func cancel()
}

nonisolated protocol XPCRequestDeadlineScheduling: Sendable {
    func schedule(
        after delaySeconds: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any XPCRequestDeadlineToken
}

nonisolated struct XPCRequestTimeoutFailure: LocalizedError, Sendable, Equatable {
    static let errorCode = "RDP_XPC_REQUEST_TIMEOUT"

    let deadlineSeconds: TimeInterval

    var code: String { Self.errorCode }

    var errorDescription: String? {
        "\(code): The FreeRDP XPC request did not reply within \(deadlineSeconds) seconds."
    }
}

nonisolated private final class DispatchXPCRequestDeadlineToken: XPCRequestDeadlineToken, @unchecked Sendable {
    private enum State {
        case active
        case cancelled
        case fired
    }

    private let lock = NSLock()
    private var state = State.active
    private var workItem: DispatchWorkItem?

    func install(_ workItem: DispatchWorkItem) {
        lock.lock()
        if state == .active {
            self.workItem = workItem
            lock.unlock()
        } else {
            lock.unlock()
            workItem.cancel()
        }
    }

    func fire(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return
        }
        state = .fired
        workItem = nil
        lock.unlock()
        action()
    }

    func cancel() {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return
        }
        state = .cancelled
        let workItem = workItem
        self.workItem = nil
        lock.unlock()
        workItem?.cancel()
    }
}

nonisolated struct DispatchXPCRequestDeadlineScheduler: XPCRequestDeadlineScheduling, @unchecked Sendable {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "com.lljts.JTSTerminal.rdp-xpc-deadlines")) {
        self.queue = queue
    }

    func schedule(
        after delaySeconds: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any XPCRequestDeadlineToken {
        precondition(delaySeconds > 0 && delaySeconds.isFinite, "XPC request deadlines must be finite and positive.")

        let token = DispatchXPCRequestDeadlineToken()
        let workItem = DispatchWorkItem { [weak token] in
            token?.fire(action)
        }
        token.install(workItem)
        queue.asyncAfter(deadline: .now() + delaySeconds, execute: workItem)
        return token
    }
}

nonisolated private protocol XPCPendingReply: AnyObject {
    func fail(_ error: Error)
}

nonisolated private final class XPCPendingReplyBox<Value>: XPCPendingReply {
    private let continuation: CheckedContinuation<Value, Error>

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Value, Error>) {
        continuation.resume(with: result)
    }

    func fail(_ error: Error) {
        continuation.resume(throwing: error)
    }
}

nonisolated private struct XPCPendingRequest {
    let reply: any XPCPendingReply
    var deadlineToken: (any XPCRequestDeadlineToken)?
}

/// Serializes all terminal outcomes for asynchronous XPC requests.
///
/// NSXPC may report a proxy error, an interruption/invalidation, a deadline,
/// task cancellation, and a late reply for the same request. Removing the
/// pending entry under one lock before cancelling its timer and resuming its
/// continuation makes every terminal outcome mutually exclusive. Connection
/// teardown can also fail every outstanding request so a crashed or stalled
/// helper never leaves the main app suspended indefinitely.
nonisolated final class XPCRequestCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let deadlineScheduler: any XPCRequestDeadlineScheduling
    private var pending: [UUID: XPCPendingRequest] = [:]

    init(deadlineScheduler: any XPCRequestDeadlineScheduling = DispatchXPCRequestDeadlineScheduler()) {
        self.deadlineScheduler = deadlineScheduler
    }

    deinit {
        failAll(CancellationError())
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func perform<Value>(
        deadlineSeconds: TimeInterval,
        _ start: (@escaping (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        precondition(deadlineSeconds > 0 && deadlineSeconds.isFinite, "XPC request deadlines must be finite and positive.")

        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = XPCPendingReplyBox(continuation: continuation)
                lock.lock()
                pending[requestID] = XPCPendingRequest(reply: box)
                lock.unlock()

                let deadlineToken = deadlineScheduler.schedule(after: deadlineSeconds) { [weak self] in
                    self?.timeout(requestID, deadlineSeconds: deadlineSeconds)
                }
                installDeadlineToken(deadlineToken, requestID: requestID)

                if Task.isCancelled {
                    cancel(requestID)
                    return
                }
                guard isPending(requestID) else {
                    return
                }

                start { [weak self] result in
                    self?.finish(requestID, with: result)
                }
            }
        } onCancel: { [weak self] in
            self?.cancel(requestID)
        }
    }

    func failAll(_ error: Error) {
        lock.lock()
        let requests = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        for request in requests {
            request.deadlineToken?.cancel()
            request.reply.fail(error)
        }
    }

    private func installDeadlineToken(
        _ deadlineToken: any XPCRequestDeadlineToken,
        requestID: UUID
    ) {
        lock.lock()
        if pending[requestID] != nil {
            pending[requestID]?.deadlineToken = deadlineToken
            lock.unlock()
        } else {
            lock.unlock()
            deadlineToken.cancel()
        }
    }

    private func isPending(_ requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending[requestID] != nil
    }

    private func finish<Value>(_ requestID: UUID, with result: Result<Value, Error>) {
        guard let request = take(requestID) else {
            return
        }
        request.deadlineToken?.cancel()
        guard let typedReply = request.reply as? XPCPendingReplyBox<Value> else {
            return
        }
        typedReply.resolve(result)
    }

    private func cancel(_ requestID: UUID) {
        guard let request = take(requestID) else {
            return
        }
        request.deadlineToken?.cancel()
        request.reply.fail(CancellationError())
    }

    private func timeout(_ requestID: UUID, deadlineSeconds: TimeInterval) {
        guard let request = take(requestID) else {
            return
        }
        request.deadlineToken?.cancel()
        request.reply.fail(XPCRequestTimeoutFailure(deadlineSeconds: deadlineSeconds))
    }

    private func take(_ requestID: UUID) -> XPCPendingRequest? {
        lock.lock()
        let request = pending.removeValue(forKey: requestID)
        lock.unlock()
        return request
    }
}
#endif
