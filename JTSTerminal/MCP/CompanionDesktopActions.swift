#if ENABLE_RDP_2
import Foundation
import JTSCompanionClient

@MainActor
extension CompanionDesktopRuntime {
    func performNativeAction(_ arguments: [String: Any], session: CompanionDesktopSession, clientID: String,
                             authorize: CompanionDevicesModel.MCPAuthorityCheck) async throws -> CompanionDesktopEnvelope {
        guard let revision = arguments["expectedStateRevision"] as? NSNumber,
              CFGetTypeID(revision) != CFBooleanGetTypeID(), revision.stringValue == String(session.revision) else {
            throw WindowsMCPToolError(code: .stateConflict, message: "Observe this desktop before acting and supply its stateRevision.")
        }
        if arguments["action"] as? String != "fillCredential" {
            let parsed = try WindowsMCPDesktopActionRequestParser.parse(arguments)
            if parsed.action.requiresSelector {
                return try await performSemanticAction(parsed, arguments: arguments, session: session, clientID: clientID, authorize: authorize)
            }
        }
        guard let observed = session.observations[clientID] else {
            throw WindowsMCPToolError(code: .stateConflict, message: "Read this desktop before raw input or credential fill.")
        }
        try observed.requireFresh(generation: session.generation, sessionID: session.windowsSessionID)
        if arguments["action"] as? String == "fillCredential" {
            return try await fillCredential(arguments, session: session, observed: observed, authorize: authorize)
        }
        let parsed = try WindowsMCPDesktopActionRequestParser.parse(arguments)
        if let frame = parsed.expectedFrameID, frame != observed.frameID {
            throw WindowsMCPToolError(code: .stateConflict, message: "The supplied frame belongs to another observation.")
        }
        var body: [String: DesktopJSONValue] = ["observationID": .string(observed.observationID.uuidString.lowercased())]
        if let point = parsed.point {
            guard (0..<observed.width).contains(point.x), (0..<observed.height).contains(point.y) else {
                throw WindowsMCPToolError(code: .invalidArgument, message: "Coordinates are outside the observed framebuffer.")
            }
            body["x"] = .integer(Int64(point.x)); body["y"] = .integer(Int64(point.y))
        }
        body["button"] = .string(parsed.mouseButton?.rawValue ?? "left")
        switch parsed.action {
        case .movePointer: body["kind"] = .string("pointerMove")
        case .click: body["kind"] = .string("click")
        case .doubleClick: body["kind"] = .string("doubleClick")
        case .mouseDown, .mouseUp:
            body["kind"] = .string("pointerButton"); body["pressed"] = .bool(parsed.action == .mouseDown)
        case .scroll: body["kind"] = .string("scroll"); body["delta"] = .integer(Int64(parsed.scrollDeltaY ?? 0))
        case .keyDown, .keyUp:
            guard let key = parsed.key, let vk = CompanionDesktopKeyMap.virtualKey(key) else { throw failure("DESKTOP_KEY_UNSUPPORTED") }
            body["kind"] = .string("key"); body["virtualKey"] = .integer(Int64(vk)); body["pressed"] = .bool(parsed.action == .keyDown)
        case .keyChord:
            let keys = parsed.keyChord ?? []
            let codes = keys.compactMap(CompanionDesktopKeyMap.virtualKey)
            guard codes.count == keys.count else { throw failure("DESKTOP_KEY_UNSUPPORTED") }
            if Set(codes) == Set([0x11, 0x12, 0x2E]), codes.count == 3 {
                body["kind"] = .string("secureAttention")
            } else {
                body["kind"] = .string("keyChord"); body["virtualKeys"] = .array(codes.map { .integer(Int64($0)) })
            }
        case .typeText:
            body["kind"] = .string("text"); body["text"] = .string(parsed.text ?? "")
        case .semanticInvoke, .semanticSetValue, .semanticSelect, .wait:
            throw CompanionDesktopError.invalidRequest
        }
        try authorize()
        // Remove local authority before sending, including failed or uncertain replies.
        session.observations[clientID] = nil
        return try await request("action", session: session, body: body)
    }

