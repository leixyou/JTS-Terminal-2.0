import Foundation

public enum CompanionIPCLane: String, Codable, Sendable { case file, rdp, desktop }

public struct CompanionIPCLaneOpen: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["privateKey", "peerSPKI", "relayURL", "allowWindows10TLS12", "lane", "grantID"]
    public static let dataKeys: Set<String> = ["privateKey", "peerSPKI"]
    public let privateKey, peerSPKI: Data
    public let relayURL: String
    public let allowWindows10TLS12: Bool
    public let lane: CompanionIPCLane
    public let grantID: UUID
    public init(configuration: CompanionIPCOpen, lane: CompanionIPCLane, grantID: UUID) {
        privateKey = configuration.privateKey; peerSPKI = configuration.peerSPKI
        relayURL = configuration.relayURL; allowWindows10TLS12 = configuration.allowWindows10TLS12
        self.lane = lane; self.grantID = grantID
    }
    public var configuration: CompanionIPCOpen {
        CompanionIPCOpen(privateKey: privateKey, peerSPKI: peerSPKI, relayURL: relayURL,
                         allowWindows10TLS12: allowWindows10TLS12)
    }
    public func validate() throws {
        try configuration.validate(); try CompanionIPCPayloadValidation.id(grantID)
    }
}

public struct CompanionIPCLaneState: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["lane", "sessionID", "maximumChunkBytes"]
    public static let chunkLimit = 64 * 1024
    public let lane: CompanionIPCLane
    public let sessionID: UUID
    public let maximumChunkBytes: Int
    public init(lane: CompanionIPCLane, sessionID: UUID, maximumChunkBytes: Int = chunkLimit) {
        self.lane = lane; self.sessionID = sessionID; self.maximumChunkBytes = maximumChunkBytes
    }
    public func validate() throws {
        try CompanionIPCPayloadValidation.id(sessionID)
        guard maximumChunkBytes == Self.chunkLimit else { throw CompanionIPCError.invalidPayload }
    }
}

public struct CompanionIPCLaneRead: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["maximumBytes", "sequence"]
    public let maximumBytes: Int
    public let sequence: UInt64
    public init(maximumBytes: Int, sequence: UInt64) { self.maximumBytes = maximumBytes; self.sequence = sequence }
    public func validate() throws {
        guard (1...CompanionIPCLaneState.chunkLimit).contains(maximumBytes), sequence > 0 else {
            throw CompanionIPCError.invalidPayload
        }
    }
}

public struct CompanionIPCLaneWrite: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["data", "sequence"]
    public static let dataKeys: Set<String> = ["data"]
    public let data: Data
    public let sequence: UInt64
    public init(data: Data, sequence: UInt64) { self.data = data; self.sequence = sequence }
    public func validate() throws {
        guard (1...CompanionIPCLaneState.chunkLimit).contains(data.count), sequence > 0 else {
            throw CompanionIPCError.invalidPayload
        }
    }
}

public struct CompanionIPCLaneBytes: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["data"]
    public static let dataKeys: Set<String> = ["data"]
    public let data: Data
    public init(_ data: Data) { self.data = data }
    public func validate() throws {
        guard (1...CompanionIPCLaneState.chunkLimit).contains(data.count) else { throw CompanionIPCError.invalidPayload }
    }
}
