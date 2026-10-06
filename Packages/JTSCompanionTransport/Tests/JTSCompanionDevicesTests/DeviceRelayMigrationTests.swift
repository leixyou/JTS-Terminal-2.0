import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionDevices

final class DeviceRelayMigrationTests: XCTestCase {
    private func fixture() async throws -> (DeviceTestPersistence, CompanionDeviceRegistry, [CompanionSavedDevice]) {
        let store = DeviceTestPersistence()
        let registry = CompanionDeviceRegistry(persistence: store)
        _ = try await registry.initialize()
        var devices: [CompanionSavedDevice] = []
        for index in 0..<3 {
            let peer = P256.Signing.PrivateKey().publicKey.derRepresentation
            devices.append(try await registry.addDevice(name: "Windows \(index)", relayURL: "https://old.example",
                peerSPKI: peer, allowWindows10TLS12: index == 1,
                verifiedPeerDeviceID: CompanionDeviceRegistry.peerDeviceID(forSPKI: peer)))
        }
        return (store, registry, devices)
    }

    private func expect(_ expected: CompanionDeviceError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected safe migration error", file: file, line: line) }
        catch { XCTAssertEqual(error as? CompanionDeviceError, expected, file: file, line: line) }
    }

    func testOneCommitMovesWholeGroupAndPreservesIdentityTrustAndRevokedRecords() async throws {
        let (store, registry, devices) = try await fixture()
        _ = try await registry.revokeDevice(id: devices[2].id)
        let beforeRaw = await store.raw
        let before = try CompanionDeviceCodec.decode(XCTUnwrap(beforeRaw))
        let writes = await store.replacements
        let moved = try await registry.updateRelay(devices: Array(devices.prefix(2)), relayURL: "https://NEW.example:443/")
        let afterRaw = await store.raw
        let after = try CompanionDeviceCodec.decode(XCTUnwrap(afterRaw))
        let finalWrites = await store.replacements
        XCTAssertEqual(finalWrites, writes + 1)
        XCTAssertEqual(after.identity, before.identity)
        XCTAssertEqual(moved.devices.count, 3)
        for index in 0..<2 {
            let old = before.devices[index], current = after.devices[index]
            XCTAssertEqual(current.id, old.id); XCTAssertEqual(current.name, old.name)
            XCTAssertEqual(current.peerDeviceID, old.peerDeviceID); XCTAssertEqual(current.peerSPKI, old.peerSPKI)
            XCTAssertEqual(current.allowWindows10TLS12, old.allowWindows10TLS12)
            XCTAssertEqual(current.confirmedAt, old.confirmedAt); XCTAssertEqual(current.revokedAt, old.revokedAt)
            XCTAssertEqual(current.relayURL, "https://new.example")
            let configuration = try await registry.openConfiguration(deviceID: current.id)
            XCTAssertEqual(configuration.relayURL, "https://new.example")
            XCTAssertEqual(configuration.privateKey, before.identity.privateKey)
        }
        XCTAssertEqual(after.devices[2], before.devices[2])
        XCTAssertNotNil(after.devices[2].revokedAt)
        let reloaded = try await CompanionDeviceRegistry(persistence: store).snapshot()
        XCTAssertEqual(reloaded, moved)
    }

    func testOneStaleMemberRejectsWholeGroupWithoutPartialWrite() async throws {
        let (store, registry, devices) = try await fixture()
        _ = try await registry.updateRelay(devices: [devices[1]], relayURL: "https://changed.example")
        let before = await store.raw, writes = await store.replacements
        await expect(.storageConflict) {
            _ = try await registry.updateRelay(devices: Array(devices.prefix(2)), relayURL: "https://new.example")
        }
        let after = await store.raw, finalWrites = await store.replacements
        XCTAssertEqual(after, before); XCTAssertEqual(finalWrites, writes)
        let snapshot = try await registry.snapshot()
        let current = try XCTUnwrap(snapshot)
        XCTAssertEqual(current.devices[0].relayURL, "https://old.example")
        XCTAssertEqual(current.devices[1].relayURL, "https://changed.example")
    }

    func testOneRevokedMemberRejectsWholeGroupWithoutUndoingRevocation() async throws {
        let (store, registry, devices) = try await fixture()
        _ = try await registry.revokeDevice(id: devices[1].id)
        let before = await store.raw, writes = await store.replacements
        await expect(.storageConflict) {
            _ = try await registry.updateRelay(devices: Array(devices.prefix(2)), relayURL: "https://new.example")
        }
        let after = await store.raw, finalWrites = await store.replacements
        XCTAssertEqual(after, before); XCTAssertEqual(finalWrites, writes)
        let snapshot = try await registry.snapshot()
        let current = try XCTUnwrap(snapshot)
        XCTAssertNotNil(current.devices[1].revokedAt)
        XCTAssertTrue(current.devices.allSatisfy { $0.relayURL == "https://old.example" })
    }

    func testCASFailurePreservesOldRoutesAndSupportsExplicitRetry() async throws {
        let (store, registry, devices) = try await fixture()
        let before = await store.raw, writes = await store.replacements
        await store.failReplace(CompanionDevicePersistenceError.conflict)
        await expect(.storageConflict) {
            _ = try await registry.updateRelay(devices: devices, relayURL: "https://new.example")
        }
        let after = await store.raw, finalWrites = await store.replacements
        XCTAssertEqual(after, before); XCTAssertEqual(finalWrites, writes + 1)
        let snapshot = try await registry.snapshot()
        XCTAssertEqual(snapshot?.devices, devices)
        await store.failReplace(nil)
        let retried = try await registry.updateRelay(devices: devices, relayURL: "https://new.example")
        XCTAssertTrue(retried.devices.allSatisfy { $0.relayURL == "https://new.example" })
    }

    func testInvalidMigrationSelectionAndOriginNeverWrite() async throws {
        let (store, registry, devices) = try await fixture()
        let before = await store.raw, writes = await store.replacements
        for selection in [[], [devices[0], devices[0]]] {
            await expect(.invalidInput) { _ = try await registry.updateRelay(devices: selection, relayURL: "https://new.example") }
        }
        await expect(.invalidInput) { _ = try await registry.updateRelay(devices: devices, relayURL: "https://new.example/path") }
        let after = await store.raw, finalWrites = await store.replacements
        XCTAssertEqual(after, before); XCTAssertEqual(finalWrites, writes)
    }
}
