import Foundation

/// Production transport factory. Missing/incorrect peer pins, ALPN or lane bindings fail closed.
/// It does not persist keys or authorize the application's commands; callers still enforce grants.
public struct PinnedTLSChannelFactory: CompanionSecureChannelFactory {
    public init() {}

    public func authenticate(carrier: any RelayByteCarrier, identity: RelayIdentity,
                             peer: PairedCompanionDevice,
                             binding: CompanionLaneBinding) async throws -> any CompanionSecureChannel {
        try await withTaskCancellationHandler {
            try await authenticateAndBind(carrier: carrier, identity: identity, peer: peer, binding: binding)
        } onCancel: {
            // Do not rely on a carrier implementation propagating task cancellation to socket I/O.
            Task { await carrier.close() }
        }
    }

    private func authenticateAndBind(carrier: any RelayByteCarrier, identity: RelayIdentity,
                                     peer: PairedCompanionDevice,
                                     binding: CompanionLaneBinding) async throws -> any CompanionSecureChannel {
        guard binding.controllerDeviceId == identity.deviceID, binding.companionDeviceId == peer.deviceID,
              peer.allowedLanes.contains(binding.lane) else {
            await carrier.close()
            throw CompanionTransportError.unauthorizedDevice
        }
        let channel: PinnedTLSChannel
        do {
            channel = try PinnedTLSChannel(carrier: carrier, identity: identity, peer: peer, binding: binding)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await channel.establish() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    await carrier.close()
                    throw CompanionTransportError.tlsHandshakeFailed
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            return channel
        } catch {
            await carrier.close()
            throw error
        }
    }
}

actor PinnedTLSChannel: CompanionSecureChannel {
    nonisolated let binding: CompanionLaneBinding
    private let carrier: any RelayByteCarrier
    private let engine: PinnedTLSEngine
    private enum Phase { case handshaking, binding, open, closed }
    private var phase = Phase.handshaking
    private var reading = false
    private var writing = false
    private var outputLocked = false
    private var outputWaiters: [CheckedContinuation<Void, Never>] = []

    init(carrier: any RelayByteCarrier, identity: RelayIdentity,
         peer: PairedCompanionDevice, binding: CompanionLaneBinding, server: Bool = false) throws {
        self.carrier = carrier
        self.binding = binding
        engine = try PinnedTLSEngine(identity: identity, peerSPKI: peer.publicKeySPKI,
                                    allowTLS12: peer.allowWindows10TLS12, server: server)
    }

    func establish() async throws {
        guard phase == .handshaking else { throw CompanionTransportError.operationInProgress }
        do {
            while true {
                try Task.checkCancellation()
                let finished = try engine.handshake()
                try await flush()
                if finished { break }
                try await feed()
            }
            guard phase != .closed, engine.authenticated else { throw CompanionTransportError.tlsPeerRejected }
            phase = .binding
            try await writePlaintext(binding.framed())
            var decoder = CompanionBindingDecoder()
            while !decoder.completed {
                try decoder.append(await readPlaintext(maximumBytes: decoder.bytesNeeded), expected: binding)
            }
            guard phase != .closed else { throw CompanionTransportError.connectionClosed }
            phase = .open
        } catch { await close(); throw error }
    }

    func send(_ plaintext: Data) async throws {
        guard phase == .open else { throw CompanionTransportError.authenticationRequired }
        guard !writing else { throw CompanionTransportError.operationInProgress }
        guard !plaintext.isEmpty, plaintext.count <= RelayLimits.webSocketMessageBytes else {
            throw CompanionTransportError.frameTooLarge
        }
        writing = true
        defer { writing = false }
        try await withTaskCancellationHandler {
            do { try await writePlaintext(plaintext) }
            catch { await close(); throw error }
        } onCancel: { Task { await self.close() } }
    }

    func receive(maximumBytes: Int) async throws -> Data {
        guard phase == .open else { throw CompanionTransportError.authenticationRequired }
        guard !reading else { throw CompanionTransportError.operationInProgress }
        guard maximumBytes > 0, maximumBytes <= RelayLimits.webSocketMessageBytes else {
            throw CompanionTransportError.frameTooLarge
        }
        reading = true
        defer { reading = false }
        return try await withTaskCancellationHandler {
            do { return try await readPlaintext(maximumBytes: maximumBytes) }
            catch { await close(); throw error }
        } onCancel: { Task { await self.close() } }
    }

    func close() async {
        phase = .closed
        await carrier.close()
    }

    private func writePlaintext(_ plaintext: Data) async throws {
        var remaining = plaintext
        while !remaining.isEmpty {
            try Task.checkCancellation()
            guard phase != .closed else { throw CompanionTransportError.connectionClosed }
            let written = try engine.write(remaining)
            try await flush()
            // Renegotiation/post-handshake authentication is disabled. Do not compete with the
            // dedicated reader for ciphertext if a peer nevertheless induces a write-side retry.
            guard written > 0 else { throw CompanionTransportError.tlsHandshakeFailed }
            remaining.removeFirst(written)
        }
    }

    private func readPlaintext(maximumBytes: Int) async throws -> Data {
        while true {
            try Task.checkCancellation()
            guard phase != .closed else { throw CompanionTransportError.connectionClosed }
            let bytes = try engine.read(maximumBytes: maximumBytes)
            try await flush()
            if let bytes, !bytes.isEmpty { return bytes }
            try await feed()
        }
    }

    private func feed() async throws {
        let ciphertext = try await carrier.read(maximumBytes: RelayLimits.webSocketMessageBytes)
        guard phase != .closed else { throw CompanionTransportError.connectionClosed }
        try engine.feed(ciphertext)
    }

    private func flush() async throws {
        if outputLocked {
            await withCheckedContinuation { outputWaiters.append($0) }
        } else { outputLocked = true }
        defer {
            if outputWaiters.isEmpty { outputLocked = false }
            else { outputWaiters.removeFirst().resume() }
        }
        while let ciphertext = try engine.drain() {
            try Task.checkCancellation()
            guard phase != .closed else { throw CompanionTransportError.connectionClosed }
            try await carrier.write(ciphertext)
        }
    }
}
