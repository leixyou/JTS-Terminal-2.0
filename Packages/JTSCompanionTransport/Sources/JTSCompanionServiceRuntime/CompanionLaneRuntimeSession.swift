import CryptoKit
import Foundation
import JTSCompanionIPC
import JTSCompanionTransport

protocol CompanionLaneRuntimeSession: Sendable {
    func connect() async throws -> CompanionIPCLaneState
    func heartbeat() async throws
    func read(maximumBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

struct PinnedCompanionLaneRuntimeSession: CompanionLaneRuntimeSession {
    let relay: RelayHTTPClient
    let coordinator: CompanionDeviceCoordinator
    let peer: PairedCompanionDevice
    let lane: RelayLane
    let input: CompanionIPCLaneOpen

    init(_ input: CompanionIPCLaneOpen) throws {
        try input.validate()
        let identity = RelayIdentity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: input.privateKey))
        guard let selected = RelayLane(rawValue: input.lane.rawValue), selected != .control else {
            throw CompanionTransportError.unsupportedLane
        }
        lane = selected
        peer = try PairedCompanionDevice(publicKeySPKI: input.peerSPKI, allowedLanes: [lane],
                                        allowWindows10TLS12: input.allowWindows10TLS12)
        guard peer.deviceID != identity.deviceID, let url = URL(string: input.relayURL) else {
            throw CompanionTransportError.invalidIdentity
        }
        relay = RelayHTTPClient(endpoint: try RelayEndpoint(url), identity: identity)
        coordinator = CompanionDeviceCoordinator(identity: identity, relay: relay, secureFactory: PinnedTLSChannelFactory())
        self.input = input
    }

    func connect() async throws -> CompanionIPCLaneState {
        try await relay.presence()
        try Task.checkCancellation()
        await coordinator.registerExplicitPairing(peer)
        try await coordinator.connect(deviceID: peer.deviceID, lane: lane)
        try await coordinator.authorizeLane(deviceID: peer.deviceID, lane: lane, grantID: input.grantID)
        guard let state = await coordinator.state(deviceID: peer.deviceID),
              case .connected(let sessionID) = state.lanes[lane], let id = UUID(uuidString: sessionID) else {
            throw CompanionTransportError.authenticationRequired
        }
        return CompanionIPCLaneState(lane: input.lane, sessionID: id)
    }

    func heartbeat() async throws { try await relay.presence() }
    func read(maximumBytes: Int) async throws -> Data {
        try await coordinator.receive(deviceID: peer.deviceID, lane: lane, maximumBytes: maximumBytes)
    }
    func write(_ data: Data) async throws { try await coordinator.send(deviceID: peer.deviceID, lane: lane, plaintext: data) }
    func close() async { await coordinator.revoke(deviceID: peer.deviceID) }
}
