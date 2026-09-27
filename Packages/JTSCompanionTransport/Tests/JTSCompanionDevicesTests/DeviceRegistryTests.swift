import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionDevices

final class DeviceRegistryTests: XCTestCase {
    private func equal<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func nilValue<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value, file: file, line: line)
    }
    private func peer() -> (spki: Data, id: String) {
        let spki = P256.Signing.PrivateKey().publicKey.derRepresentation
        return (spki, SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined())
    }
    private func add(_ registry: CompanionDeviceRegistry) async throws -> CompanionSavedDevice {
        let peer = peer()
        return try await registry.addDevice(name: " Windows lab ", relayURL: "https://RELAY.example:443/",
            peerSPKI: peer.spki, verifiedPeerDeviceID: peer.id)
    }
    private func expect(_ expected: CompanionDeviceError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected safe registry error", file: file, line: line) }
        catch { XCTAssertEqual(error as? CompanionDeviceError, expected, file: file, line: line) }
    }

    func testReadDoesNotCreateIdentityAndExplicitInitializeIsCreateOnly() async throws {
        let store = DeviceTestPersistence()
        let actual = CompanionDeviceRegistry(persistence: store)
        nilValue(try await actual.snapshot())
        let snapshot = try await actual.initialize()
        XCTAssertEqual(snapshot.deviceID, try CompanionDeviceRegistry.peerDeviceID(forSPKI: snapshot.publicSPKI))
        XCTAssertEqual(snapshot.devices, [])
        equal(await store.creates, 1)
        let loaded = try await CompanionDeviceRegistry(persistence: store).snapshot()
        XCTAssertEqual(loaded, snapshot)
        await expect(.alreadyInitialized) { _ = try await actual.initialize() }
        equal(await store.creates, 1)
    }

    func testConfirmedLocalRecordBuildsConfigurationWithoutAnyGrantAndRevocationPersists() async throws {
        let store = DeviceTestPersistence()
        let actual = CompanionDeviceRegistry(persistence: store)
        await expect(.notInitialized) { _ = try await self.add(actual) }
        let identity = try await actual.initialize()
        let device = try await add(actual)
        XCTAssertEqual(device.name, "Windows lab"); XCTAssertEqual(device.relayURL, "https://relay.example")
        XCTAssertNil(device.revokedAt); XCTAssertFalse(device.allowWindows10TLS12)
        let configuration = try await actual.openConfiguration(deviceID: device.id)
        XCTAssertEqual(try P256.Signing.PrivateKey(rawRepresentation: configuration.privateKey).publicKey.derRepresentation, identity.publicSPKI)
        XCTAssertEqual(configuration.peerSPKI, device.peerSPKI)
        let revoked = try await actual.revokeDevice(id: device.id)
        XCTAssertNotNil(revoked.devices.first?.revokedAt)
        let fresh = CompanionDeviceRegistry(persistence: store)
        await expect(.deviceRevoked) { _ = try await fresh.openConfiguration(deviceID: device.id) }
        await expect(.deviceAlreadyKnown) {
            _ = try await fresh.addDevice(name: "again", relayURL: device.relayURL, peerSPKI: device.peerSPKI,
                verifiedPeerDeviceID: device.peerDeviceID)
        }
        let writes = await store.replacements
        _ = try await fresh.revokeDevice(id: device.id)
        equal(await store.replacements, writes)
    }

    func testWrongPeerIDNoncanonicalDERAndUnsafeOriginAreRejectedWithoutWriting() async throws {
        let store = DeviceTestPersistence(), peer = peer()
        let registry = CompanionDeviceRegistry(persistence: store)
        _ = try await registry.initialize()
        await expect(.invalidInput) {
            _ = try await registry.addDevice(name: "lab", relayURL: "https://relay.example", peerSPKI: peer.spki,
                verifiedPeerDeviceID: String(repeating: "a", count: 64))
        }
        for spki in [Data(), peer.spki + Data([0]), Data(repeating: 1, count: 513)] {
            XCTAssertThrowsError(try CompanionDeviceRegistry.peerDeviceID(forSPKI: spki))
        }
        for origin in ["http://relay.example", "https://user:secret@relay.example", "https://relay.example/path", "https://relay.example?q=1"] {
            await expect(.invalidInput) {
                _ = try await registry.addDevice(name: "lab", relayURL: origin, peerSPKI: peer.spki, verifiedPeerDeviceID: peer.id)
            }
        }
        equal(await store.replacements, 0)
    }

    func testMissingOrChangedIdentityNeverRegenerates() async throws {
        let store = DeviceTestPersistence()
        let actual = CompanionDeviceRegistry(persistence: store)
        _ = try await actual.initialize()
        await store.put(nil)
        await expect(.missingState) { _ = try await actual.snapshot() }
        await expect(.missingState) { _ = try await actual.initialize() }
        let otherStore = DeviceTestPersistence()
        _ = try await CompanionDeviceRegistry(persistence: otherStore).initialize()
        await store.put(await otherStore.raw)
        await expect(.identityChanged) { _ = try await actual.snapshot() }
        equal(await store.creates, 1)
    }

    func testPersistenceFailuresAreSanitizedAndCASIsNotRetried() async throws {
        let store = DeviceTestPersistence()
        let actual = CompanionDeviceRegistry(persistence: store)
        _ = try await actual.initialize()
        let before = await store.raw
        await store.failReplace(CompanionDevicePersistenceError.conflict)
        await expect(.storageConflict) { _ = try await self.add(actual) }
        equal(await store.replacements, 1); equal(await store.raw, before)
        await store.failLoad(PrivateTestError())
        await expect(.storageUnavailable) { _ = try await actual.snapshot() }
        XCTAssertFalse(String(reflecting: CompanionDeviceError.storageUnavailable).contains("PRIVATE_PASSWORD"))
    }

    func testSuspendedPersistenceDoesNotAllowActorReentrantMutation() async throws {
        let store = DeviceTestPersistence()
        let actual = CompanionDeviceRegistry(persistence: store)
        await store.holdLoad()
        let pending = Task { try await actual.snapshot() }
        await store.waitForHeldLoad()
        await expect(.operationInProgress) { _ = try await actual.initialize() }
        await store.releaseLoad()
        nilValue(try await pending.value)
        equal(await store.creates, 0)
    }

    func testSnapshotAndDocumentDescriptionsNeverExposePrivateKey() async throws {
        let store = DeviceTestPersistence()
        let registry = CompanionDeviceRegistry(persistence: store)
        let snapshot = try await registry.initialize()
        let raw = await store.raw
        let document = try CompanionDeviceCodec.decode(XCTUnwrap(raw))
        let secret = document.identity.privateKey.base64EncodedString()
        for value in [String(describing: snapshot), String(reflecting: snapshot), String(reflecting: document), String(reflecting: document.identity)] {
            XCTAssertFalse(value.contains(secret))
        }
        XCTAssertFalse(Mirror(reflecting: snapshot).children.contains { $0.label == "privateKey" })
    }
}
