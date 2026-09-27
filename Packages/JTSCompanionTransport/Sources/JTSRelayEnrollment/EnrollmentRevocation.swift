import CryptoKit
import Foundation

/// Persist before submission. Its exact epoch/grants remain revocable while Windows is offline.
public struct EnrollmentRevocation: Codable, Equatable, Sendable {
    public let version: Int
    public let revocationId, relayOrigin, controllerDeviceId, peerDeviceId: String
    public let pairingId, grantId, fileGrantId, rdpGrantId: String
    public let requestedAtUnixSeconds: Int64
    public let signatureBase64: String

    init(bundle: EnrollmentBundle, origin: String, key: P256.Signing.PrivateKey, now: Date) throws {
        let instant = now.timeIntervalSince1970
        guard instant.isFinite, instant >= 1, instant < Double(Int64.max),
              try EnrollmentWire.origin(bundle.relayURL) == origin else { throw EnrollmentError.invalidMessage }
        version = 2; revocationId = UUID().uuidString.lowercased(); relayOrigin = origin
        controllerDeviceId = EnrollmentWire.hash(key.publicKey.derRepresentation); peerDeviceId = bundle.peerDeviceID
        pairingId = bundle.pairingID; grantId = bundle.grantID; fileGrantId = bundle.fileGrantID; rdpGrantId = bundle.rdpGrantID
        requestedAtUnixSeconds = Int64(instant)
        signatureBase64 = try key.signature(for: Self.transcript(id: revocationId, origin: origin,
            controller: controllerDeviceId, peer: peerDeviceId, pairing: pairingId, grant: grantId,
            file: fileGrantId, rdp: rdpGrantId, requested: requestedAtUnixSeconds)).rawRepresentation.base64EncodedString()
        try verify(controllerSPKI: key.publicKey.derRepresentation)
        try verifyPeer(EnrollmentWire.base64(bundle.peerSPKIBase64, maximum: 512))
    }

    public var requestHash: String {
        get throws { EnrollmentWire.hash(try transcript() + EnrollmentWire.base64(signatureBase64, maximum: 64)) }
    }

    public func verify(controllerSPKI: Data) throws {
        let grants = [pairingId, grantId, fileGrantId, rdpGrantId]
        guard version == 2, EnrollmentWire.validID(revocationId), grants.allSatisfy(EnrollmentWire.validID), Set(grants).count == 4,
              try EnrollmentWire.origin(relayOrigin) == relayOrigin, requestedAtUnixSeconds > 0,
              controllerDeviceId == EnrollmentWire.hash(controllerSPKI), controllerDeviceId != peerDeviceId,
              peerDeviceId.utf8.count == 64, peerDeviceId.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EnrollmentError.invalidMessage
        }
        let key = try P256.Signing.PublicKey(derRepresentation: controllerSPKI)
        let signature = try EnrollmentWire.base64(signatureBase64, maximum: 64)
        guard key.derRepresentation == controllerSPKI, signature.count == 64,
              key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: transcript()) else {
            throw EnrollmentError.invalidIdentity
        }
    }

    func verifyPeer(_ spki: Data) throws {
        let key = try P256.Signing.PublicKey(derRepresentation: spki)
        guard key.derRepresentation == spki, EnrollmentWire.hash(spki) == peerDeviceId else { throw EnrollmentError.invalidIdentity }
    }
    func transcript() -> Data {
        Self.transcript(id: revocationId, origin: relayOrigin, controller: controllerDeviceId, peer: peerDeviceId,
            pairing: pairingId, grant: grantId, file: fileGrantId, rdp: rdpGrantId, requested: requestedAtUnixSeconds)
    }
    static func decode(_ data: Data) throws -> Self {
        _ = try EnrollmentWire.object(data, required: ["version", "revocationId", "relayOrigin", "controllerDeviceId", "peerDeviceId",
            "pairingId", "grantId", "fileGrantId", "rdpGrantId", "requestedAtUnixSeconds", "signatureBase64"])
        return try JSONDecoder().decode(Self.self, from: data)
    }
    private static func transcript(id: String, origin: String, controller: String, peer: String, pairing: String,
                                   grant: String, file: String, rdp: String, requested: Int64) -> Data {
        Data(["JTS-PAIR-REVOKE-2", id, origin, controller, peer, pairing, grant, file, rdp,
              String(requested)].joined(separator: "\n").utf8)
    }
}

public struct EnrollmentRevocationReceipt: Codable, Equatable, Sendable {
    public let version: Int
    public let revocationId, requestHash, controllerDeviceId, peerDeviceId: String
    public let revokedAtUnixSeconds: Int64
    public let signatureBase64: String

    public func verify(revocation: EnrollmentRevocation, peerSPKI: Data) throws {
        try revocation.verifyPeer(peerSPKI)
        guard version == 2, revocationId == revocation.revocationId, requestHash == (try revocation.requestHash),
              controllerDeviceId == revocation.controllerDeviceId, peerDeviceId == revocation.peerDeviceId,
              revokedAtUnixSeconds > 0 else { throw EnrollmentError.changed }
        let signature = try EnrollmentWire.base64(signatureBase64, maximum: 64)
        let key = try P256.Signing.PublicKey(derRepresentation: peerSPKI)
        let transcript = Data(["JTS-PAIR-REVOKED-2", revocationId, requestHash, controllerDeviceId,
            peerDeviceId, String(revokedAtUnixSeconds)].joined(separator: "\n").utf8)
        guard signature.count == 64,
              key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: transcript) else {
            throw EnrollmentError.invalidIdentity
        }
    }
    static func decode(_ data: Data) throws -> Self {
        _ = try EnrollmentWire.object(data, required: ["version", "revocationId", "requestHash", "controllerDeviceId",
            "peerDeviceId", "revokedAtUnixSeconds", "signatureBase64"])
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct EnrollmentRevocationStatus: Sendable {
    public enum State: String, Decodable, Sendable { case pending, complete }
    public let state: State
    public let receipt: EnrollmentRevocationReceipt?

    static func decode(_ data: Data, expected: EnrollmentRevocation, controllerSPKI: Data, peerSPKI: Data) throws -> Self {
        let object = try EnrollmentWire.object(data, required: ["revocationId", "requestHash", "state", "revocation", "controllerSPKIBase64"],
            optional: ["receipt"])
        let actual = try EnrollmentRevocation.decode(JSONSerialization.data(withJSONObject: object["revocation"]!))
        guard actual == expected, object["revocationId"] as? String == expected.revocationId,
              object["requestHash"] as? String == (try expected.requestHash),
              object["controllerSPKIBase64"] as? String == controllerSPKI.base64EncodedString(),
              let rawState = object["state"] as? String, let state = State(rawValue: rawState) else { throw EnrollmentError.changed }
        try actual.verify(controllerSPKI: controllerSPKI)
        try actual.verifyPeer(peerSPKI)
        var receipt: EnrollmentRevocationReceipt?
        if let raw = object["receipt"] {
            receipt = try EnrollmentRevocationReceipt.decode(JSONSerialization.data(withJSONObject: raw))
            try receipt!.verify(revocation: expected, peerSPKI: peerSPKI)
        }
        guard (state == .complete) == (receipt != nil) else { throw EnrollmentError.invalidResponse }
        return Self(state: state, receipt: receipt)
    }
}
