import CryptoKit
import Foundation
import XCTest
import JTSRelayEnrollment
@testable import JTSCompanionDevices

final class EnrollmentStoreTests: XCTestCase {
    func testRestartKeepsCodeAndExpiryWithoutAnyRDPState() async throws {
        let persistence = DeviceTestPersistence()
        let key = P256.Signing.PrivateKey()
        let request = try EnrollmentRequest(controllerSPKI: key.publicKey.derRepresentation, allowWindows10TLS12: true)
        let record = CompanionEnrollmentRecord(attempt: try EnrollmentAttempt(relayOrigin: "https://relay.example.test", request: request),
                                               targetID: UUID(), targetBinding: String(repeating: "a", count: 64))
        try await CompanionEnrollmentStore(persistence: persistence).save(record, controllerDeviceId: request.controllerDeviceID)
        let restarted = CompanionEnrollmentStore(persistence: persistence)
        let saved = try await restarted.records(controllerDeviceId: request.controllerDeviceID)
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved[0].attempt.code, record.attempt.code)
        XCTAssertEqual(saved[0].attempt.expiresAtUnixSeconds, record.attempt.expiresAtUnixSeconds)
        XCTAssertEqual(saved[0].targetID, record.targetID)
        do {
            _ = try await restarted.records(controllerDeviceId: String(repeating: "b", count: 64))
            XCTFail("A different controller must not resume another identity's invitation")
        } catch {}
    }
    func testCancellationCannotBeRevertedByStaleRetry() async throws {
        let persistence = DeviceTestPersistence()
        let request = try EnrollmentRequest(controllerSPKI: P256.Signing.PrivateKey().publicKey.derRepresentation, allowWindows10TLS12: false)
        let original = CompanionEnrollmentRecord(attempt: try EnrollmentAttempt(relayOrigin: "https://relay.example.test", request: request))
        let store = CompanionEnrollmentStore(persistence: persistence)
        try await store.save(original, controllerDeviceId: request.controllerDeviceID)
        var cancelled = original; cancelled.state = "cancelled"
        try await store.save(cancelled, controllerDeviceId: request.controllerDeviceID)
        do {
            try await CompanionEnrollmentStore(persistence: persistence).save(original, controllerDeviceId: request.controllerDeviceID)
            XCTFail("A stale retry cannot resurrect cancelled enrollment")
        } catch { XCTAssertEqual(error as? EnrollmentError, .changed) }
    }
}
