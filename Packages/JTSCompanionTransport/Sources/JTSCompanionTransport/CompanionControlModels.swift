import Foundation
import JTSCompanionIPC

public enum CompanionControlError: Error, Equatable, Sendable {
    case invalidRequest, invalidResponse, timedOut, remote(String)
}

// UI/XPC callers consume these data-only models without linking the TLS/parser archive.
public typealias CompanionJobState = JTSCompanionIPC.CompanionJobState
public typealias CompanionControlStatus = JTSCompanionIPC.CompanionControlStatus
public typealias CompanionJobReceipt = JTSCompanionIPC.CompanionJobReceipt
public typealias CompanionJobOutput = JTSCompanionIPC.CompanionJobOutput

protocol ControlResult: Decodable, Sendable { static var fields: Set<String> { get } }
extension CompanionControlStatus: ControlResult { static var fields: Set<String> { requiredKeys } }
extension CompanionJobReceipt: ControlResult { static var fields: Set<String> { requiredKeys } }
extension CompanionJobOutput: ControlResult { static var fields: Set<String> { requiredKeys } }

enum ControlLimits {
    static let frame = 96 * 1024
    static let payload = 64 * 1024
    static let outputChunk = 32 * 1024
    static let operations: Set<String> = ["device.status", "job.submit", "job.get", "job.cancel", "job.output", "desktop.authorize"]
    static func canonical(_ value: UUID) throws -> String {
        let result = value.uuidString.lowercased()
        guard result != "00000000-0000-0000-0000-000000000000" else { throw CompanionControlError.invalidRequest }
        return result
    }
}
