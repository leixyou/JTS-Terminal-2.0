import Foundation
import XCTest
@testable import JTSCompanionDevices

final class RelayStationRegistryTests: XCTestCase {
    private func equal<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func expect(_ expected: RelayStationError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected safe catalog error", file: file, line: line) }
        catch { XCTAssertEqual(error as? RelayStationError, expected, file: file, line: line) }
    }

    func testCatalogCanBeCreatedWithoutDeviceIdentityAndReadDoesNotWrite() async throws {
        let store = DeviceTestPersistence()
        let registry = RelayStationRegistry(persistence: store)
        equal(try await registry.snapshot(), RelayStationSnapshot(stations: [], defaultStationID: nil))
        try await registry.setDefault(id: nil)
        try await registry.importOrigins([])
        equal(await store.creates, 0)
        let station = try await registry.save(name: " Lab relay ", relayURL: "https://RELAY.example:443/")
        XCTAssertEqual(station.name, "Lab relay")
        XCTAssertEqual(station.relayURL, "https://relay.example")
        equal(await store.creates, 1)
        let snapshot = try await RelayStationRegistry(persistence: store).snapshot()
        XCTAssertEqual(snapshot.stations, [station])
        XCTAssertNil(snapshot.defaultStationID)
        let raw = await store.raw
        XCTAssertFalse(try XCTUnwrap(raw).contains("identity"))
    }

    func testEditingPreservesIdentifierAndDefaultDeletingDefaultClearsSelection() async throws {
        let store = DeviceTestPersistence()
        let registry = RelayStationRegistry(persistence: store)
        let first = try await registry.save(name: "First", relayURL: "https://one.example")
        let second = try await registry.save(name: "Second", relayURL: "https://two.example")
        try await registry.setDefault(id: first.id)
        let edited = try await registry.save(id: first.id, name: "New name", relayURL: "https://new.example:8443/")
        XCTAssertEqual(edited.id, first.id)
        equal(try await registry.snapshot().defaultStationID, first.id)
        let writes = await store.replacements
        _ = try await registry.save(id: first.id, name: edited.name, relayURL: edited.relayURL)
        try await registry.setDefault(id: first.id)
        equal(await store.replacements, writes)
        try await registry.remove(id: first.id)
        let snapshot = try await registry.snapshot()
        XCTAssertEqual(snapshot.stations, [second])
        XCTAssertNil(snapshot.defaultStationID)
    }

    func testImportDeduplicatesCanonicalOriginsAndNeverChangesNamesOrDefault() async throws {
        let store = DeviceTestPersistence()
        let registry = RelayStationRegistry(persistence: store)
        let original = try await registry.save(name: "Custom name", relayURL: "https://one.example")
        try await registry.setDefault(id: original.id)
        try await registry.importOrigins(["https://ONE.example:443/", "https://two.example/", "https://TWO.example:443"])
        let snapshot = try await registry.snapshot()
        XCTAssertEqual(snapshot.stations.count, 2)
        XCTAssertEqual(snapshot.stations.first, original)
        XCTAssertEqual(snapshot.stations.last?.relayURL, "https://two.example")
        XCTAssertEqual(snapshot.defaultStationID, original.id)
        let writes = await store.replacements
        try await registry.importOrigins(["https://one.example", "https://two.example"])
        equal(await store.replacements, writes)

        let empty = RelayStationRegistry(persistence: DeviceTestPersistence())
        try await empty.importOrigins(["https://one.example"])
        let imported = try await empty.snapshot()
        XCTAssertNil(imported.defaultStationID)
    }

