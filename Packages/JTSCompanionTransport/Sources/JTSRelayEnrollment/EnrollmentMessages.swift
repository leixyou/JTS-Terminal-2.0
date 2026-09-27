import CryptoKit
import CoreFoundation
import Foundation

public struct EnrollmentRequest: Codable, Sendable {
    public let version: Int
    public let authorizationSource, authorizationReference, controllerDeviceID, controllerSPKIBase64: String
    public let pairingID, grantID, fileGrantID, rdpGrantID, issuedAtUtc, expiresAtUtc: String
    public let allowWindows10TLS12: Bool?

    public init(controllerSPKI: Data, allowWindows10TLS12: Bool, now: Date = Date()) throws {
        let key = try P256.Signing.PublicKey(derRepresentation: controllerSPKI)
        guard key.derRepresentation == controllerSPKI else { throw EnrollmentError.invalidIdentity }
        version = 1; authorizationSource = "ownerDelegated"; authorizationReference = "device-ai-control-enabled"
        controllerDeviceID = EnrollmentWire.hash(controllerSPKI); controllerSPKIBase64 = controllerSPKI.base64EncodedString()
        pairingID = UUID().uuidString.lowercased(); grantID = UUID().uuidString.lowercased()
        fileGrantID = UUID().uuidString.lowercased(); rdpGrantID = UUID().uuidString.lowercased()
        let formatter = ISO8601DateFormatter()
        issuedAtUtc = formatter.string(from: now); expiresAtUtc = formatter.string(from: now.addingTimeInterval(1800))
        self.allowWindows10TLS12 = allowWindows10TLS12 ? true : nil
    }

    public static func decode(_ data: Data) throws -> Self {
        let object = try EnrollmentWire.object(data, required: ["version", "authorizationSource", "authorizationReference",
            "controllerDeviceID", "controllerSPKIBase64", "pairingID", "grantID", "fileGrantID", "rdpGrantID",
            "issuedAtUtc", "expiresAtUtc"], optional: ["allowWindows10TLS12"])
        try validateCompatibility(object)
        let value = try JSONDecoder().decode(Self.self, from: data)
        let spki = try EnrollmentWire.base64(value.controllerSPKIBase64, maximum: 512)
        let key = try P256.Signing.PublicKey(derRepresentation: spki)
        let ids = [value.pairingID, value.grantID, value.fileGrantID, value.rdpGrantID]
        let formatter = ISO8601DateFormatter()
        guard value.version == 1, value.authorizationSource == "ownerDelegated",
              value.authorizationReference == "device-ai-control-enabled", key.derRepresentation == spki,
              EnrollmentWire.hash(spki) == value.controllerDeviceID, ids.allSatisfy(EnrollmentWire.validID),
              Set(ids).count == 4, let issued = formatter.date(from: value.issuedAtUtc),
              let expires = formatter.date(from: value.expiresAtUtc), expires > issued,
              expires.timeIntervalSince(issued) <= 1800 else { throw EnrollmentError.invalidMessage }
        return value
    }
}

public struct EnrollmentBundle: Codable, Sendable {
    public let version: Int
    public let name, relayURL, peerSPKIBase64, peerDeviceID, pairingID, grantID, fileGrantID, rdpGrantID: String
    public let allowWindows10TLS12: Bool?
    public let installationState: String?
    public var peerSPKI: Data { Data(base64Encoded: peerSPKIBase64)! }

    static func decode(_ data: Data, request: EnrollmentRequest, origin: String, peerSPKI: Data) throws -> Self {
        let object = try EnrollmentWire.object(data, required: ["version", "name", "relayURL", "peerSPKIBase64", "peerDeviceID",
            "pairingID", "grantID", "fileGrantID", "rdpGrantID"], optional: ["allowWindows10TLS12", "installationState"])
        try validateCompatibility(object)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, (1...128).contains(value.name.utf8.count),
              !value.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              try EnrollmentWire.origin(value.relayURL) == origin,
              try EnrollmentWire.base64(value.peerSPKIBase64, maximum: 512) == peerSPKI,
              value.peerDeviceID == EnrollmentWire.hash(peerSPKI), value.peerDeviceID != request.controllerDeviceID,
              value.pairingID == request.pairingID, value.grantID == request.grantID,
              value.fileGrantID == request.fileGrantID, value.rdpGrantID == request.rdpGrantID,
              (value.allowWindows10TLS12 ?? false) == (request.allowWindows10TLS12 ?? false),
              value.installationState == nil || value.installationState == "installedAwaitingRelayAdmission" else {
            throw EnrollmentError.invalidMessage
        }
        return value
    }
}

public struct EnrollmentClaim: Codable, Equatable, Sendable {
    public let peerSPKIBase64, responseBase64, signatureBase64, claimHash: String
    public func verify(invitationId: String, controllerDeviceId: String, offer: Data) throws -> (Data, Data) {
        let spki = try EnrollmentWire.base64(peerSPKIBase64, maximum: 512)
        let key = try P256.Signing.PublicKey(derRepresentation: spki)
        let response = try EnrollmentWire.base64(responseBase64)
        let signature = try EnrollmentWire.base64(signatureBase64, maximum: 64)
        let transcript = Self.transcript(invitationId: invitationId, controllerDeviceId: controllerDeviceId,
                                         offer: offer, response: response, spki: spki)
        guard key.derRepresentation == spki, EnrollmentWire.hash(transcript) == claimHash, signature.count == 64,
              key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: transcript) else {
            throw EnrollmentError.invalidIdentity
        }
        return (spki, response)
    }
    public static func transcript(invitationId: String, controllerDeviceId: String, offer: Data, response: Data, spki: Data) -> Data {
        Data(["JTS-PAIR-1", invitationId, controllerDeviceId, EnrollmentWire.hash(offer),
              EnrollmentWire.hash(response), EnrollmentWire.hash(spki)].joined(separator: "\n").utf8)
    }
}

public struct EnrollmentReceipt: Codable, Sendable {
    public enum State: String, Codable, Sendable { case pending, claimed, bound, cancelled, expired }
    public let invitationId, controllerDeviceId: String
    public let state: State
    public let expiresAtUnixSeconds: Int64
    public let offerBase64: String
    public let claim: EnrollmentClaim?

    static func decode(_ data: Data) throws -> Self {
        let object = try EnrollmentWire.object(data, required: ["invitationId", "controllerDeviceId", "state",
            "expiresAtUnixSeconds", "offerBase64"], optional: ["claim"])
        if let claim = object["claim"] {
            _ = try EnrollmentWire.object(JSONSerialization.data(withJSONObject: claim),
                required: ["peerSPKIBase64", "responseBase64", "signatureBase64", "claimHash"])
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard EnrollmentWire.validID(value.invitationId),
              value.controllerDeviceId.count == 64, value.expiresAtUnixSeconds > 0,
              ![State.claimed, .bound].contains(value.state) || value.claim != nil else { throw EnrollmentError.invalidResponse }
        return value
    }
}

struct EnrollmentOffer: Codable { let version: Int; let relayOrigin, requestBase64, requestSha256: String }
struct EnrollmentResponse: Codable { let version: Int; let invitationId, relayOrigin, requestSha256, enrollmentBase64: String }

private func validateCompatibility(_ object: [String: Any]) throws {
    if let raw = object["allowWindows10TLS12"] {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw EnrollmentError.invalidMessage }
    }
}
