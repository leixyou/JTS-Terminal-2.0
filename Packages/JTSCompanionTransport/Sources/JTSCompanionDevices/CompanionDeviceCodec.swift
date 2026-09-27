import CryptoKit
import Foundation
import JTSCompanionIPC

enum CompanionDeviceCodec {
    static let maximumRecords = 256
    static let maximumBytes = CompanionIPCLimits.frameBytes
    private static let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func peerDeviceID(_ spki: Data) throws -> String {
        guard spki.count <= 512, let key = try? P256.Signing.PublicKey(derRepresentation: spki),
              key.derRepresentation == spki else { throw CompanionDeviceError.invalidInput }
        // Identical SHA-256-over-canonical-SPKI representation to the relay's RelayIdentity.
        return SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
    }

    static func name(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(result.utf8.count),
              !result.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CompanionDeviceError.invalidInput
        }
        return result
    }

    static func origin(_ value: String) throws -> String {
        do {
            try CompanionIPCOpen(privateKey: Data(repeating: 0, count: 32), peerSPKI: Data([1]), relayURL: value).validate()
            guard var parts = URLComponents(string: value) else { throw CompanionDeviceError.invalidInput }
            parts.host = parts.host?.lowercased(); parts.path = ""
            if parts.port == 443 { parts.port = nil }
            guard let result = parts.string else { throw CompanionDeviceError.invalidInput }
            return result
        } catch { throw CompanionDeviceError.invalidInput }
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func validTime(_ value: Int64) -> Bool { (0...253_402_300_799_000).contains(value) }

    static func encode(_ document: DeviceDocument) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw CompanionDeviceError.capacityReached }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) throws -> DeviceDocument {
        do {
            guard !raw.isEmpty, raw.utf8.count <= maximumBytes else { throw CompanionDeviceError.corruptState }
            let data = Data(raw.utf8)
            try StrictCompanionJSON.validate(data, requiredKeys: ["schemaVersion", "identity", "devices"])
            let document = try JSONDecoder().decode(DeviceDocument.self, from: data)
            guard document.schemaVersion == 1, document.devices.count <= maximumRecords,
                  document.identity.identityID != zeroID, validTime(document.identity.createdAt),
                  document.identity.privateKey.count == 32,
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: document.identity.privateKey),
                  key.rawRepresentation == document.identity.privateKey,
                  key.publicKey.derRepresentation == document.identity.publicSPKI,
                  try peerDeviceID(document.identity.publicSPKI) == document.identity.deviceID else {
                throw CompanionDeviceError.corruptState
            }
            var ids = Set<UUID>(), peers = Set<String>()
            for device in document.devices {
                guard device.id != zeroID, ids.insert(device.id).inserted,
                      peers.insert(device.peerDeviceID).inserted, device.peerDeviceID != document.identity.deviceID,
                      try peerDeviceID(device.peerSPKI) == device.peerDeviceID,
                      try name(device.name) == device.name, try origin(device.relayURL) == device.relayURL,
                      validTime(device.confirmedAt),
                      device.revokedAt.map({ validTime($0) && $0 >= device.confirmedAt }) ?? true else {
                    throw CompanionDeviceError.corruptState
                }
            }
            // Exact canonical encoding also rejects unknown nested keys, missing null fields,
            // alternate base64, non-integer number forms, and ambiguous UUID representations.
            guard try encode(document) == raw else { throw CompanionDeviceError.corruptState }
            return document
        } catch { throw CompanionDeviceError.corruptState }
    }
}
