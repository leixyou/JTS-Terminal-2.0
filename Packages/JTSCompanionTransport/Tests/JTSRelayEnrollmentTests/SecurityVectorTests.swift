import CryptoKit
import Foundation
import XCTest
@testable import JTSRelayEnrollment

final class SecurityVectorTests: XCTestCase {
    func testIndependentPythonConfirmationMatchesExistingEncryptedClaim() throws {
        let attempt = try vectorAttempt()
        let vector = try object("confirmation-v2")
        let value = try EnrollmentConfirmation.decode(JSONSerialization.data(withJSONObject: vector["confirmation"]!))
        try value.verify(attempt: attempt)
        let transcript = EnrollmentConfirmation.transcript(origin: value.relayOrigin, invitation: value.invitationId,
            controller: value.controllerDeviceId, peer: value.peerDeviceId, claim: value.claimHash,
            confirmed: value.confirmedAtUnixSeconds, expires: value.expiresAtUnixSeconds)
        XCTAssertEqual(transcript.base64EncodedString(), vector["transcriptBase64"] as? String)
    }

    func testIndependentPythonRevocationAndCompletionSignatures() throws {
        let vector = try object("revocation-v2")
        let request = try EnrollmentRevocation.decode(JSONSerialization.data(withJSONObject: vector["revocation"]!))
        let receipt = try EnrollmentRevocationReceipt.decode(JSONSerialization.data(withJSONObject: vector["receipt"]!))
        let controller = Data(base64Encoded: vector["controllerSPKIBase64"] as! String)!
        let peer = Data(base64Encoded: vector["peerSPKIBase64"] as! String)!
        try request.verify(controllerSPKI: controller)
        try receipt.verify(revocation: request, peerSPKI: peer)
        XCTAssertEqual(try request.requestHash, vector["requestHash"] as? String)
        XCTAssertEqual(request.transcript().base64EncodedString(), vector["requestTranscriptBase64"] as? String)
    }

    func testActualClientSignatureUsesIndependentPythonAuthTranscript() async throws {
        let vector = try object("auth-v2")
        let expected = Data(base64Encoded: vector["transcriptBase64"] as! String)!
        let publicKey = try P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: vector["controllerSPKIBase64"] as! String)!)
        let vectorSignature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: vector["signatureBase64"] as! String)!)
        XCTAssertTrue(publicKey.isValidSignature(vectorSignature, for: expected))
        let attempt = try vectorAttempt()
        let transport = VectorAuthTransport(challenge: vector["challengeId"] as! String, nonce: vector["nonceBase64"] as! String,
            expectedPayload: vector["payloadBase64"] as! String, transcript: expected, key: publicKey, attempt: attempt)
        // The fixture explicitly publishes scalar 1; no real identity is used.
        let client = try EnrollmentClient(privateKey: Data(repeating: 0, count: 31) + Data([1]),
            relayOrigin: vector["relayOrigin"] as! String, transport: transport)
        _ = try await client.status(attempt)
    }

    private func object(_ name: String) throws -> [String: Any] {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private func vectorAttempt() throws -> EnrollmentAttempt {
        let f = try object("enrollment") as! [String: String]
        let code = try EnrollmentCode(relayOrigin: f["relayOrigin"]!, invitationId: f["invitationId"]!, secret: Data(base64Encoded: f["secretBase64"]!)!)
        let request = try EnrollmentRequest.decode(Data(base64Encoded: f["requestBase64"]!)!)
        let claim = EnrollmentClaim(peerSPKIBase64: f["peerSPKIBase64"]!, responseBase64: f["responseBase64"]!,
            signatureBase64: f["signatureBase64"]!, claimHash: f["claimHash"]!)
        let object: [String: Any] = ["id": f["invitationId"]!, "code": code.presentation, "request": f["requestBase64"]!,
            "offer": f["offerBase64"]!, "expiresAtUnixSeconds": Int64(ISO8601DateFormatter().date(from: request.expiresAtUtc)!.timeIntervalSince1970),
            "verifiedClaim": try JSONSerialization.jsonObject(with: EnrollmentWire.encode(claim))]
        return try JSONDecoder().decode(EnrollmentAttempt.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private struct VectorAuthTransport: EnrollmentHTTPTransport {
    let challenge, nonce, expectedPayload: String
    let transcript: Data
    let key: P256.Signing.PublicKey
    let attempt: EnrollmentAttempt
    func post(_ url: URL, body: Data) async throws -> (Int, Data) {
        if url.path == "/v1/challenges" {
            return (200, try JSONSerialization.data(withJSONObject: ["challengeId": challenge, "nonceBase64": nonce,
                "expiresAtUnixSeconds": Int64(Date().timeIntervalSince1970) + 60]))
        }
        let envelope = try JSONSerialization.jsonObject(with: body) as! [String: String]
        XCTAssertEqual(envelope["payloadBase64"], expectedPayload)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: envelope["signatureBase64"]!)!)
        XCTAssertTrue(key.isValidSignature(signature, for: transcript))
        return (200, try JSONSerialization.data(withJSONObject: ["invitationId": attempt.id,
            "controllerDeviceId": EnrollmentWire.hash(key.derRepresentation), "state": "claimed",
            "expiresAtUnixSeconds": attempt.expiresAtUnixSeconds, "offerBase64": attempt.offer.base64EncodedString(),
            "claim": try JSONSerialization.jsonObject(with: EnrollmentWire.encode(attempt.verifiedClaim!))]))
    }
}
