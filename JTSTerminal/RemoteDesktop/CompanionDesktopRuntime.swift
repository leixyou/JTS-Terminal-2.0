#if ENABLE_RDP_2
import AppKit
import Combine
import ImageIO
import JTSCompanionClient
import JTSCompanionIPC

@MainActor
final class CompanionDesktopSession {
    let id = UUID()
    let target: RemoteSession
    let binding: CompanionTargetRouteBinding
    let client = CompanionDesktopClient()
    let userClient = CompanionDesktopClient()
    let decoder = CompanionDesktopFrameDecoder()
    var generation = UUID()
    var windowsSessionID = 0
    var revision: UInt64 = 1
    var status = "connecting"
    var remoteState: [String: DesktopJSONValue] = [:]
    var latest: CompanionDesktopObservation?
    var image: CGImage?
    var observations: [String: CompanionDesktopObservation] = [:]
    var uiaObservations: [String: (id: String, generation: UUID, expiresAt: Date)] = [:]
    var polling: Task<Void, Never>?
    var busy = false
    var userBusy = false
    var userGeneration: UUID?
    var pollingPaused = false
    var streaming = false
    var availableWindowsSessions: [[String: DesktopJSONValue]] = []
    var errorCode: String?
    private var retiredGenerations: [UUID] = []
    var manualInputs: [(generation: UUID, body: [String: DesktopJSONValue], queuedAt: Date)] = []
    var manualTask: Task<Void, Never>?
    init(target: RemoteSession, binding: CompanionTargetRouteBinding) { self.target = target; self.binding = binding }
    @discardableResult func accept(_ value: CompanionDesktopEnvelope) -> Bool {
        guard !retiredGenerations.contains(value.generation) else { return false }
        if generation != value.generation || windowsSessionID != value.sessionId {
            retiredGenerations.append(generation)
            if retiredGenerations.count > 64 { retiredGenerations.removeFirst() }
            generation = value.generation; windowsSessionID = value.sessionId; revision += 1
            observations.removeAll(); uiaObservations.removeAll(); latest = nil; image = nil; decoder.reset()
            userGeneration = nil
            manualInputs.removeAll()
        }
        if let state = value.body["state"]?.objectValue {
            remoteState = state; status = state["status"]?.stringValue ?? "unavailable"
            if ["unavailable", "awaitingFrame"].contains(status) {
                image = nil; latest = nil; observations.removeAll(); uiaObservations.removeAll()
            }
            errorCode = state["errorCode"]?.stringValue
        }
        return true
    }
}

@MainActor
final class CompanionDesktopRuntime: ObservableObject {
    static let shared = CompanionDesktopRuntime()
    @Published private(set) var sessions: [UUID: CompanionDesktopSession] = [:]
    @Published private(set) var routes: [UUID: CompanionDesktopRoutePreference] = [:]
    private var openings = CompanionDesktopOpeningGate()
    private var listeners: [NSObjectProtocol] = []
    private let devices = CompanionDevicesModel.shared
    private let bindings = CompanionTargetRouteStore.shared

