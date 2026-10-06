#if ENABLE_RDP_2
import Foundation
import JTSCompanionClient
import JTSCompanionIPC
import Network
import Testing
@testable import JTSTerminal

@MainActor
struct NativeScreenSharingLoopbackBridgeTests {
    @Test func loopbackCarriesBothDirectionsWithBoundedWritesAndBackpressure() async throws {
        let lane = NativeScreenSharingTraceLane()
        await lane.holdWrites()
        let grant = UUID()
        let bridge = try await open(lane, grantID: grant)
        defer { bridge.stop() }
        let url = try #require(bridge.viewerURL)
        #expect(url.scheme == "vnc")
        #expect(url.host == "127.0.0.1")
        #expect(url.user == nil && url.password == nil && url.query == nil)
        let viewer = try await NativeScreenSharingTestViewer.connect(url)
        defer { viewer.close() }
        let outgoing = Data((0..<160_000).map { UInt8(truncatingIfNeeded: $0) })
        for offset in stride(from: 0, to: outgoing.count, by: 65_536) {
            try await viewer.write(outgoing.subdata(in: offset..<min(offset + 65_536, outgoing.count)))
        }
        try await eventually { await lane.writeCount == 1 }
        // The lane acknowledgement is blocked: no second socket read/write may begin.
        #expect(await lane.writeCount == 1)
        #expect(await lane.maximumConcurrentWrites == 1)
        await lane.releaseWrites()
        try await eventually { await lane.written.count == outgoing.count }
        #expect(await lane.written == outgoing)
        #expect(await lane.maximumWriteBytes <= 65_536)
        #expect(await lane.openedLane == .rdp)
        #expect(await lane.openedGrant == grant)

        let incoming = Data(repeating: 0x5a, count: 120_000)
        for offset in stride(from: 0, to: incoming.count, by: 65_536) {
            await lane.deliver(incoming.subdata(in: offset..<min(offset + 65_536, incoming.count)))
        }
        #expect(try await viewer.readExactly(incoming.count) == incoming)
        #expect(await lane.maximumReadBytes == 65_536)
        bridge.stop()
        try await eventually { await lane.invalidated }
        #expect(bridge.phase == .stopped)
    }

    @Test func waitingViewerTimeoutClosesListenerAndAuthenticatedLane() async throws {
        let lane = NativeScreenSharingTraceLane()
        let deadlines = NativeScreenSharingTestDeadlines()
        let bridge = try await open(lane, deadlines: deadlines)
        let url = try #require(bridge.viewerURL)
        #expect(deadlines.delays == [10, 30])
        // Listener readiness replaced its old timer with the viewer admission lease.
        deadlines.fire(0)
        #expect(bridge.phase == .waitingForViewer)
        #expect(bridge.viewerURL == url)
        deadlines.fire(1)
        try await eventually { bridge.phase == .failed }
        #expect(bridge.error == .viewerTimedOut)
        try await eventually { await lane.invalidated }
        do {
            let unexpected = try await NativeScreenSharingTestViewer.connect(url)
            unexpected.close()
            Issue.record("Timed-out listener accepted a new viewer.")
        } catch { /* The exact saved loopback endpoint is no longer admitted. */ }
    }

