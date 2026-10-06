import Foundation

/// Persists a separate relay catalog. The adapter must use its own encrypted vault account.
/// Every operation reloads durable state, and never overwrites corrupt or conflicting data.
public actor RelayStationRegistry {
    private let persistence: any CompanionDevicePersistence
    private var observedDocument = false
    private var busy = false

    public init(persistence: any CompanionDevicePersistence) { self.persistence = persistence }

    public nonisolated static func normalizedOrigin(_ value: String) throws -> String {
        try RelayStationCodec.origin(value)
    }

    public nonisolated static func normalizedName(_ value: String) throws -> String {
        try RelayStationCodec.name(value)
    }

    public func snapshot() async throws -> RelayStationSnapshot {
        try begin(); defer { busy = false }
        return try await load().document.snapshot
    }

    @discardableResult
    public func save(id: UUID? = nil, name: String, relayURL: String) async throws -> RelayStation {
        try begin(); defer { busy = false }
        var stored = try await load()
        let name = try Self.normalizedName(name), origin = try Self.normalizedOrigin(relayURL)
        let index: Int?
        if let id {
            guard let found = stored.document.stations.firstIndex(where: { $0.id == id }) else {
                throw RelayStationError.stationNotFound
            }
            index = found
        } else {
            guard stored.document.stations.count < RelayStationCodec.maximumRecords else {
                throw RelayStationError.capacityReached
            }
            index = nil
        }
        guard !stored.document.stations.contains(where: { $0.relayURL == origin && $0.id != id }) else {
            throw RelayStationError.stationAlreadyKnown
        }
        let station = RelayStation(id: id ?? UUID(), name: name, relayURL: origin)
        if let index {
            guard stored.document.stations[index] != station else { return station }
            stored.document.stations[index] = station
        } else {
            stored.document.stations.append(station)
        }
        try await persist(stored.document, expected: stored.raw)
        return station
    }

    public func remove(id: UUID) async throws {
        try begin(); defer { busy = false }
        var stored = try await load()
        guard let index = stored.document.stations.firstIndex(where: { $0.id == id }) else {
            throw RelayStationError.stationNotFound
        }
        stored.document.stations.remove(at: index)
        if stored.document.defaultStationID == id { stored.document.defaultStationID = nil }
        try await persist(stored.document, expected: stored.raw)
    }

    /// Only establishes the choice for future devices; existing devices are never changed here.
    public func setDefault(id: UUID?) async throws {
        try begin(); defer { busy = false }
        var stored = try await load()
        guard id == nil || stored.document.stations.contains(where: { $0.id == id }) else {
            throw RelayStationError.stationNotFound
        }
        guard stored.document.defaultStationID != id else { return }
        stored.document.defaultStationID = id
        try await persist(stored.document, expected: stored.raw)
    }

    /// Imports existing device origins atomically without replacing names or changing the default.
    public func importOrigins(_ values: [String]) async throws {
        try begin(); defer { busy = false }
        var stored = try await load()
        var origins = Set(stored.document.stations.map(\.relayURL))
        let initialCount = stored.document.stations.count
        for value in values {
            let origin = try Self.normalizedOrigin(value)
            guard origins.insert(origin).inserted else { continue }
            guard stored.document.stations.count < RelayStationCodec.maximumRecords else {
                throw RelayStationError.capacityReached
            }
            let host = URLComponents(string: origin)?.host ?? ""
            let name = (try? Self.normalizedName(host)) ?? "中转站"
            stored.document.stations.append(RelayStation(id: UUID(), name: name, relayURL: origin))
        }
        guard stored.document.stations.count != initialCount else { return }
        try await persist(stored.document, expected: stored.raw)
    }

    private func begin() throws {
        guard !busy else { throw RelayStationError.operationInProgress }
        busy = true
    }

    private func load() async throws -> (raw: String?, document: RelayStationDocument) {
        let raw: String?
        do { raw = try await persistence.load() } catch { throw storageError(error) }
        guard let raw else {
            guard !observedDocument else { throw RelayStationError.missingState }
            return (nil, .empty)
        }
        observedDocument = true
        return (raw, try RelayStationCodec.decode(raw))
    }

    private func persist(_ document: RelayStationDocument, expected: String?) async throws {
        let raw = try RelayStationCodec.encode(document)
        do {
            if let expected { try await persistence.replace(expected: expected, with: raw) }
            else { try await persistence.create(raw) }
        } catch { throw storageError(error) }
        observedDocument = true
    }

    private func storageError(_ error: Error) -> RelayStationError {
        if let error = error as? CompanionDevicePersistenceError, error == .conflict || error == .alreadyExists {
            return .storageConflict
        }
        return .storageUnavailable
    }
}
