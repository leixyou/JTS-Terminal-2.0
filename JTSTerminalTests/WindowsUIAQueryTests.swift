#if ENABLE_RDP_2
import Foundation
import SwiftData
import Testing
@testable import JTSTerminal

@MainActor
struct WindowsUIAQueryTests {
    private func node(children: [[String: Any]] = []) -> [String: Any] {
        ["runtimeId": "1.2", "automationId": "editor", "name": "Document", "controlType": "Edit",
         "processId": 42, "isEnabled": true, "isOffscreen": false,
         "bounds": ["x": -10, "y": 20, "width": 100, "height": 40], "children": children]
    }

    @Test func rejectsAmbiguousLimitsAndMutationFields() throws {
        for value: Any in [true, 1.5, "2", 0, -1, 1_001, NSNull(), Double.infinity] {
            #expect(throws: WindowsMCPToolError.self) {
                _ = try WindowsUIAQuery(["operation": "snapshot", "maximumNodes": value])
            }
        }
        for arguments: [String: Any] in [
            ["operation": "snapshot", "selector": "{}"],
            ["operation": "find", "selector": "{}"],
            ["operation": "find", "selector": "{\"processId\":-1}"],
            ["operation": "find", "selector": "{\"processId\":true}"],
            ["operation": "find", "selector": "{\"processId\":1.5}"],
            ["operation": "find", "selector": "{\"processId\":2147483648}"],
            ["operation": "find", "selector": "{\"runtimeId\":\"1.2\"}"],
            ["operation": "snapshot", "idempotencyKey": "unused"],
            ["operation": "find", "selector": "{\"name\":\"Editor\"}", "text": "mutation"],
        ] {
            #expect(throws: WindowsMCPToolError.self) { _ = try WindowsUIAQuery(arguments) }
        }
        let query = try WindowsUIAQuery(["operation": "find", "selector": "{\"processId\":42}"])
        #expect(query.method == "uia.find")
        #expect((query.parameters["selector"] as? [String: Any])?["processId"] as? Int == 42)
    }

    @Test func readSchemaAdvertisesSupportedParametersAndMatchesLimits() throws {
        let definition = try #require(WindowsMCPToolRegistry.definitions.first {
            $0["name"] as? String == WindowsMCPToolName.desktopUIA.rawValue
        })
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["targetId", "sessionId", "expectedStateRevision", "deadlineMs",
            "operation", "maximumDepth", "maximumNodes", "maximumResults", "selector"])
        #expect(Set(try #require(schema["required"] as? [String])) == ["targetId", "sessionId", "operation"])
        #expect(schema["additionalProperties"] as? Bool == false)

        for (key, operation, bounds) in [
            ("maximumDepth", "snapshot", 1...10),
            ("maximumNodes", "snapshot", 1...1_000),
            ("maximumResults", "find", 1...500),
            ("deadlineMs", "snapshot", 100...30_000),
        ] {
            let field = try #require(properties[key] as? [String: Any])
            #expect(field["minimum"] as? Int == bounds.lowerBound)
            #expect(field["maximum"] as? Int == bounds.upperBound)
            var arguments: [String: Any] = ["operation": operation]
            if operation == "find" { arguments["selector"] = "{\"processId\":42}" }
            for value in [bounds.lowerBound, bounds.upperBound] {
                arguments[key] = value
                _ = try WindowsUIAQuery(arguments)
            }
            for value in [bounds.lowerBound - 1, bounds.upperBound + 1] {
                arguments[key] = value
                #expect(throws: WindowsMCPToolError.self) { _ = try WindowsUIAQuery(arguments) }
            }
        }
        for value: Any in [true, -1, 1.5, "3", NSNull()] {
            #expect(throws: WindowsMCPToolError.self) {
                _ = try WindowsUIAQuery(["operation": "snapshot", "expectedStateRevision": value])
            }
        }
        _ = try WindowsUIAQuery(["operation": "snapshot", "expectedStateRevision": UInt64.max])
    }

    @Test func rejectsOversizedTreesMalformedNodesAndFalseCompleteness() throws {
        let query = try WindowsUIAQuery(["operation": "snapshot", "maximumNodes": 2, "maximumDepth": 1])
        let valid: [String: Any] = ["root": node(children: [node()]), "nodeCount": 2, "truncated": false]
        #expect(try query.validatedResult(valid)["nodeCount"] as? Int == 2)
        for bad: [String: Any] in [
            ["root": node(children: [node(), node()]), "nodeCount": 3, "truncated": false],
            ["root": node(children: [node(children: [node()])]), "nodeCount": 3, "truncated": true],
            ["root": node(), "nodeCount": true, "truncated": false],
            ["root": node(), "nodeCount": 2, "truncated": false],
            ["root": node(), "nodeCount": 1, "truncated": 0],
        ] {
            #expect(throws: WindowsMCPToolError.self) { _ = try query.validatedResult(bad) }
        }
        var malformed = node(); malformed["processId"] = true
        #expect(throws: WindowsMCPToolError.self) {
            _ = try query.validatedResult(["root": malformed, "nodeCount": 1, "truncated": false])
        }
        let find = try WindowsUIAQuery(["operation": "find", "selector": "{\"name\":\"Document\"}", "maximumResults": 1])
        #expect(try find.validatedResult(["value": [node()]])["mayHaveMore"] as? Bool == true)
        #expect(try find.validatedResult(["value": []])["mayHaveMore"] as? Bool == false)
        #expect(throws: WindowsMCPToolError.self) { _ = try find.validatedResult(["value": [node(children: [node()])]]) }
    }

    @Test func observationContextRejectsOtherCallersTakeoverReconnectAndExpiry() throws {
        var ledger = RDPUIAObservationLedger()
        let session = UUID()
        let token = RDPAuthorizedOperationToken(operationID: UUID(), targetID: UUID(), targetBinding: "binding",
            clientID: "codex", generation: 4, connectionGeneration: 8, showsControlActivity: false,
            showsViewingActivity: true, survivesConnectionTransition: false)
        let id = ledger.record(token: token, sessionID: session, now: 100)
        var nextOperation = token; nextOperation.operationID = UUID(); nextOperation.showsControlActivity = true
        try ledger.validate(id, token: nextOperation, sessionID: session, now: 159)
        var otherClient = token; otherClient.clientID = "other"
        var takeover = token; takeover.generation += 1
        var reconnect = token; reconnect.connectionGeneration += 1
        var changedTarget = token; changedTarget.targetBinding = "new-binding"
        for changed in [otherClient, takeover, reconnect, changedTarget] {
            #expect(throws: WindowsMCPToolError.self) { try ledger.validate(id, token: changed, sessionID: session, now: 101) }
        }
        #expect(throws: WindowsMCPToolError.self) { try ledger.validate(id, token: token, sessionID: UUID(), now: 101) }
        #expect(throws: WindowsMCPToolError.self) { try ledger.validate(id, token: token, sessionID: session, now: 160) }
        for index in 1...RDPUIAObservationLedger.capacity { _ = ledger.record(token: token, sessionID: session, now: 100 + Double(index) / 100) }
        #expect(throws: WindowsMCPToolError.self) { try ledger.validate(id, token: token, sessionID: session, now: 102) }
    }

    @Test func acceptsCompanionOmittedNullPropertiesButRejectsMissingRequiredFields() throws {
        let query = try WindowsUIAQuery(["operation": "snapshot"])
        var element = node()
        element.removeValue(forKey: "automationId")
        element.removeValue(forKey: "name")
        _ = try query.validatedResult(["root": element, "nodeCount": 1, "truncated": false])
        element["name"] = NSNull()
        _ = try query.validatedResult(["root": element, "nodeCount": 1, "truncated": false])
        element.removeValue(forKey: "runtimeId")
        #expect(throws: WindowsMCPToolError.self) {
            _ = try query.validatedResult(["root": element, "nodeCount": 1, "truncated": false])
        }
    }

    @Test func acceptsNativeCompanionWireShapeAndRejectsInvalidIdentityOrBounds() throws {
        // The Windows serializer writes camelCase, omits nullable strings, and
        // encodes RuntimeId as a string. Find results are wrapped by CompanionClient.
        let wire = Data("""
        {"root":{"runtimeId":"42.123.7","controlType":"Pane","processId":0,
        "isEnabled":true,"isOffscreen":false,"bounds":{"x":-1920.5,"y":0,"width":0,"height":0},
        "children":[]},"truncated":false,"nodeCount":1}
        """.utf8)
        let snapshot = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let query = try WindowsUIAQuery(["operation": "snapshot"])
        _ = try query.validatedResult(snapshot)
        let element = try #require(snapshot["root"] as? [String: Any])
        let find = try WindowsUIAQuery(["operation": "find", "selector": "{\"controlType\":\"Pane\"}"])
        _ = try find.validatedResult(["value": [element]])

        for (key, value): (String, Any) in [
            ("runtimeId", [42, 123, 7]), ("runtimeId", NSNull()),
            ("automationId", 42), ("name", String(repeating: "x", count: 4_097)),
            ("bounds", ["x": true, "y": 0, "width": 1, "height": 1]),
            ("bounds", ["x": 0, "y": 0, "width": -1, "height": 1]),
            ("bounds", ["x": 0, "y": 0, "width": 1]),
            ("bounds", ["x": 0, "y": 0, "width": 1, "height": 1, "scale": 2]),
            ("children", NSNull()), ("unexpected", "not in the DTO"),
        ] {
            var malformed = element; malformed[key] = value
            #expect(throws: WindowsMCPToolError.self) {
                _ = try query.validatedResult(["root": malformed, "nodeCount": 1, "truncated": false])
            }
        }
    }

    @Test func semanticContextCannotBeUsedForRawInput() throws {
        let id = UUID().uuidString
        #expect(throws: WindowsMCPToolError.self) {
            _ = try WindowsMCPDesktopActionRequestParser.parse(["action": "typeText", "text": "hello",
                "expectedStateRevision": 1, "expectedUiaObservationId": id])
        }
        _ = try WindowsMCPDesktopActionRequestParser.parse(["action": "semanticInvoke",
            "selector": "{\"processId\":42,\"automationId\":\"save\"}",
            "expectedStateRevision": 1, "expectedUiaObservationId": id])
        for selector in ["{\"name\":\"Save\"}", "{\"processId\":42}",
                         "{\"processId\":true,\"automationId\":\"save\"}"] {
            #expect(throws: WindowsMCPToolError.self) {
                _ = try WindowsMCPDesktopActionRequestParser.parse(["action": "semanticInvoke",
                    "selector": selector, "expectedStateRevision": 1, "expectedUiaObservationId": id])
            }
        }
    }

    @Test func observedSemanticActionsToleratePaintsWithoutChangingSelectorOrRawValidation() throws {
        var ledger = RDPUIAObservationLedger()
        let session = UUID()
        let token = RDPAuthorizedOperationToken(operationID: UUID(), targetID: UUID(), targetBinding: "binding",
            clientID: "codex", generation: 4, connectionGeneration: 8, showsControlActivity: true,
            showsViewingActivity: false, survivesConnectionTransition: false)
        let observation = ledger.record(token: token, sessionID: session, now: 100)
        let frame = DesktopFrameMetadata(sessionID: session, stateRevision: 236,
            pixelWidth: 1_920, pixelHeight: 1_080)
        let selector = #"{"processId":42,"automationId":"editor"}"#
        for action: DesktopActionKind in [.semanticInvoke, .semanticSetValue, .semanticSelect, .wait] {
            let request = DesktopActionRequest(action: action, expectedStateRevision: 232,
                selector: selector, text: action == .semanticSetValue ? "value" : nil)
            #expect(throws: DesktopActionValidationError.staleState(expected: 232, current: 236)) {
                try request.validate(against: frame)
            }
            let rebound = try ledger.rebindSemanticAction(request, observationID: observation,
                token: token, sessionID: session, latestFrame: frame, now: 101)
            try rebound.validate(against: frame)
            #expect(rebound.expectedStateRevision == 236)
            #expect(rebound.selector == selector)
            #expect(rebound.text == request.text)
        }
        for action: DesktopActionKind in [.click, .typeText, .keyChord] {
            let request = DesktopActionRequest(action: action, expectedStateRevision: 232,
                expectedFrameID: frame.frameID, point: DesktopPoint(x: 1, y: 1))
            #expect(throws: WindowsMCPToolError.self) {
                try ledger.rebindSemanticAction(request, observationID: observation,
                    token: token, sessionID: session, latestFrame: frame, now: 101)
            }
            #expect(throws: DesktopActionValidationError.staleState(expected: 232, current: 236)) {
                try request.validate(against: frame)
            }
        }
    }

    @Test func observedSemanticRebindingRejectsExpiredOrChangedContext() throws {
        var ledger = RDPUIAObservationLedger()
        let session = UUID()
        let token = RDPAuthorizedOperationToken(operationID: UUID(), targetID: UUID(), targetBinding: "binding",
            clientID: "codex", generation: 4, connectionGeneration: 8, showsControlActivity: true,
            showsViewingActivity: false, survivesConnectionTransition: false)
        let observation = ledger.record(token: token, sessionID: session, now: 100)
        let frame = DesktopFrameMetadata(sessionID: session, stateRevision: 236,
            pixelWidth: 1_920, pixelHeight: 1_080)
        let request = DesktopActionRequest(action: .semanticSetValue, expectedStateRevision: 232,
            selector: #"{"processId":42,"automationId":"editor"}"#, text: "value")
        var otherClient = token; otherClient.clientID = "other"
        var takeover = token; takeover.generation += 1
        var reconnect = token; reconnect.connectionGeneration += 1
        var changedTarget = token; changedTarget.targetBinding = "other-binding"
        for changed in [otherClient, takeover, reconnect, changedTarget] {
            #expect(throws: WindowsMCPToolError.self) {
                try ledger.rebindSemanticAction(request, observationID: observation,
                    token: changed, sessionID: session, latestFrame: frame, now: 101)
            }
        }
        for (id, requestedSession, now) in [(UUID(), session, 101.0),
                                           (observation, UUID(), 101.0),
                                           (observation, session, 160.0)] {
            #expect(throws: WindowsMCPToolError.self) {
                try ledger.rebindSemanticAction(request, observationID: id,
                    token: token, sessionID: requestedSession, latestFrame: frame, now: now)
            }
        }
        var otherFrame = frame; otherFrame.sessionID = UUID()
        #expect(throws: WindowsMCPToolError.self) {
            try ledger.rebindSemanticAction(request, observationID: observation,
                token: token, sessionID: session, latestFrame: otherFrame, now: 101)
        }
    }

    @Test func runtimeSemanticRebindingStillRequiresCurrentAuthorityAndCompanion() async throws {
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw WindowsMCPToolError(code: .runtimeFailure, message: "No connection expected.")
        })
        defer { runtime.stopAllImmediately() }
        let target = RemoteSession(name: "Windows", host: "uia.test", username: "operator", connectionType: .rdp)
        var profile = target.rdpProfile; profile.clipboardEnabled = false
        try target.setRDPProfile(profile)
        let session = runtime.installActiveDesktopForTesting(target: target)
        let observedFrame = try #require(runtime.installDesktopFrameForTesting(sessionID: session, runtimeStateRevision: 232))
        let token = try runtime.beginAuthorizedOperation(targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding, clientID: "codex", displayIdentity: "codex",
            capabilities: [.desktopControl])
        let observation = runtime.uiaObservations.record(token: token, sessionID: session)
        _ = try #require(runtime.installDesktopFrameForTesting(sessionID: session, runtimeStateRevision: 236))
        let request = DesktopActionRequest(action: .semanticSetValue,
            expectedStateRevision: observedFrame.stateRevision,
            selector: #"{"processId":42,"automationId":"editor"}"#, text: "value")
        do {
            _ = try await runtime.performDesktopAction(sessionID: session, request: request)
            Issue.record("An unobserved stale semantic action must remain rejected.")
        } catch let error as WindowsMCPToolError { #expect(error.code == .stateConflict) }
        do {
            _ = try await runtime.performObservedSemanticAction(sessionID: session, request: request,
                observationID: observation, operationToken: token)
            Issue.record("The fixture has no paired Companion and must not execute remotely.")
        } catch let error as WindowsMCPToolError {
            // Reaching the real dispatch gate proves frame repaints did not
            // reject a valid semantic context or bypass Companion authority.
            #expect(error.code == .companionRequired)
        }
        runtime.revokeAuthorizedOperations(targetID: target.targetID)
        do {
            _ = try await runtime.performObservedSemanticAction(sessionID: session, request: request,
                observationID: observation, operationToken: token)
            Issue.record("A retained UIA observation cannot restore revoked control authority.")
        } catch let error as WindowsMCPToolError { #expect(error.code == .permissionDenied) }
    }

    @Test func companionChannelTransitionInvalidatesObservationWithoutClosingRDP() throws {
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw WindowsMCPToolError(code: .runtimeFailure, message: "No connection expected.")
        })
        defer { runtime.stopAllImmediately() }
        let target = RemoteSession(name: "Windows", host: "uia.test", username: "operator", connectionType: .rdp)
        let session = runtime.installActiveDesktopForTesting(target: target)
        let token = RDPAuthorizedOperationToken(operationID: UUID(), targetID: target.targetID,
            targetBinding: "binding", clientID: "codex", generation: 1, connectionGeneration: 1,
            showsControlActivity: false, showsViewingActivity: true, survivesConnectionTransition: false)
        let id = runtime.uiaObservations.record(token: token, sessionID: session)
        runtime.uiaObservations.remove(targetID: UUID())
        try runtime.uiaObservations.validate(id, token: token, sessionID: session)
        runtime.receiveDesktopStateForTesting(sessionID: session, phase: .connected,
            companionDVCConnected: false, companionDVCGeneration: 2)
        #expect(throws: WindowsMCPToolError.self) {
            try runtime.uiaObservations.validate(id, token: token, sessionID: session)
        }
        #expect(runtime.sessionID(for: target.targetID) == session)
    }

    @Test func resultBindsTargetSessionProvenanceAndObservation() throws {
        let target = UUID().uuidString, session = UUID().uuidString
        let arguments: [String: Any] = ["targetId": target, "sessionId": session, "operation": "snapshot"]
        let content: [String: Any] = ["ok": true, "targetId": target, "sessionId": session,
            "operation": "snapshot", "observationId": UUID().uuidString, "validForSeconds": 60,
            "stateRevision": 3, "capturedAt": "2026-09-26T10:00:00Z",
            "transportProof": ["channel": "companion-dvc"],
            "data": ["root": node(), "nodeCount": 1, "truncated": false]]
        _ = try WindowsMCPToolResponse(structuredContent: content).validated(for: .desktopUIA, arguments: arguments)
        for (key, value): (String, Any) in [("targetId", UUID().uuidString), ("sessionId", UUID().uuidString),
            ("observationId", "bad"), ("validForSeconds", 3_600), ("stateRevision", true),
            ("operation", "find"), ("transportProof", ["channel": "other"])] {
            var bad = content; bad[key] = value
            #expect(throws: WindowsMCPToolError.self) {
                _ = try WindowsMCPToolResponse(structuredContent: bad).validated(for: .desktopUIA, arguments: arguments)
            }
        }
    }

    @Test func structureRequiresSeparateExternalDataConsent() {
        #expect(RemoteExternalDataPolicy.completeTypes(for: [.desktopObserve]) == [.desktopImage, .desktopStructure])
        #expect(WindowsMCPToolName.desktopUIA.requiresCompanion)
        #expect(!WindowsMCPToolName.desktopObserve.requiresCompanion)
    }
}
#endif
