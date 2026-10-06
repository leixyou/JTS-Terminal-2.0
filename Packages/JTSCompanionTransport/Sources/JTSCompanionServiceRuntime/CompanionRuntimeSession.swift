import CryptoKit
import Foundation
import JTSCompanionIPC
import JTSCompanionTransport

/// One explicitly paired control route. No desktop state, arbitrary byte forwarding or permission creation.
protocol CompanionRuntimeSession: Sendable {
    func connect() async throws -> String
    func heartbeat() async throws
    func execute(_ request: CompanionIPCRequest) async throws -> Data
    func close() async
}

struct PinnedCompanionRuntimeSession: CompanionRuntimeSession {
    let identity: RelayIdentity
    let relay: RelayHTTPClient
    let coordinator: CompanionDeviceCoordinator
    let peer: PairedCompanionDevice

    init(_ input: CompanionIPCOpen) throws {
        try input.validate()
        identity = RelayIdentity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: input.privateKey))
        peer = try PairedCompanionDevice(publicKeySPKI: input.peerSPKI, allowedLanes: [.control],
                                        allowWindows10TLS12: input.allowWindows10TLS12)
        guard peer.deviceID != identity.deviceID, let url = URL(string: input.relayURL) else {
            throw CompanionTransportError.invalidIdentity
        }
        relay = RelayHTTPClient(endpoint: try RelayEndpoint(url), identity: identity)
        coordinator = CompanionDeviceCoordinator(identity: identity, relay: relay, secureFactory: PinnedTLSChannelFactory())
    }

    func connect() async throws -> String {
        try await relay.presence()
        try Task.checkCancellation()
        await coordinator.registerExplicitPairing(peer)
        try await coordinator.connect(deviceID: peer.deviceID, lane: .control)
        guard let state = await coordinator.state(deviceID: peer.deviceID),
              case .connected(let sessionID) = state.lanes[.control] else {
            throw CompanionTransportError.authenticationRequired
        }
        return sessionID
    }

    func heartbeat() async throws { try await relay.presence() }

    func execute(_ request: CompanionIPCRequest) async throws -> Data {
        let client = try await coordinator.controlClient(deviceID: peer.deviceID)
        switch request.operation {
        case .authorizeDesktop:
            let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCDesktopAuthorization.self)
            return try CompanionIPCCodec.encodePayload(await client.authorizeDesktop(input, identity: identity,
                endpoint: relay.endpoint, peerSPKI: peer.publicKeySPKI))
        case .status:
            let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCGrant.self)
            return try CompanionIPCCodec.encodePayload(await client.status(grantID: input.grantID))
        case .submit:
            let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCSubmit.self)
            return try CompanionIPCCodec.encodePayload(await client.submit(jobID: input.jobID, grantID: input.grantID,
                kind: input.kind, deadline: Date(timeIntervalSince1970: Double(input.deadlineUnixMilliseconds) / 1000),
                payload: input.payload, allowDisconnected: input.allowDisconnected))
        case .job, .cancel:
            let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCJob.self)
            let receipt = request.operation == .job
                ? try await client.job(jobID: input.jobID, grantID: input.grantID)
                : try await client.cancel(jobID: input.jobID, grantID: input.grantID)
            return try CompanionIPCCodec.encodePayload(receipt)
        case .output:
            let input = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCOutput.self)
            return try CompanionIPCCodec.encodePayload(await client.output(jobID: input.jobID, grantID: input.grantID,
                offset: input.offset, maximumBytes: input.maximumBytes))
        default: throw CompanionControlError.invalidRequest
        }
    }

    func close() async { await coordinator.revoke(deviceID: peer.deviceID) }
}
