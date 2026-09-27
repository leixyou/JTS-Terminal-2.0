import CryptoKit
import Foundation
import XCTest
import JTSRelayEnrollment
@testable import JTSCompanionDevices

final class EnrollmentConfirmationStoreTests: XCTestCase {
    func testSavedConfirmationCannotBeRemovedOrReplacedEvenAfterRestart() async throws {
        let persistence = DeviceTestPersistence()
        var record = try fixtureRecord()
        let identity = try EnrollmentRequest.decode(record.attempt.request).controllerDeviceID
        let client = try EnrollmentClient(privateKey: Data(repeating: 0, count: 31) + Data([1]), relayOrigin: "https://relay.example.test:9443")
        let original = try await client.prepareConfirmation(record.attempt, now: Date(timeIntervalSince1970: 1790467500))
        let replacement = try await client.prepareConfirmation(record.attempt, now: Date(timeIntervalSince1970: 1790467501))
        record.attempt.confirmation = original; record.state = "bound"
        try await CompanionEnrollmentStore(persistence: persistence).save(record, controllerDeviceId: identity)
        let reopened = CompanionEnrollmentStore(persistence: persistence)
        for confirmation in [nil, replacement] {
            var stale = record; stale.state = "claimed"; stale.attempt.confirmation = confirmation
            do { try await reopened.save(stale, controllerDeviceId: identity); XCTFail("Persisted confirmation changed") }
            catch { XCTAssertEqual(error as? EnrollmentError, .changed) }
        }
        let values = try await reopened.records(controllerDeviceId: identity)
        XCTAssertEqual(values.first?.attempt.confirmation, original)
        XCTAssertEqual(values.first?.state, "bound")
    }

