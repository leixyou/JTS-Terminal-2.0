import Foundation
import JTSCompanionTransport
import JTSRelayEnrollment

/// Keep the signed request and old pin after deleting active trust. The exact
/// signed receipt survives a lost relay acknowledgement and process restart.
struct NativeRelayHostRevocation: Codable, Equatable {
    let authorization: EnrollmentHostAuthorization
    let request: EnrollmentRevocation
    var receipt: EnrollmentRevocationReceipt?
    var completed = false

    func validate(host: RelayIdentity) throws {
        try authorization.validate()
        try request.verify(controllerSPKI: authorization.controllerSPKI)
        guard request.peerDeviceId == host.deviceID,
              request.controllerDeviceId == authorization.controllerDeviceID,
              request.relayOrigin == authorization.relayOrigin,
              request.pairingId == authorization.pairingID.uuidString.lowercased(),
              request.grantId == authorization.controlGrantID.uuidString.lowercased(),
              request.fileGrantId == authorization.fileGrantID.uuidString.lowercased(),
              request.rdpGrantId == authorization.rdpGrantID.uuidString.lowercased(),
              !completed || receipt != nil else { throw CompanionStoreError.invalidIdentity }
        try receipt?.verify(revocation: request, peerSPKI: host.publicKeySPKI)
    }
}

extension NativeRelayHostConfiguration {
    var hasPendingRevocations: Bool { revocations.contains { !$0.completed } }

    /// The caller durably saves this whole value before closing bridges and
    /// creating any signed receipt. A revoked epoch can never remain enabled.
    mutating func deny(_ request: EnrollmentRevocation, authorization: EnrollmentHostAuthorization) throws {
        let record = NativeRelayHostRevocation(authorization: authorization, request: request)
        try record.validate(host: identity)
        guard trust?.authorization == authorization else { throw CompanionStoreError.invalidIdentity }
        if !revocations.contains(where: { $0.request == request }) {
            if revocations.count == 64 {
                // Only completed acknowledgements may retire; pending receipts
                // and their old pins must survive every restart/retry.
                guard let completed = revocations.firstIndex(where: \.completed) else { throw CompanionStoreError.invalidIdentity }
                revocations.remove(at: completed)
            }
            revocations.append(record)
        }
        trust = nil
        enabled = false
    }
}
