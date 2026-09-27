import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionTransport

final class RelayAudienceTests: XCTestCase {
    func testForwardedChallengeCannotMoveProofToAnotherRelayOrLegacyTranscript() throws {
        let key = P256.Signing.PrivateKey(), now = Date(timeIntervalSince1970: 1000)
        let identity = RelayIdentity(privateKey: key)
        let first = try RelayEndpoint(URL(string: "https://FIRST.example:443/")!)
        let second = try RelayEndpoint(URL(string: "https://second.example")!)
        XCTAssertEqual(first.canonicalOrigin, "https://first.example")
        let challenge = RelayChallenge(challengeId: "00000000-0000-4000-8000-000000000001",
            nonceBase64: Data(repeating: 1, count: 32).base64EncodedString(), expiresAtUnixSeconds: 1060)
        let payload = Data("{}".utf8)
        let proof = try identity.proof(endpoint: first, operation: .presence, challenge: challenge, payload: payload, now: now)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: proof.signatureBase64)!)
        let a = try RelayIdentity.canonicalProof(endpoint: first, deviceID: identity.deviceID, operation: .presence,
            challenge: challenge, payload: payload, now: now)
        let b = try RelayIdentity.canonicalProof(endpoint: second, deviceID: identity.deviceID, operation: .presence,
            challenge: challenge, payload: payload, now: now)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: a))
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: b))
        let legacy = Data(["JTS-RELAY-AUTH-V1", identity.deviceID, "presence", challenge.challengeId,
            challenge.nonceBase64, "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"].joined(separator: "\n").utf8)
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: legacy))
    }

    func testHTTPClientSignsItsConfiguredAudience() async throws {
        let key = P256.Signing.PrivateKey(), identity = RelayIdentity(privateKey: key)
        let transport = AudienceVerifyingTransport(key: key.publicKey)
        let client = RelayHTTPClient(endpoint: try RelayEndpoint(URL(string: "https://expected.example/")!), identity: identity, transport: transport)
        try await client.presence()
    }
}

private struct AudienceVerifyingTransport: RelayHTTPTransport {
    let key: P256.Signing.PublicKey
    let id = "00000000-0000-4000-8000-000000000001"
    let nonce = Data(repeating: 8, count: 32).base64EncodedString()
    func perform(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayHTTPResponse {
        if request.url!.path == "/v1/challenges" {
            return RelayHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["challengeId": id,
                "nonceBase64": nonce, "expiresAtUnixSeconds": Int64(Date().timeIntervalSince1970) + 60]))
        }
        let proof = try JSONDecoder().decode(RelayProof.self, from: request.httpBody!)
        let payload = Data(base64Encoded: proof.payloadBase64)!
        let transcript = Data(["JTS-RELAY-AUTH-V2", "https://expected.example", proof.deviceId, "presence", id, nonce,
            SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()].joined(separator: "\n").utf8)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: proof.signatureBase64)!)
        XCTAssertTrue(key.isValidSignature(signature, for: transcript))
        return RelayHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["deviceId": proof.deviceId]))
    }
}
