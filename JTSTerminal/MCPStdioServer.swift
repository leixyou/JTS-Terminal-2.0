//
//  MCPStdioServer.swift
//  JTSTerminal
//
//  Created by Codex on 2026/5/6.
//

import Foundation
import SwiftData

struct MCPToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Transport-neutral names used by the legacy SSH/local MCP surface.
///
/// The concrete grant implementation only exists in the 2.0 release track. Keeping
/// these names local to the MCP server lets the 1.2 compatibility scheme retain its
/// established behavior without importing any RDP-only authorization types.
enum LegacyMCPPermission: Hashable {
    case discovery
    case commandExecution
    case fileAccess
    case destructiveOperations
}

enum LegacyMCPExternalData: Hashable {
    case targetMetadata
    case commandOutput
    case terminalOutput
    case fileMetadata
    case fileContent
}

enum LegacyMCPToolName: String, CaseIterable, Hashable {
    case listServers = "jts_list_servers"
    case exec = "jts_exec"
    case listDirectory = "jts_list_dir"
    case readFile = "jts_read_file"
    case writeFile = "jts_write_file"
    case uploadFile = "jts_upload_file"
    case downloadFile = "jts_download_file"
    case stat = "jts_stat"
    case makeDirectory = "jts_mkdir"
    case rename = "jts_rename"
    case remove = "jts_remove"
    case listOpenTerminals = "jts_list_open_terminals"
    case openTerminal = "jts_open_terminal"
    case terminalExec = "jts_terminal_exec"
    case terminalRead = "jts_terminal_read"
}

struct LegacyMCPAuthorizationRequirement: Equatable {
    var permissions: Set<LegacyMCPPermission>
    var externalData: Set<LegacyMCPExternalData>
    var auditCategory: String
}

/// One source of truth for the 1.2 MCP surface's 2.0 grant requirements.
///
/// Downloading to a new local path is ordinary file access. Replacing or
/// resuming into an existing destination also consumes destructive authority;
/// this keeps the 1.2 wire schema unchanged while making overwrite fail closed.
enum LegacyMCPAuthorizationContract {
    static func requirement(
        for tool: LegacyMCPToolName,
        overwritesLocalDestination: Bool = false
    ) -> LegacyMCPAuthorizationRequirement {
        switch tool {
        case .listServers, .listOpenTerminals:
            return LegacyMCPAuthorizationRequirement(
                permissions: [.discovery],
                externalData: [.targetMetadata],
                auditCategory: "legacy.discovery"
            )
        case .exec:
            return LegacyMCPAuthorizationRequirement(
                permissions: [.commandExecution],
                externalData: [.commandOutput],
                auditCategory: "legacy.command"
            )
        case .listDirectory, .stat:
            return LegacyMCPAuthorizationRequirement(
                permissions: [.fileAccess],
                externalData: [.fileMetadata],
                auditCategory: "legacy.file"
            )
        case .readFile:
            return LegacyMCPAuthorizationRequirement(
                permissions: [.fileAccess],
                externalData: [.fileContent],
                auditCategory: "legacy.file"
            )
        case .downloadFile:
            return LegacyMCPAuthorizationRequirement(
                permissions: overwritesLocalDestination
                    ? [.fileAccess, .destructiveOperations]
                    : [.fileAccess],
                externalData: [.fileContent],
                auditCategory: overwritesLocalDestination
                    ? "legacy.destructive"
                    : "legacy.file"
            )
        case .writeFile, .uploadFile, .makeDirectory, .rename, .remove:
            return LegacyMCPAuthorizationRequirement(
                permissions: [.fileAccess, .destructiveOperations],
                externalData: [],
                auditCategory: "legacy.destructive"
            )
        case .openTerminal:
            return LegacyMCPAuthorizationRequirement(
                permissions: [.commandExecution],
                externalData: [],
                auditCategory: "legacy.terminal"
            )
        case .terminalExec, .terminalRead:
            return LegacyMCPAuthorizationRequirement(
                permissions: [.commandExecution],
                externalData: [.terminalOutput],
                auditCategory: "legacy.terminal"
            )
        }
    }
}

private struct LegacyMCPAuthorization {
    let controlLeaseExpiresAt: Date?
}

#if ENABLE_RDP_2
private extension LegacyMCPPermission {
    var remoteCapability: RemoteCapability {
        switch self {
        case .discovery:
            return .discovery
        case .commandExecution:
            return .commandExecution
        case .fileAccess:
            return .fileAccess
        case .destructiveOperations:
            return .destructiveOperations
        }
    }
}

private extension LegacyMCPExternalData {
    var remoteDataType: RemoteExternalDataType {
        switch self {
        case .targetMetadata:
            return .targetMetadata
        case .commandOutput:
            return .commandOutput
        case .terminalOutput:
            return .terminalOutput
        case .fileMetadata:
            return .fileMetadata
        case .fileContent:
            return .fileContent
        }
    }
}
#endif

struct JTSGUIAppLauncher {
    var launch: () throws -> Void
    var launchInBackground: (() throws -> Void)?

    init(_ launch: @escaping () throws -> Void) { self.launch = launch }

    static var live: JTSGUIAppLauncher {
        var launcher = JTSGUIAppLauncher { try openApp(activate: true) }
        launcher.launchInBackground = { try openApp(activate: false) }
        return launcher
    }

    private static func openApp(activate: Bool) throws {
        let environmentPath = ProcessInfo.processInfo.environment["JTS_TERMINAL_APP_BUNDLE_PATH"]
        let bundleURL = environmentPath.map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw MCPToolFailure(message: "Cannot locate JTS Terminal.app bundle. Set JTS_TERMINAL_APP_BUNDLE_PATH or run MCP from the app bundle.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = JTSBackgroundLaunchPolicy.openArguments(bundlePath: bundleURL.path, activate: activate)
        // `ensureGUIBridgeAvailable` owns the absolute startup deadline. Do
        // not synchronously wait for the helper process here; the descriptor
        // probe below is the authoritative launch-success signal.
        try process.run()
    }

    static let disabled = JTSGUIAppLauncher {}
}

struct MCPFileTransferRunner {
    var upload: (RemoteSession, String, String, Bool, Bool) async throws -> CommandResult
    var download: (RemoteSession, String, String, Bool, Bool, Int64?) async throws -> CommandResult

