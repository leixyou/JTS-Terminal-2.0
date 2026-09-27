#if ENABLE_RDP_2
import CryptoKit
import Foundation

struct WindowsPowerShellExecutionPlan {
    struct ElevationScope: Equatable {
        enum Access: String {
            case read
            case readWrite
        }

        var rootID: String
        var relativePath: String
        var access: Access

        var foundationValue: [String: Any] {
            [
                "rootId": rootID,
                "relativePath": relativePath,
                "access": access.rawValue,
            ]
        }
    }

    struct ElevationGrant: Equatable {
        var leaseID: UUID
        var actionID: String
        var issuedAt: Date
        var expiresAt: Date
        var payloadSHA256: String
    }

    static let maximumScriptCharacters = 65_536
    static let minimumTimeoutMilliseconds = 100
    static let maximumTimeoutMilliseconds = 15 * 60 * 1_000
    static let minimumOutputBytes = 1_024
    static let maximumOutputBytes = 128 * 1_024
    static let maximumElevationScopes = 16

    var script: String
    var rootID: String
    var workingDirectory: String
    var timeoutMilliseconds: Int
    var maximumOutputBytes: Int
    var requiresElevation: Bool
    var elevationDurationMilliseconds: Int?
    var elevationScopes: [ElevationScope]
    var idempotencyKey: String?

    init(arguments: [String: Any]) throws {
        guard let script = Self.nonemptyString(arguments["command"]),
              script.utf16.count <= Self.maximumScriptCharacters,
              !script.contains("\0") else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "PowerShell command must contain 1 to 65,536 characters and no NUL byte."
            )
        }
        guard let rootID = Self.nonemptyString(arguments["rootId"] ?? "default"),
              rootID.utf16.count <= 128,
              let workingDirectory = Self.nonemptyString(arguments["cwd"] ?? "."),
              workingDirectory.utf16.count <= 32_768,
              !workingDirectory.contains("\0") else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "rootId and cwd must be non-empty bounded values."
            )
        }

        let timeout: Int
        if let rawTimeout = arguments["deadlineMs"] {
            guard let parsedTimeout = Self.integer(rawTimeout) else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "deadlineMs must be an integer."
                )
            }
            timeout = parsedTimeout
        } else {
            timeout = 60_000
        }
        guard (Self.minimumTimeoutMilliseconds...Self.maximumTimeoutMilliseconds).contains(timeout) else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "deadlineMs must be between 100 and 900,000 milliseconds."
            )
        }
        let outputBytes: Int
        if let rawOutputBytes = arguments["maxOutputBytes"] {
            guard let parsedOutputBytes = Self.integer(rawOutputBytes) else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "maxOutputBytes must be an integer."
                )
            }
            outputBytes = parsedOutputBytes
        } else {
            outputBytes = Self.maximumOutputBytes
        }
        guard (Self.minimumOutputBytes...Self.maximumOutputBytes).contains(outputBytes) else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "maxOutputBytes must be between 1,024 and 131,072 bytes."
            )
        }

        let requiresElevation: Bool
        if let rawRequiresElevation = arguments["requiresElevation"] {
            guard let parsedRequiresElevation = Self.boolean(rawRequiresElevation) else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "requiresElevation must be a boolean."
                )
            }
            requiresElevation = parsedRequiresElevation
        } else {
            requiresElevation = false
        }
        let key = Self.nonemptyString(arguments["idempotencyKey"])
        if arguments["idempotencyKey"] != nil {
            guard let key, key.utf16.count <= 128, !key.contains("\0") else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "idempotencyKey must contain 1 to 128 characters and no NUL byte."
                )
            }
        }
        let scopes = try Self.parseElevationScopes(arguments["elevationDataScopes"])
        let duration: Int?
        if requiresElevation {
            guard let key else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Elevated PowerShell requires an idempotencyKey of at most 128 characters."
                )
            }
            guard !scopes.isEmpty else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Elevated PowerShell requires one to sixteen explicit elevationDataScopes."
                )
            }
            let requestedDuration: Int
            if let rawDuration = arguments["elevationDurationMs"] {
                guard let parsedDuration = Self.integer(rawDuration) else {
                    throw WindowsMCPToolError(
                        code: .invalidArgument,
                        message: "elevationDurationMs must be an integer."
                    )
                }
                requestedDuration = parsedDuration
            } else {
                requestedDuration = min(Self.maximumTimeoutMilliseconds, max(60_000, timeout + 30_000))
            }
            guard (1...Self.maximumTimeoutMilliseconds).contains(requestedDuration) else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "elevationDurationMs must be between 1 and 900,000 milliseconds."
                )
            }
            duration = requestedDuration
            idempotencyKey = key
        } else {
            guard scopes.isEmpty, arguments["elevationDurationMs"] == nil else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "elevationDurationMs and elevationDataScopes require requiresElevation=true."
                )
            }
            duration = nil
            idempotencyKey = key
        }

        self.script = script
        self.rootID = rootID
        self.workingDirectory = workingDirectory
        self.timeoutMilliseconds = timeout
        self.maximumOutputBytes = outputBytes
        self.requiresElevation = requiresElevation
        elevationDurationMilliseconds = duration
        elevationScopes = scopes
    }

    var currentUserParameters: [String: Any] {
        executionParameters(requiresElevation: false, grant: nil)
    }

    var elevationRequestParameters: [String: Any] {
        [
            "execution": executionParameters(requiresElevation: true, grant: nil),
            "durationMilliseconds": elevationDurationMilliseconds ?? 0,
            "dataScopes": elevationScopes.map(\.foundationValue),
        ]
    }

    func elevatedExecutionParameters(grant: ElevationGrant) -> [String: Any] {
        executionParameters(requiresElevation: true, grant: grant)
    }

    func derivedIdempotencyKey(suffix: String) -> String? {
        guard let idempotencyKey else { return nil }
        let digest = SHA256.hash(data: Data(idempotencyKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let boundedSuffix = String(suffix.prefix(48))
        return "jts:\(digest)\(boundedSuffix)"
    }

    static func elevationGrant(from value: [String: Any], now: Date = Date()) throws -> ElevationGrant {
        guard let leaseIDString = value["leaseId"] as? String,
              let leaseID = UUID(uuidString: leaseIDString),
              let issuedAtString = value["issuedAt"] as? String,
              let issuedAt = parseDate(issuedAtString),
              let expiresAtString = value["expiresAt"] as? String,
              let expiresAt = parseDate(expiresAtString),
              issuedAt <= now.addingTimeInterval(60),
              expiresAt > now,
              expiresAt.timeIntervalSince(issuedAt) > 0,
              expiresAt.timeIntervalSince(issuedAt) <= 15 * 60 + 1,
              let actions = value["actions"] as? [[String: Any]],
              actions.count == 1,
              let action = actions.first,
              let actionID = nonemptyString(action["actionId"]),
              actionID.count <= 128,
              let digest = action["payloadSha256"] as? String,
              isASCIIHexSHA256(digest),
              isApprovedPowerShell(action["kind"]) else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: "The Windows elevation broker returned an invalid or expired action-bound lease."
            )
        }
        return ElevationGrant(
            leaseID: leaseID,
            actionID: actionID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            payloadSHA256: digest.uppercased()
        )
    }

    private func executionParameters(
        requiresElevation: Bool,
        grant: ElevationGrant?
    ) -> [String: Any] {
        var result: [String: Any] = [
            "script": script,
            "rootId": rootID,
            "workingDirectory": workingDirectory,
            "timeoutMilliseconds": timeoutMilliseconds,
            "maximumOutputBytes": maximumOutputBytes,
            "requiresElevation": requiresElevation,
        ]
        if let grant {
            result["elevationLeaseId"] = grant.leaseID.uuidString.lowercased()
            result["elevationActionId"] = grant.actionID
        }
        return result
    }

    private static func parseElevationScopes(_ value: Any?) throws -> [ElevationScope] {
        guard let value else { return [] }
        guard let rawScopes = value as? [Any],
              !rawScopes.isEmpty,
              rawScopes.count <= maximumElevationScopes else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "elevationDataScopes must contain one to sixteen scope objects."
            )
        }
        return try rawScopes.map { raw in
            guard let dictionary = raw as? [String: Any],
                  let rootID = nonemptyString(dictionary["rootId"]),
                  rootID.utf16.count <= 128,
                  let relativePath = nonemptyString(dictionary["relativePath"]),
                  relativePath.utf16.count <= 32_768,
                  !relativePath.contains("\0"),
                  let accessValue = dictionary["access"] as? String,
                  let access = ElevationScope.Access(rawValue: accessValue) else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Every elevationDataScope requires rootId, relativePath, and access=read or readWrite."
                )
            }
            return ElevationScope(rootID: rootID, relativePath: relativePath, access: access)
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let floatingValue = number.doubleValue
        guard floatingValue.isFinite,
              floatingValue.rounded(.towardZero) == floatingValue,
              floatingValue >= Double(Int.min),
              floatingValue <= Double(Int.max) else {
            return nil
        }
        return Int(floatingValue)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func isApprovedPowerShell(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.intValue == 0
        }
        if let integer = value as? Int {
            return integer == 0
        }
        if let string = value as? String {
            return string.caseInsensitiveCompare("approvedPowerShell") == .orderedSame
        }
        return false
    }

    private static func isASCIIHexSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

