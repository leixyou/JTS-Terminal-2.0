#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices
import JTSRelayEnrollment

extension CompanionDeviceMCPHandler {
    func enrollmentStatus(_ request: CompanionDeviceMCPRequest, targetBinding: String,
                          authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> [String: Any] {
        let model = CompanionEnrollmentModel.shared
        try authorize()
        if request.action == "revokeRelay" {
            let revocations = CompanionRevocationModel.shared
            try await revocations.refresh()
            let currentBinding = try await bindings.binding(targetID: request.targetID, targetBinding: targetBinding)
            if let prior = revocations.records.last(where: {
                $0.targetID == request.targetID && $0.targetBinding == targetBinding
            }), prior.receipt == nil || currentBinding == nil {
                revocations.start(); await revocations.retryPending(); try authorize()
                let state = revocations.records.first(where: { $0.request.revocationId == prior.request.revocationId })?.state ?? "revocationPending"
                return envelope(request, extra: ["state": state, "ready": false, "windowsRevocationConfirmed": state == "revoked"])
            }
            guard let binding = try await bindings.binding(targetID: request.targetID, targetBinding: targetBinding),
                  let snapshot = try await devices.mcpSnapshot(),
                  let device = snapshot.devices.first(where: { $0.id == binding.deviceID }) else { throw EnrollmentError.changed }
            let state = try await model.revoke(device: device, targetID: request.targetID, currentBinding: binding, authorize: authorize)
            return envelope(request, extra: ["state": state, "ready": false, "windowsRevocationConfirmed": state == "revoked"])
        }
        let record: CompanionEnrollmentRecord
        if request.action == "createCode" {
            record = try await model.create(relayURL: request.arguments["relayURL"] as? String ?? "",
                compatibility: CompanionDeviceMCPRequest.boolean("allowWindows10TLS12", request.arguments),
                targetID: request.targetID, targetBinding: targetBinding, authorize: authorize)
        } else {
            let id = try CompanionDeviceMCPRequest.identifier("invitationId", request.arguments).uuidString.lowercased()
            if request.action == "cancelCode" {
                record = try await model.cancel(id: id, targetID: request.targetID, targetBinding: targetBinding, authorize: authorize)
            } else {
                record = try await model.advance(id: id, targetID: request.targetID, targetBinding: targetBinding, authorize: authorize)
            }
        }
        try authorize()
        var result: [String: Any] = ["state": record.state, "invitationId": record.id,
            "expiresAtUnixSeconds": record.attempt.expiresAtUnixSeconds,
            "deviceBound": ["bound", "complete"].contains(record.state), "rdpLoginRequired": false,
            "ready": record.state == "complete", "retryAction": "codeStatus"]
        if ["creating", "pending", "claimed"].contains(record.state) { result["accessCode"] = record.attempt.code }
        if let deviceID = record.deviceID { result["deviceId"] = deviceID.uuidString.lowercased() }
        return envelope(request, extra: result)
    }
}
#endif
