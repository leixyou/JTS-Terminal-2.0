#if ENABLE_RDP_2
import CryptoKit
import Foundation
import JTSCompanionClient
import JTSCompanionDevices
import JTSCompanionIPC
import Testing
@testable import JTSTerminal

@MainActor @Suite(.serialized)
struct CompanionDevicePermissionIsolationTests {
    @Test func discoveryOnlyDeviceCannotBeReachedThroughAnotherProfile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jts-alias-audit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let grants = RemoteClientGrantStore(storageURL: dir.appendingPathComponent("grants.json"))
        let audit = RemoteCapabilityAuditStore(storageURL: dir.appendingPathComponent("audit.json"))
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw CancellationError()
        }, grantStoreForTesting: grants, auditStoreForTesting: audit)
        defer { runtime.stopAllImmediately() }
        let registry = CompanionDeviceRegistry(persistence: AliasAuditMemory())
        _ = try await registry.initialize()
        let peerKey = P256.Signing.PrivateKey().publicKey.derRepresentation
        let deviceB = try await registry.addDevice(name: "Windows B", relayURL: "https://relay.example.test",
            peerSPKI: peerKey, verifiedPeerDeviceID: CompanionDeviceRegistry.peerDeviceID(forSPKI: peerKey))
        let peer = AliasAuditPeer()
        await peer.enableJobs()
        let model = CompanionDevicesModel(registry: registry, journal: CompanionJobJournal(persistence: AliasAuditMemory()), makeConnection: { peer })
        let bindings = CompanionTargetRouteStore(persistence: AliasAuditMemory())
        let targetA = RemoteSession(name: "Allowed A", host: "a.example.test", username: "owner", connectionType: .rdp)
        let targetB = RemoteSession(name: "Read-only B", host: "b.example.test", username: "owner", connectionType: .rdp)
        targetA.mcpEnabled = true; targetB.mcpEnabled = true
        try targetA.setRDPProfile(RDPConnectionProfile(permissionPolicy: RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .desktopControl, .commandExecution], controlLeaseCapabilities: [], requireExternalDataConsent: false)))
        try targetB.setRDPProfile(RDPConnectionProfile(permissionPolicy: RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery], controlLeaseCapabilities: [], requireExternalDataConsent: false)))
        let grantB = UUID()
        try await bindings.bind(targetID: targetB.targetID, targetBinding: targetB.mcpGrantTargetBinding, deviceID: deviceB.id, grantID: grantB)
        let handler = CompanionDeviceMCPHandler(devices: model, bindings: bindings, runtime: runtime)
        func args(_ target: RemoteSession, _ extra: [String: Any]) -> [String: Any] {
            ["targetId": target.targetID.uuidString, "_jtsClientID": "audit-registered-client"].merging(extra) { _, b in b }
        }
        // Baseline proves the production handler denies commands on B.
        do {
            _ = try await handler.handle(tool: .task, target: targetB, arguments: args(targetB, ["action": "submit", "script": "Get-Date"]))
            Issue.record("Direct B operation unexpectedly allowed")
        } catch let e as WindowsMCPToolError { #expect(e.code == .permissionDenied) }
        #expect(await peer.submits == 0)
        let metadata = try await handler.handle(tool: .status, target: targetB, arguments: args(targetB, ["action": "status"]))
        #expect(metadata["deviceId"] as? String == deviceB.id.uuidString.lowercased())
        #expect(metadata["grantId"] as? String == grantB.uuidString.lowercased())
        await #expect(throws: WindowsMCPToolError.self) {
            try await handler.handle(tool: .status, target: targetA, arguments: args(targetA,
                ["action": "bind", "deviceId": metadata["deviceId"]!, "grantId": metadata["grantId"]!]))
        }
        #expect(await peer.submits == 0)
        #expect(await peer.opens == 0)
        #expect(try await bindings.binding(targetID: targetA.targetID, targetBinding: targetA.mcpGrantTargetBinding) == nil)
        // Disabling discovery on B must not make its retained identity borrowable.
        targetB.mcpEnabled = false
        await #expect(throws: WindowsMCPToolError.self) {
            try await handler.handle(tool: .status, target: targetA, arguments: args(targetA,
                ["action": "bind", "deviceId": metadata["deviceId"]!, "grantId": metadata["grantId"]!]))
        }
        #expect(await peer.opens == 0)
    }
}

