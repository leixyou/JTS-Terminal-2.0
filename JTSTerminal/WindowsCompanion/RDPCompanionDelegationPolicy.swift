#if ENABLE_RDP_2
import CryptoKit
import Foundation

/// The saved device AI-control permission includes pairing delegation. No
/// second permission switch or consent dialog is introduced by this feature.
@MainActor
enum RDPCompanionDelegationPolicy {
    static func isEnabled(for target: RemoteSession) -> Bool {
        target.mcpEnabled && target.mcpPermissionPolicy.maximumCapabilities.contains(.desktopControl)
    }

    static func prepare(
        target: RemoteSession,
        peer: WindowsCompanionPeerIdentity,
        store: CompanionPairingDelegationStore? = nil,
        allowReplacingRevokedGrant: Bool = false
    ) async throws -> CompanionPairingDelegationExport {
        guard isEnabled(for: target) else {
            throw WindowsMCPToolError(code: .permissionDenied,
                message: "Enable AI desktop control for this device before using delegated pairing.")
        }
        let binding = target.mcpGrantTargetBinding
        let exported = try await (store ?? .shared).createExport(
            targetID: target.targetID, targetBinding: binding, peer: peer,
            allowReplacingRevokedGrant: allowReplacingRevokedGrant
        )
        guard isEnabled(for: target), binding == target.mcpGrantTargetBinding else {
            throw WindowsMCPToolError(code: .permissionDenied,
                message: "The device AI-control permission changed during pairing preparation.")
        }
        return exported
    }

    static func enrollmentMetadata(_ exported: CompanionPairingDelegationExport) -> [String: Any] {
        ["enrollmentRequestBase64": exported.requestBase64,
         "enrollmentRequestSHA256": SHA256.hash(data: exported.requestJSON)
            .map { String(format: "%02x", $0) }.joined()]
    }

    static func audit(target: RemoteSession, action: String, result: RemoteCapabilityAuditResult) {
        RemoteCapabilityAuditStore.shared.record(
            clientID: "device-ai-control", clientDisplayIdentity: "Device AI control policy",
            targetID: target.targetID, targetAlias: target.name,
            actionType: action, capabilities: [.desktopControl], result: result,
            resultCode: "OK", controlLeaseExpiresAt: nil, startedAt: Date()
        )
    }
}
#endif
