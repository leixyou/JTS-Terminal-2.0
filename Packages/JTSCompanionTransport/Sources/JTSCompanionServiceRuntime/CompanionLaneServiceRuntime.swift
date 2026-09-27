import Foundation
import JTSCompanionIPC
import JTSCompanionTransport

/// One stream per signed XPC caller. Independent read/write sequences retain
/// replay protection without a growing request-ID set on long RDP sessions.
actor CompanionLaneServiceRuntime {
    typealias Factory = @Sendable (CompanionIPCLaneOpen) throws -> any CompanionLaneRuntimeSession
    private let factory: Factory
    private let openTimeout, heartbeatInterval: UInt64
    private var session: (any CompanionLaneRuntimeSession)?
    private var connectionID: UUID?
    private var generation = UUID()
    private var opened = false
    private var invalidated = false
    private var readSequence: UInt64 = 0
    private var writeSequence: UInt64 = 0
    private var reading = false
    private var writing = false
    private var opening: Task<CompanionIPCLaneState, Error>?
    private var heartbeat: Task<Void, Never>?

    init(factory: @escaping Factory = { try PinnedCompanionLaneRuntimeSession($0) },
         openTimeout: UInt64 = 50_000_000_000, heartbeatInterval: UInt64 = 20_000_000_000) {
        self.factory = factory; self.openTimeout = openTimeout; self.heartbeatInterval = heartbeatInterval
    }

    func handle(_ request: CompanionIPCRequest) async -> Data {
        guard !invalidated, request.version == 2, request.operation.isLaneOperation else { return Data() }
        guard connectionID == nil || connectionID == request.connectionID else { return reply(request, error: "CONNECTION_MISMATCH") }
        do {
            let payload: Data
            switch request.operation {
            case .openLane: payload = try await open(request)
            case .readLane: payload = try await read(request)
            case .writeLane: payload = try await write(request)
            case .closeLane:
                _ = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCEmpty.self)
                await shutdown()
                payload = try CompanionIPCCodec.encodePayload(CompanionIPCEmpty())
            default: return Data()
            }
            return reply(request, payload: payload)
        } catch CompanionControlError.remote(let code) {
            return reply(request, error: "REMOTE_" + code)
        } catch {
            return reply(request, error: CompanionRuntimeErrors.code(error))
        }
    }

    func invalidate() async { invalidated = true; await shutdown() }

    private func open(_ request: CompanionIPCRequest) async throws -> Data {
        guard connectionID == nil else { throw CompanionRuntimeErrors.alreadyOpened }
        let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCLaneOpen.self)
        let route = try factory(input)
        connectionID = request.connectionID; session = route
        let expected = generation
        let task = Task { try await route.connect() }; opening = task
        defer { if generation == expected { opening = nil } }
        do {
            let state = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: CompanionIPCLaneState.self) { group in
                    group.addTask { try await task.value }
                    group.addTask { [openTimeout] in
                        try await Task.sleep(nanoseconds: openTimeout)
                        task.cancel(); await route.close()
                        throw CompanionRuntimeErrors.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } onCancel: { task.cancel(); Task { await route.close() } }
            try Task.checkCancellation()
            guard generation == expected, !invalidated, state.lane == input.lane else { throw CompanionRuntimeErrors.closed }
            try state.validate(); opened = true
            heartbeat = Task { [weak self, heartbeatInterval] in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: heartbeatInterval)
                        try await route.heartbeat()
                    }
                } catch {
                    if !Task.isCancelled { await self?.failed(generation: expected) }
                }
            }
            return try CompanionIPCCodec.encodePayload(state)
        } catch {
            if generation == expected { await shutdown() }
            throw error
        }
    }

    private func read(_ request: CompanionIPCRequest) async throws -> Data {
        let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCLaneRead.self)
        guard opened, let route = session else { throw CompanionRuntimeErrors.closed }
        guard !reading else { throw CompanionTransportError.operationInProgress }
        guard readSequence < UInt64.max, input.sequence == readSequence + 1 else { throw CompanionRuntimeErrors.replayed }
        reading = true; readSequence = input.sequence
        defer { reading = false }
        let expected = generation
        do {
            let bytes = try await route.read(maximumBytes: input.maximumBytes)
            try Task.checkCancellation()
            guard generation == expected, !invalidated else { throw CompanionRuntimeErrors.closed }
            guard !bytes.isEmpty, bytes.count <= input.maximumBytes else { throw CompanionControlError.invalidResponse }
            return try CompanionIPCCodec.encodePayload(CompanionIPCLaneBytes(bytes))
        } catch {
            if generation == expected { await shutdown() }
            throw error
        }
    }

    private func write(_ request: CompanionIPCRequest) async throws -> Data {
        let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCLaneWrite.self)
        guard opened, let route = session else { throw CompanionRuntimeErrors.closed }
        guard !writing else { throw CompanionTransportError.operationInProgress }
        guard writeSequence < UInt64.max, input.sequence == writeSequence + 1 else { throw CompanionRuntimeErrors.replayed }
        writing = true; writeSequence = input.sequence
        defer { writing = false }
        let expected = generation
        do {
            try await route.write(input.data)
            try Task.checkCancellation()
            guard generation == expected, !invalidated else { throw CompanionRuntimeErrors.closed }
            return try CompanionIPCCodec.encodePayload(CompanionIPCEmpty())
        } catch {
            if generation == expected { await shutdown() }
            throw error
        }
    }

    private func failed(generation expected: UUID) async {
        guard generation == expected else { return }; await shutdown()
    }

    private func shutdown() async {
        generation = UUID(); opened = false
        opening?.cancel(); opening = nil
        heartbeat?.cancel(); heartbeat = nil
        let previous = session; session = nil
        await previous?.close()
    }

    private func reply(_ request: CompanionIPCRequest, payload: Data? = nil, error: String? = nil) -> Data {
        guard !invalidated else { return Data() }
        let code = error.map { value in
            (1...80).contains(value.utf8.count) && value.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 })
                ? value : "REQUEST_FAILED"
        }
        return (try? CompanionIPCCodec.encodeReply(CompanionIPCReply(version: 2, id: request.id,
            connectionID: request.connectionID, ok: code == nil, payload: payload, errorCode: code))) ?? Data()
    }
}