    func testLegacyBoundIsPreservedButRequiresAuthenticatedConfirmation() async throws {
        var historical = try fixtureRecord(); historical.state = "complete"; historical.deviceID = UUID()
        let identity = try EnrollmentRequest.decode(historical.attempt.request).controllerDeviceID
        let records = try JSONSerialization.jsonObject(with: EnrollmentWire.encode([historical]))
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["version": 1, "records": records]), as: UTF8.self)
        let persistence = DeviceTestPersistence(raw)
        let store = CompanionEnrollmentStore(persistence: persistence)
        let loaded = try await store.records(controllerDeviceId: identity)
        XCTAssertEqual(loaded.first?.state, "confirmationRequired")
        XCTAssertEqual(loaded.first?.attempt.code, historical.attempt.code)
        XCTAssertEqual(loaded.first?.deviceID, historical.deviceID)
        let retained = try await persistence.load()
        XCTAssertEqual(retained, raw, "Read-only recovery must not overwrite historical material")
        do { try await store.save(historical, controllerDeviceId: identity); XCTFail("Unsigned bound state was saved") }
        catch { XCTAssertEqual(error as? EnrollmentError, .invalidMessage) }
        var recovered = loaded[0]
        let vectorURL = Bundle.module.url(forResource: "confirmation-v2", withExtension: "json", subdirectory: "Fixtures")!
        let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as! [String: Any]
        recovered.attempt.confirmation = try JSONDecoder().decode(EnrollmentConfirmation.self,
            from: JSONSerialization.data(withJSONObject: vector["confirmation"]!))
        recovered.state = "bound"
        try await store.save(recovered, controllerDeviceId: identity)
        let confirmed = try await store.records(controllerDeviceId: identity)
        XCTAssertEqual(confirmed.first?.state, "bound")
    }

    func testOrdinaryPendingIsNotPromotedOrDiscardedByMigration() async throws {
        var record = try fixtureRecord(); record.state = "pending"; record.attempt.verifiedClaim = nil
        let persistence = DeviceTestPersistence(), identity = try EnrollmentRequest.decode(record.attempt.request).controllerDeviceID
        try await CompanionEnrollmentStore(persistence: persistence).save(record, controllerDeviceId: identity)
        let loaded = try await CompanionEnrollmentStore(persistence: persistence).records(controllerDeviceId: identity)
        XCTAssertEqual(loaded.first?.state, "pending")
        XCTAssertEqual(loaded.first?.attempt.code, record.attempt.code)
        XCTAssertNil(loaded.first?.attempt.confirmation)
    }

    func testFullStorePreservesCompletedProofAndRejectsNewAttemptWithoutWriting() async throws {
        let complete = try signedFixtureRecord(state: "complete")
        let request = try EnrollmentRequest.decode(complete.attempt.request)
        let records = try [complete] + (0..<63).map { _ in try pendingRecord(request) }
        let raw = try document(records)
        let persistence = DeviceTestPersistence(raw)
        let store = CompanionEnrollmentStore(persistence: persistence)
        do {
            try await store.save(pendingRecord(request), controllerDeviceId: request.controllerDeviceID)
            XCTFail("Capacity must not erase the completed epoch needed for revocation")
        } catch { XCTAssertEqual(error as? EnrollmentError, .capacity) }
        let retained = try await persistence.load()
        XCTAssertEqual(retained, raw, "Capacity failure must leave durable proof unchanged")
        let reopened = try await CompanionEnrollmentStore(persistence: persistence).records(controllerDeviceId: request.controllerDeviceID)
        XCTAssertEqual(reopened.count, 64)
        XCTAssertEqual(reopened.first?.state, "complete")
        XCTAssertEqual(reopened.first?.attempt.confirmation, complete.attempt.confirmation)
        XCTAssertEqual(reopened.first?.attempt.request, complete.attempt.request)
    }

    func testCapacityReclaimsOnlyCancelledAndExpiredAttemptsWhileKeepingBoundProof() async throws {
        let bound = try signedFixtureRecord(state: "bound")
        let request = try EnrollmentRequest.decode(bound.attempt.request)
        var cancelled = try pendingRecord(request); cancelled.state = "cancelled"
        var expired = try pendingRecord(request); expired.state = "expired"
        let records = try [bound, cancelled, expired] + (0..<61).map { _ in try pendingRecord(request) }
        let persistence = DeviceTestPersistence(try document(records))
        let inserted = try pendingRecord(request)
        try await CompanionEnrollmentStore(persistence: persistence).save(inserted, controllerDeviceId: request.controllerDeviceID)
        let reopened = try await CompanionEnrollmentStore(persistence: persistence).records(controllerDeviceId: request.controllerDeviceID)
        XCTAssertEqual(reopened.count, 63)
        XCTAssertEqual(reopened.first?.state, "bound")
        XCTAssertEqual(reopened.first?.attempt.confirmation, bound.attempt.confirmation)
        XCTAssertTrue(reopened.contains { $0.id == inserted.id })
        XCTAssertFalse(reopened.contains { $0.id == cancelled.id || $0.id == expired.id })
        XCTAssertTrue(Set(records.dropFirst(3).map(\.id)).isSubset(of: Set(reopened.map(\.id))))
    }

    private func signedFixtureRecord(state: String) throws -> CompanionEnrollmentRecord {
        var record = try fixtureRecord()
        let url = Bundle.module.url(forResource: "confirmation-v2", withExtension: "json", subdirectory: "Fixtures")!
        let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        record.attempt.confirmation = try JSONDecoder().decode(EnrollmentConfirmation.self,
            from: JSONSerialization.data(withJSONObject: vector["confirmation"]!))
        record.state = state
        return record
    }

    private func pendingRecord(_ request: EnrollmentRequest) throws -> CompanionEnrollmentRecord {
        var record = CompanionEnrollmentRecord(attempt: try EnrollmentAttempt(relayOrigin: "https://relay.example.test:9443", request: request))
        record.state = "pending"
        return record
    }

    private func document(_ records: [CompanionEnrollmentRecord]) throws -> String {
        let objects = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(records))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["version": 1, "records": objects]), as: UTF8.self)
    }

    private func fixtureRecord() throws -> CompanionEnrollmentRecord {
        let url = Bundle.module.url(forResource: "enrollment", withExtension: "json", subdirectory: "Fixtures")!
        let f = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let code = try EnrollmentCode(relayOrigin: f["relayOrigin"]!, invitationId: f["invitationId"]!, secret: Data(base64Encoded: f["secretBase64"]!)!)
        let request = try EnrollmentRequest.decode(Data(base64Encoded: f["requestBase64"]!)!)
        let claim = ["peerSPKIBase64": f["peerSPKIBase64"]!, "responseBase64": f["responseBase64"]!,
            "signatureBase64": f["signatureBase64"]!, "claimHash": f["claimHash"]!]
        let object: [String: Any] = ["id": f["invitationId"]!, "code": code.presentation, "request": f["requestBase64"]!, "offer": f["offerBase64"]!,
            "verifiedClaim": claim, "expiresAtUnixSeconds": Int64(ISO8601DateFormatter().date(from: request.expiresAtUtc)!.timeIntervalSince1970)]
        return CompanionEnrollmentRecord(attempt: try JSONDecoder().decode(EnrollmentAttempt.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