    init() {
        for name in [Notification.Name.jtsCompanionTargetRouteChanged, .jtsCompanionDeviceTrustChanged] {
            listeners.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = note.object as? UUID
                Task { @MainActor in await self?.trustChanged(id) }
            })
        }
    }
    func route(for target: RemoteSession) async throws -> CompanionTargetRouteBinding? {
        let binding = try await bindings.binding(targetID: target.targetID, targetBinding: target.mcpGrantTargetBinding)
        routes[target.targetID] = binding?.effectiveDesktopRoute ?? .rdp
        return binding
    }
    func choose(_ preference: CompanionDesktopRoutePreference, target: RemoteSession) async throws {
        guard let current = try await route(for: target) else { throw failure("DESKTOP_RELAY_NOT_BOUND") }
        await close(targetID: target.targetID)
        try await bindings.chooseDesktopRoute(expected: current, preference: preference)
        routes[target.targetID] = preference
    }

    func open(target: RemoteSession, authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck = {}) async throws -> CompanionDesktopSession {
        try authorize()
        guard let opening = openings.begin(target.targetID) else { throw failure("DESKTOP_BUSY") }
        defer { openings.finish(target.targetID, token: opening) }
        func checkOpening() throws {
            try Task.checkCancellation()
            try authorize()
            guard openings.isCurrent(target.targetID, token: opening) else { throw failure("DESKTOP_OPEN_CANCELLED") }
        }
        guard var binding = try await route(for: target), binding.effectiveDesktopRoute == .companion,
              let pairingID = binding.pairingID else { throw failure("DESKTOP_RELAY_NOT_BOUND") }
        try checkOpening()
        if let existing = sessions[target.targetID], existing.status != "disconnected" {
            guard existing.binding == binding else { await close(targetID: target.targetID); throw failure("DESKTOP_BINDING_CHANGED") }
            return existing
        }
        let control = try await devices.mcpConnect(deviceID: binding.deviceID, grantID: binding.grantID, authorize: authorize)
        try checkOpening()
        if binding.desktopGrantID == nil || (binding.desktopGrantExpiresAt ?? .distantPast) <= Date().addingTimeInterval(60) {
            guard control.capabilities.contains("desktop.authorize"), let connection = control.connection else {
                throw failure("DESKTOP_COMPANION_UPGRADE_REQUIRED")
            }
            for attempt in 0...1 {
                binding = try await bindings.prepareDesktopAuthorization(expected: binding)
                try checkOpening()
                guard let pending = binding.pendingDesktopAuthorization else { throw failure("DESKTOP_GRANT_NOT_PREPARED") }
                let request = CompanionIPCDesktopAuthorization(targetBinding: binding.targetBinding, pairingID: pairingID,
                    controlGrantID: binding.grantID, desktopGrantID: pending.grantID,
                    issuedAtUnixSeconds: Int64(pending.issuedAt.timeIntervalSince1970),
                    expiresAtUnixSeconds: Int64(pending.expiresAt.timeIntervalSince1970))
                do {
                    _ = try await connection.authorizeDesktop(request)
                    try checkOpening()
                    try await bindings.saveDesktopAuthorization(expected: binding, grantID: pending.grantID, expiresAt: pending.expiresAt)
                    break
                } catch CompanionClientError.remote(let code) where code == "DESKTOP_GRANT_TIME_REJECTED" && attempt == 0 {
                    try authorize()
                    binding = try await bindings.discardRejectedDesktopAuthorization(expected: binding)
                }
            }
            guard let updated = try await route(for: target) else { throw failure("DESKTOP_BINDING_CHANGED") }
            binding = updated
        }
        guard let grant = binding.desktopGrantID else { throw failure("DESKTOP_GRANT_MISSING") }
        let configuration = try await devices.relayConfiguration(deviceID: binding.deviceID, grantID: binding.grantID)
        try checkOpening()
        guard try await route(for: target) == binding else { throw failure("DESKTOP_BINDING_CHANGED") }
        try checkOpening()
        let session = CompanionDesktopSession(target: target, binding: binding)
        sessions[target.targetID] = session
        do {
            try await session.client.open(configuration: configuration, grantID: grant)
            try checkOpening()
            await installStreamHandler(session)
            try checkOpening()
            let state = try await session.client.request("status")
            session.accept(state); try checkOpening()
            await refreshSessions(session)
            try checkOpening()
            await enableStream(session)
            try checkOpening()
            startPolling(session)
            RDPDesktopWindowCoordinator.shared.open(target, activate: false)
            return session
        } catch {
            await session.client.close(); session.status = "disconnected"; session.errorCode = safeCode(error)
            objectWillChange.send(); throw error
        }
    }

    func observe(_ session: CompanionDesktopSession, retainObservation: Bool = true) async throws -> CompanionDesktopObservation {
        guard !session.busy else { throw failure("DESKTOP_BUSY") }
        session.busy = true; defer { session.busy = false }
        let value = try await session.client.request("observe", body: ["retainObservation": .bool(retainObservation)])
        guard session.accept(value) else { throw CompanionDesktopError.sessionChanged }
        let observation = try CompanionDesktopObservation(value)
        session.image = try session.decoder.decode(observation); session.latest = observation
        session.errorCode = nil; objectWillChange.send(); return observation
    }
    func refreshSessions(_ session: CompanionDesktopSession) async {
        do {
            let value = try await request("sessions", session: session, body: [:])
            if case .array(let available) = value.body["sessions"] {
                session.availableWindowsSessions = available.compactMap(\.objectValue)
                objectWillChange.send()
            }
        } catch { session.errorCode = safeCode(error) }
    }
    func selectSession(_ id: Int, session: CompanionDesktopSession) async throws {
        _ = try await request("selectSession", session: session, body: ["sessionId": .integer(Int64(id))])
        await enableStream(session)
    }
    func selectMonitor(_ id: String, session: CompanionDesktopSession) async throws {
        _ = try await request("selectMonitor", session: session, body: ["monitorID": .string(id)])
    }
    func request(_ operation: String, session: CompanionDesktopSession, body: [String: DesktopJSONValue]) async throws -> CompanionDesktopEnvelope {
        if operation.hasPrefix("user.") { return try await userRequest(operation, session: session, body: body) }
        session.pollingPaused = true
        defer { session.pollingPaused = false }
        let deadline = Date().addingTimeInterval(15)
        while session.busy {
            guard Date() < deadline else { throw failure("DESKTOP_BUSY") }
            try await Task.sleep(for: .milliseconds(10))
        }
        session.busy = true; defer { session.busy = false }
        let value = try await session.client.request(operation, body: body,
            expectedGeneration: session.generation, expectedSessionId: session.windowsSessionID)
        guard session.accept(value) else { throw CompanionDesktopError.sessionChanged }
        objectWillChange.send(); return value
    }
    func close(targetID: UUID) async {
        openings.cancel(targetID)
        guard let session = sessions.removeValue(forKey: targetID) else { return }
        session.polling?.cancel(); session.polling = nil
        session.manualTask?.cancel(); session.manualTask = nil; session.manualInputs.removeAll()
        await session.client.close(); await session.userClient.close()
        session.userGeneration = nil; session.observations.removeAll(); session.uiaObservations.removeAll(); session.latest = nil
        session.image = nil; session.decoder.reset(); session.status = "disconnected"
    }
    private func startPolling(_ session: CompanionDesktopSession) {
        guard session.polling == nil else { return }
        session.polling = Task { @MainActor [weak self, weak session] in
            while let self, let session, !Task.isCancelled, self.sessions[session.target.targetID] === session {
                do {
                    if !session.busy && !session.pollingPaused {
                        if session.streaming {
                            _ = try await self.request("status", session: session, body: [:])
                            if let delivery = await session.client.deliveryMetrics() {
                                _ = try await self.request("streamFeedback", session: session, body: [
                                    "deliveryLatencyMs": .integer(Int64(delivery.milliseconds)),
                                    "deliveredBytes": .integer(Int64(delivery.bytes))])
                            }
                        } else { _ = try await self.observe(session, retainObservation: false) }
                    }
                    try await Task.sleep(for: .milliseconds(session.streaming ? 1000 : 33))
                } catch is CancellationError { return }
                catch {
                    session.errorCode = self.safeCode(error)
                    session.status = "connecting"
                    session.remoteState["status"] = .string("connecting")
                    session.image = nil; session.latest = nil; session.observations.removeAll()
                    session.uiaObservations.removeAll()
                    self.objectWillChange.send()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    if self.needsReconnect(error) {
                        do { try await self.reconnect(session) }
                        catch { session.errorCode = self.safeCode(error) }
                    }
                }
            }
        }
    }
    private func reconnect(_ session: CompanionDesktopSession) async throws {
        guard !session.busy, !session.pollingPaused,
              sessions[session.target.targetID] === session,
              let current = try await route(for: session.target), current == session.binding,
              let grant = current.desktopGrantID, (current.desktopGrantExpiresAt ?? .distantPast) > Date() else {
            throw failure("DESKTOP_RECONNECT_BINDING_CHANGED")
        }
        session.status = "connecting"; session.generation = UUID(); session.revision += 1
        await session.userClient.close(); session.userGeneration = nil
        session.streaming = false
        session.observations.removeAll(); session.uiaObservations.removeAll(); session.decoder.reset()
        let configuration = try await devices.relayConfiguration(deviceID: current.deviceID, grantID: current.grantID)
        try Task.checkCancellation()
        try await session.client.open(configuration: configuration, grantID: grant)
        await installStreamHandler(session)
        let state = try await session.client.request("status"); session.accept(state)
        await enableStream(session)
        session.errorCode = nil; objectWillChange.send()
    }
    private func trustChanged(_ id: UUID?) async {
        for session in Array(sessions.values) where id == nil || id == session.target.targetID || id == session.binding.deviceID {
            guard let current = try? await bindings.binding(targetID: session.target.targetID,
                targetBinding: session.target.mcpGrantTargetBinding), current == session.binding,
                (try? await devices.relayConfiguration(deviceID: current.deviceID, grantID: current.grantID)) != nil else {
                await close(targetID: session.target.targetID); continue
            }
        }
    }
    func failure(_ code: String) -> WindowsMCPToolError {
        WindowsMCPToolError(code: .runtimeFailure, message: "Companion desktop is unavailable: \(code).", details: ["desktopCode": code])
    }
    func safeCode(_ error: Error) -> String {
        if case CompanionDesktopError.remote(let code) = error { return code }
        if let desktop = error as? CompanionDesktopError {
            switch desktop {
            case .invalidFrame: return "DESKTOP_FRAME_INVALID"
            case .invalidRequest: return "DESKTOP_REQUEST_INVALID"
            case .staleObservation: return "DESKTOP_OBSERVATION_STALE"
            case .sessionChanged: return "DESKTOP_SESSION_CHANGED"
            case .busy: return "DESKTOP_BUSY"
            default: break
            }
        }
        if let value = error as? WindowsMCPToolError, let code = value.details["desktopCode"] as? String { return code }
        return "DESKTOP_CONNECTION_UNAVAILABLE"
    }
    private func needsReconnect(_ error: Error) -> Bool {
        if case CompanionDesktopError.remote = error { return false }
        if let error = error as? WindowsMCPToolError, error.details["desktopCode"] as? String == "DESKTOP_BUSY" { return false }
        return true
    }
}
#endif
