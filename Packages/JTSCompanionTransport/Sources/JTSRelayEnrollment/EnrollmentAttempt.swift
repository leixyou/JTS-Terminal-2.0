import Foundation

/// Retry state is a credential. The caller must persist it before the first network request.
public struct EnrollmentAttempt: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    public let code: String
    public let request: Data
    public let offer: Data
    public let expiresAtUnixSeconds: Int64
    public var verifiedClaim: EnrollmentClaim?
    public var confirmation: EnrollmentConfirmation?
    public var description: String { "EnrollmentAttempt (credentials omitted)" }
    public var debugDescription: String { description }

    public init(relayOrigin: String, request: EnrollmentRequest) throws {
        let code = try EnrollmentCode(relayOrigin: relayOrigin)
        self.code = code.presentation; id = code.invitationId
        self.request = try EnrollmentWire.encode(request)
        expiresAtUnixSeconds = Int64(ISO8601DateFormatter().date(from: request.expiresAtUtc)!.timeIntervalSince1970)
        offer = try code.sealOffer(EnrollmentWire.encode(EnrollmentOffer(version: 1, relayOrigin: code.relayOrigin,
            requestBase64: self.request.base64EncodedString(), requestSha256: EnrollmentWire.hash(self.request))))
    }

    public func validate(controllerDeviceId: String) throws {
        let key = try EnrollmentCode(code)
        let requestValue = try EnrollmentRequest.decode(request)
        let plain = try key.openOffer(offer)
        _ = try EnrollmentWire.object(plain, required: ["version", "relayOrigin", "requestBase64", "requestSha256"])
        let wrapped = try JSONDecoder().decode(EnrollmentOffer.self, from: plain)
        guard key.invitationId == id, wrapped.version == 1, wrapped.relayOrigin == key.relayOrigin,
              wrapped.requestBase64 == request.base64EncodedString(), wrapped.requestSha256 == EnrollmentWire.hash(request),
              requestValue.controllerDeviceID == controllerDeviceId,
              Int64(ISO8601DateFormatter().date(from: requestValue.expiresAtUtc)!.timeIntervalSince1970) == expiresAtUnixSeconds else {
            throw EnrollmentError.changed
        }
        if let verifiedClaim { _ = try bundle(for: verifiedClaim) }
        if let confirmation { try confirmation.verify(attempt: self) }
    }

    public func check(_ receipt: EnrollmentReceipt) throws {
        let requestValue = try EnrollmentRequest.decode(request)
        guard receipt.invitationId == id, receipt.controllerDeviceId == requestValue.controllerDeviceID,
              receipt.offerBase64 == offer.base64EncodedString(), receipt.expiresAtUnixSeconds == expiresAtUnixSeconds,
              verifiedClaim == nil || receipt.claim == verifiedClaim else { throw EnrollmentError.changed }
        if receipt.state == .bound && receipt.confirmation == nil { throw EnrollmentError.invalidResponse }
        if let confirmation = receipt.confirmation {
            var observed = self
            observed.verifiedClaim = receipt.claim
            try confirmation.verify(attempt: observed)
            guard self.confirmation == nil || self.confirmation == confirmation else { throw EnrollmentError.changed }
        }
    }

    /// Only a definitive node rejection can terminate an expired, uncommitted retry.
    public func recoveryState(after error: Error, localState: String, now: Date = Date()) -> String? {
        guard ["creating", "pending", "claimed"].contains(localState),
              expiresAtUnixSeconds <= Int64(now.timeIntervalSince1970),
              let failure = error as? EnrollmentError, case .remote(let code) = failure,
              ["invalid_invitation_expiry", "invitation_not_found"].contains(code) else { return nil }
        return "expired"
    }

    public func bundle(for claim: EnrollmentClaim) throws -> EnrollmentBundle {
        let key = try EnrollmentCode(code)
        let requestValue = try EnrollmentRequest.decode(request)
        let (spki, response) = try claim.verify(invitationId: id, controllerDeviceId: requestValue.controllerDeviceID, offer: offer)
        let plain = try key.openResponse(response, offer: offer)
        _ = try EnrollmentWire.object(plain, required: ["version", "invitationId", "relayOrigin", "requestSha256", "enrollmentBase64"])
        let wrapped = try JSONDecoder().decode(EnrollmentResponse.self, from: plain)
        guard wrapped.version == 1, wrapped.invitationId == id, wrapped.relayOrigin == key.relayOrigin,
              wrapped.requestSha256 == EnrollmentWire.hash(request) else { throw EnrollmentError.changed }
        return try EnrollmentBundle.decode(EnrollmentWire.base64(wrapped.enrollmentBase64), request: requestValue,
                                            origin: key.relayOrigin, peerSPKI: spki)
    }
}
