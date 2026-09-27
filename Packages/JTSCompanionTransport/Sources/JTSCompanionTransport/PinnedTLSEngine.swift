import CPinnedTLS
import CryptoKit
import Foundation

/// Synchronous memory-BIO engine. Its owner must serialize every operation (the channel actor does).
final class PinnedTLSEngine {
    private let handle: OpaquePointer

    init(identity: RelayIdentity, peerSPKI: Data, allowTLS12: Bool, server: Bool = false) throws {
        let key = identity.privateKeyDER
        let pin = Data(SHA256.hash(data: peerSPKI))
        let pointer = key.withUnsafeBytes { keyBytes in
            pin.withUnsafeBytes { pinBytes in
                jts_tls_create(keyBytes.bindMemory(to: UInt8.self).baseAddress, key.count,
                    pinBytes.bindMemory(to: UInt8.self).baseAddress, allowTLS12 ? 1 : 0, server ? 1 : 0)
            }
        }
        guard let pointer else { throw CompanionTransportError.tlsUnavailable }
        handle = pointer
    }

    deinit { jts_tls_free(handle) }

    var authenticated: Bool { jts_tls_is_authenticated(handle) == 1 }

    func handshake() throws -> Bool {
        let status = jts_tls_handshake(handle)
        guard status >= 0 else { throw CompanionTransportError.tlsHandshakeFailed }
        return status == 1
    }

    func feed(_ ciphertext: Data) throws {
        let status = ciphertext.withUnsafeBytes {
            jts_tls_feed(handle, $0.bindMemory(to: UInt8.self).baseAddress, ciphertext.count)
        }
        guard status == 1 else { throw CompanionTransportError.tlsHandshakeFailed }
    }

    func drain() throws -> Data? {
        var result = Data(count: RelayLimits.webSocketMessageBytes)
        var written = 0
        let status = result.withUnsafeMutableBytes {
            jts_tls_drain(handle, $0.bindMemory(to: UInt8.self).baseAddress,
                          RelayLimits.webSocketMessageBytes, &written)
        }
        guard status >= 0 else { throw CompanionTransportError.tlsHandshakeFailed }
        guard status == 1 else { return nil }
        result.count = written
        return result
    }

    func read(maximumBytes: Int) throws -> Data? {
        guard maximumBytes > 0, maximumBytes <= RelayLimits.webSocketMessageBytes else {
            throw CompanionTransportError.frameTooLarge
        }
        var result = Data(count: maximumBytes)
        var written = 0
        let status = result.withUnsafeMutableBytes {
            jts_tls_read(handle, $0.bindMemory(to: UInt8.self).baseAddress, maximumBytes, &written)
        }
        if status == -2 { throw CompanionTransportError.connectionClosed }
        guard status >= 0 else { throw CompanionTransportError.tlsHandshakeFailed }
        guard status == 1 else { return nil }
        result.count = written
        return result
    }

    func write(_ plaintext: Data) throws -> Int {
        var written = 0
        let status = plaintext.withUnsafeBytes {
            jts_tls_write(handle, $0.bindMemory(to: UInt8.self).baseAddress, plaintext.count, &written)
        }
        guard status >= 0 else { throw CompanionTransportError.tlsHandshakeFailed }
        return status == 1 ? written : 0
    }
}