    func testInvalidInputDuplicateOriginAndMissingIdentifierNeverWrite() async throws {
        let store = DeviceTestPersistence()
        let registry = RelayStationRegistry(persistence: store)
        let original = try await registry.save(name: "Original", relayURL: "https://one.example")
        let second = try await registry.save(name: "Second", relayURL: "https://two.example")
        let before = await store.raw, writes = await store.replacements
        for name in [" ", "bad\nname", String(repeating: "a", count: 129)] {
            await expect(.invalidInput) { _ = try await registry.save(name: name, relayURL: "https://new.example") }
        }
        for origin in ["http://one.example", "https://user:secret@one.example", "https://one.example/path",
                       "https://one.example?q=1", "https://one.example#fragment"] {
            await expect(.invalidInput) { _ = try await registry.save(name: "Invalid", relayURL: origin) }
        }
        await expect(.stationAlreadyKnown) {
            _ = try await registry.save(name: "Duplicate", relayURL: "https://ONE.example:443/")
        }
        await expect(.stationAlreadyKnown) {
            _ = try await registry.save(id: second.id, name: "Duplicate", relayURL: original.relayURL)
        }
        await expect(.stationNotFound) { _ = try await registry.save(id: UUID(), name: "Missing", relayURL: original.relayURL) }
        await expect(.stationNotFound) { try await registry.setDefault(id: UUID()) }
        await expect(.stationNotFound) { try await registry.remove(id: UUID()) }
        await expect(.invalidInput) { try await registry.importOrigins(["https://new.example", "http://invalid.example"]) }
        equal(await store.raw, before)
        equal(await store.replacements, writes)
    }

    func testCorruptOrDisappearedStateIsNeverOverwritten() async throws {
        let store = DeviceTestPersistence("{}")
        let registry = RelayStationRegistry(persistence: store)
        await expect(.corruptState) { _ = try await registry.save(name: "New", relayURL: "https://new.example") }
        await store.put(nil)
        await expect(.missingState) { _ = try await registry.snapshot() }
        await expect(.missingState) { try await registry.importOrigins(["https://new.example"]) }
        equal(await store.creates, 0)
        equal(await store.replacements, 0)
    }

    func testPersistenceConflictsAreNotRetriedAndErrorsAreSanitized() async throws {
        let store = DeviceTestPersistence()
        let registry = RelayStationRegistry(persistence: store)
        await store.failCreate(CompanionDevicePersistenceError.alreadyExists)
        await expect(.storageConflict) { _ = try await registry.save(name: "New", relayURL: "https://new.example") }
        equal(await store.creates, 1)
        await store.failCreate(nil)
        let station = try await registry.save(name: "New", relayURL: "https://new.example")
        let before = await store.raw
        await store.failReplace(CompanionDevicePersistenceError.conflict)
        await expect(.storageConflict) { try await registry.remove(id: station.id) }
        equal(await store.replacements, 1)
        equal(await store.raw, before)
        await store.failLoad(PrivateTestError())
        await expect(.storageUnavailable) { _ = try await registry.snapshot() }
        XCTAssertFalse(String(reflecting: RelayStationError.storageUnavailable).contains("PRIVATE_PASSWORD"))
    }

    func testExternalCatalogChangesAreReloadedBeforeMutation() async throws {
        let store = DeviceTestPersistence()
        let first = RelayStationRegistry(persistence: store), second = RelayStationRegistry(persistence: store)
        let original = try await first.save(name: "Original", relayURL: "https://one.example")
        _ = try await first.snapshot()
        let added = try await second.save(name: "External", relayURL: "https://two.example")
        try await first.setDefault(id: original.id)
        equal(try await second.snapshot().stations, [original, added])
        try await second.remove(id: original.id)
        equal(try await first.snapshot(), RelayStationSnapshot(stations: [added], defaultStationID: nil))
    }

    func testSuspendedLoadRejectsReentrantMutations() async throws {
        let store = DeviceTestPersistence()
        let registry = RelayStationRegistry(persistence: store)
        await store.holdLoad()
        let pending = Task { try await registry.snapshot() }
        await store.waitForHeldLoad()
        await expect(.operationInProgress) { _ = try await registry.save(name: "New", relayURL: "https://new.example") }
        await store.releaseLoad()
        equal(try await pending.value.stations, [])
        equal(await store.creates, 0)
    }
}
