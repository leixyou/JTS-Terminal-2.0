import CryptoKit
import Foundation
import XCTest
@testable import JTSRelayEnrollment

final class EnrollmentAudienceTests: XCTestCase {
    func testActualEnrollmentClientDoesNotSignForwardedChallengeForDifferentAudience() async throws {
        let key = P256.Signing.PrivateKey()
        let request = try EnrollmentRequest(controllerSPKI: key.publicKey.derRepresentation, allowWindows10TLS12: false)
        let attempt = try EnrollmentAttempt(relayOrigin: "https://expected.example", request: request)
        let transport = EnrollmentAudienceTransport(key: key.publicKey, attempt: attempt)
        let client = try EnrollmentClient(privateKey: key.rawRepresentation, relayOrigin: "https://expected.example", transport: transport)
        _ = try await client.create(attempt)
    }
}

private struct EnrollmentAudienceTransport: EnrollmentHTTPTransport {
    let key: P256.Signing.PublicKey
    let attempt: EnrollmentAttempt
    let id = "00000000-0000-4000-8000-000000000002"
    let nonce = Data(repeating: 9, count: 32).base64EncodedString()
    func post(_ url: URL, body: Data) async throws -> (Int, Data) {
        if url.path == "/v1/challenges" {
            return (200, try JSONSerialization.data(withJSONObject: ["challengeId": id,
                "nonceBase64": nonce, "expiresAtUnixSeconds": Int64(Date().timeIntervalSince1970) + 60]))
        }
        let proof = try JSONSerialization.jsonObject(with: body) as! [String: String]
        let device = EnrollmentWire.hash(key.derRepresentation)
        let payload = Data(base64Encoded: proof["payloadBase64"]!)!
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: proof["signatureBase64"]!)!)
        let suffix = [device, "enrollment", id, nonce, EnrollmentWire.hash(payload)]
        func transcript(_ prefix: [String]) -> Data { Data((prefix + suffix).joined(separator: "\n").utf8) }
        XCTAssertTrue(key.isValidSignature(signature, for: transcript(["JTS-RELAY-AUTH-V2", "https://expected.example"])))
        XCTAssertFalse(key.isValidSignature(signature, for: transcript(["JTS-RELAY-AUTH-V2", "https://other.example"])))
        XCTAssertFalse(key.isValidSignature(signature, for: transcript(["JTS-RELAY-AUTH-V1"])))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(attempt.code))
        return (200, try JSONSerialization.data(withJSONObject: ["invitationId": attempt.id, "controllerDeviceId": device,
            "state": "pending", "expiresAtUnixSeconds": attempt.expiresAtUnixSeconds, "offerBase64": attempt.offer.base64EncodedString()]))
    }
}
