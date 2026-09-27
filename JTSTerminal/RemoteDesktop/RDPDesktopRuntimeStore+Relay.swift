#if ENABLE_RDP_2
import Foundation

nonisolated enum RDPDesktopTransportRoute: Equatable, Sendable {
    case unknown, direct, relay
}

extension RDPDesktopRuntimeStore {
    /// An enrolled route takes precedence over a private IP address, allowing
    /// the same target and MCP grants to survive a network change.
    func connectTransport(for active: ActiveDesktop, configuration: [String: Any],
                          deadlineMilliseconds: Int? = nil) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let attempt = active.connectionAttemptID
        let store = CompanionTargetRouteStore.shared
        active.relayBridge?.stop(); active.relayBridge = nil
        active.transportRoute = .unknown
        let binding = try await store.binding(targetID: active.target.targetID, targetBinding: active.targetBinding)
        try requireRelayAttempt(active, attempt: attempt)
        guard let binding else {
            active.transportRoute = .direct
            try await active.xpc.connect(configuration: configuration, deadlineMilliseconds: deadlineMilliseconds)
            return
        }
        active.transportRoute = .relay
        guard let grantID = binding.rdpGrantID else {
            throw FreeRDPXPCFailure(code: "RDP_RELAY_GRANT_MISSING",
                                   message: "This device route has no remote-desktop relay grant.")
        }
        let model = CompanionDevicesModel.shared
        let relay = try await model.relayConfiguration(deviceID: binding.deviceID, grantID: grantID)
        try requireRelayAttempt(active, attempt: attempt)
        let bridge = try await RDPRelaySocketBridge.open(configuration: relay, grantID: grantID)
        do {
            bridge.watchTrust(targetID: binding.targetID, deviceID: binding.deviceID)
            try requireRelayAttempt(active, attempt: attempt)
            guard try await store.binding(targetID: binding.targetID, targetBinding: binding.targetBinding) == binding else {
                throw CompanionTargetRouteError.changed
            }
            _ = try await model.relayConfiguration(deviceID: binding.deviceID, grantID: grantID)
            try requireRelayAttempt(active, attempt: attempt)
            var remaining = deadlineMilliseconds
            if let budget = deadlineMilliseconds {
                remaining = budget - Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                guard remaining! > 0 else { throw FreeRDPXPCFailure(
                    code: "RDP_RELAY_DEADLINE_EXCEEDED", message: "Opening the authenticated relay exceeded the connection deadline.") }
            }
            active.relayBridge = bridge
            try await active.xpc.connect(configuration: configuration, relaySocket: bridge.helperSocket,
                                         deadlineMilliseconds: remaining)
            bridge.helperAcceptedSocket()
            try requireRelayAttempt(active, attempt: attempt)
        } catch {
            bridge.stop()
            if active.relayBridge === bridge { active.relayBridge = nil }
            throw error
        }
    }

    private func requireRelayAttempt(_ active: ActiveDesktop, attempt: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(active), targetBindingIsCurrent(active), !active.intentionallyClosing,
              active.connectionAttemptID == attempt else { throw CancellationError() }
    }
}
#endif
