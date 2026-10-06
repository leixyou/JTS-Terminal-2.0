import CryptoKit
import Foundation
import XCTest
@testable import JTSRelayEnrollment

final class EnrollmentHostRevocationTests: XCTestCase {
    func testHostPinExactEpochAndSignedAckSurvivePersistence() async throws {
        let f = try ConfirmationFixture()
        let request = try await f.client().prepareRevocation(f.attempt.bundle(for: f.attempt.verifiedClaim!), now: f.now)
        let authorization = try authority(f)
        let wrapper = try delivery(request, pin: f.controller.publicKey.derRepresentation)
        let host = try EnrollmentHostRevocationClient(privateKey: f.windows.rawRepresentation,
            relayOrigin: authorization.relayOrigin, transport: ReceiptOnlyTransport(body: JSONSerialization.data(withJSONObject: ["revocations": [wrapper]])))
        let polled = try await host.poll(authorizations: [authorization])
        XCTAssertEqual(polled, [request])
        let persisted = try JSONDecoder().decode(EnrollmentHostAuthorization.self, from: EnrollmentWire.encode(authorization))
        try persisted.validate(); XCTAssertEqual(persisted, authorization)
        let receipt = try await host.prepareReceipt(for: request, authorization: persisted, now: f.now)
        try receipt.verify(revocation: request, peerSPKI: f.windows.publicKey.derRepresentation)
        var completed = wrapper; completed["state"] = "complete"
        completed["receipt"] = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(receipt))
        let completing = try EnrollmentHostRevocationClient(privateKey: f.windows.rawRepresentation,
            relayOrigin: authorization.relayOrigin, transport: ReceiptOnlyTransport(body: JSONSerialization.data(withJSONObject: completed)))
        let result = try await completing.complete(receipt, revocation: request, authorization: persisted)
        XCTAssertEqual(result.state, .complete); XCTAssertEqual(result.receipt, receipt)
    }

    func testForeignEpochRelayReplacementPinAndForgedSignatureDoNotRevoke() async throws {
        let f = try ConfirmationFixture(), authority = try authority(f)
        let request = try await f.client().prepareRevocation(f.attempt.bundle(for: f.attempt.verifiedClaim!), now: f.now)
        let body = try JSONSerialization.data(withJSONObject: ["revocations": [delivery(request, pin: f.controller.publicKey.derRepresentation)]])
        let host = try EnrollmentHostRevocationClient(privateKey: f.windows.rawRepresentation,
            relayOrigin: authority.relayOrigin, transport: ReceiptOnlyTransport(body: body))
        var object = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(authority)) as! [String: Any]
        object["pairingID"] = UUID().uuidString
        let anotherEpoch = try JSONDecoder().decode(EnrollmentHostAuthorization.self, from: JSONSerialization.data(withJSONObject: object))
        let ignored = try await host.poll(authorizations: [anotherEpoch]); XCTAssertTrue(ignored.isEmpty)
        do { _ = try await host.prepareReceipt(for: request, authorization: anotherEpoch, now: f.now); XCTFail("Foreign epoch acked") }
        catch { XCTAssertEqual(error as? EnrollmentError, .changed) }
        let spoofed = try JSONSerialization.data(withJSONObject: ["revocations": [delivery(request, pin: P256.Signing.PrivateKey().publicKey.derRepresentation)]])
        let spoofedHost = try EnrollmentHostRevocationClient(privateKey: f.windows.rawRepresentation,
            relayOrigin: authority.relayOrigin, transport: ReceiptOnlyTransport(body: spoofed))
        do { _ = try await spoofedHost.poll(authorizations: [authority]); XCTFail("Relay supplied trust") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidIdentity) }
        var raw = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(request)) as! [String: Any]
        raw["signatureBase64"] = Data(repeating: 0, count: 64).base64EncodedString()
        let forged = try EnrollmentRevocation.decode(JSONSerialization.data(withJSONObject: raw))
        do { _ = try await host.prepareReceipt(for: forged, authorization: authority, now: f.now); XCTFail("Forged controller signature") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidIdentity) }
    }

    private func authority(_ f: ConfirmationFixture) throws -> EnrollmentHostAuthorization {
        let request = try EnrollmentRequest.decode(f.attempt.request)
        return EnrollmentHostAuthorization(relayOrigin: "https://relay.example.test", controllerSPKI: f.controller.publicKey.derRepresentation,
            controllerDeviceID: request.controllerDeviceID, pairingID: UUID(uuidString: request.pairingID)!,
            controlGrantID: UUID(uuidString: request.grantID)!, fileGrantID: UUID(uuidString: request.fileGrantID)!,
            rdpGrantID: UUID(uuidString: request.rdpGrantID)!, allowWindows10TLS12: false)
    }
    private func delivery(_ request: EnrollmentRevocation, pin: Data) throws -> [String: Any] {
        ["revocationId": request.revocationId, "requestHash": try request.requestHash, "state": "pending",
         "revocation": try JSONSerialization.jsonObject(with: EnrollmentWire.encode(request)), "controllerSPKIBase64": pin.base64EncodedString()]
    }
}
