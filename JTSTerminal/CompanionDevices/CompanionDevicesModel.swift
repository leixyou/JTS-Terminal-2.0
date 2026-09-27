#if ENABLE_RDP_2
import Foundation
import Observation
import JTSCompanionClient
import JTSCompanionDevices
import JTSCompanionIPC
import JTSRelayEnrollment

@Observable @MainActor
final class CompanionDevicesModel {
    static let windowID = "companion-devices"
    static let shared = CompanionDevicesModel(registry: CompanionDeviceRegistry(persistence: CompanionVaultPersistence()),
        journal: CompanionJobJournal(persistence: CompanionVaultPersistence(account: "jts.companion.jobs.v1.metadata")))

    private(set) var snapshot: CompanionDeviceSnapshot?
    private(set) var loaded = false
    private(set) var selectedID: UUID?
    private(set) var routes: [UUID: CompanionDeviceRoute] = [:]
    private var storeBusy = false
    private var storeError: String?
    private let registry: CompanionDeviceRegistry
    let journal: CompanionJobJournal?
    private let makeConnection: @Sendable () -> any CompanionDeviceConnection
    @ObservationIgnored private var registryLocked = false
    @ObservationIgnored private var registryWaiters: [CheckedContinuation<Void, Never>] = []

    init(registry: CompanionDeviceRegistry, journal: CompanionJobJournal? = nil,
         makeConnection: @escaping @Sendable () -> any CompanionDeviceConnection = { CompanionTransportClient() }) {
        self.registry = registry; self.journal = journal; self.makeConnection = makeConnection
    }

    var selected: CompanionSavedDevice? { snapshot?.devices.first { $0.id == selectedID } }
    var selectedRoute: CompanionDeviceRoute? { selectedID.flatMap { routes[$0] } }
    var busy: Bool { storeBusy || selectedRoute?.busy == true }
    var errorCode: String? { storeError ?? selectedRoute?.errorCode }
    var openedAt: Date? { selectedRoute?.openedAt }
    var verifiedAt: Date? { selectedRoute?.verifiedAt }
    var verifiedGrant: UUID? { selectedRoute?.verifiedGrant }
    var capabilities: [String] { selectedRoute?.capabilities ?? [] }
    var hasRoute: Bool { selectedRoute?.hasRoute == true }
    var canConnect: Bool { loaded && storeError == nil && selected?.revokedAt == nil && selected != nil && !busy }
    var connectedCount: Int { routes.values.filter(\.hasRoute).count }

    func refresh() async {
        guard !storeBusy else { return }
        storeBusy = true; storeError = nil
        defer { storeBusy = false }
        do {
            let current = try await withRegistry { try await registry.snapshot() }
            snapshot = current; loaded = true
            if selectedID == nil { selectedID = current?.devices.first?.id }
            for device in current?.devices ?? [] where routes[device.id] == nil {
                routes[device.id] = CompanionDeviceRoute(deviceID: device.id)
            }
            let trustedIDs = Set((current?.devices ?? []).filter { $0.revokedAt == nil }.map(\.id))
            for (id, route) in routes where !trustedIDs.contains(id) { route.disconnect() }
            if let journal {
                for metadata in try await journal.load() {
                    guard let route = routes[metadata.deviceID], !route.jobs.contains(where: { $0.id == metadata.id }) else { continue }
                    route.jobs.append(CompanionDeviceJob(metadata: metadata))
                }
            }
        } catch { storeFailed(error) }
    }

    func initialize() async {
        guard loaded, snapshot == nil, storeError == nil, !storeBusy else { return }
        storeBusy = true; defer { storeBusy = false }
        do { snapshot = try await withRegistry { try await registry.initialize() } }
        catch { storeFailed(error) }
    }

    func add(name: String, relayURL: String, peerSPKI: Data, compatibility: Bool, verifiedID: String) async -> Bool {
        guard !storeBusy else { return false }
        storeBusy = true; storeError = nil; defer { storeBusy = false }
        do {
            let device = try await withRegistry {
                try await registry.addDevice(name: name, relayURL: relayURL, peerSPKI: peerSPKI,
                    allowWindows10TLS12: compatibility, verifiedPeerDeviceID: verifiedID)
            }
            snapshot = try await withRegistry { try await registry.snapshot() }
            routes[device.id] = CompanionDeviceRoute(deviceID: device.id); selectedID = device.id
            return true
        } catch { storeFailed(error); return false }
    }

    func select(_ id: UUID?) { selectedID = id }
    func disconnect() { selectedRoute?.disconnect() }
    func disconnectAll() { for route in routes.values { route.disconnect() } }

    func revokeSelected() async {
        guard let id = selectedID, !storeBusy else { return }
        routes[id]?.disconnect()
        storeBusy = true; storeError = nil; defer { storeBusy = false }
        do {
            snapshot = try await withRegistry { try await registry.revokeDevice(id: id) }
            NotificationCenter.default.post(name: .jtsCompanionDeviceTrustChanged, object: id)
        }
        catch { storeFailed(error) }
    }

