import CryptoKit
import Foundation

public struct PairedCompanionDevice: Sendable {
    public let deviceID: String
    public let publicKeySPKI: Data
    public let allowedLanes: Set<RelayLane>
    public let allowWindows10TLS12: Bool

    /// Only construct from an explicitly verified pairing record, never relay discovery metadata.
    public init(publicKeySPKI: Data, allowedLanes: Set<RelayLane>, allowWindows10TLS12: Bool = false) throws {
        let key = try P256.Signing.PublicKey(derRepresentation: publicKeySPKI)
        guard key.derRepresentation == publicKeySPKI else { throw CompanionTransportError.invalidIdentity }
        self.publicKeySPKI = publicKeySPKI
        deviceID = RelayIdentity.deviceID(publicKeySPKI: publicKeySPKI)
        self.allowedLanes = allowedLanes
        self.allowWindows10TLS12 = allowWindows10TLS12
    }
}

/// Implementations must complete pinned mutual TLS AND the inside-TLS lane binding before returning.
/// The relay's ready message alone cannot satisfy this interface.
public protocol CompanionSecureChannelFactory: Sendable {
    func authenticate(carrier: any RelayByteCarrier, identity: RelayIdentity,
                      peer: PairedCompanionDevice, binding: CompanionLaneBinding) async throws -> any CompanionSecureChannel
}

public protocol CompanionSecureChannel: Sendable {
    var binding: CompanionLaneBinding { get }
    func send(_ plaintext: Data) async throws
    func receive(maximumBytes: Int) async throws -> Data
    func close() async
}

/// A safe default for builds that have not linked a genuine mutual-TLS implementation.
public struct UnavailableCompanionTLS: CompanionSecureChannelFactory {
    public init() {}
    public func authenticate(carrier: any RelayByteCarrier, identity: RelayIdentity,
                             peer: PairedCompanionDevice,
                             binding: CompanionLaneBinding) async throws -> any CompanionSecureChannel {
        await carrier.close()
        throw CompanionTransportError.tlsUnavailable
    }
}

public enum CompanionLaneState: Equatable, Sendable {
    case disconnected, connecting, authenticating, connected(sessionID: String), failed
}

public struct CompanionDeviceState: Equatable, Sendable {
    public let deviceID: String
    public var lanes: [RelayLane: CompanionLaneState] = [:]
    // Desktop login/open state deliberately does not gate device transport.
}

public protocol RelayCarrierFactory: Sendable {
    func connect(endpoint: RelayEndpoint, ticket: RelaySessionTicket,
                 lane: RelayLane) async throws -> any RelayByteCarrier
}

public struct WebSocketRelayCarrierFactory: RelayCarrierFactory {
    public init() {}
    public func connect(endpoint: RelayEndpoint, ticket: RelaySessionTicket,
                        lane: RelayLane) async throws -> any RelayByteCarrier {
        try await RelayWebSocketCarrier.connect(endpoint: endpoint, ticket: ticket, lane: lane)
    }
}

