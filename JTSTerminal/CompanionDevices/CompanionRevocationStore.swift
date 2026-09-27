#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices
import JTSRelayEnrollment

nonisolated struct CompanionRevocationRecord: Codable, Equatable, Sendable {
    let request: EnrollmentRevocation
    let controllerSPKI: Data
    let peerSPKI: Data
    let deviceID: UUID
    let targetID: UUID?
    let targetBinding: String?
    var receipt: EnrollmentRevocationReceipt?
    var state: String { receipt == nil ? "revocationPending" : "revoked" }
}

/// A durable local deny precedes any network request. Only a pinned Windows
/// signature can turn a queued revocation into a completed one.
actor CompanionRevocationStore {
    static let shared = CompanionRevocationStore(persistence: CompanionVaultPersistence(account: "jts.companion.revocations.v2"))
    private let persistence: any CompanionDevicePersistence
    private var busy = false
    private struct Document: Codable { var version = 2; var records: [CompanionRevocationRecord] = [] }
    init(persistence: any CompanionDevicePersistence) { self.persistence = persistence }

    func records() async throws -> [CompanionRevocationRecord] { try await read().1.records }
    func requireAllowed(deviceID: UUID, grantID: UUID? = nil) async throws {
        let records = try await records()
        guard !records.contains(where: { record in
            record.deviceID == deviceID && (record.receipt == nil || grantID.map { grant in
                [record.request.grantId, record.request.fileGrantId, record.request.rdpGrantId].contains(grant.uuidString.lowercased())
            } == true)
        }) else {
            throw CompanionDeviceError.deviceRevoked
        }
    }
    func save(_ record: CompanionRevocationRecord) async throws {
        guard !busy else { throw EnrollmentError.busy }; busy = true; defer { busy = false }
        try Self.validate(record)
        let (raw, old) = try await read(); var document = old
        if let index = document.records.firstIndex(where: { $0.request.revocationId == record.request.revocationId }) {
            var expected = document.records[index]; expected.receipt = record.receipt
            guard expected == record,
                  document.records[index].receipt == nil || document.records[index].receipt == record.receipt else {
                throw EnrollmentError.changed
            }
            document.records[index] = record
        } else {
            guard document.records.count < 256 else { throw EnrollmentError.capacity }
            document.records.append(record)
        }
        let value = String(decoding: try EnrollmentWire.encode(document), as: UTF8.self)
        guard value.utf8.count <= 2 * 1024 * 1024 else { throw EnrollmentError.capacity }
        if let raw { try await persistence.replace(expected: raw, with: value) } else { try await persistence.create(value) }
    }
    private func read() async throws -> (String?, Document) {
        guard let text = try await persistence.load() else { return (nil, Document()) }
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw EnrollmentError.invalidMessage }
        let document = try JSONDecoder().decode(Document.self, from: Data(text.utf8))
        guard document.version == 2, document.records.count <= 256,
              Set(document.records.map { $0.request.revocationId }).count == document.records.count else { throw EnrollmentError.invalidMessage }
        try document.records.forEach(Self.validate)
        return (text, document)
    }
    private static func validate(_ record: CompanionRevocationRecord) throws {
        try record.request.verify(controllerSPKI: record.controllerSPKI)
        guard EnrollmentWire.hash(record.peerSPKI) == record.request.peerDeviceId,
              (record.targetID == nil) == (record.targetBinding == nil),
              record.targetBinding.map({ $0.utf8.count == 64 }) ?? true else { throw EnrollmentError.invalidIdentity }
        try record.receipt?.verify(revocation: record.request, peerSPKI: record.peerSPKI)
    }
}
#endif
