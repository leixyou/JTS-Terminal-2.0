import CryptoKit
import Foundation
import XCTest
@testable import JTSRelayEnrollment

final class EnrollmentTests: XCTestCase {
    func fixture() throws -> [String: String] {
        let url = Bundle.module.url(forResource: "enrollment", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
    func testIndependentCryptoVectorAndClaimSignature() throws {
        let f = try fixture(); func bytes(_ key: String) -> Data { Data(base64Encoded: f[key]!)! }
        let code = try EnrollmentCode(relayOrigin: f["relayOrigin"]!, invitationId: f["invitationId"]!, secret: bytes("secretBase64"))
        XCTAssertEqual(code.claimToken, bytes("claimTokenBase64")); XCTAssertEqual(code.claimTokenHash, f["claimTokenHash"])
        XCTAssertEqual(try code.openOffer(bytes("offerBase64")), bytes("offerPlaintextBase64"))
        XCTAssertEqual(try code.openResponse(bytes("responseBase64"), offer: bytes("offerBase64")), bytes("responsePlaintextBase64"))
        let claim = EnrollmentClaim(peerSPKIBase64: f["peerSPKIBase64"]!, responseBase64: f["responseBase64"]!,
            signatureBase64: f["signatureBase64"]!, claimHash: f["claimHash"]!)
        let (spki, response) = try claim.verify(invitationId: code.invitationId,
            controllerDeviceId: EnrollmentWire.hash(bytes("controllerSPKIBase64")), offer: bytes("offerBase64"))
        XCTAssertEqual(spki, bytes("peerSPKIBase64")); XCTAssertEqual(response, bytes("responseBase64"))
    }
    func testCodeRejectsAmbiguityAndKeepsSecretsOutOfDescriptions() throws {
        let code = try EnrollmentCode(relayOrigin: "https://Example.test:443/")
        XCTAssertEqual(code.relayOrigin, "https://example.test")
        XCTAssertEqual(try EnrollmentCode(code.presentation).presentation, code.presentation)
        XCTAssertFalse(String(describing: code).contains("jts-pair"))
        for suffix in ["&key=x", "&unknown=x", "#fragment"] {
            XCTAssertThrowsError(try EnrollmentCode(code.presentation + suffix))
        }
        XCTAssertThrowsError(try EnrollmentCode(relayOrigin: "http://example.test"))
        XCTAssertThrowsError(try EnrollmentCode(relayOrigin: "https://user:password@example.test"))
    }
    func testWrongSecretChangedOfferAndChangedCiphertextFailClosed() throws {
        let code = try EnrollmentCode(relayOrigin: "https://example.test")
        let offer = try code.sealOffer(Data("request".utf8))
        let response = try code.sealResponse(Data("response".utf8), offer: offer)
        let wrong = try EnrollmentCode(relayOrigin: code.relayOrigin, invitationId: code.invitationId)
        XCTAssertThrowsError(try wrong.openOffer(offer))
        XCTAssertThrowsError(try code.openResponse(response, offer: offer + Data([1])))
        var changed = response; changed[12] ^= 1
        XCTAssertThrowsError(try code.openResponse(changed, offer: offer))
    }
    func testPersistedAttemptRetainsIdentityAndCodeAcrossRDPRetry() throws {
        let key = P256.Signing.PrivateKey()
        let request = try EnrollmentRequest(controllerSPKI: key.publicKey.derRepresentation, allowWindows10TLS12: true)
        let original = try EnrollmentAttempt(relayOrigin: "https://example.test", request: request)
        // Reopening the enrollment state is independent of any RDP connection or login result.
        let reloaded = try JSONDecoder().decode(EnrollmentAttempt.self, from: EnrollmentWire.encode(original))
        try reloaded.validate(controllerDeviceId: request.controllerDeviceID)
        XCTAssertEqual(reloaded.code, original.code); XCTAssertEqual(reloaded.offer, original.offer)
        XCTAssertEqual(reloaded.request, original.request); XCTAssertEqual(reloaded.expiresAtUnixSeconds, original.expiresAtUnixSeconds)
        XCTAssertFalse(String(describing: reloaded).contains(original.code))
    }
    func testSubstitutedControllerAndDuplicateJSONRejected() throws {
        let key = P256.Signing.PrivateKey()
        let request = try EnrollmentRequest(controllerSPKI: key.publicKey.derRepresentation, allowWindows10TLS12: false)
        let attempt = try EnrollmentAttempt(relayOrigin: "https://example.test", request: request)
        XCTAssertThrowsError(try attempt.validate(controllerDeviceId: String(repeating: "0", count: 64)))
        let raw = String(decoding: try EnrollmentWire.encode(request), as: UTF8.self)
        let duplicate = "{\"version\":1," + raw.dropFirst()
        XCTAssertThrowsError(try EnrollmentRequest.decode(Data(duplicate.utf8)))
    }

    func testExpiryNeedsDefinitiveNodeResponseAndCannotEraseKnownBinding() throws {
        let request = try EnrollmentRequest(controllerSPKI: P256.Signing.PrivateKey().publicKey.derRepresentation,
            allowWindows10TLS12: false, now: Date().addingTimeInterval(-1900))
        let attempt = try EnrollmentAttempt(relayOrigin: "https://relay.example.test", request: request)
        XCTAssertEqual(attempt.recoveryState(after: EnrollmentError.remote("invalid_invitation_expiry"), localState: "creating"), "expired")
        XCTAssertEqual(attempt.recoveryState(after: EnrollmentError.remote("invitation_not_found"), localState: "pending"), "expired")
        XCTAssertNil(attempt.recoveryState(after: URLError(.notConnectedToInternet), localState: "creating"))
        XCTAssertNil(attempt.recoveryState(after: EnrollmentError.remote("invitation_not_found"), localState: "bound"))
        XCTAssertNil(attempt.recoveryState(after: EnrollmentError.remote("request_failed"), localState: "pending"))
    }
}
