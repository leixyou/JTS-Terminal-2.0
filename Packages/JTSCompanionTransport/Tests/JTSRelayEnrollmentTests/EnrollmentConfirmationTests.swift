import CryptoKit
import Foundation
import XCTest
@testable import JTSRelayEnrollment

final class EnrollmentConfirmationTests: XCTestCase {
    func testConfirmationSurvivesPersistenceAndRetriesAfterExpiryWithoutResigning() async throws {
        let fixture = try ConfirmationFixture()
        var attempt = fixture.attempt
        let client = try fixture.client()
        let signed = try await client.prepareConfirmation(attempt, now: fixture.now)
        attempt.confirmation = signed
        let recovered = try JSONDecoder().decode(EnrollmentAttempt.self, from: EnrollmentWire.encode(attempt))
        try recovered.validate(controllerDeviceId: EnrollmentWire.hash(fixture.controller.publicKey.derRepresentation))
        let retried = try await client.prepareConfirmation(recovered, now: fixture.now.addingTimeInterval(3600))
        XCTAssertEqual(retried, signed)
        let receipt = try fixture.receipt(confirmation: signed)
        try recovered.check(receipt)
        // A lost local response can recover an authentic, controller-signed bound receipt too.
        try fixture.attempt.check(receipt)
    }

    func testCannotNewlyConfirmExpiredOrNotYetIssuedRequest() async throws {
        let fixture = try ConfirmationFixture()
        let client = try fixture.client()
        for date in [fixture.now.addingTimeInterval(-1), fixture.now.addingTimeInterval(1800)] {
            do { _ = try await client.prepareConfirmation(fixture.attempt, now: date); XCTFail("Signed outside import window") }
            catch { XCTAssertEqual(error as? EnrollmentError, .expired) }
        }
        do { _ = try await client.confirm(fixture.attempt); XCTFail("Implicit confirmation must not be signed/sent") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidMessage) }
    }

    func testRelayCannotForgeBoundByChangingOnlyReceiptState() async throws {
        let fixture = try ConfirmationFixture()
        let body = try fixture.receiptBytes()
        let transport = ReceiptOnlyTransport(body: body)
        let client = try fixture.client(transport: transport)
        do { _ = try await client.status(fixture.attempt); XCTFail("Unsigned bound receipt accepted") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidResponse) }
    }

    func testEveryConfirmationBindingAndSignatureIsAuthenticated() async throws {
        let fixture = try ConfirmationFixture()
        let signed = try await fixture.client().prepareConfirmation(fixture.attempt, now: fixture.now)
        let original = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(signed)) as! [String: Any]
        let changes: [String: Any] = ["version": 1, "relayOrigin": "https://other.example", "invitationId": UUID().uuidString.lowercased(),
            "controllerDeviceId": String(repeating: "a", count: 64), "peerDeviceId": String(repeating: "b", count: 64),
            "claimHash": String(repeating: "c", count: 64), "confirmedAtUnixSeconds": signed.confirmedAtUnixSeconds + 1,
            "expiresAtUnixSeconds": signed.expiresAtUnixSeconds + 1, "signatureBase64": Data(repeating: 0, count: 64).base64EncodedString()]
        for (field, value) in changes {
            var object = original; object[field] = value
            let tampered = try EnrollmentConfirmation.decode(JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try tampered.verify(attempt: fixture.attempt), field)
        }
        var extra = original; extra["ignored"] = true
        XCTAssertThrowsError(try EnrollmentConfirmation.decode(JSONSerialization.data(withJSONObject: extra)))
        let raw = String(decoding: try EnrollmentWire.encode(signed), as: UTF8.self)
        XCTAssertThrowsError(try EnrollmentConfirmation.decode(Data(("{\"version\":2," + raw.dropFirst()).utf8)))
    }

    func testConfirmationForAnotherClaimCannotAuthorizeTheReceipt() async throws {
        let first = try ConfirmationFixture(), second = try ConfirmationFixture()
        let signed = try await first.client().prepareConfirmation(first.attempt, now: first.now)
        XCTAssertThrowsError(try second.attempt.check(second.receipt(confirmation: signed)))
    }

    func testCancelledReceiptRetainsProofButPendingClaimedAndExpiredCannotAssertIt() async throws {
        let fixture = try ConfirmationFixture()
        let proof = try await fixture.client().prepareConfirmation(fixture.attempt, now: fixture.now)
        var object = try JSONSerialization.jsonObject(with: fixture.receiptBytes(confirmation: proof)) as! [String: Any]
        object["state"] = "cancelled"
        let cancelled = try EnrollmentReceipt.decode(JSONSerialization.data(withJSONObject: object))
        try fixture.attempt.check(cancelled)
        XCTAssertEqual(cancelled.state, .cancelled); XCTAssertEqual(cancelled.confirmation, proof)
        for state in ["pending", "claimed", "expired"] {
            object["state"] = state
            XCTAssertThrowsError(try EnrollmentReceipt.decode(JSONSerialization.data(withJSONObject: object)), state)
        }
    }
}

