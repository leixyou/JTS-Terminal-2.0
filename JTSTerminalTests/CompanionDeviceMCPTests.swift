#if ENABLE_RDP_2
import CryptoKit
import Foundation
import JTSCompanionClient
import JTSCompanionDevices
import JTSCompanionIPC
import Testing
@testable import JTSTerminal

@MainActor @Suite(.serialized)
struct CompanionDeviceMCPTests {
    private let target = UUID().uuidString.lowercased()

    @Test func accessCodeUsesDelegatedControlWithoutRDPAndRestrictsArguments() throws {
        let create: [String: Any] = ["targetId": target, "action": "createCode", "relayURL": "https://relay.example.test",
                                     "allowWindows10TLS12": true]
        #expect(try CompanionDeviceMCPRequest(tool: .status, arguments: create).capabilities == [.desktopControl])
        for action in ["codeStatus", "cancelCode"] {
            let values: [String: Any] = ["targetId": target, "action": action, "invitationId": UUID().uuidString]
            #expect(try CompanionDeviceMCPRequest(tool: .status, arguments: values).capabilities == [.desktopControl])
            var invalid = values; invalid["allowWindows10TLS12"] = true
            #expect(throws: WindowsMCPToolError.self) { try CompanionDeviceMCPRequest(tool: .status, arguments: invalid) }
        }
        for extra in ["sessionId", "privateKey", "approved"] {
            var invalid = create; invalid[extra] = "injected"
            #expect(throws: WindowsMCPToolError.self) { try CompanionDeviceMCPRequest(tool: .status, arguments: invalid) }
        }
        #expect(throws: WindowsMCPToolError.self) {
            try CompanionDeviceMCPRequest(tool: .status, arguments: ["targetId": target, "action": "codeStatus"])
        }
        #expect(throws: WindowsMCPToolError.self) {
            try CompanionDeviceMCPRequest(tool: .status, arguments: ["targetId": target, "relayURL": "https://relay.example.test"])
        }
    }

    @Test func independentToolsRejectSessionAndInjectedAuthority() throws {
        let valid: [String: Any] = ["targetId": target, "script": "Get-Date"]
        let parsed = try CompanionDeviceMCPRequest(tool: .exec, arguments: valid)
        #expect(parsed.capabilities == [.commandExecution])
        for key in ["sessionId", "grantId", "privateKey", "approved", "transport"] {
            var values = valid; values[key] = UUID().uuidString
            #expect(throws: WindowsMCPToolError.self) { try CompanionDeviceMCPRequest(tool: .exec, arguments: values) }
        }
        let definitions = CompanionDeviceMCPRegistry.definitions
        #expect(definitions.count == 4)
        for definition in definitions {
            let schema = try #require(definition["inputSchema"] as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(properties["sessionId"] == nil)
            #expect((schema["required"] as? [String])?.contains("targetId") == true)
        }
    }

    @Test func delegationUsesExistingDesktopControlAndDistinctLaneGrants() throws {
        let control = UUID().uuidString
        let values: [String: Any] = ["targetId": target, "action": "bind", "deviceId": UUID().uuidString,
            "grantId": control, "fileGrantId": UUID().uuidString, "rdpGrantId": UUID().uuidString]
        #expect(try CompanionDeviceMCPRequest(tool: .status, arguments: values).capabilities == [.desktopControl])
        var reused = values; reused["rdpGrantId"] = control
        #expect(throws: WindowsMCPToolError.self) { try CompanionDeviceMCPRequest(tool: .status, arguments: reused) }
        #expect(try CompanionDeviceMCPRequest(tool: .status, arguments: ["targetId": target]).capabilities == [.discovery])
    }

    @Test func publicEnrollmentBindsTheExactPeerAndCannotImportSecrets() throws {
        let key = P256.Signing.PrivateKey().publicKey.derRepresentation
        var bundle: [String: Any] = ["version": 1, "name": "Test Windows", "relayURL": "https://relay.example.test",
            "peerSPKIBase64": key.base64EncodedString(), "peerDeviceID": try CompanionDeviceRegistry.peerDeviceID(forSPKI: key),
            "pairingID": UUID().uuidString, "grantID": UUID().uuidString,
            "fileGrantID": UUID().uuidString, "rdpGrantID": UUID().uuidString]
        #expect(try CompanionPublicEnrollment(bundle).peerSPKI == key)
        #expect(try CompanionPublicEnrollment(bundle).compatibility == false)
        bundle["allowWindows10TLS12"] = true
        #expect(try CompanionPublicEnrollment(bundle).compatibility == true)
        for invalid in [1, "true", NSNull()] as [Any] {
            bundle["allowWindows10TLS12"] = invalid
            #expect(throws: WindowsMCPToolError.self) { try CompanionPublicEnrollment(bundle) }
        }
        bundle.removeValue(forKey: "allowWindows10TLS12")
        bundle["installationState"] = "installedAwaitingRelayAdmission"
        #expect(try CompanionPublicEnrollment(bundle).peerSPKI == key)
        bundle["installationState"] = true
        #expect(throws: WindowsMCPToolError.self) { try CompanionPublicEnrollment(bundle) }
        bundle.removeValue(forKey: "installationState")
        bundle["privateKey"] = "not permitted"
        #expect(throws: WindowsMCPToolError.self) { try CompanionPublicEnrollment(bundle) }
        bundle.removeValue(forKey: "privateKey"); bundle["peerDeviceID"] = String(repeating: "0", count: 64)
        #expect(throws: WindowsMCPToolError.self) { try CompanionPublicEnrollment(bundle) }
    }

    @Test func identityRequestCarriesExplicitCompatibilityWithoutChangingExistingBindings() throws {
        let key = P256.Signing.PrivateKey().publicKey.derRepresentation
        let deviceID = try CompanionDeviceRegistry.peerDeviceID(forSPKI: key)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var values: [String: Any] = ["targetId": target, "action": "identity"]
        for selection in [nil, false, true] as [Bool?] {
            values["allowWindows10TLS12"] = selection
            let request = try CompanionDeviceMCPRequest(tool: .status, arguments: values)
            #expect(request.capabilities == [.desktopControl])
            let bundle = try request.delegatedEnrollmentRequest(controllerDeviceID: deviceID, publicSPKI: key, now: now)
            let bytes = try JSONSerialization.data(withJSONObject: bundle)
            let wire = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(wire["allowWindows10TLS12"] as? Bool == (selection == true ? true : nil))
            #expect(wire["controllerDeviceID"] as? String == deviceID)
            #expect(wire["controllerSPKIBase64"] as? String == key.base64EncodedString())
            let grants = try ["pairingID", "grantID", "fileGrantID", "rdpGrantID"].map { try CompanionDeviceMCPRequest.identifier($0, wire) }
            #expect(Set(grants).count == 4)
            let expiry = try #require(ISO8601DateFormatter().date(from: wire["expiresAtUtc"] as? String ?? ""))
            #expect(expiry.timeIntervalSince(now) == 1800)
        }
        for invalid in [1, "true", NSNull()] as [Any] {
            values["allowWindows10TLS12"] = invalid
            #expect(throws: WindowsMCPToolError.self) { try CompanionDeviceMCPRequest(tool: .status, arguments: values) }
        }
        for action in ["status", "connect", "disconnect", "bind", "unbind", "enroll"] {
            values["action"] = action; values["allowWindows10TLS12"] = true
            #expect(throws: WindowsMCPToolError.self) { try CompanionDeviceMCPRequest(tool: .status, arguments: values) }
        }
    }

    @Test func atomicWriteCommitsOnlyAfterEveryChunkAndVerifiesPublishedHash() async throws {
        let bytes = Data(repeating: 65, count: 70000)
        let request = try CompanionDeviceMCPRequest(tool: .files, arguments: ["targetId": target, "action": "write",
            "rootId": "user-profile", "path": "probe.txt", "content": bytes.base64EncodedString(), "encoding": "base64"])
        #expect(request.capabilities == [.fileAccess, .destructiveOperations])
        let plan = try CompanionDeviceFilePlan(request)
        var operations: [CompanionFileOperation] = [], uploaded = Data(), transfer: String?
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let result = try await plan.perform { operation, parameters in
            operations.append(operation)
            if operation == .beginWrite { transfer = parameters["transferId"] as? String; #expect(parameters["overwrite"] as? Bool == false) }
            if operation == .writeChunk {
                #expect(parameters["transferId"] as? String == transfer)
                #expect(parameters["offset"] as? Int == uploaded.count)
                uploaded.append(try #require(Data(base64Encoded: parameters["dataBase64"] as? String ?? "")))
                #expect(parameters["final"] as? Bool == (uploaded.count == bytes.count))
            }
            return operation == .commitWrite ? ["size": bytes.count, "sha256": sha] : [:]
        }
        #expect(uploaded == bytes)
        #expect(operations == [.beginWrite, .writeChunk, .writeChunk, .writeChunk, .commitWrite])
        #expect(result["sha256"] as? String == sha)
    }

    @Test func failedUploadNeverCommitsOrRetries() async throws {
        let request = try CompanionDeviceMCPRequest(tool: .files, arguments: ["targetId": target, "action": "write",
            "rootId": "user-profile", "path": "probe.txt", "content": "hello", "encoding": "utf8"])
        let plan = try CompanionDeviceFilePlan(request)
        var operations: [CompanionFileOperation] = []
        do {
            _ = try await plan.perform { operation, _ in
                operations.append(operation)
                if operation == .writeChunk { throw CancellationError() }
                return [:]
            }
            Issue.record("Expected cancelled upload")
        } catch is CancellationError {}
        #expect(operations == [.beginWrite, .writeChunk])
    }

    @Test func booleansAndUnsupportedRecursiveRemovalFailClosed() throws {
        #expect(throws: WindowsMCPToolError.self) {
            try CompanionDeviceMCPRequest(tool: .task, arguments: ["targetId": target, "action": "submit", "script": "Get-Date", "allowDisconnected": 1])
        }
        let request = try CompanionDeviceMCPRequest(tool: .files, arguments: ["targetId": target, "action": "remove",
            "rootId": "user-profile", "path": "folder", "recursive": true])
        #expect(throws: WindowsMCPToolError.self) { try CompanionDeviceFilePlan(request) }
        #expect(throws: WindowsMCPToolError.self) {
            try CompanionDeviceMCPRequest(tool: .exec, arguments: ["targetId": target, "script": "Get-Date", "timeoutSeconds": 1.5])
        }
    }

    @Test func listingLimitMatchesTheWindowsLaneBound() throws {
        for limit in [1, 100] {
            let request = try CompanionDeviceMCPRequest(tool: .files, arguments: ["targetId": target,
                "action": "list", "rootId": "shared", "path": ".", "limit": limit])
            _ = try CompanionDeviceFilePlan(request)
        }
        let tooLarge = try CompanionDeviceMCPRequest(tool: .files, arguments: ["targetId": target,
            "action": "list", "rootId": "shared", "path": ".", "limit": 101])
        #expect(throws: WindowsMCPToolError.self) { try CompanionDeviceFilePlan(tooLarge) }
    }
}
#endif
