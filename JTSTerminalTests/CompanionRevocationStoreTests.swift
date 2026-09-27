#if ENABLE_RDP_2
import Foundation
import Testing
import JTSCompanionDevices
import JTSRelayEnrollment
@testable import JTSTerminal

@Suite struct CompanionRevocationStoreTests {
    @Test func pendingSurvivesRestartAndOnlySignedCompletionReleasesNewEpoch() async throws {
        let (record, receipt) = try fixture()
        let persistence = RevocationTestPersistence()
        let first = CompanionRevocationStore(persistence: persistence)
        try await first.save(record)
        let reopened = CompanionRevocationStore(persistence: persistence)
        await #expect(throws: CompanionDeviceError.deviceRevoked) { try await reopened.requireAllowed(deviceID: record.deviceID) }
        await #expect(throws: CompanionDeviceError.deviceRevoked) { try await reopened.requireAllowed(deviceID: record.deviceID, grantID: UUID()) }
        var completed = record; completed.receipt = receipt
        try await reopened.save(completed)
        for grant in [record.request.grantId, record.request.fileGrantId, record.request.rdpGrantId] {
            await #expect(throws: CompanionDeviceError.deviceRevoked) {
                try await reopened.requireAllowed(deviceID: record.deviceID, grantID: UUID(uuidString: grant)!)
            }
        }
        try await reopened.requireAllowed(deviceID: record.deviceID, grantID: UUID())
        await #expect(throws: EnrollmentError.changed) { try await reopened.save(record) }
        #expect(try await reopened.records().first?.receipt == receipt)
    }
    @Test func tamperedReceiptAndStorageFailureNeverReportCompletion() async throws {
        let (record, receipt) = try fixture()
        let persistence = RevocationTestPersistence()
        let store = CompanionRevocationStore(persistence: persistence)
        try await store.save(record)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        object["revokedAtUnixSeconds"] = receipt.revokedAtUnixSeconds + 1
        var forged = record
        forged.receipt = try JSONDecoder().decode(EnrollmentRevocationReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        await #expect(throws: (any Error).self) { try await store.save(forged) }
        #expect(try await store.records().first?.state == "revocationPending")
        var completed = record; completed.receipt = receipt
        await persistence.rejectWrites()
        await #expect(throws: CompanionDevicePersistenceError.self) { try await store.save(completed) }
        #expect(try await store.records().first?.state == "revocationPending")
        await persistence.corrupt()
        await #expect(throws: (any Error).self) { try await store.requireAllowed(deviceID: record.deviceID) }
    }
    private func fixture() throws -> (CompanionRevocationRecord, EnrollmentRevocationReceipt) {
        struct Vector: Decodable {
            let controllerSPKIBase64, peerSPKIBase64: String
            let revocation: EnrollmentRevocation
            let receipt: EnrollmentRevocationReceipt
        }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(Self.vector.utf8))
        return (CompanionRevocationRecord(request: vector.revocation, controllerSPKI: Data(base64Encoded: vector.controllerSPKIBase64)!,
            peerSPKI: Data(base64Encoded: vector.peerSPKIBase64)!, deviceID: UUID(), targetID: UUID(),
            targetBinding: String(repeating: "a", count: 64)), vector.receipt)
    }
    // Public cross-language fixture, fixed non-production private scalars 1 and 2.
    private static let vector = #"""
{
  "controllerSPKIBase64": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9Q==",
  "peerSPKIBase64": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfPJ7GI0DT36KUjgDBLUaw8CJaeJ38hs1pgtI/EdmmXgHd1UQ247QQCk9msafdDDbun2t5jzpgimeBLedInhz0Q==",
  "revocation": {
    "version": 2,
    "revocationId": "66666666-6666-4666-8666-666666666666",
    "relayOrigin": "https://relay.example.test:9443",
    "controllerDeviceId": "5cd252fb0ce8932436faf8ccd1040981b89ee4ad6b9fe9e2a2b7e71aacb27cd3",
    "peerDeviceId": "dc0ce633dbcc913dafafa4b89ac44d8ce683fdfc3f60c8bdf21213b9f2b534ba",
    "pairingId": "22222222-2222-4222-8222-222222222222",
    "grantId": "33333333-3333-4333-8333-333333333333",
    "fileGrantId": "44444444-4444-4444-8444-444444444444",
    "rdpGrantId": "55555555-5555-4555-8555-555555555555",
    "requestedAtUnixSeconds": 1790467600,
    "signatureBase64": "TYjcH749Gl/6RF56Is4ez0Vw7qC/J+6vuMflwdRmoZ7Q3fscd8iCOElZQ8KgsuXus0eD0+CUp8nxObU8OxCoZA=="
  },
  "receipt": {
    "version": 2,
    "revocationId": "66666666-6666-4666-8666-666666666666",
    "requestHash": "d9a1a1b40a18fa1c0c49617022a340f5e5e7207f47ecc2476a83681b9698429b",
    "controllerDeviceId": "5cd252fb0ce8932436faf8ccd1040981b89ee4ad6b9fe9e2a2b7e71aacb27cd3",
    "peerDeviceId": "dc0ce633dbcc913dafafa4b89ac44d8ce683fdfc3f60c8bdf21213b9f2b534ba",
    "revokedAtUnixSeconds": 1790467601,
    "signatureBase64": "4I31a8ytPJVJhF9IBl2+14bkkPT09stD6aJVAetR8OWrCjpszsV495UwlRKRRmgLdjD8Rf1DsqRE7KwU4rNyxw=="
  }
}
"""#
}
private actor RevocationTestPersistence: CompanionDevicePersistence {
    private var value: String?
    private var reject = false
    func load() async throws -> String? { value }
    func create(_ value: String) async throws {
        guard self.value == nil, !reject else { throw CompanionDevicePersistenceError.conflict }
        self.value = value
    }
    func replace(expected: String, with value: String) async throws {
        guard self.value == expected, !reject else { throw CompanionDevicePersistenceError.conflict }
        self.value = value
    }
    func rejectWrites() { reject = true }
    func corrupt() { value = "{invalid" }
}
#endif
