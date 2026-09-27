#if ENABLE_RDP_2
import AppKit
import CryptoKit
import Foundation
import JTSCompanionDevices
import JTSCompanionIPC
import JTSCompanionClient
import SwiftUI
import Testing
@testable import JTSTerminal

@MainActor @Suite(.serialized)
struct CompanionDevicesModelTests {
    @Test(arguments: [false, true])
    func concurrentReadOnlySnapshotsShareRefreshAndItsFailure(failStorage: Bool) async throws {
        let persistence = DeviceMemoryPersistence()
        let (model, _, client, deviceID) = try await fixture(persistence: persistence)
        let initialLoads = await persistence.loads
        if failStorage { await persistence.remove() }
        await persistence.blockNextLoad()
        let first = Task { try await model.mcpSnapshot() }
        await persistence.waitForBlockedLoad()
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await model.mcpSnapshot()
        }
        while !secondStarted { await Task.yield() }
        await persistence.releaseLoad()
        for result in [await first.result, await second.result] {
            switch result {
            case .success(let snapshot):
                #expect(!failStorage)
                #expect(snapshot?.devices.first?.id == deviceID)
            case .failure(let error):
                #expect(failStorage)
                #expect(error as? CompanionDeviceError == .storageUnavailable)
            }
        }
        #expect(await persistence.loads == initialLoads + 1)
        #expect(model.loaded == !failStorage)
        #expect(!model.busy)
        #expect(await persistence.creates == 1)
        #expect(await client.opens == 0)
    }

    @Test func readOnlySnapshotStillRejectsConcurrentRevocation() async throws {
        let persistence = DeviceMemoryPersistence()
        let (model, _, _, _) = try await fixture(persistence: persistence)
        await persistence.blockNextLoad()
        let revocation = Task { await model.revokeSelected() }
        await persistence.waitForBlockedLoad()
        do {
            _ = try await model.mcpSnapshot()
            Issue.record("A read must not bypass an in-progress trust mutation")
        } catch {
            #expect(error as? CompanionDeviceError == .operationInProgress)
        }
        await persistence.releaseLoad()
        await revocation.value
        #expect(model.selected?.revokedAt != nil)
    }

    @Test func readsDoNotCreateAnIdentityOrOpenANetworkConnection() async throws {
        let persistence = DeviceMemoryPersistence()
        let registry = CompanionDeviceRegistry(persistence: persistence)
        let client = DeviceConnectionProbe()
        let model = CompanionDevicesModel(registry: registry, makeConnection: { client })
        await model.refresh()
        #expect(model.loaded && model.snapshot == nil)
        #expect(await persistence.creates == 0)
        #expect(await client.opens == 0)
        await model.initialize()
        #expect(model.snapshot != nil)
        #expect(await persistence.creates == 1)
        #expect(await client.opens == 0)
    }

    @Test func openingPinnedTransportDoesNotInventCapabilities() async throws {
        let (model, _, client, _) = try await fixture()
        await model.connect()
        #expect(model.hasRoute && model.openedAt != nil)
        #expect(model.capabilities.isEmpty && model.verifiedAt == nil)
        #expect(await client.opens == 1)
        #expect(await client.statusCalls == 0)
        await model.checkGrant(UUID().uuidString)
        #expect(model.verifiedAt != nil && model.verifiedGrant != nil)
        #expect(model.capabilities == ["device.status", "job.get"])
        model.disconnect()
        #expect(!model.hasRoute && model.verifiedAt == nil && model.capabilities.isEmpty)
    }

    @Test func externalRevocationPreventsAnotherControlCall() async throws {
        let (model, registry, client, id) = try await fixture()
        await model.connect()
        _ = try await registry.revokeDevice(id: id)
        await model.checkGrant(UUID().uuidString)
        #expect(await client.statusCalls == 0)
        #expect(!model.hasRoute && model.errorCode != nil)
    }

    @Test func localRevokePersistsBeforeItIsShownAndNoRouteReopens() async throws {
        let (model, _, client, _) = try await fixture()
        await model.connect()
        await model.revokeSelected()
        #expect(model.selected?.revokedAt != nil)
        #expect(!model.canConnect && !model.hasRoute)
        await model.connect()
        #expect(await client.opens == 1)
    }

    @Test func lostStateCannotBecomeANewIdentity() async throws {
        let persistence = DeviceMemoryPersistence()
        let registry = CompanionDeviceRegistry(persistence: persistence)
        _ = try await registry.initialize()
        let model = CompanionDevicesModel(registry: registry)
        await model.refresh()
        await persistence.remove()
        await model.refresh()
        #expect(!model.loaded && model.errorCode == "DEVICE_STORE_UNAVAILABLE")
        await model.initialize()
        #expect(await persistence.creates == 1)
    }

    @Test func disconnectDuringOpenDoesNotResurrectRoute() async throws {
        let (model, _, client, _) = try await fixture()
        await client.blockOpen()
        let task = Task { await model.connect() }
        for _ in 0..<1_000 {
            if await client.opens > 0 { break }
            await Task.yield()
        }
        #expect(await client.opens == 1)
        model.disconnect()
        await client.releaseOpen()
        await task.value
        #expect(!model.hasRoute && model.openedAt == nil && !model.busy)
    }

    @Test func disconnectDuringTrustReadPreventsStatusRequest() async throws {
        let persistence = DeviceMemoryPersistence()
        let (model, _, client, _) = try await fixture(persistence: persistence)
        await model.connect()
        await persistence.blockNextLoad()
        let task = Task { await model.checkGrant(UUID().uuidString) }
        await persistence.waitForBlockedLoad()
        model.disconnect()
        await persistence.releaseLoad()
        await task.value
        #expect(await client.statusCalls == 0)
        #expect(!model.hasRoute && model.verifiedAt == nil && !model.busy)
    }

    @Test func renderEmptyDeviceWindowWithIsolatedState() async throws {
        let registry = CompanionDeviceRegistry(persistence: DeviceMemoryPersistence())
        let model = CompanionDevicesModel(registry: registry)
        await model.refresh()
        let host = NSHostingView(rootView: CompanionDevicesView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 920, height: 640)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width >= 740)
        #expect(host.fittingSize.height >= 520)
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let bytes = try #require(image.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-companion-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("devices-empty.png")
        try bytes.write(to: destination)
        print("JTS_COMPANION_UI_EVIDENCE: \(destination.path)")
    }

    @Test func selectionKeepsExistingRouteAndItsGrant() async throws {
        let (model, registry, client, first) = try await fixture()
        await model.connect()
        let grant = UUID()
        await model.checkGrant(grant.uuidString)
        let peer = P256.Signing.PrivateKey().publicKey.derRepresentation
        let second = try await registry.addDevice(name: "Other Windows", relayURL: "https://relay.example.com",
            peerSPKI: peer, verifiedPeerDeviceID: CompanionDeviceRegistry.peerDeviceID(forSPKI: peer))
        await model.refresh()
        model.select(second.id)
        #expect(!model.hasRoute && model.connectedCount == 1)
        #expect(model.routes[first]?.verifiedGrant == grant)
        model.select(first)
        #expect(model.hasRoute && model.verifiedGrant == grant)
        #expect(await client.opens == 1)
    }

    @Test func submitIsJournaledAndRestoredWithoutScriptsOutputOrReplay() async throws {
        let persistence = DeviceMemoryPersistence()
        let registry = CompanionDeviceRegistry(persistence: DeviceMemoryPersistence())
        _ = try await registry.initialize()
        let peer = P256.Signing.PrivateKey().publicKey.derRepresentation
        let device = try await registry.addDevice(name: "Windows", relayURL: "https://relay.example.com",
            peerSPKI: peer, verifiedPeerDeviceID: CompanionDeviceRegistry.peerDeviceID(forSPKI: peer))
        let journal = CompanionJobJournal(persistence: persistence)
        let client = DeviceConnectionProbe()
        await client.enableJobs()
        let model = CompanionDevicesModel(registry: registry, journal: journal, makeConnection: { client })
        await model.refresh(); await model.connect(); await model.checkGrant(UUID().uuidString)
        let id = try #require(await model.submitJob(script: "Write-Output 'private-script'", directory: "C:\\secret",
            timeoutSeconds: 300, allowDisconnected: false))
        #expect(model.selectedRoute?.jobs.first?.receipt?.state == .running)
        let raw = try #require(await persistence.load())
        #expect(!raw.contains("private-script") && !raw.contains("secret") && !raw.contains("output"))
        let restored = CompanionDevicesModel(registry: registry, journal: CompanionJobJournal(persistence: persistence), makeConnection: { client })
        await restored.refresh()
        #expect(restored.routes[device.id]?.jobs.first?.id == id)
        #expect(restored.routes[device.id]?.jobs.first?.receipt == nil)
        #expect(await client.submits == 1)
    }

    @Test func cancelledReplyMustComeFromRemoteAndOutputIsMemoryOnly() async throws {
        let (model, _, client, _) = try await fixture()
        await client.enableJobs()
        await model.connect(); await model.checkGrant(UUID().uuidString)
        let id = try #require(await model.submitJob(script: "Write-Output 'hi'", directory: "C:\\",
            timeoutSeconds: 300, allowDisconnected: true))
        await model.cancelJob(id)
        #expect(model.selectedRoute?.jobs.first?.receipt?.state == .cancelling)
        #expect(model.selectedRoute?.jobs.first?.isTerminal == false)
        await model.readJobOutput(id)
        #expect(model.selectedRoute?.jobs.first?.output == Data("hello".utf8))
        model.disconnect()
        #expect(model.selectedRoute?.jobs.first?.receipt?.state == .cancelling)
        #expect(model.selectedRoute?.jobs.first?.output.isEmpty == true)
    }

    @Test func disconnectDuringSubmitKeepsIDAndIgnoresLateReceipt() async throws {
        let (model, _, client, _) = try await fixture()
        await client.enableJobs(); await client.blockSubmit()
        await model.connect(); await model.checkGrant(UUID().uuidString)
        let operation = Task { await model.submitJob(script: "Get-Date", directory: "C:\\", timeoutSeconds: 60, allowDisconnected: false) }
        await client.waitForSubmit()
        let id = try #require(model.selectedRoute?.jobs.first?.id)
        model.disconnect()
        await client.releaseSubmit()
        _ = await operation.value
        #expect(model.selectedRoute?.jobs.first?.id == id)
        #expect(model.selectedRoute?.jobs.first?.receipt == nil)
        #expect(!model.hasRoute && !model.busy)
    }

    @Test func revokeBeforeJobReadPreventsNetworkRequest() async throws {
        let (model, registry, client, deviceID) = try await fixture()
        await client.enableJobs()
        await model.connect(); await model.checkGrant(UUID().uuidString)
        let id = try #require(await model.submitJob(script: "Get-Date", directory: "C:\\", timeoutSeconds: 60, allowDisconnected: false))
        _ = try await registry.revokeDevice(id: deviceID)
        await model.refreshJob(id)
        #expect(await client.jobReads == 0)
        #expect(!model.hasRoute)
    }

    @Test func scriptAndWorkingFolderValidationMatchesNativePayloadBounds() throws {
        for directory in ["C:\\", "D:\\jobs\\working", "C:\\中文"] {
            #expect(CompanionPowerShellRequest.validDirectory(directory))
        }
        for directory in ["relative", "C:/jobs", "\\\\server\\share", "C:\\..\\secret", "C:\\a ", "C:\\a\\\\b"] {
            #expect(!CompanionPowerShellRequest.validDirectory(directory))
        }
        #expect(throws: (any Error).self) { try CompanionPowerShellRequest.payload(script: " ", directory: "C:\\") }
        #expect(throws: (any Error).self) { try CompanionPowerShellRequest.payload(script: String(repeating: "x", count: 48 * 1024 + 1), directory: "C:\\") }
    }

    @Test func independentMCPRevocationDuringJournalPreventsDispatch() async throws {
        let persistence = DeviceMemoryPersistence()
        let (model, _, client, deviceID) = try await fixture(journalPersistence: persistence)
        await client.enableJobs()
        let route = try await model.mcpConnect(deviceID: deviceID, grantID: UUID(), authorize: {})
        await persistence.blockNextLoad()
        var authorized = true
        let operation = Task {
            try await model.mcpSubmit(route: route, script: "Get-Date", directory: ".", timeoutSeconds: 60,
                allowDisconnected: false, authorize: {
                    guard authorized else { throw CancellationError() }
                })
        }
        await persistence.waitForBlockedLoad()
        authorized = false
        await persistence.releaseLoad()
        do { _ = try await operation.value; Issue.record("Expected authority cancellation") }
        catch is CancellationError {}
        #expect(await client.submits == 0)
        #expect(route.jobs.isEmpty)
    }

    @Test func independentMCPUsesCurrentUserRootWithoutAnRDPDesktop() async throws {
        let (model, _, client, deviceID) = try await fixture()
        await client.enableJobs()
        let route = try await model.mcpConnect(deviceID: deviceID, grantID: UUID(), authorize: {})
        let job = try await model.mcpSubmit(route: route, script: "Get-Date", directory: ".",
            timeoutSeconds: 60, allowDisconnected: false, authorize: {})
        #expect(job.receipt?.state == .running)
        #expect(await client.submits == 1)
        let payload = try JSONSerialization.jsonObject(with: CompanionPowerShellRequest.payload(script: "Get-Date", directory: ".")) as? [String: Any]
        #expect(payload?["workingDirectory"] as? String == ".")
    }

    private func fixture(persistence: DeviceMemoryPersistence = DeviceMemoryPersistence(),
                         journalPersistence: DeviceMemoryPersistence = DeviceMemoryPersistence()) async throws
        -> (CompanionDevicesModel, CompanionDeviceRegistry, DeviceConnectionProbe, UUID) {
        let registry = CompanionDeviceRegistry(persistence: persistence)
        _ = try await registry.initialize()
        let peer = P256.Signing.PrivateKey().publicKey.derRepresentation
        let device = try await registry.addDevice(name: "Windows fixture", relayURL: "https://relay.example.com",
            peerSPKI: peer, verifiedPeerDeviceID: CompanionDeviceRegistry.peerDeviceID(forSPKI: peer))
        let client = DeviceConnectionProbe()
        let model = CompanionDevicesModel(registry: registry, journal: CompanionJobJournal(persistence: journalPersistence), makeConnection: { client })
        await model.refresh()
        return (model, registry, client, device.id)
    }
}

private actor DeviceMemoryPersistence: CompanionDevicePersistence {
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

private actor DeviceConnectionProbe: CompanionDeviceConnection {
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
