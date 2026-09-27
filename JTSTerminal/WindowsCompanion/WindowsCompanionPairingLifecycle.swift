#if ENABLE_RDP_2
import Foundation

nonisolated struct WindowsCompanionUnpairAction: Sendable {
    private let operation: @MainActor @Sendable () async throws -> Void

    init(operation: @escaping @MainActor @Sendable () async throws -> Void) {
        self.operation = operation
    }

    @MainActor
    func callAsFunction() async throws {
        try await operation()
    }
}

/// Fail-closed policy shared by the runtime and pairing UI. Windows Companion
/// persists one approved Mac client identity, while JTS Terminal intentionally
/// gives each saved RDP profile its own Mac identity. Only the profile that is
/// currently authenticated may revoke that Windows-side grant.
nonisolated enum WindowsCompanionPairingLifecycle {
    static func requireAuthorizedPeer(
        availability: WindowsCompanionAvailability,
        peerIdentity: WindowsCompanionPeerIdentity?
    ) throws -> WindowsCompanionPeerIdentity {
        guard availability == .ready, let peerIdentity else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_REQUIRED",
                message: "Only the currently authorized Companion peer can unpair this Windows device.",
                retryable: false
            )
        }
        return peerIdentity
    }

    static func validateUnpairResponse(_ result: [String: Any]) throws -> UInt64 {
        guard result["revoked"] as? Bool == true,
              let stateRevision = unsignedInteger(result["stateRevision"]),
              stateRevision > 0 else {
            throw WindowsCompanionRequestFailure(
                code: "COMPANION_UNPAIR_RESPONSE_INVALID",
                message: "The Windows Companion returned an invalid unpair result.",
                retryable: false
            )
        }
        return stateRevision
    }

    static func blockedPairingState(
        companionVersion: String?,
        reason: String = "The previous Mac client grant was revoked. Confirm fingerprints before pairing this RDP profile again."
    ) -> WindowsCompanionState {
        WindowsCompanionState(
            availability: .pairingRequired,
            protocolVersion: WindowsCompanionDVC.protocolVersion,
            companionVersion: companionVersion,
            reason: reason
        )
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int64, value >= 0 { return UInt64(value) }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.int64Value >= 0 else {
                return nil
            }
            return value.uint64Value
        }
        return nil
    }
}

#endif
