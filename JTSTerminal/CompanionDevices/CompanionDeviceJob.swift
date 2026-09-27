#if ENABLE_RDP_2
import Foundation
import Observation
import JTSCompanionIPC

/// Only these identifiers/policy fields are durable; never persist script, path or output.
nonisolated struct CompanionJobMetadata: Codable, Equatable, Sendable, Identifiable {
    let id, deviceID, grantID: UUID
    let createdAtMilliseconds, deadlineMilliseconds: Int64
    let allowDisconnected: Bool
    var createdAt: Date { Date(timeIntervalSince1970: Double(createdAtMilliseconds) / 1_000) }
    var deadline: Date { Date(timeIntervalSince1970: Double(deadlineMilliseconds) / 1_000) }

    init(id: UUID, deviceID: UUID, grantID: UUID, createdAt: Date, deadline: Date, allowDisconnected: Bool) {
        self.id = id; self.deviceID = deviceID; self.grantID = grantID
        self.createdAtMilliseconds = Int64((createdAt.timeIntervalSince1970 * 1_000).rounded(.down))
        self.deadlineMilliseconds = Int64((deadline.timeIntervalSince1970 * 1_000).rounded(.down))
        self.allowDisconnected = allowDisconnected
    }
    func validate() throws {
        let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        guard ![id, deviceID, grantID].contains(zero), createdAtMilliseconds >= 0, createdAtMilliseconds < 253_402_300_799_999,
              deadlineMilliseconds > createdAtMilliseconds, deadlineMilliseconds <= 253_402_300_799_999,
              deadlineMilliseconds - createdAtMilliseconds <= 86_400_000 else { throw CompanionJobError.invalidRequest }
    }
}

@Observable @MainActor
final class CompanionDeviceJob: Identifiable {
    let metadata: CompanionJobMetadata
    var receipt: CompanionJobReceipt?
    var verifiedAt: Date?
    var output = Data()
    var errorCode: String?
    var id: UUID { metadata.id }
    var isTerminal: Bool {
        guard let state = receipt?.state else { return false }
        return [.succeeded, .failed, .cancelled, .expired, .interrupted].contains(state)
    }
    init(metadata: CompanionJobMetadata) { self.metadata = metadata }
    func accept(_ receipt: CompanionJobReceipt) throws {
        try receipt.validate()
        guard receipt.jobId == id.uuidString.lowercased(), receipt.grantId == metadata.grantID.uuidString.lowercased(),
              receipt.kind == "powershell.v1", receipt.allowDisconnected == metadata.allowDisconnected,
              receipt.deadlineUnixMilliseconds == metadata.deadlineMilliseconds else { throw CompanionJobError.invalidReply }
        self.receipt = receipt; verifiedAt = Date(); errorCode = nil
    }
}

nonisolated enum CompanionJobError: Error { case invalidRequest, invalidReply, journalUnavailable, journalFull }

nonisolated enum CompanionPowerShellRequest {
    static func payload(script: String, directory: String) throws -> Data {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !script.contains("\0"), script.utf8.count <= 48 * 1024, (directory == "." || validDirectory(directory)) else {
            throw CompanionJobError.invalidRequest
        }
        let data = try JSONEncoder().encode(Payload(version: 1, script: script, workingDirectory: directory))
        guard data.count <= 65536 else { throw CompanionJobError.invalidRequest }
        return data
    }
    private struct Payload: Encodable { let version: Int; let script, workingDirectory: String }
    static func validDirectory(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        guard (3...240).contains(path.utf16.count), scalars.count >= 3,
              (65...90).contains(scalars[0].value) || (97...122).contains(scalars[0].value),
              scalars[1] == ":", scalars[2] == "\\",
              !scalars.dropFirst(2).contains(where: { $0.value < 32 || ":/\"<>|?*".unicodeScalars.contains($0) }) else { return false }
        let remainder = String(path.dropFirst(3)).replacingOccurrences(of: #"\\+$"#, with: "", options: .regularExpression)
        if remainder.isEmpty { return true }
        return remainder.split(separator: "\\", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".") && !$0.hasSuffix(" ")
        }
    }
}
#endif
