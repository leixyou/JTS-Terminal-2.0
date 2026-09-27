#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices
import JTSRelayEnrollment

nonisolated enum CompanionRevocationEpoch {
    struct Selection {
        let bundle: EnrollmentBundle
        let record: CompanionEnrollmentRecord?
    }
    /// The active route selects the epoch, not the newest invitation. A newer
    /// bound receipt may exist while its control probe is still incomplete.
    static func resolve(device: CompanionSavedDevice, route: CompanionTargetRouteBinding?,
                        records: [CompanionEnrollmentRecord]) throws -> Selection {
        guard route == nil || route?.deviceID == device.id else { throw EnrollmentError.changed }
        for record in records.reversed() {
            guard let claim = record.attempt.verifiedClaim,
                  let bundle = try? record.attempt.bundle(for: claim),
                  bundle.peerDeviceID == device.peerDeviceID, bundle.relayURL == device.relayURL else { continue }
            if let route, !matches(bundle: bundle, route: route) { continue }
            return Selection(bundle: bundle, record: record)
        }
        guard let route, let pairing = route.pairingID, let file = route.fileGrantID, let rdp = route.rdpGrantID else {
            throw EnrollmentError.remote("VERIFIED_PAIRING_EPOCH_REQUIRED")
        }
        // Manual public imports retain their epoch only after pinned control
        // verification. Windows still verifies every identifier before revoking.
        let value: [String: Any] = ["version": 1, "name": device.name, "relayURL": device.relayURL,
            "peerSPKIBase64": device.peerSPKI.base64EncodedString(), "peerDeviceID": device.peerDeviceID,
            "pairingID": pairing.uuidString.lowercased(), "grantID": route.grantID.uuidString.lowercased(),
            "fileGrantID": file.uuidString.lowercased(), "rdpGrantID": rdp.uuidString.lowercased(),
            "allowWindows10TLS12": device.allowWindows10TLS12]
        return Selection(bundle: try JSONDecoder().decode(EnrollmentBundle.self,
            from: JSONSerialization.data(withJSONObject: value)), record: nil)
    }
    static func matches(bundle: EnrollmentBundle, route: CompanionTargetRouteBinding) -> Bool {
        bundle.grantID == route.grantID.uuidString.lowercased() &&
        bundle.fileGrantID == route.fileGrantID?.uuidString.lowercased() &&
        bundle.rdpGrantID == route.rdpGrantID?.uuidString.lowercased() &&
        (route.pairingID == nil || bundle.pairingID == route.pairingID?.uuidString.lowercased())
    }
}
#endif
