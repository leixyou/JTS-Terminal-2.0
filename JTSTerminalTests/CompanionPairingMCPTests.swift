#if ENABLE_RDP_2
import Foundation
import SwiftData
import Testing
@testable import JTSTerminal

@MainActor
struct CompanionPairingMCPTests {
    private func arguments(action: String = "status") -> [String: Any] {
        ["targetId": UUID().uuidString, "sessionId": UUID().uuidString, "action": action]
    }

    @Test func parserRejectsCallerChosenAuthorityAndAmbiguousDeadlines() throws {
        for action in WindowsMCPCompanionPairingRequest.Action.allCases {
            let request = try WindowsMCPCompanionPairingRequest(arguments(action: action.rawValue))
            #expect(request.action == action)
            #expect(request.deadlineMilliseconds == 30_000)
        }
        for key in ["grantId", "authorizationSource", "approved", "macFingerprint",
                    "windowsFingerprint", "enrollmentRequestBase64", "idempotencyKey", "text"] {
            var input = arguments(); input[key] = "caller-selected"
            #expect(throws: WindowsMCPToolError.self) { _ = try WindowsMCPCompanionPairingRequest(input) }
        }
        for value: Any in [true, false, "1000", 100.5, 99, 120_001, NSNull(), Double.infinity] {
            var input = arguments(); input["deadlineMs"] = value
            #expect(throws: WindowsMCPToolError.self) { _ = try WindowsMCPCompanionPairingRequest(input) }
        }
        for value in [100, 120_000] {
            var input = arguments(); input["deadlineMs"] = value
            #expect(try WindowsMCPCompanionPairingRequest(input).deadlineMilliseconds == value)
        }
        for key in ["targetId", "sessionId", "action"] {
            var input = arguments(); input.removeValue(forKey: key)
            #expect(throws: WindowsMCPToolError.self) { _ = try WindowsMCPCompanionPairingRequest(input) }
            input[key] = "invalid"
            #expect(throws: WindowsMCPToolError.self) { _ = try WindowsMCPCompanionPairingRequest(input) }
        }
    }

