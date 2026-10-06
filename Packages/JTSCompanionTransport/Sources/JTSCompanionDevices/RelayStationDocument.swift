import Foundation
import JTSCompanionIPC

struct RelayStationDocument: Codable {
    let schemaVersion: Int
    var stations: [RelayStation]
    var defaultStationID: UUID?

    static var empty: Self { Self(schemaVersion: 1, stations: [], defaultStationID: nil) }
    var snapshot: RelayStationSnapshot {
        RelayStationSnapshot(stations: stations, defaultStationID: defaultStationID)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, stations, defaultStationID }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(schemaVersion, forKey: .schemaVersion)
        try fields.encode(stations, forKey: .stations)
        try fields.encode(defaultStationID, forKey: .defaultStationID)
    }
}

enum RelayStationCodec {
    static let maximumRecords = 256
    static let maximumBytes = CompanionDeviceCodec.maximumBytes
    private static let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func name(_ value: String) throws -> String {
        do { return try CompanionDeviceCodec.name(value) }
        catch { throw RelayStationError.invalidInput }
    }

    static func origin(_ value: String) throws -> String {
        do { return try CompanionDeviceCodec.origin(value) }
        catch { throw RelayStationError.invalidInput }
    }

    static func encode(_ document: RelayStationDocument) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw RelayStationError.capacityReached }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) throws -> RelayStationDocument {
        do {
            guard !raw.isEmpty, raw.utf8.count <= maximumBytes else { throw RelayStationError.corruptState }
            let data = Data(raw.utf8)
            try StrictCompanionJSON.validate(data, requiredKeys: ["schemaVersion", "stations", "defaultStationID"])
            let document = try JSONDecoder().decode(RelayStationDocument.self, from: data)
            guard document.schemaVersion == 1, document.stations.count <= maximumRecords else {
                throw RelayStationError.corruptState
            }
            var ids = Set<UUID>(), origins = Set<String>()
            for station in document.stations {
                guard station.id != zeroID, ids.insert(station.id).inserted,
                      origins.insert(station.relayURL).inserted,
                      try name(station.name) == station.name,
                      try origin(station.relayURL) == station.relayURL else {
                    throw RelayStationError.corruptState
                }
            }
            guard document.defaultStationID.map(ids.contains) ?? true,
                  try encode(document) == raw else { throw RelayStationError.corruptState }
            return document
        } catch { throw RelayStationError.corruptState }
    }
}
