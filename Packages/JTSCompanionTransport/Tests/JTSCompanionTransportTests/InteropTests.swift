import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
@testable import JTSCompanionTransport

/// Explicitly gated integration fixture; never a production plaintext carrier or key export path.
final class InteropTests: XCTestCase {
    func testDotNetPinnedTLSBindingAndRoundTripAllLanes() async throws {
        let tools = try interopTools()
        for lane in RelayLane.allCases {
            let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
            let sessionID = UUID().uuidString.lowercased()
            let host = try startHost(tools: tools, controllerID: identity.deviceID, sessionID: sessionID, lane: lane)
            defer { if host.process.isRunning { host.process.terminate() } }
            let peer = try PairedCompanionDevice(publicKeySPKI: Data(base64Encoded: host.info.publicKeySpkiBase64)!,
                allowedLanes: [lane], allowWindows10TLS12: host.info.tlsPolicy == "tls12")
            XCTAssertEqual(peer.deviceID, host.info.companionDeviceId)
            let binding = try CompanionLaneBinding(sessionID: sessionID, lane: lane,
                controllerDeviceID: identity.deviceID, companionDeviceID: peer.deviceID)
            let carrier = try await TestLoopbackTCPCarrier.connect(port: host.info.port)
            let channel = try await PinnedTLSChannelFactory().authenticate(carrier: carrier, identity: identity,
                peer: peer, binding: binding)
            let payload = Data("\(lane.rawValue): Swift OpenSSL / dotnet SslStream pinned binding".utf8)
                + Data(repeating: 0xA5, count: 63 * 1024)
            var length = UInt32(payload.count).bigEndian
            let message = withUnsafeBytes(of: &length) { Data($0) } + payload
            async let incoming = readExactly(channel, count: message.count)
            try await channel.send(message)
            let received = try await incoming
            XCTAssertEqual(received, message)
            await channel.close()
            host.process.waitUntilExit()
            XCTAssertEqual(host.process.terminationStatus, 0)
        }
    }

    func testDotNetWrongClientPinRejected() async throws {
        let tools = try interopTools()
        let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let wrongIdentity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let sessionID = UUID().uuidString.lowercased()
        let host = try startHost(tools: tools, controllerID: wrongIdentity.deviceID, sessionID: sessionID, lane: .control)
        defer { if host.process.isRunning { host.process.terminate() } }
        let peer = try PairedCompanionDevice(publicKeySPKI: Data(base64Encoded: host.info.publicKeySpkiBase64)!,
            allowedLanes: [.control], allowWindows10TLS12: host.info.tlsPolicy == "tls12")
        let binding = try CompanionLaneBinding(sessionID: sessionID, lane: .control,
            controllerDeviceID: identity.deviceID, companionDeviceID: peer.deviceID)
        let carrier = try await TestLoopbackTCPCarrier.connect(port: host.info.port)
        do {
            _ = try await PinnedTLSChannelFactory().authenticate(carrier: carrier, identity: identity, peer: peer, binding: binding)
            XCTFail("accepted a client not in the C# peer trust")
        } catch { /* A protocol/TLS denial is expected; no application bytes are sent. */ }
        host.process.waitUntilExit()
        XCTAssertEqual(host.process.terminationStatus, 1)
    }

    func testDotNetRejectsCrossLaneBindingAfterTLS() async throws {
        let tools = try interopTools()
        let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let sessionID = UUID().uuidString.lowercased()
        let host = try startHost(tools: tools, controllerID: identity.deviceID, sessionID: sessionID, lane: .file)
        defer { if host.process.isRunning { host.process.terminate() } }
        let peer = try PairedCompanionDevice(publicKeySPKI: Data(base64Encoded: host.info.publicKeySpkiBase64)!,
            allowedLanes: [.control, .file], allowWindows10TLS12: host.info.tlsPolicy == "tls12")
        let binding = try CompanionLaneBinding(sessionID: sessionID, lane: .control,
            controllerDeviceID: identity.deviceID, companionDeviceID: peer.deviceID)
        let carrier = try await TestLoopbackTCPCarrier.connect(port: host.info.port)
        do {
            _ = try await PinnedTLSChannelFactory().authenticate(carrier: carrier, identity: identity, peer: peer, binding: binding)
            XCTFail("accepted a file stream as control after TLS")
        } catch { /* Mutual TLS alone must not authorize a mismatched lane. */ }
        host.process.waitUntilExit()
        XCTAssertEqual(host.process.terminationStatus, 1)
    }

    struct Tools { let dotnet: String; let hostDLL: String }
    struct HostInfo: Decodable {
        let port: UInt16
        let companionDeviceId, publicKeySpkiBase64, tlsPolicy: String
        let grantId: String?
    }

    func interopTools() throws -> Tools {
        let environment = ProcessInfo.processInfo.environment
        guard let dotnet = environment["JTS_INTEROP_DOTNET"], let dll = environment["JTS_INTEROP_HOST_DLL"] else {
            throw XCTSkip("Explicit local dotnet interop fixture not configured; not a Windows-runtime acceptance result.")
        }
        guard dotnet.hasPrefix("/"), dll.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: dotnet),
              FileManager.default.fileExists(atPath: dll) else { throw CompanionTransportError.invalidEndpoint }
        return Tools(dotnet: dotnet, hostDLL: dll)
    }

    func startHost(tools: Tools, controllerID: String, sessionID: String, lane: RelayLane, mode: String = "echo") throws -> (process: Process, info: HostInfo) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tools.dotnet)
        process.arguments = [tools.hostDLL]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        do {
            let request = try JSONSerialization.data(withJSONObject: ["controllerDeviceId": controllerID,
                "sessionId": sessionID, "lane": lane.rawValue, "mode": mode]) + Data([10])
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
            let data = try readPublicLine(output.fileHandleForReading)
            return (process, try JSONDecoder().decode(HostInfo.self, from: data))
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private func readPublicLine(_ handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < 2048 {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 10_000) > 0 else { throw CompanionTransportError.connectionClosed }
            var byte: UInt8 = 0
            guard Darwin.read(handle.fileDescriptor, &byte, 1) == 1 else { throw CompanionTransportError.connectionClosed }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw CompanionTransportError.responseTooLarge
    }

    private func readExactly(_ channel: any CompanionSecureChannel, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count { data += try await channel.receive(maximumBytes: count - data.count) }
        return data
    }
}

final class TestLoopbackTCPCarrier: RelayByteCarrier, @unchecked Sendable {
    private let connection: NWConnection
    private init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    static func connect(port: UInt16) async throws -> TestLoopbackTCPCarrier {
        guard port > 0 else { throw CompanionTransportError.invalidEndpoint }
        let carrier = TestLoopbackTCPCarrier(port: port)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            carrier.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    carrier.connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed, .cancelled:
                    carrier.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: CompanionTransportError.connectionClosed)
                default: break
                }
            }
            carrier.connection.start(queue: DispatchQueue(label: "JTS-test-only-loopback"))
        }
        return carrier
    }

    func read(maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= RelayLimits.webSocketMessageBytes else { throw CompanionTransportError.frameTooLarge }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) { bytes, _, _, error in
                if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: error ?? CompanionTransportError.connectionClosed) }
            }
        }
    }

    func write(_ bytes: Data) async throws {
        guard !bytes.isEmpty, bytes.count <= RelayLimits.webSocketMessageBytes else { throw CompanionTransportError.frameTooLarge }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func close() async { connection.cancel() }
}
