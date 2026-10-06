import Foundation

public enum RelayLane: String, Codable, CaseIterable, Sendable { case control, file, rdp, desktop }
public enum RelayOperation: String, Codable, Sendable { case presence, devices, sessions, poll }

public enum CompanionTransportError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidIdentity, invalidChallenge, expiredTicket, invalidTicket
    case invalidResponse, unsupportedVersion, responseTooLarge, invalidReady, unexpectedText
    case invalidBinding, frameTooLarge, connectionClosed, authenticationRequired
    case unauthorizedDevice, unsupportedLane, alreadyConnected, operationInProgress
    case tlsUnavailable, tlsHandshakeFailed, tlsPeerRejected
    case remote(String)
}

public enum RelayLimits {
    public static let payloadBytes = 16 * 1024
    public static let responseBytes = 64 * 1024
    public static let webSocketMessageBytes = 64 * 1024
    public static let bindingBytes = 1024
}

/// Transport addressing is independent from the paired endpoint's identity.
public struct RelayEndpoint: Equatable, Sendable {
    public let url: URL
    public var canonicalOrigin: String { url.absoluteString }

    public init(_ url: URL, allowLoopbackHTTP: Bool = false) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CompanionTransportError.invalidEndpoint
        }
        let secure = components.scheme == "https"
        let loopback = ["127.0.0.1", "[::1]", "::1"].contains(host)
        guard secure || (allowLoopbackHTTP && loopback && components.scheme == "http") else {
            throw CompanionTransportError.invalidEndpoint
        }
        components.host = host.lowercased()
        components.path = ""
        if components.port == (secure ? 443 : 80) { components.port = nil }
        guard let normalized = components.url else { throw CompanionTransportError.invalidEndpoint }
        self.url = normalized
    }

    public func httpURL(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CompanionTransportError.invalidEndpoint
        }
        components.path = path
        guard let result = components.url else { throw CompanionTransportError.invalidEndpoint }
        return result
    }

    func channelURL() throws -> URL {
        var components = URLComponents(url: try httpURL(path: "/v1/channel"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }
}

public struct RelayChallenge: Codable, Sendable {
    public let challengeId: String
    public let nonceBase64: String
    public let expiresAtUnixSeconds: Int64

    public init(challengeId: String, nonceBase64: String, expiresAtUnixSeconds: Int64) {
        self.challengeId = challengeId
        self.nonceBase64 = nonceBase64
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
    }
}

public struct RelayProof: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let deviceId: String
    public let challengeId: String
    public let payloadBase64: String
    public let signatureBase64: String
    public var description: String { "RelayProof (credentials omitted)" }
    public var debugDescription: String { description }
}

public struct RelayDevice: Codable, Equatable, Sendable {
    public let deviceId: String
    public let lastSeenAtUnixSeconds: Int64?
}

public final class RelaySessionTicket: Decodable, @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sessionId: String
    let ticket: String
    public let expiresAtUnixSeconds: Int64
    public let channelPath: String
    private let lock = NSLock()
    private var issuer: RelayEndpoint?
    private var claimed = false
    private enum CodingKeys: String, CodingKey { case sessionId, ticket, expiresAtUnixSeconds, channelPath }
    public var description: String { "RelaySessionTicket (credentials omitted)" }
    public var debugDescription: String { description }

    public init(sessionId: String, ticket: String, expiresAtUnixSeconds: Int64, channelPath: String) {
        self.sessionId = sessionId
        self.ticket = ticket
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
        self.channelPath = channelPath
    }

    public func validate(now: Date = Date()) throws {
        guard UUID(uuidString: sessionId) != nil, channelPath == "/v1/channel",
              ticket.utf8.count == 43,
              ticket.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let decoded = Data(base64Encoded: ticket.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="), decoded.count == 32 else {
            throw CompanionTransportError.invalidTicket
        }
        let epoch = Int64(now.timeIntervalSince1970)
        guard expiresAtUnixSeconds > epoch, expiresAtUnixSeconds <= epoch + 65 else {
            throw CompanionTransportError.expiredTicket
        }
    }

    func bindIssuer(_ endpoint: RelayEndpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard issuer == nil, !claimed else { throw CompanionTransportError.invalidTicket }
        issuer = endpoint
    }

    func claim(endpoint: RelayEndpoint) throws {
        try validate()
        lock.lock()
        defer { lock.unlock() }
        guard issuer == endpoint, !claimed else { throw CompanionTransportError.invalidTicket }
        claimed = true
    }
}

public struct RelaySessionOffer: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sessionId: String
    public let lane: RelayLane
    public let controllerDeviceId: String
    private let ticket: String
    public let expiresAtUnixSeconds: Int64
    public let channelPath: String
    private var issuedTicket: RelaySessionTicket?
    private enum CodingKeys: String, CodingKey {
        case sessionId, lane, controllerDeviceId, ticket, expiresAtUnixSeconds, channelPath
    }
    public var description: String { "RelaySessionOffer (credentials omitted)" }
    public var debugDescription: String { description }

    public var sessionTicket: RelaySessionTicket {
        issuedTicket ?? RelaySessionTicket(sessionId: sessionId, ticket: ticket,
                           expiresAtUnixSeconds: expiresAtUnixSeconds, channelPath: channelPath)
    }

    mutating func bindIssuer(_ endpoint: RelayEndpoint) throws {
        let value = sessionTicket
        try value.bindIssuer(endpoint)
        issuedTicket = value
    }
}

public struct RelayInfo: Decodable, Sendable {
    public let protocolVersion: Int
    public let lanes: [RelayLane]
}

/// Additive capabilities live outside the frozen, three-lane `/v1/info` response.
public struct RelayCapabilities: Decodable, Sendable {
    public let protocolVersion: Int
    public let extensions: [String]
    public let lanes: [RelayLane]
    public let desktopMaximumBufferedBytes: Int
    public let desktopBytesPerSecond: Int

    public func validate() throws {
        guard protocolVersion == 1 else { throw CompanionTransportError.unsupportedVersion }
        guard !extensions.isEmpty, extensions.count <= 16,
              Set(extensions).count == extensions.count,
              extensions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy {
                  (97...122).contains($0) || (48...57).contains($0) || $0 == 45
              }}), lanes.count <= 4, Set(lanes).count == lanes.count,
              Set([RelayLane.control, .file, .rdp]).isSubset(of: Set(lanes)),
              lanes.contains(.desktop) == extensions.contains("desktop-v1"),
              (1...65_536).contains(desktopMaximumBufferedBytes),
              (16_384...1_073_741_824).contains(desktopBytesPerSecond) else {
            throw CompanionTransportError.invalidResponse
        }
    }
}

enum RelayJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
