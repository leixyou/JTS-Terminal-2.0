#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices

extension CompanionDeviceMCPHandler {
    func status(_ request: CompanionDeviceMCPRequest, targetBinding: String,
                authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> [String: Any] {
        if ["createCode", "codeStatus", "cancelCode", "revokeRelay"].contains(request.action) {
            return try await enrollmentStatus(request, targetBinding: targetBinding, authorize: authorize)
        }
        let snapshot = try await devices.mcpSnapshot(createIdentity: request.action == "identity")
        try authorize()
        if request.action == "identity" {
            guard let snapshot else { throw CompanionDeviceError.notInitialized }
            let enrollment = try request.delegatedEnrollmentRequest(controllerDeviceID: snapshot.deviceID,
                publicSPKI: snapshot.publicSPKI)
            return envelope(request, extra: ["state": "identityReady", "controllerDeviceID": snapshot.deviceID,
                "controllerSPKIBase64": snapshot.publicSPKI.base64EncodedString(), "enrollmentRequest": enrollment])
        }
        if request.action == "bind" || request.action == "enroll" {
            let deviceID: UUID, grantID: UUID, fileGrantID: UUID?, rdpGrantID: UUID?, pairingID: UUID?
            if request.action == "enroll" {
                let bundle = try CompanionPublicEnrollment(request.arguments["enrollment"] as? [String: Any] ?? [:])
                deviceID = try await devices.importPublicDevice(name: bundle.name, relayURL: bundle.relayURL,
                    peerSPKI: bundle.peerSPKI, peerDeviceID: bundle.peerDeviceID, compatibility: bundle.compatibility)
                grantID = bundle.grantID; fileGrantID = bundle.fileGrantID; rdpGrantID = bundle.rdpGrantID; pairingID = bundle.pairingID
            } else {
                deviceID = try CompanionDeviceMCPRequest.identifier("deviceId", request.arguments)
                grantID = try CompanionDeviceMCPRequest.identifier("grantId", request.arguments)
                fileGrantID = try optionalID("fileGrantId", request.arguments)
                rdpGrantID = try optionalID("rdpGrantId", request.arguments)
                pairingID = nil
            }
            try authorize()
            do {
                try await bindings.requireAssignment(targetID: request.targetID, targetBinding: targetBinding, deviceID: deviceID)
            } catch CompanionTargetRouteError.deviceAssigned {
                throw WindowsMCPToolError(code: .permissionDenied, message: "This Windows device belongs to another saved target. Use that target's own authorization.")
            } catch CompanionTargetRouteError.targetAssigned {
                throw WindowsMCPToolError(code: .permissionDenied, message: "This saved target is pinned to a different Windows identity.")
            }
            _ = try await devices.mcpConnect(deviceID: deviceID, grantID: grantID, authorize: authorize)
            try authorize()
            // Never persist an unverified control grant or substitute it for either data lane.
            try await bindings.bind(targetID: request.targetID, targetBinding: targetBinding, deviceID: deviceID,
                grantID: grantID, fileGrantID: fileGrantID, rdpGrantID: rdpGrantID, pairingID: pairingID)
            try authorize()
        }
        let binding = try await bindings.binding(targetID: request.targetID, targetBinding: targetBinding)
        try authorize()
        guard let binding else {
            return envelope(request, extra: ["state": "unbound", "ready": false])
        }
        if request.action == "connect" {
            _ = try await devices.mcpConnect(deviceID: binding.deviceID, grantID: binding.grantID, authorize: authorize)
        } else if request.action == "disconnect" || request.action == "unbind" {
            devices.routes[binding.deviceID]?.disconnect()
            if request.action == "unbind" { try await bindings.remove(targetID: request.targetID) }
        }
        try authorize()
        let route = devices.routes[binding.deviceID]
        let ready = request.action != "unbind" && route?.hasRoute == true && route?.verifiedGrant == binding.grantID
        let device = devices.snapshot?.devices.first { $0.id == binding.deviceID }
        return envelope(request, binding: binding, extra: ["state": request.action == "unbind" ? "unbound" : ready ? "ready" : "disconnected",
            "ready": ready, "relayURL": device?.relayURL ?? NSNull(), "peerDeviceID": device?.peerDeviceID ?? NSNull(),
            "fileGrantId": binding.fileGrantID?.uuidString.lowercased() ?? NSNull(),
            "rdpGrantId": binding.rdpGrantID?.uuidString.lowercased() ?? NSNull(),
            "capabilities": ready ? route?.capabilities ?? [] : [],
            "grantVerifiedAt": route?.verifiedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "statusSource": request.action == "status" ? "cached" : "operation", "errorCode": route?.errorCode ?? NSNull()])
    }
    private func optionalID(_ key: String, _ values: [String: Any]) throws -> UUID? {
        values[key] == nil ? nil : try CompanionDeviceMCPRequest.identifier(key, values)
    }
}

nonisolated extension CompanionDeviceMCPRequest {
    func delegatedEnrollmentRequest(controllerDeviceID: String, publicSPKI: Data, now: Date = Date()) throws -> [String: Any] {
        guard tool == .status, action == "identity" else { throw Self.invalid("An identity request is required.") }
        let formatter = ISO8601DateFormatter()
        var enrollment: [String: Any] = ["version": 1, "authorizationSource": "ownerDelegated",
            "authorizationReference": "device-ai-control-enabled", "controllerDeviceID": controllerDeviceID,
            "controllerSPKIBase64": publicSPKI.base64EncodedString(),
            "pairingID": UUID().uuidString.lowercased(), "grantID": UUID().uuidString.lowercased(),
            "fileGrantID": UUID().uuidString.lowercased(), "rdpGrantID": UUID().uuidString.lowercased(),
            "issuedAtUtc": formatter.string(from: now), "expiresAtUtc": formatter.string(from: now.addingTimeInterval(1800))]
        // Keep the original TLS 1.3 request compatible with older installers. Compatibility
        // is explicit and becomes part of the public request covered by its pinned SHA-256.
        if try Self.boolean("allowWindows10TLS12", arguments) { enrollment["allowWindows10TLS12"] = true }
        return enrollment
    }
}

nonisolated struct CompanionPublicEnrollment {
    let name, relayURL, peerDeviceID: String
    let peerSPKI: Data
    let pairingID, grantID: UUID
    let fileGrantID, rdpGrantID: UUID?
    let compatibility: Bool
    init(_ value: [String: Any]) throws {
        let keys: Set<String> = ["version", "name", "relayURL", "peerSPKIBase64", "peerDeviceID", "pairingID", "grantID", "fileGrantID", "rdpGrantID", "allowWindows10TLS12", "installationState"]
        guard Set(value.keys).isSubset(of: keys), try CompanionDeviceMCPRequest.integer("version", value, range: 1...1) == 1,
              let name = value["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
              let relay = value["relayURL"] as? String,
              let encoded = value["peerSPKIBase64"] as? String, encoded.utf8.count <= 1024,
              let key = Data(base64Encoded: encoded), key.base64EncodedString() == encoded,
              let peerID = value["peerDeviceID"] as? String,
              try CompanionDeviceRegistry.peerDeviceID(forSPKI: key) == peerID else {
            throw CompanionDeviceMCPRequest.invalid("Invalid Windows public enrollment bundle or public identity fingerprint.")
        }
        self.name = name; relayURL = relay; peerDeviceID = peerID; peerSPKI = key
        grantID = try CompanionDeviceMCPRequest.identifier("grantID", value)
        fileGrantID = value["fileGrantID"] == nil ? nil : try CompanionDeviceMCPRequest.identifier("fileGrantID", value)
        rdpGrantID = value["rdpGrantID"] == nil ? nil : try CompanionDeviceMCPRequest.identifier("rdpGrantID", value)
        pairingID = try CompanionDeviceMCPRequest.identifier("pairingID", value)
        let grants = [grantID, fileGrantID, rdpGrantID, pairingID].compactMap { $0 }
        guard Set(grants).count == grants.count else { throw CompanionDeviceMCPRequest.invalid("Pairing, control, file and RDP identifiers must be distinct.") }
        compatibility = try CompanionDeviceMCPRequest.boolean("allowWindows10TLS12", value)
        if let state = value["installationState"] {
            guard state as? String == "installedAwaitingRelayAdmission" else {
                throw CompanionDeviceMCPRequest.invalid("Unknown Windows installation state.")
            }
        }
    }
}
#endif
