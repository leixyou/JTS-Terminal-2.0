import Foundation
import Network
import Security

public struct DesktopPreSharedKey: Equatable, Sendable {
    public var identity: String
    public var key: Data
    public init(identity: String, key: Data) {
        self.identity = identity
        self.key = key
    }
}

public enum DesktopTLS {
    public static func parameters(psk: Data, identity: String = DesktopProtocol.invitationIdentity) throws -> NWParameters {
        try parameters(preSharedKeys: [.init(identity: identity, key: psk)])
    }

    /// A listener contains the invitation key and each locally approved device's unique key.
    public static func parameters(preSharedKeys: [DesktopPreSharedKey]) throws -> NWParameters {
        guard !preSharedKeys.isEmpty, preSharedKeys.count <= 65,
              Set(preSharedKeys.map(\.identity)).count == preSharedKeys.count else {
            throw DesktopProtocolError.invalidSecret
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 provides forward secrecy and AEAD encryption.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        for entry in preSharedKeys {
            guard entry.key.count == 32 else { throw DesktopProtocolError.invalidSecret }
            try validateDesktopText(entry.identity, maximumBytes: 128)
            let key = entry.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(entry.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

/// Owns encrypted connection framing. Callbacks run on the serial queue supplied to `start`.
public final class DesktopChannel {
    public var onStateChange: ((NWConnection.State) -> Void)?
    public var onMessage: ((RemoteDesktopMessage) -> Void)?
    public var onError: ((Error) -> Void)?
    public let connection: NWConnection
    private var receiving = false
    private var callbackQueue = DispatchQueue.main
    private let workerQueue = DispatchQueue(label: "JTS.RemoteDesktop.Codec", qos: .userInitiated)
    private let pendingLock = NSLock()
    private var pendingSends = 0
    private var pendingBytes = 0
    private var handshakeTimeout: DispatchWorkItem?

    public init(host: String, port: UInt16, psk: Data, identity: String = DesktopProtocol.invitationIdentity) throws {
        guard !host.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw DesktopProtocolError.invalidInvitation
        }
        connection = NWConnection(host: .init(host), port: endpointPort,
                                  using: try DesktopTLS.parameters(psk: psk, identity: identity))
    }

    public init(connection: NWConnection) { self.connection = connection }

    public func start(queue: DispatchQueue) {
        callbackQueue = queue
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.receiving else { return }
            self.fail(DesktopProtocolError.connectionTimeout)
        }
        handshakeTimeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready, .failed, .cancelled:
                self.handshakeTimeout?.cancel()
                self.handshakeTimeout = nil
            default: break
            }
            self.onStateChange?(state)
            if case .ready = state, !self.receiving {
                self.receiving = true
                self.receiveHeader()
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() { connection.cancel() }

    public func send(_ message: RemoteDesktopMessage, completion: ((Error?) -> Void)? = nil) {
        do { try message.validate() }
        catch { callbackQueue.async { completion?(error) }; return }
        let cost: Int
        if case .frame(let frame) = message { cost = frame.jpeg.count * 4 / 3 + 1_024 }
        else { cost = 4_096 }
        pendingLock.lock()
        guard pendingSends < 128, pendingBytes + cost <= 32 * 1_024 * 1_024 else {
            pendingLock.unlock()
            callbackQueue.async { completion?(DesktopProtocolError.outboundQueueFull) }
            return
        }
        pendingSends += 1
        pendingBytes += cost
        pendingLock.unlock()
        workerQueue.async { [self] in
            do {
                let packet = try DesktopPacketCodec.encode(message)
                connection.send(content: packet, completion: .contentProcessed { [self] error in
                    finishSend(error, cost: cost, completion: completion)
                })
            } catch { finishSend(error, cost: cost, completion: completion) }
        }
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.fail(error); return }
            guard let data, data.count == 4 else {
                if complete, data == nil || data?.isEmpty == true { self.cancel() }
                else { self.fail(DesktopProtocolError.truncatedPacket) }
                return
            }
            do { self.receivePayload(length: try DesktopPacketCodec.payloadLength(header: data)) }
            catch { self.fail(error) }
        }
    }

    private func receivePayload(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { self.fail(error); return }
            guard let data, data.count == length else { self.fail(DesktopProtocolError.truncatedPacket); return }
            self.workerQueue.async {
                do {
                    let message = try DesktopPacketCodec.decodePayload(data)
                    self.callbackQueue.async {
                        self.onMessage?(message)
                        self.receiveHeader()
                    }
                } catch { self.callbackQueue.async { self.fail(error) } }
            }
        }
    }

    private func fail(_ error: Error) {
        onError?(error)
        connection.cancel()
    }

    private func finishSend(_ error: Error?, cost: Int, completion: ((Error?) -> Void)?) {
        pendingLock.lock()
        pendingSends -= 1
        pendingBytes -= cost
        pendingLock.unlock()
        callbackQueue.async { completion?(error) }
    }
}
