import Foundation

public protocol CompanionIPCPayload: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static var requiredKeys: Set<String> { get }
    static var dataKeys: Set<String> { get }
    func validate() throws
}
public extension CompanionIPCPayload {
    static var dataKeys: Set<String> { [] }
    var description: String { "\(Self.self) (contents redacted)" }
    var debugDescription: String { description }
}

public struct CompanionIPCEmpty: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = []
    public init() {}
    public func validate() throws {}
}

public struct CompanionIPCOpen: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["privateKey", "peerSPKI", "relayURL", "allowWindows10TLS12"]
    public static let dataKeys: Set<String> = ["privateKey", "peerSPKI"]
    public let privateKey, peerSPKI: Data
    public let relayURL: String
    public let allowWindows10TLS12: Bool
    public init(privateKey: Data, peerSPKI: Data, relayURL: String, allowWindows10TLS12: Bool = false) {
        self.privateKey = privateKey; self.peerSPKI = peerSPKI
        self.relayURL = relayURL; self.allowWindows10TLS12 = allowWindows10TLS12
    }
    public func validate() throws {
        guard privateKey.count == 32, (1...512).contains(peerSPKI.count),
              (1...2048).contains(relayURL.utf8.count),
              !relayURL.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\\" }),
              let url = URLComponents(string: relayURL), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.url != nil,
              url.port == nil || (1...65535).contains(url.port!) else { throw CompanionIPCError.invalidPayload }
        // ASN.1/P-256 and pinned TLS verification belong exclusively to the sandbox helper.
    }
}

public struct CompanionIPCGrant: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["grantID"]
    public let grantID: UUID
    public init(grantID: UUID) { self.grantID = grantID }
    public func validate() throws { try CompanionIPCPayloadValidation.id(grantID) }
}

public struct CompanionIPCJob: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["grantID", "jobID"]
    public let grantID, jobID: UUID
    public init(grantID: UUID, jobID: UUID) { self.grantID = grantID; self.jobID = jobID }
    public func validate() throws { try CompanionIPCPayloadValidation.id(grantID); try CompanionIPCPayloadValidation.id(jobID) }
}

public struct CompanionIPCState: CompanionIPCPayload, Equatable {
    public static let requiredKeys: Set<String> = ["phase", "sessionID"]
    public let phase: String
    public let sessionID: String?
    public init(phase: String, sessionID: String? = nil) { self.phase = phase; self.sessionID = sessionID }
    public func validate() throws {
        guard ["connecting", "connected", "disconnected", "failed"].contains(phase) else { throw CompanionIPCError.invalidPayload }
        if phase == "connected" {
            guard let sessionID, sessionID.count == 36, let id = UUID(uuidString: sessionID) else { throw CompanionIPCError.invalidPayload }
            try CompanionIPCPayloadValidation.id(id)
        } else if sessionID != nil { throw CompanionIPCError.invalidPayload }
    }
    private enum CodingKeys: String, CodingKey { case phase, sessionID }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(phase, forKey: .phase); try fields.encode(sessionID, forKey: .sessionID)
    }
}

enum CompanionIPCPayloadValidation {
    static func id(_ value: UUID) throws {
        guard value.uuidString != "00000000-0000-0000-0000-000000000000" else { throw CompanionIPCError.invalidPayload }
    }
}
