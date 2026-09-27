import Foundation
import SwiftData

nonisolated enum MCPAuditRecordPolicy {
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    static func actionCategory(for toolName: String) -> String {
        switch toolName {
        case "jts_list_servers", "jts_list_open_terminals":
            return "discovery"
        case "jts_exec", "jts_terminal_exec":
            return "command"
        case "jts_list_dir", "jts_read_file", "jts_stat", "jts_terminal_read":
            return "read"
        case "jts_write_file", "jts_mkdir", "jts_rename", "jts_remove":
            return "mutation"
        case "jts_upload_file", "jts_download_file":
            return "transfer"
        case "jts_open_terminal":
            return "session"
        default:
            return "automation"
        }
    }

    static func clientIdentifier(_ value: String?) -> String {
        let fallback = "unidentified-mcp-client"
        guard let value else { return fallback }
        let sanitized = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        let bounded = String(String.UnicodeScalarView(sanitized)).trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? fallback : String(bounded.prefix(128))
    }

    @MainActor
    static func purgeExpired(in context: ModelContext, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        guard let records = try? context.fetch(FetchDescriptor<MCPAuditEntry>()) else { return }
        for record in records where record.finishedAt < cutoff {
            context.delete(record)
        }
    }
}
