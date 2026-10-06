import Foundation

/// The peer pin authenticates the device; this separate request checks its
/// current lane grant before any file protocol or RDP bytes are exposed.
enum CompanionLaneAuthorization {
    static func authorize(channel: any CompanionSecureChannel, grantID: UUID) async throws {
        guard [.file, .rdp, .desktop].contains(channel.binding.lane) else {
            throw CompanionTransportError.unsupportedLane
        }
        let id = UUID().uuidString.lowercased()
        let request = try RelayJSON.encode(Request(version: 1, id: id,
            operation: channel.binding.lane.rawValue + ".open",
            grantId: ControlLimits.canonical(grantID), parameters: Empty()))
        do {
            let reply = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await exchange(request, channel: channel) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        await channel.close()
                        throw CompanionControlError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } onCancel: { Task { await channel.close() } }
            try StrictRelayJSON.validate(reply, requiredKeys: ["version", "id", "ok", "result", "errorCode"])
            let envelope = try JSONDecoder().decode(Reply.self, from: reply)
            guard envelope.version == 1, envelope.id == id else { throw CompanionControlError.invalidResponse }
            if !envelope.ok {
                guard envelope.result == nil, let code = envelope.errorCode,
                      (1...64).contains(code.utf8.count), code.utf8.allSatisfy({
                          (65...90).contains($0) || (48...57).contains($0) || $0 == 95
                      }) else { throw CompanionControlError.invalidResponse }
                throw CompanionControlError.remote(code)
            }
            guard envelope.errorCode == nil, envelope.result?.ready == true,
                  let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let result = object["result"] as? [String: Any], Set(result.keys) == ["ready"] else {
                throw CompanionControlError.invalidResponse
            }
        } catch { await channel.close(); throw error }
    }

    private static func exchange(_ bytes: Data, channel: any CompanionSecureChannel) async throws -> Data {
        var count = UInt32(bytes.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }; frame.append(bytes)
        try await channel.send(frame)
        let header = try await readExactly(4, channel: channel)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...98_304).contains(length) else { throw CompanionControlError.invalidResponse }
        return try await readExactly(length, channel: channel)
    }

    private static func readExactly(_ count: Int, channel: any CompanionSecureChannel) async throws -> Data {
        var result = Data()
        while result.count < count {
            let limit = min(16 * 1024, count - result.count)
            let bytes = try await channel.receive(maximumBytes: limit)
            guard !bytes.isEmpty, bytes.count <= limit else { throw CompanionControlError.invalidResponse }
            result.append(bytes)
        }
        return result
    }

    private struct Empty: Encodable {}
    private struct Request: Encodable {
        let version: Int; let id, operation, grantId: String; let parameters: Empty
    }
    private struct Ready: Decodable { let ready: Bool }
    private struct Reply: Decodable {
        let version: Int; let id: String; let ok: Bool; let result: Ready?; let errorCode: String?
    }
}
