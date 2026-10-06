#if ENABLE_RDP_2
import CryptoKit
import Foundation
import JTSCompanionClient
import JTSCompanionDevices
import JTSCompanionIPC
import Testing
@testable import JTSTerminal

@MainActor @Suite(.serialized)
struct RelayStationsModelTests {
    @Test func earlierLaneConfigurationIsRejectedAfterDeviceMigration() async throws {
        let fixture = try await fixture()
        let device = try #require(fixture.devices.snapshot?.devices.first)
        let original = try await fixture.devices.relayConfiguration(deviceID: device.id)
        try await fixture.devices.requireRelayConfiguration(deviceID: device.id, expected: original)
        #expect(await fixture.model.include(origin: "https://new.example"))
        #expect(await fixture.model.moveDevice(id: device.id, to: "https://new.example"))
        do {
            try await fixture.devices.requireRelayConfiguration(deviceID: device.id, expected: original)
            Issue.record("A lane opened on the old relay must not continue after migration")
        } catch { #expect(error as? CompanionDeviceError == .storageConflict) }
        let current = try await fixture.devices.relayConfiguration(deviceID: device.id)
        try await fixture.devices.requireRelayConfiguration(deviceID: device.id, expected: current)
        #expect(fixture.devices.snapshot?.devices.last?.relayURL == "https://old.example")
    }

    @Test func emptySettingsDoesNotCreateDeviceIdentityOrOpenNetwork() async throws {
        let deviceStore = RelayModelMemoryPersistence(), catalogStore = RelayModelMemoryPersistence()
        let connection = RelayModelConnectionStub(), probe = RelayModelProbeStub()
        let devices = CompanionDevicesModel(registry: CompanionDeviceRegistry(persistence: deviceStore),
            makeConnection: { connection })
        let model = RelayStationsModel(registry: RelayStationRegistry(persistence: catalogStore), devices: devices, probe: probe)
        await model.refresh()
        #expect(model.loaded && model.stations.isEmpty && model.defaultStationID == nil)
        #expect(devices.snapshot == nil)
        #expect(await deviceStore.creates == 0)
        #expect(await catalogStore.creates == 0)
        #expect(await connection.opened.isEmpty)
        #expect(await probe.origins.isEmpty)
    }

    @Test func refreshImportsExistingOriginsWithoutChangingDevicesOrChoosingDefault() async throws {
        let fixture = try await fixture(refreshCatalog: false)
        let before = await fixture.deviceStore.value, writes = await fixture.deviceStore.replacements
        await fixture.model.refresh()
        #expect(fixture.model.loaded && fixture.model.errorCode == nil)
        #expect(fixture.model.stations.count == 1)
        #expect(fixture.model.stations.first?.relayURL == "https://old.example")
        #expect(fixture.model.defaultStationID == nil)
        #expect(await fixture.deviceStore.value == before)
        #expect(await fixture.deviceStore.replacements == writes)
        #expect(await fixture.catalogStore.creates == 1)
        #expect(await fixture.connection.opened.isEmpty)
        #expect(await fixture.probe.origins.isEmpty)
    }

    @Test func changingDefaultOnlyChangesCatalogAndPreservesExistingDeviceRoutes() async throws {
        let fixture = try await fixture()
        let before = await fixture.deviceStore.value
        #expect(await fixture.model.include(origin: "https://new.example"))
        let destination = try #require(fixture.model.stations.first { $0.relayURL == "https://new.example" })
        await fixture.model.setDefault(id: destination.id)
        #expect(fixture.model.defaultStationID == destination.id)
        #expect(fixture.model.defaultOrigin == "https://new.example")
        #expect(await fixture.deviceStore.value == before)
        #expect(fixture.devices.snapshot?.devices.allSatisfy { $0.relayURL == "https://old.example" } == true)
        #expect(await fixture.connection.opened.isEmpty)
        #expect(await fixture.probe.origins.isEmpty)
    }

    @Test func removingStationInUseIsRejectedWithoutPersistentChanges() async throws {
        let fixture = try await fixture()
        let station = try #require(fixture.model.stations.first)
        let before = await fixture.catalogStore.value, writes = await fixture.catalogStore.replacements
        await fixture.model.remove(id: station.id)
        #expect(fixture.model.errorCode == "stationInUse")
        #expect(fixture.model.stations == [station])
        #expect(await fixture.catalogStore.value == before)
        #expect(await fixture.catalogStore.replacements == writes)
    }

    @Test func failedPublicProbeLeavesCatalogAndDevicesUntouched() async throws {
        let fixture = try await fixture()
        let station = try #require(fixture.model.stations.first)
        let beforeCatalog = await fixture.catalogStore.value, beforeDevices = await fixture.deviceStore.value
        await fixture.probe.setFailure(.serviceUnavailable)
        #expect(!(await fixture.model.save(id: station.id, name: "New relay", relayURL: "https://new.example")))
        #expect(fixture.model.errorCode == "serviceUnavailable")
        #expect(fixture.model.probeErrors["https://new.example"] == "serviceUnavailable")
        #expect(await fixture.catalogStore.value == beforeCatalog)
        #expect(await fixture.deviceStore.value == beforeDevices)
        #expect(await fixture.connection.opened.isEmpty)
    }

    @Test func failureToVerifyAnyPinnedPeerRejectsEntireMigration() async throws {
        let fixture = try await fixture()
        let station = try #require(fixture.model.stations.first)
        let peers = try #require(fixture.devices.snapshot?.devices)
        let beforeCatalog = await fixture.catalogStore.value, beforeDevices = await fixture.deviceStore.value
        await fixture.connection.reject(peerSPKI: peers[1].peerSPKI)
        #expect(!(await fixture.model.save(id: station.id, name: "New relay", relayURL: "https://new.example")))
        #expect(fixture.model.errorCode == "deviceVerificationFailed")
        #expect(await fixture.catalogStore.value == beforeCatalog)
        #expect(await fixture.deviceStore.value == beforeDevices)
        let opened = await fixture.connection.opened
        #expect(opened.map(\.peerSPKI) == peers.map(\.peerSPKI))
        #expect(opened.allSatisfy { $0.origin == "https://new.example" })
        #expect(await fixture.connection.invalidations == 2)
    }

    @Test func successfulMigrationMovesDefaultAndDisconnectsEveryAffectedLiveRoute() async throws {
        let fixture = try await fixture()
        let station = try #require(fixture.model.stations.first)
        let peers = try #require(fixture.devices.snapshot?.devices)
        await fixture.model.setDefault(id: station.id)
        for device in peers { await fixture.devices.connect(deviceID: device.id) }
        #expect(fixture.devices.connectedCount == peers.count)
        for device in peers {
            fixture.devices.routes[device.id]?.verifiedGrant = UUID()
            fixture.devices.routes[device.id]?.capabilities = ["device.status"]
        }
        #expect(await fixture.model.save(id: station.id, name: "New relay", relayURL: "https://new.example"))
        #expect(fixture.model.errorCode == nil)
        #expect(fixture.model.stations.count == 1)
        let destination = try #require(fixture.model.stations.first)
        #expect(destination.id != station.id && destination.name == "New relay")
        #expect(destination.relayURL == "https://new.example")
        #expect(fixture.model.defaultStationID == destination.id)
        #expect(fixture.devices.connectedCount == 0)
        for original in peers {
            let current = try #require(fixture.devices.snapshot?.devices.first { $0.id == original.id })
            #expect(current.relayURL == "https://new.example")
            #expect(current.peerSPKI == original.peerSPKI && current.peerDeviceID == original.peerDeviceID)
            #expect(current.allowWindows10TLS12 == original.allowWindows10TLS12)
            #expect(fixture.devices.routes[original.id]?.verifiedGrant == nil)
            #expect(fixture.devices.routes[original.id]?.capabilities.isEmpty == true)
        }
        let verified = await fixture.connection.opened.filter { $0.origin == "https://new.example" }
        #expect(verified.map(\.peerSPKI) == peers.map(\.peerSPKI))
    }

    @Test func failedDeviceWriteRetainsOldStationAndRoutesAndCanRetryStagedDestination() async throws {
        let fixture = try await fixture()
        let station = try #require(fixture.model.stations.first)
        await fixture.model.setDefault(id: station.id)
        let before = await fixture.deviceStore.value
        await fixture.deviceStore.failReplacements(true)
        #expect(!(await fixture.model.save(id: station.id, name: "New relay", relayURL: "https://new.example")))
        #expect(fixture.model.errorCode == "migrationIncomplete")
        #expect(await fixture.deviceStore.value == before)
        #expect(fixture.model.stations.contains(station))
        #expect(fixture.model.defaultStationID == station.id)
        let staged = try #require(fixture.model.stations.first { $0.relayURL == "https://new.example" })
        await fixture.deviceStore.failReplacements(false)
        #expect(await fixture.model.save(id: station.id, name: "New relay", relayURL: "https://new.example"))
        #expect(fixture.model.stations == [staged])
        #expect(fixture.model.defaultStationID == staged.id)
        #expect(fixture.devices.snapshot?.devices.allSatisfy { $0.relayURL == staged.relayURL } == true)
    }

    @Test func failedCatalogStagingLeavesOldCatalogAndDevicesIntactForRetry() async throws {
        let fixture = try await fixture()
        let station = try #require(fixture.model.stations.first)
        let beforeCatalog = await fixture.catalogStore.value, beforeDevices = await fixture.deviceStore.value
        await fixture.catalogStore.failReplacements(true)
        #expect(!(await fixture.model.save(id: station.id, name: "New relay", relayURL: "https://new.example")))
        #expect(fixture.model.errorCode != nil)
        #expect(await fixture.catalogStore.value == beforeCatalog)
        #expect(await fixture.deviceStore.value == beforeDevices)
        #expect(fixture.model.stations == [station])
        await fixture.catalogStore.failReplacements(false)
        #expect(await fixture.model.save(id: station.id, name: "New relay", relayURL: "https://new.example"))
        #expect(fixture.model.stations.count == 1 && fixture.model.stations.first?.relayURL == "https://new.example")
    }

    @Test func deviceAddedDuringPublicProbeRejectsMigrationOfAnOutdatedAffectedList() async throws {
        let fixture = try await fixture()
        let station = try #require(fixture.model.stations.first)
        let beforeCatalog = await fixture.catalogStore.value
        await fixture.probe.blockNextCheck()
        let saving = Task { await fixture.model.save(id: station.id, name: "New relay", relayURL: "https://new.example") }
        await fixture.probe.waitForBlockedCheck()
        let peer = P256.Signing.PrivateKey().publicKey.derRepresentation
        _ = try await fixture.devices.registry.addDevice(name: "Added during check", relayURL: "https://old.example",
            peerSPKI: peer, verifiedPeerDeviceID: CompanionDeviceRegistry.peerDeviceID(forSPKI: peer))
        let deviceStateWithNewPeer = await fixture.deviceStore.value
        await fixture.probe.releaseCheck()
        #expect(!(await saving.value))
        #expect(fixture.model.errorCode != nil)
        #expect(await fixture.catalogStore.value == beforeCatalog)
        #expect(await fixture.deviceStore.value == deviceStateWithNewPeer)
        #expect(fixture.devices.snapshot?.devices.count == 3)
        #expect(fixture.devices.snapshot?.devices.allSatisfy { $0.relayURL == "https://old.example" } == true)
        #expect(await fixture.connection.opened.isEmpty)
    }

    private func fixture(refreshCatalog: Bool = true) async throws -> RelayModelFixture {
        let deviceStore = RelayModelMemoryPersistence(), catalogStore = RelayModelMemoryPersistence()
        let registry = CompanionDeviceRegistry(persistence: deviceStore)
        _ = try await registry.initialize()
        for index in 0..<2 {
            let peer = P256.Signing.PrivateKey().publicKey.derRepresentation
            _ = try await registry.addDevice(name: "Windows \(index)", relayURL: "https://old.example",
                peerSPKI: peer, allowWindows10TLS12: index == 1,
                verifiedPeerDeviceID: CompanionDeviceRegistry.peerDeviceID(forSPKI: peer))
        }
        let connection = RelayModelConnectionStub(), probe = RelayModelProbeStub()
        let devices = CompanionDevicesModel(registry: registry, makeConnection: { connection })
        await devices.refresh()
        let model = RelayStationsModel(registry: RelayStationRegistry(persistence: catalogStore), devices: devices, probe: probe)
        if refreshCatalog { await model.refresh() }
        return RelayModelFixture(model: model, devices: devices, deviceStore: deviceStore,
            catalogStore: catalogStore, connection: connection, probe: probe)
    }
}

@MainActor private struct RelayModelFixture {
    let model: RelayStationsModel
    let devices: CompanionDevicesModel
    let deviceStore, catalogStore: RelayModelMemoryPersistence
    let connection: RelayModelConnectionStub
    let probe: RelayModelProbeStub
}

private actor RelayModelMemoryPersistence: CompanionDevicePersistence {
    private(set) var value: String?
    private(set) var creates = 0, replacements = 0
    private var failReplace = false

    func load() -> String? { value }
    func create(_ value: String) throws {
        guard self.value == nil else { throw CompanionDevicePersistenceError.alreadyExists }
        self.value = value; creates += 1
    }
    func replace(expected: String, with value: String) throws {
        replacements += 1
        guard !failReplace, self.value == expected else { throw CompanionDevicePersistenceError.conflict }
        self.value = value
    }
    func failReplacements(_ value: Bool) { failReplace = value }
}

private actor RelayModelProbeStub: RelayStationProbing {
    private(set) var origins: [String] = []
    private var failure: RelayStationProbeError?
    private var blockNext = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func setFailure(_ failure: RelayStationProbeError?) { self.failure = failure }
    func blockNextCheck() { blockNext = true }
    func waitForBlockedCheck() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseCheck() { continuation?.resume(); continuation = nil }
    func check(origin: String) async throws -> RelayStationProbeResult {
        origins.append(origin)
        if blockNext {
            blockNext = false
            await withCheckedContinuation {
                continuation = $0
                started?.resume(); started = nil
            }
        }
        if let failure { throw failure }
        return RelayStationProbeResult(checkedAt: Date(), latencyMilliseconds: 3)
    }
}

nonisolated private struct RelayModelOpenedPeer: Sendable {
    let origin: String
    let peerSPKI: Data
}

private actor RelayModelConnectionStub: CompanionDeviceConnection {
    private(set) var opened: [RelayModelOpenedPeer] = []
    private(set) var invalidations = 0
    private var rejectedPeer: Data?
    func reject(peerSPKI: Data) { rejectedPeer = peerSPKI }
    func open(_ configuration: CompanionIPCOpen) throws -> CompanionIPCState {
        try configuration.validate()
        opened.append(RelayModelOpenedPeer(origin: configuration.relayURL, peerSPKI: configuration.peerSPKI))
        guard configuration.peerSPKI != rejectedPeer else { throw CompanionClientError.invalidReply }
        return CompanionIPCState(phase: "connected", sessionID: UUID().uuidString)
    }
    func invalidate() { invalidations += 1 }
    func status(grantID: UUID) throws -> CompanionControlStatus { throw CompanionClientError.invalidReply }
    func submit(_ request: CompanionIPCSubmit) throws -> CompanionJobReceipt { throw CompanionClientError.invalidReply }
    func job(grantID: UUID, jobID: UUID) throws -> CompanionJobReceipt { throw CompanionClientError.invalidReply }
    func cancel(grantID: UUID, jobID: UUID) throws -> CompanionJobReceipt { throw CompanionClientError.invalidReply }
    func output(_ request: CompanionIPCOutput) throws -> CompanionJobOutput { throw CompanionClientError.invalidReply }
}
#endif
