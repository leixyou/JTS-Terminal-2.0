import CryptoKit
import Foundation
import XCTest
@testable import JTSRelayEnrollment

final class EnrollmentHostTests: XCTestCase {
    func testHostClaimIsPersistedExactlyAndRequiresControllerProofBeforeAuthorization() async throws {
        let fixture = try HostFixture()
        let host = try fixture.client()
        let prepared = try await host.prepare(code: fixture.attempt.code, name: "Mac fixture", now: fixture.now)
        let recovered = try JSONDecoder().decode(EnrollmentHostAttempt.self, from: EnrollmentWire.encode(prepared))
        try recovered.validate()
        let pending = try await host.receipt(recovered)
        XCTAssertEqual(pending.state, .pending); XCTAssertNil(pending.authorization)
        XCTAssertEqual(recovered.enrollment.verifiedClaim, prepared.enrollment.verifiedClaim)
        XCTAssertFalse(recovered.description.contains(fixture.attempt.code))
        var controller = fixture.attempt
        controller.verifiedClaim = recovered.enrollment.verifiedClaim
        _ = try controller.bundle(for: XCTUnwrap(controller.verifiedClaim))
        await fixture.transport.respond(try fixture.receipt(state: .claimed, claim: controller.verifiedClaim))
        let claimed = try await host.claim(recovered)
        XCTAssertEqual(claimed.state, .claimed); XCTAssertNil(claimed.authorization)
        let firstBody = await fixture.transport.requests.last!.1
        _ = try await host.claim(recovered)
        let retryBody = await fixture.transport.requests.last!.1
        XCTAssertEqual(firstBody, retryBody)
        controller.confirmation = try EnrollmentConfirmation(attempt: controller, key: fixture.controller, now: fixture.now)
        await fixture.transport.respond(try fixture.receipt(state: .bound, claim: controller.verifiedClaim, confirmation: controller.confirmation))
        let bound = try await host.receipt(recovered)
        let trusted = try XCTUnwrap(bound.authorization)
        XCTAssertEqual(trusted.controllerSPKI, fixture.controller.publicKey.derRepresentation)
        XCTAssertEqual(trusted.rdpGrantID.uuidString.lowercased(), try EnrollmentRequest.decode(controller.request).rdpGrantID)
    }

    func testForgedBoundOrChangedClaimCannotAuthorizeHost() async throws {
        let fixture = try HostFixture(), host = try fixture.client()
        let attempt = try await host.prepare(code: fixture.attempt.code, name: "Mac", now: fixture.now)
        await fixture.transport.respond(try fixture.receipt(state: .bound, claim: attempt.enrollment.verifiedClaim))
        do { _ = try await host.receipt(attempt); XCTFail("Relay asserted unsigned authorization") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidResponse) }
        let another = try HostFixture()
        let otherAttempt = try await another.client().prepare(code: another.attempt.code, name: "Other", now: another.now)
        await fixture.transport.respond(try fixture.receipt(state: .claimed, claim: otherAttempt.enrollment.verifiedClaim))
        do { _ = try await host.receipt(attempt); XCTFail("Different claim accepted") }
        catch { XCTAssertEqual(error as? EnrollmentError, .changed) }
    }

    func testChangedHostPrivateIdentityCannotRetryStoredClaim() async throws {
        let fixture = try HostFixture(), host = try fixture.client()
        let attempt = try await host.prepare(code: fixture.attempt.code, name: "Mac", now: fixture.now)
        let other = try EnrollmentHostClient(privateKey: P256.Signing.PrivateKey().rawRepresentation, transport: fixture.transport)
        do { _ = try await other.claim(attempt); XCTFail("Stored claim submitted by other identity") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidIdentity) }
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testExpiredAlreadyClaimedWrongBearerAndReceiptBindingsRejected() async throws {
        let fixture = try HostFixture(), host = try fixture.client()
        do { _ = try await host.prepare(code: fixture.attempt.code, name: "Mac", now: fixture.now.addingTimeInterval(1800)); XCTFail("Expired offer") }
        catch { XCTAssertEqual(error as? EnrollmentError, .expired) }
        let wrong = try EnrollmentCode(relayOrigin: "https://relay.example.test", invitationId: fixture.attempt.id)
        do { _ = try await host.prepare(code: wrong.presentation, name: "Mac", now: fixture.now); XCTFail("Wrong secret") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidMessage) }
        await fixture.transport.respond(try fixture.receipt(state: .claimed))
        do { _ = try await host.prepare(code: fixture.attempt.code, name: "Mac", now: fixture.now); XCTFail("Regenerated claim") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidResponse) }
        var object = try JSONSerialization.jsonObject(with: fixture.receipt(state: .pending)) as! [String: Any]
        object["controllerDeviceId"] = String(repeating: "a", count: 64)
        await fixture.transport.respond(try JSONSerialization.data(withJSONObject: object))
        do { _ = try await host.prepare(code: fixture.attempt.code, name: "Mac", now: fixture.now); XCTFail("Relay swapped controller") }
        catch { XCTAssertEqual(error as? EnrollmentError, .changed) }
    }
}

private struct HostFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let controller = P256.Signing.PrivateKey(), hostKey = P256.Signing.PrivateKey()
    let attempt: EnrollmentAttempt
    let transport: HostReceiptTransport
    init() throws {
        attempt = try EnrollmentAttempt(relayOrigin: "https://relay.example.test",
            request: EnrollmentRequest(controllerSPKI: controller.publicKey.derRepresentation, allowWindows10TLS12: false, now: now))
        transport = HostReceiptTransport(body: try JSONSerialization.data(withJSONObject: [
            "invitationId": attempt.id, "controllerDeviceId": EnrollmentWire.hash(controller.publicKey.derRepresentation),
            "state": "pending", "expiresAtUnixSeconds": attempt.expiresAtUnixSeconds, "offerBase64": attempt.offer.base64EncodedString()]))
    }
    func client() throws -> EnrollmentHostClient { try EnrollmentHostClient(privateKey: hostKey.rawRepresentation, transport: transport) }
    func receipt(state: EnrollmentReceipt.State, claim: EnrollmentClaim? = nil, confirmation: EnrollmentConfirmation? = nil) throws -> Data {
        var object: [String: Any] = ["invitationId": attempt.id, "controllerDeviceId": EnrollmentWire.hash(controller.publicKey.derRepresentation),
            "state": state.rawValue, "expiresAtUnixSeconds": attempt.expiresAtUnixSeconds, "offerBase64": attempt.offer.base64EncodedString()]
        if let claim { object["claim"] = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(claim)) }
        if let confirmation { object["confirmation"] = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(confirmation)) }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private actor HostReceiptTransport: EnrollmentHTTPTransport {
    var body: Data
    var requests: [(URL, Data)] = []
    init(body: Data) { self.body = body }
    func respond(_ body: Data) { self.body = body }
    func post(_ url: URL, body: Data) async throws -> (Int, Data) {
        requests.append((url, body)); return (200, self.body)
    }
}
