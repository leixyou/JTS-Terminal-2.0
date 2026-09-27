import Foundation
import JTSRelayEnrollment

public struct CompanionEnrollmentRecord: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    public var attempt: EnrollmentAttempt
    public var state: String
    public let targetID: UUID?
    public let targetBinding: String?
    public var deviceID: UUID?
    public var description: String { "CompanionEnrollmentRecord (credentials omitted)" }
    public var debugDescription: String { description }
    public init(attempt: EnrollmentAttempt, targetID: UUID? = nil, targetBinding: String? = nil) {
        id = attempt.id; self.attempt = attempt; state = "creating"
        self.targetID = targetID; self.targetBinding = targetBinding
    }
}

/// Encrypted persistence is supplied by the app; RDP events never mutate these records.
public actor CompanionEnrollmentStore {
    private let persistence: any CompanionDevicePersistence
    private var busy = false
    private struct Document: Codable { var version = 1; var records: [CompanionEnrollmentRecord] = [] }
    public init(persistence: any CompanionDevicePersistence) { self.persistence = persistence }

    public func records(controllerDeviceId: String) async throws -> [CompanionEnrollmentRecord] {
        let (_, document) = try await read(controllerDeviceId: controllerDeviceId); return document.records
    }
    public func save(_ record: CompanionEnrollmentRecord, controllerDeviceId: String) async throws {
        guard !busy else { throw EnrollmentError.busy }; busy = true; defer { busy = false }
        try validate(record, controllerDeviceId: controllerDeviceId)
        let (raw, before) = try await read(controllerDeviceId: controllerDeviceId)
        var document = before
        if let index = document.records.firstIndex(where: { $0.id == record.id }) {
            let old = document.records[index]
            guard old.attempt.code == record.attempt.code, old.attempt.offer == record.attempt.offer,
                  old.attempt.request == record.attempt.request, old.targetID == record.targetID,
                  old.targetBinding == record.targetBinding,
                  old.attempt.verifiedClaim == nil || old.attempt.verifiedClaim == record.attempt.verifiedClaim,
                  old.attempt.confirmation == nil || old.attempt.confirmation == record.attempt.confirmation,
                  old.state != "cancelled" || record.state == "cancelled" else { throw EnrollmentError.changed }
            document.records[index] = record
        } else {
            // Bound/complete records retain the exact epoch required for signed revocation.
            // Only unbound terminal attempts may be reclaimed; live proof is never evicted.
            if document.records.count >= 64 {
                document.records.removeAll { ["cancelled", "expired"].contains($0.state) }
            }
            guard document.records.count < 64 else { throw EnrollmentError.capacity }; document.records.append(record)
        }
        let data = try EnrollmentWire.encode(document)
        guard data.count <= 2 * 1024 * 1024 else { throw EnrollmentError.capacity }
        let text = String(decoding: data, as: UTF8.self)
        if let raw { try await persistence.replace(expected: raw, with: text) } else { try await persistence.create(text) }
    }
    private func read(controllerDeviceId: String) async throws -> (String?, Document) {
        guard let text = try await persistence.load() else { return (nil, Document()) }
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw EnrollmentError.invalidMessage }
        var document = try JSONDecoder().decode(Document.self, from: Data(text.utf8))
        guard document.version == 1, document.records.count <= 64,
              Set(document.records.map(\.id)).count == document.records.count else { throw EnrollmentError.invalidMessage }
        for index in document.records.indices {
            // Historical V1 bound receipts were assertions by the relay. Preserve retry material,
            // but never present them as authenticated V2 authorization merely by reopening the vault.
            if ["bound", "complete"].contains(document.records[index].state), document.records[index].attempt.confirmation == nil {
                document.records[index].state = "confirmationRequired"
            }
            try validate(document.records[index], controllerDeviceId: controllerDeviceId)
        }
        return (text, document)
    }
    private func validate(_ record: CompanionEnrollmentRecord, controllerDeviceId: String) throws {
        guard record.id == record.attempt.id,
              ["creating", "pending", "claimed", "bound", "complete", "cancelled", "expired", "confirmationRequired"].contains(record.state),
              !["bound", "complete"].contains(record.state) || record.attempt.confirmation != nil,
              (record.targetID == nil) == (record.targetBinding == nil),
              record.targetBinding.map({ $0.count == 64 }) ?? true else { throw EnrollmentError.invalidMessage }
        try record.attempt.validate(controllerDeviceId: controllerDeviceId)
    }
}
