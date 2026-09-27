import Foundation

public enum CompanionIPCCodec {
    private static let requestKeys: Set<String> = ["version", "id", "connectionID", "operation", "payload"]
    private static let replyKeys: Set<String> = ["version", "id", "connectionID", "ok", "payload", "errorCode"]

    public static func encodeRequest(_ request: CompanionIPCRequest) throws -> Data {
        try validate(request); let bytes = try encode(request)
        guard bytes.count <= CompanionIPCLimits.frameBytes else { throw CompanionIPCError.invalidFrame }
        return bytes
    }
    public static func decodeRequest(_ data: Data) throws -> CompanionIPCRequest {
        do {
            try StrictCompanionJSON.validate(data, requiredKeys: requestKeys)
            try canonicalData(data, keys: ["payload"])
            let value = try JSONDecoder().decode(CompanionIPCRequest.self, from: data)
            try validate(value); return value
        } catch let error as CompanionIPCError { throw error }
        catch { throw CompanionIPCError.invalidFrame }
    }
    public static func encodeReply(_ reply: CompanionIPCReply) throws -> Data {
        try validate(reply); let bytes = try encode(reply)
        guard bytes.count <= CompanionIPCLimits.frameBytes else { throw CompanionIPCError.invalidFrame }
        return bytes
    }
    public static func decodeReply(_ data: Data) throws -> CompanionIPCReply {
        do {
            try StrictCompanionJSON.validate(data, requiredKeys: replyKeys)
            try canonicalData(data, keys: ["payload"], nullable: ["payload"])
            let value = try JSONDecoder().decode(CompanionIPCReply.self, from: data)
            try validate(value); return value
        } catch let error as CompanionIPCError { throw error }
        catch { throw CompanionIPCError.invalidFrame }
    }
    public static func encodePayload<T: CompanionIPCPayload>(_ value: T) throws -> Data {
        do {
            try value.validate(); let bytes = try encode(value)
            try StrictCompanionJSON.validate(bytes, requiredKeys: T.requiredKeys, maximumBytes: CompanionIPCLimits.payloadBytes)
            try canonicalData(bytes, keys: T.dataKeys); return bytes
        } catch { throw CompanionIPCError.invalidPayload }
    }
    public static func decodePayload<T: CompanionIPCPayload>(_ bytes: Data, as type: T.Type = T.self) throws -> T {
        do {
            try StrictCompanionJSON.validate(bytes, requiredKeys: T.requiredKeys, maximumBytes: CompanionIPCLimits.payloadBytes)
            try canonicalData(bytes, keys: T.dataKeys)
            let result = try JSONDecoder().decode(type, from: bytes); try result.validate(); return result
        } catch { throw CompanionIPCError.invalidPayload }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func validate(_ value: CompanionIPCRequest) throws {
        guard value.version == (value.operation.isLaneOperation ? 2 : 1) else { throw CompanionIPCError.unsupportedVersion }
        guard nonzero(value.id), nonzero(value.connectionID), value.payload.count <= CompanionIPCLimits.payloadBytes else {
            throw CompanionIPCError.invalidFrame
        }
    }
    private static func validate(_ value: CompanionIPCReply) throws {
        guard value.version == 1 || value.version == 2 else { throw CompanionIPCError.unsupportedVersion }
        guard nonzero(value.id), nonzero(value.connectionID), (value.payload?.count ?? 0) <= CompanionIPCLimits.payloadBytes else {
            throw CompanionIPCError.invalidFrame
        }
        if value.ok {
            guard value.errorCode == nil else { throw CompanionIPCError.invalidFrame }
        } else {
            guard value.payload == nil, let code = value.errorCode, (1...80).contains(code.utf8.count),
                  code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                throw CompanionIPCError.invalidFrame
            }
        }
    }
    private static func nonzero(_ id: UUID) -> Bool { id.uuidString != "00000000-0000-0000-0000-000000000000" }
    private static func canonicalData(_ data: Data, keys: Set<String>, nullable: Set<String> = []) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompanionIPCError.invalidFrame }
        for key in keys {
            if nullable.contains(key), object[key] is NSNull { continue }
            guard let text = object[key] as? String, let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else {
                throw CompanionIPCError.invalidFrame
            }
        }
    }
}
