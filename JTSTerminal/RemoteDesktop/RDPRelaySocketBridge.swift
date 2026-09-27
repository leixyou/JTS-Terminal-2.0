#if ENABLE_RDP_2
import Foundation
import JTSCompanionClient
import JTSCompanionIPC

/// Private descriptor bridge between the authenticated transport helper and
/// FreeRDP. At most one 64 KiB chunk per direction is in flight.
@MainActor
final class RDPRelaySocketBridge {
    let helperSocket: FileHandle
    private let endpoint: RDPRelaySocketEndpoint
    private let lane: CompanionLaneClient
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false
    private var observers: [NSObjectProtocol] = []

    private init(endpoint: RDPRelaySocketEndpoint, helperSocket: FileHandle, lane: CompanionLaneClient) {
        self.endpoint = endpoint; self.helperSocket = helperSocket; self.lane = lane
    }

    static func open(configuration: CompanionIPCOpen, grantID: UUID) async throws -> RDPRelaySocketBridge {
        let lane = CompanionLaneClient()
        do {
            _ = try await lane.open(configuration: configuration, lane: .rdp, grantID: grantID)
            try Task.checkCancellation()
            let (endpoint, socket) = try RDPRelaySocketEndpoint.pair()
            let bridge = RDPRelaySocketBridge(endpoint: endpoint, helperSocket: socket, lane: lane)
            bridge.start()
            return bridge
        } catch { await lane.invalidate(); throw error }
    }

    func helperAcceptedSocket() { try? helperSocket.close() }

    func watchTrust(targetID: UUID, deviceID: UUID) {
        for (name, expected) in [(Notification.Name.jtsCompanionTargetRouteChanged, targetID),
                                 (.jtsCompanionDeviceTrustChanged, deviceID)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard notification.object as? UUID == expected else { return }
                Task { @MainActor [weak self] in self?.stop() }
            })
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        endpoint.close(); try? helperSocket.close()
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        let lane = lane
        Task { await lane.invalidate() }
    }

    private func start() {
        let endpoint = endpoint, lane = lane
        tasks = [
            Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let bytes = try await endpoint.read()
                        if bytes.isEmpty { break }
                        try await lane.write(bytes)
                    }
                } catch { /* Socket EOF propagates the transport failure to FreeRDP. */ }
                self?.stop()
            },
            Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let bytes = try await lane.read(maximumBytes: 65_536)
                        if bytes.isEmpty { break }
                        try await endpoint.write(bytes)
                    }
                } catch { /* Close both directions after a lane failure. */ }
                self?.stop()
            }
        ]
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        endpoint.close(); try? helperSocket.close()
        tasks.forEach { $0.cancel() }
        let lane = lane
        Task { await lane.invalidate() }
    }
}
#endif
