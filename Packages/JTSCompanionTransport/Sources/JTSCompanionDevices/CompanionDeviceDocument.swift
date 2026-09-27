import Foundation

// These types never leave this module. Persistence receives the encoded document only.
struct DeviceDocument: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let schemaVersion: Int
    let identity: StoredDeviceIdentity
    var devices: [StoredDevice]
    var description: String { "DeviceDocument (private contents redacted)" }
    var debugDescription: String { description }
    var snapshot: CompanionDeviceSnapshot {
        CompanionDeviceSnapshot(identityID: identity.identityID, deviceID: identity.deviceID,
            publicSPKI: identity.publicSPKI, createdAt: deviceDate(identity.createdAt), devices: devices.map(\.snapshot))
    }
}

struct StoredDeviceIdentity: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let identityID: UUID
    let deviceID: String
    let publicSPKI, privateKey: Data
    let createdAt: Int64
    var description: String { "StoredDeviceIdentity (private contents redacted)" }
    var debugDescription: String { description }
}

struct StoredDevice: Codable, Equatable {
    let id: UUID
    let name, relayURL, peerDeviceID: String
    let peerSPKI: Data
    let allowWindows10TLS12: Bool
    let confirmedAt: Int64
    var revokedAt: Int64?
    var snapshot: CompanionSavedDevice {
        CompanionSavedDevice(id: id, name: name, relayURL: relayURL, peerDeviceID: peerDeviceID,
            peerSPKI: peerSPKI, allowWindows10TLS12: allowWindows10TLS12,
            confirmedAt: deviceDate(confirmedAt), revokedAt: revokedAt.map(deviceDate))
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, relayURL, peerDeviceID, peerSPKI, allowWindows10TLS12, confirmedAt, revokedAt
    }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id); try fields.encode(name, forKey: .name)
        try fields.encode(relayURL, forKey: .relayURL); try fields.encode(peerDeviceID, forKey: .peerDeviceID)
        try fields.encode(peerSPKI, forKey: .peerSPKI); try fields.encode(allowWindows10TLS12, forKey: .allowWindows10TLS12)
        try fields.encode(confirmedAt, forKey: .confirmedAt); try fields.encode(revokedAt, forKey: .revokedAt)
    }
}

func deviceDate(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