private actor AliasAuditMemory: CompanionDevicePersistence {
    private var value: String?
    private(set) var creates = 0
    private(set) var loads = 0
    private var shouldBlockLoad = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    func load() async -> String? {
        loads += 1
        if shouldBlockLoad {
            shouldBlockLoad = false
            await withCheckedContinuation {
                loadContinuation = $0
                startedContinuation?.resume(); startedContinuation = nil
            }
        }
        return value
    }
    func blockNextLoad() { shouldBlockLoad = true }
    func waitForBlockedLoad() async {
        if loadContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func releaseLoad() { loadContinuation?.resume(); loadContinuation = nil }
    func create(_ value: String) throws {
        guard self.value == nil else { throw CompanionDevicePersistenceError.alreadyExists }
        self.value = value; creates += 1
    }
    func replace(expected: String, with value: String) throws {
        guard self.value == expected else { throw CompanionDevicePersistenceError.conflict }
        self.value = value
    }
    func remove() { value = nil }
}

private actor AliasAuditPeer: CompanionDeviceConnection {
    private(set) var opens = 0
    private(set) var statusCalls = 0
    private(set) var submits = 0
    private(set) var jobReads = 0
    private var jobsEnabled = false
    private var lastRequest: CompanionIPCSubmit?
    private var submitBlocked = false
    private var submitContinuation: CheckedContinuation<Void, Never>?
    private var submitStarted: CheckedContinuation<Void, Never>?
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func blockOpen() { blocked = true }
    func releaseOpen() { blocked = false; continuation?.resume(); continuation = nil }
    func open(_ configuration: CompanionIPCOpen) async throws -> CompanionIPCState {
        try configuration.validate(); opens += 1
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return CompanionIPCState(phase: "connected", sessionID: UUID().uuidString)
    }
    func enableJobs() { jobsEnabled = true }
    func blockSubmit() { submitBlocked = true }
    func waitForSubmit() async {
        if submitContinuation != nil { return }
        await withCheckedContinuation { submitStarted = $0 }
    }
    func releaseSubmit() { submitBlocked = false; submitContinuation?.resume(); submitContinuation = nil }
    func status(grantID: UUID) throws -> CompanionControlStatus {
        statusCalls += 1
        if jobsEnabled {
            return try CompanionIPCCodec.decodePayload(Data(#"{"capabilities":["device.status","job.submit","job.get","job.cancel","job.output"],"maximumPayloadBytes":65536,"maximumOutputChunkBytes":32768}"#.utf8), as: CompanionControlStatus.self)
        }
        return try CompanionIPCCodec.decodePayload(Data(#"{"capabilities":["device.status","job.get"],"maximumPayloadBytes":65536,"maximumOutputChunkBytes":32768}"#.utf8), as: CompanionControlStatus.self)
    }
    func submit(_ request: CompanionIPCSubmit) async throws -> CompanionJobReceipt {
        submits += 1; lastRequest = request
        if submitBlocked {
            await withCheckedContinuation { submitContinuation = $0; submitStarted?.resume(); submitStarted = nil }
        }
        return try receipt(state: "running")
    }
    func job(grantID: UUID, jobID: UUID) throws -> CompanionJobReceipt { jobReads += 1; return try receipt(state: "running") }
    func cancel(grantID: UUID, jobID: UUID) throws -> CompanionJobReceipt { try receipt(state: "cancelling") }
    func output(_ request: CompanionIPCOutput) throws -> CompanionJobOutput {
        let bytes = Data("hello".utf8)
        let data = try JSONSerialization.data(withJSONObject: ["jobId": request.jobID.uuidString.lowercased(),
            "offset": request.offset, "nextOffset": request.offset + bytes.count, "outputBytes": request.offset + bytes.count,
            "dataBase64": bytes.base64EncodedString()])
        return try CompanionIPCCodec.decodePayload(data, as: CompanionJobOutput.self)
    }
    private func receipt(state: String) throws -> CompanionJobReceipt {
        guard let request = lastRequest else { throw CompanionClientError.invalidReply }
        let data = try JSONSerialization.data(withJSONObject: ["jobId": request.jobID.uuidString.lowercased(),
            "grantId": request.grantID.uuidString.lowercased(), "kind": request.kind,
            "deadlineUnixMilliseconds": request.deadlineUnixMilliseconds, "allowDisconnected": request.allowDisconnected,
            "state": state, "submittedAtUnixMilliseconds": request.deadlineUnixMilliseconds - 1000,
            "startedAtUnixMilliseconds": NSNull(), "completedAtUnixMilliseconds": NSNull(),
            "resultCode": NSNull(), "outputBytes": 5, "dataExpired": false])
        return try CompanionIPCCodec.decodePayload(data, as: CompanionJobReceipt.self)
    }
    func invalidate() { releaseOpen(); releaseSubmit() }
}

#endif
