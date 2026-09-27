import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionTransport

final class ProtocolTests: XCTestCase {
    func testCrossLanguageProofVector() throws {
        struct Vector: Decodable {
            let deviceId: String, publicKeySpkiBase64: String, operation: RelayOperation
            let challengeId: String, nonceBase64: String, payloadBase64: String
            let canonicalUtf8: String, signatureBase64: String
        }
        let url = Bundle.module.url(forResource: "auth-presence", withExtension: "json", subdirectory: "Fixtures")!
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        let spki = Data(base64Encoded: vector.publicKeySpkiBase64)!
        XCTAssertEqual(RelayIdentity.deviceID(publicKeySPKI: spki), vector.deviceId)
        let challenge = RelayChallenge(challengeId: vector.challengeId, nonceBase64: vector.nonceBase64,
                                       expiresAtUnixSeconds: 1060)
        let canonical = try RelayIdentity.canonicalProof(deviceID: vector.deviceId, operation: vector.operation,
            challenge: challenge, payload: Data(base64Encoded: vector.payloadBase64)!, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(String(decoding: canonical, as: UTF8.self), vector.canonicalUtf8)
        XCTAssertFalse(canonical.last == 10)
        let publicKey = try P256.Signing.PublicKey(derRepresentation: spki)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: vector.signatureBase64)!)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: canonical))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: canonical + Data([10])))
    }

    func testProofUsesRawP1363AndRejectsExpiredChallenge() throws {
        let key = P256.Signing.PrivateKey()
        let identity = RelayIdentity(privateKey: key)
        let challenge = RelayChallenge(challengeId: UUID().uuidString, nonceBase64: Data(repeating: 9, count: 32).base64EncodedString(),
                                       expiresAtUnixSeconds: 1060)
        let proof = try identity.proof(operation: .presence, challenge: challenge,
                                      payload: Data("{}".utf8), now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(Data(base64Encoded: proof.signatureBase64)?.count, 64)
        XCTAssertThrowsError(try identity.proof(operation: .presence, challenge: challenge,
            payload: Data("{}".utf8), now: Date(timeIntervalSince1970: 1060)))
        XCTAssertThrowsError(try identity.proof(operation: .presence, challenge: challenge,
            payload: Data("[]".utf8), now: Date(timeIntervalSince1970: 1000)))
    }

    func testEndpointRequiresHTTPSAndExplicitNumericLoopbackDevelopment() throws {
        for raw in ["http://example.com", "https://user:password@example.com", "https://example.com/?token=x", "https://example.com/prefix"] {
            XCTAssertThrowsError(try RelayEndpoint(URL(string: raw)!, allowLoopbackHTTP: true))
        }
        XCTAssertThrowsError(try RelayEndpoint(URL(string: "http://127.0.0.1:8080")!))
        XCTAssertThrowsError(try RelayEndpoint(URL(string: "http://localhost:8080")!, allowLoopbackHTTP: true))
        let endpoint = try RelayEndpoint(URL(string: "http://127.0.0.1:8080")!, allowLoopbackHTTP: true)
        XCTAssertEqual(try endpoint.channelURL().absoluteString, "ws://127.0.0.1:8080/v1/channel")
        XCTAssertEqual(try RelayEndpoint(URL(string: "https://relay.example.com")!).channelURL().scheme, "wss")
    }

    func testLaneBindingIncrementalAndExact() throws {
        let binding = try makeBinding(lane: .file)
        let frame = try binding.framed()
        XCTAssertEqual(frame.prefix(2), Data([0, 0]))
        var decoder = CompanionBindingDecoder()
        for byte in frame { try decoder.append(Data([byte]), expected: binding) }
        XCTAssertTrue(decoder.completed)
        XCTAssertThrowsError(try decoder.append(Data([0]), expected: binding))
        var oversized = CompanionBindingDecoder()
        XCTAssertThrowsError(try oversized.append(Data([0, 0, 4, 1]), expected: binding))
        var wrong = CompanionBindingDecoder()
        let other = try CompanionLaneBinding(sessionID: binding.sessionId, lane: .control,
            controllerDeviceID: binding.controllerDeviceId, companionDeviceID: binding.companionDeviceId)
        try wrong.append(Data(frame.prefix(4)), expected: other)
        XCTAssertThrowsError(try wrong.append(Data(frame.dropFirst(4)), expected: other))
    }

    func testTicketCannotOverrideChannelOrExpire() throws {
        let ticket = RelaySessionTicket(sessionId: UUID().uuidString, ticket: String(repeating: "A", count: 43),
            expiresAtUnixSeconds: 1060, channelPath: "/v1/channel")
        try ticket.validate(now: Date(timeIntervalSince1970: 1000))
        XCTAssertThrowsError(try ticket.validate(now: Date(timeIntervalSince1970: 1060)))
        XCTAssertThrowsError(try RelaySessionTicket(sessionId: ticket.sessionId, ticket: ticket.ticket,
            expiresAtUnixSeconds: 1060, channelPath: "https://evil.example").validate(now: Date(timeIntervalSince1970: 1000)))
    }

    func testDuplicateEscapedAndUnknownBindingFieldsRejected() throws {
        let binding = try makeBinding()
        let original = String(decoding: try RelayJSON.encode(binding), as: UTF8.self)
        let duplicate = "{\"lane\":\"rdp\"," + original.dropFirst()
        let escaped = "{\"l\\u0061ne\":\"rdp\"," + original.dropFirst()
        let unknown = "{\"remoteHost\":\"other-machine\"," + original.dropFirst()
        for raw in [duplicate, escaped, unknown] {
            XCTAssertThrowsError(try CompanionLaneBinding.validate(payload: Data(raw.utf8), expected: binding))
        }
        XCTAssertThrowsError(try StrictRelayJSON.validate(Data("{\"offers\":[{\"lane\":1,\"lane\":2}]}".utf8)))
    }

    func testTicketIsIssuerBoundSingleUseAndRedacted() throws {
        let origin = try RelayEndpoint(URL(string: "https://relay.example")!)
        let other = try RelayEndpoint(URL(string: "https://other.example")!)
        let ticket = RelaySessionTicket(sessionId: UUID().uuidString, ticket: String(repeating: "A", count: 43),
            expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + 60, channelPath: "/v1/channel")
        XCTAssertThrowsError(try ticket.claim(endpoint: origin))
        try ticket.bindIssuer(origin)
        XCTAssertThrowsError(try ticket.claim(endpoint: other))
        try ticket.claim(endpoint: origin)
        XCTAssertThrowsError(try ticket.claim(endpoint: origin))
        XCTAssertFalse(String(reflecting: ticket).contains(ticket.ticket))
    }
}

func makeBinding(lane: RelayLane = .control) throws -> CompanionLaneBinding {
    try CompanionLaneBinding(sessionID: "00000000-0000-4000-8000-000000000001", lane: lane,
        controllerDeviceID: String(repeating: "a", count: 64), companionDeviceID: String(repeating: "b", count: 64))
}
