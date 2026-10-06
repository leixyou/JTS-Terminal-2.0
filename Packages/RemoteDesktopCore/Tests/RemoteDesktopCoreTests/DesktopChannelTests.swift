import XCTest
import Network
import Security
@testable import RemoteDesktopCore

final class DesktopChannelTests: XCTestCase {
    func testEncryptedLoopbackWithMultipleDeviceKeys() throws {
        let invitationPSK = Data(repeating: 1, count: 32)
        let devicePSK = Data(repeating: 2, count: 32)
        let identity = UUID().uuidString
        let parameters = try DesktopTLS.parameters(preSharedKeys: [
            .init(identity: DesktopProtocol.invitationIdentity, key: invitationPSK),
            .init(identity: identity, key: devicePSK)
        ])
        let listener = try NWListener(using: parameters, on: .any)
        let listening = expectation(description: "TLS listener")
        let response = expectation(description: "Encrypted echo")
        let queue = DispatchQueue(label: "DesktopChannelTests")
        var server: DesktopChannel?
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            server = DesktopChannel(connection: connection)
            server?.onStateChange = { state in
                if case .ready = state {
                    let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    XCTAssertNotNil(metadata)
                    if let metadata {
                        XCTAssertEqual(sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata), .TLSv12)
                        let cipher = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
                        XCTAssertEqual(cipher, UInt16(0xCCAC))
                    }
                }
            }
            server?.onMessage = { if case .ping(let value) = $0 { server?.send(.pong(value)) } }
            server?.start(queue: queue)
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = try DesktopChannel(host: "127.0.0.1", port: port.rawValue, psk: devicePSK, identity: identity)
        client.onStateChange = { if case .ready = $0 { client.send(.ping(42)) } }
        client.onMessage = { if case .pong(42) = $0 { response.fulfill() } }
        client.start(queue: queue)
        defer {
            client.cancel()
            server?.cancel()
            listener.cancel()
            client.onStateChange = nil
            client.onMessage = nil
            server?.onMessage = nil
        }
        wait(for: [response], timeout: 8)
    }

    func testWrongPSKCannotConnect() throws {
        let listener = try NWListener(using: DesktopTLS.parameters(psk: Data(repeating: 1, count: 32)), on: .any)
        let listening = expectation(description: "TLS listener")
        let rejected = expectation(description: "Wrong PSK rejected")
        let queue = DispatchQueue(label: "DesktopChannelWrongPSKTests")
        var server: DesktopChannel?
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            server = DesktopChannel(connection: connection)
            server?.start(queue: queue)
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = try DesktopChannel(host: "127.0.0.1", port: port.rawValue, psk: Data(repeating: 8, count: 32))
        client.onStateChange = { state in
            if case .failed(let error) = state {
                guard case .tls = error else { XCTFail("Expected a TLS rejection, got \(error)"); return }
                rejected.fulfill()
            }
            if case .waiting(let error) = state {
                guard case .tls = error else { XCTFail("Expected a TLS rejection, got \(error)"); return }
                rejected.fulfill()
            }
            if case .ready = state { XCTFail("TLS accepted an incorrect PSK") }
        }
        client.start(queue: queue)
        defer { client.cancel(); server?.cancel(); listener.cancel() }
        wait(for: [rejected], timeout: 8)
    }

    func testInvalidKeyConfigurationIsRejected() throws {
        XCTAssertThrowsError(try DesktopTLS.parameters(psk: Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try DesktopTLS.parameters(preSharedKeys: []))
        XCTAssertThrowsError(try DesktopTLS.parameters(preSharedKeys: [
            .init(identity: "same", key: Data(repeating: 0, count: 32)),
            .init(identity: "same", key: Data(repeating: 0, count: 32))
        ]))
    }
}
