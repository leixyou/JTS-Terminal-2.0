#if ENABLE_RDP_2
import Combine
import Foundation
import JTSCompanionClient
import JTSCompanionIPC
import Network

nonisolated protocol NativeScreenSharingLane: Sendable {
    func open(configuration: CompanionIPCOpen, lane: CompanionIPCLane, grantID: UUID) async throws -> CompanionIPCLaneState
    func read(maximumBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func invalidate() async
}
extension CompanionLaneClient: NativeScreenSharingLane {}

nonisolated enum NativeScreenSharingBridgeError: String, Error, Equatable, Sendable {
    case invalidConfiguration, listenerFailed, viewerTimedOut, viewerDisconnected, transportFailed, transportRejected, cancelled
}

/// A short-lived, loopback-only carrier for the system VNC viewer. Endpoint identity,
/// grants and lane framing stay inside the existing signed Companion transport helper.
/// It never configures macOS sharing or places remote credentials in the viewer URL.
@MainActor
final class NativeScreenSharingLoopbackBridge: ObservableObject {
    enum Phase: Equatable { case opening, waitingForViewer, connected, stopped, failed }
    typealias DeadlineScheduler = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> DispatchWorkItem
    @Published private(set) var phase: Phase = .opening
    @Published private(set) var error: NativeScreenSharingBridgeError?
    private(set) var viewerURL: URL?
    var onFailure: ((NativeScreenSharingBridgeError) -> Void)?

    private let lane: any NativeScreenSharingLane
    private let scheduleDeadline: DeadlineScheduler
    private var listener: NWListener?
    private var socket: NativeScreenSharingSocket?
    private var streamTask: Task<Void, Never>?
    private var expiry: DispatchWorkItem?
    private var timeoutGeneration = UUID()
    private var ready: CheckedContinuation<Void, Error>?
    private var generation = UUID()
    private var acceptedViewer = false
    private var observers: [NSObjectProtocol] = []

    private init(lane: any NativeScreenSharingLane, scheduleDeadline: DeadlineScheduler?) {
        self.lane = lane
        self.scheduleDeadline = scheduleDeadline ?? Self.dispatchDeadline
    }

    private static func dispatchDeadline(after seconds: TimeInterval,
                                         action: @escaping @MainActor @Sendable () -> Void) -> DispatchWorkItem {
        let timer = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
        return timer
    }

    static func open(configuration: CompanionIPCOpen, grantID: UUID) async throws -> NativeScreenSharingLoopbackBridge {
        try await open(configuration: configuration, grantID: grantID, using: CompanionLaneClient(), viewerTimeout: 30)
    }

    /// Injection is limited to this module's acceptance tests; production always uses the signed helper.
    static func open(configuration: CompanionIPCOpen, grantID: UUID, using lane: any NativeScreenSharingLane,
                     viewerTimeout: TimeInterval, scheduleDeadline: DeadlineScheduler? = nil) async throws -> NativeScreenSharingLoopbackBridge {
        guard viewerTimeout.isFinite, viewerTimeout > 0, viewerTimeout <= 120 else {
            throw NativeScreenSharingBridgeError.invalidConfiguration
        }
        let bridge = NativeScreenSharingLoopbackBridge(lane: lane, scheduleDeadline: scheduleDeadline)
        do {
            try configuration.validate()
            let state = try await lane.open(configuration: configuration, lane: .rdp, grantID: grantID)
            try state.validate()
            guard state.lane == .rdp else { throw NativeScreenSharingBridgeError.invalidConfiguration }
            try Task.checkCancellation()
            try await bridge.startListener(viewerTimeout: viewerTimeout)
            return bridge
        } catch {
            bridge.finish(error: error is CancellationError ? .cancelled : .transportFailed)
            await lane.invalidate()
            throw error
        }
    }

    func watchTrust(targetID: UUID, deviceID: UUID) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        for (name, expected) in [(Notification.Name.jtsCompanionTargetRouteChanged, targetID),
                                 (.jtsCompanionDeviceTrustChanged, deviceID)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard notification.object as? UUID == expected else { return }
                Task { @MainActor [weak self] in self?.stop() }
            })
        }
    }

    func stop() { finish(error: nil) }

    private func startListener(viewerTimeout: TimeInterval) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let active = generation
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, self.generation == active else { connection.cancel(); return }
                self.accept(connection, generation: active)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == active else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port, port.rawValue > 0,
                          let url = URL(string: "vnc://127.0.0.1:\(port.rawValue)") else {
                        self.finish(error: .listenerFailed); return
                    }
                    self.viewerURL = url
                    self.phase = .waitingForViewer
                    self.armTimeout(viewerTimeout, error: .viewerTimedOut, generation: active)
                    let ready = self.ready; self.ready = nil; ready?.resume()
                case .failed: self.finish(error: .listenerFailed)
                case .cancelled: self.finish(error: .cancelled)
                default: break
                }
            }
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ready = continuation
                armTimeout(10, error: .listenerFailed, generation: active)
                listener.start(queue: .main)
            }
        } onCancel: { [weak self] in Task { @MainActor [weak self] in self?.finish(error: .cancelled) } }
    }

    private func armTimeout(_ seconds: TimeInterval, error: NativeScreenSharingBridgeError, generation active: UUID) {
        expiry?.cancel()
        let lease = UUID()
        timeoutGeneration = lease
        expiry = scheduleDeadline(seconds) { [weak self] in
            guard let self, self.generation == active, self.timeoutGeneration == lease else { return }
            self.finish(error: error)
        }
    }

    private func accept(_ connection: NWConnection, generation active: UUID) {
        guard !acceptedViewer, phase == .waitingForViewer,
              case .hostPort(let host, _) = connection.endpoint, host == .ipv4(.loopback) else {
            connection.cancel(); return
        }
        acceptedViewer = true
        // Close admission before starting the only viewer; queued second connections are rejected above.
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = { $0.cancel() }
        listener?.cancel(); listener = nil
        let socket = NativeScreenSharingSocket(connection: connection)
        self.socket = socket
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == active else { return }
                switch state {
                case .ready:
                    guard self.streamTask == nil else { return }
                    self.expiry?.cancel(); self.expiry = nil
                    self.timeoutGeneration = UUID()
                    self.phase = .connected
                    self.startStream(socket, generation: active)
                case .failed, .cancelled:
                    // Once streaming, the supervisor owns the exact EOF/failure reason.
                    // Its transport cleanup also cancels this local socket.
                    if self.streamTask == nil { self.finish(error: .viewerDisconnected) }
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func startStream(_ socket: NativeScreenSharingSocket, generation active: UUID) {
        let lane = lane
        // One supervisor owns both directions. Every read waits for the previous write acknowledgement.
        streamTask = Task { [weak self] in
            let failure = await withTaskGroup(of: NativeScreenSharingBridgeError.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let data: Data
                        do { data = try await socket.read() }
                        catch { return Task.isCancelled ? .cancelled : .viewerDisconnected }
                        guard !data.isEmpty else { return .viewerDisconnected }
                        do { try await lane.write(data) }
                        catch { return Task.isCancelled ? .cancelled : Self.laneFailure(error) }
                    }
                    return .cancelled
                }
                group.addTask {
                    while !Task.isCancelled {
                        let data: Data
                        do { data = try await lane.read(maximumBytes: 65_536) }
                        catch { return Task.isCancelled ? .cancelled : Self.laneFailure(error) }
                        guard !data.isEmpty else { return .transportFailed }
                        guard data.count <= 65_536 else { return .transportRejected }
                        do { try await socket.write(data) }
                        catch { return Task.isCancelled ? .cancelled : .viewerDisconnected }
                    }
                    return .cancelled
                }
                let first = await group.next() ?? .cancelled
                group.cancelAll()
                socket.close()
                await lane.invalidate() // Wake a blocked read before draining child tasks.
                return first
            }
            guard let self, self.generation == active else { return }
            self.finish(error: failure)
        }
    }

    nonisolated private static func laneFailure(_ error: Error) -> NativeScreenSharingBridgeError {
        guard let failure = error as? CompanionClientError else { return .transportRejected }
        switch failure {
        case .remote(let code):
            return ["DEVICE_OFFLINE", "CHANNEL_CLOSED", "CONNECTION_UNAVAILABLE"].contains(code)
                ? .transportFailed : .transportRejected
        case .notConnected, .timedOut, .interrupted, .unavailable: return .transportFailed
        case .cancelled, .invalidated: return .cancelled
        default: return .transportRejected
        }
    }

    private func finish(error: NativeScreenSharingBridgeError?) {
        guard phase != .stopped, phase != .failed else { return }
        generation = UUID()
        self.error = error
        phase = error == nil ? .stopped : .failed
        viewerURL = nil
        expiry?.cancel(); expiry = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = { $0.cancel() }
        listener?.cancel(); listener = nil
        socket?.close(); socket = nil
        streamTask?.cancel(); streamTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        let continuation = ready; ready = nil
        continuation?.resume(throwing: error ?? .cancelled)
        let lane = lane
        Task { await lane.invalidate() }
        if let error { onFailure?(error) }
    }

    deinit {
        expiry?.cancel(); listener?.cancel(); socket?.close(); streamTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        ready?.resume(throwing: NativeScreenSharingBridgeError.cancelled)
        let lane = lane
        Task { await lane.invalidate() }
    }
}

