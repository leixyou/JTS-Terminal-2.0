import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionTransport

final class TLSTests: XCTestCase {
    func testMutualPinnedTLSMemoryBIOEncryptsAndRoundTrips() throws {
        let mac = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let windows = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let client = try PinnedTLSEngine(identity: mac, peerSPKI: windows.publicKeySPKI, allowTLS12: false)
        let server = try PinnedTLSEngine(identity: windows, peerSPKI: mac.publicKeySPKI, allowTLS12: false, server: true)
        XCTAssertThrowsError(try client.write(Data("not before TLS".utf8)))
        try handshake(client, server)
        XCTAssertTrue(client.authenticated)
        XCTAssertTrue(server.authenticated)
        let plaintext = Data("a private command or file is not a relay instruction".utf8)
        XCTAssertEqual(try client.write(plaintext), plaintext.count)
        let ciphertext = try XCTUnwrap(client.drain())
        XCTAssertNil(ciphertext.range(of: plaintext))
        // Fragmentation is independent of TLS record boundaries.
        for byte in ciphertext { try server.feed(Data([byte])) }
        XCTAssertEqual(try server.read(maximumBytes: 1024), plaintext)
        XCTAssertEqual(try server.write(Data([0, 1, 2])), 3)
        try transfer(server, client)
        XCTAssertEqual(try client.read(maximumBytes: 10), Data([0, 1, 2]))
    }

    func testWrongPeerPinCannotFinishHandshake() throws {
        let mac = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let windows = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let impostor = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let client = try PinnedTLSEngine(identity: mac, peerSPKI: impostor.publicKeySPKI, allowTLS12: false)
        let server = try PinnedTLSEngine(identity: windows, peerSPKI: mac.publicKeySPKI, allowTLS12: false, server: true)
        XCTAssertThrowsError(try handshake(client, server))
        XCTAssertFalse(client.authenticated)
        XCTAssertThrowsError(try client.write(Data([1])))
    }

    func testServerRejectsWrongClientPin() throws {
        let mac = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let windows = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let other = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let client = try PinnedTLSEngine(identity: mac, peerSPKI: windows.publicKeySPKI, allowTLS12: false)
        let server = try PinnedTLSEngine(identity: windows, peerSPKI: other.publicKeySPKI, allowTLS12: false, server: true)
        XCTAssertThrowsError(try handshake(client, server))
        XCTAssertFalse(server.authenticated)
    }

    func testPlaintextAndOversizedTLSInputRejected() throws {
        let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let peer = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let server = try PinnedTLSEngine(identity: identity, peerSPKI: peer.publicKeySPKI, allowTLS12: false, server: true)
        XCTAssertThrowsError(try server.feed(Data(repeating: 1, count: 65537)))
        try server.feed(Data("GET /plaintext HTTP/1.1\r\n\r\n".utf8))
        XCTAssertThrowsError(try server.handshake())
        XCTAssertFalse(server.authenticated)
    }

    private func handshake(_ client: PinnedTLSEngine, _ server: PinnedTLSEngine) throws {
        for _ in 0..<20 {
            _ = try client.handshake()
            try transfer(client, server)
            _ = try server.handshake()
            try transfer(server, client)
            if client.authenticated && server.authenticated { return }
        }
        XCTFail("TLS handshake did not converge")
        throw CompanionTransportError.tlsHandshakeFailed
    }

    private func transfer(_ source: PinnedTLSEngine, _ destination: PinnedTLSEngine) throws {
        while let bytes = try source.drain() { try destination.feed(bytes) }
    }
}
