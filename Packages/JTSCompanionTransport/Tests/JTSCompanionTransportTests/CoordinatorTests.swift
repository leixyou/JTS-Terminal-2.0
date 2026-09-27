import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionTransport

actor ProtocolHTTPStub: RelayHTTPTransport {
    let identity: RelayIdentity
    var requests: [URLRequest] = []
    var responseVersion = 1
    var rejectSession = false
    var sessionCount = 0
    let challengeID = "00000000-0000-4000-8000-000000000002"
    let nonce = Data(repeating: 7, count: 32).base64EncodedString()
    init(identity: RelayIdentity) { self.identity = identity }

    func setVersion(_ version: Int) { responseVersion = version }
    func setRejectSession() { rejectSession = true }

    func perform(_ request: URLRequest, maximumResponseBytes: Int) throws -> RelayHTTPResponse {
        requests.append(request)
        let expiry = Int64(Date().timeIntervalSince1970) + 60
        switch request.url!.path {
        case "/v1/info":
            return response("{\"protocolVersion\":\(responseVersion),\"lanes\":[\"control\",\"file\",\"rdp\"]}")
        case "/v1/challenges":
            return response("{\"challengeId\":\"\(challengeID)\",\"nonceBase64\":\"\(nonce)\",\"expiresAtUnixSeconds\":\(expiry)}")
        case "/v1/sessions":
            let proof = try JSONDecoder().decode(RelayProof.self, from: request.httpBody!)
            let payload = Data(base64Encoded: proof.payloadBase64)!
            let challenge = RelayChallenge(challengeId: challengeID, nonceBase64: nonce, expiresAtUnixSeconds: expiry)
            let canonical = try RelayIdentity.canonicalProof(endpoint: try RelayEndpoint(URL(string: "https://relay.example")!), deviceID: identity.deviceID, operation: .sessions,
                challenge: challenge, payload: payload)
            let publicKey = try P256.Signing.PublicKey(derRepresentation: identity.publicKeySPKI)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: proof.signatureBase64)!)
            guard publicKey.isValidSignature(signature, for: canonical) else { throw CompanionTransportError.invalidIdentity }
            if rejectSession { return response("{\"code\":\"not_admitted\"}", status: 403) }
            sessionCount += 1
            return response("{\"sessionId\":\"\(UUID().uuidString)\",\"ticket\":\"\(String(repeating: "A", count: 43))\",\"expiresAtUnixSeconds\":\(expiry),\"channelPath\":\"/v1/channel\"}")
        default: throw CompanionTransportError.invalidResponse
        }
    }

    private func response(_ json: String, status: Int = 200) -> RelayHTTPResponse {
        RelayHTTPResponse(status: status, body: Data(json.utf8))
    }
}

actor RecordingCarrier: RelayByteCarrier {
    var closed = false
    var writes: [Data] = []
    func read(maximumBytes: Int) throws -> Data { throw CompanionTransportError.connectionClosed }
    func write(_ bytes: Data) { writes.append(bytes) }
    func close() { closed = true }
}

struct StubCarrierFactory: RelayCarrierFactory {
    let carrier: RecordingCarrier
    func connect(endpoint: RelayEndpoint, ticket: RelaySessionTicket, lane: RelayLane) -> any RelayByteCarrier { carrier }
}

actor TestAuthenticatedChannel: CompanionSecureChannel {
    nonisolated let binding: CompanionLaneBinding
    var closed = false
    init(binding: CompanionLaneBinding) { self.binding = binding }
    func send(_ plaintext: Data) throws { throw CompanionTransportError.connectionClosed }
    func receive(maximumBytes: Int) throws -> Data { throw CompanionTransportError.connectionClosed }
    func close() { closed = true }
}

struct TestAuthenticatedFactory: CompanionSecureChannelFactory {
    func authenticate(carrier: any RelayByteCarrier, identity: RelayIdentity, peer: PairedCompanionDevice,
                      binding: CompanionLaneBinding) -> any CompanionSecureChannel { TestAuthenticatedChannel(binding: binding) }
}

