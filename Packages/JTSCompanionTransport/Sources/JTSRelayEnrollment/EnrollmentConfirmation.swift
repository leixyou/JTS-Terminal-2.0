import CryptoKit
import Foundation

/// Durable authorization by the controller for one exact claim. Relay state is not authorization.
public struct EnrollmentConfirmation: Codable, Equatable, Sendable {
    public let version: Int
    public let relayOrigin, invitationId, controllerDeviceId, peerDeviceId, claimHash: String
    public let confirmedAtUnixSeconds, expiresAtUnixSeconds: Int64
    public let signatureBase64: String

    init(attempt: EnrollmentAttempt, key: P256.Signing.PrivateKey, now: Date) throws {
        guard let claim = attempt.verifiedClaim else { throw EnrollmentError.invalidMessage }
        let request = try EnrollmentRequest.decode(attempt.request)
        let bundle = try attempt.bundle(for: claim)
        let code = try EnrollmentCode(attempt.code)
        let instant = now.timeIntervalSince1970
        guard instant.isFinite, instant >= 0, instant < Double(Int64.max) else { throw EnrollmentError.invalidMessage }
        let confirmed = Int64(instant)
        let issued = ISO8601DateFormatter().date(from: request.issuedAtUtc)!.timeIntervalSince1970
        guard Double(confirmed) >= issued, confirmed < attempt.expiresAtUnixSeconds else { throw EnrollmentError.expired }
        guard EnrollmentWire.hash(key.publicKey.derRepresentation) == request.controllerDeviceID else {
            throw EnrollmentError.invalidIdentity
        }
        version = 2; relayOrigin = code.relayOrigin; invitationId = attempt.id
        controllerDeviceId = request.controllerDeviceID; peerDeviceId = bundle.peerDeviceID; claimHash = claim.claimHash
        confirmedAtUnixSeconds = confirmed; expiresAtUnixSeconds = attempt.expiresAtUnixSeconds
        signatureBase64 = try key.signature(for: Self.transcript(origin: relayOrigin, invitation: invitationId,
            controller: controllerDeviceId, peer: peerDeviceId, claim: claimHash, confirmed: confirmed,
            expires: expiresAtUnixSeconds)).rawRepresentation.base64EncodedString()
    }

    public func verify(attempt: EnrollmentAttempt) throws {
        guard let claim = attempt.verifiedClaim else { throw EnrollmentError.invalidMessage }
        let request = try EnrollmentRequest.decode(attempt.request)
        let bundle = try attempt.bundle(for: claim)
        let code = try EnrollmentCode(attempt.code)
        let issued = ISO8601DateFormatter().date(from: request.issuedAtUtc)!.timeIntervalSince1970
        guard version == 2, relayOrigin == code.relayOrigin, invitationId == attempt.id,
              controllerDeviceId == request.controllerDeviceID, peerDeviceId == bundle.peerDeviceID,
              claimHash == claim.claimHash, expiresAtUnixSeconds == attempt.expiresAtUnixSeconds,
              Double(confirmedAtUnixSeconds) >= issued, confirmedAtUnixSeconds < expiresAtUnixSeconds else {
            throw EnrollmentError.changed
        }
        let key = try P256.Signing.PublicKey(derRepresentation: EnrollmentWire.base64(request.controllerSPKIBase64, maximum: 512))
        let signature = try EnrollmentWire.base64(signatureBase64, maximum: 64)
        guard signature.count == 64,
              key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature),
                for: Self.transcript(origin: relayOrigin, invitation: invitationId, controller: controllerDeviceId,
                    peer: peerDeviceId, claim: claimHash, confirmed: confirmedAtUnixSeconds, expires: expiresAtUnixSeconds)) else {
            throw EnrollmentError.invalidIdentity
        }
    }

    static func decode(_ data: Data) throws -> Self {
        _ = try EnrollmentWire.object(data, required: ["version", "relayOrigin", "invitationId", "controllerDeviceId",
            "peerDeviceId", "claimHash", "confirmedAtUnixSeconds", "expiresAtUnixSeconds", "signatureBase64"])
        return try JSONDecoder().decode(Self.self, from: data)
    }

    static func transcript(origin: String, invitation: String, controller: String, peer: String, claim: String,
                           confirmed: Int64, expires: Int64) -> Data {
        Data(["JTS-PAIR-CONFIRM-2", origin, invitation, controller, peer, claim,
              String(confirmed), String(expires)].joined(separator: "\n").utf8)
    }
}
