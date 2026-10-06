#if ENABLE_RDP_2
import Foundation
import ImageIO
import UniformTypeIdentifiers
import JTSCompanionClient

@MainActor
extension CompanionDesktopRuntime {
    func handleMCP(tool: WindowsMCPToolName, target: RemoteSession, arguments: [String: Any]) async throws -> WindowsMCPToolResponse {
        guard let clientID = arguments["_jtsClientID"] as? String, !clientID.isEmpty, target.mcpEnabled else {
            throw WindowsMCPToolError(code: .permissionDenied, message: "An enabled target and registered AI client are required.")
        }
        let security = RDPDesktopRuntimeStore.shared
        security.register(target: target)
        let binding = target.mcpGrantTargetBinding
        let display = MCPClientDisplayIdentity.resolved(arguments["_jtsClientDisplayIdentity"] as? String, authorizationID: clientID)
        let capabilities = Self.capabilities(tool: tool, arguments: arguments)
        let externalData = Self.externalData(tool: tool, arguments: arguments)
        func authorize() throws {
            guard target.mcpEnabled, target.mcpGrantTargetBinding == binding else { throw failure("DESKTOP_TARGET_CHANGED") }
            _ = try security.grantStore.authorize(clientID: clientID, clientDisplayIdentity: display,
                targetID: target.targetID, targetBinding: binding, capabilities: capabilities,
                policy: target.mcpPermissionPolicy, externalDataTypes: externalData, implicitProfileAccess: target.mcpEnabled)
        }
        try authorize()
        let started = Date()
        let token = try security.beginAuthorizedOperation(targetID: target.targetID, targetBinding: binding,
            clientID: clientID, displayIdentity: display, capabilities: capabilities, survivesConnectionTransition: true,
            deferClipboardSuspensionUntilPreparation: true, startedAt: started)
        let task = Task { @MainActor in
            let check: CompanionDevicesModel.MCPAuthorityCheck = {
                try security.requireAuthorizedOperation(token); try authorize()
            }
            try check()
            let response = try await self.performMCP(tool: tool, target: target, arguments: arguments, clientID: clientID, authorize: check)
            try check(); return response
        }
        security.attachAuthorizedOperationCancellation(token) { task.cancel() }
        defer { task.cancel(); security.finishAuthorizedOperation(token) }
        do {
            let response = try await task.value
            security.auditStore.record(clientID: clientID, clientDisplayIdentity: display, targetID: target.targetID,
                targetAlias: target.effectiveMCPAlias, actionType: tool.rawValue, capabilities: capabilities, result: .succeeded,
                resultCode: "OK", controlLeaseExpiresAt: nil, startedAt: started)
            return response
        } catch {
            security.auditStore.record(clientID: clientID, clientDisplayIdentity: display, targetID: target.targetID,
                targetAlias: target.effectiveMCPAlias, actionType: tool.rawValue, capabilities: capabilities, result: .failed,
                resultCode: "DESKTOP_OPERATION_FAILED", controlLeaseExpiresAt: nil, startedAt: started)
            throw error
        }
    }

