import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionDevices

final class DeviceDocumentTests: XCTestCase {
    private func initialized() async throws -> (DeviceTestPersistence, CompanionDeviceRegistry, String) {
        let store = DeviceTestPersistence()
        let registry = CompanionDeviceRegistry(persistence: store)
        _ = try await registry.initialize()
        let raw = await store.raw
        return (store, registry, try XCTUnwrap(raw))
    }
    private func device(revoked: Bool = false) throws -> StoredDevice {
        let spki = P256.Signing.PrivateKey().publicKey.derRepresentation
        return StoredDevice(id: UUID(), name: "Lab", relayURL: "https://relay.example",
            peerDeviceID: try CompanionDeviceRegistry.peerDeviceID(forSPKI: spki), peerSPKI: spki,
            allowWindows10TLS12: false, confirmedAt: 1000, revokedAt: revoked ? 1001 : nil)
    }
    private func expect(_ expected: CompanionDeviceError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected safe registry error", file: file, line: line) }
        catch { XCTAssertEqual(error as? CompanionDeviceError, expected, file: file, line: line) }
    }

    func testDocumentRejectsUnknownVersionKeysDuplicateKeysAndInvalidKeyBinding() async throws {
        let (_, _, raw) = try await initialized()
        let valid = try CompanionDeviceCodec.decode(raw)
        XCTAssertEqual(try CompanionDeviceCodec.encode(valid), raw)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        var future = original; future["schemaVersion"] = 2
        var extra = original; extra["grants"] = []
        var nested = original
        var identity = try XCTUnwrap(nested["identity"] as? [String: Any]); identity["systemShell"] = true
        nested["identity"] = identity
        var mismatch = original
        identity = try XCTUnwrap(original["identity"] as? [String: Any])
        identity["privateKey"] = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        mismatch["identity"] = identity
        for object in [future, extra, nested, mismatch] {
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertThrowsError(try CompanionDeviceCodec.decode(String(decoding: bytes, as: UTF8.self)))
        }
        for invalid in [" " + raw, raw.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
                        String(repeating: "x", count: CompanionDeviceCodec.maximumBytes + 1)] {
            XCTAssertThrowsError(try CompanionDeviceCodec.decode(invalid))
        }
    }

    func testCorruptDocumentThenMissingStateCannotBeInitializedOver() async throws {
        let store = DeviceTestPersistence("{}")
        let actual = CompanionDeviceRegistry(persistence: store)
        await expect(.corruptState) { _ = try await actual.initialize() }
        await store.put(nil)
        await expect(.missingState) { _ = try await actual.initialize() }
        let creates = await store.creates
        XCTAssertEqual(creates, 0)
    }

    func testRecordLimitIncludesTombstonesAndDuplicatePeersAreCorrupt() async throws {
        let (store, _, raw) = try await initialized()
        var document = try CompanionDeviceCodec.decode(raw)
        document.devices = try (0..<256).map { try device(revoked: $0 % 2 == 0) }
        let full = try CompanionDeviceCodec.encode(document)
        XCTAssertEqual(try CompanionDeviceCodec.decode(full).devices.count, 256)
        await store.put(full)
        let registry = CompanionDeviceRegistry(persistence: store), extra = try device()
        await expect(.capacityReached) {
            _ = try await registry.addDevice(name: extra.name, relayURL: extra.relayURL, peerSPKI: extra.peerSPKI,
                verifiedPeerDeviceID: extra.peerDeviceID)
        }
        document.devices = [extra, extra]
        XCTAssertThrowsError(try CompanionDeviceCodec.decode(CompanionDeviceCodec.encode(document)))
        document.devices = try (0..<257).map { _ in try device() }
        XCTAssertThrowsError(try CompanionDeviceCodec.decode(CompanionDeviceCodec.encode(document)))
    }

    func testOpenReloadsExternalRevocationAndDoesNotAcceptTombstoneRollback() async throws {
        let (store, registry, _) = try await initialized()
        let peer = try device()
        let saved = try await registry.addDevice(name: peer.name, relayURL: peer.relayURL,
            peerSPKI: peer.peerSPKI, verifiedPeerDeviceID: peer.peerDeviceID)
        let before = await store.raw
        _ = try await CompanionDeviceRegistry(persistence: store).revokeDevice(id: saved.id)
        await expect(.deviceRevoked) { _ = try await registry.openConfiguration(deviceID: saved.id) }
        await store.put(before)
        await expect(.corruptState) { _ = try await registry.snapshot() }
    }

    func testCreateCollisionDoesNotRetryAndAllUnrecognizedStorageErrorsAreSanitized() async throws {
        let store = DeviceTestPersistence()
        let registry = CompanionDeviceRegistry(persistence: store)
        await store.failCreate(CompanionDevicePersistenceError.alreadyExists)
        await expect(.storageConflict) { _ = try await registry.initialize() }
        let creates = await store.creates
        XCTAssertEqual(creates, 1)
        await store.failCreate(PrivateTestError())
        await expect(.storageUnavailable) { _ = try await registry.initialize() }
        let raw = await store.raw
        XCTAssertNil(raw)
    }
}
