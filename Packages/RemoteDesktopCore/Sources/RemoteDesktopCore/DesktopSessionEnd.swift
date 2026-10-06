import Foundation

/// A stable reason lets a paired client distinguish an outage from revoked consent.
public enum DesktopSessionEndCode: String, Codable, Equatable, Sendable, CaseIterable {
    case hostStopped
    case revoked
    case rejected
    case invalidCredentials
    case protocolViolation
    case busy
    case permissionRequired
    case captureFailed
    case idleTimeout
    case shutdown

    public var allowsReconnect: Bool {
        switch self {
        case .busy, .permissionRequired, .captureFailed, .idleTimeout, .shutdown:
            return true
        case .hostStopped, .revoked, .rejected, .invalidCredentials, .protocolViolation:
            return false
        }
    }
}

public struct DesktopSessionEnd: Codable, Equatable, Sendable {
    public var code: DesktopSessionEndCode
    public var message: String

    public init(code: DesktopSessionEndCode, message: String) {
        self.code = code
        self.message = message
    }
}