final class CoordinatorTests: XCTestCase {
    func testAbsentTLSImplementationClosesCarrierAndNeverSendsPlaintext() async throws {
        let fixture = try setup()
        await fixture.coordinator.registerExplicitPairing(fixture.peer)
        do { try await fixture.coordinator.connect(deviceID: fixture.peer.deviceID, lane: .control); XCTFail("connected without TLS") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .tlsUnavailable) }
        let state = await fixture.coordinator.state(deviceID: fixture.peer.deviceID)
        XCTAssertEqual(state?.lanes[.control], .failed)
        let writes = await fixture.carrier.writes
        let closed = await fixture.carrier.closed
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(closed)
        do { try await fixture.coordinator.send(deviceID: fixture.peer.deviceID, lane: .control, plaintext: Data([1])); XCTFail("sent") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unsupportedLane) }
    }

    func testUnpairedOrWrongLaneNeverRequestsSession() async throws {
        let fixture = try setup()
        do { try await fixture.coordinator.connect(deviceID: fixture.peer.deviceID, lane: .control); XCTFail("connected") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unauthorizedDevice) }
        await fixture.coordinator.registerExplicitPairing(fixture.peer)
        do { try await fixture.coordinator.connect(deviceID: fixture.peer.deviceID, lane: .rdp); XCTFail("connected") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unsupportedLane) }
        let requests = await fixture.http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnsupportedVersionStopsBeforeChallengeAndDoesNotRetry() async throws {
        let fixture = try setup()
        await fixture.http.setVersion(2)
        await fixture.coordinator.registerExplicitPairing(fixture.peer)
        do { try await fixture.coordinator.connect(deviceID: fixture.peer.deviceID, lane: .control); XCTFail("connected") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unsupportedVersion) }
        let requests = await fixture.http.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/info"])
    }

    func testAuthenticatedSessionFailureAllowsReconnectWithoutPairingReset() async throws {
        let fixture = try setup(secureFactory: TestAuthenticatedFactory())
        await fixture.coordinator.registerExplicitPairing(fixture.peer)
        try await fixture.coordinator.connect(deviceID: fixture.peer.deviceID, lane: .file)
        do { try await fixture.coordinator.send(deviceID: fixture.peer.deviceID, lane: .file, plaintext: Data([1])); XCTFail("sent") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .connectionClosed) }
        var state = await fixture.coordinator.state(deviceID: fixture.peer.deviceID)
        XCTAssertEqual(state?.lanes[.file], .failed)
        try await fixture.coordinator.connect(deviceID: fixture.peer.deviceID, lane: .file)
        do { _ = try await fixture.coordinator.receive(deviceID: fixture.peer.deviceID, lane: .file, maximumBytes: 10); XCTFail("read") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .connectionClosed) }
        state = await fixture.coordinator.state(deviceID: fixture.peer.deviceID)
        XCTAssertEqual(state?.lanes[.file], .failed)
        let count = await fixture.http.sessionCount
        XCTAssertEqual(count, 2)
        await fixture.coordinator.revoke(deviceID: fixture.peer.deviceID)
        let revoked = await fixture.coordinator.state(deviceID: fixture.peer.deviceID)
        XCTAssertNil(revoked)
    }

    func testControlClientIsExclusiveAndOldFailureCannotRemoveNewSession() async throws {
        let fixture = try setup(secureFactory: TestAuthenticatedFactory())
        await fixture.coordinator.registerExplicitPairing(fixture.peer)
        try await fixture.coordinator.connect(deviceID: fixture.peer.deviceID, lane: .control)
        let first = try await fixture.coordinator.controlClient(deviceID: fixture.peer.deviceID)
        let cached = try await fixture.coordinator.controlClient(deviceID: fixture.peer.deviceID)
        XCTAssertTrue(first === cached)
        do { _ = try await fixture.coordinator.receive(deviceID: fixture.peer.deviceID, lane: .control, maximumBytes: 4); XCTFail("raw control reader") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unsupportedLane) }
        do { _ = try await first.status(grantID: UUID()); XCTFail("stub cannot exchange") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .connectionClosed) }
        do { _ = try await fixture.coordinator.controlClient(deviceID: fixture.peer.deviceID); XCTFail("stale client") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .authenticationRequired) }
        try await fixture.coordinator.connect(deviceID: fixture.peer.deviceID, lane: .control)
        let second = try await fixture.coordinator.controlClient(deviceID: fixture.peer.deviceID)
        await first.close()
        let current = try await fixture.coordinator.controlClient(deviceID: fixture.peer.deviceID)
        XCTAssertTrue(second === current)
        XCTAssertFalse(first === second)
        await fixture.coordinator.revoke(deviceID: fixture.peer.deviceID)
        do { _ = try await fixture.coordinator.controlClient(deviceID: fixture.peer.deviceID); XCTFail("revoked client") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .authenticationRequired) }
    }

    private func setup(secureFactory: any CompanionSecureChannelFactory = UnavailableCompanionTLS()) throws
        -> (coordinator: CompanionDeviceCoordinator, peer: PairedCompanionDevice, http: ProtocolHTTPStub, carrier: RecordingCarrier) {
        let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let peer = try PairedCompanionDevice(publicKeySPKI: P256.Signing.PrivateKey().publicKey.derRepresentation, allowedLanes: [.control, .file])
        let http = ProtocolHTTPStub(identity: identity)
        let carrier = RecordingCarrier()
        let client = RelayHTTPClient(endpoint: try RelayEndpoint(URL(string: "https://relay.example")!), identity: identity, transport: http)
        let coordinator = CompanionDeviceCoordinator(identity: identity, relay: client,
            carrierFactory: StubCarrierFactory(carrier: carrier), secureFactory: secureFactory)
        return (coordinator, peer, http, carrier)
    }
}