    func connect(deviceID: UUID? = nil, authorize: (() throws -> Void)? = nil) async {
        guard loaded, storeError == nil, !storeBusy, let id = deviceID ?? selectedID,
              snapshot?.devices.contains(where: { $0.id == id && $0.revokedAt == nil }) == true,
              let route = routes[id], !route.hasRoute, let token = route.begin() else { return }
        defer { route.finish(token) }
        let client = makeConnection(); route.connection = client
        do {
            let configuration = try await trustedConfiguration(route, token: token)
            try authorize?()
            let state = try await client.open(configuration)
            _ = try await trustedConfiguration(route, token: token)
            try authorize?()
            try state.validate()
            guard state.phase == "connected" else { throw CompanionClientError.invalidReply }
            route.hasRoute = true; route.openedAt = Date()
        } catch { await client.invalidate(); failed(error, route: route, token: token) }
    }

    func checkGrant(_ text: String, deviceID: UUID? = nil, authorize: (() throws -> Void)? = nil) async {
        guard let id = deviceID ?? selectedID, let route = routes[id], route.hasRoute, let client = route.connection,
              let grant = UUID(uuidString: text), grant != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
              let token = route.begin() else { return }
        route.clearGrant(); defer { route.finish(token) }
        do {
            _ = try await trustedConfiguration(route, token: token)
            try authorize?()
            let status = try await client.status(grantID: grant)
            _ = try await trustedConfiguration(route, token: token)
            try authorize?()
            try status.validate()
            route.verifiedAt = Date(); route.verifiedGrant = grant; route.capabilities = status.capabilities
            route.maximumPayloadBytes = status.maximumPayloadBytes
            route.maximumOutputChunkBytes = status.maximumOutputChunkBytes
        } catch { failed(error, route: route, token: token) }
    }

    /// Re-reads encrypted trust for every independent lane; never exports private material to MCP.
    func relayConfiguration(deviceID: UUID) async throws -> CompanionIPCOpen {
        try await withRegistry { try await registry.openConfiguration(deviceID: deviceID) }
    }

    func enrollmentClient(relayOrigin: String) async throws -> EnrollmentClient {
        try await withRegistry { try await registry.enrollmentClient(relayOrigin: relayOrigin) }
    }

    func mcpSnapshot(createIdentity: Bool = false) async throws -> CompanionDeviceSnapshot? {
        guard !storeBusy else { throw CompanionDeviceError.operationInProgress }
        await refresh()
        guard loaded, storeError == nil else { throw CompanionDeviceError.storageUnavailable }
        if createIdentity, snapshot == nil {
            await initialize()
            guard let snapshot, storeError == nil else { throw CompanionDeviceError.storageUnavailable }
            return snapshot
        }
        return snapshot
    }

    func importPublicDevice(name: String, relayURL: String, peerSPKI: Data,
                            peerDeviceID: String, compatibility: Bool = false) async throws -> UUID {
        guard let snapshot = try await mcpSnapshot(createIdentity: true) else { throw CompanionDeviceError.notInitialized }
        if let saved = snapshot.devices.first(where: { $0.peerDeviceID == peerDeviceID }) {
            guard saved.revokedAt == nil else { throw CompanionDeviceError.deviceRevoked }
            guard saved.peerSPKI == peerSPKI, saved.relayURL == relayURL,
                  saved.allowWindows10TLS12 == compatibility else { throw CompanionDeviceError.identityChanged }
            return saved.id
        }
        guard await add(name: name, relayURL: relayURL, peerSPKI: peerSPKI,
                        compatibility: compatibility, verifiedID: peerDeviceID), let selectedID else {
            throw CompanionDeviceError.storageUnavailable
        }
        return selectedID
    }

    func trustedConfiguration(_ route: CompanionDeviceRoute, token: UUID) async throws -> CompanionIPCOpen {
        guard route.generation == token else { throw CancellationError() }
        let configuration = try await withRegistry { try await registry.openConfiguration(deviceID: route.deviceID) }
        guard route.generation == token else { throw CancellationError() }
        return configuration
    }

    // The registry deliberately rejects reentrancy. Serialize only durable reads/mutations,
    // leaving separate devices' network operations free to run concurrently.
    private func withRegistry<T>(_ body: () async throws -> T) async rethrows -> T {
        if registryLocked { await withCheckedContinuation { registryWaiters.append($0) } }
        else { registryLocked = true }
        defer {
            if registryWaiters.isEmpty { registryLocked = false }
            else { registryWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    func failed(_ error: Error, route: CompanionDeviceRoute, token: UUID) {
        guard route.generation == token else { return }
        if let error = error as? CompanionClientError, case .remote(let code) = error {
            route.errorCode = code; route.clearGrant(); return
        }
        route.disconnect()
        route.errorCode = (error as? CompanionDeviceError) == .deviceRevoked ? "DEVICE_LOCAL_TRUST_REVOKED"
            : error is CompanionDeviceError ? "DEVICE_STORE_UNAVAILABLE" : "CONTROL_CONNECTION_FAILED"
    }

    private func storeFailed(_ error: Error) {
        if let failure = error as? CompanionDeviceError {
            switch failure {
            case .invalidInput: storeError = "INVALID_DEVICE_DETAILS"; return
            case .deviceAlreadyKnown: storeError = "DEVICE_IDENTITY_ALREADY_RECORDED"; return
            case .capacityReached: storeError = "DEVICE_REGISTRY_FULL"; return
            default: break
            }
        }
        disconnectAll(); loaded = false; storeError = "DEVICE_STORE_UNAVAILABLE"
    }
}
#endif
