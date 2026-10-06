import CryptoKit
import Foundation

/// The controller identity and grants covered by its signed confirmation.
/// A value obtained from an attempt is a preview; only a bound receipt authorizes persistence.
public struct EnrollmentHostAuthorization: Codable, Equatable, Sendable {
    public let relayOrigin: String
    public let controllerSPKI: Data
    public let controllerDeviceID: String
    public let pairingID, controlGrantID, fileGrantID, rdpGrantID: UUID
    public let allowWindows10TLS12: Bool

    public func validate() throws {
        let key = try P256.Signing.PublicKey(derRepresentation: controllerSPKI)
        let ids = [pairingID, controlGrantID, fileGrantID, rdpGrantID].map { $0.uuidString.lowercased() }
        guard try EnrollmentWire.origin(relayOrigin) == relayOrigin, key.derRepresentation == controllerSPKI,
              EnrollmentWire.hash(controllerSPKI) == controllerDeviceID, ids.allSatisfy(EnrollmentWire.validID),
              Set(ids).count == 4 else { throw EnrollmentError.invalidMessage }
    }
}

/// Contains the invitation secret and the exact encrypted claim. Persist in the encrypted
/// vault before calling claim so a lost response never creates a different claim on retry.
public struct EnrollmentHostAttempt: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let enrollment: EnrollmentAttempt
    public var description: String { "EnrollmentHostAttempt (credentials omitted)" }
    public var debugDescription: String { description }

    public func validate() throws {
        let request = try EnrollmentRequest.decode(enrollment.request)
        guard enrollment.verifiedClaim != nil else { throw EnrollmentError.invalidMessage }
        try enrollment.validate(controllerDeviceId: request.controllerDeviceID)
    }

    /// Review metadata only. Calling this method does not authorize the controller.
    public func authorization() throws -> EnrollmentHostAuthorization {
        try validate()
        let request = try EnrollmentRequest.decode(enrollment.request)
        return EnrollmentHostAuthorization(relayOrigin: try EnrollmentCode(enrollment.code).relayOrigin,
            controllerSPKI: try EnrollmentWire.base64(request.controllerSPKIBase64, maximum: 512),
            controllerDeviceID: request.controllerDeviceID, pairingID: UUID(uuidString: request.pairingID)!,
            controlGrantID: UUID(uuidString: request.grantID)!, fileGrantID: UUID(uuidString: request.fileGrantID)!,
            rdpGrantID: UUID(uuidString: request.rdpGrantID)!, allowWindows10TLS12: request.allowWindows10TLS12 ?? false)
    }
}

public struct EnrollmentHostReceipt: Sendable {
    public let state: EnrollmentReceipt.State
    /// Non-nil only after verifying the controller's signature for this exact host claim.
    public let authorization: EnrollmentHostAuthorization?
}

