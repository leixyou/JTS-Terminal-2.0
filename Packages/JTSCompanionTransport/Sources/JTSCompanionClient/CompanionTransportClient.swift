import Foundation
import JTSCompanionIPC

/// Lazy, one-RPC-at-a-time local client. Credentials remain caller-owned in memory;
/// a failed generation cannot reconnect or replay an operation automatically.
public actor CompanionTransportClient {
    public typealias TransportFactory = @Sendable () throws -> any CompanionIPCTransport
    private let factory: TransportFactory
    private let openTimeout, commandTimeout: UInt64
    private var transport: (any CompanionIPCTransport)?
    private var generation = UUID()
    private var connectionID: UUID?
    private var opened = false
    private var pending: Pending?

    private struct Pending {
        let request: CompanionIPCRequest
        let generation: UUID
        let continuation: CheckedContinuation<CompanionIPCReply, Error>
        let timeout: Task<Void, Never>
    }

    public init() {
        factory = { XPCCompanionIPCTransport() }
        openTimeout = 60_000_000_000; commandTimeout = 25_000_000_000
    }
    public init(transportFactory: @escaping TransportFactory) {
        factory = transportFactory
        openTimeout = 60_000_000_000; commandTimeout = 25_000_000_000
    }
    // A test-only shorter deadline. Production callers cannot extend the fixed bounds.
    init(transportFactory: @escaping TransportFactory, testTimeoutNanoseconds: UInt64) {
        factory = transportFactory
        openTimeout = min(max(1, testTimeoutNanoseconds), 60_000_000_000)
        commandTimeout = min(max(1, testTimeoutNanoseconds), 25_000_000_000)
    }
    deinit {
        pending?.timeout.cancel(); pending?.continuation.resume(throwing: CompanionClientError.invalidated)
        transport?.invalidate()
    }

    public func connect(_ configuration: CompanionIPCOpen) async throws -> CompanionIPCState { try await open(configuration) }
    public func open(_ configuration: CompanionIPCOpen) async throws -> CompanionIPCState {
        guard pending == nil else { throw CompanionClientError.busy }
        let payload: Data
        do { payload = try CompanionIPCCodec.encodePayload(configuration) }
        catch { throw CompanionClientError.invalidRequest }
        tearDown(.invalidated)
        let active = UUID(); generation = active; connectionID = UUID()
        do {
            let next = try factory(); transport = next
            try next.start { [weak self] error in Task { await self?.fail(error, generation: active) } }
            let reply = try await exchange(.open, payload: payload)
            guard let bytes = reply.payload else { throw CompanionClientError.invalidReply }
            let state = try CompanionIPCCodec.decodePayload(bytes, as: CompanionIPCState.self)
            guard generation == active, state.phase == "connected" else { throw CompanionClientError.invalidReply }
            opened = true; return state
        } catch {
            fail(map(error), generation: active); throw map(error)
        }
    }

    public func invoke(operation: CompanionIPCOperation, payload: Data) async throws -> Data? {
        guard operation != .open, operation != .close else { throw CompanionClientError.invalidRequest }
        guard opened else { throw CompanionClientError.notConnected }
        do { try StrictCompanionJSON.validate(payload, maximumBytes: CompanionIPCLimits.payloadBytes) }
        catch { throw CompanionClientError.invalidRequest }
        return try await exchange(operation, payload: payload).payload
    }

    public func perform<P: CompanionIPCPayload, R: CompanionIPCPayload>(_ operation: CompanionIPCOperation,
        payload: P, response: R.Type) async throws -> R {
        let encoded: Data
        do { encoded = try CompanionIPCCodec.encodePayload(payload) }
        catch { throw CompanionClientError.invalidRequest }
        let active = generation
        let reply = try await invoke(operation: operation, payload: encoded)
        do {
            guard let reply else { throw CompanionClientError.invalidReply }
            return try CompanionIPCCodec.decodePayload(reply, as: response)
        } catch { fail(.invalidReply, generation: active); throw CompanionClientError.invalidReply }
    }

    public func close() async throws {
        if pending != nil { tearDown(.cancelled); return }
        guard transport != nil else { return }
        let active = generation
        do {
            _ = try await exchange(.close, payload: CompanionIPCCodec.encodePayload(CompanionIPCEmpty()))
            fail(.invalidated, generation: active)
        } catch { fail(map(error), generation: active); throw map(error) }
    }
    public func invalidate() { tearDown(.invalidated) }

    private func exchange(_ operation: CompanionIPCOperation, payload: Data) async throws -> CompanionIPCReply {
        guard pending == nil else { throw CompanionClientError.busy }
        guard let transport, let connectionID else { throw CompanionClientError.notConnected }
        let active = generation
        let request = CompanionIPCRequest(id: UUID(), connectionID: connectionID, operation: operation, payload: payload)
        let requestID = request.id
        let bytes: Data
        do { bytes = try CompanionIPCCodec.encodeRequest(request) }
        catch { throw CompanionClientError.invalidRequest }
        let duration = operation == .open ? openTimeout : commandTimeout
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { fail(.cancelled, generation: active); throw CompanionClientError.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: duration) } catch { return }
                    await self?.finishPending(.timedOut, generation: active, requestID: requestID)
                }
                pending = Pending(request: request, generation: active, continuation: continuation, timeout: timeout)
                transport.send(bytes) { [weak self] result in
                    Task { await self?.receive(result, generation: active, requestID: requestID) }
                }
            }
        } onCancel: { [weak self] in Task { await self?.finishPending(.cancelled, generation: active, requestID: requestID) } }
    }

    private func receive(_ result: Result<Data, CompanionClientError>, generation active: UUID, requestID: UUID) {
        guard generation == active, let waiting = pending, waiting.generation == active, waiting.request.id == requestID else { return }
        do {
            let reply = try CompanionIPCCodec.decodeReply(result.get())
            guard reply.version == waiting.request.version, reply.id == waiting.request.id,
                  reply.connectionID == waiting.request.connectionID else { throw CompanionClientError.invalidReply }
            if !reply.ok {
                let error = CompanionClientError.remote(reply.errorCode!)
                if reply.errorCode!.hasPrefix("REMOTE_") {
                    // A validated endpoint business denial does not imply broken IPC/TLS.
                    pending = nil; waiting.timeout.cancel(); waiting.continuation.resume(throwing: error); return
                }
                throw error
            }
            pending = nil; waiting.timeout.cancel(); waiting.continuation.resume(returning: reply)
        } catch { fail(map(error), generation: active) }
    }
    private func fail(_ error: CompanionClientError, generation active: UUID) {
        guard generation == active else { return }; tearDown(error)
    }
    private func finishPending(_ error: CompanionClientError, generation active: UUID, requestID: UUID) {
        guard pending?.request.id == requestID else { return }
        fail(error, generation: active)
    }
    private func tearDown(_ error: CompanionClientError) {
        generation = UUID(); opened = false; connectionID = nil
        let waiting = pending; pending = nil
        let old = transport; transport = nil
        waiting?.timeout.cancel(); old?.invalidate(); waiting?.continuation.resume(throwing: error)
    }
    private func map(_ error: Error) -> CompanionClientError {
        if let known = error as? CompanionClientError { return known }
        if error is CancellationError { return .cancelled }
        return .invalidReply
    }
}
