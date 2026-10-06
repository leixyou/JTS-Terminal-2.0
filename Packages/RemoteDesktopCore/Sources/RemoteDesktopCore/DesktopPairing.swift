import Foundation
import Security

public enum DesktopSecret {
    public static func randomData() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw DesktopProtocolError.invalidSecret }
        return data
    }

    public static func randomToken() throws -> String { try randomData().desktopBase64URL }

    public static func validate(_ token: String) throws {
        guard token.utf8.count == 43, let bytes = Data(desktopBase64URL: token), bytes.count == 32,
              bytes.desktopBase64URL == token else { throw DesktopProtocolError.invalidSecret }
    }

    /// Avoid short-circuiting comparisons of authentication credentials.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == 43, rhs.utf8.count == 43 else { return false }
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

public struct DesktopPairingInvitation: Codable, Equatable, Sendable {
    public var version: Int
    public var serverID: UUID
    public var host: String
    public var port: UInt16
    public var psk: Data
    public var invitationToken: String
    public var expiresAt: Date

    public init(serverID: UUID, host: String, port: UInt16, psk: Data, invitationToken: String, expiresAt: Date) {
        version = DesktopProtocol.version
        self.serverID = serverID
        self.host = host
        self.port = port
        self.psk = psk
        self.invitationToken = invitationToken
        self.expiresAt = expiresAt
    }

    public init(code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "jtsmac://pair/"
        guard trimmed.utf8.count <= 4_096, trimmed.hasPrefix(prefix),
              let data = Data(desktopBase64URL: String(trimmed.dropFirst(prefix.count))) else {
            throw DesktopProtocolError.invalidInvitation
        }
        do { self = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw DesktopProtocolError.invalidInvitation }
        try validate()
    }

    public func encodedCode() throws -> String {
        try validate()
        return "jtsmac://pair/" + (try JSONEncoder().encode(self)).desktopBase64URL
    }

    public func validate(now: Date? = nil) throws {
        guard version == DesktopProtocol.version else { throw DesktopProtocolError.unsupportedVersion }
        guard port > 0, psk.count == 32, !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || ".:-_%".unicodeScalars.contains($0)
              }), expiresAt.timeIntervalSince1970.isFinite else {
            throw DesktopProtocolError.invalidInvitation
        }
        try DesktopSecret.validate(invitationToken)
        if let now, expiresAt <= now { throw DesktopProtocolError.invitationExpired }
    }
}

public enum DesktopAuthenticationDecision: Equatable, Sendable {
    case authorized
    case approvalRequired
    case rejected
}

/// Pure authorization policy; the host owns local approval, persistence and transport-key rotation.
public struct DesktopPairingAuthority: Sendable {
    public private(set) var invitationToken: String?
    public private(set) var expiresAt: Date?
    public private(set) var authorizedClients: [UUID: String]

    public init(invitationToken: String?, expiresAt: Date?, authorizedClients: [UUID: String] = [:]) {
        self.invitationToken = invitationToken
        self.expiresAt = expiresAt
        self.authorizedClients = authorizedClients
    }

    public func evaluate(_ authentication: DesktopAuthentication, now: Date = Date()) -> DesktopAuthenticationDecision {
        guard (try? authentication.validate()) != nil else { return .rejected }
        if let token = authentication.token {
            guard let stored = authorizedClients[authentication.clientID], DesktopSecret.matches(stored, token) else {
                return .rejected
            }
            return .authorized
        }
        guard let candidate = authentication.invitationToken, let invitationToken,
              let expiresAt, expiresAt > now, DesktopSecret.matches(candidate, invitationToken) else { return .rejected }
        return .approvalRequired
    }

    public mutating func approve(_ authentication: DesktopAuthentication, token: String, now: Date = Date()) throws {
        guard evaluate(authentication, now: now) == .approvalRequired else {
            throw DesktopProtocolError.invitationUnavailable
        }
        try DesktopSecret.validate(token)
        authorizedClients[authentication.clientID] = token
        invitationToken = nil
        expiresAt = nil
    }

    public mutating func revoke(clientID: UUID) { authorizedClients.removeValue(forKey: clientID) }
}

extension Data {
    var desktopBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(desktopBase64URL text: String) {
        guard !text.isEmpty, text.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        self.init(base64Encoded: padded)
    }
}
