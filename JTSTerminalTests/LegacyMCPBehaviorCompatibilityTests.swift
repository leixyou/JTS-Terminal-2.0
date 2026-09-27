//
//  LegacyMCPBehaviorCompatibilityTests.swift
//  JTSTerminalTests
//
//  Verifies that the 15-tool JTS Terminal 1.2 MCP surface still dispatches
//  through the same command, transfer, and terminal-bridge paths in 2.0.
//

import Darwin
import Foundation
import SwiftData
import Testing
@testable import JTSTerminal

enum LegacyMCPBehaviorCase: String, CaseIterable, Sendable {
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

    var usesTerminalBridge: Bool {
        switch self {
        case .listOpenTerminals, .openTerminal, .terminalExec, .terminalRead:
            return true
        default:
            return false
        }
    }

    #if ENABLE_RDP_2
    var expectedCapabilities: Set<RemoteCapability> {
        switch self {
        case .listServers, .listOpenTerminals:
            return [.discovery]
        case .exec, .openTerminal, .terminalExec, .terminalRead:
            return [.commandExecution]
        case .listDirectory, .readFile, .downloadFile, .stat:
            return [.fileAccess]
        case .writeFile, .uploadFile, .makeDirectory, .rename, .remove:
            return [.fileAccess, .destructiveOperations]
        }
    }

    var expectedExternalData: Set<RemoteExternalDataType> {
        switch self {
        case .listServers, .listOpenTerminals:
            return [.targetMetadata]
        case .exec:
            return [.commandOutput]
        case .listDirectory, .stat:
            return [.fileMetadata]
        case .readFile, .downloadFile:
            return [.fileContent]
        case .terminalExec, .terminalRead:
            return [.terminalOutput]
        case .writeFile, .uploadFile, .makeDirectory, .rename, .remove, .openTerminal:
            return []
        }
    }

    var isDiscoveryOnly: Bool {
        switch self {
        case .listServers, .listOpenTerminals:
            return true
        default:
            return false
        }
    }
    #endif
}

private struct LegacyMCPRemoteInvocation {
    var remoteCommand: String
    var standardInput: String?
    var timeoutSeconds: TimeInterval?
}

private final class LegacyMCPRemoteRecorder: @unchecked Sendable {
    private let behavior: LegacyMCPBehaviorCase
    private let lock = NSLock()
    private var recordedInvocations: [LegacyMCPRemoteInvocation] = []

    init(behavior: LegacyMCPBehaviorCase) {
        self.behavior = behavior
    }