    @Test func oneViewerOnlyAndRevocationWakesBlockedDirections() async throws {
        let lane = NativeScreenSharingTraceLane()
        let bridge = try await open(lane)
        defer { bridge.stop() }
        let target = UUID(), device = UUID()
        bridge.watchTrust(targetID: target, deviceID: device)
        let url = try #require(bridge.viewerURL)
        let first = try await NativeScreenSharingTestViewer.connect(url)
        defer { first.close() }
        try await eventually { bridge.phase == .connected }
        do {
            let second = try await NativeScreenSharingTestViewer.connect(url)
            defer { second.close() }
            // A queued TCP handshake may succeed, but the second stream must be rejected before forwarding.
            #expect(try await second.readExactly(1).isEmpty)
        } catch { #expect(error as? NativeScreenSharingBridgeError != .viewerTimedOut) }
        #expect(await lane.openCount == 1)
        NotificationCenter.default.post(name: .jtsCompanionDeviceTrustChanged, object: UUID())
        #expect(bridge.phase == .connected)
        NotificationCenter.default.post(name: .jtsCompanionDeviceTrustChanged, object: device)
        try await eventually { bridge.phase == .stopped }
        try await eventually { await lane.invalidated }
        #expect(await lane.pendingReads == 0)
    }

    @Test func invalidLaneNeverOpensLocalViewerListener() async throws {
        let lane = NativeScreenSharingTraceLane()
        await lane.returnWrongLane()
        do {
            _ = try await open(lane)
            Issue.record("Wrong authenticated lane was accepted.")
        } catch { #expect(error as? NativeScreenSharingBridgeError == .invalidConfiguration) }
        #expect(await lane.invalidated)
        #expect(await lane.writeCount == 0)
    }

    @Test func closingViewerStopsInsteadOfBecomingTransportRetry() async throws {
        let lane = NativeScreenSharingTraceLane()
        let bridge = try await open(lane)
        defer { bridge.stop() }
        let viewer = try await NativeScreenSharingTestViewer.connect(try #require(bridge.viewerURL))
        try await eventually { let pending = await lane.pendingReads; return bridge.phase == .connected && pending == 1 }
        viewer.close()
        try await eventually { bridge.phase == .failed }
        #expect(bridge.error == .viewerDisconnected)
        #expect(bridge.viewerURL == nil)
        try await eventually { await lane.invalidated }
    }

    @Test(arguments: [CompanionClientError.remote("DEVICE_OFFLINE"), .remote("GRANT_REVOKED"), .invalidReply])
    func laneFailureKeepsTransientAndPermanentReasons(_ failure: CompanionClientError) async throws {
        let lane = NativeScreenSharingTraceLane()
        let bridge = try await open(lane)
        defer { bridge.stop() }
        let viewer = try await NativeScreenSharingTestViewer.connect(try #require(bridge.viewerURL))
        defer { viewer.close() }
        try await eventually { let pending = await lane.pendingReads; return bridge.phase == .connected && pending == 1 }
        await lane.failRead(failure)
        try await eventually { bridge.phase == .failed }
        #expect(bridge.error == (failure == .remote("DEVICE_OFFLINE") ? .transportFailed : .transportRejected))
        try await eventually { await lane.invalidated }
    }

    @Test func acceptedViewerSurvivesItsExpiredAdmissionTimer() async throws {
        let lane = NativeScreenSharingTraceLane()
        let deadlines = NativeScreenSharingTestDeadlines()
        let bridge = try await open(lane, deadlines: deadlines)
        defer { bridge.stop() }
        let viewer = try await NativeScreenSharingTestViewer.connect(try #require(bridge.viewerURL))
        defer { viewer.close() }
        try await eventually { bridge.phase == .connected }
        #expect(deadlines.cancelled == [true, true])
        // Simulate timer callbacks that were already queued before cancellation.
        deadlines.fire(0)
        deadlines.fire(1)
        await lane.deliver(Data([0x5a]))
        #expect(try await viewer.readExactly(1) == Data([0x5a]))
        #expect(bridge.phase == .connected)
        #expect(await lane.invalidated == false)
    }

    @Test func productionDeadlineStillClosesAnIdleAuthenticatedLane() async throws {
        let lane = NativeScreenSharingTraceLane()
        // This checks the real dispatch scheduler without racing a viewer against wall time.
        let bridge = try await NativeScreenSharingLoopbackBridge.open(configuration: configuration, grantID: UUID(),
                                                                     using: lane, viewerTimeout: 0.15)
        defer { bridge.stop() }
        try await eventually { bridge.phase == .failed }
        #expect(bridge.error == .viewerTimedOut)
        try await eventually { await lane.invalidated }
    }

    private func open(_ lane: NativeScreenSharingTraceLane, grantID: UUID = UUID(),
                      deadlines: NativeScreenSharingTestDeadlines? = nil) async throws -> NativeScreenSharingLoopbackBridge {
        let deadlines = deadlines ?? NativeScreenSharingTestDeadlines()
        return try await NativeScreenSharingLoopbackBridge.open(configuration: configuration, grantID: grantID,
            using: lane, viewerTimeout: 30, scheduleDeadline: deadlines.schedule)
    }

    private var configuration: CompanionIPCOpen {
        CompanionIPCOpen(privateKey: Data(repeating: 3, count: 32), peerSPKI: Data(repeating: 4, count: 91),
                         relayURL: "https://relay.example.test")
    }
    private func eventually(_ predicate: () async -> Bool) async throws {
        // Other suites can occupy MainActor for seconds; count opportunities to observe,
        // rather than consuming this fixture's budget while it cannot be scheduled.
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Loopback lifecycle condition timed out.")
        throw NativeScreenSharingBridgeError.viewerTimedOut
    }
}

private actor NativeScreenSharingTraceLane: NativeScreenSharingLane {
    private(set) var invalidated = false
    private(set) var openedLane: CompanionIPCLane?
    private(set) var openedGrant: UUID?
    private(set) var openCount = 0
    private(set) var writeCount = 0
    private(set) var written = Data()
    private(set) var maximumWriteBytes = 0
    private(set) var maximumReadBytes = 0
    private(set) var maximumConcurrentWrites = 0
    var pendingReads: Int { waitingRead == nil ? 0 : 1 }
    private var activeWrites = 0
    private var writesHeld = false
    private var wrongLane = false
    private var buffered: [Data] = []
    private var waitingRead: CheckedContinuation<Data, Error>?
    private var waitingWrites: [CheckedContinuation<Void, Error>] = []

    func holdWrites() { writesHeld = true }
    func returnWrongLane() { wrongLane = true }
    func releaseWrites() {
        writesHeld = false
        let waiters = waitingWrites; waitingWrites = []
        waiters.forEach { $0.resume() }
    }
    func open(configuration: CompanionIPCOpen, lane: CompanionIPCLane, grantID: UUID) async throws -> CompanionIPCLaneState {
        openCount += 1; openedLane = lane; openedGrant = grantID
        return CompanionIPCLaneState(lane: wrongLane ? .file : lane, sessionID: UUID())
    }
    func read(maximumBytes: Int) async throws -> Data {
        guard !invalidated else { throw NativeScreenSharingBridgeError.cancelled }
        maximumReadBytes = max(maximumReadBytes, maximumBytes)
        if !buffered.isEmpty { return buffered.removeFirst() }
        return try await withCheckedThrowingContinuation { waitingRead = $0 }
    }
    func deliver(_ data: Data) {
        if let waiter = waitingRead { waitingRead = nil; waiter.resume(returning: data) }
        else { buffered.append(data) }
    }
    func failRead(_ error: CompanionClientError) {
        waitingRead?.resume(throwing: error); waitingRead = nil
    }
    func write(_ data: Data) async throws {
        guard !invalidated else { throw NativeScreenSharingBridgeError.cancelled }
        activeWrites += 1; defer { activeWrites -= 1 }
        maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        maximumWriteBytes = max(maximumWriteBytes, data.count)
        writeCount += 1; written.append(data)
        if writesHeld { try await withCheckedThrowingContinuation { waitingWrites.append($0) } }
    }
    func invalidate() async {
        invalidated = true
        waitingRead?.resume(throwing: NativeScreenSharingBridgeError.cancelled); waitingRead = nil
        let waiting = waitingWrites; waitingWrites = []
        waiting.forEach { $0.resume(throwing: NativeScreenSharingBridgeError.cancelled) }
    }
}

@MainActor
private final class NativeScreenSharingTestDeadlines {
    private struct Deadline {
        let delay: TimeInterval
        let action: @MainActor @Sendable () -> Void
        let item: DispatchWorkItem
    }
    private var deadlines: [Deadline] = []
    var delays: [TimeInterval] { deadlines.map(\.delay) }
    var cancelled: [Bool] { deadlines.map { $0.item.isCancelled } }
    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem {}
        deadlines.append(Deadline(delay: delay, action: action, item: item))
        return item
    }
    func fire(_ index: Int) {
        // Deliberately deliver cancelled callbacks too: the production lease must reject them.
        deadlines[index].action()
    }
}

@MainActor
private enum NativeScreenSharingTestViewer {
    static func connect(_ url: URL) async throws -> NativeScreenSharingSocket {
        let portValue = try #require(url.port)
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(portValue)))
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NativeScreenSharingTestDial(connection: connection, continuation: continuation).start()
        }
        return NativeScreenSharingSocket(connection: connection)
    }
}

/// Fixture dial callbacks and its watchdog use an independent queue; MainActor
/// contention from unrelated suites cannot turn a completed TCP dial into a timeout.
nonisolated private final class NativeScreenSharingTestDial: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "jts.tests.native-sharing-dial")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: DispatchWorkItem?
    init(connection: NWConnection, continuation: CheckedContinuation<Void, Error>) {
        self.connection = connection; self.continuation = continuation
    }
    func start() {
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(NativeScreenSharingBridgeError.viewerTimedOut)) }
        lock.lock(); timeout = timer; lock.unlock()
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: finish(.success(()))
            case .waiting, .failed, .cancelled: finish(.failure(NativeScreenSharingBridgeError.viewerDisconnected))
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2, execute: timer)
    }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard let pending = continuation else { lock.unlock(); return }
        continuation = nil
        let timer = timeout; timeout = nil
        lock.unlock()
        timer?.cancel(); connection.stateUpdateHandler = nil
        if case .failure = result { connection.cancel() }
        pending.resume(with: result)
    }
}

@MainActor
private enum NativeScreenSharingFixtureBudget {
    static func exhaust() async throws -> Data {
        // Bound progress checks on the same executor as the bridge, not unrelated wall-clock load.
        for _ in 0..<500 { try await Task.sleep(for: .milliseconds(10)) }
        throw NativeScreenSharingBridgeError.viewerTimedOut
    }
}

private extension NativeScreenSharingSocket {
    func readExactly(_ count: Int) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var data = Data()
                while data.count < count {
                    let next = try await self.read()
                    guard !next.isEmpty else { return data }
                    data.append(next)
                }
                return data
            }
            group.addTask { try await NativeScreenSharingFixtureBudget.exhaust() }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
    }
}
#endif
