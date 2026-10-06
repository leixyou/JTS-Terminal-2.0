import Foundation
import XCTest
@testable import JTSCompanionDevices

final class RelayStationDocumentTests: XCTestCase {
    private func station(_ index: Int = 0) -> RelayStation {
        RelayStation(id: UUID(), name: "Relay \(index)", relayURL: "https://relay\(index).example")
    }

    func testCodecRejectsMalformedSchemaDuplicateRecordsAndDanglingDefault() throws {
        let first = station()
        let good = RelayStationDocument(schemaVersion: 1, stations: [first], defaultStationID: first.id)
        let raw = try RelayStationCodec.encode(good)
        XCTAssertEqual(try RelayStationCodec.decode(raw).snapshot, good.snapshot)
        let invalid = [
            RelayStationDocument(schemaVersion: 2, stations: [first], defaultStationID: nil),
            RelayStationDocument(schemaVersion: 1, stations: [first, first], defaultStationID: nil),
            RelayStationDocument(schemaVersion: 1, stations: [first, RelayStation(id: UUID(), name: "Other", relayURL: first.relayURL)], defaultStationID: nil),
            RelayStationDocument(schemaVersion: 1, stations: [first], defaultStationID: UUID()),
            RelayStationDocument(schemaVersion: 1, stations: [RelayStation(id: UUID(), name: " Space ", relayURL: first.relayURL)], defaultStationID: nil),
            RelayStationDocument(schemaVersion: 1, stations: [RelayStation(id: UUID(), name: "Relay", relayURL: "https://RELAY.example:443/")], defaultStationID: nil),
            RelayStationDocument(schemaVersion: 1, stations: [RelayStation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "Relay", relayURL: first.relayURL)], defaultStationID: nil)
        ]
        for document in invalid {
            XCTAssertThrowsError(try RelayStationCodec.decode(RelayStationCodec.encode(document))) { error in
                XCTAssertEqual(error as? RelayStationError, .corruptState)
            }
        }
        let empty = try RelayStationCodec.encode(.empty)
        for invalid in [" " + raw, raw.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
                        raw.replacingOccurrences(of: "\"name\":", with: "\"unknown\":true,\"name\":"),
                        empty.replacingOccurrences(of: "\"defaultStationID\":null,", with: ""),
                        String(repeating: "x", count: RelayStationCodec.maximumBytes + 1)] {
            XCTAssertThrowsError(try RelayStationCodec.decode(invalid))
        }
    }

    func testFullCatalogRejectsAdditionAndImportAtomicallyButAllowsEditing() async throws {
        let full = RelayStationDocument(schemaVersion: 1, stations: (0..<256).map(station), defaultStationID: nil)
        let raw = try RelayStationCodec.encode(full)
        XCTAssertEqual(try RelayStationCodec.decode(raw).stations.count, 256)
        let store = DeviceTestPersistence(raw)
        let registry = RelayStationRegistry(persistence: store)
        do {
            _ = try await registry.save(name: "Overflow", relayURL: "https://overflow.example")
            XCTFail("Expected catalog capacity limit")
        } catch { XCTAssertEqual(error as? RelayStationError, .capacityReached) }
        do {
            try await registry.importOrigins(["https://relay0.example", "https://overflow.example"])
            XCTFail("Expected catalog capacity limit")
        } catch { XCTAssertEqual(error as? RelayStationError, .capacityReached) }
        let unchanged = await store.raw, writes = await store.replacements
        XCTAssertEqual(unchanged, raw); XCTAssertEqual(writes, 0)
        let original = try XCTUnwrap(full.stations.first)
        _ = try await registry.save(id: original.id, name: "Renamed", relayURL: original.relayURL)
        var overfull = full; overfull.stations.append(station(256))
        XCTAssertThrowsError(try RelayStationCodec.decode(RelayStationCodec.encode(overfull)))
    }
}