    static let live = MCPFileTransferRunner(
        upload: { session, localPath, remotePath, recursive, resume in
            try await MCPStagedFileTransfer.upload(
                session: session,
                localPath: localPath,
                remotePath: remotePath,
                recursive: recursive,
                resume: resume
            )
        },
        download: { session, remotePath, localPath, recursive, resume, expectedBytes in
            try await MCPStagedFileTransfer.download(
                session: session,
                remotePath: remotePath,
                localPath: localPath,
                recursive: recursive,
                resume: resume,
                expectedBytes: expectedBytes
            )
        }
    )
}

struct MCPRemoteCommandRunner {
    private var handler: (
        _ session: RemoteSession,
        _ remoteCommand: String,
        _ standardInput: String?,
        _ timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult

    init(
        runSSH: @escaping (
            _ session: RemoteSession,
            _ remoteCommand: String,
            _ standardInput: String?,
            _ timeoutSeconds: TimeInterval?
        ) async throws -> CommandResult
    ) {
        handler = runSSH
    }

    func runSSH(
        session: RemoteSession,
        remoteCommand: String,
        standardInput: String? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> CommandResult {
        try await handler(session, remoteCommand, standardInput, timeoutSeconds)
    }

    static let live = MCPRemoteCommandRunner(
        runSSH: { session, remoteCommand, standardInput, timeoutSeconds in
            try await AuthenticatedRemoteCommandRunner().runSSH(
                session: session,
                remoteCommand: remoteCommand,
                standardInput: standardInput,
                timeoutSeconds: timeoutSeconds
            )
        }
    )
}

@MainActor
final class MCPStdioServer {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--mcp")
    }

    nonisolated static func requestedRegistrationID(arguments: [String]) -> String? {
        let marker = "--mcp-client-registration"
        let indexes = arguments.indices.filter { arguments[$0] == marker }
        guard indexes.count == 1 else { return nil }
        let valueIndex = indexes[0] + 1
        guard arguments.indices.contains(valueIndex) else { return nil }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != marker else { return nil }
        return value
    }

#if ENABLE_RDP_2
    nonisolated static func routedDesktopOpenArguments(
        _ arguments: [String: Any],
        deadlineUptimeMilliseconds: Int
    ) -> [String: Any] {
        var routed = arguments
        // Preserve the caller's public relative deadline for validation and
        // diagnostics. The hidden absolute uptime value alone carries the
        // shrinking end-to-end budget across process boundaries.
        routed["_jtsDeadlineUptimeMilliseconds"] = deadlineUptimeMilliseconds
        return routed
    }
#endif

    static func runAndExit() -> Never {
        Task { @MainActor in
            do {
                let container = try ModelContainerFactory.makePersistentContainer()
                let registrar = MCPClientRegistrar()
                let registration: MCPClientRegistrationRecord?
                if let requestedID = requestedRegistrationID(arguments: CommandLine.arguments) {
                    registration = try? registrar.registrationRegistry.resolve(registrationID: requestedID)
                } else {
                    registration = nil
                }
                let server = MCPStdioServer(
                    modelContext: ModelContext(container),
                    clientRegistration: registration,
                    runtimeRegistrationObserver: { registration in
                        try? registrar.recordObservedRuntime(
                            registration: registration,
                            commandPath: MCPClientConfiguration.commandPath()
                        )
                    }
                )
                await server.runStdio()
                Foundation.exit(0)
            } catch {
                fputs("JTS Terminal MCP failed to start: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }
        RunLoop.main.run()
        Foundation.exit(1)
    }

    private let modelContext: ModelContext
    private let remoteRunner: MCPRemoteCommandRunner
    private let sftpTransport = RemoteSFTPTransport()
    private let terminalBridgeClient: TerminalMCPBridgeClient
    private let guiLauncher: JTSGUIAppLauncher
    private let fileTransferRunner: MCPFileTransferRunner
    private let windowsDispatcher: WindowsMCPToolDispatcher
    private let remoteGrantStore: RemoteClientGrantStore
    private let clientRegistration: MCPClientRegistrationRecord?
    private let runtimeRegistrationObserver:
        ((MCPClientRegistrationRecord) -> Void)?
    private var didRecordRuntimeRegistration = false

    private var mcpClientID: String {
        clientRegistration?.authorizationClientID ?? "unregistered-mcp-client"
    }

    private var mcpClientDisplayIdentity: String {
        clientRegistration?.displayIdentity ?? "Unregistered MCP client"
    }

    init(
        modelContext: ModelContext,
        terminalBridgeClient: TerminalMCPBridgeClient = TerminalMCPBridgeClient(),
        guiLauncher: JTSGUIAppLauncher? = nil,
        fileTransferRunner: MCPFileTransferRunner? = nil,
        remoteRunner: MCPRemoteCommandRunner? = nil,
        windowsDispatcher: WindowsMCPToolDispatcher? = nil,
        remoteGrantStore: RemoteClientGrantStore? = nil,
        clientRegistration: MCPClientRegistrationRecord? = nil,
        runtimeRegistrationObserver:
            ((MCPClientRegistrationRecord) -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self.terminalBridgeClient = terminalBridgeClient
        self.guiLauncher = guiLauncher ?? .live
        self.fileTransferRunner = fileTransferRunner ?? .live
        self.remoteRunner = remoteRunner ?? .live
        self.windowsDispatcher = windowsDispatcher ?? .guiBridge(client: terminalBridgeClient)
        self.remoteGrantStore = remoteGrantStore ?? .shared
        self.clientRegistration = clientRegistration
        self.runtimeRegistrationObserver = runtimeRegistrationObserver
    }

    func runStdio() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let response = await handleLine(line) {
                print(response)
                fflush(stdout)
            }
        }
    }

    func handleLine(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8) else {
            return encodedError(id: nil, code: -32700, message: "Request is not UTF-8.")
        }

        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return encodedError(id: nil, code: -32600, message: "Invalid JSON-RPC request.")
            }
            guard let method = request["method"] as? String else {
                return encodedError(id: request["id"], code: -32600, message: "Missing method.")
            }

            if method.hasPrefix("notifications/") {
                return nil
            }

            let id = request["id"]
            let params = request["params"] as? [String: Any] ?? [:]
            let result = try await handle(method: method, params: params)
            return encodedResponse(id: id, result: result)
        } catch let failure as MCPToolFailure {
            return encodedError(id: (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"], code: -32000, message: failure.message)
        } catch {
            return encodedError(id: (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"], code: -32603, message: error.localizedDescription)
        }
    }

    private func handle(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            if !didRecordRuntimeRegistration,
               let clientRegistration {
                runtimeRegistrationObserver?(clientRegistration)
                didRecordRuntimeRegistration = true
            }
            return [
                "protocolVersion": "2025-11-25",
                "capabilities": [
                    "tools": [:],
                    "resources": ["subscribe": false, "listChanged": false]
                ],
                "serverInfo": [
                    "name": "jts-terminal",
                    "version": "1.0"
                ]
            ]
        case "ping":
            try requireRegisteredClient()
            return [:]
        case "tools/list":
            return ["tools": toolDefinitions()]
        case "tools/call":
            try requireRegisteredClient()
            guard let name = params["name"] as? String else {
                throw MCPToolFailure(message: "tools/call requires a tool name.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return try await callTool(name: name, arguments: arguments)
        case "resources/list":
            try requireRegisteredClient()
            return ["resources": try resourceList()]
        case "resources/templates/list":
            try requireRegisteredClient()
            return [
                "resourceTemplates": [
                    [
                        "uriTemplate": "jts://server/{alias}/file/{path}",
                        "name": "Remote file",
                        "description": "Read a file from an MCP-enabled JTS Terminal SSH server.",
                        "mimeType": "text/plain"
                    ]
                ]
            ]
        case "resources/read":
            try requireRegisteredClient()
            guard let uri = params["uri"] as? String else {
                throw MCPToolFailure(message: "resources/read requires uri.")
            }
            return try await readResource(uri: uri)
        default:
            throw MCPToolFailure(message: "Unsupported MCP method: \(method)")
        }
    }

    private func requireRegisteredClient() throws {
        #if ENABLE_RDP_2
        guard clientRegistration != nil else {
            throw MCPToolFailure(
                message: "CLIENT_REGISTRATION_REQUIRED: Start JTS Terminal MCP with a valid --mcp-client-registration issued by the in-app registrar. Self-reported initialize.clientInfo is not an authorization identity."
            )
        }
        #endif
    }

    private func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if ENABLE_RDP_2
        if let deviceTool = CompanionDeviceMCPTool(rawValue: name) {
            guard AppReleasePolicy.includesNativeRDP else { throw MCPToolFailure(message: "Unknown MCP tool.") }
            return await callDeviceTool(deviceTool, arguments: arguments)
        }
        if let windowsTool = WindowsMCPToolName(rawValue: name) {
            guard AppReleasePolicy.includesNativeRDP else {
                throw MCPToolFailure(message: "Unknown JTS Terminal MCP tool: \(name)")
            }
            return await callWindowsTool(windowsTool, arguments: arguments)
        }
        #endif

        switch name {
        case "jts_list_servers":
            return toolResult(try jsonText(listServerPayload()))
        case "jts_exec":
            return try await execute(arguments)
        case "jts_list_dir":
            return try await listDirectory(arguments)
        case "jts_read_file":
            return try await readFile(arguments)
        case "jts_write_file":
            return try await writeFile(arguments)
        case "jts_upload_file":
            return try await uploadFile(arguments)
        case "jts_download_file":
            return try await downloadFile(arguments)
        case "jts_stat":
            return try await stat(arguments)
        case "jts_mkdir":
            return try await makeDirectory(arguments)
        case "jts_rename":
            return try await rename(arguments)
        case "jts_remove":
            return try await remove(arguments)
        case "jts_list_open_terminals":
            return try listOpenTerminals()
        case "jts_open_terminal":
            return try await openTerminal(arguments)
        case "jts_terminal_exec":
            return try terminalExec(arguments)
        case "jts_terminal_read":
            return try terminalRead(arguments)
        default:
            throw MCPToolFailure(message: "Unknown JTS Terminal MCP tool: \(name)")
        }
    }

    #if ENABLE_RDP_2
    private func callDeviceTool(_ tool: CompanionDeviceMCPTool, arguments: [String: Any]) async -> [String: Any] {
        do {
            _ = try CompanionDeviceMCPRequest(tool: tool, arguments: arguments)
            let target = try windowsTarget(from: arguments)
            _ = try await ensureGUIBridgeAvailable(waitSeconds: 30, activate: false)
            var routed = arguments
            routed["targetId"] = target.targetID.uuidString.lowercased()
            routed["_jtsClientID"] = mcpClientID
            routed["_jtsClientDisplayIdentity"] = mcpClientDisplayIdentity
            let response = try terminalBridgeClient.invokeDeviceTool(tool.rawValue,
                targetID: target.targetID.uuidString.lowercased(), arguments: routed)
            guard let value = response["structuredContent"] as? [String: Any], value["ok"] as? Bool == true,
                  value["targetId"] as? String == target.targetID.uuidString.lowercased() else { throw TerminalMCPBridgeError.invalidResponse }
            return try WindowsMCPToolResponse(structuredContent: value).mcpResult()
        } catch let failure as WindowsMCPToolError { return failure.mcpResult() }
        catch { return WindowsMCPToolError(code: .runtimeFailure, message: error.localizedDescription).mcpResult() }
    }

    private func callWindowsTool(
        _ tool: WindowsMCPToolName,
        arguments: [String: Any]
    ) async -> [String: Any] {
        do {
            if tool == .listTargets {
                var payload = try listTargetPayload()
                do {
                    let routes = try terminalBridgeClient.discoverDeviceRoutes(clientID: mcpClientID, displayIdentity: mcpClientDisplayIdentity)
                    payload["independentRoutes"] = routes
                    if var targets = payload["targets"] as? [[String: Any]] {
                        for index in targets.indices {
                            if let route = routes.first(where: { $0["targetId"] as? String == targets[index]["targetId"] as? String }),
                               let desktop = route["desktop"] as? [String: Any] {
                                var runtime = targets[index]["runtime"] as? [String: Any] ?? [:]
                                runtime["desktop"] = desktop; targets[index]["runtime"] = runtime
                            }
                        }
                        payload["targets"] = targets
                    }
                } catch {
                    payload["independentRoutes"] = []
                    payload["independentRouteDiscovery"] = "GUI bridge unavailable; jts_device_status can start it."
                }
                return try WindowsMCPToolResponse(structuredContent: payload).mcpResult()
            }

            try validateWindowsArguments(for: tool, arguments: arguments)
            var routedArguments = arguments
            routedArguments["_jtsClientID"] = mcpClientID
            routedArguments["_jtsClientDisplayIdentity"] = mcpClientDisplayIdentity
            if tool == .openDesktop, windowsDispatcher.availability.desktopRuntimeAvailable {
                let requestedMilliseconds = intValue(arguments["deadlineMs"])
                    ?? DesktopOpenRequestPolicy.defaultDeadlineMilliseconds
                let deadlineUptimeMilliseconds = Int(
                    ProcessInfo.processInfo.systemUptime * 1_000
                ) + requestedMilliseconds
                routedArguments = Self.routedDesktopOpenArguments(
                    routedArguments,
                    deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
                )
                let initialWaitSeconds = max(
                    0.1,
                    TimeInterval(requestedMilliseconds) / 1_000
                )
                do {
                    _ = try await ensureGUIBridgeAvailable(
                        waitSeconds: initialWaitSeconds,
                        deadlineUptimeMilliseconds: deadlineUptimeMilliseconds,
                        activate: arguments["activate"] as? Bool ?? true
                    )
                } catch {
                    guard deadlineUptimeMilliseconds > Int(ProcessInfo.processInfo.systemUptime * 1_000) else {
                        throw desktopOpenDeadlineExceeded(requestedMilliseconds: requestedMilliseconds)
                    }
                    throw error
                }
                let remainingMilliseconds = deadlineUptimeMilliseconds
                    - Int(ProcessInfo.processInfo.systemUptime * 1_000)
                guard remainingMilliseconds > 0 else {
                    throw desktopOpenDeadlineExceeded(requestedMilliseconds: requestedMilliseconds)
                }
            }
            let target = try windowsTarget(from: arguments)
            if tool == .openDesktop,
               let deadlineUptimeMilliseconds = intValue(routedArguments["_jtsDeadlineUptimeMilliseconds"]) {
                let remainingMilliseconds = deadlineUptimeMilliseconds
                    - Int(ProcessInfo.processInfo.systemUptime * 1_000)
                guard remainingMilliseconds > 0 else {
                    throw desktopOpenDeadlineExceeded(
                        requestedMilliseconds: intValue(arguments["deadlineMs"])
                            ?? DesktopOpenRequestPolicy.defaultDeadlineMilliseconds
                    )
                }
            }
            let response = try await windowsDispatcher.invoke(
                tool: tool,
                target: target,
                arguments: routedArguments
            ).validated(for: tool, arguments: routedArguments)
            return try response.mcpResult()
        } catch let failure as WindowsMCPToolError {
            return failure.mcpResult()
        } catch {
            return WindowsMCPToolError(
                code: .runtimeFailure,
                message: error.localizedDescription
            ).mcpResult()
        }
    }

    private func validateWindowsArguments(
        for tool: WindowsMCPToolName,
        arguments: [String: Any]
    ) throws {
        if tool == .openDesktop, let raw = arguments["activate"], WindowsUIAQuery.boolean(raw) == nil {
            throw WindowsMCPToolError(code: .invalidArgument, message: "activate must be a boolean.")
        }
        let deadlineRange = tool == .openDesktop
            ? DesktopOpenRequestPolicy.minimumDeadlineMilliseconds...DesktopOpenRequestPolicy.maximumDeadlineMilliseconds
            : 1...1_800_000
        if let deadline = intValue(arguments["deadlineMs"]),
           !deadlineRange.contains(deadline) {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: tool == .openDesktop
                    ? "deadlineMs must be between 100 and 60,000 milliseconds for desktop open requests."
                    : "deadlineMs must be between 1 and 1800000 milliseconds."
            )
        }
        if let key = arguments["idempotencyKey"] as? String {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let maximumCharacters = tool == .openDesktop
                ? DesktopOpenRequestPolicy.maximumIdempotencyKeyCharacters
                : 256
            guard !normalized.isEmpty,
                  normalized.utf16.count <= maximumCharacters,
                  !normalized.contains("\0") else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "idempotencyKey must contain 1 to \(maximumCharacters) characters and no NUL byte."
                )
            }
        }

        let toolsRequiringSession: Set<WindowsMCPToolName> = [
            .companionPairing,
            .desktopStatus,
            .desktopObserve,
            .desktopUIA,
            .desktopAction,
            .windowsExec,
            .windowsFiles,
            .windowsTask,
            .closeDesktop,
        ]
        if toolsRequiringSession.contains(tool) {
            guard let sessionID = optionalString("sessionId", in: arguments),
                  UUID(uuidString: sessionID) != nil else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "sessionId must be a desktop session UUID."
                )
            }
        }

