import Foundation

public struct CompanionIPCSubmit: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["grantID", "jobID", "kind", "deadlineUnixMilliseconds", "allowDisconnected", "payload"]
    public static let dataKeys: Set<String> = ["payload"]
    public let grantID, jobID: UUID
    public let kind: String
    public let deadlineUnixMilliseconds: Int64
    public let allowDisconnected: Bool
    public let payload: Data
    public init(grantID: UUID, jobID: UUID, kind: String, deadlineUnixMilliseconds: Int64, allowDisconnected: Bool, payload: Data) {
        self.grantID = grantID; self.jobID = jobID; self.kind = kind
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds; self.allowDisconnected = allowDisconnected; self.payload = payload
    }
    public func validate() throws {
        try CompanionIPCPayloadValidation.id(grantID); try CompanionIPCPayloadValidation.id(jobID)
        guard (1...64).contains(kind.utf8.count), kind.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              (0...253_402_300_799_999).contains(deadlineUnixMilliseconds),
              !payload.isEmpty, payload.count <= 64 * 1024 else { throw CompanionIPCError.invalidPayload }
    }
}

public struct CompanionIPCOutput: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["grantID", "jobID", "offset", "maximumBytes"]
    public let grantID, jobID: UUID
    public let offset, maximumBytes: Int
    public init(grantID: UUID, jobID: UUID, offset: Int = 0, maximumBytes: Int = 32 * 1024) {
        self.grantID = grantID; self.jobID = jobID; self.offset = offset; self.maximumBytes = maximumBytes
    }
    public func validate() throws {
        try CompanionIPCPayloadValidation.id(grantID); try CompanionIPCPayloadValidation.id(jobID)
        guard (0...1024 * 1024).contains(offset), (1...32 * 1024).contains(maximumBytes) else { throw CompanionIPCError.invalidPayload }
    }
}
