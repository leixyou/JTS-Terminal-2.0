import Foundation
import JTSCompanionIPC

/// A dedicated signed XPC connection for one authenticated File or RDP stream.
/// One read and one write may overlap; neither occupies the Control RPC slot.
public actor CompanionLaneClient {
    public typealias TransportFactory = @Sendable () throws -> any CompanionIPCTransport
    private let factory: TransportFactory
    private let openTimeout, writeTimeout: UInt64
    private var transport: (any CompanionIPCTransport)?
    private var connectionID: UUID?
    private var generation = UUID()
    private var opened = false
    private var readSequence: UInt64 = 0
    private var writeSequence: UInt64 = 0
    private var pending: [CompanionIPCOperation: Pending] = [:]

    private struct Pending {
        let request: CompanionIPCRequest
        let continuation: CheckedContinuation<CompanionIPCReply, Error>
        let timeout: Task<Void, Never>?
    }

    public init() {
        factory = { XPCCompanionIPCTransport() }; openTimeout = 60_000_000_000; writeTimeout = 25_000_000_000
    }

    public init(transportFactory: @escaping TransportFactory) {
        factory = transportFactory; openTimeout = 60_000_000_000; writeTimeout = 25_000_000_000
    }

    init(transportFactory: @escaping TransportFactory, testTimeoutNanoseconds: UInt64) {
        factory = transportFactory
        openTimeout = min(max(1, testTimeoutNanoseconds), 60_000_000_000)
        writeTimeout = min(max(1, testTimeoutNanoseconds), 25_000_000_000)
    }

    deinit {
        transport?.invalidate()
        for value in pending.values {
            value.timeout?.cancel(); value.continuation.resume(throwing: CompanionClientError.invalidated)
        }
    }

    public func open(configuration: CompanionIPCOpen, lane: CompanionIPCLane,
                     grantID: UUID) async throws -> CompanionIPCLaneState {
        guard pending.isEmpty else { throw CompanionClientError.busy }
        let request = CompanionIPCLaneOpen(configuration: configuration, lane: lane, grantID: grantID)
        let payload = try encode(request)
        tearDown(.invalidated)
        let active = UUID(); generation = active; connectionID = UUID()
        do {
            let next = try factory(); transport = next
            try next.start { [weak self] error in Task { await self?.fail(error, generation: active) } }
            let reply = try await exchange(.openLane, payload: payload, timeout: openTimeout)
            guard let bytes = reply.payload else { throw CompanionClientError.invalidReply }
            let state = try CompanionIPCCodec.decodePayload(bytes, as: CompanionIPCLaneState.self)
            guard generation == active, state.lane == lane else { throw CompanionClientError.invalidReply }
            opened = true
            return state
        } catch {
            fail(map(error), generation: active); throw map(error)
        }
    }

    public func read(maximumBytes: Int = CompanionIPCLaneState.chunkLimit) async throws -> Data {
        guard opened else { throw CompanionClientError.notConnected }
        guard pending[.readLane] == nil else { throw CompanionClientError.busy }
        guard readSequence < UInt64.max else { tearDown(.invalidated); throw CompanionClientError.invalidated }
        let payload = try encode(CompanionIPCLaneRead(maximumBytes: maximumBytes, sequence: readSequence + 1))
        readSequence += 1
        let active = generation
        do {
            // An idle desktop is valid indefinitely. Cancellation, XPC loss or
            // helper heartbeat failure terminates the blocked read.
            let reply = try await exchange(.readLane, payload: payload, timeout: nil)
            guard let bytes = reply.payload else { throw CompanionClientError.invalidReply }
            let value = try CompanionIPCCodec.decodePayload(bytes, as: CompanionIPCLaneBytes.self)
            guard generation == active, opened else { throw CompanionClientError.invalidated }
            guard value.data.count <= maximumBytes else { throw CompanionClientError.invalidReply }
            return value.data
        } catch { fail(map(error), generation: active); throw map(error) }
    }

    public func write(_ data: Data) async throws {
        guard opened else { throw CompanionClientError.notConnected }
        guard pending[.writeLane] == nil else { throw CompanionClientError.busy }
        guard writeSequence < UInt64.max else { tearDown(.invalidated); throw CompanionClientError.invalidated }
        let payload = try encode(CompanionIPCLaneWrite(data: data, sequence: writeSequence + 1))
        writeSequence += 1
        let active = generation
        do {
            let reply = try await exchange(.writeLane, payload: payload, timeout: writeTimeout)
            guard let bytes = reply.payload else { throw CompanionClientError.invalidReply }
            _ = try CompanionIPCCodec.decodePayload(bytes, as: CompanionIPCEmpty.self)
            guard generation == active, opened else { throw CompanionClientError.invalidated }
        } catch { fail(map(error), generation: active); throw map(error) }
    }

    /// XPC invalidation closes the helper's lane and wakes both local directions.
    public func close() { tearDown(.cancelled) }
    public func invalidate() { tearDown(.invalidated) }

    private func exchange(_ operation: CompanionIPCOperation, payload: Data,
                          timeout duration: UInt64?) async throws -> CompanionIPCReply {
        guard pending[operation] == nil else { throw CompanionClientError.busy }
        guard let transport, let connectionID else { throw CompanionClientError.notConnected }
        let active = generation
        let request = CompanionIPCRequest(version: 2, id: UUID(), connectionID: connectionID,
                                          operation: operation, payload: payload)
        let bytes = try CompanionIPCCodec.encodeRequest(request)
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { fail(.cancelled, generation: active); throw CompanionClientError.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                let timer = duration.map { duration in Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: duration) } catch { return }
                    await self?.finish(.timedOut, generation: active, request: request)
                } }
                pending[operation] = Pending(request: request, continuation: continuation, timeout: timer)
                transport.send(bytes) { [weak self] result in
                    Task { await self?.receive(result, generation: active, request: request) }
                }
            }
        } onCancel: { [weak self] in Task { await self?.finish(.cancelled, generation: active, request: request) } }
    }

    private func receive(_ result: Result<Data, CompanionClientError>, generation active: UUID,
                         request: CompanionIPCRequest) {
        guard generation == active, let waiting = pending[request.operation], waiting.request.id == request.id else { return }
        do {
            let reply = try CompanionIPCCodec.decodeReply(result.get())
            guard reply.version == 2, reply.id == request.id, reply.connectionID == request.connectionID else {
                throw CompanionClientError.invalidReply
            }
            guard reply.ok else { throw CompanionClientError.remote(reply.errorCode!) }
            pending[request.operation] = nil
            waiting.timeout?.cancel(); waiting.continuation.resume(returning: reply)
        } catch { fail(map(error), generation: active) }
    }

    private func finish(_ error: CompanionClientError, generation active: UUID, request: CompanionIPCRequest) {
        guard pending[request.operation]?.request.id == request.id else { return }
        fail(error, generation: active)
    }

    private func fail(_ error: CompanionClientError, generation active: UUID) {
        guard generation == active else { return }; tearDown(error)
    }

    private func tearDown(_ error: CompanionClientError) {
        generation = UUID(); connectionID = nil; opened = false; readSequence = 0; writeSequence = 0
        let waiting = pending; pending.removeAll()
        let old = transport; transport = nil; old?.invalidate()
        for value in waiting.values { value.timeout?.cancel(); value.continuation.resume(throwing: error) }
    }

    private func encode<P: CompanionIPCPayload>(_ payload: P) throws -> Data {
        do { return try CompanionIPCCodec.encodePayload(payload) }
        catch { throw CompanionClientError.invalidRequest }
    }

    private func map(_ error: Error) -> CompanionClientError {
        if let known = error as? CompanionClientError { return known }
        return error is CancellationError ? .cancelled : .invalidReply
    }
}