    private func performSemanticAction(_ parsed: DesktopActionRequest, arguments: [String: Any],
                                       session: CompanionDesktopSession, clientID: String,
                                       authorize: CompanionDevicesModel.MCPAuthorityCheck) async throws -> CompanionDesktopEnvelope {
        guard let selector = parsed.selector, let recorded = session.uiaObservations[clientID],
              recorded.generation == session.generation, recorded.expiresAt > Date(),
              arguments["expectedUiaObservationId"] as? String == recorded.id else {
            throw WindowsMCPToolError(code: .stateConflict, message: "Read UIA controls before a semantic action and use this caller's fresh observation.")
        }
        let method = parsed.action == .semanticInvoke ? "invoke" : parsed.action == .semanticSelect ? "select" : parsed.action == .wait ? "find" : "setValue"
        var body: [String: DesktopJSONValue] = ["method": .string(method), "observationID": .string(recorded.id),
            "selector": try Self.jsonValue(JSONSerialization.jsonObject(with: Data(selector.utf8)))]
        if let text = parsed.text { body["value"] = .string(text) }
        try authorize()
        session.uiaObservations[clientID] = nil
        return try await request("user.uia", session: session, body: body)
    }

    private func fillCredential(_ arguments: [String: Any], session: CompanionDesktopSession,
                                observed: CompanionDesktopObservation,
                                authorize: CompanionDevicesModel.MCPAuthorityCheck) async throws -> CompanionDesktopEnvelope {
        let allowed: Set<String> = ["targetId", "sessionId", "action", "expectedStateRevision", "expectedFrameId", "credentialRef", "purpose",
            "deadlineMs", "_jtsClientID", "_jtsClientDisplayIdentity", "_jtsDeadlineUptimeMilliseconds"]
        guard Set(arguments.keys).isSubset(of: allowed), let purpose = arguments["purpose"] as? String,
              ["login", "elevation"].contains(purpose), let reference = arguments["credentialRef"] as? String,
              reference == RDPPasswordStore.account(targetID: session.target.targetID),
              let frame = arguments["expectedFrameId"] as? String, UUID(uuidString: frame) == observed.frameID else {
            throw WindowsMCPToolError(code: .invalidArgument, message: "fillCredential requires a target-bound credentialRef, login/elevation purpose and observed frame; raw passwords are not accepted.")
        }
        let requiredDesktop = purpose == "login" ? "winlogon" : "secure"
        guard session.remoteState["desktop"]?.stringValue == requiredDesktop else { throw failure("CREDENTIAL_DESKTOP_MISMATCH") }
        guard let password = try await RDPPasswordAccess.shared.readPassword(targetID: session.target.targetID), !password.isEmpty else {
            throw failure("CREDENTIAL_NOT_STORED")
        }
        try authorize()
        try observed.requireFresh(generation: session.generation, sessionID: session.windowsSessionID)
        session.observations[arguments["_jtsClientID"] as? String ?? ""] = nil
        return try await request("fillCredential", session: session, body: ["purpose": .string(purpose),
            "credentialRef": .string(reference), "observationID": .string(observed.observationID.uuidString.lowercased()),
            "secretBase64": .string(Data(password.utf8).base64EncodedString())])
    }