        if tool == .desktopUIA {
            _ = try WindowsUIAQuery(arguments)
        }
        if tool == .companionPairing {
            _ = try WindowsMCPCompanionPairingRequest(arguments)
        }
        if tool == .desktopAction {
            let allowedKeys: Set<String> = [
                "targetId",
                "sessionId",
                "deadlineMs",
                "idempotencyKey",
                "expectedStateRevision",
                "action",
                "expectedFrameId",
                "expectedUiaObservationId",
                "selector",
                "x",
                "y",
                "button",
                "scrollDeltaY",
                "key",
                "keys",
                "text",
                "credentialRef",
                "purpose",
            ]
            guard Set(arguments.keys).isSubset(of: allowedKeys) else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "jts_desktop_action contains unsupported arguments."
                )
            }
            if arguments["action"] as? String == "fillCredential" {
                try WindowsMCPCredentialFillRequest.validate(arguments)
            } else {
                _ = try WindowsMCPDesktopActionRequestParser.parse(arguments)
            }
        }
    }

    private func desktopOpenDeadlineExceeded(
        requestedMilliseconds: Int
    ) -> WindowsMCPToolError {
        WindowsMCPToolError(
            code: .deadlineExceeded,
            message: "The desktop open request exceeded its \(requestedMilliseconds) millisecond deadline.",
            details: [
                "machineCode": "RDP_OPEN_DEADLINE_EXCEEDED",
                "retryable": true,
            ]
        )
    }
    #endif

    private func execute(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .exec,
            session: session
        )
        let command = try requiredString("command", in: arguments)
        let cwd = optionalString("cwd", in: arguments)
        let timeout = boundedTimeout(arguments["timeoutSeconds"], defaultSeconds: 60)
        let maxBytes = boundedByteLimit(arguments["maxOutputBytes"], defaultBytes: 1_048_576)
        let remoteCommand = cwd.map { "cd -- \(SSHCommandBuilder.shellQuote($0)) && \(command)" } ?? command
        let started = Date()
        let result = try await remoteRunner.runSSH(session: session, remoteCommand: remoteCommand, timeoutSeconds: timeout)
        let finished = Date()
        let stdout = truncate(result.standardOutput, maxBytes: maxBytes)
        let stderr = truncate(result.standardError, maxBytes: maxBytes)
        let truncated = stdout.truncated || stderr.truncated
        audit(tool: "jts_exec", session: session, summary: command, exitCode: Int(result.exitCode), truncated: truncated, started: started, finished: finished)
        return toolResult(try jsonText([
            "exitCode": Int(result.exitCode),
            "stdout": stdout.text,
            "stderr": stderr.text,
            "truncated": truncated,
            "durationMs": Int(finished.timeIntervalSince(started) * 1000)
        ]))
    }

    private func listDirectory(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .listDirectory,
            session: session
        )
        let path = optionalString("path", in: arguments) ?? session.remotePath
        let started = Date()
        let sftpResult = try await sftpTransport.listDirectory(session: session, path: path)
        var entries = RemoteSFTPFileListParser.parse(sftpResult.standardOutput)
        var transport = "sftp"
        var exitCode = Int(sftpResult.exitCode)

        if RemoteSFTPTransport.shouldAttemptSSHListingFallback(result: sftpResult, parsedEntries: entries) {
            let fallback = try await remoteRunner.runSSH(
                session: session,
                remoteCommand: SSHCommandBuilder.structuredDirectoryListingCommand(path: path),
                timeoutSeconds: 120
            )
            let fallbackEntries = RemoteStructuredFileListParser.parse(fallback.standardOutput)
            if fallback.succeeded {
                entries = fallbackEntries
                transport = "ssh"
                exitCode = Int(fallback.exitCode)
            } else if !sftpResult.succeeded {
                throw MCPToolFailure(message: RemoteSFTPTransport.failureMessage(for: sftpResult))
            }
        } else if !sftpResult.succeeded {
            throw MCPToolFailure(message: RemoteSFTPTransport.failureMessage(for: sftpResult))
        }

        let finished = Date()
        audit(tool: "jts_list_dir", session: session, summary: path, exitCode: exitCode, truncated: false, started: started, finished: finished)
        return toolResult(try jsonText([
            "path": path,
            "transport": transport,
            "entries": entries.map(remoteFileDictionary)
        ]))
    }

    private func readFile(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .readFile,
            session: session
        )
        let path = try requiredString("path", in: arguments)
        let offset = intValue(arguments["offset"]) ?? 0
        let limit = boundedByteLimit(arguments["limitBytes"], defaultBytes: 1_048_576)
        let requestedEncoding = optionalString("encoding", in: arguments) ?? "utf8"
        let started = Date()
        let result = try await remoteRunner.runSSH(
            session: session,
            remoteCommand: SSHCommandBuilder.readFileCommand(path: path, offset: offset, limitBytes: limit, encoding: requestedEncoding),
            timeoutSeconds: 120
        )
        let finished = Date()
        audit(tool: "jts_read_file", session: session, summary: path, exitCode: Int(result.exitCode), truncated: result.standardOutput.contains("\"truncated\": true"), started: started, finished: finished)
        guard result.succeeded else {
            throw MCPToolFailure(message: result.displayText)
        }
        return toolResult(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func writeFile(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .writeFile,
            session: session
        )
        let path = try requiredString("path", in: arguments)
        let content = try requiredString("content", in: arguments)
        let encoding = optionalString("encoding", in: arguments) ?? "utf8"
        let createParents = boolValue(arguments["createParents"]) ?? false
        let mode = optionalString("mode", in: arguments)
        let data: Data
        if encoding == "base64" {
            guard let decoded = Data(base64Encoded: content) else {
                throw MCPToolFailure(message: "Invalid base64 content.")
            }
            data = decoded
        } else {
            data = Data(content.utf8)
        }
        let started = Date()
        let result = try await remoteRunner.runSSH(
            session: session,
            remoteCommand: SSHCommandBuilder.writeFileCommand(
                path: path,
                createParents: createParents,
                mode: mode
            ),
            standardInput: data.base64EncodedString(),
            timeoutSeconds: 120
        )
        let finished = Date()
        audit(tool: "jts_write_file", session: session, summary: path, exitCode: Int(result.exitCode), truncated: false, started: started, finished: finished)
        guard result.succeeded else {
            throw MCPToolFailure(message: result.displayText)
        }
        return toolResult(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func uploadFile(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .uploadFile,
            session: session
        )
        let localPath = expandedLocalPath(try requiredString("localPath", in: arguments))
        let remotePath = try requiredString("remotePath", in: arguments)
        let localAccess = try LocalTransferAccessStore().beginAccess(to: URL(fileURLWithPath: localPath))
        defer { localAccess.stop() }
        let isDirectory: Bool
        do {
            isDirectory = try URL(fileURLWithPath: localPath)
                .resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            throw LocalTransferAccessRequired.explaining(error, path: localPath)
        }

        let recursive = boolValue(arguments["recursive"]) ?? isDirectory
        if isDirectory, !recursive {
            throw MCPToolFailure(message: "Local upload path is a directory. Set recursive=true to upload directories.")
        }
        let resume = (boolValue(arguments["resume"]) ?? true) && !recursive
        let expectedBytes = recursive ? nil : localFileSize(at: localPath)

        return try await runFileTransfer(
            tool: "jts_upload_file",
            session: session,
            direction: .upload,
            remotePath: remotePath,
            localPath: localPath,
            recursive: recursive,
            resume: resume,
            expectedByteCount: expectedBytes
        ) {
            try await fileTransferRunner.upload(session, localPath, remotePath, recursive, resume)
        }
    }

    private func downloadFile(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        let remotePath = try requiredString("remotePath", in: arguments)
        let localPath = expandedLocalPath(try requiredString("localPath", in: arguments))
        let localAccess = try LocalTransferAccessStore().beginAccess(to: URL(fileURLWithPath: localPath))
        defer { localAccess.stop() }
        let destinationExists = FileManager.default.fileExists(atPath: localPath)
        _ = try authorizeLegacy(
            tool: .downloadFile,
            session: session,
            overwritesLocalDestination: destinationExists
        )
        let recursive = boolValue(arguments["recursive"]) ?? false
        let resume = (boolValue(arguments["resume"]) ?? true) && !recursive
        let createParents = boolValue(arguments["createParents"]) ?? true
        if createParents {
            do {
                try createParentDirectoryIfNeeded(forLocalPath: localPath)
            } catch {
                throw LocalTransferAccessRequired.explaining(error, path: localPath)
            }
        }
        let expectedBytes = int64Value(arguments["expectedBytes"])
        if let expectedBytes, expectedBytes < 0 {
            throw MCPToolFailure(message: "expectedBytes must be nonnegative.")
        }

        return try await runFileTransfer(
            tool: "jts_download_file",
            session: session,
            direction: .download,
            remotePath: remotePath,
            localPath: localPath,
            recursive: recursive,
            resume: resume,
            expectedByteCount: expectedBytes
        ) {
            try await fileTransferRunner.download(session, remotePath, localPath, recursive, resume, expectedBytes)
        }
    }

    private func runFileTransfer(
        tool: String,
        session: RemoteSession,
        direction: RemoteTransferDirection,
        remotePath: String,
        localPath: String,
        recursive: Bool,
        resume: Bool,
        expectedByteCount: Int64?,
        operation: () async throws -> CommandResult
    ) async throws -> [String: Any] {
        let task = RemoteTransferTask(
            session: session,
            direction: direction,
            remotePath: remotePath,
            localPath: localPath,
            recursive: recursive,
            resumeSupported: resume,
            expectedByteCount: expectedByteCount
        )
        modelContext.insert(task)
        task.markRunning()
        try? modelContext.save()

        let started = Date()
        do {
            let result = RemoteSFTPTransport.resultByRecognizingSFTPFailureOutput(try await operation())
            let finished = Date()
            if result.succeeded, direction == .download, !recursive {
                let destination = LocalTransferFileIO.downloadDestination(
                    localPath: localPath, remotePath: remotePath, recursive: false
                )
                try LocalTransferFileIO.verifyDownload(destination, recursive: false, expectedBytes: expectedByteCount)
                task.transferredByteCount = try LocalTransferFileIO.byteCount(at: destination)
            }
            task.markFinished(result: result)
            try? modelContext.save()
            audit(
                tool: tool,
                session: session,
                summary: task.summary,
                exitCode: Int(result.exitCode),
                truncated: false,
                started: started,
                finished: finished
            )
            guard result.succeeded else {
                throw MCPToolFailure(message: result.displayText)
            }
            return toolResult(try jsonText(fileTransferPayload(
                task: task,
                session: session,
                result: result,
                durationMs: Int(finished.timeIntervalSince(started) * 1000)
            )))
        } catch let failure as MCPToolFailure {
            task.markFailed(failure.message)
            try? modelContext.save()
            audit(
                tool: tool,
                session: session,
                summary: task.summary,
                exitCode: task.exitCode,
                truncated: false,
                started: started,
                finished: Date()
            )
            throw failure
        } catch {
            task.markFailed(error.localizedDescription)
            try? modelContext.save()
            audit(
                tool: tool,
                session: session,
                summary: task.summary,
                exitCode: task.exitCode,
                truncated: false,
                started: started,
                finished: Date()
            )
            throw error
        }
    }

    private func stat(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .stat,
            session: session
        )
        let path = try requiredString("path", in: arguments)
        let started = Date()
        let result = try await remoteRunner.runSSH(session: session, remoteCommand: SSHCommandBuilder.statCommand(path: path), timeoutSeconds: 60)
        let finished = Date()
        audit(tool: "jts_stat", session: session, summary: path, exitCode: Int(result.exitCode), truncated: false, started: started, finished: finished)
        guard result.succeeded else { throw MCPToolFailure(message: result.displayText) }
        return toolResult(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func makeDirectory(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .makeDirectory,
            session: session
        )
        let path = try requiredString("path", in: arguments)
        let parents = boolValue(arguments["parents"]) ?? false
        return try await runSimpleShellTool("jts_mkdir", session: session, summary: path, command: "\(parents ? "mkdir -p --" : "mkdir --") \(SSHCommandBuilder.shellQuote(path))")
    }

    private func rename(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .rename,
            session: session
        )
        let from = try requiredString("from", in: arguments)
        let to = try requiredString("to", in: arguments)
        return try await runSimpleShellTool("jts_rename", session: session, summary: "\(from) -> \(to)", command: "mv -- \(SSHCommandBuilder.shellQuote(from)) \(SSHCommandBuilder.shellQuote(to))")
    }

    private func remove(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try session(from: arguments)
        _ = try authorizeLegacy(
            tool: .remove,
            session: session
        )
        let path = try requiredString("path", in: arguments)
        let recursive = boolValue(arguments["recursive"]) ?? false
        let command = recursive
            ? "rm -rf -- \(SSHCommandBuilder.shellQuote(path))"
            : "if [ -d \(SSHCommandBuilder.shellQuote(path)) ]; then rmdir -- \(SSHCommandBuilder.shellQuote(path)); else rm -- \(SSHCommandBuilder.shellQuote(path)); fi"
        return try await runSimpleShellTool("jts_remove", session: session, summary: path, command: command)
    }

    private func runSimpleShellTool(_ tool: String, session: RemoteSession, summary: String, command: String) async throws -> [String: Any] {
        let started = Date()
        let result = try await remoteRunner.runSSH(session: session, remoteCommand: command, timeoutSeconds: 120)
        let finished = Date()
        audit(tool: tool, session: session, summary: summary, exitCode: Int(result.exitCode), truncated: false, started: started, finished: finished)
        guard result.succeeded else {
            throw MCPToolFailure(message: result.displayText)
        }
        return toolResult(try jsonText(["exitCode": Int(result.exitCode), "stdout": result.standardOutput, "stderr": result.standardError]))
    }

    private func listOpenTerminals() throws -> [String: Any] {
        var listedAliases: Set<String> = []
        for session in try enabledTerminalSessions() {
            recordDiscoveryAudit(
                session: session,
                actionType: LegacyMCPAuthorizationContract.requirement(
                    for: .listOpenTerminals
                ).auditCategory
            )
            listedAliases.insert(session.effectiveMCPAlias)
        }
        let terminals = try terminalBridgeClient
            .listOpenTerminals(clientID: mcpClientID)
            .filter { terminal in
                guard let alias = terminal["serverAlias"] as? String else { return false }
                return listedAliases.contains(alias)
            }
        return toolResult(try jsonText(["terminals": terminals]))
    }

    private func terminalExec(_ arguments: [String: Any]) throws -> [String: Any] {
        let terminalID = try requiredString("terminalId", in: arguments)
        let command = try requiredString("command", in: arguments)
        let session = try terminalSession(forTerminalID: terminalID)
        _ = try authorizeLegacy(
            tool: .terminalExec,
            session: session
        )
        let timeout = boundedTimeout(arguments["timeoutSeconds"], defaultSeconds: 60)
        let maxBytes = boundedByteLimit(arguments["maxOutputBytes"], defaultBytes: 1_048_576)
        let result = try terminalBridgeClient.executeTerminal(
            terminalID: terminalID,
            command: command,
            timeoutSeconds: timeout,
            maxOutputBytes: maxBytes,
            clientID: mcpClientID
        )
        return toolResult(try jsonText(result))
    }

    private func terminalRead(_ arguments: [String: Any]) throws -> [String: Any] {
        let terminalID = try requiredString("terminalId", in: arguments)
        let session = try terminalSession(forTerminalID: terminalID)
        _ = try authorizeLegacy(
            tool: .terminalRead,
            session: session
        )
        let maxBytes = boundedByteLimit(arguments["maxOutputBytes"], defaultBytes: 16_384)
        let result = try terminalBridgeClient.readTerminal(
            terminalID: terminalID,
            maxOutputBytes: maxBytes,
            clientID: mcpClientID
        )
        return toolResult(try jsonText(result))
    }

    private func openTerminal(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try terminalSession(from: arguments)
        _ = try authorizeLegacy(
            tool: .openTerminal,
            session: session
        )
        let waitSeconds = min(max(TimeInterval(intValue(arguments["waitSeconds"]) ?? 20), 1), 60)
        let requireMCPControl = boolValue(arguments["requireMCPControl"]) ?? false
        if requireMCPControl, !session.mcpAlwaysAllowTerminalControl {
            throw MCPToolFailure(message: "Terminal profile '\(session.effectiveMCPAlias)' is MCP-enabled, but persistent MCP Control is not enabled. Enable 'Always allow MCP Control for all terminal sessions' in Server Properties, or open the terminal and use the per-pane temporary switch.")
        }

        let started = Date()
        let launchedGUI = try await ensureGUIBridgeAvailable(waitSeconds: waitSeconds)
        var result = try terminalBridgeClient.openTerminal(
            serverAlias: session.effectiveMCPAlias,
            waitSeconds: waitSeconds,
            clientID: mcpClientID
        )
        result["launchedGUI"] = launchedGUI
        result["durationMs"] = Int(Date().timeIntervalSince(started) * 1000)
        if result["mcpControlAuthorized"] as? Bool != true {
            result["note"] = "Terminal opened, but jts_terminal_exec requires either persistent MCP Control on this server or the pane-level temporary MCP switch."
        }
        return toolResult(try jsonText(result))
    }

    private func ensureGUIBridgeAvailable(
        waitSeconds: TimeInterval,
        deadlineUptimeMilliseconds explicitDeadlineUptimeMilliseconds: Int? = nil,
        activate: Bool = true
    ) async throws -> Bool {
        let deadlineUptimeMilliseconds = explicitDeadlineUptimeMilliseconds
            ?? Int(ProcessInfo.processInfo.systemUptime * 1_000)
                + max(1, Int(ceil(waitSeconds * 1_000)))
        do {
            _ = try terminalBridgeClient.listOpenTerminals(
                deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
            )
            return false
        } catch {
            guard isRecoverableBridgeStartupError(error) else {
                throw error
            }
        }

        guard deadlineUptimeMilliseconds > Int(ProcessInfo.processInfo.systemUptime * 1_000) else {
            throw TerminalMCPBridgeError.deadlineExceeded
        }
        if !activate, let launchInBackground = guiLauncher.launchInBackground { try launchInBackground() }
        else { try guiLauncher.launch() }
        var lastError: Error?
        while deadlineUptimeMilliseconds > Int(ProcessInfo.processInfo.systemUptime * 1_000) {
            do {
                _ = try terminalBridgeClient.listOpenTerminals(
                    deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
                )
                return true
            } catch {
                lastError = error
                guard isRecoverableBridgeStartupError(error) else {
                    throw error
                }
                let remainingMilliseconds = deadlineUptimeMilliseconds
                    - Int(ProcessInfo.processInfo.systemUptime * 1_000)
                guard remainingMilliseconds > 0 else { break }
                try await Task.sleep(
                    for: .milliseconds(min(250, remainingMilliseconds))
                )
            }
        }

        throw MCPToolFailure(message: "JTS Terminal GUI did not publish its MCP bridge within \(Int(waitSeconds)) seconds. Last error: \(lastError?.localizedDescription ?? "unknown")")
    }

    private func isRecoverableBridgeStartupError(_ error: Error) -> Bool {
        guard let bridgeError = error as? TerminalMCPBridgeError else {
            return false
        }
        switch bridgeError {
        case .descriptorMissing, .guiNotRunning, .socketFailure:
            return true
        case .socketPathTooLong, .deadlineExceeded, .invalidResponse, .unauthorized, .bridgeError:
            return false
        }
    }

    private func readResource(uri: String) async throws -> [String: Any] {
        if uri == "jts://servers" {
            return ["contents": [["uri": uri, "mimeType": "application/json", "text": try jsonText(listServerPayload())]]]
        }

        guard let components = URLComponents(string: uri),
              components.scheme == "jts",
              components.host == "server" else {
            throw MCPToolFailure(message: "Unsupported resource URI: \(uri)")
        }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[1] == "file" else {
            throw MCPToolFailure(message: "Unsupported server resource URI: \(uri)")
        }
        let alias = parts[0]
        let path = "/" + parts.dropFirst(2).joined(separator: "/")
        let result = try await readFile(["server": alias, "path": path, "encoding": "utf8"])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return ["contents": [["uri": uri, "mimeType": "text/plain", "text": text]]]
    }

    private func enabledSSHSessions() throws -> [RemoteSession] {
        let descriptor = FetchDescriptor<RemoteSession>()
        return try modelContext.fetch(descriptor)
            .filter { $0.mcpEnabled && $0.connectionType == .ssh && $0.isConnectable }
            .sorted { $0.effectiveMCPAlias.localizedStandardCompare($1.effectiveMCPAlias) == .orderedAscending }
    }

    private func enabledTargetSessions() throws -> [RemoteSession] {
        let descriptor = FetchDescriptor<RemoteSession>()
        return try modelContext.fetch(descriptor)
            .filter { $0.mcpEnabled && $0.isConnectable }
            .sorted { $0.effectiveMCPAlias.localizedStandardCompare($1.effectiveMCPAlias) == .orderedAscending }
    }

    #if ENABLE_RDP_2
    private func windowsTarget(from arguments: [String: Any]) throws -> RemoteSession {
        guard let rawTargetID = optionalString("targetId", in: arguments),
              let targetID = UUID(uuidString: rawTargetID) else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "targetId must be a stable target UUID from jts_list_targets."
            )
        }
        guard let target = try enabledTargetSessions().first(where: {
            $0.targetID == targetID && $0.connectionType == .rdp
        }) else {
            throw WindowsMCPToolError(
                code: .targetNotFound,
                message: "The requested target is not an MCP-enabled, connectable RDP profile.",
                details: ["targetId": rawTargetID]
            )
        }
        return target
    }

    private func listTargetPayload() throws -> [String: Any] {
        var targets: [[String: Any]] = []
        var pendingRequestIDs: Set<String> = []
        for session in try enabledTargetSessions() {
            recordDiscoveryAudit(
                session: session,
                actionType: WindowsMCPToolName.listTargets.rawValue
            )
            let target = session.remoteTargetDescriptor
            var runtime: [String: Any] = [
                "desktopRuntimeAvailable": NSNull(),
                "companionAvailable": NSNull(),
            ]
            if session.connectionType == .rdp {
                runtime = [
                    "desktopRuntimeAvailable": windowsDispatcher.availability.desktopRuntimeAvailable,
                    "companionAvailable": windowsDispatcher.availability.companionAvailable,
                    "reason": windowsDispatcher.availability.reason ?? NSNull(),
                ]
            }
            let authorization = targetAuthorizationPayload(for: session)
            if let targetPendingRequestIDs = authorization["pendingRequestIds"] as? [String] {
                pendingRequestIDs.formUnion(targetPendingRequestIDs)
            }
            targets.append([
                "targetId": target.targetID.uuidString.lowercased(),
                "alias": target.alias,
                "name": target.name,
                "connectionType": target.connectionType.rawValue,
                "address": target.address,
                "configuredCapabilities": target.configuredCapabilities.map(\.rawValue).sorted(),
                "authorization": authorization,
                "runtime": runtime,
            ])
        }
        return [
            "targets": targets,
            "authorization": [
                "status": pendingRequestIDs.isEmpty ? "complete" : "approval_required",
                "pendingRequestIds": pendingRequestIDs.sorted(),
                "denialCodes": [String](),
            ],
        ]
    }

    private func targetAuthorizationPayload(for session: RemoteSession) -> [String: Any] {
        // Remove policy-obsolete and older-endpoint requests before reporting
        // the exact target binding's current authorization state.
        _ = try? remoteGrantStore.reconcileResolvedPendingRequests(
            targetID: session.targetID,
            policy: session.mcpPermissionPolicy,
            targetBinding: session.mcpGrantTargetBinding
        )
        let configuredCapabilities = Set(session.remoteTargetDescriptor.configuredCapabilities)
        let clientGrants = remoteGrantStore.activeGrants(
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding
        )
            .filter { $0.clientID == mcpClientID }
        let grantedCapabilities = clientGrants.reduce(into: Set<RemoteCapability>()) {
            $0.formUnion($1.capabilities.intersection(session.mcpPermissionPolicy.maximumCapabilities))
        }
        let pendingRequests = remoteGrantStore.pendingRequests(
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding
        )
            .filter { $0.clientID == mcpClientID }
        let pendingCapabilities = pendingRequests.reduce(into: Set<RemoteCapability>()) {
            $0.formUnion($1.requestedCapabilities)
        }
        let unresolvedCapabilities = configuredCapabilities
            .subtracting(grantedCapabilities)
            .subtracting(pendingCapabilities)
        let status: String
        if !pendingRequests.isEmpty {
            status = "approval_required"
        } else if configuredCapabilities.isSubset(of: grantedCapabilities) {
            status = "complete"
        } else if grantedCapabilities.isEmpty {
            status = "not_granted"
        } else {
            status = "partial"
        }
        return [
            "status": status,
            "grantedCapabilities": grantedCapabilities.map(\.rawValue).sorted(),
            "pendingCapabilities": pendingCapabilities.map(\.rawValue).sorted(),
            "unresolvedCapabilities": unresolvedCapabilities.map(\.rawValue).sorted(),
            "pendingRequestIds": pendingRequests.map { $0.id.uuidString.lowercased() }.sorted(),
        ]
    }
    #endif

    private func enabledTerminalSessions() throws -> [RemoteSession] {
        let descriptor = FetchDescriptor<RemoteSession>()
        return try modelContext.fetch(descriptor)
            .filter {
                $0.mcpEnabled &&
                    $0.isConnectable &&
                    TerminalWorkspaceState.Kind.preferredTerminalKind(for: $0) != nil
            }
            .sorted { $0.effectiveMCPAlias.localizedStandardCompare($1.effectiveMCPAlias) == .orderedAscending }
    }

    private func session(from arguments: [String: Any]) throws -> RemoteSession {
        let alias = MCPAlias.normalized(try requiredString("server", in: arguments))
        guard let session = try enabledSSHSessions().first(where: { $0.effectiveMCPAlias == alias }) else {
            throw MCPToolFailure(message: "Server '\(alias)' is not MCP-enabled or is not an SSH profile.")
        }
        return session
    }

    private func terminalSession(from arguments: [String: Any]) throws -> RemoteSession {
        let alias = MCPAlias.normalized(try requiredString("server", in: arguments))
        guard let session = try enabledTerminalSessions().first(where: { $0.effectiveMCPAlias == alias }) else {
            throw MCPToolFailure(message: "Terminal profile '\(alias)' is not MCP-enabled or is not connectable.")
        }
        return session
    }

    private func terminalSession(forTerminalID terminalID: String) throws -> RemoteSession {
        let terminals = try terminalBridgeClient.listOpenTerminals(clientID: mcpClientID)
        guard let terminal = terminals.first(where: { $0["terminalId"] as? String == terminalID }),
              let alias = terminal["serverAlias"] as? String,
              let session = try enabledTerminalSessions().first(where: {
                  $0.effectiveMCPAlias == MCPAlias.normalized(alias)
              }) else {
            throw MCPToolFailure(message: "Terminal '\(terminalID)' is not an MCP-enabled open terminal.")
        }
        return session
    }

    private func listServerPayload() throws -> [[String: Any]] {
        var payloads: [[String: Any]] = []
        for session in try enabledTerminalSessions() {
            recordDiscoveryAudit(
                session: session,
                actionType: LegacyMCPAuthorizationContract.requirement(
                    for: .listServers
                ).auditCategory
            )
            var capabilities: [String]
            switch session.connectionType {
            case .ssh:
                capabilities = [
                    "exec",
                    "list_dir",
                    "read_file",
                    "write_file",
                    "upload_file",
                    "download_file",
                    "stat",
                    "mkdir",
                    "rename",
                    "remove",
                    "open_terminal"
                ]
            case .localShell:
                capabilities = [
                    "open_terminal",
                    "terminal_exec",
                    "terminal_read"
                ]
            case .rdp, .macDesktop:
                capabilities = []
            }
            if session.mcpAlwaysAllowTerminalControl {
                capabilities.append("persistent_terminal_control")
            }
            var payload: [String: Any] = [
                "alias": session.effectiveMCPAlias,
                "name": session.name,
                "connectionType": session.connectionType.rawValue,
                "address": session.address,
                "persistentMCPControl": session.mcpAlwaysAllowTerminalControl,
                "capabilities": capabilities
            ]
            if session.connectionType == .ssh {
                payload.merge([
                "host": session.host,
                "username": session.username,
                "port": session.port,
                "defaultPath": session.remotePath
                ]) { _, new in new }
            }
            payloads.append(payload)
        }
        return payloads
    }

    private func resourceList() throws -> [[String: Any]] {
        var resources: [[String: Any]] = [
            [
                "uri": "jts://servers",
                "name": "MCP-enabled JTS Terminal servers",
                "mimeType": "application/json"
            ]
        ]
        let authorizedSessions: [RemoteSession]
        #if ENABLE_RDP_2
        // The GUI and stdio server own separate grant-store instances. Refresh
        // the read-only snapshot so approvals and revocations are reflected in
        // resource discovery without creating or surfacing an approval request.
        remoteGrantStore.reloadFromDiskIfChanged(
            postApprovalRequestNotifications: false
        )
        let checkedAt = Date()
        authorizedSessions = try enabledSSHSessions().filter {
            hasDiscoverableFileResource(for: $0, at: checkedAt)
        }
        #else
        authorizedSessions = try enabledSSHSessions()
        #endif
        resources += authorizedSessions.map {
                [
                    "uri": "jts://server/\($0.effectiveMCPAlias)/file/\($0.remotePath)",
                    "name": "\($0.effectiveMCPAlias) default path",
                    "mimeType": "text/plain"
                ]
            }
        return resources
    }

    #if ENABLE_RDP_2
    /// MCP clients commonly enumerate resources while establishing a session.
    /// Enabling MCP on the profile is enough to advertise the default path;
    /// an explicit revoke still hides it. `resources/read` continues to run
    /// the normal authorization check before returning file bytes.
    private func hasDiscoverableFileResource(
        for session: RemoteSession,
        at date: Date
    ) -> Bool {
        let permissionPolicy = session.mcpPermissionPolicy
        guard permissionPolicy.maximumCapabilities.contains(.fileAccess) else {
            return false
        }
        return !remoteGrantStore.hasBlockingRevocation(
            clientID: mcpClientID,
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding,
            at: date
        )
    }
    #endif

    private func recordDiscoveryAudit(
        session: RemoteSession,
        actionType: String,
        at startedAt: Date = Date()
    ) {
        #if ENABLE_RDP_2
        RemoteCapabilityAuditStore.shared.record(
            clientID: mcpClientID,
            clientDisplayIdentity: mcpClientDisplayIdentity,
            targetID: session.targetID,
            targetAlias: session.effectiveMCPAlias,
            actionType: actionType,
            capabilities: [.discovery],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: startedAt
        )
        #endif
    }

    @discardableResult
    private func authorizeLegacy(
        tool: LegacyMCPToolName,
        session: RemoteSession,
        overwritesLocalDestination: Bool = false,
        at startedAt: Date = Date()
    ) throws -> LegacyMCPAuthorization {
        let requirement = LegacyMCPAuthorizationContract.requirement(
            for: tool,
            overwritesLocalDestination: overwritesLocalDestination
        )
        return try authorizeLegacy(
            session: session,
            capabilities: requirement.permissions,
            externalDataTypes: requirement.externalData,
            category: requirement.auditCategory,
            at: startedAt
        )
    }

    @discardableResult
    private func authorizeLegacy(
        session: RemoteSession,
        capabilities: Set<LegacyMCPPermission>,
        externalDataTypes: Set<LegacyMCPExternalData>,
        category: String,
        at startedAt: Date = Date()
    ) throws -> LegacyMCPAuthorization {
        #if ENABLE_RDP_2
        let remoteCapabilities = Set(capabilities.map(\.remoteCapability))
        let remoteDataTypes = Set(externalDataTypes.map(\.remoteDataType))
        do {
            let authorization = try remoteGrantStore.authorize(
                clientID: mcpClientID,
                clientDisplayIdentity: mcpClientDisplayIdentity,
                targetID: session.targetID,
                targetBinding: session.mcpGrantTargetBinding,
                capabilities: remoteCapabilities,
                policy: session.mcpPermissionPolicy,
                externalDataTypes: remoteDataTypes,
                implicitProfileAccess: session.mcpEnabled,
                at: startedAt
            )
            RemoteCapabilityAuditStore.shared.record(
                clientID: mcpClientID,
                clientDisplayIdentity: mcpClientDisplayIdentity,
                targetID: session.targetID,
                targetAlias: session.effectiveMCPAlias,
                actionType: category,
                capabilities: remoteCapabilities,
                result: .succeeded,
                resultCode: "OK",
                controlLeaseExpiresAt: authorization.controlLeaseExpiresAt,
                startedAt: startedAt
            )
            return LegacyMCPAuthorization(
                controlLeaseExpiresAt: authorization.controlLeaseExpiresAt
            )
        } catch let failure as RemoteGrantGateFailure {
            RemoteCapabilityAuditStore.shared.record(
                clientID: mcpClientID,
                clientDisplayIdentity: mcpClientDisplayIdentity,
                targetID: session.targetID,
                targetAlias: session.effectiveMCPAlias,
                actionType: category,
                capabilities: remoteCapabilities,
                result: .denied,
                resultCode: failure.denialCode,
                controlLeaseExpiresAt: nil,
                startedAt: startedAt
            )
            let requestSuffix = failure.pendingRequestID.map {
                " Pending request: \($0.uuidString.lowercased())."
            } ?? ""
            throw MCPToolFailure(message: "\(failure.denialCode): \(failure.message)\(requestSuffix)")
        } catch {
            RemoteCapabilityAuditStore.shared.record(
                clientID: mcpClientID,
                clientDisplayIdentity: mcpClientDisplayIdentity,
                targetID: session.targetID,
                targetAlias: session.effectiveMCPAlias,
                actionType: category,
                capabilities: remoteCapabilities,
                result: .failed,
                resultCode: "RUNTIME_FAILURE",
                controlLeaseExpiresAt: nil,
                startedAt: startedAt
            )
            throw error
        }
        #else
        return LegacyMCPAuthorization(controlLeaseExpiresAt: nil)
        #endif
    }

    private func audit(tool: String, session: RemoteSession, summary _: String, exitCode: Int, truncated: Bool, started: Date, finished: Date) {
        MCPAuditRecordPolicy.purgeExpired(in: modelContext, now: finished)
        modelContext.insert(MCPAuditEntry(
            clientID: mcpClientID,
            toolName: tool,
            serverAlias: session.effectiveMCPAlias,
            operationSummary: MCPAuditRecordPolicy.actionCategory(for: tool),
            exitCode: exitCode,
            outputTruncated: truncated,
            startedAt: started,
            finishedAt: finished
        ))
        try? modelContext.save()
    }

    private func toolDefinitions() -> [[String: Any]] {
        var definitions = [
            tool("jts_list_servers", "List JTS Terminal connection profiles explicitly enabled for MCP access. SSH profiles expose remote file tools; Local Shell profiles expose terminal-control tools only.", [:]),
            tool("jts_exec", "Run a shell command on an MCP-enabled SSH server.", [
                "server": stringSchema("MCP server alias"),
                "command": stringSchema("Remote shell command"),
                "cwd": stringSchema("Optional remote working directory"),
                "timeoutSeconds": numberSchema("Optional timeout in seconds"),
                "maxOutputBytes": numberSchema("Optional stdout/stderr byte limit")
            ], required: ["server", "command"]),
            tool("jts_list_dir", "List a remote directory.", ["server": stringSchema("MCP server alias"), "path": stringSchema("Remote path")], required: ["server"]),
            tool("jts_read_file", "Read a remote file.", ["server": stringSchema("MCP server alias"), "path": stringSchema("Remote path"), "offset": numberSchema("Byte offset"), "limitBytes": numberSchema("Maximum bytes"), "encoding": stringSchema("utf8 or base64")], required: ["server", "path"]),
            tool("jts_write_file", "Write a remote file atomically.", ["server": stringSchema("MCP server alias"), "path": stringSchema("Remote path"), "content": stringSchema("Content"), "encoding": stringSchema("utf8 or base64"), "createParents": booleanSchema("Create parent directories"), "mode": stringSchema("Optional chmod mode")], required: ["server", "path", "content"]),
            tool("jts_upload_file", "Upload a local file or directory to an MCP-enabled SSH server using the same SFTP transfer path as the Files workspace.", [
                "server": stringSchema("MCP server alias"),
                "localPath": stringSchema("Local source file or directory path. ~/Downloads, ~/Pictures, ~/Music and ~/Movies are available by default; other folders may require access in JTS Terminal."),
                "remotePath": stringSchema("Remote destination path"),
                "recursive": booleanSchema("Set true to upload a directory recursively"),
                "resume": booleanSchema("Resume a partial single-file upload when supported")
            ], required: ["server", "localPath", "remotePath"]),
            tool("jts_download_file", "Download a remote file or directory from an MCP-enabled SSH server using the same SFTP transfer path as the Files workspace.", [
                "server": stringSchema("MCP server alias"),
                "remotePath": stringSchema("Remote source file or directory path"),
                "localPath": stringSchema("Local destination path. Use ~/Downloads for a destination available by default; ~/Pictures, ~/Music and ~/Movies are also supported without a folder grant."),
                "recursive": booleanSchema("Set true to download a directory recursively"),
                "resume": booleanSchema("Resume a partial single-file download when supported"),
                "createParents": booleanSchema("Create missing local parent directories before downloading"),
                "expectedBytes": numberSchema("Optional expected byte count for progress history")
            ], required: ["server", "remotePath", "localPath"]),
            tool("jts_stat", "Stat a remote path.", ["server": stringSchema("MCP server alias"), "path": stringSchema("Remote path")], required: ["server", "path"]),
            tool("jts_mkdir", "Create a remote directory.", ["server": stringSchema("MCP server alias"), "path": stringSchema("Remote path"), "parents": booleanSchema("Create parent directories")], required: ["server", "path"]),
            tool("jts_rename", "Rename or move a remote path.", ["server": stringSchema("MCP server alias"), "from": stringSchema("Source path"), "to": stringSchema("Destination path")], required: ["server", "from", "to"]),
            tool("jts_remove", "Remove a remote file or directory.", ["server": stringSchema("MCP server alias"), "path": stringSchema("Remote path"), "recursive": booleanSchema("Recursive delete")], required: ["server", "path"]),
            tool("jts_list_open_terminals", "List running JTS Terminal SSH or Local Shell sessions explicitly authorized for MCP terminal control. Use mcpName, connectionType, and terminalId to choose the intended terminal; a Local Shell that the user already switched to root will execute commands as root.", [:]),
            tool("jts_open_terminal", "Launch JTS Terminal GUI if needed, then open and start the interactive terminal for an MCP-enabled SSH or Local Shell profile.", [
                "server": stringSchema("MCP server alias"),
                "waitSeconds": numberSchema("Optional seconds to wait for the GUI bridge and terminal process startup"),
                "requireMCPControl": booleanSchema("Require persistent MCP Control so the opened pane can be used by jts_terminal_exec")
            ], required: ["server"]),
            tool("jts_terminal_exec", "Run a queued shell command inside an authorized open JTS Terminal session, preserving that terminal's current shell identity.", [
                "terminalId": stringSchema("Authorized terminal ID from jts_list_open_terminals. Choose it by matching the desired mcpName."),
                "command": stringSchema("Shell command to run in the open terminal"),
                "timeoutSeconds": numberSchema("Optional timeout in seconds"),
                "maxOutputBytes": numberSchema("Optional stdout byte limit")
            ], required: ["terminalId", "command"]),
            tool("jts_terminal_read", "Read recent transcript text from an authorized open JTS Terminal session without sending input.", [
                "terminalId": stringSchema("Authorized terminal ID from jts_list_open_terminals. Choose it by matching the desired mcpName."),
                "maxOutputBytes": numberSchema("Optional transcript byte limit")
            ], required: ["terminalId"])
        ]
        #if ENABLE_RDP_2
        definitions += WindowsMCPToolRegistry.definitions
        definitions += CompanionDeviceMCPRegistry.definitions
        #endif
        return definitions
    }

    private func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }

    private func stringSchema(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private func numberSchema(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    private func booleanSchema(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }

    private func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func fileTransferPayload(
        task: RemoteTransferTask,
        session: RemoteSession,
        result: CommandResult,
        durationMs: Int
    ) -> [String: Any] {
        [
            "transferId": String(describing: task.persistentModelID),
            "direction": task.direction.rawValue,
            "status": task.status.rawValue,
            "serverAlias": session.effectiveMCPAlias,
            "remotePath": task.remotePath,
            "localPath": task.localPath,
            "recursive": task.recursive,
            "resume": task.resumeSupported,
            "expectedBytes": task.expectedByteCount ?? NSNull(),
            "transferredBytes": task.recursive ? NSNull() : task.transferredByteCount as Any,
            "exitCode": Int(result.exitCode),
            "stdout": result.standardOutput,
            "stderr": result.standardError,
            "durationMs": durationMs
        ]
    }

    private func remoteFileDictionary(_ entry: RemoteFileEntry) -> [String: Any] {
        [
            "name": entry.name,
            "displayName": entry.displayName,
            "kind": entry.kind.rawValue,
            "permissions": entry.permissions,
            "owner": entry.owner,
            "group": entry.group,
            "size": entry.byteSize ?? 0,
            "modified": entry.modified,
            "linkTarget": entry.linkTarget ?? NSNull()
        ]
    }

    private func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = optionalString(key, in: arguments) else {
            throw MCPToolFailure(message: "Missing required parameter: \(key)")
        }
        return value
    }

    private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
        guard let value = arguments[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func expandedLocalPath(_ value: String) -> String {
        if value == "~" { return MCPClientHostEnvironment.accountHomeDirectory().path }
        if value.hasPrefix("~/") {
            return MCPClientHostEnvironment.accountHomeDirectory()
                .appendingPathComponent(String(value.dropFirst(2))).path
        }
        return (value as NSString).expandingTildeInPath
    }

    private func createParentDirectoryIfNeeded(forLocalPath path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard !parent.path.isEmpty else { return }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func localFileSize(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func boundedTimeout(_ value: Any?, defaultSeconds: TimeInterval) -> TimeInterval {
        min(max(TimeInterval(intValue(value) ?? Int(defaultSeconds)), 1), 1_800)
    }

    private func boundedByteLimit(_ value: Any?, defaultBytes: Int) -> Int {
        min(max(intValue(value) ?? defaultBytes, 1), 16 * 1_024 * 1_024)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let integer = value as? Int { return Int64(integer) }
        if let int64 = value as? Int64 { return int64 }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return nil
    }

    private func truncate(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return (text, false) }
        return (String(decoding: data.prefix(maxBytes), as: UTF8.self), true)
    }

    private func jsonText(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func encodedResponse(id: Any?, result: [String: Any]) -> String {
        encodeJSON(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func encodedError(id: Any?, code: Int, message: String) -> String {
        encodeJSON(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func encodeJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Could not encode response."}}"#
        }
        return String(data: data, encoding: .utf8) ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Could not encode response."}}"#
    }
}