struct ConfirmationFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let controller = P256.Signing.PrivateKey()
    let windows = P256.Signing.PrivateKey()
    let attempt: EnrollmentAttempt

    init() throws {
        let request = try EnrollmentRequest(controllerSPKI: controller.publicKey.derRepresentation, allowWindows10TLS12: false, now: now)
        var value = try EnrollmentAttempt(relayOrigin: "https://relay.example.test", request: request)
        let code = try EnrollmentCode(value.code), spki = windows.publicKey.derRepresentation
        let bundle: [String: Any] = ["version": 1, "name": "Fixture", "relayURL": code.relayOrigin,
            "peerSPKIBase64": spki.base64EncodedString(), "peerDeviceID": EnrollmentWire.hash(spki),
            "pairingID": request.pairingID, "grantID": request.grantID, "fileGrantID": request.fileGrantID, "rdpGrantID": request.rdpGrantID]
        let wrapper = EnrollmentResponse(version: 1, invitationId: value.id, relayOrigin: code.relayOrigin,
            requestSha256: EnrollmentWire.hash(value.request), enrollmentBase64: try JSONSerialization.data(withJSONObject: bundle).base64EncodedString())
        let response = try code.sealResponse(EnrollmentWire.encode(wrapper), offer: value.offer)
        let transcript = EnrollmentClaim.transcript(invitationId: value.id, controllerDeviceId: request.controllerDeviceID,
            offer: value.offer, response: response, spki: spki)
        value.verifiedClaim = EnrollmentClaim(peerSPKIBase64: spki.base64EncodedString(), responseBase64: response.base64EncodedString(),
            signatureBase64: try windows.signature(for: transcript).rawRepresentation.base64EncodedString(), claimHash: EnrollmentWire.hash(transcript))
        attempt = value
    }
    func client(transport: any EnrollmentHTTPTransport = ReceiptOnlyTransport(body: Data())) throws -> EnrollmentClient {
        try EnrollmentClient(privateKey: controller.rawRepresentation, relayOrigin: "https://relay.example.test", transport: transport)
    }
    func receiptBytes(confirmation: EnrollmentConfirmation? = nil) throws -> Data {
        var object: [String: Any] = ["invitationId": attempt.id, "controllerDeviceId": EnrollmentWire.hash(controller.publicKey.derRepresentation),
            "state": "bound", "expiresAtUnixSeconds": attempt.expiresAtUnixSeconds, "offerBase64": attempt.offer.base64EncodedString(),
            "claim": try JSONSerialization.jsonObject(with: EnrollmentWire.encode(attempt.verifiedClaim!))]
        if let confirmation { object["confirmation"] = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(confirmation)) }
        return try JSONSerialization.data(withJSONObject: object)
    }
    func receipt(confirmation: EnrollmentConfirmation) throws -> EnrollmentReceipt { try EnrollmentReceipt.decode(receiptBytes(confirmation: confirmation)) }
}

struct ReceiptOnlyTransport: EnrollmentHTTPTransport {
    let body: Data
    func post(_ url: URL, body: Data) async throws -> (Int, Data) {
        if url.path == "/v1/challenges" {
            return (200, try JSONSerialization.data(withJSONObject: ["challengeId": UUID().uuidString.lowercased(),
                "nonceBase64": Data(repeating: 7, count: 32).base64EncodedString(), "expiresAtUnixSeconds": Int64(Date().timeIntervalSince1970) + 60]))
        }
        return (200, self.body)
    }
}