    private func performMCP(tool: WindowsMCPToolName, target: RemoteSession, arguments: [String: Any], clientID: String,
                            authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> WindowsMCPToolResponse {
        if tool == .openDesktop {
            let session = try await open(target: target, authorize: authorize)
            RDPDesktopWindowCoordinator.shared.open(target, activate: arguments["activate"] as? Bool ?? true)
            return WindowsMCPToolResponse(structuredContent: metadata(session))
        }
        guard let session = sessions[target.targetID],
              let rawSession = arguments["sessionId"] as? String, UUID(uuidString: rawSession) == session.id else {
            throw WindowsMCPToolError.desktopNotOpen
        }
        switch tool {
        case .desktopStatus:
            let state = try await request("status", session: session, body: [:]); session.accept(state)
            return WindowsMCPToolResponse(structuredContent: metadata(session))
        case .desktopObserve:
            let deadline = Date().addingTimeInterval(15)
            session.pollingPaused = true; defer { session.pollingPaused = false }
            while session.busy {
                guard Date() < deadline else { throw failure("DESKTOP_BUSY") }
                try await Task.sleep(for: .milliseconds(10)); try authorize()
            }
            let observed = try await observe(session)
            try observed.requireFresh(generation: session.generation, sessionID: session.windowsSessionID)
            if session.observations.count >= 128,
               let oldest = session.observations.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key {
                session.observations[oldest] = nil
            }
            session.observations[clientID] = observed
            // The viewport may already show a newer pushed frame. Decode the
            // retained observation itself so image and input authorization agree.
            let bytes = try CompanionDesktopFrameDecoder.snapshotPNG(observed)
            var result = metadata(session)
            result.merge(["frameId": observed.frameID.uuidString.lowercased(), "observationId": observed.observationID.uuidString.lowercased(),
                "pixelWidth": observed.width, "pixelHeight": observed.height, "mimeType": "image/png",
                "capturedAt": ISO8601DateFormatter().string(from: observed.capturedAt)]) { _, new in new }
            return WindowsMCPToolResponse(structuredContent: result, pngData: bytes)
        case .desktopAction:
            let result = try await performNativeAction(arguments, session: session, clientID: clientID, authorize: authorize)
            var meta = metadata(session); meta["result"] = result.body.foundationValue
            return WindowsMCPToolResponse(structuredContent: meta)
        case .closeDesktop:
            await close(targetID: target.targetID)
            var result = metadata(session); result["state"] = "disconnected"; result["closed"] = true
            return WindowsMCPToolResponse(structuredContent: result)
        case .desktopUIA, .windowsExec, .windowsFiles, .windowsTask:
            let operation: String
            switch tool {
            case .desktopUIA: operation = "user.uia"
            case .windowsExec: operation = "user.command"
            case .windowsFiles: operation = "user.files"
            default: operation = "user.task"
            }
            let body = try Self.userOperationBody(tool: tool, arguments: arguments)
            let value = try await request(operation, session: session, body: body)
            guard value.body["executionIdentity"]?.stringValue == "interactive-user",
                  let userSID = value.body["userSID"]?.stringValue, userSID.hasPrefix("S-1-"), userSID != "S-1-5-18",
                  userSID.utf8.count <= 184 else { throw failure("DESKTOP_USER_IDENTITY_NOT_VERIFIED") }
            var result = metadata(session)
            result["executionIdentity"] = "interactive-user"; result["userSID"] = userSID
            let fields = value.body["result"]?.foundationValue
            if tool == .desktopUIA {
                let query = try WindowsUIAQuery(arguments)
                let input = query.operation == .find ? ["value": fields ?? []] : (fields as? [String: Any] ?? [:])
                let data = try query.validatedResult(input)
                guard let observation = value.body["observationID"]?.stringValue, UUID(uuidString: observation) != nil else {
                    throw failure("DESKTOP_UIA_OBSERVATION_UNAVAILABLE")
                }
                session.uiaObservations[clientID] = (observation, session.generation, Date().addingTimeInterval(60))
                result.merge(["operation": query.operation.rawValue, "observationId": observation, "validForSeconds": 60,
                    "capturedAt": ISO8601DateFormatter().string(from: Date()), "data": data]) { _, new in new }
            } else if tool == .windowsExec, let command = fields as? [String: Any] {
                result.merge(["exitCode": command["exitCode"] ?? -1, "stdout": command["standardOutput"] ?? "",
                    "stderr": command["standardError"] ?? "", "timedOut": command["timedOut"] ?? false,
                    "truncated": command["outputTruncated"] ?? false, "durationMs": command["durationMilliseconds"] ?? 0]) { _, new in new }
            } else {
                result["operation"] = arguments["operation"] ?? arguments["action"] ?? ""
                if let fields = fields as? [String: Any] { result.merge(fields) { _, new in new } }
                else { result["result"] = fields ?? [:] }
            }
            return WindowsMCPToolResponse(structuredContent: result)
        case .companionPairing:
            throw failure("DESKTOP_PAIRING_MANAGED_BY_DEVICE_ROUTE")
        case .listTargets, .openDesktop:
            throw WindowsMCPToolError(code: .invalidArgument, message: "Invalid native desktop operation.")
        }
    }

    func metadata(_ session: CompanionDesktopSession) -> [String: Any] {
        ["ok": true, "targetId": session.target.targetID.uuidString.lowercased(), "sessionId": session.id.uuidString.lowercased(),
         "transport": "companion-desktop-relay", "requiresRDP": false, "state": session.status,
         "stateRevision": session.revision, "sessionGeneration": session.generation.uuidString.lowercased(),
         "windowsSessionId": session.windowsSessionID, "executionIdentity": "LocalSystem-screen-input",
         "currentUserDefaultRootId": "shared", "currentUserRoots": ["shared"],
         "credentialRefs": ["login": RDPPasswordStore.account(targetID: session.target.targetID)],
         "capabilities": session.remoteState["capabilities"]?.foundationValue ?? [:],
         "currentUserFiles": ["list", "stat", "read", "write"],
         "structuredTasks": false, "elevatedCurrentUserCommands": false, "virtualDisplayQualified": false,
         "transportProof": ["channel": "companion-desktop-relay", "deviceId": session.binding.deviceID.uuidString.lowercased(),
             "desktopGrantId": session.binding.desktopGrantID?.uuidString.lowercased() ?? "",
             "pairingId": session.binding.pairingID?.uuidString.lowercased() ?? ""]]
    }
    private static func capabilities(tool: WindowsMCPToolName, arguments: [String: Any]) -> Set<RemoteCapability> {
        switch tool {
        case .openDesktop: return [.discovery, .desktopControl]
        case .desktopStatus, .listTargets: return [.discovery]
        case .desktopObserve, .desktopUIA: return [.desktopObserve]
        case .desktopAction, .closeDesktop, .companionPairing: return [.desktopControl]
        case .windowsExec: return arguments["requiresElevation"] as? Bool == true ? [.commandExecution, .elevation] : [.commandExecution]
        case .windowsFiles: return ["write", "upload"].contains(arguments["operation"] as? String ?? "") ? [.fileAccess, .destructiveOperations] : [.fileAccess]
        case .windowsTask: return [.structuredTasks]
        }
    }
    private static func externalData(tool: WindowsMCPToolName, arguments: [String: Any]) -> Set<RemoteExternalDataType> {
        switch tool {
        case .desktopObserve: return [.desktopImage]
        case .desktopUIA: return [.desktopStructure]
        case .windowsExec: return [.commandOutput]
        case .windowsFiles: return ["read", "download"].contains(arguments["operation"] as? String ?? "") ? [.fileContent] : [.fileMetadata]
        case .windowsTask: return arguments["action"] as? String == "collect" ? [.fileContent] : []
        default: return []
        }
    }
}

extension DesktopJSONValue {
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let x): return x
        case .integer(let x): return x
        case .number(let x): return x
        case .string(let x): return x
        case .array(let x): return x.map(\.foundationValue)
        case .object(let x): return x.foundationValue
        }
    }
}
extension Dictionary where Key == String, Value == DesktopJSONValue {
    var foundationValue: [String: Any] { mapValues(\.foundationValue) }
}
#endif
