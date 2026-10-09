#if ENABLE_RDP_2
import Foundation
import JTSCompanionIPC

/// The app owns independent connections. The stdio process only forwards registered-client requests.
@MainActor
final class CompanionDeviceMCPHandler {
    static let shared = CompanionDeviceMCPHandler()
    let devices: CompanionDevicesModel
    let bindings: CompanionTargetRouteStore
    let runtime: RDPDesktopRuntimeStore

    init(devices: CompanionDevicesModel = .shared, bindings: CompanionTargetRouteStore = .shared,
         runtime: RDPDesktopRuntimeStore = .shared) {
        self.devices = devices; self.bindings = bindings; self.runtime = runtime
    }

    func handle(tool: CompanionDeviceMCPTool, target: RemoteSession, arguments: [String: Any]) async throws -> [String: Any] {
        let request = try CompanionDeviceMCPRequest(tool: tool, arguments: arguments)
        guard request.targetID == target.targetID, target.mcpEnabled, target.connectionType == .rdp,
              let clientID = arguments["_jtsClientID"] as? String, !clientID.isEmpty else {
            throw WindowsMCPToolError(code: .permissionDenied, message: "A registered AI client and an enabled Windows target are required.")
        }
        let started = Date(), targetBinding = target.mcpGrantTargetBinding
        let display = MCPClientDisplayIdentity.resolved(arguments["_jtsClientDisplayIdentity"] as? String, authorizationID: clientID)
        runtime.register(target: target)
        func authorize() throws {
            guard target.mcpEnabled, target.mcpGrantTargetBinding == targetBinding else {
                throw WindowsMCPToolError(code: .permissionDenied, message: "Target access was disabled or its identity changed.")
            }
            try target.requirePersistentMCPControl(for: request.capabilities)
            _ = try runtime.grantStore.authorize(clientID: clientID, clientDisplayIdentity: display,
                targetID: target.targetID, targetBinding: targetBinding, capabilities: request.capabilities,
                policy: target.mcpPermissionPolicy, externalDataTypes: request.externalData, implicitProfileAccess: target.mcpEnabled)
        }
        do {
            try authorize()
            let token = try runtime.beginAuthorizedOperation(targetID: target.targetID, targetBinding: targetBinding,
                clientID: clientID, displayIdentity: display, capabilities: request.capabilities,
                survivesConnectionTransition: true, deferClipboardSuspensionUntilPreparation: true, startedAt: started)
            let task = Task { @MainActor in
                let check: CompanionDevicesModel.MCPAuthorityCheck = {
                    try self.runtime.requireAuthorizedOperation(token)
                    try authorize()
                }
                try check()
                try await self.runtime.prepareAuthorizedOperation(token)
                try check()
                let result = try await self.perform(request, targetBinding: targetBinding, authorize: check)
                try check()
                return result
            }
            runtime.attachAuthorizedOperationCancellation(token) { task.cancel() }
            defer { task.cancel(); runtime.finishAuthorizedOperation(token) }
            let result = try await task.value
            record(request, target: target, clientID: clientID, display: display, started: started, result: .succeeded, code: "OK")
            return result
        } catch let failure as RemoteGrantGateFailure {
            record(request, target: target, clientID: clientID, display: display, started: started, result: .denied, code: failure.denialCode)
            throw WindowsMCPToolError(code: .permissionDenied, message: failure.message,
                details: ["authorizationCode": failure.denialCode])
        } catch {
            record(request, target: target, clientID: clientID, display: display, started: started, result: .failed, code: "DEVICE_OPERATION_FAILED")
            throw error
        }
    }

    private func record(_ request: CompanionDeviceMCPRequest, target: RemoteSession, clientID: String,
                        display: String, started: Date, result: RemoteCapabilityAuditResult, code: String) {
        runtime.auditStore.record(clientID: clientID, clientDisplayIdentity: display, targetID: target.targetID,
            targetAlias: target.effectiveMCPAlias, actionType: request.tool.rawValue, capabilities: request.capabilities,
            result: result, resultCode: code, controlLeaseExpiresAt: nil, startedAt: started)
    }

    func perform(_ request: CompanionDeviceMCPRequest, targetBinding: String,
                 authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> [String: Any] {
        if request.tool == .status { return try await status(request, targetBinding: targetBinding, authorize: authorize) }
        guard let binding = try await bindings.binding(targetID: request.targetID, targetBinding: targetBinding) else {
            throw WindowsMCPToolError(code: .runtimeFailure, message: "This target has no independent device route. Import the Windows public enrollment bundle with jts_device_status action=enroll.", details: ["deviceCode": "DEVICE_ROUTE_NOT_BOUND"])
        }
        try authorize()
        let route = try await devices.mcpConnect(deviceID: binding.deviceID, grantID: binding.grantID, authorize: authorize)
        try authorize()
        let result: [String: Any]
        switch request.tool {
        case .exec, .task: result = try await job(request, route: route, authorize: authorize)
        case .files: result = try await files(request, binding: binding, authorize: authorize)
        case .status: preconditionFailure("Handled above")
        }
        guard try await bindings.binding(targetID: request.targetID, targetBinding: targetBinding) == binding else {
            throw WindowsMCPToolError(code: .permissionDenied, message: "The target's independent device binding changed during this operation.")
        }
        try authorize()
        return envelope(request, binding: binding, extra: result)
    }

    func envelope(_ request: CompanionDeviceMCPRequest, binding: CompanionTargetRouteBinding? = nil,
                  extra: [String: Any]) -> [String: Any] {
        var value: [String: Any] = ["ok": true, "targetId": request.targetID.uuidString.lowercased(),
            "action": request.action, "transport": "companion-relay", "requiresRDP": false]
        if request.tool != .status || ["connect", "bind", "enroll"].contains(request.action) { value["transportProof"] = "companion-relay" }
        if let binding { value["deviceId"] = binding.deviceID.uuidString.lowercased(); value["grantId"] = binding.grantID.uuidString.lowercased() }
        value.merge(extra) { _, new in new }; return value
    }
}
#endif
