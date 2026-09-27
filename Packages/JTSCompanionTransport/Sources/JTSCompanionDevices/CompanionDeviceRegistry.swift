import CryptoKit
import Foundation
import JTSCompanionIPC
import JTSRelayEnrollment

/// Owns local trust, not remote pairing or authorization. Every operation reloads durable state.
public actor CompanionDeviceRegistry {
    private let persistence: any CompanionDevicePersistence
    private var identity: StoredDeviceIdentity?
    private var observedDocument = false
    private var observedDevices: [UUID: StoredDevice] = [:]
    private var busy = false

    public init(persistence: any CompanionDevicePersistence) { self.persistence = persistence }

    public nonisolated static func peerDeviceID(forSPKI spki: Data) throws -> String {
        try CompanionDeviceCodec.peerDeviceID(spki)
    }

    public func snapshot() async throws -> CompanionDeviceSnapshot? {
        try begin(); defer { busy = false }
        return try await load()?.document.snapshot
    }

    public func initialize() async throws -> CompanionDeviceSnapshot {
        try begin(); defer { busy = false }
        guard try await load() == nil else { throw CompanionDeviceError.alreadyInitialized }
        let key = P256.Signing.PrivateKey()
        let value = StoredDeviceIdentity(identityID: UUID(), deviceID: try Self.peerDeviceID(forSPKI: key.publicKey.derRepresentation),
            publicSPKI: key.publicKey.derRepresentation, privateKey: key.rawRepresentation, createdAt: CompanionDeviceCodec.now())
        let document = DeviceDocument(schemaVersion: 1, identity: value, devices: [])
        let raw = try CompanionDeviceCodec.encode(document)
        do { try await persistence.create(raw) } catch { throw storageError(error) }
        identity = value
        observedDocument = true
        return document.snapshot
    }

    public func addDevice(name: String, relayURL: String, peerSPKI: Data, allowWindows10TLS12: Bool = false,
                          verifiedPeerDeviceID: String) async throws -> CompanionSavedDevice {
        try begin(); defer { busy = false }
        guard var stored = try await load() else { throw CompanionDeviceError.notInitialized }
        let peerID = try Self.peerDeviceID(forSPKI: peerSPKI)
        guard peerID == verifiedPeerDeviceID, peerID != stored.document.identity.deviceID else {
            throw CompanionDeviceError.invalidInput
        }
        guard !stored.document.devices.contains(where: { $0.peerDeviceID == peerID }) else {
            throw CompanionDeviceError.deviceAlreadyKnown
        }
        guard stored.document.devices.count < CompanionDeviceCodec.maximumRecords else { throw CompanionDeviceError.capacityReached }
        let device = StoredDevice(id: UUID(), name: try CompanionDeviceCodec.name(name),
            relayURL: try CompanionDeviceCodec.origin(relayURL), peerDeviceID: peerID, peerSPKI: peerSPKI,
            allowWindows10TLS12: allowWindows10TLS12, confirmedAt: CompanionDeviceCodec.now(), revokedAt: nil)
        stored.document.devices.append(device)
        try await replace(stored.document, expected: stored.raw)
        return device.snapshot
    }

    public func revokeDevice(id: UUID) async throws -> CompanionDeviceSnapshot {
        try begin(); defer { busy = false }
        guard var stored = try await load() else { throw CompanionDeviceError.notInitialized }
        guard let index = stored.document.devices.firstIndex(where: { $0.id == id }) else { throw CompanionDeviceError.deviceNotFound }
        if stored.document.devices[index].revokedAt == nil {
            stored.document.devices[index].revokedAt = max(CompanionDeviceCodec.now(), stored.document.devices[index].confirmedAt)
            try await replace(stored.document, expected: stored.raw)
        }
        return stored.document.snapshot
    }

    public func openConfiguration(deviceID: UUID) async throws -> CompanionIPCOpen {
        try begin(); defer { busy = false }
        guard let stored = try await load() else { throw CompanionDeviceError.notInitialized }
        guard let device = stored.document.devices.first(where: { $0.id == deviceID }) else { throw CompanionDeviceError.deviceNotFound }
        guard device.revokedAt == nil else { throw CompanionDeviceError.deviceRevoked }
        let configuration = CompanionIPCOpen(privateKey: stored.document.identity.privateKey, peerSPKI: device.peerSPKI,
            relayURL: device.relayURL, allowWindows10TLS12: device.allowWindows10TLS12)
        do { try configuration.validate() } catch { throw CompanionDeviceError.corruptState }
        return configuration
    }

    /// Returns a signing client, never raw private material to the GUI or MCP response.
    public func enrollmentClient(relayOrigin: String) async throws -> EnrollmentClient {
        try begin(); defer { busy = false }
        guard let stored = try await load() else { throw CompanionDeviceError.notInitialized }
        return try EnrollmentClient(privateKey: stored.document.identity.privateKey, relayOrigin: relayOrigin)
    }

    private func begin() throws {
        guard !busy else { throw CompanionDeviceError.operationInProgress }
        busy = true
    }

    private func load() async throws -> (raw: String, document: DeviceDocument)? {
        let raw: String?
        do { raw = try await persistence.load() } catch { throw storageError(error) }
        guard let raw else {
            guard !observedDocument else { throw CompanionDeviceError.missingState }
            return nil
        }
        observedDocument = true
        let document = try CompanionDeviceCodec.decode(raw)
        if let identity, identity != document.identity { throw CompanionDeviceError.identityChanged }
        let devices = Dictionary(uniqueKeysWithValues: document.devices.map { ($0.id, $0) })
        for (id, previous) in observedDevices {
            guard var current = devices[id], previous.revokedAt == nil || previous.revokedAt == current.revokedAt else {
                throw CompanionDeviceError.corruptState
            }
            current.revokedAt = previous.revokedAt
            guard current == previous else { throw CompanionDeviceError.corruptState }
        }
        identity = document.identity
        observedDevices = devices
        return (raw, document)
    }

    private func replace(_ document: DeviceDocument, expected: String) async throws {
        let raw = try CompanionDeviceCodec.encode(document)
        do { try await persistence.replace(expected: expected, with: raw) } catch { throw storageError(error) }
        observedDevices = Dictionary(uniqueKeysWithValues: document.devices.map { ($0.id, $0) })
    }

    private func storageError(_ error: Error) -> CompanionDeviceError {
        if let error = error as? CompanionDevicePersistenceError, error == .conflict || error == .alreadyExists {
            return .storageConflict
        }
        return .storageUnavailable
    }
}