/// Network.framework owns the socket. Cancellation wakes its receive/send callbacks;
/// locks permit at most one bounded operation in each direction and no use after close.
nonisolated final class NativeScreenSharingSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false
    private var reading = false
    private var writing = false

    init(connection: NWConnection) { self.connection = connection }
    deinit { close() }

    func read() async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try begin(write: false)
            return try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
                    end(write: false)
                    if error != nil { continuation.resume(throwing: NativeScreenSharingBridgeError.viewerDisconnected) }
                    else if let data, !data.isEmpty, data.count <= 65_536 { continuation.resume(returning: data) }
                    else if complete { continuation.resume(returning: Data()) }
                    else { continuation.resume(throwing: NativeScreenSharingBridgeError.viewerDisconnected) }
                }
            }
        } onCancel: { self.close() }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw NativeScreenSharingBridgeError.invalidConfiguration }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try begin(write: true)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { [self] error in
                    end(write: true)
                    if error != nil { continuation.resume(throwing: NativeScreenSharingBridgeError.viewerDisconnected) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { self.close() }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; lock.unlock()
        connection.cancel()
    }

    private func begin(write: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, write ? !writing : !reading else { throw NativeScreenSharingBridgeError.cancelled }
        if write { writing = true } else { reading = true }
    }
    private func end(write: Bool) {
        lock.lock(); defer { lock.unlock() }
        if write { writing = false } else { reading = false }
    }
}
#endif