public actor CompanionDeviceCoordinator {
    private let identity: RelayIdentity
    private let relay: RelayHTTPClient
    private let carrierFactory: any RelayCarrierFactory
    private let secureFactory: any CompanionSecureChannelFactory
    private var peers: [String: PairedCompanionDevice] = [:]
    private var states: [String: CompanionDeviceState] = [:]
    private var channels: [String: [RelayLane: any CompanionSecureChannel]] = [:]
    private var controlClients: [String: CompanionControlClient] = [:]
    private var generations: [String: UUID] = [:]

    public init(identity: RelayIdentity, relay: RelayHTTPClient,
                carrierFactory: any RelayCarrierFactory = WebSocketRelayCarrierFactory(),
                secureFactory: any CompanionSecureChannelFactory = UnavailableCompanionTLS()) {
        self.identity = identity
        self.relay = relay
        self.carrierFactory = carrierFactory
        self.secureFactory = secureFactory
    }

    public func registerExplicitPairing(_ peer: PairedCompanionDevice) async {
        await revoke(deviceID: peer.deviceID)
        peers[peer.deviceID] = peer
        generations[peer.deviceID] = UUID()
        states[peer.deviceID] = CompanionDeviceState(deviceID: peer.deviceID)
    }

    public func state(deviceID: String) -> CompanionDeviceState? { states[deviceID] }

    public func controlClient(deviceID: String) throws -> CompanionControlClient {
        guard peers[deviceID]?.allowedLanes.contains(.control) == true, let client = controlClients[deviceID] else {
            throw CompanionTransportError.authenticationRequired
        }
        return client
    }

    public func connect(deviceID: String, lane: RelayLane) async throws {
        guard let peer = peers[deviceID], let generation = generations[deviceID] else {
            throw CompanionTransportError.unauthorizedDevice
        }
        guard peer.allowedLanes.contains(lane) else { throw CompanionTransportError.unsupportedLane }
        switch states[deviceID]?.lanes[lane] ?? .disconnected {
        case .connecting, .authenticating, .connected: throw CompanionTransportError.alreadyConnected
        case .disconnected, .failed: break
        }
        states[deviceID]?.lanes[lane] = .connecting
        var carrier: (any RelayByteCarrier)?
        var authenticated: (any CompanionSecureChannel)?
        do {
            guard relay.deviceID == identity.deviceID else { throw CompanionTransportError.invalidIdentity }
            let info = try await relay.info()
            try requireGeneration(deviceID, generation)
            guard info.lanes.contains(lane) else { throw CompanionTransportError.unsupportedLane }
            let ticket = try await relay.createSession(peerDeviceID: deviceID, lane: lane)
            try requireGeneration(deviceID, generation)
            let raw = try await carrierFactory.connect(endpoint: relay.endpoint, ticket: ticket, lane: lane)
            carrier = raw
            try requireGeneration(deviceID, generation)
            let binding = try CompanionLaneBinding(sessionID: ticket.sessionId, lane: lane,
                controllerDeviceID: identity.deviceID, companionDeviceID: peer.deviceID)
            states[deviceID]?.lanes[lane] = .authenticating
            let channel = try await secureFactory.authenticate(carrier: raw, identity: identity, peer: peer, binding: binding)
            authenticated = channel
            try requireGeneration(deviceID, generation)
            guard channel.binding == binding else { throw CompanionTransportError.invalidBinding }
            channels[deviceID, default: [:]][lane] = channel
            if lane == .control {
                controlClients[deviceID] = try CompanionControlClient(channel: channel) { [weak self] in
                    await self?.failChannel(deviceID: deviceID, lane: lane, generation: generation, sessionID: binding.sessionId)
                }
            }
            states[deviceID]?.lanes[lane] = .connected(sessionID: ticket.sessionId)
        } catch {
            await authenticated?.close()
            await carrier?.close()
            if generations[deviceID] == generation { states[deviceID]?.lanes[lane] = .failed }
            throw error
        }
    }

    public func send(deviceID: String, lane: RelayLane, plaintext: Data) async throws {
        // The cached RPC client owns control framing and its single reader/writer.
        guard lane != .control else { throw CompanionTransportError.unsupportedLane }
        guard peers[deviceID]?.allowedLanes.contains(lane) == true,
              let channel = channels[deviceID]?[lane] else { throw CompanionTransportError.authenticationRequired }
        let generation = generations[deviceID]
        do { try await channel.send(plaintext) }
        catch {
            await failChannel(deviceID: deviceID, lane: lane, generation: generation, sessionID: channel.binding.sessionId)
            throw error
        }
    }

    public func authorizeLane(deviceID: String, lane: RelayLane, grantID: UUID) async throws {
        guard lane != .control, let channel = channels[deviceID]?[lane],
              let generation = generations[deviceID] else { throw CompanionTransportError.authenticationRequired }
        do {
            try await CompanionLaneAuthorization.authorize(channel: channel, grantID: grantID)
            try requireGeneration(deviceID, generation)
        } catch {
            await failChannel(deviceID: deviceID, lane: lane, generation: generation, sessionID: channel.binding.sessionId)
            throw error
        }
    }

    public func receive(deviceID: String, lane: RelayLane, maximumBytes: Int) async throws -> Data {
        guard lane != .control else { throw CompanionTransportError.unsupportedLane }
        guard peers[deviceID]?.allowedLanes.contains(lane) == true,
              let channel = channels[deviceID]?[lane] else { throw CompanionTransportError.authenticationRequired }
        let generation = generations[deviceID]
        do { return try await channel.receive(maximumBytes: maximumBytes) }
        catch {
            await failChannel(deviceID: deviceID, lane: lane, generation: generation, sessionID: channel.binding.sessionId)
            throw error
        }
    }

    public func revoke(deviceID: String) async {
        // Invalidate authorization before awaiting shutdown; in-flight connections cannot be resurrected.
        generations[deviceID] = nil
        peers[deviceID] = nil
        controlClients[deviceID] = nil
        states[deviceID] = nil
        let previous = channels.removeValue(forKey: deviceID) ?? [:]
        for channel in previous.values { await channel.close() }
    }

    private func requireGeneration(_ deviceID: String, _ generation: UUID) throws {
        guard generations[deviceID] == generation else { throw CompanionTransportError.unauthorizedDevice }
    }

    private func failChannel(deviceID: String, lane: RelayLane, generation: UUID?, sessionID: String) async {
        guard generations[deviceID] == generation,
              channels[deviceID]?[lane]?.binding.sessionId == sessionID else { return }
        let channel = channels[deviceID]?.removeValue(forKey: lane)
        if lane == .control { controlClients[deviceID] = nil }
        states[deviceID]?.lanes[lane] = .failed
        await channel?.close()
    }
}
