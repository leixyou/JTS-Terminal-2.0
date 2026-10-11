//
//  MCPToolAnnotations.swift
//  JTSTerminal
//

import Foundation

/// Standard MCP tool annotations (`readOnlyHint`, `destructiveHint`,
/// `idempotentHint`). Clients may use them to group tools or to skip a
/// confirmation for read-only calls. They are hints only: JTS Terminal's own
/// profile, grant and pane checks still decide every call.
///
/// A tool that multiplexes several actions is annotated by its most
/// dangerous action.
nonisolated enum MCPToolAnnotations {
    enum Kind: Equatable {
        /// Reads data without changing the remote or local environment.
        case readOnly
        /// Changes state but cannot delete or overwrite data.
        case additive(idempotent: Bool)
        /// May run commands, overwrite, move or delete data.
        case destructive
    }

    static func kind(forTool name: String) -> Kind? {
        switch name {
        case "jts_list_servers", "jts_list_dir", "jts_read_file", "jts_stat",
             "jts_list_open_terminals", "jts_terminal_read",
             "jts_list_targets", "jts_desktop_status", "jts_desktop_observe",
             "jts_desktop_uia":
            return .readOnly
        case "jts_mkdir":
            return .additive(idempotent: true)
        case "jts_open_terminal", "jts_open_desktop", "jts_close_desktop":
            return .additive(idempotent: false)
        case "jts_exec", "jts_write_file", "jts_upload_file", "jts_download_file",
             "jts_rename", "jts_remove", "jts_terminal_exec",
             "jts_companion_pairing", "jts_desktop_action", "jts_windows_exec",
             "jts_windows_files", "jts_windows_task",
             "jts_device_status", "jts_device_exec", "jts_device_task",
             "jts_device_files":
            return .destructive
        default:
            return nil
        }
    }

    static func annotations(forTool name: String) -> [String: Any]? {
        guard let kind = kind(forTool: name) else { return nil }
        switch kind {
        case .readOnly:
            return ["readOnlyHint": true]
        case let .additive(idempotent):
            return [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": idempotent,
            ]
        case .destructive:
            return ["readOnlyHint": false, "destructiveHint": true]
        }
    }

    /// Adds annotations to tool definitions that do not already carry them.
    static func annotated(_ definitions: [[String: Any]]) -> [[String: Any]] {
        definitions.map { definition in
            guard definition["annotations"] == nil,
                  let name = definition["name"] as? String,
                  let annotations = annotations(forTool: name) else {
                return definition
            }
            var annotated = definition
            annotated["annotations"] = annotations
            return annotated
        }
    }
}
