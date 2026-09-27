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
            guard let binding = try await bindings.binding(targetID: request.targetID, targetBinding: targetBinding),
                  let snapshot = try await devices.mcpSnapshot(),
                  let device = snapshot.devices.first(where: { $0.id == binding.deviceID }) else { throw EnrollmentError.changed }
            try await model.revoke(device: device, targetID: request.targetID, authorize: authorize)
            return envelope(request, extra: ["state": "revoked", "ready": false])
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
