import Foundation
import JTSCompanionIPC
import JTSCompanionServiceRuntime

/// One actor and operation registry per authenticated XPC connection, never a shared identity singleton.
final class CompanionConnectionBridge: NSObject, CompanionTransportServiceProtocol, @unchecked Sendable {
    private static let maximumRequests = 16
    private static let maximumEnvelopeBytes = CompanionIPCLimits.frameBytes
    private let runtime = CompanionServiceRuntime()
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var invalidated = false

    init(connection: NSXPCConnection) { self.connection = connection; super.init() }

    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard !request.isEmpty, request.count <= Self.maximumEnvelopeBytes else { reject(); return }
        let operation = UUID()
        let callback = Reply(reply)
        lock.lock()
        guard !invalidated, tasks.count < Self.maximumRequests else { lock.unlock(); reject(); return }
        // The lock makes registration precede completion, including an immediate actor reply.
        tasks[operation] = Task { [weak self] in
            guard let self else { return }
            let response = await runtime.handle(request)
            finish(operation, response: response, reply: callback)
        }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        invalidated = true
        let active = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        for task in active { task.cancel() }
        let runtime = runtime
        Task { await runtime.invalidate() }
    }

    private func finish(_ operation: UUID, response: Data, reply: Reply) {
        lock.lock()
        let shouldReply = tasks.removeValue(forKey: operation) != nil && !invalidated
        lock.unlock()
        guard shouldReply else { return }
        guard !response.isEmpty, response.count <= Self.maximumEnvelopeBytes else { reject(); return }
        reply.body(response)
    }

    private func reject() {
        // A transport violation closes the connection; do not invent a business response or leak data.
        invalidate()
        connection?.invalidate()
    }

    private final class Reply: @unchecked Sendable {
        let body: (Data) -> Void
        init(_ body: @escaping (Data) -> Void) { self.body = body }
    }
}
