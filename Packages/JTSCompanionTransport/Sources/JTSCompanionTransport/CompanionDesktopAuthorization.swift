import CryptoKit
import Foundation
import JTSCompanionIPC

extension CompanionDesktopAcknowledgement: ControlResult { static var fields: Set<String> { requiredKeys } }

struct DesktopGrantProof: Codable {
    var version: Int = 1
    let relayOrigin, targetBinding, companionDeviceId, controllerDeviceId: String
    let pairingId, controlGrantId, desktopGrantId: String
    let issuedAtUnixSeconds, expiresAtUnixSeconds: Int64
    let controllerSpkiBase64, signatureBase64: String
    var canonical: Data {
        Data(["jts-desktop-grant-v1", "1", relayOrigin, targetBinding, companionDeviceId,
              controllerDeviceId, pairingId, controlGrantId, desktopGrantId,
              String(issuedAtUnixSeconds), String(expiresAtUnixSeconds), controllerSpkiBase64]
            .joined(separator: "\n").utf8)
    }
}

public extension CompanionControlClient {
    func authorizeDesktop(_ input: CompanionIPCDesktopAuthorization, identity: RelayIdentity,
                          endpoint: RelayEndpoint, peerSPKI: Data, now: Date = Date()) async throws -> CompanionDesktopAcknowledgement {
        try input.validate()
        let issued = input.issuedAtUnixSeconds
        let current = Int64(now.timeIntervalSince1970)
        guard issued <= current + 120, input.expiresAtUnixSeconds > current,
              input.expiresAtUnixSeconds - issued <= 366 * 86400 else { throw CompanionControlError.invalidRequest }
        let unsigned = DesktopGrantProof(relayOrigin: endpoint.canonicalOrigin, targetBinding: input.targetBinding,
            companionDeviceId: RelayIdentity.deviceID(publicKeySPKI: peerSPKI), controllerDeviceId: identity.deviceID,
            pairingId: try ControlLimits.canonical(input.pairingID), controlGrantId: try ControlLimits.canonical(input.controlGrantID),
            desktopGrantId: try ControlLimits.canonical(input.desktopGrantID), issuedAtUnixSeconds: issued,
            expiresAtUnixSeconds: input.expiresAtUnixSeconds, controllerSpkiBase64: identity.publicKeySPKI.base64EncodedString(), signatureBase64: "")
        let signed = DesktopGrantProof(relayOrigin: unsigned.relayOrigin, targetBinding: unsigned.targetBinding,
            companionDeviceId: unsigned.companionDeviceId, controllerDeviceId: unsigned.controllerDeviceId,
            pairingId: unsigned.pairingId, controlGrantId: unsigned.controlGrantId, desktopGrantId: unsigned.desktopGrantId,
            issuedAtUnixSeconds: issued, expiresAtUnixSeconds: input.expiresAtUnixSeconds,
            controllerSpkiBase64: unsigned.controllerSpkiBase64, signatureBase64: try identity.signDesktopBinding(unsigned.canonical))
        let result: CompanionDesktopAcknowledgement = try await request("desktop.authorize", grantID: input.controlGrantID, parameters: signed)
        try result.validate()
        let hash = SHA256.hash(data: unsigned.canonical).map { String(format: "%02x", $0) }.joined()
        guard result.desktopGrantId == signed.desktopGrantId, result.pairingId == signed.pairingId,
              result.targetBinding == signed.targetBinding, result.companionDeviceId == signed.companionDeviceId,
              result.controllerDeviceId == signed.controllerDeviceId, result.proofSha256 == hash,
              result.committedAtUnixSeconds >= issued - 120, result.committedAtUnixSeconds <= current + 120,
              result.committedAtUnixSeconds < input.expiresAtUnixSeconds else {
            await close(); throw CompanionControlError.invalidResponse
        }
        let proof = Data(["jts-desktop-grant-ack-v1", "1", result.desktopGrantId, result.pairingId,
            result.targetBinding, result.companionDeviceId, result.controllerDeviceId, result.proofSha256,
            String(result.committedAtUnixSeconds)].joined(separator: "\n").utf8)
        let key = try P256.Signing.PublicKey(derRepresentation: peerSPKI)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: result.signatureBase64)!)
        guard key.isValidSignature(signature, for: proof) else { await close(); throw CompanionControlError.invalidResponse }
        return result
    }
}
