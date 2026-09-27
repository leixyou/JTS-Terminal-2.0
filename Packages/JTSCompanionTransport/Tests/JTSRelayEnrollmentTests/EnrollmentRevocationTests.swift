import CryptoKit
import Foundation
import XCTest
@testable import JTSRelayEnrollment

final class EnrollmentRevocationTests: XCTestCase {
    func testPersistedRevocationKeepsExactEpochGrantsAndRequestHash() async throws {
        let f = try ConfirmationFixture()
        let bundle = try f.attempt.bundle(for: f.attempt.verifiedClaim!)
        let request = try await f.client().prepareRevocation(bundle, now: f.now)
        let restored = try EnrollmentRevocation.decode(EnrollmentWire.encode(request))
        XCTAssertEqual(restored, request)
        XCTAssertEqual(restored.pairingId, bundle.pairingID)
        XCTAssertEqual(restored.grantId, bundle.grantID)
        XCTAssertEqual(restored.fileGrantId, bundle.fileGrantID)
        XCTAssertEqual(restored.rdpGrantId, bundle.rdpGrantID)
        try restored.verify(controllerSPKI: f.controller.publicKey.derRepresentation)
        let expectedHash = EnrollmentWire.hash(request.transcript() + Data(base64Encoded: request.signatureBase64)!)
        XCTAssertEqual(try restored.requestHash, expectedHash)
    }

    func testRelayCannotClaimCompletedRevocationWithoutWindowsSignature() async throws {
        let f = try ConfirmationFixture(), bundle = try f.attempt.bundle(for: f.attempt.verifiedClaim!)
        let request = try await f.client().prepareRevocation(bundle, now: f.now)
        let forged = try status(request, fixture: f, state: "complete")
        let client = try f.client(transport: ReceiptOnlyTransport(body: forged))
        do { _ = try await client.submitRevocation(request, peerSPKI: f.windows.publicKey.derRepresentation); XCTFail("Unsigned completion accepted") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidResponse) }
        let pending = try await f.client(transport: ReceiptOnlyTransport(body: status(request, fixture: f, state: "pending")))
            .submitRevocation(request, peerSPKI: f.windows.publicKey.derRepresentation)
        XCTAssertEqual(pending.state, .pending); XCTAssertNil(pending.receipt)
    }

    func testOnlyPinnedWindowsReceiptForExactSignedRequestCompletes() async throws {
        let f = try ConfirmationFixture(), bundle = try f.attempt.bundle(for: f.attempt.verifiedClaim!)
        let request = try await f.client().prepareRevocation(bundle, now: f.now)
        let receipt = try signedReceipt(request, fixture: f)
        let client = try f.client(transport: ReceiptOnlyTransport(body: status(request, fixture: f, state: "complete", receipt: receipt)))
        let value = try await client.revocationStatus(request, peerSPKI: f.windows.publicKey.derRepresentation)
        XCTAssertEqual(value.state, .complete); XCTAssertEqual(value.receipt, receipt)
        let later = try await f.client().prepareRevocation(bundle, now: f.now.addingTimeInterval(3600))
        XCTAssertThrowsError(try receipt.verify(revocation: later, peerSPKI: f.windows.publicKey.derRepresentation))
        XCTAssertThrowsError(try receipt.verify(revocation: request, peerSPKI: P256.Signing.PrivateKey().publicKey.derRepresentation))
    }

    func testModifiedEpochOrReplayedReceiptSignatureCannotAuthorizeAnotherGrant() async throws {
        let f = try ConfirmationFixture(), bundle = try f.attempt.bundle(for: f.attempt.verifiedClaim!)
        let request = try await f.client().prepareRevocation(bundle, now: f.now)
        for field in ["pairingId", "grantId", "fileGrantId", "rdpGrantId", "revocationId"] {
            var object = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(request)) as! [String: Any]
            object[field] = UUID().uuidString.lowercased()
            let changed = try EnrollmentRevocation.decode(JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try changed.verify(controllerSPKI: f.controller.publicKey.derRepresentation), field)
        }
        let receipt = try signedReceipt(request, fixture: f)
        var object = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(receipt)) as! [String: Any]
        object["revokedAtUnixSeconds"] = receipt.revokedAtUnixSeconds + 1
        let changed = try EnrollmentRevocationReceipt.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try changed.verify(revocation: request, peerSPKI: f.windows.publicKey.derRepresentation))
    }

    func testSignedCompletionAllowsWindowsClockSkewButRejectsNonpositiveTime() async throws {
        let f = try ConfirmationFixture(), bundle = try f.attempt.bundle(for: f.attempt.verifiedClaim!)
        let request = try await f.client().prepareRevocation(bundle, now: f.now)
        let early = try signedReceipt(request, fixture: f, at: request.requestedAtUnixSeconds - 5)
        XCTAssertNoThrow(try early.verify(revocation: request, peerSPKI: f.windows.publicKey.derRepresentation))
        let zero = try signedReceipt(request, fixture: f, at: 0)
        XCTAssertThrowsError(try zero.verify(revocation: request, peerSPKI: f.windows.publicKey.derRepresentation))
    }

    private func signedReceipt(_ request: EnrollmentRevocation, fixture f: ConfirmationFixture, at: Int64? = nil) throws -> EnrollmentRevocationReceipt {
        let at = at ?? Int64(f.now.timeIntervalSince1970) + 1
        let transcript = Data(["JTS-PAIR-REVOKED-2", request.revocationId, try request.requestHash,
            request.controllerDeviceId, request.peerDeviceId, String(at)].joined(separator: "\n").utf8)
        return EnrollmentRevocationReceipt(version: 2, revocationId: request.revocationId, requestHash: try request.requestHash,
            controllerDeviceId: request.controllerDeviceId, peerDeviceId: request.peerDeviceId, revokedAtUnixSeconds: at,
            signatureBase64: try f.windows.signature(for: transcript).rawRepresentation.base64EncodedString())
    }

    private func status(_ request: EnrollmentRevocation, fixture f: ConfirmationFixture, state: String,
                        receipt: EnrollmentRevocationReceipt? = nil) throws -> Data {
        var object: [String: Any] = ["revocationId": request.revocationId, "requestHash": try request.requestHash, "state": state,
            "revocation": try JSONSerialization.jsonObject(with: EnrollmentWire.encode(request)),
            "controllerSPKIBase64": f.controller.publicKey.derRepresentation.base64EncodedString()]
        if let receipt { object["receipt"] = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(receipt)) }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
