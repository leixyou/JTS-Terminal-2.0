#if ENABLE_RDP_2
import CoreFoundation
import Foundation

nonisolated enum CompanionDeviceMCPTool: String, CaseIterable {
    case status = "jts_device_status"
    case exec = "jts_device_exec"
    case task = "jts_device_task"
    case files = "jts_device_files"
}

/// Only the GUI bridge supplies client identity. Device operations never accept an RDP session.
nonisolated struct CompanionDeviceMCPRequest {
    let tool: CompanionDeviceMCPTool
    let targetID: UUID
    let action: String
    let arguments: [String: Any]

    init(tool: CompanionDeviceMCPTool, arguments: [String: Any]) throws {
        self.tool = tool; self.arguments = arguments
        targetID = try Self.identifier("targetId", arguments)
        let shared: Set<String> = ["targetId", "_jtsClientID", "_jtsClientDisplayIdentity"]
        let allowed: Set<String>
        switch tool {
        case .status:
            action = arguments["action"] as? String ?? "status"
            guard ["status", "identity", "connect", "disconnect", "bind", "unbind", "enroll", "createCode", "codeStatus", "cancelCode", "revokeRelay"].contains(action) else { throw Self.invalid("Unknown device status action.") }
            allowed = ["action", "deviceId", "grantId", "fileGrantId", "rdpGrantId", "enrollment", "allowWindows10TLS12", "relayURL", "invitationId"]
            if arguments["allowWindows10TLS12"] != nil {
                guard ["identity", "createCode"].contains(action) else { throw Self.invalid("TLS compatibility is selected only when creating an enrollment request.") }
                _ = try Self.boolean("allowWindows10TLS12", arguments)
            }
            if action == "bind" { _ = try Self.identifier("deviceId", arguments); _ = try Self.identifier("grantId", arguments) }
            for key in ["fileGrantId", "rdpGrantId"] where arguments[key] != nil { _ = try Self.identifier(key, arguments) }
            if action == "bind" {
                let ids = try ["grantId", "fileGrantId", "rdpGrantId"].filter { arguments[$0] != nil }.map { try Self.identifier($0, arguments) }
                guard Set(ids).count == ids.count else { throw Self.invalid("Each lane requires a distinct Windows grant.") }
            }
            if action == "enroll" { guard arguments["enrollment"] is [String: Any] else { throw Self.invalid("enrollment must contain the Windows public device bundle.") } }
            if action == "createCode" {
                guard let relay = arguments["relayURL"] as? String, relay.utf8.count <= 2048 else { throw Self.invalid("relayURL is required.") }
            } else if arguments["relayURL"] != nil { throw Self.invalid("relayURL is only accepted by createCode.") }
            if ["codeStatus", "cancelCode"].contains(action) { _ = try Self.identifier("invitationId", arguments) }
            else if arguments["invitationId"] != nil { throw Self.invalid("invitationId is only accepted by codeStatus or cancelCode.") }
        case .exec:
            action = "exec"; allowed = ["script", "workingDirectory", "timeoutSeconds", "waitSeconds", "maximumOutputBytes"]
            try Self.validateScript(arguments)
        case .task:
            action = arguments["action"] as? String ?? "status"
            guard ["submit", "status", "cancel", "output"].contains(action) else { throw Self.invalid("Unknown task action.") }
            allowed = ["action", "jobId", "script", "workingDirectory", "timeoutSeconds", "allowDisconnected", "offset", "maximumBytes"]
            if action == "submit" { try Self.validateScript(arguments) }
            else { _ = try Self.identifier("jobId", arguments) }
            if arguments["allowDisconnected"] != nil { _ = try Self.boolean("allowDisconnected", arguments) }
        case .files:
            action = arguments["action"] as? String ?? "list"
            allowed = ["action", "rootId", "path", "destination", "content", "encoding", "offset", "maximumBytes", "limit", "overwrite", "recursive"]
            guard ["roots", "list", "stat", "read", "write", "mkdir", "rename", "remove"].contains(action) else { throw Self.invalid("Unknown file action.") }
        }
        guard Set(arguments.keys).isSubset(of: shared.union(allowed)) else { throw Self.invalid("Unexpected argument; device tools do not accept sessionId, client authority or transport keys.") }
        for key in ["timeoutSeconds", "waitSeconds", "maximumOutputBytes", "offset", "maximumBytes"] where arguments[key] != nil {
            _ = try Self.integer(key, arguments, range: key == "offset" ? 0...268435456 : 1...1_048_576)
        }
    }

    var capabilities: Set<RemoteCapability> {
        switch tool {
        case .status: return [action == "status" ? .discovery : .desktopControl]
        case .exec, .task: return [.commandExecution]
        case .files:
            return ["write", "mkdir", "rename", "remove"].contains(action) ? [.fileAccess, .destructiveOperations] : [.fileAccess]
        }
    }
    var externalData: Set<RemoteExternalDataType> {
        switch tool {
        case .status: return [.targetMetadata]
        case .exec, .task: return action == "cancel" ? [] : [.commandOutput]
        case .files: return action == "read" ? [.fileContent] : ["roots", "list", "stat"].contains(action) ? [.fileMetadata] : []
        }
    }
    static func identifier(_ key: String, _ values: [String: Any]) throws -> UUID {
        guard let raw = values[key] as? String, let id = UUID(uuidString: raw), id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else { throw invalid("\(key) must be a nonzero UUID.") }
        return id
    }
    static func integer(_ key: String, _ values: [String: Any], range: ClosedRange<Int>, default fallback: Int? = nil) throws -> Int {
        guard let value = values[key] else { if let fallback { return fallback }; throw invalid("\(key) is required.") }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let result = Int(number.stringValue), range.contains(result) else { throw invalid("\(key) must be an integer in \(range).") }
        return result
    }
    static func boolean(_ key: String, _ values: [String: Any], default fallback: Bool = false) throws -> Bool {
        guard let value = values[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("\(key) must be a boolean.") }
        return number.boolValue
    }
    static func invalid(_ message: String) -> WindowsMCPToolError { WindowsMCPToolError(code: .invalidArgument, message: message) }
    private static func validateScript(_ values: [String: Any]) throws {
        guard let script = values["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              script.utf8.count <= 48 * 1024, !script.contains("\0") else { throw invalid("script must be nonempty PowerShell of at most 48 KiB.") }
        if let directory = values["workingDirectory"] { guard let directory = directory as? String, directory == "." || CompanionPowerShellRequest.validDirectory(directory) else { throw invalid("workingDirectory must be '.' or an absolute Windows directory.") } }
        _ = try integer("timeoutSeconds", values, range: 1...86400, default: 60)
        if values["waitSeconds"] != nil { _ = try integer("waitSeconds", values, range: 1...60) }
    }
}

nonisolated enum CompanionDeviceMCPRegistry {
    static var definitions: [[String: Any]] {
        let target: [String: Any] = ["type": "string", "description": "Existing AI-enabled target UUID from jts_list_targets; no RDP session required."]
        func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        func number(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
        func definition(_ tool: CompanionDeviceMCPTool, _ description: String, _ fields: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["name": tool.rawValue, "description": description, "inputSchema": ["type": "object", "additionalProperties": false, "properties": fields.merging(["targetId": target]) { _, new in new }, "required": ["targetId"] + required]]
        }
        let script: [String: Any] = ["script": string("PowerShell script, executed directly through Companion."), "workingDirectory": string("Absolute Windows directory or '.' for the Companion shared root."), "timeoutSeconds": number("Remote job deadline, 1–86400 seconds.")]
        return [
            definition(.status, "Inspect, connect or bind a saved Windows device through the relay. Existing AI control includes pairing delegation; no desktop session or keyboard input is needed.", ["action": ["type": "string", "enum": ["status", "identity", "connect", "disconnect", "bind", "unbind", "enroll", "createCode", "codeStatus", "cancelCode", "revokeRelay"]], "deviceId": string("Saved device UUID for bind."), "grantId": string("Windows-issued control grant UUID for bind."), "fileGrantId": string("Separate Windows file-lane grant UUID."), "rdpGrantId": string("Separate Windows RDP-lane grant UUID."), "allowWindows10TLS12": ["type": "boolean", "description": "For action=identity or createCode: explicitly select pinned TLS 1.2 for Windows 10 or Windows Server 2019. Default false (TLS 1.3)."], "relayURL": string("HTTPS relay origin for createCode. Relay owner must admit this Mac once."), "invitationId": string("Saved invitation UUID for codeStatus/cancelCode. Repeat codeStatus until complete; binding does not require RDP login."), "enrollment": ["type": "object", "description": "Public Windows enrollment bundle, used only by action=enroll."]]),
            definition(.exec, "Execute PowerShell directly over the independent Companion relay connection. Waits up to waitSeconds; returns jobId and honest remote state when still running. Never replays uncertain submissions.", script.merging(["waitSeconds": number("Bounded wait, default 30, maximum 60."), "maximumOutputBytes": number("Maximum returned output bytes, default 32768, maximum 1 MiB.")]) { _, new in new }, ["script"]),
            definition(.task, "Submit, inspect, cancel or read output from an independent Windows task.", script.merging(["action": ["type": "string", "enum": ["submit", "status", "cancel", "output"]], "jobId": string("Previously returned job UUID."), "allowDisconnected": ["type": "boolean"], "offset": number("Output byte offset."), "maximumBytes": number("Output chunk limit, at most 32768.")]) { _, new in new }, ["action"]),
            definition(.files, "Operate on Windows files directly through the encrypted Companion file lane.", ["action": ["type": "string", "enum": ["roots", "list", "stat", "read", "write", "mkdir", "rename", "remove"]], "rootId": string("Windows-authorized root identifier."), "path": string("Path inside the authorized root."), "destination": string("Destination for rename."), "content": string("Write content."), "encoding": string("utf8 or base64."), "offset": number("Byte offset."), "maximumBytes": number("Maximum bytes to read (32768)."), "limit": number("Maximum entries to list (100)."), "overwrite": ["type": "boolean"], "recursive": ["type": "boolean"]], ["action"])
        ]
    }
}
#endif
