import CryptoKit
import Foundation
import XCTest
@testable import JTSRelayEnrollment

final class EnrollmentHTTPTests: XCTestCase {
    func testTransportRejectsPlaintextAndCredentialURLsBeforeNetwork() async throws {
        let transport = EnrollmentURLTransport()
        for value in ["http://127.0.0.1:1/v1/enrollment", "https://user:password@127.0.0.1:1/v1/enrollment"] {
            do {
                _ = try await transport.post(URL(string: value)!, body: Data())
                XCTFail("Invalid transport URL accepted")
            } catch EnrollmentError.invalidMessage { }
        }
    }

    func testHTTPSRelayOneUseBindingAndRetryWithoutRDP() async throws {
        guard let origin = ProcessInfo.processInfo.environment["JTS_ENROLLMENT_TEST_ORIGIN"] else {
            throw XCTSkip("Requires a separate authorized enrollment test relay")
        }
        // Public fixture scalar 1 is installed only in the disposable test relay.
        let privateKey = Data(repeating: 0, count: 31) + Data([1])
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
        let request = try EnrollmentRequest(controllerSPKI: key.publicKey.derRepresentation, allowWindows10TLS12: true)
        var attempt = try EnrollmentAttempt(relayOrigin: origin, request: request)
        let controller = try EnrollmentClient(privateKey: privateKey, relayOrigin: origin)
        let created = try await controller.create(attempt)
        XCTAssertEqual(created.state, .pending)
        let code = try EnrollmentCode(attempt.code)
        let transport = EnrollmentURLTransport()
        func post(_ action: String, fields: [String: String] = [:]) async throws -> EnrollmentReceipt {
            var body = fields; body["invitationId"] = code.invitationId; body["claimTokenBase64"] = code.claimToken.base64EncodedString()
            let (status, data) = try await transport.post(URL(string: origin + "/v1/enrollment/" + action)!,
                body: EnrollmentWire.encode(body))
            XCTAssertEqual(status, 200, String(decoding: data, as: UTF8.self))
            return try EnrollmentReceipt.decode(data)
        }
        let offered = try await post("offer"); try attempt.check(offered)
        XCTAssertEqual(try code.openOffer(attempt.offer), try code.openOffer(Data(base64Encoded: offered.offerBase64)!))
        let windows = P256.Signing.PrivateKey()
        let spki = windows.publicKey.derRepresentation
        let bundle: [String: Any] = ["version": 1, "name": "Enrollment HTTPS test", "relayURL": origin,
            "peerSPKIBase64": spki.base64EncodedString(), "peerDeviceID": EnrollmentWire.hash(spki),
            "pairingID": request.pairingID, "grantID": request.grantID, "fileGrantID": request.fileGrantID,
            "rdpGrantID": request.rdpGrantID, "allowWindows10TLS12": true,
            "installationState": "installedAwaitingRelayAdmission"]
        let payload = EnrollmentResponse(version: 1, invitationId: code.invitationId, relayOrigin: origin,
            requestSha256: EnrollmentWire.hash(attempt.request), enrollmentBase64:
                try JSONSerialization.data(withJSONObject: bundle).base64EncodedString())
        let cipher = try code.sealResponse(EnrollmentWire.encode(payload), offer: attempt.offer)
        let transcript = EnrollmentClaim.transcript(invitationId: attempt.id, controllerDeviceId: request.controllerDeviceID,
                                                    offer: attempt.offer, response: cipher, spki: spki)
        let fields = ["peerSPKIBase64": spki.base64EncodedString(), "responseBase64": cipher.base64EncodedString(),
            "signatureBase64": try windows.signature(for: transcript).rawRepresentation.base64EncodedString()]
        let claim = try await post("claim", fields: fields)
        XCTAssertEqual(claim.state, .claimed)
        let repeatedClaim = try await post("claim", fields: fields)
        XCTAssertEqual(repeatedClaim.claim, claim.claim)
        let observed = try await controller.status(attempt)
        try attempt.check(observed)
        attempt.verifiedClaim = observed.claim
        let imported = try attempt.bundle(for: XCTUnwrap(observed.claim))
        XCTAssertEqual(imported.grantID, request.grantID)
        attempt.confirmation = try await controller.prepareConfirmation(attempt)
        // The application persists this attempt before sending confirm.
        attempt = try JSONDecoder().decode(EnrollmentAttempt.self, from: EnrollmentWire.encode(attempt))
        let bound = try await controller.confirm(attempt)
        XCTAssertEqual(bound.state, .bound)
        // Lost confirmation reply and a failed/nonexistent RDP login do not consume a second code.
        let repeatedConfirm = try await controller.confirm(attempt)
        let recovered = try await post("receipt")
        let repeatedCreate = try await controller.create(attempt)
        XCTAssertEqual(repeatedConfirm.state, .bound)
        XCTAssertEqual(recovered.state, .bound)
        XCTAssertEqual(repeatedCreate.state, .bound)
        let revocation = try await controller.prepareRevocation(imported)
        let pendingRevoke = try await controller.submitRevocation(revocation, peerSPKI: imported.peerSPKI)
        XCTAssertEqual(pendingRevoke.state, .pending) // No Windows completion proof has been submitted by this fixture.
        let revoked = try await post("receipt")
        XCTAssertEqual(revoked.state, .cancelled)
    }
}
