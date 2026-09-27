import Foundation

/// The app adapter MUST use durable encrypted storage with atomic create and compare-and-swap.
/// There is deliberately no default persistence, plaintext fallback, reset, or automatic retry.
public protocol CompanionDevicePersistence: Sendable {
    func load() async throws -> String?
    func create(_ value: String) async throws
    func replace(expected: String, with value: String) async throws
}

public enum CompanionDevicePersistenceError: String, Error, Sendable {
    case alreadyExists, conflict, unavailable
}

public enum CompanionDeviceError: String, Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case notInitialized, alreadyInitialized, missingState, corruptState, identityChanged
    case invalidInput, deviceNotFound, deviceRevoked, deviceAlreadyKnown, capacityReached
    case operationInProgress, storageConflict, storageUnavailable
    public var description: String { "CompanionDeviceError.\(rawValue)" }
    public var debugDescription: String { description }
}

/// Local peer trust only: not Windows pairing approval, capability authorization, or an MCP grant.
public struct CompanionSavedDevice: Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let name, relayURL, peerDeviceID: String
    public let peerSPKI: Data
    public let allowWindows10TLS12: Bool
    public let confirmedAt: Date
    public let revokedAt: Date?
    public var description: String { "CompanionSavedDevice (contents redacted)" }
    public var debugDescription: String { description }
}

/// Public identity and trust metadata only; the private key is never part of a snapshot.
public struct CompanionDeviceSnapshot: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let identityID: UUID
    public let deviceID: String
    public let publicSPKI: Data
    public let createdAt: Date
    public let devices: [CompanionSavedDevice]
    public var description: String { "CompanionDeviceSnapshot (contents redacted)" }
    public var debugDescription: String { description }
}
