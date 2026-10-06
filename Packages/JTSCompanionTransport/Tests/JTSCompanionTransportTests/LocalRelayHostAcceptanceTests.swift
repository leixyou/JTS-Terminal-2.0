import CryptoKit
import Darwin
import Foundation
import JTSRelayEnrollment
import XCTest
@testable import JTSCompanionTransport

/// Opt-in acceptance against an independently built relay executable. No sibling source is
/// imported, no production node is changed, and disposable secrets are never printed.
final class LocalRelayHostAcceptanceTests: XCTestCase {
    func testRealRelayEnrollmentPinnedHostGrantByteRoundTripAndReconnect() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dotnet = env["JTS_LOCAL_RELAY_DOTNET"], let server = env["JTS_LOCAL_RELAY_SERVER_DLL"] else {
            throw XCTSkip("Independent local relay acceptance fixture not explicitly configured.")
        }
        let controllerKey = P256.Signing.PrivateKey(), hostKey = P256.Signing.PrivateKey()
        let controller = RelayIdentity(privateKey: controllerKey), host = RelayIdentity(privateKey: hostKey)
        let fixture = try LocalRelayFixture(dotnet: dotnet, server: server, controller: controller)
        defer { fixture.close() }
        let endpoint = try RelayEndpoint(URL(string: fixture.origin)!)
        let controllerRelay = RelayHTTPClient(endpoint: endpoint, identity: controller)
        try await fixture.waitUntilReady(controllerRelay)
        let enrollment = try EnrollmentClient(privateKey: controllerKey.rawRepresentation, relayOrigin: fixture.origin)
        var controllerAttempt = try EnrollmentAttempt(relayOrigin: fixture.origin,
            request: EnrollmentRequest(controllerSPKI: controller.publicKeySPKI, allowWindows10TLS12: false))
        let pending = try await enrollment.create(controllerAttempt)
        XCTAssertEqual(pending.state, .pending)
        let companionEnrollment = try EnrollmentHostClient(privateKey: hostKey.rawRepresentation)
        let hostAttempt = try await companionEnrollment.prepare(code: controllerAttempt.code, name: "Disposable Mac host")
        // Exercise the exact state recovered from encrypted storage without storing any real key.
        let recovered = try JSONDecoder().decode(EnrollmentHostAttempt.self, from: EnrollmentWire.encode(hostAttempt))
        try recovered.validate()
        let initial = try await companionEnrollment.receipt(recovered)
        XCTAssertEqual(initial.state, .pending); XCTAssertNil(initial.authorization)
        let claimed = try await companionEnrollment.claim(recovered)
        XCTAssertEqual(claimed.state, .claimed); XCTAssertNil(claimed.authorization)
        controllerAttempt.verifiedClaim = try await enrollment.status(controllerAttempt).claim
        controllerAttempt.confirmation = try await enrollment.prepareConfirmation(controllerAttempt)
        let committed = try await enrollment.confirm(controllerAttempt)
        XCTAssertEqual(committed.state, .bound)
        let bound = try await companionEnrollment.receipt(recovered)
        let authorization = try XCTUnwrap(bound.authorization)
        XCTAssertEqual(authorization.controllerSPKI, controller.publicKeySPKI)
        XCTAssertEqual(authorization.controllerDeviceID, controller.deviceID)
        let hostRelay = RelayHTTPClient(endpoint: endpoint, identity: host)
        try await hostRelay.presence(); try await controllerRelay.presence()
        let legacy = try await controllerRelay.info(), caps = try await controllerRelay.capabilities()
        XCTAssertFalse(legacy.lanes.contains(.desktop)); XCTAssertTrue(caps.lanes.contains(.desktop))
        let hostPeer = try PairedCompanionDevice(publicKeySPKI: authorization.controllerSPKI, allowedLanes: [.rdp, .desktop])
        let controllerPeer = try PairedCompanionDevice(publicKeySPKI: host.publicKeySPKI, allowedLanes: [.rdp, .desktop])
        // One initial connection and a fresh connection using only the durable paired identity.
        for lane in [RelayLane.rdp, .rdp, .desktop] {
            let pair = try await connect(endpoint: endpoint, controller: controller, host: host, controllerRelay: controllerRelay,
                hostRelay: hostRelay, controllerPeer: controllerPeer, hostPeer: hostPeer, lane: lane)
            do {
                async let accepted = CompanionHostLaneAuthorization.accept(channel: pair.host, approvedGrantIDs: [authorization.rdpGrantID])
                try await pair.coordinator.authorizeLane(deviceID: host.deviceID, lane: lane, grantID: authorization.rdpGrantID)
                let grant = try await accepted
                XCTAssertEqual(grant, authorization.rdpGrantID)
                let payload = Data((0..<32_768).map { UInt8(truncatingIfNeeded: $0) })
                async let hostBytes = readExactly(pair.host, count: payload.count)
                try await pair.coordinator.send(deviceID: host.deviceID, lane: lane, plaintext: payload)
                let atHost = try await hostBytes; XCTAssertEqual(atHost, payload)
                async let controllerBytes = readExactly(pair.coordinator, peer: host.deviceID, lane: lane, count: payload.count)
                try await pair.host.send(atHost)
                let returned = try await controllerBytes; XCTAssertEqual(returned, payload)
            } catch { await pair.host.close(); await pair.coordinator.revoke(deviceID: host.deviceID); throw error }
            await pair.host.close(); await pair.coordinator.revoke(deviceID: host.deviceID)
        }
        let denied = try await connect(endpoint: endpoint, controller: controller, host: host, controllerRelay: controllerRelay,
            hostRelay: hostRelay, controllerPeer: controllerPeer, hostPeer: hostPeer, lane: .rdp)
        let accepting = Task { try await CompanionHostLaneAuthorization.accept(channel: denied.host, approvedGrantIDs: [authorization.rdpGrantID]) }
        do { try await denied.coordinator.authorizeLane(deviceID: host.deviceID, lane: .rdp, grantID: UUID()); XCTFail("Wrong grant") }
        catch { }
        do { _ = try await accepting.value; XCTFail("Host accepted unapproved grant") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unauthorizedDevice) }
        await denied.coordinator.revoke(deviceID: host.deviceID)
        let bundle = try controllerAttempt.bundle(for: XCTUnwrap(controllerAttempt.verifiedClaim))
        let revocation = try await enrollment.prepareRevocation(bundle)
        let submitted = try await enrollment.submitRevocation(revocation, peerSPKI: host.publicKeySPKI)
        XCTAssertEqual(submitted.state, .pending)
        let hostRevocation = try EnrollmentHostRevocationClient(privateKey: hostKey.rawRepresentation, relayOrigin: fixture.origin)
        let requests = try await hostRevocation.poll(authorizations: [authorization])
        XCTAssertEqual(requests, [revocation])
        // The composition layer has closed every live bridge above. Persist the exact signed ack for retries.
        let receipt = try await hostRevocation.prepareReceipt(for: revocation, authorization: authorization)
        let savedReceipt = try JSONDecoder().decode(EnrollmentRevocationReceipt.self, from: EnrollmentWire.encode(receipt))
        let completion = try await hostRevocation.complete(savedReceipt, revocation: revocation, authorization: authorization)
        XCTAssertEqual(completion.state, .complete)
        let retry = try await hostRevocation.complete(savedReceipt, revocation: revocation, authorization: authorization)
        XCTAssertEqual(retry.receipt, savedReceipt)
        let observed = try await enrollment.revocationStatus(revocation, peerSPKI: host.publicKeySPKI)
        XCTAssertEqual(observed.state, .complete); XCTAssertEqual(observed.receipt, savedReceipt)
        do { _ = try await controllerRelay.createSession(peerDeviceID: host.deviceID, lane: .rdp); XCTFail("Revoked pair created new session") }
        catch { }
        print("LOCAL_RELAY_HOST_OK enrollment_signed_bound=true pinned_mtls=true rdp_grant=true bytes=32768 reconnect=true desktop_capability=true wrong_grant_rejected=true signed_revocation_ack=true revoked_new_session_denied=true native_screen_login=false")
    }

    private func connect(endpoint: RelayEndpoint, controller: RelayIdentity, host: RelayIdentity,
                         controllerRelay: RelayHTTPClient, hostRelay: RelayHTTPClient,
                         controllerPeer: PairedCompanionDevice, hostPeer: PairedCompanionDevice, lane: RelayLane) async throws
        -> (coordinator: CompanionDeviceCoordinator, host: any CompanionSecureChannel) {
        let coordinator = CompanionDeviceCoordinator(identity: controller, relay: controllerRelay, secureFactory: PinnedTLSChannelFactory())
        await coordinator.registerExplicitPairing(controllerPeer)
        let connecting = Task { try await coordinator.connect(deviceID: host.deviceID, lane: lane) }
        do {
            var offered: RelaySessionOffer?
            for _ in 0..<100 {
                if let offer = try await hostRelay.poll().first(where: { $0.lane == lane && $0.controllerDeviceId == controller.deviceID }) {
                    offered = offer; break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let offer = try XCTUnwrap(offered)
            let binding = try CompanionLaneBinding(sessionID: offer.sessionId, lane: lane,
                controllerDeviceID: controller.deviceID, companionDeviceID: host.deviceID)
            let carrier = try await RelayWebSocketCarrier.connect(endpoint: endpoint, ticket: offer.sessionTicket, lane: lane)
            let channel = try await PinnedTLSChannelFactory().accept(carrier: carrier, identity: host, peer: hostPeer, binding: binding)
            try await connecting.value
            return (coordinator, channel)
        } catch {
            connecting.cancel(); await coordinator.revoke(deviceID: host.deviceID)
            _ = try? await connecting.value
            throw error
        }
    }

    private func readExactly(_ channel: any CompanionSecureChannel, count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count { bytes.append(try await channel.receive(maximumBytes: min(16_384, count - bytes.count))) }
        return bytes
    }
    private func readExactly(_ coordinator: CompanionDeviceCoordinator, peer: String, lane: RelayLane, count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count { bytes.append(try await coordinator.receive(deviceID: peer, lane: lane, maximumBytes: min(16_384, count - bytes.count))) }
        return bytes
    }
}

private final class LocalRelayFixture {
    let directory: URL
    let origin: String
    private let process = Process()
    init(dotnet: String, server: String, controller: RelayIdentity) throws {
        guard dotnet.hasPrefix("/"), server.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: dotnet),
              FileManager.default.fileExists(atPath: server) else { throw CompanionTransportError.invalidEndpoint }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jts-local-relay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let port = try Self.unusedPort()
        origin = "https://127.0.0.1:" + String(port)
        do {
            let cert = directory.appendingPathComponent("tls.crt"), key = directory.appendingPathComponent("tls.key")
            let certificate = Process(); certificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            certificate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", key.path, "-out", cert.path, "-days", "1", "-subj", "/CN=127.0.0.1",
                "-addext", "subjectAltName=IP:127.0.0.1"]
            certificate.standardOutput = FileHandle.nullDevice; certificate.standardError = FileHandle.nullDevice
            try certificate.run(); certificate.waitUntilExit()
            guard certificate.terminationStatus == 0 else { throw CompanionTransportError.invalidIdentity }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cert.path)
            let config: [String: Any] = ["Kestrel": ["Endpoints": ["Https": ["Url": origin,
                "Certificate": ["Path": cert.path, "KeyPath": key.path]]]],
                "Relay": ["DatabasePath": directory.appendingPathComponent("relay.sqlite").path,
                    "PublicOrigin": origin, "MaxRequestsPerMinute": 10000,
                    "Devices": [["DeviceId": controller.deviceID, "PublicKeySpkiBase64": controller.publicKeySPKI.base64EncodedString(),
                                 "Role": "controller", "Peers": []]]]]
            let path = directory.appendingPathComponent("relay.json")
            try JSONSerialization.data(withJSONObject: config, options: .sortedKeys).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            process.executableURL = URL(fileURLWithPath: dotnet); process.arguments = [server, "--config", path.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func waitUntilReady(_ relay: RelayHTTPClient) async throws {
        for _ in 0..<100 {
            guard process.isRunning else { throw CompanionTransportError.connectionClosed }
            if (try? await relay.info()) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CompanionTransportError.connectionClosed
    }
    func close() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
    private static func unusedPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CompanionTransportError.connectionClosed }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }}
        guard bound == 0 else { throw CompanionTransportError.connectionClosed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }}
        guard status == 0 else { throw CompanionTransportError.connectionClosed }
        return UInt16(bigEndian: address.sin_port)
    }
}
