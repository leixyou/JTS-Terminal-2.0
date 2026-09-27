import Foundation

/// Serial, bounded task RPC over an already pinned/bound control channel. Never automatically replays an operation.
public actor CompanionControlClient {
    private let channel: any CompanionSecureChannel
    private let onFailure: (@Sendable () async -> Void)?
    private var busy = false
    private var closed = false

    public init(channel: any CompanionSecureChannel) throws {
        guard channel.binding.lane == .control else { throw CompanionTransportError.unsupportedLane }
        self.channel = channel; onFailure = nil
    }
    init(channel: any CompanionSecureChannel, onFailure: @escaping @Sendable () async -> Void) throws {
        guard channel.binding.lane == .control else { throw CompanionTransportError.unsupportedLane }
        self.channel = channel; self.onFailure = onFailure
    }

    public func status(grantID: UUID) async throws -> CompanionControlStatus {
        let result: CompanionControlStatus = try await request("device.status", grantID: grantID, parameters: Empty())
        guard Set(result.capabilities).count == result.capabilities.count,
              Set(result.capabilities).isSubset(of: ControlLimits.operations),
              result.maximumPayloadBytes > 0, result.maximumPayloadBytes <= ControlLimits.payload,
              result.maximumOutputChunkBytes > 0, result.maximumOutputChunkBytes <= ControlLimits.outputChunk else {
            try await invalidResponse()
        }
        return result
    }

    public func submit(jobID: UUID, grantID: UUID, kind: String, deadline: Date, payload: Data,
                       allowDisconnected: Bool = false) async throws -> CompanionJobReceipt {
        let time = floor(deadline.timeIntervalSince1970 * 1000)
        guard !payload.isEmpty, payload.count <= ControlLimits.payload, (1...64).contains(kind.utf8.count),
              kind.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }),
              time.isFinite, time >= 0, time <= 253_402_300_799_999 else { throw CompanionControlError.invalidRequest }
        let args = Submit(jobId: try ControlLimits.canonical(jobID), kind: kind, deadlineUnixMilliseconds: Int64(time),
                          allowDisconnected: allowDisconnected, payloadBase64: payload.base64EncodedString())
        let result: CompanionJobReceipt = try await request("job.submit", grantID: grantID, parameters: args)
        try await validate(result, jobID: jobID, grantID: grantID)
        guard result.kind == kind, result.deadlineUnixMilliseconds == Int64(time), result.allowDisconnected == allowDisconnected else {
            try await invalidResponse()
        }
        return result
    }

    public func job(jobID: UUID, grantID: UUID) async throws -> CompanionJobReceipt {
        let result: CompanionJobReceipt = try await request("job.get", grantID: grantID,
            parameters: Job(jobId: try ControlLimits.canonical(jobID)))
        try await validate(result, jobID: jobID, grantID: grantID); return result
    }

    public func cancel(jobID: UUID, grantID: UUID) async throws -> CompanionJobReceipt {
        let result: CompanionJobReceipt = try await request("job.cancel", grantID: grantID,
            parameters: Job(jobId: try ControlLimits.canonical(jobID)))
        try await validate(result, jobID: jobID, grantID: grantID); return result
    }

    public func output(jobID: UUID, grantID: UUID, offset: Int = 0, maximumBytes: Int = 32 * 1024) async throws -> CompanionJobOutput {
        guard offset >= 0, offset <= 1024 * 1024, (1...ControlLimits.outputChunk).contains(maximumBytes) else {
            throw CompanionControlError.invalidRequest
        }
        let result: CompanionJobOutput = try await request("job.output", grantID: grantID,
            parameters: Output(jobId: try ControlLimits.canonical(jobID), offset: offset, maximumBytes: maximumBytes))
        guard result.jobId == jobID.uuidString.lowercased(), result.offset == offset,
              let bytes = Data(base64Encoded: result.dataBase64), bytes.base64EncodedString() == result.dataBase64,
              bytes.count <= maximumBytes, result.nextOffset == offset + bytes.count,
              result.outputBytes >= result.nextOffset, result.outputBytes <= 1024 * 1024 else { try await invalidResponse() }
        return result
    }

    public func close() async {
        closed = true
        await channel.close()
        await onFailure?()
    }

    private func validate(_ value: CompanionJobReceipt, jobID: UUID, grantID: UUID) async throws {
        guard value.jobId == jobID.uuidString.lowercased(), value.grantId == grantID.uuidString.lowercased(),
              value.outputBytes >= 0, value.outputBytes <= 1024 * 1024 else { try await invalidResponse() }
    }

    private func invalidResponse() async throws -> Never {
        await close(); throw CompanionControlError.invalidResponse
    }

    private func request<P: Encodable, R: ControlResult>(_ operation: String, grantID: UUID, parameters: P) async throws -> R {
        guard !closed else { throw CompanionTransportError.connectionClosed }
        guard !busy else { throw CompanionTransportError.operationInProgress }
        let id = UUID().uuidString.lowercased()
        let bytes = try RelayJSON.encode(Request(version: 1, id: id, operation: operation,
            grantId: ControlLimits.canonical(grantID), parameters: parameters))
        guard bytes.count <= ControlLimits.frame else { throw CompanionControlError.invalidRequest }
        busy = true
        defer { busy = false }
        do {
            let reply = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await self.exchange(bytes) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        await self.channel.close()
                        throw CompanionControlError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } onCancel: { Task { await self.channel.close() } }
            try StrictRelayJSON.validate(reply, requiredKeys: ["version", "id", "ok", "result", "errorCode"])
            let envelope = try JSONDecoder().decode(Envelope<R>.self, from: reply)
            guard envelope.version == 1, envelope.id == id else { throw CompanionControlError.invalidResponse }
            if !envelope.ok {
                guard envelope.result == nil, let code = envelope.errorCode, (1...64).contains(code.utf8.count),
                      code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                    throw CompanionControlError.invalidResponse
                }
                throw CompanionControlError.remote(code)
            }
            guard envelope.errorCode == nil, let result = envelope.result,
                  let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let value = object["result"] as? [String: Any], Set(value.keys) == R.fields else {
                throw CompanionControlError.invalidResponse
            }
            return result
        } catch CompanionControlError.remote(let code) { throw CompanionControlError.remote(code) }
        catch { await close(); throw error }
    }

    private func exchange(_ bytes: Data) async throws -> Data {
        try Task.checkCancellation()
        var length = UInt32(bytes.count).bigEndian
        try await channel.send(withUnsafeBytes(of: &length) { Data($0) })
        for start in stride(from: 0, to: bytes.count, by: 16 * 1024) {
            try await channel.send(bytes.subdata(in: start..<min(start + 16 * 1024, bytes.count)))
        }
        let header = try await readExactly(4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= ControlLimits.frame else { throw CompanionControlError.invalidResponse }
        return try await readExactly(count)
    }
    private func readExactly(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            let chunk = try await channel.receive(maximumBytes: min(16 * 1024, count - bytes.count))
            guard !chunk.isEmpty, chunk.count <= min(16 * 1024, count - bytes.count) else { throw CompanionControlError.invalidResponse }
            bytes += chunk
        }
        return bytes
    }
    private struct Empty: Encodable {}
    private struct Job: Encodable { let jobId: String }
    private struct Output: Encodable { let jobId: String; let offset, maximumBytes: Int }
    private struct Submit: Encodable {
        let jobId, kind: String; let deadlineUnixMilliseconds: Int64; let allowDisconnected: Bool; let payloadBase64: String
    }
    private struct Request<P: Encodable>: Encodable { let version: Int; let id, operation, grantId: String; let parameters: P }
    private struct Envelope<R: Decodable>: Decodable { let version: Int; let id: String; let ok: Bool; let result: R?; let errorCode: String? }
}
