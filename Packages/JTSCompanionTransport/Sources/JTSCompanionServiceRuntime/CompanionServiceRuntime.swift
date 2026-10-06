import Foundation
import JTSCompanionIPC
import JTSCompanionTransport

/// Per-XPC-connection ownership. Invalidating the caller closes every route and forgets its in-memory key.
/// This layer does not persist identities, approve pairing, grant capabilities, or retry commands.
public actor CompanionServiceRuntime {
    typealias Factory = @Sendable (CompanionIPCOpen) throws -> any CompanionRuntimeSession
    private let factory: Factory
    private let openTimeout: UInt64
    private let heartbeatInterval: UInt64
    private var connectionID: UUID?
    private var generation = UUID()
    private var phase = "disconnected"
    private var sessionID: String?
    private var session: (any CompanionRuntimeSession)?
    private var opening: Task<String, Error>?
    private var heartbeat: Task<Void, Never>?
    private var seen = Set<UUID>()
    private var busy = false
    private var invalidated = false
    private var laneRuntime: CompanionLaneServiceRuntime?

    public init() {
        factory = { try PinnedCompanionRuntimeSession($0) }
        openTimeout = 50_000_000_000
        heartbeatInterval = 20_000_000_000
    }

    init(factory: @escaping Factory, openTimeout: UInt64 = 50_000_000_000,
         heartbeatInterval: UInt64 = 20_000_000_000) {
        self.factory = factory; self.openTimeout = openTimeout; self.heartbeatInterval = heartbeatInterval
    }

    public func handle(_ data: Data) async -> Data {
        guard !invalidated, let request = try? CompanionIPCCodec.decodeRequest(data) else { return Data() }
        if request.operation.isLaneOperation {
            guard connectionID == nil else { return Data() }
            let runtime = laneRuntime ?? CompanionLaneServiceRuntime()
            laneRuntime = runtime
            return await runtime.handle(request)
        }
        guard laneRuntime == nil else { return Data() }
        guard seen.count < 65_536 else { await invalidate(); return Data() }
        guard seen.insert(request.id).inserted else { return failure(request, "REQUEST_REPLAY_REJECTED") }
        guard connectionID == nil || connectionID == request.connectionID else {
            return failure(request, "CONNECTION_MISMATCH")
        }
        do {
            let payload: Data
            switch request.operation {
            case .open: payload = try await open(request)
            case .close:
                _ = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCEmpty.self)
                guard connectionID != nil else { return failure(request, "NOT_CONNECTED") }
                await shutdown(phase: "disconnected")
                payload = try state()
            case .state:
                _ = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCEmpty.self)
                payload = try state()
            default:
                // Validate before taking the in-flight slot or touching a remote endpoint.
                try validateOperation(request)
                guard !busy else { return failure(request, "OPERATION_IN_PROGRESS") }
                guard phase == "connected", let current = session else { return failure(request, "NOT_CONNECTED") }
                let expected = generation
                busy = true
                defer { busy = false }
                do {
                    payload = try await current.execute(request)
                    try Task.checkCancellation()
                    guard generation == expected, !invalidated else { return failure(request, "CONNECTION_CLOSED") }
                } catch {
                    // A typed remote denial is not transport loss. No automatic retry follows either case.
                    if case CompanionControlError.remote(let code) = error {
                        return failure(request, "REMOTE_" + code)
                    }
                    if generation == expected { await shutdown(phase: "failed") }
                    throw error
                }
            }
            guard !invalidated else { return Data() }
            return try CompanionIPCCodec.encodeReply(CompanionIPCReply(id: request.id, connectionID: request.connectionID,
                ok: true, payload: payload, errorCode: nil))
        } catch {
            return failure(request, CompanionRuntimeErrors.code(error))
        }
    }

    public func invalidate() async {
        invalidated = true
        await laneRuntime?.invalidate(); laneRuntime = nil
        await shutdown(phase: "disconnected")
        seen.removeAll(keepingCapacity: false)
    }

    private func open(_ request: CompanionIPCRequest) async throws -> Data {
        guard connectionID == nil, !busy else { throw CompanionRuntimeErrors.alreadyOpened }
        let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCOpen.self)
        let route = try factory(input)
        connectionID = request.connectionID
        session = route
        phase = "connecting"
        let expected = generation
        let connectionTask = Task { try await route.connect() }
        opening = connectionTask
        defer { if expected == generation { opening = nil } }
        do {
            let id = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await connectionTask.value }
                    group.addTask { [openTimeout] in
                        try await Task.sleep(nanoseconds: openTimeout)
                        connectionTask.cancel()
                        await route.close()
                        throw CompanionRuntimeErrors.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } onCancel: { connectionTask.cancel(); Task { await route.close() } }
            try Task.checkCancellation()
            guard expected == generation, !invalidated else {
                await route.close(); throw CompanionRuntimeErrors.closed
            }
            guard UUID(uuidString: id) != nil else { throw CompanionRuntimeErrors.invalidSession }
            sessionID = id
            phase = "connected"
            heartbeat = Task { [weak self, heartbeatInterval] in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: heartbeatInterval)
                        try await route.heartbeat()
                    }
                } catch {
                    if !Task.isCancelled { await self?.heartbeatFailed(expected) }
                }
            }
            return try state()
        } catch {
            if expected == generation { await shutdown(phase: "failed") }
            throw error
        }
    }

    private func heartbeatFailed(_ expected: UUID) async {
        guard expected == generation, !invalidated else { return }
        await shutdown(phase: "failed")
    }

    private func shutdown(phase next: String) async {
        generation = UUID()
        let previous = session
        session = nil; sessionID = nil; phase = next
        opening?.cancel(); opening = nil
        heartbeat?.cancel(); heartbeat = nil
        await previous?.close()
    }

    private func state() throws -> Data {
        try CompanionIPCCodec.encodePayload(CompanionIPCState(phase: phase, sessionID: sessionID))
    }

    private func failure(_ request: CompanionIPCRequest, _ code: String) -> Data {
        let safe = code.utf8.count <= 80 && code.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }
            ? code : "REQUEST_FAILED"
        return (try? CompanionIPCCodec.encodeReply(CompanionIPCReply(id: request.id, connectionID: request.connectionID,
            ok: false, payload: nil, errorCode: safe))) ?? Data()
    }

    private func validateOperation(_ request: CompanionIPCRequest) throws {
        switch request.operation {
        case .authorizeDesktop: _ = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCDesktopAuthorization.self)
        case .status: _ = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCGrant.self)
        case .submit: _ = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCSubmit.self)
        case .job, .cancel: _ = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCJob.self)
        case .output: _ = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCOutput.self)
        default: throw CompanionControlError.invalidRequest
        }
    }
}
