import Foundation

/// Must run after pinned mutual TLS and before exposing a local screen-sharing or file endpoint.
public enum CompanionHostLaneAuthorization {
    public static func accept(channel: any CompanionSecureChannel,
                              approvedGrantIDs: Set<UUID>) async throws -> UUID {
        guard [.file, .rdp, .desktop].contains(channel.binding.lane) else {
            await channel.close()
            throw CompanionTransportError.unsupportedLane
        }
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: UUID.self) { group in
                    group.addTask { try await exchange(channel: channel, approvedGrantIDs: approvedGrantIDs) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        await channel.close()
                        throw CompanionControlError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } onCancel: { Task { await channel.close() } }
        } catch { await channel.close(); throw error }
    }

    private static func exchange(channel: any CompanionSecureChannel, approvedGrantIDs: Set<UUID>) async throws -> UUID {
        let header = try await readExactly(4, channel: channel)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...16_384).contains(length) else { throw CompanionTransportError.frameTooLarge }
        let bytes = try await readExactly(length, channel: channel)
        try StrictRelayJSON.validate(bytes, requiredKeys: ["version", "id", "operation", "grantId", "parameters"])
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        guard request.version == 1, let requestID = UUID(uuidString: request.id),
              requestID.uuidString.lowercased() == request.id,
              let grant = UUID(uuidString: request.grantId), grant != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              grant.uuidString.lowercased() == request.grantId,
              request.operation == channel.binding.lane.rawValue + ".open",
              request.parameters.isEmpty, approvedGrantIDs.contains(grant) else {
            throw CompanionTransportError.unauthorizedDevice
        }
        let reply = try RelayJSON.encode(Reply(version: 1, id: request.id, ok: true,
                                               result: Ready(ready: true), errorCode: nil))
        var lengthPrefix = UInt32(reply.count).bigEndian
        var framed = withUnsafeBytes(of: &lengthPrefix) { Data($0) }
        framed.append(reply)
        try await channel.send(framed)
        return grant
    }

    private static func readExactly(_ count: Int, channel: any CompanionSecureChannel) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            let maximum = min(16_384, count - bytes.count)
            let chunk = try await channel.receive(maximumBytes: maximum)
            guard !chunk.isEmpty, chunk.count <= maximum else { throw CompanionTransportError.invalidResponse }
            bytes.append(chunk)
        }
        return bytes
    }

    private struct Request: Decodable {
        let version: Int
        let id, operation, grantId: String
        let parameters: [String: String]
    }
    private struct Ready: Encodable { let ready: Bool }
    private struct Reply: Encodable {
        let version: Int
        let id: String
        let ok: Bool
        let result: Ready
        let errorCode: String?
        enum CodingKeys: String, CodingKey { case version, id, ok, result, errorCode }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version); try container.encode(id, forKey: .id)
            try container.encode(ok, forKey: .ok); try container.encode(result, forKey: .result)
            try container.encode(errorCode, forKey: .errorCode)
        }
    }
}
