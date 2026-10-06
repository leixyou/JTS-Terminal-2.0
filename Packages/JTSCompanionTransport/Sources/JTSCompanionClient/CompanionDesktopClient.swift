import Foundation
import JTSCompanionIPC

/// One full-duplex desktop connection. RPC replies are correlated separately
/// from streamed frames; a frame handler provides bounded decode backpressure.
/// Failed or cancelled actions are never replayed.
public actor CompanionDesktopClient {
    public typealias EventHandler = @Sendable (CompanionDesktopEnvelope) async -> Void
    private let lane: CompanionLaneClient
    private var connected = false
    private var epoch = UUID(), generation = UUID()
    private var sessionId = 0
    private var reader: Task<Void, Never>?
    private var handler: EventHandler?
    private var pending: Pending?
    private var delivery: (milliseconds: Int, bytes: Int)?
    private var retiredGenerations: [UUID] = []
    private struct Pending {
        let id: String
        let operation: String
        let continuation: CheckedContinuation<CompanionDesktopEnvelope, Error>
        let timeout: Task<Void, Never>
    }
    public init(lane: CompanionLaneClient = CompanionLaneClient()) { self.lane = lane }
    public func setEventHandler(_ handler: EventHandler?) { self.handler = handler }
    public func deliveryMetrics() -> (milliseconds: Int, bytes: Int)? { delivery }

    public func open(configuration: CompanionIPCOpen, grantID: UUID) async throws {
        guard pending == nil else { throw CompanionDesktopError.busy }
        await close()
        let token = UUID(); epoch = token
        _ = try await lane.open(configuration: configuration, lane: .desktop, grantID: grantID)
        guard token == epoch else { throw CompanionDesktopError.disconnected }
        connected = true
        reader = Task { [weak self] in await self?.readLoop(token) }
    }
    public func close() async {
        epoch = UUID(); connected = false; delivery = nil; retiredGenerations.removeAll()
        reader?.cancel(); reader = nil
        let waiting = pending; pending = nil
        waiting?.timeout.cancel(); waiting?.continuation.resume(throwing: CompanionDesktopError.disconnected)
        await lane.close()
    }

    public func request(_ operation: String, body: [String: DesktopJSONValue] = [:],
                        expectedGeneration: UUID? = nil, expectedSessionId: Int? = nil) async throws -> CompanionDesktopEnvelope {
        guard connected else { throw CompanionDesktopError.disconnected }
        guard pending == nil else { throw CompanionDesktopError.busy }
        // The broker verifies the referenced primary before a secondary lane
        // binds. It acquires no screen/input authority from this operation.
        let readOnly = ["status", "observe", "sessions", "bindUserSession"].contains(operation)
        guard readOnly || (expectedGeneration == generation && expectedSessionId == sessionId) else {
            throw CompanionDesktopError.sessionChanged
        }
        let token = epoch, id = UUID().uuidString.lowercased()
        let value = CompanionDesktopEnvelope(kind: "request", id: id, operation: operation,
            generation: expectedGeneration ?? generation, sessionId: expectedSessionId ?? sessionId, body: body)
        let bytes = try CompanionDesktopWire.encode(value)
        let commandTimeout = body["timeoutMilliseconds"]?.integerValue ?? 0
        let timeout = UInt64(max(15_000, min(900_000, max(0, commandTimeout)) + 3_000)) * 1_000_000
        let reply = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CompanionDesktopEnvelope, Error>) in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self?.fail(CompanionDesktopError.disconnected, token: token)
                }
                pending = Pending(id: id, operation: operation, continuation: continuation, timeout: timer)
                Task { [weak self] in await self?.send(bytes, token: token) }
            }
        } onCancel: { Task { await self.fail(CompanionDesktopError.disconnected, token: token) } }
        guard token == epoch else { throw CompanionDesktopError.disconnected }
        if let code = reply.body["errorCode"]?.stringValue {
            guard !code.isEmpty, code.utf8.count <= 80, code.utf8.allSatisfy({
                (65...90).contains($0) || (48...57).contains($0) || $0 == 95
            }) else { await close(); throw CompanionDesktopError.invalidFrame }
            throw CompanionDesktopError.remote(code)
        }
        return reply
    }

    private func send(_ bytes: Data, token: UUID) async {
        do {
            for offset in stride(from: 0, to: bytes.count, by: CompanionIPCLaneState.chunkLimit) {
                guard connected, token == epoch else { throw CompanionDesktopError.disconnected }
                try Task.checkCancellation()
                try await lane.write(bytes.subdata(in: offset..<min(bytes.count, offset + CompanionIPCLaneState.chunkLimit)))
            }
        } catch { await fail(error, token: token) }
    }
    private func readLoop(_ token: UUID) async {
        do {
            while connected, token == epoch, !Task.isCancelled {
                let started = ContinuousClock.now
                let header = try await readExactly(4)
                let length = header.reduce(0) { ($0 << 8) | Int($1) }
                guard (1...CompanionDesktopWire.maximumBytes).contains(length) else { throw CompanionDesktopError.invalidFrame }
                let value = try CompanionDesktopWire.decode(await readExactly(length))
                guard token == epoch else { return }
                if retiredGenerations.contains(value.generation) {
                    if value.id == nil { continue }
                    throw CompanionDesktopError.sessionChanged
                }
                if generation != value.generation {
                    retiredGenerations.append(generation)
                    if retiredGenerations.count > 64 { retiredGenerations.removeFirst() }
                }
                generation = value.generation; sessionId = value.sessionId
                if value.id == nil, ["state", "frame"].contains(value.kind) {
                    // Decode every encoded H.264 frame in order. Only decoded
                    // images are replaced; compressed reference frames survive.
                    if let handler { await handler(value) }
                    guard connected, epoch == token, !Task.isCancelled else { return }
                    if value.kind == "frame" {
                        let elapsed = started.duration(to: .now)
                        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        delivery = (max(1, min(30_000, Int(seconds * 1000))), length)
                    }
                } else {
                    guard let waiting = pending, value.id == waiting.id, value.operation == waiting.operation,
                          ["response", "frame"].contains(value.kind) else {
                        throw CompanionDesktopError.invalidFrame
                    }
                    pending = nil; waiting.timeout.cancel(); waiting.continuation.resume(returning: value)
                }
            }
        } catch { await fail(error, token: token) }
    }
    private func fail(_ error: Error, token: UUID) async {
        guard token == epoch else { return }
        let waiting = pending; pending = nil
        waiting?.timeout.cancel(); waiting?.continuation.resume(throwing: error)
        await close()
    }
    private func readExactly(_ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            try Task.checkCancellation()
            let limit = min(CompanionIPCLaneState.chunkLimit, count - data.count)
            let bytes = try await lane.read(maximumBytes: limit)
            guard !bytes.isEmpty, bytes.count <= limit else { throw CompanionDesktopError.invalidFrame }
            data.append(bytes)
        }
        return data
    }
}