    @Test func registrySupportsPrepairingAndAdvertisesOnlyScopedManagement() throws {
        #expect(!WindowsMCPToolName.companionPairing.requiresCompanion)
        let definition = try #require(WindowsMCPToolRegistry.definitions.first {
            $0["name"] as? String == "jts_companion_pairing"
        })
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["targetId", "sessionId", "action", "deadlineMs"])
        #expect(Set(try #require(schema["required"] as? [String])) == ["targetId", "sessionId", "action"])
        #expect(schema["additionalProperties"] as? Bool == false)
        let action = try #require(properties["action"] as? [String: Any])
        #expect(Set(try #require(action["enum"] as? [String])) == ["status", "confirm", "revoke"])
        let deadline = try #require(properties["deadlineMs"] as? [String: Any])
        #expect(deadline["minimum"] as? Int == 100)
        #expect(deadline["maximum"] as? Int == 120_000)
    }

    @Test func resultsBindDeviceSessionAndActionWithoutClaimingReady() throws {
        let input = arguments(action: "confirm")
        let valid: [String: Any] = ["ok": true, "targetId": input["targetId"]!,
            "sessionId": input["sessionId"]!, "action": "confirm", "state": "enrollmentRequired",
            "ready": false, "authorizationSource": "device-ai-control"]
        _ = try WindowsMCPToolResponse(structuredContent: valid)
            .validated(for: .companionPairing, arguments: input)
        for (key, value): (String, Any) in [
            ("targetId", UUID().uuidString), ("sessionId", UUID().uuidString),
            ("action", "revoke"), ("ok", false), ("state", ""), ("state", NSNull()),
        ] {
            var result = valid; result[key] = value
            #expect(throws: WindowsMCPToolError.self) {
                _ = try WindowsMCPToolResponse(structuredContent: result)
                    .validated(for: .companionPairing, arguments: input)
            }
        }
    }

    @Test func everyActionRequiresTheExistingDesktopControlGrantAndAuditsItsAction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-pairing-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl])
        let target = RemoteSession(name: "Windows", host: "pairing.test",
            username: "operator", connectionType: .rdp)
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let grants = RemoteClientGrantStore(storageURL: directory.appendingPathComponent("grants.json"))
        let audit = RemoteCapabilityAuditStore(storageURL: directory.appendingPathComponent("audit.json"))
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw WindowsMCPToolError(code: .runtimeFailure, message: "Pairing must never open a desktop.")
        }, grantStoreForTesting: grants, auditStoreForTesting: audit)
        defer { runtime.stopAllImmediately() }
        let sessionID = runtime.installActiveDesktopForTesting(target: target)
        for action in WindowsMCPCompanionPairingRequest.Action.allCases {
            let clientID = "pairing-test-\(action.rawValue)"
            do {
                _ = try await runtime.handleMCP(tool: .companionPairing, target: target, arguments: [
                    "targetId": target.targetID.uuidString, "sessionId": sessionID.uuidString,
                    "action": action.rawValue, "_jtsClientID": clientID,
                ])
                Issue.record("An ungranted client must not manage device pairing.")
            } catch let error as WindowsMCPToolError {
                #expect(error.code == .permissionDenied)
                #expect(error.details["authorizationCode"] as? String == "GRANT_APPROVAL_REQUIRED")
            }
            let pending = try #require(grants.pendingRequests(targetID: target.targetID)
                .first { $0.clientID == clientID })
            #expect(pending.requestedCapabilities == [.desktopControl])
            #expect(pending.externalDataTypes.isEmpty)
            let record = try #require(audit.records(targetID: target.targetID)
                .first { $0.clientID == clientID })
            #expect(record.actionType == "jts_companion_pairing.\(action.rawValue)")
            #expect(record.result == .denied)
            #expect(record.capabilityNames == [RemoteCapability.desktopControl.rawValue])
        }
    }

    @Test func jsonRPCRequiresRegisteredClientAndExactSessionBeforePrepairingDispatch() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let target = RemoteSession(name: "Windows", host: "pairing.test",
            username: "operator", connectionType: .rdp)
        target.mcpEnabled = true
        context.insert(target)
        try context.save()
        let registration = MCPClientRegistrationRecord(
            registrationID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            configurationKey: "/tmp/jts-pairing-mcp-test.json", clientLabel: "Pairing Tests", createdAt: Date())
        var invocations = 0
        let dispatcher = WindowsMCPToolDispatcher(availability: WindowsMCPRuntimeAvailability(
            desktopRuntimeAvailable: true, companionAvailable: false, reason: "Pairing required")) { tool, routedTarget, input in
            #expect(tool == .companionPairing)
            #expect(routedTarget.targetID == target.targetID)
            #expect(input["_jtsClientID"] as? String == registration.authorizationClientID)
            invocations += 1
            return WindowsMCPToolResponse(structuredContent: ["ok": true,
                "targetId": routedTarget.targetID.uuidString, "sessionId": input["sessionId"]!,
                "action": input["action"]!, "state": "enrollmentRequired", "ready": false])
        }
        func request(_ input: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
                "method": "tools/call", "params": ["name": "jts_companion_pairing", "arguments": input]]), as: UTF8.self)
        }
        let server = MCPStdioServer(modelContext: context, windowsDispatcher: dispatcher,
            clientRegistration: registration)
        var input: [String: Any] = ["targetId": target.targetID.uuidString,
            "sessionId": UUID().uuidString, "action": "status"]
        let validLine = try #require(await server.handleLine(request(input)))
        let valid = try #require(JSONSerialization.jsonObject(with: Data(validLine.utf8)) as? [String: Any])
        let result = try #require(valid["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(invocations == 1)

        for key in ["sessionId", "action"] {
            var invalid = input; invalid.removeValue(forKey: key)
            let line = try #require(await server.handleLine(request(invalid)))
            let response = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let result = try #require(response["result"] as? [String: Any])
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["code"] as? String == "INVALID_ARGUMENT")
        }
        input["approved"] = true
        _ = try #require(await server.handleLine(request(input)))
        #expect(invocations == 1)

        input.removeValue(forKey: "approved")
        let unregistered = MCPStdioServer(modelContext: context, windowsDispatcher: dispatcher)
        let line = try #require(await unregistered.handleLine(request(input)))
        #expect(line.contains("CLIENT_REGISTRATION_REQUIRED"))
        #expect(invocations == 1)
    }

    @Test func connectionRevocationPreservesPairingManagementButFullRevocationStopsIt() async throws {
        for fullRevocation in [false, true] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("jts-pairing-transition-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = RemoteSession(name: "Windows", host: "pairing.test",
                username: "operator", connectionType: .rdp)
            target.mcpEnabled = true
            try target.setRDPProfile(RDPConnectionProfile(clipboardEnabled: true,
                permissionPolicy: RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl],
                    controlLeaseCapabilities: [], requireExternalDataConsent: false)))
            let grants = RemoteClientGrantStore(storageURL: directory.appendingPathComponent("grants.json"))
            var runtime: RDPDesktopRuntimeStore?
            var isolationCount = 0
            runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
                throw WindowsMCPToolError(code: .runtimeFailure, message: "No connection expected.")
            }, grantStoreForTesting: grants, clipboardIsolationBarrierForTesting: { _, isolated, _ in
                guard isolated else { return }
                isolationCount += 1
                if fullRevocation {
                    runtime?.revokeAuthorizedOperations(targetID: target.targetID)
                } else {
                    runtime?.revokeConnectionBoundAuthorizedOperations(targetID: target.targetID)
                }
            })
            let store = try #require(runtime)
            defer { store.stopAllImmediately(); runtime = nil }
            store.installActiveDesktopForTesting(target: target)
            do {
                // An obsolete session is deliberate: after the connection
                // generation changes, management must still reach the exact
                // session check without acquiring any remote authority.
                _ = try await store.handleMCP(tool: .companionPairing, target: target, arguments: [
                    "targetId": target.targetID.uuidString, "sessionId": UUID().uuidString,
                    "action": "revoke", "_jtsClientID": "mcp-registration:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                ])
                Issue.record("Management must still reject an obsolete desktop session.")
            } catch let error as WindowsMCPToolError {
                #expect(error.code == (fullRevocation ? .permissionDenied : .stateConflict))
                if fullRevocation {
                    #expect(error.details["authorizationCode"] as? String == "AUTHORITY_REVOKED_DURING_OPERATION")
                }
            }
            #expect(isolationCount == 1)
            #expect(grants.pendingRequests(targetID: target.targetID).isEmpty)
        }
    }
}
#endif
