import CryptoKit
import Foundation

/// Callers persist keys in the credential vault/Keychain. This value never persists or logs them.
public struct RelayIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let key: P256.Signing.PrivateKey
    public let deviceID: String
    public var publicKeySPKI: Data { key.publicKey.derRepresentation }
    var privateKeyDER: Data { key.derRepresentation }
    public var description: String { "RelayIdentity (private key omitted)" }
    public var debugDescription: String { description }

    public init(privateKey: P256.Signing.PrivateKey) {
        key = privateKey
        deviceID = Self.deviceID(publicKeySPKI: privateKey.publicKey.derRepresentation)
    }

    public static func deviceID(publicKeySPKI: Data) -> String {
        SHA256.hash(data: publicKeySPKI).map { String(format: "%02x", $0) }.joined()
    }

    public static func validateDeviceID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func signDesktopBinding(_ proof: Data) throws -> String {
        try key.signature(for: proof).rawRepresentation.base64EncodedString()
    }

    public func proof(endpoint: RelayEndpoint, operation: RelayOperation, challenge: RelayChallenge,
                      payload: Data, now: Date = Date()) throws -> RelayProof {
        let canonical = try Self.canonicalProof(endpoint: endpoint, deviceID: deviceID, operation: operation,
                                               challenge: challenge, payload: payload, now: now)
        return RelayProof(deviceId: deviceID, challengeId: challenge.challengeId,
                          payloadBase64: payload.base64EncodedString(),
                          signatureBase64: try key.signature(for: canonical).rawRepresentation.base64EncodedString())
    }

    public static func canonicalProof(endpoint: RelayEndpoint, deviceID: String, operation: RelayOperation,
                                      challenge: RelayChallenge, payload: Data,
                                      now: Date = Date()) throws -> Data {
        guard validateDeviceID(deviceID), UUID(uuidString: challenge.challengeId) != nil,
              let nonce = Data(base64Encoded: challenge.nonceBase64), nonce.count == 32,
              nonce.base64EncodedString() == challenge.nonceBase64,
              payload.count <= RelayLimits.payloadBytes,
              (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else {
            throw CompanionTransportError.invalidChallenge
        }
        let epoch = Int64(now.timeIntervalSince1970)
        guard challenge.expiresAtUnixSeconds > epoch,
              challenge.expiresAtUnixSeconds <= epoch + 65 else {
            throw CompanionTransportError.invalidChallenge
        }
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return Data(["JTS-RELAY-AUTH-V2", endpoint.canonicalOrigin, deviceID, operation.rawValue, challenge.challengeId,
                     challenge.nonceBase64, hash].joined(separator: "\n").utf8)
    }
}