/// Companion-side anonymous enrollment. The bearer invitation authenticates encrypted offers;
/// the durable controller signature, rather than relay state, authorizes the new peer.
public actor EnrollmentHostClient {
    public let deviceID: String
    public let publicKeySPKI: Data
    private let key: P256.Signing.PrivateKey
    private let transport: any EnrollmentHTTPTransport

    public init(privateKey: Data, transport: any EnrollmentHTTPTransport = EnrollmentURLTransport()) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
        publicKeySPKI = key.publicKey.derRepresentation
        deviceID = EnrollmentWire.hash(publicKeySPKI)
        self.transport = transport
    }

    public func prepare(code text: String, name: String, now: Date = Date()) async throws -> EnrollmentHostAttempt {
        guard (1...128).contains(name.utf8.count),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw EnrollmentError.invalidMessage }
        let code = try EnrollmentCode(text)
        let receipt = try EnrollmentReceipt.decode(await post("offer", code: code))
        guard receipt.invitationId == code.invitationId, receipt.state == .pending,
              receipt.claim == nil, receipt.confirmation == nil else { throw EnrollmentError.changed }
        guard Double(receipt.expiresAtUnixSeconds) > now.timeIntervalSince1970 else { throw EnrollmentError.expired }
        let offer = try EnrollmentWire.base64(receipt.offerBase64)
        let plain = try code.openOffer(offer)
        _ = try EnrollmentWire.object(plain, required: ["version", "relayOrigin", "requestBase64", "requestSha256"])
        let wrapper = try JSONDecoder().decode(EnrollmentOffer.self, from: plain)
        let requestBytes = try EnrollmentWire.base64(wrapper.requestBase64)
        let request = try EnrollmentRequest.decode(requestBytes)
        let dates = ISO8601DateFormatter()
        guard wrapper.version == 1, wrapper.relayOrigin == code.relayOrigin,
              wrapper.requestSha256 == EnrollmentWire.hash(requestBytes),
              request.controllerDeviceID == receipt.controllerDeviceId, request.controllerDeviceID != deviceID,
              Int64(dates.date(from: request.expiresAtUtc)!.timeIntervalSince1970) == receipt.expiresAtUnixSeconds,
              dates.date(from: request.issuedAtUtc)! <= now.addingTimeInterval(120) else { throw EnrollmentError.changed }
        let bundle = EnrollmentBundle(version: 1, name: name, relayURL: code.relayOrigin,
            peerSPKIBase64: publicKeySPKI.base64EncodedString(), peerDeviceID: deviceID,
            pairingID: request.pairingID, grantID: request.grantID, fileGrantID: request.fileGrantID,
            rdpGrantID: request.rdpGrantID, allowWindows10TLS12: request.allowWindows10TLS12,
            installationState: nil)
        let response = try code.sealResponse(EnrollmentWire.encode(EnrollmentResponse(version: 1,
            invitationId: code.invitationId, relayOrigin: code.relayOrigin,
            requestSha256: EnrollmentWire.hash(requestBytes), enrollmentBase64: try EnrollmentWire.encode(bundle).base64EncodedString())), offer: offer)
        let transcript = EnrollmentClaim.transcript(invitationId: code.invitationId,
            controllerDeviceId: request.controllerDeviceID, offer: offer, response: response, spki: publicKeySPKI)
        let claim = EnrollmentClaim(peerSPKIBase64: publicKeySPKI.base64EncodedString(), responseBase64: response.base64EncodedString(),
            signatureBase64: try key.signature(for: transcript).rawRepresentation.base64EncodedString(), claimHash: EnrollmentWire.hash(transcript))
        let attempt = EnrollmentHostAttempt(enrollment: EnrollmentAttempt(hostCode: code, request: requestBytes,
            offer: offer, expiresAtUnixSeconds: receipt.expiresAtUnixSeconds, claim: claim))
        try attempt.validate()
        return attempt
    }

    public func claim(_ attempt: EnrollmentHostAttempt) async throws -> EnrollmentHostReceipt {
        try validateIdentity(attempt)
        let claim = attempt.enrollment.verifiedClaim!
        return try checkedReceipt(await post("claim", code: EnrollmentCode(attempt.enrollment.code),
            fields: ["peerSPKIBase64": claim.peerSPKIBase64, "responseBase64": claim.responseBase64,
                     "signatureBase64": claim.signatureBase64]), attempt: attempt)
    }

    /// May recover a signed bound receipt after the invitation expiry without a new signature.
    public func receipt(_ attempt: EnrollmentHostAttempt) async throws -> EnrollmentHostReceipt {
        try validateIdentity(attempt)
        return try checkedReceipt(await post("receipt", code: EnrollmentCode(attempt.enrollment.code)), attempt: attempt)
    }

    private func validateIdentity(_ attempt: EnrollmentHostAttempt) throws {
        try attempt.validate()
        guard attempt.enrollment.verifiedClaim?.peerSPKIBase64 == publicKeySPKI.base64EncodedString() else {
            throw EnrollmentError.invalidIdentity
        }
    }

    private func checkedReceipt(_ bytes: Data, attempt: EnrollmentHostAttempt) throws -> EnrollmentHostReceipt {
        let receipt = try EnrollmentReceipt.decode(bytes)
        var expected = attempt.enrollment
        // A receipt read before the first successful claim legitimately has no remote claim.
        // It may report pending, but can never authorize trust or replace the stored claim.
        if receipt.state == .pending, receipt.claim == nil, expected.confirmation == nil {
            expected.verifiedClaim = nil
        }
        try expected.check(receipt)
        return EnrollmentHostReceipt(state: receipt.state,
            authorization: receipt.state == .bound ? try attempt.authorization() : nil)
    }

    private func post(_ operation: String, code: EnrollmentCode, fields: [String: String] = [:]) async throws -> Data {
        var payload = fields
        payload["invitationId"] = code.invitationId; payload["claimTokenBase64"] = code.claimToken.base64EncodedString()
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        guard body.count <= 16384 else { throw EnrollmentError.invalidMessage }
        let (status, response) = try await transport.post(URL(string: code.relayOrigin + "/v1/enrollment/" + operation)!, body: body)
        guard response.count <= 32768 else { throw EnrollmentError.invalidResponse }
        guard status == 200 else {
            let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
            let value = object?["code"] as? String ?? "request_failed"
            let safe = (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }
            throw EnrollmentError.remote(safe ? value : "request_failed")
        }
        return response
    }
}

extension EnrollmentAttempt {
    init(hostCode: EnrollmentCode, request: Data, offer: Data, expiresAtUnixSeconds: Int64, claim: EnrollmentClaim) {
        id = hostCode.invitationId; code = hostCode.presentation; self.request = request; self.offer = offer
        self.expiresAtUnixSeconds = expiresAtUnixSeconds; verifiedClaim = claim; confirmation = nil
    }
}