    var invocations: [LegacyMCPRemoteInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    func makeRunner() -> MCPRemoteCommandRunner {
        MCPRemoteCommandRunner { [self] _, remoteCommand, standardInput, timeoutSeconds in
            lock.withLock {
                recordedInvocations.append(LegacyMCPRemoteInvocation(
                    remoteCommand: remoteCommand,
                    standardInput: standardInput,
                    timeoutSeconds: timeoutSeconds
                ))
            }

            let standardOutput: String
            switch behavior {
            case .exec:
                standardOutput = "legacy-output"
            case .listDirectory:
                standardOutput = #"""
                [
                  {
                    "name": "compat.txt",
                    "kind": "file",
                    "permissions": "-rw-r--r--",
                    "owner": "tester",
                    "group": "staff",
                    "size": 12,
                    "modified": "2026-07-16 12:00:00",
                    "linkTarget": null
                  }
                ]
                """#
            case .readFile:
                standardOutput = #"{"bytes":11,"content":"legacy-read","encoding":"utf8","offset":7,"path":"/compat/read.txt","truncated":false}"#
            case .writeFile:
                standardOutput = #"{"bytes":12,"path":"/compat/write.txt","written":true}"#
            case .stat:
                standardOutput = #"{"kind":"file","path":"/compat/stat.txt","size":42}"#
            default:
                standardOutput = "legacy-shell-ok"
            }

            return CommandResult(
                command: remoteCommand,
                exitCode: 0,
                standardOutput: standardOutput,
                standardError: ""
            )
        }
    }
}

private enum LegacyMCPTransferDirection: String {
    case upload
    case download
}

private struct LegacyMCPTransferInvocation {
    var direction: LegacyMCPTransferDirection
    var localPath: String
    var remotePath: String
    var recursive: Bool
    var resume: Bool
}

private final class LegacyMCPTransferRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInvocations: [LegacyMCPTransferInvocation] = []

    var invocations: [LegacyMCPTransferInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    func makeRunner() -> MCPFileTransferRunner {
        MCPFileTransferRunner(
            upload: { [self] _, localPath, remotePath, recursive, resume in
                record(
                    direction: .upload,
                    localPath: localPath,
                    remotePath: remotePath,
                    recursive: recursive,
                    resume: resume
                )
                return CommandResult(
                    command: "legacy upload",
                    exitCode: 0,
                    standardOutput: "legacy-transfer-ok",
                    standardError: ""
                )
            },
            download: { [self] _, remotePath, localPath, recursive, resume, _ in
                record(
                    direction: .download,
                    localPath: localPath,
                    remotePath: remotePath,
                    recursive: recursive,
                    resume: resume
                )
                return CommandResult(
                    command: "legacy download",
                    exitCode: 0,
                    standardOutput: "legacy-transfer-ok",
                    standardError: ""
                )
            }
        )
    }

    private func record(
        direction: LegacyMCPTransferDirection,
        localPath: String,
        remotePath: String,
        recursive: Bool,
        resume: Bool
    ) {
        lock.lock()
        recordedInvocations.append(LegacyMCPTransferInvocation(
            direction: direction,
            localPath: localPath,
            remotePath: remotePath,
            recursive: recursive,
            resume: resume
        ))
        lock.unlock()
    }
}

private struct LegacyMCPBridgeRequest {
    var method: String
    var params: [String: Any]
}

/// Minimal bridge peer that exercises the production descriptor, Unix socket,
/// request encoding, and response decoding without launching the GUI process.
private final class LegacyMCPFakeBridge: @unchecked Sendable {
    static let terminalID = "legacy-terminal-id"

    let runtimeRoot: URL

    private let alias: String
    private let descriptor: TerminalMCPBridgeDescriptor
    private let queue = DispatchQueue(label: "com.lljts.JTSTerminalTests.legacy-mcp-bridge")
    private let lock = NSLock()
    private var listenFD: Int32
    private var stopped = false
    private var recordedRequests: [LegacyMCPBridgeRequest] = []

    init(runtimeRoot: URL, alias: String) throws {
        self.runtimeRoot = runtimeRoot
        self.alias = alias

        let socketURL = try TerminalMCPBridgeRuntime.socketURL(runtimeRoot: runtimeRoot)
        let listenFD = try TerminalMCPBridgeSocket.listen(path: socketURL.path)
        let descriptor = TerminalMCPBridgeDescriptor(
            socketPath: socketURL.path,
            token: "legacy-mcp-\(UUID().uuidString)",
            appPID: getpid(),
            createdAt: Date()
        )
        try TerminalMCPBridgeRuntime.writeDescriptor(
            descriptor,
            runtimeRoot: runtimeRoot
        )

        self.listenFD = listenFD
        self.descriptor = descriptor
        queue.async { [self] in
            acceptLoop()
        }
    }

    func requests(method: String) -> [LegacyMCPBridgeRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.filter { $0.method == method }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()

        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        queue.sync {}
        TerminalMCPBridgeRuntime.removeRuntimeFiles(
            descriptor: descriptor,
            runtimeRoot: runtimeRoot
        )
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let shouldStop = stopped
            lock.unlock()
            guard !shouldStop, fd >= 0 else { return }

            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        do {
            try TerminalMCPBridgeSocket.suppressSIGPIPE(on: clientFD)
            try TerminalMCPBridgeSocket.setTimeout(milliseconds: 5_000, on: clientFD)
            let request = try TerminalMCPBridgeSocket.readJSONLine(from: clientFD)
            guard request["token"] as? String == descriptor.token else {
                try TerminalMCPBridgeSocket.writeJSONLine([
                    "ok": false,
                    "error": TerminalMCPBridgeError.unauthorized.localizedDescription
                ], to: clientFD)
                return
            }

            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]
            lock.lock()
            recordedRequests.append(LegacyMCPBridgeRequest(method: method, params: params))
            lock.unlock()

            try TerminalMCPBridgeSocket.writeJSONLine(
                response(method: method, params: params),
                to: clientFD
            )
        } catch {
            try? TerminalMCPBridgeSocket.writeJSONLine([
                "ok": false,
                "error": error.localizedDescription
            ], to: clientFD)
        }
    }

    private func response(method: String, params: [String: Any]) -> [String: Any] {
        switch method {
        case "list_open_terminals":
            return [
                "ok": true,
                "result": [
                    "terminals": [[
                        "terminalId": Self.terminalID,
                        "serverAlias": alias,
                        "mcpName": "legacy-compatible-terminal",
                        "connectionType": RemoteConnectionType.localShell.rawValue,
                        "running": true
                    ]]
                ]
            ]
        case "open_terminal":
            return [
                "ok": true,
                "result": [
                    "terminalId": Self.terminalID,
                    "serverAlias": alias,
                    "connectionType": RemoteConnectionType.localShell.rawValue,
                    "didStart": true,
                    "persistentMCPControl": true,
                    "mcpControlAuthorized": true,
                    "running": true
                ]
            ]
        case "terminal_exec":
            let maxBytes = integerValue(params["maxOutputBytes"]) ?? 1_048_576
            let fullOutput = "legacy-terminal-output"
            let outputData = Data(fullOutput.utf8)
            let truncated = outputData.count > maxBytes
            return [
                "ok": true,
                "result": [
                    "terminalId": params["terminalId"] ?? Self.terminalID,
                    "serverAlias": alias,
                    "connectionType": RemoteConnectionType.localShell.rawValue,
                    "exitCode": 0,
                    "stdout": String(decoding: outputData.prefix(maxBytes), as: UTF8.self),
                    "truncated": truncated,
                    "durationMs": 4,
                    "timedOut": false
                ]
            ]
        case "terminal_read":
            let maxBytes = integerValue(params["maxOutputBytes"]) ?? 16_384
            let fullText = "legacy-transcript"
            let textData = Data(fullText.utf8)
            let truncated = textData.count > maxBytes
            return [
                "ok": true,
                "result": [
                    "terminalId": params["terminalId"] ?? Self.terminalID,
                    "serverAlias": alias,
                    "connectionType": RemoteConnectionType.localShell.rawValue,
                    "text": String(decoding: textData.prefix(maxBytes), as: UTF8.self),
                    "truncated": truncated
                ]
            ]
        default:
            return [
                "ok": false,
                "error": "Unsupported test bridge method: \(method)"
            ]
        }
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

private struct LegacyMCPCallResponse {
    let object: [String: Any]

    init(line: String) throws {
        object = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
    }

    var errorMessage: String? {
        (object["error"] as? [String: Any])?["message"] as? String
    }

    func textPayload() throws -> String {
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(result["isError"] as? Bool == false)
        return try #require(content.first?["text"] as? String)
    }
}

@MainActor
private final class LegacyMCPBehaviorHarness {
    static let alias = "legacy-compat"

    let behavior: LegacyMCPBehaviorCase
    let root: URL
    let context: ModelContext
    let session: RemoteSession
    let registration: MCPClientRegistrationRecord
    let uploadURL: URL
    let downloadURL: URL
    let remoteRecorder: LegacyMCPRemoteRecorder
    let transferRecorder: LegacyMCPTransferRecorder
    let bridge: LegacyMCPFakeBridge?

    #if ENABLE_RDP_2
    let grantStore: RemoteClientGrantStore
    #endif

    private let container: ModelContainer
    private let server: MCPStdioServer

    init(behavior: LegacyMCPBehaviorCase) throws {
        self.behavior = behavior

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root

        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        self.container = container
        let context = ModelContext(container)
        self.context = context

        let connectionType: RemoteConnectionType = behavior.usesTerminalBridge
            ? .localShell
            : .ssh
        let session = RemoteSession(
            name: "Legacy Compatibility",
            host: behavior == .listDirectory ? "127.0.0.1" : "compat.example.com",
            username: "tester",
            port: behavior == .listDirectory ? 1 : nil,
            connectionType: connectionType,
            remotePath: "/srv/default"
        )
        session.mcpEnabled = true
        session.mcpAlias = Self.alias
        session.mcpAlwaysAllowTerminalControl = behavior.usesTerminalBridge &&
            behavior != .openTerminal
        context.insert(session)
        try context.save()
        self.session = session

        let registration = MCPClientRegistrationRecord(
            registrationID: "22222222-2222-4222-8222-222222222222",
            configurationKey: root.appendingPathComponent("mcp.json").path,
            clientLabel: "Legacy MCP Compatibility",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        self.registration = registration

        let uploadURL = root.appendingPathComponent("legacy-upload.txt")
        try Data("legacy-upload".utf8).write(to: uploadURL)
        self.uploadURL = uploadURL
        self.downloadURL = root.appendingPathComponent("downloads/nested/legacy-download.txt")

        let remoteRecorder = LegacyMCPRemoteRecorder(behavior: behavior)
        self.remoteRecorder = remoteRecorder
        let transferRecorder = LegacyMCPTransferRecorder()
        self.transferRecorder = transferRecorder

        let bridge: LegacyMCPFakeBridge?
        if behavior.usesTerminalBridge {
            bridge = try LegacyMCPFakeBridge(
                runtimeRoot: root.appendingPathComponent("bridge", isDirectory: true),
                alias: Self.alias
            )
        } else {
            bridge = nil
        }
        self.bridge = bridge
        let terminalBridgeClient = TerminalMCPBridgeClient(
            runtimeRoot: bridge?.runtimeRoot
                ?? root.appendingPathComponent("unused-bridge", isDirectory: true)
        )

        #if ENABLE_RDP_2
        let grantStore = RemoteClientGrantStore(
            storageURL: root.appendingPathComponent("security/grants.json")
        )
        self.grantStore = grantStore
        self.server = MCPStdioServer(
            modelContext: context,
            terminalBridgeClient: terminalBridgeClient,
            guiLauncher: .disabled,
            fileTransferRunner: transferRecorder.makeRunner(),
            remoteRunner: remoteRecorder.makeRunner(),
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )
        #else
        self.server = MCPStdioServer(
            modelContext: context,
            terminalBridgeClient: terminalBridgeClient,
            guiLauncher: .disabled,
            fileTransferRunner: transferRecorder.makeRunner(),
            remoteRunner: remoteRecorder.makeRunner(),
            clientRegistration: registration
        )
        #endif
    }

    func stop() {
        bridge?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func call(requestID: Int) async throws -> LegacyMCPCallResponse {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "tools/call",
            "params": [
                "name": behavior.rawValue,
                "arguments": arguments
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let line = try #require(String(data: data, encoding: .utf8))
        let response = try #require(await server.handleLine(line))
        return try LegacyMCPCallResponse(line: response)
    }

    func enablePersistentTerminalControl() throws {
        session.mcpAlwaysAllowTerminalControl = true
        try context.save()
    }

    func verifyInitialAuthorizationResponse(_ response: LegacyMCPCallResponse) throws {
        switch behavior {
        case .listServers:
            #expect(response.errorMessage == nil)
            let payload = try response.textPayload()
            let servers = try #require(
                JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]]
            )
            #expect(servers.isEmpty)
        case .listOpenTerminals:
            #expect(response.errorMessage == nil)
            let payload = try decodedTextObject(response)
            #expect((payload["terminals"] as? [[String: Any]])?.isEmpty == true)
        default:
            #expect(response.errorMessage?.contains("GRANT_APPROVAL_REQUIRED") == true)
        }

        #expect(remoteRecorder.invocations.isEmpty)
        #expect(transferRecorder.invocations.isEmpty)
        #expect(bridge?.requests(method: "open_terminal").isEmpty ?? true)
        #expect(bridge?.requests(method: "terminal_exec").isEmpty ?? true)
        #expect(bridge?.requests(method: "terminal_read").isEmpty ?? true)
    }

    func verifySuccess(_ response: LegacyMCPCallResponse) throws {
        #expect(response.errorMessage == nil)

        switch behavior {
        case .listServers:
            let payload = try response.textPayload()
            let servers = try #require(
                JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]]
            )
            let server = try #require(servers.first)
            let capabilities = Set(server["capabilities"] as? [String] ?? [])
            #expect(servers.count == 1)
            #expect(server["alias"] as? String == Self.alias)
            #expect(server["connectionType"] as? String == RemoteConnectionType.ssh.rawValue)
            #expect(server["host"] as? String == "compat.example.com")
            #expect(capabilities == [
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
            ])
        case .exec:
            let payload = try decodedTextObject(response)
            let invocation = try onlyRemoteInvocation()
            #expect(payload["exitCode"] as? Int == 0)
            #expect(payload["stdout"] as? String == "legacy")
            #expect(payload["truncated"] as? Bool == true)
            #expect(invocation.remoteCommand == "cd -- '/srv/compat dir' && printf legacy-output")
            #expect(invocation.standardInput == nil)
            #expect(invocation.timeoutSeconds == 9)
        case .listDirectory:
            let payload = try decodedTextObject(response)
            let entries = try #require(payload["entries"] as? [[String: Any]])
            let invocation = try onlyRemoteInvocation()
            #expect(payload["path"] as? String == "/srv/compat dir")
            #expect(payload["transport"] as? String == "ssh")
            #expect(entries.first?["name"] as? String == "compat.txt")
            #expect(invocation.remoteCommand == SSHCommandBuilder.structuredDirectoryListingCommand(
                path: "/srv/compat dir"
            ))
            #expect(invocation.timeoutSeconds == 120)
        case .readFile:
            let payload = try decodedTextObject(response)
            let invocation = try onlyRemoteInvocation()
            #expect(payload["path"] as? String == "/compat/read.txt")
            #expect(payload["content"] as? String == "legacy-read")
            #expect(payload["offset"] as? Int == 7)
            #expect(invocation.remoteCommand == SSHCommandBuilder.readFileCommand(
                path: "/compat/read.txt",
                offset: 7,
                limitBytes: 128,
                encoding: "utf8"
            ))
            #expect(invocation.timeoutSeconds == 120)
        case .writeFile:
            let payload = try decodedTextObject(response)
            let invocation = try onlyRemoteInvocation()
            let content = Data("legacy-write".utf8)
            #expect(payload["written"] as? Bool == true)
            #expect(invocation.remoteCommand == SSHCommandBuilder.writeFileCommand(
                path: "/compat/write.txt",
                createParents: true,
                mode: "0640"
            ))
            #expect(invocation.standardInput == content.base64EncodedString())
            #expect(invocation.timeoutSeconds == 120)
        case .uploadFile:
            let payload = try decodedTextObject(response)
            let invocation = try onlyTransferInvocation()
            #expect(payload["direction"] as? String == LegacyMCPTransferDirection.upload.rawValue)
            #expect(payload["status"] as? String == RemoteTransferStatus.succeeded.rawValue)
            #expect(payload["localPath"] as? String == uploadURL.path)
            #expect(payload["remotePath"] as? String == "/compat/upload.txt")
            #expect(payload["recursive"] as? Bool == false)
            #expect(payload["resume"] as? Bool == false)
            #expect(invocation.direction == .upload)
            #expect(invocation.localPath == uploadURL.path)
            #expect(invocation.remotePath == "/compat/upload.txt")
            #expect(!invocation.recursive)
            #expect(!invocation.resume)
        case .downloadFile:
            let payload = try decodedTextObject(response)
            let invocation = try onlyTransferInvocation()
            #expect(payload["direction"] as? String == LegacyMCPTransferDirection.download.rawValue)
            #expect(payload["status"] as? String == RemoteTransferStatus.succeeded.rawValue)
            #expect(payload["localPath"] as? String == downloadURL.path)
            #expect(payload["remotePath"] as? String == "/compat/download")
            #expect(payload["recursive"] as? Bool == true)
            #expect(payload["resume"] as? Bool == false)
            #expect(payload["expectedBytes"] as? Int == 41)
            #expect(payload["transferredBytes"] is NSNull)
            #expect(FileManager.default.fileExists(
                atPath: downloadURL.deletingLastPathComponent().path
            ))
            #expect(invocation.direction == .download)
            #expect(invocation.localPath == downloadURL.path)
            #expect(invocation.remotePath == "/compat/download")
            #expect(invocation.recursive)
            #expect(!invocation.resume)
        case .stat:
            let payload = try decodedTextObject(response)
            let invocation = try onlyRemoteInvocation()
            #expect(payload["kind"] as? String == "file")
            #expect(payload["size"] as? Int == 42)
            #expect(invocation.remoteCommand == SSHCommandBuilder.statCommand(
                path: "/compat/stat.txt"
            ))
            #expect(invocation.timeoutSeconds == 60)
        case .makeDirectory:
            let payload = try decodedTextObject(response)
            let invocation = try onlyRemoteInvocation()
            #expect(payload["exitCode"] as? Int == 0)
            #expect(payload["stdout"] as? String == "legacy-shell-ok")
            #expect(invocation.remoteCommand == "mkdir -p -- '/compat/new dir'")
            #expect(invocation.timeoutSeconds == 120)
        case .rename:
            let payload = try decodedTextObject(response)
            let invocation = try onlyRemoteInvocation()
            #expect(payload["exitCode"] as? Int == 0)
            #expect(invocation.remoteCommand == "mv -- '/compat/from name' '/compat/to name'")
            #expect(invocation.timeoutSeconds == 120)
        case .remove:
            let payload = try decodedTextObject(response)
            let invocation = try onlyRemoteInvocation()
            #expect(payload["exitCode"] as? Int == 0)
            #expect(invocation.remoteCommand == "rm -rf -- '/compat/remove dir'")
            #expect(invocation.timeoutSeconds == 120)
        case .listOpenTerminals:
            let payload = try decodedTextObject(response)
            let terminals = try #require(payload["terminals"] as? [[String: Any]])
            let request = try #require(bridge?.requests(method: "list_open_terminals").last)
            #expect(terminals.count == 1)
            #expect(terminals.first?["terminalId"] as? String == LegacyMCPFakeBridge.terminalID)
            #expect(terminals.first?["serverAlias"] as? String == Self.alias)
            #expect(request.params["clientId"] as? String == registration.authorizationClientID)
        case .openTerminal:
            let payload = try decodedTextObject(response)
            let request = try #require(bridge?.requests(method: "open_terminal").last)
            #expect(payload["terminalId"] as? String == LegacyMCPFakeBridge.terminalID)
            #expect(payload["serverAlias"] as? String == Self.alias)
            #expect(payload["mcpControlAuthorized"] as? Bool == true)
            #expect(payload["launchedGUI"] as? Bool == false)
            #expect(request.params["server"] as? String == Self.alias)
            #expect(integerValue(request.params["waitSeconds"]) == 3)
            #expect(request.params["clientId"] as? String == registration.authorizationClientID)
        case .terminalExec:
            let payload = try decodedTextObject(response)
            let request = try #require(bridge?.requests(method: "terminal_exec").last)
            #expect(payload["terminalId"] as? String == LegacyMCPFakeBridge.terminalID)
            #expect(payload["stdout"] as? String == "legac")
            #expect(payload["truncated"] as? Bool == true)
            #expect(request.params["terminalId"] as? String == LegacyMCPFakeBridge.terminalID)
            #expect(request.params["command"] as? String == "printf legacy-terminal-output")
            #expect(integerValue(request.params["timeoutSeconds"]) == 7)
            #expect(integerValue(request.params["maxOutputBytes"]) == 5)
            #expect(request.params["clientId"] as? String == registration.authorizationClientID)
        case .terminalRead:
            let payload = try decodedTextObject(response)
            let request = try #require(bridge?.requests(method: "terminal_read").last)
            #expect(payload["terminalId"] as? String == LegacyMCPFakeBridge.terminalID)
            #expect(payload["text"] as? String == "legacy-")
            #expect(payload["truncated"] as? Bool == true)
            #expect(request.params["terminalId"] as? String == LegacyMCPFakeBridge.terminalID)
            #expect(integerValue(request.params["maxOutputBytes"]) == 7)
            #expect(request.params["clientId"] as? String == registration.authorizationClientID)
        }
    }

    private var arguments: [String: Any] {
        switch behavior {
        case .listServers, .listOpenTerminals:
            return [:]
        case .exec:
            return [
                "server": Self.alias,
                "command": "printf legacy-output",
                "cwd": "/srv/compat dir",
                "timeoutSeconds": "9",
                "maxOutputBytes": "6"
            ]
        case .listDirectory:
            return [
                "server": Self.alias,
                "path": "/srv/compat dir"
            ]
        case .readFile:
            return [
                "server": Self.alias,
                "path": "/compat/read.txt",
                "offset": "7",
                "limitBytes": "128",
                "encoding": "utf8"
            ]
        case .writeFile:
            return [
                "server": Self.alias,
                "path": "/compat/write.txt",
                "content": Data("legacy-write".utf8).base64EncodedString(),
                "encoding": "base64",
                "createParents": true,
                "mode": "0640"
            ]
        case .uploadFile:
            return [
                "server": Self.alias,
                "localPath": uploadURL.path,
                "remotePath": "/compat/upload.txt",
                "recursive": false,
                "resume": false
            ]
        case .downloadFile:
            return [
                "server": Self.alias,
                "remotePath": "/compat/download",
                "localPath": downloadURL.path,
                "recursive": true,
                "resume": true,
                "createParents": true,
                "expectedBytes": "41"
            ]
        case .stat:
            return [
                "server": Self.alias,
                "path": "/compat/stat.txt"
            ]
        case .makeDirectory:
            return [
                "server": Self.alias,
                "path": "/compat/new dir",
                "parents": true
            ]
        case .rename:
            return [
                "server": Self.alias,
                "from": "/compat/from name",
                "to": "/compat/to name"
            ]
        case .remove:
            return [
                "server": Self.alias,
                "path": "/compat/remove dir",
                "recursive": true
            ]
        case .openTerminal:
            return [
                "server": Self.alias,
                "waitSeconds": "3",
                "requireMCPControl": true
            ]
        case .terminalExec:
            return [
                "terminalId": LegacyMCPFakeBridge.terminalID,
                "command": "printf legacy-terminal-output",
                "timeoutSeconds": "7",
                "maxOutputBytes": "5"
            ]
        case .terminalRead:
            return [
                "terminalId": LegacyMCPFakeBridge.terminalID,
                "maxOutputBytes": "7"
            ]
        }
    }

    private func decodedTextObject(_ response: LegacyMCPCallResponse) throws -> [String: Any] {
        let text = try response.textPayload()
        return try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    private func onlyRemoteInvocation() throws -> LegacyMCPRemoteInvocation {
        let invocations = remoteRecorder.invocations
        #expect(invocations.count == 1)
        return try #require(invocations.first)
    }

    private func onlyTransferInvocation() throws -> LegacyMCPTransferInvocation {
        let invocations = transferRecorder.invocations
        #expect(invocations.count == 1)
        return try #require(invocations.first)
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

@Suite("JTS Terminal 2.0 MCP backward-compatibility contracts")
struct LegacyMCPBehaviorCompatibilityTests {
    @Test
    func behaviorMatrixCoversEveryLegacyToolExactlyOnce() {
        #expect(LegacyMCPBehaviorCase.allCases.count == 15)
        #expect(
            Set(LegacyMCPBehaviorCase.allCases.map(\.rawValue)) ==
                Set(LegacyMCPToolName.allCases.map(\.rawValue))
        )
    }

    @MainActor
    @Test(arguments: LegacyMCPBehaviorCase.allCases)
    func legacyToolPreservesAuthorizationRoutingAndResultSemantics(
        _ behavior: LegacyMCPBehaviorCase
    ) async throws {
        let harness = try LegacyMCPBehaviorHarness(behavior: behavior)
        defer { harness.stop() }

        if behavior == .openTerminal {
            let controlDenied = try await harness.call(requestID: 101)
            #expect(
                controlDenied.errorMessage?
                    .contains("persistent MCP Control is not enabled") == true
            )
            #expect(harness.bridge?.requests(method: "open_terminal").isEmpty == true)
            try harness.enablePersistentTerminalControl()
        }

        let success = try await harness.call(requestID: 102)
        try harness.verifySuccess(success)

        #if ENABLE_RDP_2
        #expect(
            harness.grantStore.pendingRequests(
                targetID: harness.session.targetID,
                targetBinding: harness.session.mcpGrantTargetBinding
            ).isEmpty
        )
        if behavior.isDiscoveryOnly {
            #expect(
                harness.grantStore.activeGrants(
                    targetID: harness.session.targetID,
                    targetBinding: harness.session.mcpGrantTargetBinding
                ).isEmpty
            )
        } else {
            let grant = try #require(
                harness.grantStore.activeGrants(
                    targetID: harness.session.targetID,
                    targetBinding: harness.session.mcpGrantTargetBinding
                ).first
            )
            #expect(grant.clientID == harness.registration.authorizationClientID)
            #expect(grant.clientDisplayIdentity == harness.registration.displayIdentity)
            #expect(behavior.expectedCapabilities.isSubset(of: grant.capabilities))
        }
        #endif
    }
}
