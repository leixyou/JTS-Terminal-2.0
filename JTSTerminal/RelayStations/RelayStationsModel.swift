#if ENABLE_RDP_2
import Foundation
import Observation
import JTSCompanionDevices

@Observable @MainActor
final class RelayStationsModel {
    static let shared = RelayStationsModel(registry: RelayStationRegistry(persistence:
        CompanionVaultPersistence(account: "jts.relay-stations.v1")), devices: .shared)

    private(set) var stations: [RelayStation] = []
    private(set) var defaultStationID: UUID?
    private(set) var devices: [CompanionSavedDevice] = []
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var errorCode: String?
    private(set) var probes: [String: RelayStationProbeResult] = [:]
    private(set) var probeErrors: [String: String] = [:]
    private let registry: RelayStationRegistry
    private let deviceModel: CompanionDevicesModel
    private let probe: any RelayStationProbing

    init(registry: RelayStationRegistry, devices: CompanionDevicesModel,
         probe: any RelayStationProbing = RelayStationProbe()) {
        self.registry = registry; deviceModel = devices; self.probe = probe
    }

    var defaultOrigin: String? { stations.first { $0.id == defaultStationID }?.relayURL }

    func affectedDevices(origin: String) -> [CompanionSavedDevice] {
        devices.filter { $0.revokedAt == nil && $0.relayURL == origin }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; errorCode = nil
        defer { busy = false }
        do { try await loadState() }
        catch { loaded = false; errorCode = Self.code(error) }
    }

    private func loadState() async throws {
        let snapshot = try await deviceModel.mcpSnapshot()
        devices = snapshot?.devices ?? []
        try await registry.importOrigins(devices.filter { $0.revokedAt == nil }.map(\.relayURL))
        try await loadCatalog()
        loaded = true
    }

    private func loadCatalog() async throws {
        let catalog = try await registry.snapshot()
        stations = catalog.stations; defaultStationID = catalog.defaultStationID
    }

    /// Imports a public bundle's explicit origin without substituting the user's default.
    func include(origin: String) async -> Bool {
        guard !busy else { return false }
        busy = true; errorCode = nil
        defer { busy = false }
        do {
            try await registry.importOrigins([origin])
            try await loadCatalog(); return true
        } catch { errorCode = Self.code(error); return false }
    }

    func save(id: UUID?, name: String, relayURL: String) async -> Bool {
        guard !busy else { return false }
        busy = true; errorCode = nil
        defer { busy = false }
        do {
            let origin = try RelayStationRegistry.normalizedOrigin(relayURL)
            let name = try RelayStationRegistry.normalizedName(name)
            let displayedStation = stations.first { $0.id == id }
            let displayedDevices = displayedStation.map { affectedDevices(origin: $0.relayURL) } ?? []
            try await loadState()
            let previous = stations.first { $0.id == id }
            if id != nil && previous == nil { throw RelayStationError.stationNotFound }
            if let previous {
                guard previous == displayedStation,
                      affectedDevices(origin: previous.relayURL) == displayedDevices else {
                    throw RelayStationError.storageConflict
                }
            }
            if previous?.relayURL == origin {
                _ = try await registry.save(id: id, name: name, relayURL: origin)
            } else {
                try await runProbe(origin)
                let affected = previous.map { affectedDevices(origin: $0.relayURL) } ?? []
                if let previous, !affected.isEmpty {
                    return await migrate(previous: previous, name: name, origin: origin, affected: affected)
                }
                if let previous {
                    try await deviceModel.moveRelay(devices: [], to: origin, replacingOrigin: previous.relayURL) {
                        _ = try await self.registry.save(id: id, name: name, relayURL: origin)
                    }
                } else {
                    _ = try await registry.save(id: nil, name: name, relayURL: origin)
                }
            }
            try await loadCatalog(); return true
        } catch { errorCode = Self.code(error); return false }
    }

    private func migrate(previous: RelayStation, name: String, origin: String,
                         affected: [CompanionSavedDevice]) async -> Bool {
        var destination: RelayStation?
        var deviceChangeCommitted = false
        do {
            let wasDefault = defaultStationID == previous.id
            try await deviceModel.moveRelay(devices: affected, to: origin, replacingOrigin: previous.relayURL) {
                // Retain both addresses until the atomic device update commits. A crash or
                // failed write leaves a usable old record and an independently usable new one.
                if let staged = self.stations.first(where: { $0.relayURL == origin }) {
                    guard staged.name == name else { throw RelayStationError.stationAlreadyKnown }
                    destination = staged
                } else {
                    destination = try await self.registry.save(id: nil, name: name, relayURL: origin)
                }
            }
            deviceChangeCommitted = true
            try await deviceModel.moveRelay(devices: [], to: origin, replacingOrigin: previous.relayURL) {
                if wasDefault { try await self.registry.setDefault(id: destination?.id) }
                try await self.registry.remove(id: previous.id)
            }
            try await loadState()
            return true
        } catch {
            // Recovery is explicit: never roll a successfully verified route back over a
            // concurrent change, nor hide a partially completed catalog housekeeping step.
            errorCode = deviceChangeCommitted ? "cleanupIncomplete"
                : destination != nil ? "migrationIncomplete" : "deviceVerificationFailed"
            try? await loadState()
            return false
        }
    }

    func remove(id: UUID) async {
        guard !busy else { return }
        busy = true; errorCode = nil
        defer { busy = false }
        do {
            try await loadState()
            guard let station = stations.first(where: { $0.id == id }) else { throw RelayStationError.stationNotFound }
            guard affectedDevices(origin: station.relayURL).isEmpty else {
                errorCode = "stationInUse"; return
            }
            try await deviceModel.moveRelay(devices: [], to: station.relayURL, replacingOrigin: station.relayURL) {
                try await self.registry.remove(id: id)
            }
            try await loadCatalog()
        } catch { errorCode = Self.code(error) }
    }

    func moveDevice(id: UUID, to origin: String) async -> Bool {
        guard !busy else { return false }
        busy = true; errorCode = nil
        defer { busy = false }
        do {
            try await loadState()
            guard stations.contains(where: { $0.relayURL == origin }),
                  let device = devices.first(where: { $0.id == id && $0.revokedAt == nil }) else {
                throw RelayStationError.stationNotFound
            }
            try await runProbe(origin)
            try await deviceModel.moveRelay(devices: [device], to: origin, prepareCatalog: {})
            try await loadState(); return true
        } catch { errorCode = "deviceVerificationFailed"; return false }
    }

    func setDefault(id: UUID?) async {
        guard !busy else { return }
        busy = true; errorCode = nil
        defer { busy = false }
        do { try await registry.setDefault(id: id); try await loadCatalog() }
        catch { errorCode = Self.code(error) }
    }

    func check(origin: String) async -> Bool {
        guard !busy else { return false }
        busy = true; errorCode = nil
        defer { busy = false }
        do { try await runProbe(origin); return true }
        catch { errorCode = Self.code(error); return false }
    }

    private func runProbe(_ origin: String) async throws {
        probes[origin] = nil; probeErrors[origin] = nil
        do { probes[origin] = try await probe.check(origin: origin) }
        catch { probeErrors[origin] = Self.code(error); throw error }
    }

    private static func code(_ error: Error) -> String {
        if let value = error as? RelayStationError { return value.rawValue }
        if let value = error as? RelayStationProbeError { return value.rawValue }
        if let value = error as? CompanionDeviceError { return value.rawValue }
        return "storageUnavailable"
    }
}
#endif