@MainActor
extension RDPDesktopRuntimeStore {
    func handleMCP(
        tool: WindowsMCPToolName,
        target: RemoteSession,
        arguments: [String: Any]
    ) async throws -> WindowsMCPToolResponse {
        register(target: target)
        let startedAt = Date()
        let clientID = (arguments["_jtsClientID"] as? String) ?? "unidentified-mcp-client"
        let clientDisplayIdentity = MCPClientDisplayIdentity.resolved(
            arguments["_jtsClientDisplayIdentity"] as? String,
            authorizationID: clientID
        )
        let capabilities = requiredCapabilities(for: tool, arguments: arguments)
        let externalDataTypes = requiredExternalDataTypes(for: tool, arguments: arguments)
        let auditAction = auditActionType(for: tool, arguments: arguments)
        let targetBinding = target.mcpGrantTargetBinding
        var authorization: RemoteGrantAuthorization?

        do {
            authorization = try grantStore.authorize(
                clientID: clientID,
                clientDisplayIdentity: clientDisplayIdentity,
                targetID: target.targetID,
                targetBinding: targetBinding,
                capabilities: capabilities,
                policy: target.mcpPermissionPolicy,
                externalDataTypes: externalDataTypes,
                implicitProfileAccess: target.mcpEnabled
            )
            let operationToken = try beginAuthorizedOperation(
                targetID: target.targetID,
                targetBinding: targetBinding,
                clientID: authorization?.clientID ?? clientID,
                displayIdentity: authorization?.clientDisplayIdentity
                    ?? clientDisplayIdentity,
                capabilities: capabilities,
                survivesConnectionTransition: survivesConnectionTransition(for: tool),
                deferClipboardSuspensionUntilPreparation: tool.requiresCompanion,
                startedAt: startedAt
            )
            let operationTask = Task { @MainActor [weak self] in
                guard let self else {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "The RDP runtime ended before the authorized operation started."
                    )
                }
                try self.requireAuthorizedOperation(operationToken)
                if !tool.requiresCompanion {
                    try await self.prepareAuthorizedOperation(operationToken)
                }
                try self.requireAuthorizedOperation(operationToken)
                return try await self.performAuthorizedMCP(
                    tool: tool,
                    target: target,
                    arguments: arguments,
                    authorization: authorization,
                    operationToken: operationToken
                )
            }
            attachAuthorizedOperationCancellation(operationToken) {
                operationTask.cancel()
            }
            defer {
                operationTask.cancel()
                finishAuthorizedOperation(operationToken)
            }
            let response: WindowsMCPToolResponse
            do {
                response = try await operationTask.value
            } catch is CancellationError {
                // Revocation normally cancels the in-flight child before its
                // next explicit generation check. Re-check authority while
                // ignoring only the parent's cancellation bit so takeover and
                // Emergency Stop return the stable permission-denied contract.
                try requireAuthorizedOperation(
                    operationToken,
                    ignoringCurrentTaskCancellation: true
                )
                throw CancellationError()
            }
            auditStore.record(
                clientID: clientID,
                clientDisplayIdentity: authorization?.clientDisplayIdentity
                    ?? clientDisplayIdentity,
                targetID: target.targetID,
                targetAlias: target.effectiveMCPAlias,
                actionType: auditAction,
                capabilities: capabilities,
                result: .succeeded,
                resultCode: "OK",
                controlLeaseExpiresAt: nil,
                startedAt: startedAt
            )
            return response
        } catch let failure as RemoteGrantGateFailure {
            auditStore.record(
                clientID: clientID,
                clientDisplayIdentity: clientDisplayIdentity,
                targetID: target.targetID,
                targetAlias: target.effectiveMCPAlias,
                actionType: auditAction,
                capabilities: capabilities,
                result: .denied,
                resultCode: failure.denialCode,
                controlLeaseExpiresAt: nil,
                startedAt: startedAt
            )
            var details: [String: Any] = ["authorizationCode": failure.denialCode]
            if let requestID = failure.pendingRequestID {
                details["pendingRequestId"] = requestID.uuidString.lowercased()
            }
            throw WindowsMCPToolError(
                code: .permissionDenied,
                message: failure.message,
                details: details
            )
        } catch let failure as WindowsMCPToolError {
            auditStore.record(
                clientID: clientID,
                clientDisplayIdentity: authorization?.clientDisplayIdentity
                    ?? clientDisplayIdentity,
                targetID: target.targetID,
                targetAlias: target.effectiveMCPAlias,
                actionType: auditAction,
                capabilities: capabilities,
                result: failure.code == .permissionDenied ? .denied : .failed,
                resultCode: failure.code.rawValue,
                controlLeaseExpiresAt: nil,
                startedAt: startedAt
            )
            throw failure
        } catch {
            auditStore.record(
                clientID: clientID,
                clientDisplayIdentity: authorization?.clientDisplayIdentity
                    ?? clientDisplayIdentity,
                targetID: target.targetID,
                targetAlias: target.effectiveMCPAlias,
                actionType: auditAction,
                capabilities: capabilities,
                result: .failed,
                resultCode: "RUNTIME_FAILURE",
                controlLeaseExpiresAt: nil,
                startedAt: startedAt
            )
            throw error
        }
    }

    private func performAuthorizedMCP(
        tool: WindowsMCPToolName,
        target: RemoteSession,
        arguments: [String: Any],
        authorization: RemoteGrantAuthorization?,
        operationToken: RDPAuthorizedOperationToken
    ) async throws -> WindowsMCPToolResponse {
        register(target: target)
        try requireAuthorizedOperation(operationToken)
        let clientID = authorization?.clientID
            ?? ((arguments["_jtsClientID"] as? String) ?? "unidentified-mcp-client")
        let clientDisplayIdentity = authorization?.clientDisplayIdentity
            ?? MCPClientDisplayIdentity.resolved(nil, authorizationID: clientID)

        switch tool {
        case .listTargets:
            throw WindowsMCPToolError(code: .invalidArgument, message: "jts_list_targets is handled by the MCP catalog.")

        case .openDesktop:
            let request = DesktopOpenRequest(
                deadlineMilliseconds: integer(arguments["deadlineMs"]),
                deadlineUptimeMilliseconds: integer(arguments["_jtsDeadlineUptimeMilliseconds"])
                    .flatMap { $0 >= 0 ? UInt64($0) : nil },
                clientID: arguments["_jtsClientID"] as? String,
                idempotencyKey: arguments["idempotencyKey"] as? String,
                requestedPixelWidth: integer(arguments["requestedWidth"]),
                requestedPixelHeight: integer(arguments["requestedHeight"]),
                activateWindow: arguments["activate"] as? Bool
            )
            try requireAuthorizedOperation(operationToken)
            let state = try await open(target: target, request: request)
            try requireAuthorizedOperation(operationToken)
            return response(state: state, extra: ["ok": true])

        case .desktopStatus:
            let activeSessionID = try requestedSessionID(arguments, target: target)
            let state = try await desktopState(sessionID: activeSessionID)
            try requireAuthorizedOperation(operationToken)
            var extra: [String: Any] = ["ok": true]
            if let metadata = pairingDelegationSnapshot(sessionID: activeSessionID) {
                extra["pairingDelegation"] = metadata
            }
            return response(state: state, extra: extra)

        case .companionPairing:
            let request = try WindowsMCPCompanionPairingRequest(arguments)
            guard request.targetID == target.targetID else {
                throw WindowsMCPToolError(code: .stateConflict,
                    message: "Pairing targetId does not match the authorized device.")
            }
            let activeSessionID = try requestedSessionID(arguments, target: target)
            try requireAuthorizedOperation(operationToken)
            var result: [String: Any]
            switch request.action {
            case .status:
                result = try await companionPairingStatus(sessionID: activeSessionID)
            case .confirm:
                _ = try await requireOpenConnectedDesktop(
                    target: target, arguments: arguments, operationToken: operationToken)
                result = try await confirmDelegatedCompanionPairing(
                    sessionID: activeSessionID, deadlineMilliseconds: request.deadlineMilliseconds)
            case .revoke:
                result = try await revokeCompanionDelegation(
                    sessionID: activeSessionID, deadlineMilliseconds: request.deadlineMilliseconds)
            }
            try requireAuthorizedOperation(operationToken)
            result["ok"] = true
            result["action"] = request.action.rawValue
            result["targetId"] = target.targetID.uuidString.lowercased()
            result["sessionId"] = activeSessionID.uuidString.lowercased()
            return WindowsMCPToolResponse(structuredContent: result)

        case .desktopObserve:
            let activeSessionID = try requestedSessionID(arguments, target: target)
            let frame = try await observeDesktop(sessionID: activeSessionID)
            try requireAuthorizedOperation(operationToken)
            guard frame.metadata.sessionID == activeSessionID,
                  frame.metadata.mimeType == "image/png",
                  !frame.pngData.isEmpty else {
                throw WindowsMCPToolError(
                    code: .runtimeFailure,
                    message: "The RDP runtime returned inconsistent desktop observation data."
                )
            }
            markAIViewing(
                targetID: target.targetID,
                clientID: clientID,
                displayIdentity: clientDisplayIdentity
            )
            return WindowsMCPToolResponse(
                structuredContent: [
                    "ok": true,
                    "targetId": target.targetID.uuidString.lowercased(),
                    "sessionId": activeSessionID.uuidString.lowercased(),
                    "frameId": frame.metadata.frameID.uuidString.lowercased(),
                    "stateRevision": frame.metadata.stateRevision,
                    "pixelWidth": frame.metadata.pixelWidth,
                    "pixelHeight": frame.metadata.pixelHeight,
                    "capturedAt": ISO8601DateFormatter().string(from: frame.metadata.capturedAt),
                    "mimeType": frame.metadata.mimeType,
                ],
                pngData: frame.pngData
            )

        case .desktopUIA:
            let query = try WindowsUIAQuery(arguments)
            let activeSessionID = try await requireOpenConnectedDesktop(
                target: target, arguments: arguments, operationToken: operationToken)
            try await prepareCompanionOperation(operationToken)
            let peer = try companionPeerIdentity(sessionID: activeSessionID)
            guard peer.capabilities.contains(query.method) else {
                throw WindowsMCPToolError(code: .companionRequired, message: "The paired Windows Companion does not support this UI Automation read operation.")
            }
            let result = try await companionRequest(sessionID: activeSessionID, method: query.method,
                parameters: query.parameters, deadlineMilliseconds: query.deadlineMilliseconds,
                idempotencyKey: nil, expectedStateRevision: unsignedInteger(arguments["expectedStateRevision"]))
            try requireAuthorizedOperation(operationToken)
            let data = try query.validatedResult(result)
            let state = try await desktopState(sessionID: activeSessionID)
            try requireAuthorizedOperation(operationToken)
            let observationID = uiaObservations.record(token: operationToken, sessionID: activeSessionID)
            markAIViewing(targetID: target.targetID, clientID: clientID, displayIdentity: clientDisplayIdentity)
            return response(state: state, extra: ["ok": true, "operation": query.operation.rawValue,
                "transportProof": ["channel": "companion-dvc"],
                "observationId": observationID.uuidString.lowercased(), "validForSeconds": 60,
                "capturedAt": ISO8601DateFormatter().string(from: Date()), "data": data])

        case .desktopAction:
            let activeSessionID = try requestedSessionID(arguments, target: target)
            let request = try WindowsMCPDesktopActionRequestParser.parse(arguments)
            try requireAuthorizedOperation(operationToken)
            if let raw = arguments["expectedUiaObservationId"] as? String, let id = UUID(uuidString: raw) {
                try uiaObservations.validate(id, token: operationToken, sessionID: activeSessionID)
            }
            let state = try await performDesktopAction(sessionID: activeSessionID, request: request)
            try requireAuthorizedOperation(operationToken)
            return response(state: state, extra: ["ok": true, "accepted": true])

        case .windowsExec:
            let plan = try WindowsPowerShellExecutionPlan(arguments: arguments)
            let activeSessionID = try await requireOpenConnectedDesktop(
                target: target,
                arguments: arguments,
                operationToken: operationToken
            )
            try await prepareCompanionOperation(operationToken)
            let result: [String: Any]
            var elevation: [String: Any] = ["requested": false]
            if plan.requiresElevation {
                try requireAuthorizedOperation(operationToken)
                let leaseValue = try await companionRequest(
                    sessionID: activeSessionID,
                    method: DVCOperation.elevationRequest.rawValue,
                    parameters: plan.elevationRequestParameters,
                    deadlineMilliseconds: plan.timeoutMilliseconds,
                    idempotencyKey: plan.derivedIdempotencyKey(suffix: ":elevation-request"),
                    expectedStateRevision: unsignedInteger(arguments["expectedStateRevision"])
                )
                let grant = try WindowsPowerShellExecutionPlan.elevationGrant(from: leaseValue)
                do {
                    try requireAuthorizedOperation(operationToken)
                    result = try await companionRequest(
                        sessionID: activeSessionID,
                        method: DVCOperation.shellExec.rawValue,
                        parameters: plan.elevatedExecutionParameters(grant: grant),
                        deadlineMilliseconds: plan.timeoutMilliseconds,
                        idempotencyKey: plan.derivedIdempotencyKey(suffix: ":elevation-execute"),
                        expectedStateRevision: unsignedInteger(arguments["expectedStateRevision"])
                    )
                } catch {
                    _ = await releaseElevationLease(
                        sessionID: activeSessionID,
                        grant: grant,
                        deadlineMilliseconds: plan.timeoutMilliseconds
                    )
                    throw error
                }
                let released = await releaseElevationLease(
                    sessionID: activeSessionID,
                    grant: grant,
                    deadlineMilliseconds: plan.timeoutMilliseconds
                )
                elevation = [
                    "requested": true,
                    "leaseId": grant.leaseID.uuidString.lowercased(),
                    "expiresAt": ISO8601DateFormatter().string(from: grant.expiresAt),
                    "released": released,
                ]
            } else {
                try requireAuthorizedOperation(operationToken)
                result = try await companionRequest(
                    sessionID: activeSessionID,
                    method: DVCOperation.shellExec.rawValue,
                    parameters: plan.currentUserParameters,
                    deadlineMilliseconds: plan.timeoutMilliseconds,
                    idempotencyKey: plan.idempotencyKey,
                    expectedStateRevision: unsignedInteger(arguments["expectedStateRevision"])
                )
            }
            try requireAuthorizedOperation(operationToken)
            return WindowsMCPToolResponse(structuredContent: [
                "ok": true,
                "targetId": target.targetID.uuidString.lowercased(),
                "sessionId": activeSessionID.uuidString.lowercased(),
                "exitCode": integer(result["exitCode"]) ?? -1,
                "stdout": result["standardOutput"] as? String ?? "",
                "stderr": result["standardError"] as? String ?? "",
                "timedOut": result["timedOut"] as? Bool ?? false,
                "truncated": result["outputTruncated"] as? Bool ?? false,
                "durationMs": integer(result["durationMilliseconds"]) ?? 0,
                "elevation": elevation,
                "transportProof": ["channel": "companion-dvc"],
            ])

        case .windowsFiles:
            let operation = try requiredString("operation", arguments)
            guard let fileOperation = RemoteFileOperation(rawValue: operation) else {
                throw WindowsMCPToolError(code: .invalidArgument, message: "Unsupported Windows file operation: \(operation).")
            }
            let preparedOperation = try prepareWindowsFileOperation(
                operation: fileOperation,
                arguments: arguments
            )
            let activeSessionID = try await requireOpenConnectedDesktop(
                target: target,
                arguments: arguments,
                operationToken: operationToken
            )
            try await prepareCompanionOperation(operationToken)
            let result = try await performWindowsFileOperation(
                preparedOperation,
                sessionID: activeSessionID,
                arguments: arguments,
                operationToken: operationToken
            )
            var structured = result
            if structured["ok"] == nil {
                structured["ok"] = true
            }
            structured["targetId"] = target.targetID.uuidString.lowercased()
            structured["sessionId"] = activeSessionID.uuidString.lowercased()
            structured["operation"] = fileOperation.rawValue
            structured["transportProof"] = ["channel": "companion-dvc"]
            return WindowsMCPToolResponse(structuredContent: structured)

        case .windowsTask:
            let actionString = try requiredString("action", arguments)
            guard let action = RemoteTaskAction(rawValue: actionString) else {
                throw WindowsMCPToolError(code: .invalidArgument, message: "Unsupported Windows worker action: \(actionString).")
            }
            let rawJobID = arguments["jobId"] as? String
            let jobID = rawJobID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let rawJobID, rawJobID != jobID {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Windows worker jobId must not contain leading or trailing whitespace."
                )
            }
            let submittedBundleBase64: String?
            switch action {
            case .doctor:
                submittedBundleBase64 = nil
            case .submit:
                guard let bundleBase64 = arguments["bundleBase64"] as? String,
                      !bundleBase64.isEmpty,
                      bundleBase64.utf8.count
                        <= maximumBase64CharacterCount(
                            forDecodedByteCount:
                                WindowsCompanionBinaryTransferManager.maximumTransferBytes
                        ) else {
                    throw WindowsMCPToolError(
                        code: .invalidArgument,
                        message: "Windows worker submit requires a non-empty bundleBase64 within the Companion transfer limit."
                    )
                }
                guard let jobID, !jobID.isEmpty else {
                    throw WindowsMCPToolError(
                        code: .invalidArgument,
                        message: "Windows worker submit requires a non-empty jobId."
                    )
                }
                submittedBundleBase64 = bundleBase64
            case .status, .cancel, .collect:
                guard let jobID, !jobID.isEmpty else {
                    throw WindowsMCPToolError(
                        code: .invalidArgument,
                        message: "Windows worker \(action.rawValue) requires a non-empty jobId."
                    )
                }
                submittedBundleBase64 = nil
            }
            let activeSessionID = try await requireOpenConnectedDesktop(
                target: target,
                arguments: arguments,
                operationToken: operationToken
            )
            let submittedBundle: Data?
            if let submittedBundleBase64 {
                guard let bundle = Data(base64Encoded: submittedBundleBase64),
                      !bundle.isEmpty,
                      bundle.count
                        <= WindowsCompanionBinaryTransferManager.maximumTransferBytes else {
                    throw WindowsMCPToolError(
                        code: .invalidArgument,
                        message: "Windows worker submit requires a valid non-empty bundleBase64 within the Companion transfer limit."
                    )
                }
                submittedBundle = bundle
            } else {
                submittedBundle = nil
            }
            try await prepareCompanionOperation(operationToken)
            let method = "worker.\(action.rawValue)"
            var parameters: [String: Any] = [:]
            if let jobID {
                parameters["jobId"] = jobID
            }
            let deadline = integer(arguments["deadlineMs"])
            var uploadTransferID: UUID?
            if action == .submit {
                guard let bundle = submittedBundle, let jobID else {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "The validated Windows worker submit plan is unavailable."
                    )
                }
                try Task.checkCancellation()
                try requireAuthorizedOperation(operationToken)
                let peer = try companionPeerIdentity(sessionID: activeSessionID)
                let signingKey = try await RDPCompanionKeychainAccess.shared.signingKey(
                    targetID: target.targetID
                )
                try requireAuthorizedOperation(operationToken)
                let bundleSHA256 = sha256(bundle)
                let jobEnvelope: VRCJobEnvelope
                do {
                    jobEnvelope = try VRCEnvelopeSecurity.signJob(
                        peer: peer,
                        jobID: jobID,
                        totalBytes: Int64(bundle.count),
                        bundleSHA256: bundleSHA256,
                        signingKey: signingKey
                    )
                } catch let error as VRCEnvelopeSecurityError {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: error.localizedDescription,
                        details: ["envelopeCode": error.code]
                    )
                }
                try requireAuthorizedOperation(operationToken)
                let transfer = try await uploadCompanionBinary(
                    sessionID: activeSessionID,
                    data: bundle,
                    purpose: "vrc-worker-submit",
                    deadlineMilliseconds: deadline
                )
                uploadTransferID = transfer.transferID
                parameters["transferId"] = transfer.transferID.uuidString.lowercased()
                parameters["totalBytes"] = transfer.totalBytes
                parameters["bundleSha256"] = transfer.sha256
                parameters["jobEnvelope"] = jobEnvelope.foundationValue
            }
            let result: [String: Any]
            do {
                try requireAuthorizedOperation(operationToken)
                result = try await companionRequest(
                    sessionID: activeSessionID,
                    method: method,
                    parameters: parameters,
                    deadlineMilliseconds: deadline,
                    idempotencyKey: action == .submit || action == .collect
                        ? nil
                        : arguments["idempotencyKey"] as? String,
                    expectedStateRevision: unsignedInteger(arguments["expectedStateRevision"])
                )
                try requireAuthorizedOperation(operationToken)
            } catch {
                if let uploadTransferID {
                    await releaseCompanionBinary(
                        sessionID: activeSessionID,
                        transferID: uploadTransferID,
                        deadlineMilliseconds: deadline
                    )
                }
                throw error
            }
            if let uploadTransferID {
                await releaseCompanionBinary(
                    sessionID: activeSessionID,
                    transferID: uploadTransferID,
                    deadlineMilliseconds: deadline
                )
            }
            let returnedJobID: String?
            if action == .doctor {
                returnedJobID = nil
            } else {
                guard let requestedJobID = jobID,
                      let companionJobID = result["jobId"] as? String,
                      companionJobID == requestedJobID else {
                    if action == .collect {
                        await releaseReturnedCompanionBinaryIfPresent(
                            result,
                            sessionID: activeSessionID,
                            deadlineMilliseconds: deadline
                        )
                    }
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "Windows Companion returned a jobId that did not match the requested job.",
                        details: [
                            "machineCode": "COMPANION_JOB_ID_MISMATCH",
                            "action": action.rawValue,
                        ]
                    )
                }
                returnedJobID = companionJobID
            }
            var structured = result
            if structured["ok"] == nil {
                structured["ok"] = true
            }
            structured["targetId"] = target.targetID.uuidString.lowercased()
            structured["sessionId"] = activeSessionID.uuidString.lowercased()
            structured.removeValue(forKey: "taskId")
            if let returnedJobID {
                structured["jobId"] = returnedJobID
            } else {
                structured.removeValue(forKey: "jobId")
            }
            structured["state"] = normalizedTaskState(result["state"], action: action)
            structured["transportProof"] = ["channel": "companion-dvc"]
            if action == .collect {
                let descriptor: DVCBinaryTransferDescriptor
                do {
                    descriptor = try binaryTransferDescriptor(
                        result,
                        purpose: "vrc-worker-result",
                        sha256Field: "bundleSha256",
                        minimumBytes: 1,
                        maximumBytes: WindowsCompanionBinaryTransferManager.maximumTransferBytes,
                        invalidMessage: "Windows worker collect returned an invalid binary transfer descriptor."
                    )
                } catch {
                    await releaseReturnedCompanionBinaryIfPresent(
                        result,
                        sessionID: activeSessionID,
                        deadlineMilliseconds: deadline
                    )
                    throw error
                }
                do {
                    let peer = try companionPeerIdentity(sessionID: activeSessionID)
                    guard let requestedJobID = jobID,
                          let returnedJobID = result["jobId"] as? String,
                          returnedJobID == requestedJobID,
                          result["state"] as? String == "collected",
                          let resultEnvelope = result["resultEnvelope"] else {
                        throw VRCEnvelopeSecurityError.invalidResultEnvelope
                    }
                    _ = try VRCEnvelopeSecurity.verifyResult(
                        resultEnvelope,
                        peer: peer,
                        expectedJobID: requestedJobID,
                        expectedTotalBytes: descriptor.totalBytes,
                        expectedBundleSHA256: descriptor.sha256
                    )
                } catch let error as VRCEnvelopeSecurityError {
                    await releaseCompanionBinary(
                        sessionID: activeSessionID,
                        transferID: descriptor.transferID,
                        deadlineMilliseconds: deadline
                    )
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: error.localizedDescription,
                        details: ["envelopeCode": error.code]
                    )
                } catch {
                    await releaseCompanionBinary(
                        sessionID: activeSessionID,
                        transferID: descriptor.transferID,
                        deadlineMilliseconds: deadline
                    )
                    throw error
                }
                try requireAuthorizedOperation(operationToken)
                let bundle = try await downloadCompanionBinary(
                    sessionID: activeSessionID,
                    descriptor: descriptor,
                    deadlineMilliseconds: deadline
                )
                try requireAuthorizedOperation(operationToken)
                structured["bundleBase64"] = bundle.base64EncodedString()
                structured["bundleSha256"] = descriptor.sha256
            }
            try requireAuthorizedOperation(operationToken)
            return WindowsMCPToolResponse(structuredContent: structured)

        case .closeDesktop:
            let activeSessionID = try requestedSessionID(arguments, target: target)
            try requireAuthorizedOperation(operationToken)
            try await closeDesktop(sessionID: activeSessionID)
            return WindowsMCPToolResponse(structuredContent: [
                "ok": true,
                "targetId": target.targetID.uuidString.lowercased(),
                "sessionId": activeSessionID.uuidString.lowercased(),
                "closed": true,
            ])
        }
    }

    private func requiredCapabilities(
        for tool: WindowsMCPToolName,
        arguments: [String: Any]
    ) -> Set<RemoteCapability> {
        switch tool {
        case .listTargets, .openDesktop, .desktopStatus:
            return [.discovery]
        case .desktopObserve, .desktopUIA:
            return [.desktopObserve]
        case .desktopAction, .companionPairing, .closeDesktop:
            return [.desktopControl]
        case .windowsExec:
            if arguments["requiresElevation"] as? Bool == true {
                return [.commandExecution, .elevation]
            }
            return [.commandExecution]
        case .windowsFiles:
            let operation = (arguments["operation"] as? String).flatMap(RemoteFileOperation.init(rawValue:))
            switch operation {
            case .write, .upload:
                return [.fileAccess, .destructiveOperations]
            case .list, .stat, .read, .download, .none:
                return [.fileAccess]
            }
        case .windowsTask:
            return [.structuredTasks]
        }
    }

    private func requiredExternalDataTypes(
        for tool: WindowsMCPToolName,
        arguments: [String: Any]
    ) -> Set<RemoteExternalDataType> {
        switch tool {
        case .listTargets:
            return [.targetMetadata]
        case .desktopObserve:
            return [.desktopImage]
        case .desktopUIA:
            return [.desktopStructure]
        case .windowsExec:
            return [.commandOutput]
        case .windowsFiles:
            let operation = (arguments["operation"] as? String)
                .flatMap(RemoteFileOperation.init(rawValue:))
            switch operation {
            case .list, .stat:
                return [.fileMetadata]
            case .read, .download:
                return [.fileContent]
            case .write, .upload, .none:
                return []
            }
        case .windowsTask:
            let action = (arguments["action"] as? String)
                .flatMap(RemoteTaskAction.init(rawValue:))
            return action == .collect ? [.fileContent] : []
        case .openDesktop, .desktopStatus, .companionPairing, .desktopAction, .closeDesktop:
            return []
        }
    }

    private func survivesConnectionTransition(
        for tool: WindowsMCPToolName
    ) -> Bool {
        switch tool {
        case .openDesktop, .desktopStatus, .companionPairing, .closeDesktop:
            return true
        case .listTargets, .desktopObserve, .desktopUIA, .desktopAction, .windowsExec,
             .windowsFiles, .windowsTask:
            return false
        }
    }

    private func auditActionType(
        for tool: WindowsMCPToolName,
        arguments: [String: Any]
    ) -> String {
        switch tool {
        case .companionPairing:
            guard let raw = arguments["action"] as? String,
                  let action = WindowsMCPCompanionPairingRequest.Action(rawValue: raw) else {
                return tool.rawValue
            }
            return "\(tool.rawValue).\(action.rawValue)"
        case .desktopAction:
            guard let raw = arguments["action"] as? String,
                  let action = DesktopActionKind(rawValue: raw) else {
                return tool.rawValue
            }
            return "\(tool.rawValue).\(action.rawValue)"
        case .windowsFiles:
            guard let raw = arguments["operation"] as? String,
                  let operation = RemoteFileOperation(rawValue: raw) else {
                return tool.rawValue
            }
            return "\(tool.rawValue).\(operation.rawValue)"
        case .windowsTask:
            guard let raw = arguments["action"] as? String,
                  let action = RemoteTaskAction(rawValue: raw) else {
                return tool.rawValue
            }
            return "\(tool.rawValue).\(action.rawValue)"
        case .listTargets, .openDesktop, .desktopStatus, .desktopObserve, .desktopUIA,
             .windowsExec, .closeDesktop:
            return tool.rawValue
        }
    }

    private func requireOpenConnectedDesktop(
        target: RemoteSession,
        arguments: [String: Any],
        operationToken: RDPAuthorizedOperationToken
    ) async throws -> UUID {
        try requireAuthorizedOperation(operationToken)
        guard let rawSessionID = arguments["sessionId"] as? String,
              let requestedSessionID = UUID(uuidString: rawSessionID) else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "sessionId must be the UUID returned by jts_open_desktop."
            )
        }
        guard let activeSessionID = sessionID(for: target) else {
            throw WindowsMCPToolError.desktopNotOpen
        }
        guard requestedSessionID == activeSessionID else {
            throw WindowsMCPToolError(
                code: .stateConflict,
                message: "sessionId does not identify the current endpoint's active RDP desktop session.",
                details: [
                    "machineCode": "RDP_DESKTOP_SESSION_MISMATCH",
                    "retryable": true,
                ]
            )
        }
        let state = try await desktopState(sessionID: activeSessionID)
        guard state.phase == .connected else {
            throw WindowsMCPToolError.desktopNotConnected(phase: state.phase)
        }
        try requireAuthorizedOperation(operationToken)
        return activeSessionID
    }

    private func prepareCompanionOperation(
        _ operationToken: RDPAuthorizedOperationToken
    ) async throws {
        try requireAuthorizedOperation(operationToken)
        // Run the clipboard barrier only after request validation and the
        // exact visible-session preflight have both succeeded. Invalid or
        // closed-session calls therefore cannot disturb human clipboard state.
        try await prepareAuthorizedOperation(operationToken)
        try requireAuthorizedOperation(operationToken)
    }

    private func releaseElevationLease(
        sessionID: UUID,
        grant: WindowsPowerShellExecutionPlan.ElevationGrant,
        deadlineMilliseconds: Int
    ) async -> Bool {
        do {
            _ = try await companionRequest(
                sessionID: sessionID,
                method: DVCOperation.elevationRelease.rawValue,
                parameters: ["leaseId": grant.leaseID.uuidString.lowercased()],
                deadlineMilliseconds: min(max(deadlineMilliseconds, 1_000), 10_000),
                idempotencyKey: nil,
                expectedStateRevision: nil
            )
            return true
        } catch {
            return false
        }
    }

    private func requestedSessionID(
        _ arguments: [String: Any],
        target: RemoteSession
    ) throws -> UUID {
        guard let raw = arguments["sessionId"] as? String,
              let sessionID = UUID(uuidString: raw),
              sessionID == self.sessionID(for: target),
              sessionMatchesTarget(sessionID: sessionID, target: target) else {
            throw WindowsMCPToolError(
                code: .stateConflict,
                message: "sessionId does not identify the current endpoint's active RDP desktop session."
            )
        }
        return sessionID
    }

    private struct PreparedWindowsFileOperation {
        let operation: RemoteFileOperation
        let rootID: String
        let path: String
        let writeContentBase64: String?
        let writeContent: Data?
        let transferPlan: WindowsMCPFileTransferPlan?
    }

    private func prepareWindowsFileOperation(
        operation: RemoteFileOperation,
        arguments: [String: Any]
    ) throws -> PreparedWindowsFileOperation {
        let rootID = (arguments["rootId"] as? String) ?? "default"
        let path = try requiredString("path", arguments)
        var writeContentBase64: String?
        var writeContent: Data?
        var transferPlan: WindowsMCPFileTransferPlan?

        switch operation {
        case .list, .stat, .read:
            break
        case .write:
            let maximumInlineBase64Characters = ((512 * 1_024 + 2) / 3) * 4
            guard let contentBase64 = arguments["contentBase64"] as? String,
                  contentBase64.utf8.count <= maximumInlineBase64Characters,
                  let content = Data(base64Encoded: contentBase64),
                  content.count <= 512 * 1_024 else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Windows writes require valid contentBase64."
                )
            }
            writeContentBase64 = contentBase64
            writeContent = content
        case .upload, .download:
            transferPlan = try WindowsMCPFileTransferPlan(
                operation: operation,
                rootID: rootID,
                path: path,
                arguments: arguments
            )
        }

        return PreparedWindowsFileOperation(
            operation: operation,
            rootID: rootID,
            path: path,
            writeContentBase64: writeContentBase64,
            writeContent: writeContent,
            transferPlan: transferPlan
        )
    }

    private func performWindowsFileOperation(
        _ prepared: PreparedWindowsFileOperation,
        sessionID: UUID,
        arguments: [String: Any],
        operationToken: RDPAuthorizedOperationToken
    ) async throws -> [String: Any] {
        let operation = prepared.operation
        let rootID = prepared.rootID
        let path = prepared.path
        let deadline = integer(arguments["deadlineMs"])
        let expectedRevision = unsignedInteger(arguments["expectedStateRevision"])
        switch operation {
        case .list:
            try requireAuthorizedOperation(operationToken)
            let result = try await companionRequest(
                sessionID: sessionID,
                method: DVCOperation.filesList.rawValue,
                parameters: ["rootId": rootID, "relativePath": path],
                deadlineMilliseconds: deadline,
                idempotencyKey: arguments["idempotencyKey"] as? String,
                expectedStateRevision: expectedRevision
            )
            try requireAuthorizedOperation(operationToken)
            return result
        case .stat:
            try requireAuthorizedOperation(operationToken)
            let result = try await companionRequest(
                sessionID: sessionID,
                method: DVCOperation.filesStat.rawValue,
                parameters: [
                    "rootId": rootID,
                    "relativePath": path,
                    "includeSha256": true,
                ],
                deadlineMilliseconds: deadline,
                idempotencyKey: arguments["idempotencyKey"] as? String,
                expectedStateRevision: expectedRevision
            )
            try requireAuthorizedOperation(operationToken)
            return result
        case .read:
            try requireAuthorizedOperation(operationToken)
            let result = try await companionRequest(
                sessionID: sessionID,
                method: DVCOperation.filesRead.rawValue,
                parameters: ["rootId": rootID, "relativePath": path],
                deadlineMilliseconds: deadline,
                idempotencyKey: arguments["idempotencyKey"] as? String,
                expectedStateRevision: expectedRevision
            )
            try requireAuthorizedOperation(operationToken)
            return result
        case .write:
            guard let contentBase64 = prepared.writeContentBase64,
                  let content = prepared.writeContent else {
                throw WindowsMCPToolError(
                    code: .runtimeFailure,
                    message: "The validated Windows write plan is unavailable."
                )
            }
            try requireAuthorizedOperation(operationToken)
            let result = try await companionRequest(
                sessionID: sessionID,
                method: DVCOperation.filesWrite.rawValue,
                parameters: [
                    "rootId": rootID,
                    "relativePath": path,
                    "contentBase64": contentBase64,
                    "expectedSha256": sha256(content),
                    "overwrite": arguments["overwrite"] as? Bool ?? false,
                ],
                deadlineMilliseconds: deadline,
                idempotencyKey: arguments["idempotencyKey"] as? String,
                expectedStateRevision: expectedRevision
            )
            try requireAuthorizedOperation(operationToken)
            return result
        case .upload:
            guard let plan = prepared.transferPlan else {
                throw WindowsMCPToolError(
                    code: .runtimeFailure,
                    message: "The validated Windows upload plan is unavailable."
                )
            }
            let content = plan.content ?? Data()
            try Task.checkCancellation()
            try requireAuthorizedOperation(operationToken)
            let transfer = try await uploadCompanionBinary(
                sessionID: sessionID,
                data: content,
                purpose: "file-upload",
                deadlineMilliseconds: deadline,
                maximumBytes: WindowsMCPFileTransferPlan.maximumBytes
            )
            let result: [String: Any]
            do {
                try requireAuthorizedOperation(operationToken)
                result = try await companionRequest(
                    sessionID: sessionID,
                    method: DVCOperation.filesUpload.rawValue,
                    parameters: [
                        "rootId": plan.rootID,
                        "relativePath": plan.destinationPath ?? plan.sourcePath,
                        "transferId": transfer.transferID.uuidString.lowercased(),
                        "totalBytes": transfer.totalBytes,
                        "sha256": transfer.sha256,
                        "overwrite": plan.overwrite,
                    ],
                    deadlineMilliseconds: deadline,
                    idempotencyKey: arguments["idempotencyKey"] as? String,
                    expectedStateRevision: expectedRevision
                )
                try requireAuthorizedOperation(operationToken)
            } catch {
                await releaseCompanionBinary(
                    sessionID: sessionID,
                    transferID: transfer.transferID,
                    deadlineMilliseconds: deadline
                )
                throw error
            }
            await releaseCompanionBinary(
                sessionID: sessionID,
                transferID: transfer.transferID,
                deadlineMilliseconds: deadline
            )
            try requireAuthorizedOperation(operationToken)
            var structured = result
            structured["sourcePath"] = plan.sourcePath
            structured["destinationPath"] = plan.destinationPath ?? plan.sourcePath
            structured["bytesTransferred"] = transfer.totalBytes
            structured["sha256"] = transfer.sha256
            return structured

        case .download:
            guard let plan = prepared.transferPlan else {
                throw WindowsMCPToolError(
                    code: .runtimeFailure,
                    message: "The validated Windows download plan is unavailable."
                )
            }
            try Task.checkCancellation()
            try requireAuthorizedOperation(operationToken)
            let result = try await companionRequest(
                sessionID: sessionID,
                method: DVCOperation.filesDownload.rawValue,
                parameters: [
                    "rootId": plan.rootID,
                    "relativePath": plan.sourcePath,
                    "offset": plan.offset,
                    "length": plan.length,
                ],
                deadlineMilliseconds: deadline,
                idempotencyKey: nil,
                expectedStateRevision: expectedRevision
            )
            try requireAuthorizedOperation(operationToken)
            let descriptor: DVCBinaryTransferDescriptor
            do {
                descriptor = try binaryTransferDescriptor(
                    result,
                    purpose: "file-download",
                    sha256Field: "sha256",
                    minimumBytes: 0,
                    maximumBytes: WindowsMCPFileTransferPlan.maximumBytes,
                    invalidMessage: "Windows file download returned an invalid binary transfer descriptor."
                )
            } catch {
                await releaseReturnedCompanionBinaryIfPresent(
                    result,
                    sessionID: sessionID,
                    deadlineMilliseconds: deadline
                )
                throw error
            }
            try requireAuthorizedOperation(operationToken)
            let content = try await downloadCompanionBinary(
                sessionID: sessionID,
                descriptor: descriptor,
                deadlineMilliseconds: deadline,
                maximumBytes: WindowsMCPFileTransferPlan.maximumBytes
            )
            try requireAuthorizedOperation(operationToken)
            var structured = result
            structured["contentBase64"] = content.base64EncodedString()
            structured["bytesTransferred"] = descriptor.totalBytes
            structured["sha256"] = descriptor.sha256
            structured["sourcePath"] = plan.sourcePath
            if let destinationPath = plan.destinationPath {
                structured["destinationPath"] = destinationPath
            }
            return structured
        }
    }

    private func response(
        state: RDPDesktopSessionState,
        extra: [String: Any]
    ) -> WindowsMCPToolResponse {
        var structured = stateDictionary(state)
        extra.forEach { structured[$0.key] = $0.value }
        return WindowsMCPToolResponse(structuredContent: structured)
    }

    private func stateDictionary(_ state: RDPDesktopSessionState) -> [String: Any] {
        [
            "targetId": state.targetID.uuidString.lowercased(),
            "sessionId": state.sessionID.uuidString.lowercased(),
            "phase": state.phase.rawValue,
            "runtimeAvailability": state.runtimeAvailability.rawValue,
            "companion": [
                "availability": state.companion.availability.rawValue,
                "protocolVersion": optionalJSON(state.companion.protocolVersion),
                "version": optionalJSON(state.companion.companionVersion),
                "reason": optionalJSON(state.companion.reason),
            ],
            "stateRevision": state.stateRevision,
            "latestFrameId": optionalJSON(state.latestFrameID?.uuidString.lowercased()),
            "pixelWidth": optionalJSON(state.remotePixelWidth),
            "pixelHeight": optionalJSON(state.remotePixelHeight),
            "lastErrorCode": optionalJSON(state.lastErrorCode),
            "lastErrorMessage": optionalJSON(state.lastErrorMessage),
        ]
    }

    private func optionalJSON<Value>(_ value: Value?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private func normalizedTaskState(_ value: Any?, action: RemoteTaskAction) -> String {
        if let string = value as? String {
            return string.lowercased()
        }
        if let numeric = integer(value) {
            return [0: "queued", 1: "running", 2: "succeeded", 3: "failed", 4: "cancelled"][numeric]
                ?? "unknown"
        }
        switch action {
        case .doctor: return "ready"
        case .submit: return "queued"
        case .cancel: return "cancelled"
        case .collect: return "collected"
        case .status: return "unknown"
        }
    }

    private func binaryTransferDescriptor(
        _ result: [String: Any],
        purpose: String,
        sha256Field: String,
        minimumBytes: Int64,
        maximumBytes: Int64,
        invalidMessage: String
    ) throws -> DVCBinaryTransferDescriptor {
        guard let transferIDString = result["transferId"] as? String,
              let transferID = UUID(uuidString: transferIDString),
              let totalBytes = signedInteger(result["totalBytes"]),
              totalBytes >= minimumBytes,
              totalBytes <= maximumBytes,
              let sha256 = result[sha256Field] as? String,
              isASCIIHexSHA256(sha256),
              result["purpose"] == nil || result["purpose"] as? String == purpose else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: invalidMessage
            )
        }
        return DVCBinaryTransferDescriptor(
            transferID: transferID,
            purpose: purpose,
            totalBytes: totalBytes,
            sha256: sha256.lowercased()
        )
    }

    private func releaseReturnedCompanionBinaryIfPresent(
        _ result: [String: Any],
        sessionID: UUID,
        deadlineMilliseconds: Int?
    ) async {
        guard let transferIDString = result["transferId"] as? String,
              let transferID = UUID(uuidString: transferIDString) else {
            return
        }
        await releaseCompanionBinary(
            sessionID: sessionID,
            transferID: transferID,
            deadlineMilliseconds: deadlineMilliseconds
        )
    }

    private func isASCIIHexSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private func maximumBase64CharacterCount(
        forDecodedByteCount byteCount: Int64
    ) -> Int {
        guard byteCount > 0 else { return 0 }
        let encodedCount = ((byteCount + 2) / 3) * 4
        return encodedCount > Int64(Int.max) ? Int.max : Int(encodedCount)
    }

    private func requiredString(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WindowsMCPToolError(code: .invalidArgument, message: "Missing required argument: \(key).")
        }
        return value
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func unsignedInteger(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? String { return UInt64(value) }
        return nil
    }

    private func signedInteger(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? UInt64, value <= UInt64(Int64.max) { return Int64(value) }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

#endif