    static func userOperationBody(tool: WindowsMCPToolName, arguments: [String: Any]) throws -> [String: DesktopJSONValue] {
        if tool == .desktopUIA {
            let query = try WindowsUIAQuery(arguments)
            var parameters = query.parameters; parameters["method"] = query.operation.rawValue
            guard case .object(let body) = try jsonValue(parameters) else { throw CompanionDesktopError.invalidRequest }
            return body
        }
        if tool == .windowsFiles {
            guard let raw = arguments["operation"] as? String, let operation = RemoteFileOperation(rawValue: raw),
                  [.list, .stat, .read, .write].contains(operation), let path = arguments["path"] as? String,
                  !path.contains("\0"), path.utf16.count <= 32768 else { throw CompanionDesktopError.invalidRequest }
            var parameters: [String: Any] = ["method": raw, "rootId": arguments["rootId"] as? String ?? "shared", "relativePath": path]
            if operation == .write {
                guard let encoded = arguments["contentBase64"] as? String,
                      encoded.utf8.count <= ((512 * 1024 + 2) / 3) * 4,
                      let data = Data(base64Encoded: encoded), data.count <= 512 * 1024 else {
                    throw WindowsMCPToolError(code: .invalidArgument, message: "Windows writes require valid contentBase64 within the existing inline file limit.")
                }
            }
            for key in ["contentBase64", "offset", "length", "overwrite"] {
                if let value = arguments[key] { parameters[key] = value }
            }
            guard case .object(let body) = try jsonValue(parameters) else { throw CompanionDesktopError.invalidRequest }
            return body
        }
        if tool == .windowsExec {
            var currentUserArguments = arguments
            if currentUserArguments["rootId"] == nil { currentUserArguments["rootId"] = "shared" }
            let plan = try WindowsPowerShellExecutionPlan(arguments: currentUserArguments)
            guard !plan.requiresElevation else { throw WindowsMCPToolError(code: .runtimeFailure,
                message: "Elevated current-user commands require a verified native elevation lease.", details: ["desktopCode": "DESKTOP_ELEVATION_LEASE_UNAVAILABLE"]) }
            guard case .object(let body) = try jsonValue(plan.currentUserParameters) else { throw CompanionDesktopError.invalidRequest }
            return body
        }
        let allowed: Set<String> = tool == .desktopUIA ? ["operation", "selector", "maximumDepth", "maximumNodes", "observationId", "deadlineMs"]
            : tool == .windowsFiles ? ["operation", "rootId", "path", "encoding", "content", "maxBytes", "recursive", "overwrite", "deadlineMs"]
            : ["action", "jobId", "bundleBase64", "deadlineMs", "idempotencyKey"]
        let omitted: Set<String> = ["targetId", "sessionId", "expectedStateRevision", "_jtsClientID", "_jtsClientDisplayIdentity", "_jtsDeadlineUptimeMilliseconds"]
        guard Set(arguments.keys).subtracting(omitted).isSubset(of: allowed) else { throw CompanionDesktopError.invalidRequest }
        let input = arguments.filter { allowed.contains($0.key) }
        guard case .object(let body) = try jsonValue(input) else { throw CompanionDesktopError.invalidRequest }
        return body
    }
    static func jsonValue(_ object: Any) throws -> DesktopJSONValue {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        guard bytes.count <= CompanionDesktopWire.maximumBytes - 8192 else { throw CompanionDesktopError.invalidRequest }
        return try JSONDecoder().decode(DesktopJSONValue.self, from: bytes)
    }
}

nonisolated enum CompanionDesktopKeyMap {
    static func virtualKey(_ key: String) -> Int? {
        let name = key.uppercased()
        let names = ["CTRL": 0x11, "CONTROL": 0x11, "SHIFT": 0x10, "ALT": 0x12, "WIN": 0x5B,
            "META": 0x5B, "ENTER": 0x0D, "RETURN": 0x0D, "TAB": 0x09, "ESC": 0x1B, "ESCAPE": 0x1B,
            "BACKSPACE": 0x08, "DELETE": 0x2E, "SPACE": 0x20, "LEFT": 0x25, "UP": 0x26,
            "RIGHT": 0x27, "DOWN": 0x28, "HOME": 0x24, "END": 0x23, "PAGEUP": 0x21, "PAGEDOWN": 0x22]
        if let value = names[name] { return value }
        if name.count == 1, let scalar = name.unicodeScalars.first, (48...90).contains(scalar.value) { return Int(scalar.value) }
        if name.hasPrefix("F"), let number = Int(name.dropFirst()), (1...12).contains(number) { return 0x6F + number }
        return nil
    }
}
#endif
