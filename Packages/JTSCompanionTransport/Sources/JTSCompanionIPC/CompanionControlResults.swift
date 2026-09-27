import Foundation

public enum CompanionJobState: String, Codable, Sendable {
    case queued, running, cancelling, succeeded, failed, cancelled, expired, interrupted
}

public struct CompanionControlStatus: CompanionIPCPayload {
    public let capabilities: [String]
    public let maximumPayloadBytes: Int
    public let maximumOutputChunkBytes: Int
    public static let requiredKeys: Set<String> = ["capabilities", "maximumPayloadBytes", "maximumOutputChunkBytes"]

    public func validate() throws {
        guard Set(capabilities).count == capabilities.count,
              Set(capabilities).isSubset(of: ["device.status", "job.submit", "job.get", "job.cancel", "job.output"]),
              (1...65536).contains(maximumPayloadBytes), (1...32768).contains(maximumOutputChunkBytes) else {
            throw ControlResultValidationError.invalidValue
        }
    }
}

public struct CompanionJobReceipt: CompanionIPCPayload {
    public let jobId, grantId, kind: String
    public let deadlineUnixMilliseconds: Int64
    public let allowDisconnected: Bool
    public let state: CompanionJobState
    public let submittedAtUnixMilliseconds: Int64
    public let startedAtUnixMilliseconds, completedAtUnixMilliseconds: Int64?
    public let resultCode: String?
    public let outputBytes: Int
    public let dataExpired: Bool
    public static let requiredKeys: Set<String> = ["jobId", "grantId", "kind", "deadlineUnixMilliseconds", "allowDisconnected",
        "state", "submittedAtUnixMilliseconds", "startedAtUnixMilliseconds", "completedAtUnixMilliseconds",
        "resultCode", "outputBytes", "dataExpired"]
    private enum CodingKeys: String, CodingKey {
        case jobId, grantId, kind, deadlineUnixMilliseconds, allowDisconnected, state, submittedAtUnixMilliseconds
        case startedAtUnixMilliseconds, completedAtUnixMilliseconds, resultCode, outputBytes, dataExpired
    }

    public func validate() throws {
        guard Self.identifier(jobId), Self.identifier(grantId), (1...64).contains(kind.utf8.count),
              kind.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }),
              (0...1_048_576).contains(outputBytes), (resultCode?.utf8.count ?? 0) <= 128,
              [deadlineUnixMilliseconds, submittedAtUnixMilliseconds, startedAtUnixMilliseconds ?? 0,
               completedAtUnixMilliseconds ?? 0].allSatisfy({ (0...253_402_300_799_999).contains($0) }) else {
            throw ControlResultValidationError.invalidValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(jobId, forKey: .jobId); try values.encode(grantId, forKey: .grantId)
        try values.encode(kind, forKey: .kind); try values.encode(deadlineUnixMilliseconds, forKey: .deadlineUnixMilliseconds)
        try values.encode(allowDisconnected, forKey: .allowDisconnected); try values.encode(state, forKey: .state)
        try values.encode(submittedAtUnixMilliseconds, forKey: .submittedAtUnixMilliseconds)
        try values.encode(startedAtUnixMilliseconds, forKey: .startedAtUnixMilliseconds)
        try values.encode(completedAtUnixMilliseconds, forKey: .completedAtUnixMilliseconds)
        try values.encode(resultCode, forKey: .resultCode); try values.encode(outputBytes, forKey: .outputBytes)
        try values.encode(dataExpired, forKey: .dataExpired)
    }

    private static func identifier(_ value: String) -> Bool {
        guard let id = UUID(uuidString: value), value == id.uuidString.lowercased() else { return false }
        return value != "00000000-0000-0000-0000-000000000000"
    }
}

public struct CompanionJobOutput: CompanionIPCPayload, CustomStringConvertible, CustomDebugStringConvertible {
    public let jobId: String
    public let offset, nextOffset, outputBytes: Int
    public let dataBase64: String
    public var data: Data { Data(base64Encoded: dataBase64) ?? Data() }
    public var description: String { "CompanionJobOutput (content omitted)" }
    public var debugDescription: String { description }
    public static let requiredKeys: Set<String> = ["jobId", "offset", "nextOffset", "outputBytes", "dataBase64"]

    public func validate() throws {
        guard let id = UUID(uuidString: jobId), jobId == id.uuidString.lowercased(),
              jobId != "00000000-0000-0000-0000-000000000000",
              (0...1_048_576).contains(offset), (offset...1_048_576).contains(nextOffset),
              (nextOffset...1_048_576).contains(outputBytes),
              let bytes = Data(base64Encoded: dataBase64), bytes.base64EncodedString() == dataBase64,
              bytes.count <= 32768, nextOffset-offset == bytes.count else { throw ControlResultValidationError.invalidValue }
    }
}

private enum ControlResultValidationError: Error { case invalidValue }
