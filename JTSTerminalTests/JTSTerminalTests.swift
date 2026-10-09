//
//  JTSTerminalTests.swift
//  JTSTerminalTests
//
//  Created by tester on 2026/4/29.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import SwiftData
import Testing
@testable import JTSTerminal

private func testMCPRegistration(
    id: String = "11111111-1111-4111-8111-111111111111"
) -> MCPClientRegistrationRecord {
    MCPClientRegistrationRecord(
        registrationID: id,
        configurationKey: "/tmp/jts-terminal-tests-mcp.json",
        clientLabel: "JTS Tests",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func testSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func installKnownHostsTestACL(
    at url: URL,
    inheritable: Bool = false
) throws {
    let flags = inheritable
        ? "allow,file_inherit,directory_inherit"
        : "allow"
    let permissions = inheritable
        ? "read,execute,readattr,readextattr,readsecurity"
        : "read,readattr,readextattr,readsecurity"
    let text = """
    !#acl 1
    group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(flags):\(permissions)

    """
    guard let acl = text.withCString({ acl_from_text($0) }) else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno == 0 ? EINVAL : errno)
        )
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            errno = EINVAL
            return -1
        }
        return acl_set_link_np(path, ACL_TYPE_EXTENDED, acl)
    }
    guard result == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno == 0 ? EIO : errno)
        )
    }
}

private func testLStat(at url: URL) throws -> stat {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            errno = EINVAL
            return -1
        }
        return lstat(path, &status)
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return status
}

private func expectUnsafeMCPConfigurationTopology(
    at expectedPath: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected MCP registration to reject unsafe configuration topology")
    } catch let error as MCPClientRegistrationError {
        guard case .unsafeConfigurationTopology(let path) = error else {
            Issue.record("Expected unsafeConfigurationTopology, got \(error)")
            return
        }
        #expect(path == expectedPath)
        #expect(error.localizedDescription.contains("exactly one hard link"))
    } catch {
        Issue.record("Expected MCPClientRegistrationError, got \(error)")
    }
}

@MainActor
private func approvedGrantStore(
    for sessions: [RemoteSession],
    registration: MCPClientRegistrationRecord
) throws -> RemoteClientGrantStore {
    #if ENABLE_RDP_2
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jts-approved-grants-\(UUID().uuidString)/grants.json")
    let store = RemoteClientGrantStore(storageURL: url)
    for session in sessions {
        let externalDataTypes: Set<RemoteExternalDataType>
        switch session.connectionType {
        case .ssh:
            externalDataTypes = [
                .targetMetadata,
                .commandOutput,
                .terminalOutput,
                .fileMetadata,
                .fileContent,
            ]
        case .localShell:
            externalDataTypes = [
                .targetMetadata,
                .commandOutput,
                .terminalOutput,
            ]
        case .macDesktop:
            externalDataTypes = []
        case .rdp:
            externalDataTypes = [
                .targetMetadata,
                .desktopImage,
                .commandOutput,
                .fileMetadata,
                .fileContent,
            ]
        }
        do {
            _ = try store.authorize(
                clientID: registration.authorizationClientID,
                targetID: session.targetID,
                targetBinding: session.mcpGrantTargetBinding,
                capabilities: session.mcpPermissionPolicy.maximumCapabilities,
                policy: session.mcpPermissionPolicy,
                externalDataTypes: externalDataTypes
            )
        } catch let failure as RemoteGrantGateFailure {
            let requestID = try #require(failure.pendingRequestID)
            _ = try store.approve(
                requestID: requestID,
                policy: session.mcpPermissionPolicy,
                consentToExternalData: true,
                currentTargetBinding: session.mcpGrantTargetBinding
            )
        }
    }
    return store
    #else
    return RemoteClientGrantStore()
    #endif
}

#if ENABLE_RDP_2
nonisolated private final class LockedNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

@MainActor
private func approveRemoteGrant(
    in store: RemoteClientGrantStore,
    session: RemoteSession,
    registration: MCPClientRegistrationRecord,
    capabilities: Set<RemoteCapability>,
    externalDataTypes: Set<RemoteExternalDataType>,
    consentToExternalData: Bool
) throws {
    do {
        _ = try store.authorize(
            clientID: registration.authorizationClientID,
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding,
            capabilities: capabilities,
            policy: session.mcpPermissionPolicy,
            externalDataTypes: externalDataTypes
        )
    } catch let failure as RemoteGrantGateFailure {
        _ = try store.approve(
            requestID: try #require(failure.pendingRequestID),
            policy: session.mcpPermissionPolicy,
            consentToExternalData: consentToExternalData,
            currentTargetBinding: session.mcpGrantTargetBinding
        )
    }
}
#endif

private let legacy12MCPToolDefinitionsJSON = #"""
[
  {
    "name": "jts_list_servers",
    "description": "List JTS Terminal connection profiles explicitly enabled for MCP access. SSH profiles expose remote file tools; Local Shell profiles expose terminal-control tools only.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  },
  {
    "name": "jts_exec",
    "description": "Run a shell command on an MCP-enabled SSH server.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "command": {"type": "string", "description": "Remote shell command"},
        "cwd": {"type": "string", "description": "Optional remote working directory"},
        "timeoutSeconds": {"type": "number", "description": "Optional timeout in seconds"},
        "maxOutputBytes": {"type": "number", "description": "Optional stdout/stderr byte limit"}
      },
      "required": ["server", "command"]
    }
  },
  {
    "name": "jts_list_dir",
    "description": "List a remote directory.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "path": {"type": "string", "description": "Remote path"}
      },
      "required": ["server"]
    }
  },
  {
    "name": "jts_read_file",
    "description": "Read a remote file.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "path": {"type": "string", "description": "Remote path"},
        "offset": {"type": "number", "description": "Byte offset"},
        "limitBytes": {"type": "number", "description": "Maximum bytes"},
        "encoding": {"type": "string", "description": "utf8 or base64"}
      },
      "required": ["server", "path"]
    }
  },
  {
    "name": "jts_write_file",
    "description": "Write a remote file atomically.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "path": {"type": "string", "description": "Remote path"},
        "content": {"type": "string", "description": "Content"},
        "encoding": {"type": "string", "description": "utf8 or base64"},
        "createParents": {"type": "boolean", "description": "Create parent directories"},
        "mode": {"type": "string", "description": "Optional chmod mode"}
      },
      "required": ["server", "path", "content"]
    }
  },
  {
    "name": "jts_upload_file",
    "description": "Upload a local file or directory to an MCP-enabled SSH server using the same SFTP transfer path as the Files workspace.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "localPath": {"type": "string", "description": "Local source file or directory path. ~/Downloads, ~/Pictures, ~/Music and ~/Movies are available by default; other folders may require access in JTS Terminal."},
        "remotePath": {"type": "string", "description": "Remote destination path"},
        "recursive": {"type": "boolean", "description": "Set true to upload a directory recursively"},
        "resume": {"type": "boolean", "description": "Resume a partial single-file upload when supported"}
      },
      "required": ["server", "localPath", "remotePath"]
    }
  },
  {
    "name": "jts_download_file",
    "description": "Download a remote file or directory from an MCP-enabled SSH server using the same SFTP transfer path as the Files workspace.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "remotePath": {"type": "string", "description": "Remote source file or directory path"},
        "localPath": {"type": "string", "description": "Local destination path. Use ~/Downloads for a destination available by default; ~/Pictures, ~/Music and ~/Movies are also supported without a folder grant."},
        "recursive": {"type": "boolean", "description": "Set true to download a directory recursively"},
        "resume": {"type": "boolean", "description": "Resume a partial single-file download when supported"},
        "createParents": {"type": "boolean", "description": "Create missing local parent directories before downloading"},
        "expectedBytes": {"type": "number", "description": "Optional expected byte count for progress history"}
      },
      "required": ["server", "remotePath", "localPath"]
    }
  },
  {
    "name": "jts_stat",
    "description": "Stat a remote path.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "path": {"type": "string", "description": "Remote path"}
      },
      "required": ["server", "path"]
    }
  },
  {
    "name": "jts_mkdir",
    "description": "Create a remote directory.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "path": {"type": "string", "description": "Remote path"},
        "parents": {"type": "boolean", "description": "Create parent directories"}
      },
      "required": ["server", "path"]
    }
  },
  {
    "name": "jts_rename",
    "description": "Rename or move a remote path.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "from": {"type": "string", "description": "Source path"},
        "to": {"type": "string", "description": "Destination path"}
      },
      "required": ["server", "from", "to"]
    }
  },
  {
    "name": "jts_remove",
    "description": "Remove a remote file or directory.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "path": {"type": "string", "description": "Remote path"},
        "recursive": {"type": "boolean", "description": "Recursive delete"}
      },
      "required": ["server", "path"]
    }
  },
  {
    "name": "jts_list_open_terminals",
    "description": "List running JTS Terminal SSH or Local Shell sessions explicitly authorized for MCP terminal control. Use mcpName, connectionType, and terminalId to choose the intended terminal; a Local Shell that the user already switched to root will execute commands as root.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  },
  {
    "name": "jts_open_terminal",
    "description": "Launch JTS Terminal GUI if needed, then open and start the interactive terminal for an MCP-enabled SSH or Local Shell profile.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "server": {"type": "string", "description": "MCP server alias"},
        "waitSeconds": {"type": "number", "description": "Optional seconds to wait for the GUI bridge and terminal process startup"},
        "requireMCPControl": {"type": "boolean", "description": "Require persistent MCP Control so the opened pane can be used by jts_terminal_exec"}
      },
      "required": ["server"]
    }
  },
  {
    "name": "jts_terminal_exec",
    "description": "Run a queued shell command inside an authorized open JTS Terminal session, preserving that terminal's current shell identity.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "terminalId": {"type": "string", "description": "Authorized terminal ID from jts_list_open_terminals. Choose it by matching the desired mcpName."},
        "command": {"type": "string", "description": "Shell command to run in the open terminal"},
        "timeoutSeconds": {"type": "number", "description": "Optional timeout in seconds"},
        "maxOutputBytes": {"type": "number", "description": "Optional stdout byte limit"}
      },
      "required": ["terminalId", "command"]
    }
  },
  {
    "name": "jts_terminal_read",
    "description": "Read recent transcript text from an authorized open JTS Terminal session without sending input.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "terminalId": {"type": "string", "description": "Authorized terminal ID from jts_list_open_terminals. Choose it by matching the desired mcpName."},
        "maxOutputBytes": {"type": "number", "description": "Optional transcript byte limit"}
      },
      "required": ["terminalId"]
    }
  }
]
"""#

private func canonicalJSON(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
}

@MainActor
private func waitForStructuredCommandActivity(
    in process: InteractiveProcessSession,
    timeout: Duration = .seconds(30),
    matching predicate: (InteractiveProcessSession.StructuredCommandActivity) -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !predicate(process.structuredCommandActivity) {
        guard clock.now < deadline, !Task.isCancelled else {
            return false
        }
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            return false
        }
    }
    return true
}

// PTY and AppKit fixtures share host resources. Keep member tests sequential;
// concurrency within each lifecycle/broadcast test remains exercised.
@Suite(.serialized)
struct JTSTerminalTests {

    @Test func modelContainerFactoryBuildsCompleteInMemorySchema() async throws {
        try await MainActor.run {
            let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
            let context = ModelContext(container)
            let session = RemoteSession(name: "Prod", host: "api.example.com", username: "deploy", folder: "Production")
            let tunnel = SavedSSHTunnel(
                session: session,
                configuration: SSHTunnelConfiguration(
                    name: "Postgres",
                    kind: .local,
                    localPort: 15432,
                    destinationHost: "db.internal",
                    destinationPort: 5432
                )
            )
            let history = CommandHistoryEntry(session: session, command: "uptime", exitCode: 0)
            let macro = SavedCommandMacro(session: session, name: "Health", command: "uptime && df -h")
            let transfer = RemoteTransferTask(
                session: session,
                direction: .download,
                remotePath: "/srv/app.log",
                localPath: "/tmp/app.log"
            )
            let audit = MCPAuditEntry(
                toolName: "jts_exec",
                serverAlias: "prod",
                operationSummary: "uptime",
                exitCode: 0,
                outputTruncated: false,
                startedAt: Date(),
                finishedAt: Date()
            )

            context.insert(session)
            context.insert(tunnel)
            context.insert(history)
            context.insert(macro)
            context.insert(transfer)
            context.insert(audit)

            try context.save()
        }
    }

    @MainActor
    @Test func mcpAuditPolicyUsesCategoriesAndPurgesAfterThirtyDays() throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_784_096_400)
        context.insert(MCPAuditEntry(
            clientID: "codex@2.0",
            toolName: "jts_exec",
            serverAlias: "prod",
            operationSummary: MCPAuditRecordPolicy.actionCategory(for: "jts_exec"),
            exitCode: 0,
            outputTruncated: false,
            startedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            finishedAt: now.addingTimeInterval(-31 * 24 * 60 * 60)
        ))
        context.insert(MCPAuditEntry(
            clientID: "claude@1.0",
            toolName: "jts_download_file",
            serverAlias: "prod",
            operationSummary: MCPAuditRecordPolicy.actionCategory(for: "jts_download_file"),
            exitCode: 0,
            outputTruncated: false,
            startedAt: now,
            finishedAt: now
        ))
        try context.save()

        MCPAuditRecordPolicy.purgeExpired(in: context, now: now)
        try context.save()
        let records = try context.fetch(FetchDescriptor<MCPAuditEntry>())

        #expect(records.count == 1)
        #expect(records.first?.clientID == "claude@1.0")
        #expect(records.first?.operationSummary == "transfer")
        #expect(!records.first!.operationSummary.contains("/"))
    }

    @MainActor
    @Test func persistentStoreURLUsesStableJTSTerminalStoreName() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let storeURL = try ModelContainerFactory.persistentStoreURL(
            applicationSupportDirectory: temporaryDirectory
        )

        #expect(storeURL.deletingLastPathComponent() == temporaryDirectory)
        #expect(storeURL.lastPathComponent == "JTS Terminal.store")
        #expect(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    @MainActor
    @Test func persistentStoreQuarantineMovesSQLiteSidecarFilesIntoBackup() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let storeURL = temporaryDirectory.appendingPathComponent("JTS Terminal.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")

        try "store".write(to: storeURL, atomically: true, encoding: .utf8)
        try "wal".write(to: walURL, atomically: true, encoding: .utf8)
        try "shm".write(to: shmURL, atomically: true, encoding: .utf8)

        let backupURL = try #require(try ModelContainerFactory.quarantinePersistentStoreFiles(
            storeURL: storeURL,
            now: Date(timeIntervalSince1970: 0)
        ))

        #expect(backupURL.deletingLastPathComponent().lastPathComponent == "19700101-000000")
        #expect(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("JTS Terminal.store").path))
        #expect(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("JTS Terminal.store-wal").path))
        #expect(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("JTS Terminal.store-shm").path))
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: shmURL.path))
    }

    @Test func sshArgumentsIncludeSessionConnectionSettings() async throws {
        let session = RemoteSession(
            name: "Production",
            host: "example.com",
            username: "deploy",
            port: 2222,
            identityFile: "~/.ssh/id_ed25519",
            jumpHost: "bastion.example.com"
        )

        let arguments = SSHCommandBuilder.sshArguments(for: session, remoteCommand: "uptime")
        let terminalCommand = SSHCommandBuilder.terminalSSHCommand(for: session)

        #expect(arguments.contains("-p"))
        #expect(arguments.contains("2222"))
        #expect(arguments.contains("-i"))
        #expect(arguments.contains("\(NSHomeDirectory())/.ssh/id_ed25519"))
        #expect(arguments.contains("-J"))
        #expect(arguments.contains("bastion.example.com"))
        #expect(arguments.contains("deploy@example.com"))
        #expect(arguments.last == "uptime")
        #expect(!arguments.contains("RequestTTY=force"))
        expectManagedHostKeyOptions(in: arguments)
        #expect(terminalCommand.contains("'-i' '\(NSHomeDirectory())/.ssh/id_ed25519'"))
        #expect(terminalCommand.contains("'-J' 'bastion.example.com'"))
        #expect(terminalCommand.contains("UserKnownHostsFile="))
    }

    @Test func terminalCommandDisablesBatchModeForInteractiveSessions() async throws {
        let session = RemoteSession(host: "10.0.0.7", username: "root", port: 22)

        let command = SSHCommandBuilder.terminalSSHCommand(for: session)

        #expect(command.contains("/usr/bin/ssh"))
        #expect(command.contains("'root@10.0.0.7'"))
        #expect(command.contains("UserKnownHostsFile="))
        #expect(command.contains("BatchMode=no"))
        #expect(!command.contains("BatchMode=yes"))
        #expect(command.contains("RequestTTY=force"))
    }

    @Test func sshIdentityNormalizesEndpointWhitespaceForVaultAndCommands() async throws {
        let session = RemoteSession(
            host: "\n  example.com\t ",
            username: "  deploy\r\n",
            port: 2222
        )

        let identity = SSHConnectionIdentity(username: session.username, host: session.host)
        let arguments = SSHCommandBuilder.sshArguments(for: session)

        #expect(identity.username == "deploy")
        #expect(identity.host == "example.com")
        #expect(identity.destination == "deploy@example.com")
        #expect(identity.credentialAccount(port: session.port) == "deploy@example.com:2222")
        #expect(
            CredentialStore.account(
                username: session.username,
                host: session.host,
                port: session.port
            ) == "deploy@example.com:2222"
        )
        #expect(CredentialStore.account(for: session) == "deploy@example.com:2222")
        #expect(arguments.last == "deploy@example.com")
    }

    @Test func remoteCommandBuildersTerminateOptionsAndRejectCraftedDestinations() async throws {
        let crafted = RemoteSession(
            host: "-oProxyCommand=/tmp/untrusted-command",
            username: "deploy",
            port: 22
        )
        let valid = RemoteSession(host: "example.com", username: "deploy", port: 22)

        #expect(!crafted.isConnectable)
        #expect(!SSHConnectionIdentity(
            username: "-oProxyCommand=/tmp/untrusted-command",
            host: "example.com"
        ).isValidForSSHCommand)
        #expect(!SSHConnectionIdentity(
            username: "deploy",
            host: "example.com\n-oProxyCommand=/tmp/untrusted-command"
        ).isValidForSSHCommand)

        let ssh = SSHCommandBuilder.sshArguments(for: crafted, remoteCommand: "hostname")
        #expect(ssh.suffix(3).elementsEqual(["--", "invalid@invalid.invalid", "hostname"]))
        #expect(!ssh.contains("deploy@-oProxyCommand=/tmp/untrusted-command"))

        let scpUpload = SSHCommandBuilder.scpUploadArguments(
            for: valid,
            localPath: "-crafted-local-path",
            remotePath: "/srv/file"
        )
        let uploadTerminator = try #require(scpUpload.firstIndex(of: "--"))
        #expect(scpUpload[scpUpload.index(after: uploadTerminator)] == "-crafted-local-path")

        let scpDownload = SSHCommandBuilder.scpDownloadArguments(
            for: valid,
            remotePath: "-crafted-remote-path",
            localPath: "/tmp/file"
        )
        let downloadTerminator = try #require(scpDownload.firstIndex(of: "--"))
        #expect(scpDownload[scpDownload.index(after: downloadTerminator)].hasPrefix("deploy@example.com:"))

        let sftp = SSHCommandBuilder.sftpBatchArguments(for: valid)
        #expect(sftp.suffix(2).elementsEqual(["--", "deploy@example.com"]))
    }

    @Test func managedKnownHostsFileUsesAppSupportStoreWithPrivatePermissions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-known-hosts-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let sshDirectory = root
            .appendingPathComponent(SSHCommandBuilder.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("SSH", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sshDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let legacyKnownHosts = sshDirectory.appendingPathComponent("known_hosts")
        #expect(FileManager.default.createFile(
            atPath: legacyKnownHosts.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o644]
        ))
        try installKnownHostsTestACL(at: sshDirectory, inheritable: true)
        try installKnownHostsTestACL(at: legacyKnownHosts)

        let path = SSHCommandBuilder.managedKnownHostsFilePath(applicationSupportDirectory: root)
        let expectedURL = sshDirectory.appendingPathComponent("known_hosts")

        #expect(path == expectedURL.path)
        #expect(FileManager.default.fileExists(atPath: path))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: sshDirectory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try PrivateFileSecurity.verifyPrivateDirectory(at: sshDirectory)
        try PrivateFileSecurity.verifyPrivateFile(at: expectedURL)
    }

    @Test func userKnownHostsFileOptionQuotesPathsForOpenSSHConfigParsing() {
        let path = "/private/tmp/JTS \"Terminal\" SSH/known_hosts"

        #expect(
            SSHCommandBuilder.userKnownHostsFileOption(path)
                == #"UserKnownHostsFile="/private/tmp/JTS \"Terminal\" SSH/known_hosts""#
        )
    }

    @Test func managedKnownHostsMigratesLegacyUnquotedPathFragmentWhenEmpty() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jts-known-hosts-migration-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let legacyFragment = root.appendingPathComponent("JTS")
        let trustedKey = "legacy.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILegacyTrustedKey\n"
        #expect(fileManager.createFile(
            atPath: legacyFragment.path,
            contents: Data(trustedKey.utf8),
            attributes: [.posixPermissions: 0o644]
        ))

        let path = SSHCommandBuilder.managedKnownHostsFilePath(
            applicationSupportDirectory: root,
            fileManager: fileManager
        )
        let migrated = try String(contentsOfFile: path, encoding: .utf8)

        #expect(migrated == trustedKey)
        let legacyAttributes = try fileManager.attributesOfItem(atPath: legacyFragment.path)
        #expect((legacyAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func managedKnownHostsRejectsSymlinkAndFailsHostCheckingClosed() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jts-known-hosts-link-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
        }
        let sshDirectory = root
            .appendingPathComponent(SSHCommandBuilder.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("SSH", isDirectory: true)
        try fileManager.createDirectory(
            at: sshDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = root.appendingPathComponent("outside-known-hosts")
        #expect(fileManager.createFile(
            atPath: target.path,
            contents: Data("unchanged".utf8),
            attributes: [.posixPermissions: 0o644]
        ))
        let link = sshDirectory.appendingPathComponent("known_hosts")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let options = SSHCommandBuilder.hostKeyVerificationOptions(
            applicationSupportDirectory: root,
            fileManager: fileManager
        )

        #expect(options.contains("UserKnownHostsFile=/dev/null"))
        #expect(options.contains("StrictHostKeyChecking=yes"))
        #expect(!options.contains("StrictHostKeyChecking=accept-new"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
        let targetAttributes = try fileManager.attributesOfItem(atPath: target.path)
        #expect((targetAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        var linkStatus = stat()
        #expect(Darwin.lstat(link.path, &linkStatus) == 0)
        #expect(linkStatus.st_mode & S_IFMT == S_IFLNK)
    }

    @Test func managedKnownHostsRejectsWrongDirectoryAndFileKinds() throws {
        let fileManager = FileManager.default
        let fileBackedRoot = fileManager.temporaryDirectory
            .appendingPathComponent("jts-known-hosts-file-dir-\(UUID().uuidString)", isDirectory: true)
        let directoryBackedRoot = fileManager.temporaryDirectory
            .appendingPathComponent("jts-known-hosts-dir-file-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fileBackedRoot)
            try? fileManager.removeItem(at: directoryBackedRoot)
        }

        let fileBackedSupport = fileBackedRoot.appendingPathComponent(
            SSHCommandBuilder.applicationSupportFolderName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: fileBackedSupport,
            withIntermediateDirectories: true
        )
        #expect(fileManager.createFile(
            atPath: fileBackedSupport.appendingPathComponent("SSH").path,
            contents: Data()
        ))
        #expect(
            SSHCommandBuilder.managedKnownHostsFilePath(
                applicationSupportDirectory: fileBackedRoot,
                fileManager: fileManager
            ) == "/dev/null"
        )

        let directoryBackedSSH = directoryBackedRoot
            .appendingPathComponent(SSHCommandBuilder.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("SSH", isDirectory: true)
        try fileManager.createDirectory(
            at: directoryBackedSSH.appendingPathComponent("known_hosts", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(
            SSHCommandBuilder.managedKnownHostsFilePath(
                applicationSupportDirectory: directoryBackedRoot,
                fileManager: fileManager
            ) == "/dev/null"
        )
    }

    @Test func processExecutorReturnsTimeoutResultOnce() async throws {
        let executor = ProcessExecutor()

        let result = try await executor.run(
            executable: "/bin/sh",
            arguments: ["-lc", "printf started; /bin/sleep 10"],
            timeoutSeconds: 2
        )

        #expect(result.exitCode == 124)
        #expect(result.standardOutput.contains("started"))
        #expect(result.standardError.contains("Process timed out."))
    }

    @Test nonisolated func processExecutorTimeoutReturnsWithoutWaitingForDescendantPipeEOF() async throws {
        let executor = ProcessExecutor()
        let readyMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-process-timeout-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyMarker) }

        let operation = Task {
            try await executor.run(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "/usr/bin/touch \"$1\"; trap '' TERM; printf 'parent-pid=%s\\n' \"$$\"; /bin/sh -c 'trap \"\" TERM; printf child-stderr >&2; while :; do /bin/sleep 30; done' & child=$!; printf 'child-pid=%s\\n' \"$child\"; wait \"$child\"",
                    "jts-process-timeout-fixture",
                    readyMarker.path,
                ],
                timeoutSeconds: 0.5
            )
        }

        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < readyDeadline,
              !FileManager.default.fileExists(atPath: readyMarker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: readyMarker.path))

        // Measure only after the real child is running. Full-suite scheduling
        // contention before process launch must not be mistaken for waiting on
        // a descendant that still owns stdout/stderr after the timeout fires.
        let childWasReady = ContinuousClock.now
        let result = try await operation.value

        #expect(childWasReady.duration(to: .now) < .seconds(5))
        #expect(result.exitCode == 124)
        #expect(result.standardError.contains("child-stderr"))
        #expect(result.standardError.contains("Process timed out."))

        let outputLines = result.standardOutput.split(whereSeparator: \Character.isNewline)
        let parentPID = outputLines
            .first { $0.hasPrefix("parent-pid=") }
            .flatMap { Int32($0.dropFirst("parent-pid=".count)) }
        let childPID = outputLines
            .first { $0.hasPrefix("child-pid=") }
            .flatMap { Int32($0.dropFirst("child-pid=".count)) }
        let launchedParentPID = try #require(parentPID)
        let launchedChildPID = try #require(childPID)
        let cleanupDeadline = Date().addingTimeInterval(2)
        while Date() < cleanupDeadline,
              Darwin.kill(launchedParentPID, 0) == 0 || Darwin.kill(launchedChildPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(Darwin.kill(launchedParentPID, 0) == -1 && errno == ESRCH)
        #expect(Darwin.kill(launchedChildPID, 0) == -1 && errno == ESRCH)
    }

    @Test nonisolated func processExecutorBoundsVerboseOutputWithoutBlockingChild() async throws {
        let maximumBytes = 32 * 1_024
        let executor = ProcessExecutor(maximumOutputBytesPerStream: maximumBytes)

        let result = try await executor.run(
            executable: "/bin/dd",
            arguments: ["if=/dev/zero", "bs=1024", "count=128"]
        )

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("[output truncated after \(maximumBytes) bytes"))
        #expect(result.standardOutput.utf8.count < maximumBytes + 256)
        #expect(!result.standardError.contains("[output truncated"))

        let exact = try await executor.run(
            executable: "/usr/bin/printf",
            arguments: ["small-output"]
        )
        #expect(exact.standardOutput == "small-output")
        #expect(exact.standardError.isEmpty)
    }

    @Test func shutdownReportSummarizesRunningRemoteProcesses() async throws {
        let report = RemoteProcessShutdownReport(
            terminals: ["Terminal tab 1: SSH pid 1234"],
            tunnels: ["Postgres Tunnel on 127.0.0.1:5432 pid 4321"]
        )

        #expect(!report.isEmpty)
        #expect(report.messageText(for: .app).contains("quitting JTS Terminal"))
        #expect(report.informativeText.contains("SSH / Terminal:"))
        #expect(report.informativeText.contains("Tunnels:"))
        #expect(report.informativeText.contains("Cancel"))
    }

    @Test func shutdownReportTreatsNoProcessesAsEmpty() async throws {
        let report = RemoteProcessShutdownReport(terminals: [], tunnels: [])

        #expect(report.isEmpty)
    }

    @Test func sessionSelectionPrefersConnectableProfileOverDraft() async throws {
        let draft = RemoteSession(name: "New Server")
        let androidRuntime = RemoteSession(
            name: "androidRuntime",
            host: "47.116.66.3",
            username: "root"
        )

        let selected = SessionSelectionPolicy.defaultSession(from: [draft, androidRuntime])

        #expect(selected?.name == "androidRuntime")
    }

    @Test func sessionSelectionFallsBackToDraftWhenNoConnectableProfilesExist() async throws {
        let draft = RemoteSession(name: "New Server")

        let selected = SessionSelectionPolicy.defaultSession(from: [draft])

        #expect(selected?.name == "New Server")
    }

    @Test func sessionSelectionDoesNotSelectDetachedDraft() async throws {
        let draft = RemoteSession(name: "New Server")

        let selected = SessionSelectionPolicy.defaultSession(
            from: [draft],
            excluding: draft.persistentModelID
        )

        #expect(selected == nil)
    }

    @Test func sessionSelectionReplacesSelectedDraftWhenConnectableProfileExists() async throws {
        let draft = RemoteSession(name: "New Server")
        let androidRuntime = RemoteSession(
            name: "androidRuntime",
            host: "47.116.66.3",
            username: "root"
        )

        let selected = SessionSelectionPolicy.usableMainSession(
            current: draft,
            sessions: [draft, androidRuntime]
        )

        #expect(selected?.name == "androidRuntime")
    }

    @Test func sessionSelectionKeepsConnectableProfileWhenDetachedDraftExists() async throws {
        let draft = RemoteSession(name: "New Server")
        let androidRuntime = RemoteSession(
            name: "androidRuntime",
            host: "47.116.66.3",
            username: "root"
        )

        let selected = SessionSelectionPolicy.usableMainSession(
            current: androidRuntime,
            sessions: [draft, androidRuntime],
            excluding: draft.persistentModelID
        )

        #expect(selected?.name == "androidRuntime")
    }

    @Test func serverPropertiesCancelDiscardsOnlyTransientUnconfiguredNewServer() async throws {
        let transientDraft = RemoteSession(name: "New Server")
        let savedServer = RemoteSession(
            name: "Saved Server",
            host: "example.com",
            username: "ubuntu"
        )
        let existingDraft = RemoteSession(name: "Existing Draft")

        #expect(ServerPropertiesCancellationPolicy.shouldDiscardTransientNewSession(
            transientDraft,
            transientNewSessionID: transientDraft.persistentModelID
        ))
        #expect(!ServerPropertiesCancellationPolicy.shouldDiscardTransientNewSession(
            savedServer,
            transientNewSessionID: savedServer.persistentModelID
        ))
        #expect(!ServerPropertiesCancellationPolicy.shouldDiscardTransientNewSession(
            existingDraft,
            transientNewSessionID: transientDraft.persistentModelID
        ))
    }

    @Test func serverPropertiesWindowCannotCloseDuringCredentialWork() {
        #expect(
            ServerPropertiesWindowClosePolicy.canClose(
                credentialOperationIsRunning: false
            )
        )
        #expect(
            !ServerPropertiesWindowClosePolicy.canClose(
                credentialOperationIsRunning: true
            )
        )
    }

    @Test func propertiesEditingDraftMovesMainSelectionToConnectableProfile() async throws {
        let draft = RemoteSession(name: "New Server")
        let androidRuntime = RemoteSession(
            name: "androidRuntime",
            host: "47.116.66.3",
            username: "root"
        )

        let selected = SessionSelectionPolicy.mainSessionWhileEditingProperties(
            current: draft,
            editing: draft,
            sessions: [draft, androidRuntime]
        )

        #expect(selected?.name == "androidRuntime")
    }

    @Test func propertiesEditingDraftPreservesExistingConnectableMainSelection() async throws {
        let draft = RemoteSession(name: "New Server")
        let androidRuntime = RemoteSession(
            name: "androidRuntime",
            host: "47.116.66.3",
            username: "root"
        )

        let selected = SessionSelectionPolicy.mainSessionWhileEditingProperties(
            current: androidRuntime,
            editing: draft,
            sessions: [draft, androidRuntime]
        )

        #expect(selected?.name == "androidRuntime")
    }

    @Test func identityFilePickerDefaultsToSSHDirectoryWhenPathIsBlank() async throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sshDirectory = temporaryHome.appendingPathComponent(".ssh", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryHome)
        }
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)

        let defaultDirectory = SSHIdentityFileSelectionPolicy.defaultDirectoryURL(
            currentPath: "",
            homeDirectory: temporaryHome
        )

        #expect(defaultDirectory == sshDirectory)
    }

    @Test func identityFilePickerCollapsesSelectedHomePathForDisplay() async throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sshDirectory = temporaryHome.appendingPathComponent(".ssh", isDirectory: true)
        let keyURL = sshDirectory.appendingPathComponent("id_ed25519")
        defer {
            try? FileManager.default.removeItem(at: temporaryHome)
        }
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)

        let displayPath = SSHIdentityFileSelectionPolicy.displayPath(
            for: keyURL,
            homeDirectory: temporaryHome
        )

        #expect(displayPath == "~/.ssh/id_ed25519")
    }

    @Test func passwordSSHArgumentsProveSavedPasswordWithoutKeyOrProxyFallback() async throws {
        let session = RemoteSession(
            host: "example.com",
            username: "deploy",
            port: 2222,
            identityFile: "~/.ssh/deploy",
            jumpHost: "bastion.example.com"
        )

        let arguments = SSHCommandBuilder.passwordSSHArguments(for: session, remoteCommand: "hostname")

        #expect(arguments.contains("-p"))
        #expect(arguments.contains("2222"))
        #expect(!arguments.contains("-i"))
        #expect(!arguments.contains("\(NSHomeDirectory())/.ssh/deploy"))
        #expect(!arguments.contains("-J"))
        #expect(!arguments.contains("bastion.example.com"))
        #expect(arguments.contains("-o"))
        #expect(arguments.contains("PasswordAuthentication=yes"))
        #expect(arguments.contains("KbdInteractiveAuthentication=yes"))
        #expect(arguments.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(!arguments.contains("RequestTTY=force"))
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("IdentityAgent=none"))
        #expect(arguments.contains("IdentityFile=none"))
        #expect(arguments.contains("CertificateFile=none"))
        #expect(arguments.contains("ProxyJump=none"))
        #expect(arguments.contains("ProxyCommand=none"))
        #expect(arguments.prefix(2).elementsEqual(["-F", "/dev/null"]))
        #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
        expectManagedHostKeyOptions(in: arguments)
        #expect(arguments.contains("BatchMode=no"))
        #expect(!arguments.contains("BatchMode=yes"))
        #expect(!arguments.contains("-b"))
        #expect(arguments[arguments.count - 3] == "--")
        #expect(arguments.contains("deploy@example.com"))
    }

    @Test func savedPasswordInteractiveSSHArgumentsOverrideDisablingUserConfig() async throws {
        let session = RemoteSession(
            host: "  example.com\n",
            username: "\tdeploy ",
            port: 2222,
            identityFile: "~/.ssh/deploy"
        )

        let arguments = SSHCommandBuilder.savedPasswordInteractiveSSHArguments(for: session)

        #expect(arguments.contains("BatchMode=no"))
        #expect(!arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("PasswordAuthentication=yes"))
        #expect(arguments.contains("KbdInteractiveAuthentication=yes"))
        #expect(arguments.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(arguments.contains("RequestTTY=force"))
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("ProxyJump=none"))
        #expect(arguments.contains("ProxyCommand=none"))
        #expect(arguments.prefix(2).elementsEqual(["-F", "/dev/null"]))
        #expect(!arguments.contains("-i"))
        #expect(arguments.last == "deploy@example.com")
    }

    @Test func sshTransferTargetsUseTheSameNormalizedIdentityAsTheVault() async throws {
        let session = RemoteSession(
            host: " files.example.com ",
            username: " deploy\n",
            port: 2200
        )

        let upload = SSHCommandBuilder.scpUploadArguments(
            for: session,
            localPath: "/tmp/local",
            remotePath: "/srv/remote"
        )
        let download = SSHCommandBuilder.scpDownloadArguments(
            for: session,
            remotePath: "/srv/remote",
            localPath: "/tmp/local"
        )
        let sftp = SSHCommandBuilder.sftpBatchArguments(for: session)

        #expect(CredentialStore.account(for: session) == "deploy@files.example.com:2200")
        #expect(upload.contains("deploy@files.example.com:'/srv/remote'"))
        #expect(download.contains("deploy@files.example.com:'/srv/remote'"))
        #expect(sftp.last == "deploy@files.example.com")
        #expect(!upload.contains("RequestTTY=force"))
        #expect(!download.contains("RequestTTY=force"))
        #expect(!sftp.contains("RequestTTY=force"))
    }

    @Test func appReviewPasswordSmokeArgumentsCannotFallBackToKeysOrSavedRouting() async throws {
        let session = RemoteSession(
            host: "review.example.com",
            username: "appreview",
            port: 2222,
            identityFile: "~/.ssh/deploy",
            jumpHost: "bastion.example.com",
            enableX11Forwarding: true
        )

        let arguments = SSHCommandBuilder.appReviewPasswordSmokeArguments(
            for: session,
            knownHostsFilePath: "/private/temporary/known_hosts"
        )

        #expect(arguments.contains("-F"))
        #expect(arguments.contains("/dev/null"))
        #expect(arguments.contains("UserKnownHostsFile=\"/private/temporary/known_hosts\""))
        #expect(arguments.contains("GlobalKnownHostsFile=/dev/null"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("UpdateHostKeys=no"))
        #expect(!arguments.contains("StrictHostKeyChecking=accept-new"))
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.contains("IdentityAgent=none"))
        #expect(arguments.contains("IdentityFile=none"))
        #expect(arguments.contains("CertificateFile=none"))
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("PasswordAuthentication=yes"))
        #expect(arguments.contains("KbdInteractiveAuthentication=yes"))
        #expect(arguments.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(arguments.contains("ProxyJump=none"))
        #expect(arguments.contains("ProxyCommand=none"))
        #expect(arguments.contains("ForwardX11=no"))
        #expect(arguments.contains("ForwardX11Trusted=no"))
        #expect(arguments.contains("appreview@review.example.com"))
        #expect(arguments.last?.contains(UITestSSHSessionEnvironment.formalSmokeMarker) == true)
        #expect(!arguments.contains("PreferredAuthentications=publickey,password,keyboard-interactive"))
        #expect(!arguments.contains("~/.ssh/deploy"))
        #expect(!arguments.contains("\(NSHomeDirectory())/.ssh/deploy"))
        #expect(!arguments.contains("bastion.example.com"))
        #expect(!arguments.contains("-i"))
        #expect(!arguments.contains("-J"))
        #expect(!arguments.contains("-X"))
        #expect(!arguments.contains("RequestTTY=force"))
    }

    @Test func encryptedCredentialVaultRoundTripsWithoutPlaintextSQLiteSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await MainActor.run {
            let vault = EncryptedCredentialVault(rootDirectory: directory)
            try vault.save(secret: "temporary-password", account: "deploy@example.com:22")
            #expect(try vault.read(account: "deploy@example.com:22") == "temporary-password")
        }

        let databaseURL = directory.appendingPathComponent("credentials.sqlite")
        let databaseData = try Data(contentsOf: databaseURL)
        let databaseText = String(decoding: databaseData, as: UTF8.self)
        #expect(!databaseText.contains("temporary-password"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("vault-rsa-private.der").path))

        try await MainActor.run {
            let restartedVault = EncryptedCredentialVault(rootDirectory: directory)
            #expect(try restartedVault.read(account: "deploy@example.com:22") == "temporary-password")
            try restartedVault.delete(account: "deploy@example.com:22")
            #expect(try restartedVault.read(account: "deploy@example.com:22") == nil)
        }
    }

    @Test func askpassEnvironmentContainsOnlyOneShotBrokerCoordinates() async throws {
        let context = try SSHCredentialAskpass.launchContext(
            account: "deploy@example.com:22",
            secret: "temporary-secret"
        )
        defer { context.cleanup() }
        let environment = context.environment
        let helperPath = try #require(environment["SSH_ASKPASS"])
        let socketPath = try #require(
            environment[SSHCredentialAskpass.brokerSocketEnvironmentKey]
        )
        let challenge = try #require(
            environment[SSHCredentialAskpass.brokerChallengeEnvironmentKey]
        )

        #expect(Set(environment.keys) == [
            "SSH_ASKPASS",
            "SSH_ASKPASS_REQUIRE",
            "DISPLAY",
            SSHCredentialAskpass.brokerSocketEnvironmentKey,
            SSHCredentialAskpass.brokerChallengeEnvironmentKey,
        ])
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment["DISPLAY"] == "JTSTerminal")
        #expect(challenge.count == SSHCredentialAskpass.challengeByteCount * 2)
        #expect(challenge.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(URL(fileURLWithPath: socketPath).lastPathComponent == "s")
        #expect(FileManager.default.fileExists(atPath: socketPath))

        let socketStatus = try testLStat(at: URL(fileURLWithPath: socketPath))
        #expect(socketStatus.st_uid == geteuid())
        #expect(socketStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK))
        #expect(socketStatus.st_mode & mode_t(0o777) == mode_t(0o600))
        let socketDirectoryStatus = try testLStat(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        )
        #expect(socketDirectoryStatus.st_uid == geteuid())
        #expect(socketDirectoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        #expect(socketDirectoryStatus.st_mode & mode_t(0o777) == mode_t(0o700))

        let markerPath = context.consumptionMarkerURL.path
        #expect(FileManager.default.fileExists(atPath: markerPath))
        #expect(context.consumptionMarkerURL.lastPathComponent.hasSuffix(".consumed"))
        let markerAttributes = try FileManager.default.attributesOfItem(atPath: markerPath)
        let markerPermissions = try #require(markerAttributes[.posixPermissions] as? NSNumber)
        #expect(markerPermissions.intValue & 0o777 == 0o600)
        #expect(helperPath.hasSuffix("/Contents/MacOS/JTSSHAskpass"))
        #expect(!helperPath.hasSuffix(".sh"))
        #expect(
            helperPath == SSHCredentialAskpass.applicationBundle.bundleURL
                .appendingPathComponent(SSHCredentialAskpass.helperRelativePath)
                .path
        )
        #expect(FileManager.default.isExecutableFile(atPath: helperPath))
        #expect(!environment.keys.contains("JTS_TERMINAL_ASKPASS_SECRET"))
        #expect(!environment.keys.contains("JTS_TERMINAL_ASKPASS_CONSUMPTION_MARKER"))
        #expect(!environment.keys.contains("JTS_TERMINAL_CREDENTIAL_ACCOUNT"))
        #expect(!environment.values.contains("temporary-secret"))

        context.cleanup()
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        let socketURL = URL(fileURLWithPath: socketPath)
        for _ in 0..<40 where FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(!FileManager.default.fileExists(
            atPath: socketURL.deletingLastPathComponent().path
        ))
    }

    @Test func askpassRejectsCredentialsThatCannotBeRepresentedBySSHAskpass() {
        #expect(throws: (any Error).self) {
            _ = try SSHCredentialAskpass.launchContext(
                account: "deploy@example.com:22",
                secret: ""
            )
        }
        #expect(throws: (any Error).self) {
            _ = try SSHCredentialAskpass.launchContext(
                account: "deploy@example.com:22",
                secret: "line-one\nline-two"
            )
        }
        #expect(throws: (any Error).self) {
            _ = try SSHCredentialAskpass.launchContext(
                account: "deploy@example.com:22",
                secret: String(repeating: "x", count: SSHCredentialAskpass.maximumSecretBytes + 1)
            )
        }
    }

    @Test func askpassPrunesOnlyStructurallySafeStaleEmptyMarkers() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("askpass-prune-\(UUID().uuidString)", isDirectory: true)
        try PrivateFileSecurity.secureDirectory(at: directory, fileManager: fileManager)
        defer { try? fileManager.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let staleDate = now.addingTimeInterval(-3_600)
        let freshDate = now.addingTimeInterval(-30)
        func markerURL() -> URL {
            directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("consumed")
        }
        func makeMarker(
            at url: URL,
            contents: Data = Data(),
            permissions: Int = 0o600,
            modifiedAt: Date = staleDate
        ) throws {
            #expect(fileManager.createFile(
                atPath: url.path,
                contents: contents,
                attributes: [.posixPermissions: permissions]
            ))
            try fileManager.setAttributes(
                [.posixPermissions: permissions, .modificationDate: modifiedAt],
                ofItemAtPath: url.path
            )
        }

        let staleEmpty = markerURL()
        let freshEmpty = markerURL()
        let payloadBearing = markerURL()
        let permissive = markerURL()
        let hardLinked = markerURL()
        let hardLinkSibling = directory.appendingPathComponent("hard-link-sibling")
        let unrelated = directory.appendingPathComponent("unrelated.consumed")
        let symlink = markerURL()

        try makeMarker(at: staleEmpty)
        try makeMarker(at: freshEmpty, modifiedAt: freshDate)
        try makeMarker(at: payloadBearing, contents: Data("not-a-secret".utf8))
        try makeMarker(at: permissive, permissions: 0o640)
        try makeMarker(at: hardLinked)
        try fileManager.linkItem(at: hardLinked, to: hardLinkSibling)
        try makeMarker(at: unrelated)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: staleEmpty)

        SSHCredentialAskpass.removeStaleConsumptionMarkers(
            in: directory,
            now: now,
            staleAfter: 300
        )

        #expect(!fileManager.fileExists(atPath: staleEmpty.path))
        #expect(fileManager.fileExists(atPath: freshEmpty.path))
        #expect(fileManager.fileExists(atPath: payloadBearing.path))
        #expect(fileManager.fileExists(atPath: permissive.path))
        #expect(fileManager.fileExists(atPath: hardLinked.path))
        #expect(fileManager.fileExists(atPath: hardLinkSibling.path))
        #expect(fileManager.fileExists(atPath: unrelated.path))
        #expect(try testLStat(at: symlink).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
    }

    @Test func bundledAskpassHelperIsANativeMachOExecutable() async throws {
        let helperURL = try SSHCredentialAskpass.helperURL()
        let header = try Data(contentsOf: helperURL, options: .mappedIfSafe).prefix(4)
        let machOMagicValues: Set<[UInt8]> = [
            [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE],
            [0xBE, 0xBA, 0xFE, 0xCA],
        ]

        #expect(FileManager.default.isExecutableFile(atPath: helperURL.path))
        #expect(machOMagicValues.contains(Array(header)))
    }

    @Test func directoryListingQuotesRemotePath() async throws {
        let command = SSHCommandBuilder.listDirectoryCommand(path: "/var/log/app logs")

        #expect(command == "LC_ALL=C ls -la '/var/log/app logs'")
    }

    @Test func structuredDirectoryListingCommandUsesPythonJSONAndQuotesPath() async throws {
        let command = SSHCommandBuilder.structuredDirectoryListingCommand(path: "/srv/app logs")

        #expect(command.contains("/usr/bin/env python3"))
        #expect(command.contains("json.dumps(entries"))
        #expect(command.contains("'/srv/app logs'"))
    }

    @Test func remoteFileMCPCommandsUsePythonJSONAndAtomicReplace() async throws {
        let readCommand = SSHCommandBuilder.readFileCommand(
            path: "/srv/app config.json",
            offset: 10,
            limitBytes: 2048,
            encoding: "utf8"
        )
        let writeCommand = SSHCommandBuilder.writeFileCommand(
            path: "/srv/app config.json",
            createParents: true,
            mode: "0644"
        )
        let statCommand = SSHCommandBuilder.statCommand(path: "/srv/app config.json")

        #expect(readCommand.contains("json.dumps"))
        #expect(readCommand.contains("read(limit + 1)"))
        #expect(readCommand.contains("'/srv/app config.json'"))
        #expect(writeCommand.contains("sys.stdin.read()"))
        #expect(writeCommand.contains("base64.b64decode"))
        #expect(writeCommand.contains("os.replace(temp_path, path)"))
        #expect(statCommand.contains("os.lstat(path)"))
        #expect(statCommand.contains("stat.filemode(mode)"))
    }

    @Test func mcpAliasNormalizesDisplayNames() async throws {
        #expect(MCPAlias.normalized(" Prod API@10.0.0.1 ") == "prod-api-10-0-0-1")
        #expect(MCPAlias.normalized("   ") == "server")
    }

    @MainActor
    @Test func mcpInitializeReturnsToolsAndResourcesCapabilities() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let server = MCPStdioServer(modelContext: ModelContext(container))

        let response = try #require(await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        let object = try decodedJSONObject(response)
        let result = try #require(object["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])

        #expect(result["protocolVersion"] as? String == "2025-11-25")
        #expect(capabilities["tools"] != nil)
        #expect(capabilities["resources"] != nil)
    }

    @MainActor
    @Test func mcpInitializeRecordsRegisteredRuntimeEvidenceOnlyOnce() async throws {
        let container = try ModelContainerFactory.makeContainer(
            isStoredInMemoryOnly: true
        )
        let registration = testMCPRegistration()
        var observations: [MCPClientRegistrationRecord] = []
        let server = MCPStdioServer(
            modelContext: ModelContext(container),
            clientRegistration: registration,
            runtimeRegistrationObserver: {
                observations.append($0)
            }
        )

        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        ))
        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#
        ))

        #expect(observations == [registration])
    }

    @MainActor
    @Test func mcpToolDefinitionsExactlyPreserveLegacy12Contract() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let server = MCPStdioServer(modelContext: ModelContext(container))

        let response = try #require(await server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#))
        let object = try decodedJSONObject(response)
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let legacyNames = Set(LegacyMCPToolName.allCases.map(\.rawValue))
        let actualLegacy = tools.filter { tool in
            guard let name = tool["name"] as? String else { return false }
            return legacyNames.contains(name)
        }
        let expectedLegacy = try #require(
            JSONSerialization.jsonObject(with: Data(legacy12MCPToolDefinitionsJSON.utf8))
                as? [[String: Any]]
        )

        #expect(LegacyMCPToolName.allCases.count == 15)
        #expect(actualLegacy.count == 15)
        #expect(try canonicalJSON(actualLegacy) == canonicalJSON(expectedLegacy))

        #if ENABLE_RDP_2
        let windowsNames = Set(WindowsMCPToolName.allCases.map(\.rawValue))
        let actualNames = Set(tools.compactMap { $0["name"] as? String })
        let deviceNames = Set(CompanionDeviceMCPTool.allCases.map(\.rawValue))
        #expect(WindowsMCPToolName.allCases.count == 11)
        #expect(windowsNames.contains("jts_companion_pairing"))
        #expect(deviceNames == ["jts_device_status", "jts_device_exec", "jts_device_task", "jts_device_files"])
        #expect(tools.count == 30)
        #expect(actualNames == legacyNames.union(windowsNames).union(deviceNames))
        #else
        #expect(tools.count == 15)
        #endif
    }

    #if ENABLE_RDP_2
    @Test func legacyMCPAuthorizationContractIsCompleteAndTableDriven() {
        let rows: [(
            tool: LegacyMCPToolName,
            overwritesLocalDestination: Bool,
            expected: LegacyMCPAuthorizationRequirement
        )] = [
            (.listServers, false, .init(permissions: [.discovery], externalData: [.targetMetadata], auditCategory: "legacy.discovery")),
            (.exec, false, .init(permissions: [.commandExecution], externalData: [.commandOutput], auditCategory: "legacy.command")),
            (.listDirectory, false, .init(permissions: [.fileAccess], externalData: [.fileMetadata], auditCategory: "legacy.file")),
            (.readFile, false, .init(permissions: [.fileAccess], externalData: [.fileContent], auditCategory: "legacy.file")),
            (.writeFile, false, .init(permissions: [.fileAccess, .destructiveOperations], externalData: [], auditCategory: "legacy.destructive")),
            (.uploadFile, false, .init(permissions: [.fileAccess, .destructiveOperations], externalData: [], auditCategory: "legacy.destructive")),
            (.downloadFile, false, .init(permissions: [.fileAccess], externalData: [.fileContent], auditCategory: "legacy.file")),
            (.downloadFile, true, .init(permissions: [.fileAccess, .destructiveOperations], externalData: [.fileContent], auditCategory: "legacy.destructive")),
            (.stat, false, .init(permissions: [.fileAccess], externalData: [.fileMetadata], auditCategory: "legacy.file")),
            (.makeDirectory, false, .init(permissions: [.fileAccess, .destructiveOperations], externalData: [], auditCategory: "legacy.destructive")),
            (.rename, false, .init(permissions: [.fileAccess, .destructiveOperations], externalData: [], auditCategory: "legacy.destructive")),
            (.remove, false, .init(permissions: [.fileAccess, .destructiveOperations], externalData: [], auditCategory: "legacy.destructive")),
            (.listOpenTerminals, false, .init(permissions: [.discovery], externalData: [.targetMetadata], auditCategory: "legacy.discovery")),
            (.openTerminal, false, .init(permissions: [.commandExecution], externalData: [], auditCategory: "legacy.terminal")),
            (.terminalExec, false, .init(permissions: [.commandExecution], externalData: [.terminalOutput], auditCategory: "legacy.terminal")),
            (.terminalRead, false, .init(permissions: [.commandExecution], externalData: [.terminalOutput], auditCategory: "legacy.terminal")),
        ]

        for row in rows {
            #expect(LegacyMCPAuthorizationContract.requirement(
                for: row.tool,
                overwritesLocalDestination: row.overwritesLocalDestination
            ) == row.expected)
        }

        let defaultMappedTools = Set(
            rows.filter { !$0.overwritesLocalDestination }.map(\.tool)
        )
        #expect(defaultMappedTools == Set(LegacyMCPToolName.allCases))
    }
    #endif

    #if ENABLE_RDP_2
    @MainActor
    @Test func mcpSelfReportedClientInfoCannotOverrideRegistrarIdentity() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Identity", host: "identity.example.com", username: "deploy")
        session.mcpEnabled = true
        session.mcpAlias = "identity"
        context.insert(session)
        try context.save()

        let registration = testMCPRegistration()
        let grantURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-identity-grants-\(UUID().uuidString)/grants.json")
        let grantStore = RemoteClientGrantStore(storageURL: grantURL)
        let server = MCPStdioServer(
            modelContext: context,
            remoteRunner: MCPRemoteCommandRunner { _, _, _, _ in
                CommandResult(
                    command: "printf identity",
                    exitCode: 0,
                    standardOutput: "identity",
                    standardError: ""
                )
            },
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )

        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"spoofed-admin","version":"999"}}}"#
        ))
        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"jts_list_servers","arguments":{}}}"#
        ))
        #expect(grantStore.pendingRequests(targetID: session.targetID).isEmpty)
        #expect(grantStore.activeGrants(targetID: session.targetID).isEmpty)

        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jts_exec","arguments":{"server":"identity","command":"printf identity"}}}"#
        ))
        let grant = try #require(grantStore.activeGrants(targetID: session.targetID).first)
        #expect(grant.clientID == registration.authorizationClientID)
        #expect(grant.clientDisplayIdentity == registration.displayIdentity)
        #expect(grant.clientID != "spoofed-admin@999")
        #expect(grantStore.pendingRequests(targetID: session.targetID).isEmpty)
    }

    @MainActor
    @Test func mcpResourceEnumerationDoesNotCreateAuthorizationRequests() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(
            name: "Resource Discovery",
            host: "resource.example.com",
            username: "deploy"
        )
        session.mcpEnabled = true
        session.mcpAlias = "resource-discovery"
        context.insert(session)
        try context.save()

        let grantURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-resource-list-grants-\(UUID().uuidString)/grants.json")
        let grantStore = RemoteClientGrantStore(storageURL: grantURL)
        let server = MCPStdioServer(
            modelContext: context,
            remoteGrantStore: grantStore,
            clientRegistration: testMCPRegistration()
        )

        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        ))
        for requestID in 2...6 {
            let response = try #require(await server.handleLine(
                "{\"jsonrpc\":\"2.0\",\"id\":\(requestID),\"method\":\"resources/list\",\"params\":{}}"
            ))
            let result = try #require(
                try decodedJSONObject(response)["result"] as? [String: Any]
            )
            let resources = try #require(result["resources"] as? [[String: Any]])
            #expect(resources.map { $0["uri"] as? String } == [
                "jts://servers",
                "jts://server/\(session.effectiveMCPAlias)/file/\(session.remotePath)",
            ])
        }

        #expect(grantStore.pendingRequests.isEmpty)
        #expect(grantStore.grants.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: grantURL.path))
    }

    @MainActor
    @Test func mcpResourceEnumerationSilentlyRefreshesCrossProcessGrantChanges() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(
            name: "Resource Freshness",
            host: "freshness.example.com",
            username: "deploy"
        )
        session.mcpEnabled = true
        session.mcpAlias = "resource-freshness"
        context.insert(session)
        try context.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-resource-freshness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grantURL = root.appendingPathComponent("grants.json")
        let registration = testMCPRegistration()
        let mcpStore = RemoteClientGrantStore(storageURL: grantURL)
        let guiStore = RemoteClientGrantStore(storageURL: grantURL)
        let server = MCPStdioServer(
            modelContext: context,
            remoteGrantStore: mcpStore,
            clientRegistration: registration
        )

        func resourceURIs(requestID: Int) async throws -> [String] {
            let response = try #require(await server.handleLine(
                "{\"jsonrpc\":\"2.0\",\"id\":\(requestID),\"method\":\"resources/list\",\"params\":{}}"
            ))
            let result = try #require(
                try decodedJSONObject(response)["result"] as? [String: Any]
            )
            let resources = try #require(result["resources"] as? [[String: Any]])
            return resources.compactMap { $0["uri"] as? String }
        }

        let targetResourceURI = "jts://server/\(session.effectiveMCPAlias)/file/\(session.remotePath)"
        #expect(try await resourceURIs(requestID: 1) == [
            "jts://servers",
            targetResourceURI,
        ])

        try approveRemoteGrant(
            in: guiStore,
            session: session,
            registration: registration,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileMetadata],
            consentToExternalData: true
        )
        #expect(try await resourceURIs(requestID: 2) == [
            "jts://servers",
            targetResourceURI,
        ])

        let grant = try #require(guiStore.activeGrants(targetID: session.targetID).first)
        try guiStore.revoke(grantID: grant.grantID)
        #expect(try await resourceURIs(requestID: 3) == ["jts://servers"])

        do {
            _ = try guiStore.authorize(
                clientID: registration.authorizationClientID,
                targetID: session.targetID,
                capabilities: [.fileAccess],
                policy: session.mcpPermissionPolicy,
                externalDataTypes: [.fileMetadata]
            )
            Issue.record("Revoked access must require a new visible approval")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
        let persistedPendingState = try Data(contentsOf: grantURL)
        let notificationCounter = LockedNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .jtsRDPGrantApprovalRequested,
            object: nil,
            queue: nil
        ) { _ in
            notificationCounter.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(try await resourceURIs(requestID: 4) == ["jts://servers"])
        #expect(mcpStore.pendingRequests(targetID: session.targetID).count == 1)
        #expect(try Data(contentsOf: grantURL) == persistedPendingState)
        #expect(notificationCounter.value == 0)
    }

    @MainActor
    @Test func unregisteredMCPProcessOnlyExposesHandshakeAndToolSchemas() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let server = MCPStdioServer(modelContext: ModelContext(container))

        let initialize = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"trusted-looking","version":"1"}}}"#
        ))
        let tools = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        ))
        let denied = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jts_list_servers","arguments":{}}}"#
        ))
        let deniedResources = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":4,"method":"resources/list","params":{}}"#
        ))

        #expect(try decodedJSONObject(initialize)["result"] != nil)
        #expect(try decodedJSONObject(tools)["result"] != nil)
        #expect(((try decodedJSONObject(denied)["error"] as? [String: Any])?["message"] as? String)?.contains("CLIENT_REGISTRATION_REQUIRED") == true)
        #expect(((try decodedJSONObject(deniedResources)["error"] as? [String: Any])?["message"] as? String)?.contains("CLIENT_REGISTRATION_REQUIRED") == true)
        #expect(MCPStdioServer.requestedRegistrationID(arguments: ["app", "--mcp", "--mcp-client-registration"]) == nil)
        #expect(MCPStdioServer.requestedRegistrationID(arguments: ["app", "--mcp-client-registration", "one", "--mcp-client-registration", "two"]) == nil)
    }
    #endif

    @Test func mcpRegistrationRegistryIsStablePrivateAndFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-registration-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("security/registrations.json")
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL
        )
        let command = "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal"

        let preview = try registrar.registrationPreview(for: .codexDesktop, commandPath: command)
        #expect(preview.arguments == MCPClientRegistrar.arguments(registrationID: preview.registration.registrationID))
        #expect(preview.configurationSnippet.contains(preview.registration.registrationID))
        #expect(preview.focusedDiff.contains("Args: \(preview.arguments)"))
        #expect(
            preview.registration.displayIdentity
                == "Codex · …\(preview.registration.registrationID.suffix(8))"
        )
        let result = try registrar.register(preview)
        let second = try registrar.registrationPreview(for: .codexCLI, commandPath: command)
        #expect(result.registrationID == preview.registration.registrationID)
        #expect(second.registration.registrationID == result.registrationID)
        #expect(try registrar.registrationRegistry.resolve(registrationID: result.registrationID)?.authorizationClientID == "mcp-registration:\(result.registrationID)")
        let permissions = try #require(
            (FileManager.default.attributesOfItem(atPath: registryURL.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        #expect(permissions & 0o777 == 0o600)
        #expect(try registrar.registrationRegistry.resolve(
            registrationID: "99999999-9999-4999-8999-999999999999"
        ) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: registryURL.path)
        #expect(throws: MCPClientRegistrationRegistryError.insecurePermissions) {
            _ = try registrar.registrationRegistry.resolve(registrationID: result.registrationID)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
        try Data("not-json".utf8).write(to: registryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
        #expect(throws: MCPClientRegistrationRegistryError.corruptRegistry) {
            _ = try registrar.registrationRegistry.resolve(registrationID: result.registrationID)
        }
    }

    #if ENABLE_RDP_2
    @MainActor
    @Test func legacySSHGrantConsentLeaseAndRevocationArePerClient() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-grants-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteClientGrantStore(storageURL: root.appendingPathComponent("grants.json"))
        let targetID = UUID()
        let firstClient = testMCPRegistration().authorizationClientID
        let secondClient = testMCPRegistration(id: "33333333-3333-4333-8333-333333333333").authorizationClientID
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            _ = try store.authorize(
                clientID: firstClient,
                targetID: targetID,
                capabilities: [.discovery],
                policy: .sshDefault,
                externalDataTypes: [],
                at: issuedAt
            )
            Issue.record("First client must require approval")
        } catch let failure as RemoteGrantGateFailure {
            _ = try store.approve(
                requestID: try #require(failure.pendingRequestID),
                policy: .sshDefault,
                consentToExternalData: false,
                at: issuedAt
            )
        }

        do {
            _ = try store.authorize(
                clientID: firstClient,
                targetID: targetID,
                capabilities: [.commandExecution],
                policy: .sshDefault,
                externalDataTypes: [.commandOutput],
                at: issuedAt
            )
            Issue.record("Command output must require capability expansion and consent")
        } catch let failure as RemoteGrantGateFailure {
            let request = try #require(store.pendingRequests.first { $0.id == failure.pendingRequestID })
            #expect(request.externalDataTypes == [.commandOutput])
            #expect(throws: RemoteGrantGateFailure.self) {
                _ = try store.approve(
                    requestID: request.id,
                    policy: .sshDefault,
                    consentToExternalData: false,
                    at: issuedAt
                )
            }
            _ = try store.approve(
                requestID: request.id,
                policy: .sshDefault,
                consentToExternalData: true,
                at: issuedAt
            )
        }

        #expect(try store.authorize(
            clientID: firstClient,
            targetID: targetID,
            capabilities: [.commandExecution],
            policy: .sshDefault,
            externalDataTypes: [.commandOutput],
            at: issuedAt.addingTimeInterval(90_000)
        ).controlLeaseExpiresAt == nil)

        do {
            _ = try store.authorize(
                clientID: secondClient,
                targetID: targetID,
                capabilities: [.commandExecution],
                policy: .sshDefault,
                externalDataTypes: [.commandOutput],
                at: issuedAt.addingTimeInterval(1_800)
            )
            Issue.record("A second registration must never inherit the first grant")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }

        let grant = try #require(store.activeGrants(targetID: targetID).first { $0.clientID == firstClient })
        try store.revoke(grantID: grant.grantID, at: issuedAt.addingTimeInterval(1_801))
        do {
            _ = try store.authorize(
                clientID: firstClient,
                targetID: targetID,
                capabilities: [.commandExecution],
                policy: .sshDefault,
                externalDataTypes: [.commandOutput],
                at: issuedAt.addingTimeInterval(1_802)
            )
            Issue.record("Revocation must remove authority")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
    }
    #endif

    @MainActor
    @Test func mcpUploadFileUsesTransferRunnerAndRecordsHistory() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Files", host: "files.example.com", username: "ubuntu")
        session.mcpEnabled = true
        session.mcpAlias = "files"
        context.insert(session)
        try context.save()

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-upload-\(UUID().uuidString).txt")
        try Data("mcp".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let runner = MCPFileTransferRunner(
            upload: { _, localPath, remotePath, recursive, resume in
                CommandResult(
                    command: "fake upload",
                    exitCode: 0,
                    standardOutput: "uploaded \(localPath) -> \(remotePath) recursive=\(recursive) resume=\(resume)",
                    standardError: ""
                )
            },
            download: { _, _, _, _, _, _ in
                CommandResult(command: "unused", exitCode: 1, standardOutput: "", standardError: "unused")
            }
        )
        let registration = testMCPRegistration()
        let grantStore = try approvedGrantStore(for: [session], registration: registration)
        let server = MCPStdioServer(
            modelContext: context,
            guiLauncher: .disabled,
            fileTransferRunner: runner,
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )
        let response = try #require(await server.handleLine(try encodedJSONLine([
            "jsonrpc": "2.0",
            "id": 31,
            "method": "tools/call",
            "params": [
                "name": "jts_upload_file",
                "arguments": [
                    "server": "files",
                    "localPath": localURL.path,
                    "remotePath": "/srv/upload.txt"
                ]
            ]
        ])))
        let payload = try decodedJSONObject(try toolTextPayload(from: response))
        let tasks = try context.fetch(FetchDescriptor<RemoteTransferTask>())
        let task = try #require(tasks.first)

        #expect(payload["direction"] as? String == "upload")
        #expect(payload["serverAlias"] as? String == "files")
        #expect(payload["remotePath"] as? String == "/srv/upload.txt")
        #expect(payload["localPath"] as? String == localURL.path)
        #expect(payload["status"] as? String == "succeeded")
        #expect((payload["stdout"] as? String)?.contains("resume=true") == true)
        #expect(task.direction == .upload)
        #expect(task.status == .succeeded)
        #expect(task.resumeSupported)
        #expect(task.expectedByteCount == 3)
    }

    @MainActor
    @Test func mcpDownloadFileCreatesParentsAndRecordsHistory() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Files", host: "files.example.com", username: "ubuntu")
        session.mcpEnabled = true
        session.mcpAlias = "files"
        context.insert(session)
        try context.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-download-\(UUID().uuidString)", isDirectory: true)
        let localURL = root.appendingPathComponent("nested/out.txt")
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = MCPFileTransferRunner(
            upload: { _, _, _, _, _ in
                CommandResult(command: "unused", exitCode: 1, standardOutput: "", standardError: "unused")
            },
            download: { _, remotePath, localPath, recursive, resume, _ in
                try Data(repeating: 0x41, count: 42).write(to: URL(fileURLWithPath: localPath))
                return CommandResult(
                    command: "fake download",
                    exitCode: 0,
                    standardOutput: "downloaded \(remotePath) -> \(localPath) recursive=\(recursive) resume=\(resume)",
                    standardError: ""
                )
            }
        )
        let registration = testMCPRegistration()
        let grantStore = try approvedGrantStore(for: [session], registration: registration)
        let server = MCPStdioServer(
            modelContext: context,
            guiLauncher: .disabled,
            fileTransferRunner: runner,
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )
        let response = try #require(await server.handleLine(try encodedJSONLine([
            "jsonrpc": "2.0",
            "id": 32,
            "method": "tools/call",
            "params": [
                "name": "jts_download_file",
                "arguments": [
                    "server": "files",
                    "remotePath": "/srv/report.txt",
                    "localPath": localURL.path,
                    "resume": false,
                    "expectedBytes": 42
                ]
            ]
        ])))
        let payload = try decodedJSONObject(try toolTextPayload(from: response))
        let tasks = try context.fetch(FetchDescriptor<RemoteTransferTask>())
        let task = try #require(tasks.first)

        #expect(FileManager.default.fileExists(atPath: localURL.deletingLastPathComponent().path))
        #expect(payload["direction"] as? String == "download")
        #expect(payload["serverAlias"] as? String == "files")
        #expect(payload["remotePath"] as? String == "/srv/report.txt")
        #expect(payload["localPath"] as? String == localURL.path)
        #expect(payload["status"] as? String == "succeeded")
        #expect((payload["stdout"] as? String)?.contains("resume=false") == true)
        #expect(task.direction == .download)
        #expect(task.status == .succeeded)
        #expect(!task.resumeSupported)
        #expect(task.expectedByteCount == 42)
    }

    #if ENABLE_RDP_2
    @MainActor
    @Test func mcpMkdirUsesAnEnabledMCPProfileWithoutAnotherApproval() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Mutation", host: "files.example.com", username: "ubuntu")
        session.mcpEnabled = true
        session.mcpAlias = "mutation"
        context.insert(session)
        try context.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-mkdir-grants-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = testMCPRegistration()
        let grantStore = RemoteClientGrantStore(storageURL: root.appendingPathComponent("grants.json"))
        try approveRemoteGrant(
            in: grantStore,
            session: session,
            registration: registration,
            capabilities: [.fileAccess],
            externalDataTypes: [],
            consentToExternalData: false
        )

        var remoteCommands: [String] = []
        let remoteRunner = MCPRemoteCommandRunner { _, remoteCommand, _, _ in
            remoteCommands.append(remoteCommand)
            return CommandResult(
                command: remoteCommand,
                exitCode: 0,
                standardOutput: "created",
                standardError: ""
            )
        }
        let server = MCPStdioServer(
            modelContext: context,
            guiLauncher: .disabled,
            remoteRunner: remoteRunner,
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )
        let request = try encodedJSONLine([
            "jsonrpc": "2.0",
            "id": 41,
            "method": "tools/call",
            "params": [
                "name": "jts_mkdir",
                "arguments": [
                    "server": "mutation",
                    "path": "/srv/new folder",
                    "parents": true,
                ],
            ],
        ])

        let allowedLine = try #require(await server.handleLine(request))
        let allowedPayload = try decodedJSONObject(try toolTextPayload(from: allowedLine))
        #expect(allowedPayload["exitCode"] as? Int == 0)
        #expect(remoteCommands == ["mkdir -p -- '/srv/new folder'"])
        #expect(grantStore.pendingRequests(targetID: session.targetID).isEmpty)
    }

    @MainActor
    @Test func mcpDownloadOverwriteAndNewDestinationBothUseAnEnabledMCPProfile() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Downloads", host: "files.example.com", username: "ubuntu")
        session.mcpEnabled = true
        session.mcpAlias = "downloads"
        context.insert(session)
        try context.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-download-overwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existingURL = root.appendingPathComponent("existing.txt")
        let newURL = root.appendingPathComponent("new.txt")
        try Data("keep-until-authorized".utf8).write(to: existingURL)

        let registration = testMCPRegistration()
        let grantStore = RemoteClientGrantStore(storageURL: root.appendingPathComponent("security/grants.json"))
        try approveRemoteGrant(
            in: grantStore,
            session: session,
            registration: registration,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileContent],
            consentToExternalData: true
        )

        var downloadedPaths: [String] = []
        let transferRunner = MCPFileTransferRunner(
            upload: { _, _, _, _, _ in
                CommandResult(command: "unused", exitCode: 1, standardOutput: "", standardError: "unused")
            },
            download: { _, remotePath, localPath, recursive, resume, _ in
                downloadedPaths.append(localPath)
                try Data("downloaded".utf8).write(to: URL(fileURLWithPath: localPath))
                return CommandResult(
                    command: "fake download",
                    exitCode: 0,
                    standardOutput: "downloaded \(remotePath) recursive=\(recursive) resume=\(resume)",
                    standardError: ""
                )
            }
        )
        let server = MCPStdioServer(
            modelContext: context,
            guiLauncher: .disabled,
            fileTransferRunner: transferRunner,
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )

        func request(localPath: String, id: Int) throws -> String {
            try encodedJSONLine([
                "jsonrpc": "2.0",
                "id": id,
                "method": "tools/call",
                "params": [
                    "name": "jts_download_file",
                    "arguments": [
                        "server": "downloads",
                        "remotePath": "/srv/report.txt",
                        "localPath": localPath,
                    ],
                ],
            ])
        }

        let overwrittenLine = try #require(await server.handleLine(
            try request(localPath: existingURL.path, id: 51)
        ))
        let overwrittenPayload = try decodedJSONObject(try toolTextPayload(from: overwrittenLine))
        #expect(overwrittenPayload["status"] as? String == "succeeded")
        #expect(downloadedPaths == [existingURL.path])
        #expect(try String(contentsOf: existingURL, encoding: .utf8) == "downloaded")
        #expect(grantStore.pendingRequests(targetID: session.targetID).isEmpty)

        let newLine = try #require(await server.handleLine(
            try request(localPath: newURL.path, id: 52)
        ))
        let newPayload = try decodedJSONObject(try toolTextPayload(from: newLine))
        #expect(newPayload["status"] as? String == "succeeded")
        #expect(downloadedPaths == [existingURL.path, newURL.path])
        #expect(try context.fetch(FetchDescriptor<RemoteTransferTask>()).count == 2)
    }
    #endif

    @Test func terminalMCPCommandEnvelopeParsesEchoedSentinels() async throws {
        let transcript = """
        printf '\\n__JTS_MCP_START_A__\\n'
        {
        whoami
        }
        printf '\\n__JTS_MCP_END_A__:%s\\n' "$__jts_mcp_status"

        __JTS_MCP_START_A__
        root
        __JTS_MCP_END_A__:0

        """

        let parsed = try #require(TerminalMCPCommandEnvelope.parse(
            transcript: transcript,
            baselineCharacterCount: 0,
            startSentinel: "__JTS_MCP_START_A__",
            endSentinel: "__JTS_MCP_END_A__"
        ))

        #expect(parsed.stdout == "root")
        #expect(parsed.exitCode == 0)
    }

    @Test func terminalMCPDisplayTranscriptHidesWrapperAndSentinels() async throws {
        let start = "__JTS_MCP_START_A__"
        let end = "__JTS_MCP_END_A__"
        let wrapper = TerminalMCPCommandEnvelope.wrappedCommand(
            command: "whoami",
            startSentinel: start,
            endSentinel: end
        )
        let display = TerminalMCPCommandEnvelope.displayTranscript(
            from: "\(wrapper)\r\n\(start)\r\nroot\r\n\(end):0\r\nash-4.4# ",
            startSentinel: start,
            endSentinel: end
        )

        #expect(display == "root\r\nash-4.4# ")
        #expect(!display.contains("__jts_mcp_cmd"))
        #expect(!display.contains("__JTS_MCP_START"))
        #expect(!display.contains("__JTS_MCP_END"))
    }

    @Test func terminalMCPCommandEnvelopeSplitsLongCommandsIntoPTYSafeLines() async throws {
        let start = "__JTS_MCP_START_LONG__"
        let end = "__JTS_MCP_END_LONG__"
        let longValue = String(repeating: "a", count: 6_000)
        let command = "value=\(SSHCommandBuilder.shellQuote(longValue)); printf '%s' \"$value\""
        let wrapper = TerminalMCPCommandEnvelope.wrappedCommand(
            command: command,
            startSentinel: start,
            endSentinel: end
        )
        let longestLine = wrapper
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.utf8.count)
            .max() ?? 0
        let chunks = TerminalMCPCommandEnvelope.inputChunks(for: wrapper)

        #expect(longestLine <= 820)
        #expect(!wrapper.contains("__jts_mcp_cmd=$(printf"))
        #expect(chunks.allSatisfy { $0.utf8.count <= 512 })
        #expect(chunks.allSatisfy {
            $0.hasSuffix("\n") || $0.hasSuffix("\r") || $0.utf8.count == 512
        })

        let result = try await ProcessExecutor().run(
            executable: "/bin/sh",
            arguments: [],
            standardInput: wrapper.replacingOccurrences(of: "\r", with: "\n"),
            timeoutSeconds: 5
        )
        let parsed = try #require(TerminalMCPCommandEnvelope.parse(
            transcript: result.standardOutput,
            baselineCharacterCount: 0,
            startSentinel: start,
            endSentinel: end
        ))

        #expect(parsed.exitCode == 0)
        #expect(parsed.stdout == longValue)
    }

    @Test func terminalMCPBridgeClientReportsMissingDescriptor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-missing-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let client = TerminalMCPBridgeClient(runtimeRoot: root)

        do {
            _ = try client.listOpenTerminals()
            Issue.record("Expected missing descriptor to throw.")
        } catch {
            #expect(error.localizedDescription.contains("bridge is not available"))
        }
    }

    @Test func terminalMCPBridgeClientBoundsStalledReplyByAbsoluteDeadline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-stalled-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let socketURL = try TerminalMCPBridgeRuntime.socketURL(runtimeRoot: root)
        let listenFD = try TerminalMCPBridgeSocket.listen(path: socketURL.path)
        defer { Darwin.close(listenFD) }
        try TerminalMCPBridgeRuntime.writeDescriptor(
            TerminalMCPBridgeDescriptor(
                socketPath: socketURL.path,
                token: "stalled-test-token",
                appPID: getpid(),
                createdAt: Date()
            ),
            runtimeRoot: root
        )

        let stalledServer = Task.detached {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }
            var suppressSigPipe: Int32 = 1
            _ = Darwin.setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &suppressSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
            // Keep every individual recv below the old relative timeout. The
            // client must still stop at the one absolute request deadline.
            for value in Data("{\"ok\":true,\"result\":{}".utf8) {
                var byte = value
                guard Darwin.send(clientFD, &byte, 1, 0) == 1 else { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        let client = TerminalMCPBridgeClient(runtimeRoot: root)
        let started = ContinuousClock.now

        do {
            _ = try client.listOpenTerminals(
                deadlineUptimeMilliseconds: Int(ProcessInfo.processInfo.systemUptime * 1_000) + 100
            )
            Issue.record("Expected the stalled bridge reply to hit its absolute deadline")
        } catch let bridgeError as TerminalMCPBridgeError {
            if case .deadlineExceeded = bridgeError {
                // Expected exact failure.
            } else {
                Issue.record("Expected deadlineExceeded, got \(bridgeError)")
            }
        }
        #expect(started.duration(to: .now) < .seconds(2))
        _ = await stalledServer.result

        var disconnectedPair = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &disconnectedPair) == 0 else {
            Issue.record("Could not create the SIGPIPE regression socket pair")
            return
        }
        defer { Darwin.close(disconnectedPair[0]) }
        Darwin.close(disconnectedPair[1])
        do {
            try TerminalMCPBridgeSocket.writeJSONLine(
                ["ok": true],
                to: disconnectedPair[0]
            )
            Issue.record("Expected a disconnected bridge peer to reject the response")
        } catch let bridgeError as TerminalMCPBridgeError {
            if case .socketFailure = bridgeError {
                // EPIPE is surfaced as an ordinary error instead of SIGPIPE.
            } else {
                Issue.record("Expected socketFailure, got \(bridgeError)")
            }
        }
    }

    @Test func terminalMCPBridgeLaunchPolicyDefaultsToDebugOnly() {
        #expect(TerminalMCPBridgeLaunchPolicy.shouldAutoStart(
            isUserEnabled: false,
            environment: [:],
            isDebugBuild: true
        ))
        #expect(!TerminalMCPBridgeLaunchPolicy.shouldAutoStart(
            isUserEnabled: false,
            environment: [:],
            isDebugBuild: false
        ))
        #expect(TerminalMCPBridgeLaunchPolicy.shouldAutoStart(
            isUserEnabled: true,
            environment: [:],
            isDebugBuild: false
        ))
    }

    @Test func terminalMCPBridgeLaunchPolicySupportsEnvironmentOverrides() {
        #expect(TerminalMCPBridgeLaunchPolicy.shouldAutoStart(
            isUserEnabled: false,
            environment: [TerminalMCPBridgeLaunchPolicy.enableEnvironmentKey: "1"],
            isDebugBuild: false
        ))
        #expect(!TerminalMCPBridgeLaunchPolicy.shouldAutoStart(
            isUserEnabled: true,
            environment: [TerminalMCPBridgeLaunchPolicy.disableEnvironmentKey: "1"],
            isDebugBuild: true
        ))
        #expect(!TerminalMCPBridgeLaunchPolicy.shouldAutoStart(
            isUserEnabled: true,
            environment: [
                TerminalMCPBridgeLaunchPolicy.enableEnvironmentKey: "1",
                TerminalMCPBridgeLaunchPolicy.disableEnvironmentKey: "1"
            ],
            isDebugBuild: true
        ))
    }

    @Test func terminalMCPBridgeRuntimeUsesUniqueFallbackSocketsForLongRuntimeRoots() throws {
        let longName = "jts-terminal-bridge-" + String(repeating: "x", count: 140)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(longName, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let firstSocket = try TerminalMCPBridgeRuntime.socketURL(runtimeRoot: root)
        let secondSocket = try TerminalMCPBridgeRuntime.socketURL(runtimeRoot: root)

        #expect(firstSocket != secondSocket)
        #expect(firstSocket.deletingLastPathComponent() == secondSocket.deletingLastPathComponent())
        #expect(firstSocket.lastPathComponent.contains("\(getpid())"))
        #expect(secondSocket.lastPathComponent.contains("\(getpid())"))
        try PrivateFileSecurity.verifyPrivateDirectory(
            at: firstSocket.deletingLastPathComponent()
        )

        let firstListener = try TerminalMCPBridgeSocket.listen(path: firstSocket.path)
        defer {
            _ = Darwin.close(firstListener)
            _ = firstSocket.path.withCString { Darwin.unlink($0) }
        }
        let secondListener = try TerminalMCPBridgeSocket.listen(path: secondSocket.path)
        defer {
            _ = Darwin.close(secondListener)
            _ = secondSocket.path.withCString { Darwin.unlink($0) }
        }
        try PrivateFileSecurity.verifyPrivateSocket(at: firstSocket)
        try PrivateFileSecurity.verifyPrivateSocket(at: secondSocket)
    }

    @MainActor
    @Test func mcpListServersFiltersAllowlistedTerminalProfiles() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let enabled = RemoteSession(name: "Prod API", host: "prod.example.com", username: "deploy", connectionType: .ssh)
        enabled.mcpEnabled = true
        enabled.mcpAlias = "prod-api"
        let local = RemoteSession(name: "Root Local", connectionType: .localShell)
        local.mcpEnabled = true
        local.mcpAlias = "root-local"
        let disabled = RemoteSession(name: "Disabled", host: "disabled.example.com", username: "deploy", connectionType: .ssh)
        disabled.mcpEnabled = false
        let incomplete = RemoteSession(name: "Incomplete", host: "incomplete.example.com", username: "", connectionType: .ssh)
        incomplete.mcpEnabled = true

        context.insert(enabled)
        context.insert(local)
        context.insert(disabled)
        context.insert(incomplete)
        try context.save()

        let registration = testMCPRegistration()
        let grantStore = try approvedGrantStore(for: [enabled, local], registration: registration)
        let server = MCPStdioServer(
            modelContext: context,
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )
        let response = try #require(await server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jts_list_servers","arguments":{}}}"#))
        let payload = try toolTextPayload(from: response)
        let servers = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])

        let sshProfile = try #require(servers.first { $0["alias"] as? String == "prod-api" })
        let localProfile = try #require(servers.first { $0["alias"] as? String == "root-local" })
        let localCapabilities = try #require(localProfile["capabilities"] as? [String])

        #expect(servers.count == 2)
        #expect(sshProfile["host"] as? String == "prod.example.com")
        #expect(sshProfile["connectionType"] as? String == RemoteConnectionType.ssh.rawValue)
        #expect(localProfile["connectionType"] as? String == RemoteConnectionType.localShell.rawValue)
        #expect(localProfile["address"] as? String == "Local shell")
        #expect(localProfile["host"] == nil)
        #expect(localCapabilities.contains("terminal_exec"))
        #expect(!localCapabilities.contains("list_dir"))
    }

    @MainActor
    @Test func mcpRejectsDisabledServersBeforeRunningSSH() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Prod", host: "prod.example.com", username: "deploy", connectionType: .ssh)
        session.mcpEnabled = false
        context.insert(session)
        try context.save()

        let server = MCPStdioServer(
            modelContext: context,
            clientRegistration: testMCPRegistration()
        )
        let response = try #require(await server.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"jts_exec","arguments":{"server":"prod","command":"pwd"}}}"#))
        let object = try decodedJSONObject(response)
        let error = try #require(object["error"] as? [String: Any])

        #expect((error["message"] as? String)?.contains("not MCP-enabled") == true)
    }

    @Test func privateReplacementStagingIsPrivateAtomicAndOnDestinationVolume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-private-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let destination = root.appendingPathComponent("config.toml")
        let original = Data("original\n".utf8)
        try original.write(to: destination)
        let destinationIdentity = try PrivateFileSecurity.identity(at: destination)
        let staged = try PrivateFileSecurity.createReplacementStagedFile(for: destination)
        let stagingDirectory = staged.directoryURL

        #expect(stagingDirectory != destination.deletingLastPathComponent())
        #expect(staged.identity.device == destinationIdentity.device)
        try PrivateFileSecurity.verifyPrivateDirectory(at: stagingDirectory)
        try PrivateFileSecurity.verifyPrivateFile(at: staged.fileURL)

        try staged.handle.write(contentsOf: Data("replacement\n".utf8))
        try staged.handle.synchronize()
        try staged.handle.close()
        try PrivateFileSecurity.installReplacing(staged, at: destination)
        try PrivateFileSecurity.verifyPrivateFile(at: destination)
        #expect(try Data(contentsOf: destination) == Data("replacement\n".utf8))

        PrivateFileSecurity.removeStaging(staged)
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    @Test func mcpClientRegistrationRejectsSymbolicLinkConfigurationBeforePreview() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-symlink-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let targetURL = root.appendingPathComponent("actual/config.toml")
        let configURL = root.appendingPathComponent("selected/codex.toml")
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("model = \"gpt-5.5\"\n".utf8)
        try original.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: targetURL)
        let originalLinkDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: configURL.path
        )

        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL
        )
        expectUnsafeMCPConfigurationTopology(at: configURL.path) {
            _ = try registrar.registrationPreview(
                for: .codexDesktop,
                commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
                destinationURL: configURL
            )
        }

        let status = try testLStat(at: configURL)
        #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: configURL.path)
                == originalLinkDestination
        )
        #expect(try Data(contentsOf: targetURL) == original)
        #expect(!FileManager.default.fileExists(atPath: registryURL.path))
    }

    @Test func mcpClientRegistrationRejectsHardLinkedConfigurationBeforePreview() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-hardlink-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/codex.toml")
        let siblingURL = root.appendingPathComponent("selected/codex-sibling.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("model = \"gpt-5.5\"\n".utf8)
        try original.write(to: configURL)
        try FileManager.default.linkItem(at: configURL, to: siblingURL)
        #expect(try testLStat(at: configURL).st_nlink == 2)

        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL
        )
        expectUnsafeMCPConfigurationTopology(at: configURL.path) {
            _ = try registrar.registrationPreview(
                for: .codexDesktop,
                commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
                destinationURL: configURL
            )
        }

        #expect(try Data(contentsOf: configURL) == original)
        #expect(try Data(contentsOf: siblingURL) == original)
        #expect(try testLStat(at: configURL).st_nlink == 2)
        #expect(try testLStat(at: siblingURL).st_nlink == 2)
        #expect(!FileManager.default.fileExists(atPath: registryURL.path))
    }

    @Test func mcpClientRegistrationRejectsSymbolicLinkIntroducedBeforeInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-symlink-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/codex.toml")
        let targetURL = root.appendingPathComponent("selected/external.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("model = \"gpt-5.5\"\n".utf8)
        let external = Data("external = true\n".utf8)
        try original.write(to: configURL)
        try external.write(to: targetURL)

        var didReachInstallHook = false
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            beforeConfigurationInstallForTesting: {
                didReachInstallHook = true
                try FileManager.default.removeItem(at: configURL)
                try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: targetURL)
            }
        )
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
            destinationURL: configURL
        )

        expectUnsafeMCPConfigurationTopology(at: configURL.path) {
            _ = try registrar.register(preview)
        }

        #expect(didReachInstallHook)
        #expect(try testLStat(at: configURL).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
        #expect(try Data(contentsOf: targetURL) == external)
    }

    @Test func mcpClientRegistrationRejectsHardLinkIntroducedBeforeInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-hardlink-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/codex.toml")
        let siblingURL = root.appendingPathComponent("selected/codex-sibling.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("model = \"gpt-5.5\"\n".utf8)
        try original.write(to: configURL)

        var didReachInstallHook = false
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            beforeConfigurationInstallForTesting: {
                didReachInstallHook = true
                try FileManager.default.linkItem(at: configURL, to: siblingURL)
            }
        )
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
            destinationURL: configURL
        )

        expectUnsafeMCPConfigurationTopology(at: configURL.path) {
            _ = try registrar.register(preview)
        }

        #expect(didReachInstallHook)
        #expect(try Data(contentsOf: configURL) == original)
        #expect(try Data(contentsOf: siblingURL) == original)
        #expect(try testLStat(at: configURL).st_nlink == 2)
        #expect(try testLStat(at: siblingURL).st_nlink == 2)
    }

    @Test func mcpClientRegistrationRejectsStaleTOMLPreviewWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-stale-toml-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL
        )
        let configURL = root.appendingPathComponent("selected/codex.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = """
        model = "gpt-5.5"

        [mcp_servers.jts-terminal]
        command = "/tmp/original"
        args = ["--original"]
        """ + "\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let commandPath = "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal"
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: commandPath,
            destinationURL: configURL
        )
        #expect(preview.configurationSnapshot.exists)
        #expect(preview.configurationSnapshot.byteCount == Data(original.utf8).count)
        #expect(preview.configurationSnapshot.sha256 == testSHA256Hex(Data(original.utf8)))
        #expect(preview.focusedDiff.contains("Target SHA-256: \(preview.configurationSnapshot.sha256)"))

        let externallyChanged = """
        model = "gpt-5.5"
        externally_selected = true

        [mcp_servers.jts-terminal]
        command = "/tmp/external-change"
        args = ["--external"]
        """ + "\n"
        try externallyChanged.write(to: configURL, atomically: true, encoding: .utf8)

        #expect(throws: MCPClientRegistrationRegistryError.previewChanged) {
            try registrar.activateRegistration(preview)
        }
        #expect(throws: MCPClientRegistrationRegistryError.previewChanged) {
            try registrar.register(preview)
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == externallyChanged)
        #expect(!FileManager.default.fileExists(atPath: registryURL.path))

        let refreshed = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: commandPath,
            destinationURL: configURL
        )
        #expect(refreshed.destinationURL == configURL)
        #expect(refreshed.configurationSnapshot.exists)
        #expect(refreshed.configurationSnapshot.sha256 == testSHA256Hex(Data(externallyChanged.utf8)))
        #expect(refreshed.configurationSnapshot != preview.configurationSnapshot)
        #expect(refreshed.focusedDiff.contains("/tmp/external-change"))

        _ = try registrar.register(refreshed)
        let stored = try String(contentsOf: configURL, encoding: .utf8)
        #expect(stored.contains("externally_selected = true"))
        #expect(stored.contains("[mcp_servers.jts-terminal]"))
        #expect(stored.contains(commandPath))
    }

    @Test func mcpClientRegistrationRejectsSnapshotDriftDuringCommit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-commit-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/codex.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = """
        model = "gpt-5.5"
        selected_profile = "original"
        """ + "\n"
        let externallyChanged = """
        model = "gpt-5.5"
        selected_profile = "external"
        """ + "\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        var didReachCommitHook = false
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            beforeRegistrationActivationForTesting: {
                didReachCommitHook = true
                try externallyChanged.write(to: configURL, atomically: true, encoding: .utf8)
            }
        )
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
            destinationURL: configURL
        )

        #expect(throws: MCPClientRegistrationRegistryError.previewChanged) {
            try registrar.register(preview)
        }
        #expect(didReachCommitHook)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == externallyChanged)
        #expect(!FileManager.default.fileExists(atPath: registryURL.path))
    }

    @Test func mcpClientRegistrationLeavesConfigUntouchedWhenRegistryActivationFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-registry-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/codex.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = "model = \"gpt-5.5\"\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            beforeRegistrationActivationForTesting: {
                try PrivateFileSecurity.secureDirectory(
                    at: registryURL.deletingLastPathComponent()
                )
                try Data("{corrupt-registry".utf8).write(to: registryURL)
                try PrivateFileSecurity.securePrivateFile(at: registryURL)
            }
        )
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
            destinationURL: configURL
        )

        #expect(throws: MCPClientRegistrationRegistryError.corruptRegistry) {
            try registrar.register(preview)
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == original)
    }

    @Test func mcpClientRegistrationAtomicallyRestoresExistingInstallDrift() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-existing-install-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/codex.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = "model = \"gpt-5.5\"\nselected_profile = \"original\"\n"
        let externallyChanged = "model = \"gpt-5.5\"\nselected_profile = \"external\"\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            beforeConfigurationInstallForTesting: {
                try externallyChanged.write(to: configURL, atomically: true, encoding: .utf8)
            }
        )
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
            destinationURL: configURL
        )

        #expect(throws: MCPClientRegistrationRegistryError.previewChanged) {
            try registrar.register(preview)
        }
        let stored = try String(contentsOf: configURL, encoding: .utf8)
        #expect(stored == externallyChanged)
        #expect(!stored.contains(preview.registration.registrationID))
        #expect(
            try registrar.registrationRegistry.record(for: configURL)?.registrationID
                == preview.registration.registrationID
        )
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: configURL.deletingLastPathComponent().path
        )
        #expect(!siblingNames.contains { $0.contains(".jts-private-") })
    }

    @Test func mcpClientRegistrationPreservesFileCreatedDuringAbsentInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-absent-install-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/claude.json")
        let externallyCreated = """
        {
          "externalChange": true
        }
        """ + "\n"
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            beforeConfigurationInstallForTesting: {
                try externallyCreated.write(to: configURL, atomically: true, encoding: .utf8)
            }
        )
        let preview = try registrar.registrationPreview(
            for: .claudeDesktop,
            commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
            destinationURL: configURL
        )
        #expect(!preview.configurationSnapshot.exists)

        #expect(throws: MCPClientRegistrationRegistryError.previewChanged) {
            try registrar.register(preview)
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == externallyCreated)
        #expect(
            try registrar.registrationRegistry.record(for: configURL)?.registrationID
                == preview.registration.registrationID
        )
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: configURL.deletingLastPathComponent().path
        )
        #expect(!siblingNames.contains { $0.contains(".jts-private-") })
    }

    @Test func mcpClientRegistrationRestoresExistingConfigAfterInstalledPermissionsDrift() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-terminal-mcp-existing-post-install-permissions-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/codex.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = "model = \"gpt-5.5\"\nselected_profile = \"original\"\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            afterConfigurationInstallForTesting: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: configURL.path
                )
            }
        )
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
            destinationURL: configURL
        )

        #expect(throws: MCPClientRegistrationError.self) {
            try registrar.register(preview)
        }
        let stored = try String(contentsOf: configURL, encoding: .utf8)
        #expect(stored == original)
        #expect(!stored.contains(preview.registration.registrationID))
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: configURL.deletingLastPathComponent().path
        )
        #expect(!siblingNames.contains { $0.contains(".jts-private-") })
    }

    @Test func mcpClientRegistrationRemovesNewConfigAfterInstalledPermissionsDrift() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-terminal-mcp-missing-post-install-permissions-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/claude.json")
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            afterConfigurationInstallForTesting: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: configURL.path
                )
            }
        )
        let preview = try registrar.registrationPreview(
            for: .claudeDesktop,
            commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal",
            destinationURL: configURL
        )
        #expect(!preview.configurationSnapshot.exists)

        #expect(throws: MCPClientRegistrationError.self) {
            try registrar.register(preview)
        }
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: configURL.deletingLastPathComponent().path
        )
        #expect(!siblingNames.contains { $0.contains(".jts-private-") })
    }

    @Test func mcpClientRegistrationReusesDormantRecordAfterPostActivationDrift() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-post-activation-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let configURL = root.appendingPathComponent("selected/claude.json")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = """
        {
          "theme": "light"
        }
        """ + "\n"
        let externallyChanged = """
        {
          "theme": "dark",
          "externalChange": true
        }
        """ + "\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        var didReachPostActivationHook = false
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL,
            afterRegistrationActivationForTesting: {
                didReachPostActivationHook = true
                try externallyChanged.write(to: configURL, atomically: true, encoding: .utf8)
            }
        )
        let commandPath = "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal"
        let preview = try registrar.registrationPreview(
            for: .claudeDesktop,
            commandPath: commandPath,
            destinationURL: configURL
        )

        #expect(throws: MCPClientRegistrationRegistryError.previewChanged) {
            try registrar.register(preview)
        }
        #expect(didReachPostActivationHook)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == externallyChanged)
        let loadedDormantRecord = try registrar.registrationRegistry.record(for: configURL)
        let dormantRecord = try #require(loadedDormantRecord)
        #expect(dormantRecord.registrationID == preview.registration.registrationID)

        let retryRegistrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL
        )
        let refreshed = try retryRegistrar.registrationPreview(
            for: .claudeDesktop,
            commandPath: commandPath,
            destinationURL: configURL
        )
        #expect(refreshed.registration.registrationID == preview.registration.registrationID)

        _ = try retryRegistrar.register(refreshed)
        let storedData = try Data(contentsOf: configURL)
        let stored = try #require(
            JSONSerialization.jsonObject(with: storedData) as? [String: Any]
        )
        #expect(stored["theme"] as? String == "dark")
        #expect(stored["externalChange"] as? Bool == true)
        let storedServers = try #require(stored["mcpServers"] as? [String: Any])
        let storedJTS = try #require(
            storedServers[MCPClientRegistrar.serverName] as? [String: Any]
        )
        #expect(storedJTS["command"] as? String == commandPath)
    }

    @Test func mcpClientRegistrationRejectsStaleJSONPreviewWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-stale-json-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("security/registrations.json")
        let registrar = MCPClientRegistrar(
            homeDirectory: root,
            registrationRegistryURL: registryURL
        )
        let selectedURL = root.appendingPathComponent("selected/claude.json")
        let commandPath = "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal"
        let preview = try registrar.registrationPreview(
            for: .claudeDesktop,
            commandPath: commandPath,
            destinationURL: selectedURL
        )
        #expect(!preview.configurationSnapshot.exists)
        #expect(preview.configurationSnapshot.byteCount == 0)
        #expect(preview.configurationSnapshot.sha256 == testSHA256Hex(Data()))

        try FileManager.default.createDirectory(
            at: selectedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let externallyCreated = """
        {
          "theme": "dark",
          "mcpServers": {
            "existing": {
              "type": "stdio",
              "command": "/bin/echo",
              "args": ["ok"]
            }
          }
        }
        """ + "\n"
        try externallyCreated.write(to: selectedURL, atomically: true, encoding: .utf8)

        #expect(throws: MCPClientRegistrationRegistryError.previewChanged) {
            try registrar.register(preview)
        }
        #expect(try String(contentsOf: selectedURL, encoding: .utf8) == externallyCreated)
        #expect(!FileManager.default.fileExists(atPath: registryURL.path))

        let refreshed = try registrar.registrationPreview(
            for: .claudeDesktop,
            commandPath: commandPath,
            destinationURL: selectedURL
        )
        #expect(refreshed.destinationURL == selectedURL)
        #expect(refreshed.configurationSnapshot.exists)
        #expect(refreshed.configurationSnapshot.sha256 == testSHA256Hex(Data(externallyCreated.utf8)))
        #expect(refreshed.configurationSnapshot != preview.configurationSnapshot)
        #expect(refreshed.focusedDiff.contains("Target: \(selectedURL.path)"))

        _ = try registrar.register(refreshed)
        let storedData = try Data(contentsOf: selectedURL)
        let rootObject = try #require(
            JSONSerialization.jsonObject(with: storedData) as? [String: Any]
        )
        let servers = try #require(rootObject["mcpServers"] as? [String: Any])
        #expect(rootObject["theme"] as? String == "dark")
        #expect((servers["existing"] as? [String: Any])?["command"] as? String == "/bin/echo")
        #expect((servers[MCPClientRegistrar.serverName] as? [String: Any])?["command"] as? String == commandPath)
    }

    @Test func mcpClientRegistrarMergesCodexClaudeAndAntigravityConfigs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-registrar-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let registrar = MCPClientRegistrar(homeDirectory: root)
        let codexURL = registrar.codexConfigURL
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        model = "gpt-5.5"

        [mcp_servers.existing]
        command = "/bin/echo"
        args = ["ok"]

        [projects."/tmp/example"]
        trust_level = "trusted"
        """.write(to: codexURL, atomically: true, encoding: .utf8)

        let codexResult = try registrar.registerCodex(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let codexConfig = try String(contentsOf: codexURL, encoding: .utf8)

        #expect(codexResult.client == .codexDesktop)
        #expect(codexConfig.contains("[mcp_servers.existing]"))
        #expect(codexConfig.contains("[projects.\"/tmp/example\"]"))
        #expect(codexConfig.contains("[mcp_servers.jts-terminal]"))
        #expect(codexConfig.contains("command = \(MCPClientRegistrar.tomlStringLiteral("/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal"))"))
        #expect(codexConfig.contains("args = [\"--mcp\", \"--mcp-client-registration\", \"\(codexResult.registrationID)\"]"))
        #expect(codexConfig.components(separatedBy: "[mcp_servers.jts-terminal]").count - 1 == 1)

        _ = try registrar.registerCodex(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let codexConfigAfterSecondRegister = try String(contentsOf: codexURL, encoding: .utf8)
        #expect(codexConfigAfterSecondRegister.components(separatedBy: "[mcp_servers.jts-terminal]").count - 1 == 1)

        try """
        [mcp_servers.jts-terminal]
        command = "/tmp/old"
        args = ["--old"]

        [mcp_servers.jts-terminal]
        command = "/tmp/duplicate"
        args = ["--duplicate"]
        """.write(to: codexURL, atomically: true, encoding: .utf8)
        _ = try registrar.registerCodex(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let deduplicatedCodexConfig = try String(contentsOf: codexURL, encoding: .utf8)
        #expect(deduplicatedCodexConfig.components(separatedBy: "[mcp_servers.jts-terminal]").count - 1 == 1)
        #expect(!deduplicatedCodexConfig.contains("/tmp/duplicate"))

        let claudeURL = registrar.claudeDesktopConfigURL
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"mcpServers":{"existing":{"type":"stdio","command":"/bin/echo","args":["ok"]}}}"#
            .write(to: claudeURL, atomically: true, encoding: .utf8)

        let claudeResult = try registrar.registerClaudeDesktop(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let claudeData = try Data(contentsOf: claudeURL)
        let claudeRoot = try #require(JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
        let claudeServers = try #require(claudeRoot["mcpServers"] as? [String: Any])
        let claudeExisting = try #require(claudeServers["existing"] as? [String: Any])
        let claudeJTS = try #require(claudeServers["jts-terminal"] as? [String: Any])

        #expect(claudeResult.client == .claudeDesktop)
        #expect(claudeExisting["command"] as? String == "/bin/echo")
        #expect(claudeJTS["type"] as? String == "stdio")
        #expect(claudeJTS["command"] as? String == "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        #expect(claudeJTS["args"] as? [String] == MCPClientRegistrar.arguments(registrationID: claudeResult.registrationID))
        let claudeConfig = try #require(String(data: claudeData, encoding: .utf8))
        #expect(occurrenceCount(of: #""jts-terminal""#, in: claudeConfig) == 1)

        _ = try registrar.registerClaudeDesktop(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let claudeConfigAfterSecondRegister = try String(contentsOf: claudeURL, encoding: .utf8)
        #expect(occurrenceCount(of: #""jts-terminal""#, in: claudeConfigAfterSecondRegister) == 1)

        try #"{"mcpServers":{"jts-terminal":{"type":"stdio","command":"/tmp/old","args":["--old"]},"jts-terminal":{"type":"stdio","command":"/tmp/duplicate","args":["--duplicate"]}}}"#
            .write(to: claudeURL, atomically: true, encoding: .utf8)
        _ = try registrar.registerClaudeDesktop(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let deduplicatedClaudeConfig = try String(contentsOf: claudeURL, encoding: .utf8)
        #expect(occurrenceCount(of: #""jts-terminal""#, in: deduplicatedClaudeConfig) == 1)
        #expect(!deduplicatedClaudeConfig.contains("/tmp/duplicate"))

        let antigravityURL = registrar.antigravityConfigURL
        try FileManager.default.createDirectory(
            at: antigravityURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"mcpServers":{"existing":{"command":"/bin/echo","args":["ok"]}}}"#
            .write(to: antigravityURL, atomically: true, encoding: .utf8)

        let antigravityResult = try registrar.registerAntigravity(commandPath: "/tmp/JTS Terminal")
        let antigravityData = try Data(contentsOf: antigravityURL)
        let antigravityRoot = try #require(JSONSerialization.jsonObject(with: antigravityData) as? [String: Any])
        let servers = try #require(antigravityRoot["mcpServers"] as? [String: Any])
        let existing = try #require(servers["existing"] as? [String: Any])
        let jts = try #require(servers["jts-terminal"] as? [String: Any])

        #expect(antigravityResult.client == .antigravity)
        #expect(existing["command"] as? String == "/bin/echo")
        #expect(jts["command"] as? String == "/tmp/JTS Terminal")
        #expect(jts["args"] as? [String] == MCPClientRegistrar.arguments(registrationID: antigravityResult.registrationID))
        let antigravityConfig = try #require(String(data: antigravityData, encoding: .utf8))
        #expect(occurrenceCount(of: #""jts-terminal""#, in: antigravityConfig) == 1)

        _ = try registrar.registerAntigravity(commandPath: "/tmp/JTS Terminal")
        let antigravityConfigAfterSecondRegister = try String(contentsOf: antigravityURL, encoding: .utf8)
        #expect(occurrenceCount(of: #""jts-terminal""#, in: antigravityConfigAfterSecondRegister) == 1)

        try #"{"mcpServers":{"jts-terminal":{"command":"/tmp/old","args":["--old"]},"jts-terminal":{"command":"/tmp/duplicate","args":["--duplicate"]}}}"#
            .write(to: antigravityURL, atomically: true, encoding: .utf8)
        _ = try registrar.registerAntigravity(commandPath: "/tmp/JTS Terminal")
        let deduplicatedAntigravityConfig = try String(contentsOf: antigravityURL, encoding: .utf8)
        #expect(occurrenceCount(of: #""jts-terminal""#, in: deduplicatedAntigravityConfig) == 1)
        #expect(!deduplicatedAntigravityConfig.contains("/tmp/duplicate"))

        let cursorURL = registrar.cursorConfigURL
        try FileManager.default.createDirectory(
            at: cursorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"mcpServers":{"existing":{"command":"/bin/echo","args":["ok"]}}}"#
            .write(to: cursorURL, atomically: true, encoding: .utf8)

        let cursorResult = try registrar.registerCursor(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let cursorData = try Data(contentsOf: cursorURL)
        let cursorRoot = try #require(JSONSerialization.jsonObject(with: cursorData) as? [String: Any])
        let cursorServers = try #require(cursorRoot["mcpServers"] as? [String: Any])
        let cursorExisting = try #require(cursorServers["existing"] as? [String: Any])
        let cursorJTS = try #require(cursorServers["jts-terminal"] as? [String: Any])

        #expect(cursorResult.client == .cursor)
        #expect(cursorResult.configPath == cursorURL.path)
        #expect(cursorExisting["command"] as? String == "/bin/echo")
        #expect(cursorJTS["type"] as? String == "stdio")
        #expect(cursorJTS["command"] as? String == "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        #expect(cursorJTS["args"] as? [String] == MCPClientRegistrar.arguments(registrationID: cursorResult.registrationID))
        let cursorConfig = try #require(String(data: cursorData, encoding: .utf8))
        #expect(occurrenceCount(of: #""jts-terminal""#, in: cursorConfig) == 1)

        _ = try registrar.registerCursor(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let cursorConfigAfterSecondRegister = try String(contentsOf: cursorURL, encoding: .utf8)
        #expect(occurrenceCount(of: #""jts-terminal""#, in: cursorConfigAfterSecondRegister) == 1)

        try #"{"mcpServers":{"jts-terminal":{"type":"stdio","command":"/tmp/old","args":["--old"]},"jts-terminal":{"type":"stdio","command":"/tmp/duplicate","args":["--duplicate"]}}}"#
            .write(to: cursorURL, atomically: true, encoding: .utf8)
        _ = try registrar.registerCursor(commandPath: "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal")
        let deduplicatedCursorConfig = try String(contentsOf: cursorURL, encoding: .utf8)
        #expect(occurrenceCount(of: #""jts-terminal""#, in: deduplicatedCursorConfig) == 1)
        #expect(!deduplicatedCursorConfig.contains("/tmp/duplicate"))
        #expect(!FileManager.default.fileExists(atPath: root
            .appendingPathComponent("Library/Application Support/JTS Terminal/MCP/jts-terminal-mcp-proxy")
            .path))
    }

    @Test func mcpClientRegistrarRegistersClaudeCLIAndCodexCLI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-cli-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let registrar = MCPClientRegistrar(homeDirectory: root)
        let commandPath = try makeFakeJTSExecutable(
            in: root.appendingPathComponent("Installed", isDirectory: true)
        )

        // Seed ~/.claude.json with unrelated keys plus an existing MCP server, to
        // confirm registration merges into mcpServers instead of clobbering the file.
        let claudeURL = registrar.claudeCLIConfigURL
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "theme": "dark",
          "numStartups": 42,
          "mcpServers": {
            "existing": {
              "type": "stdio",
              "command": "/bin/echo",
              "args": ["ok"]
            }
          },
          "projects": {
            "/tmp/example": {
              "trusted": true
            }
          }
        }
        """.write(to: claudeURL, atomically: true, encoding: .utf8)

        let claudeResult = try registrar.registerClaudeCLI(commandPath: commandPath)
        let claudeData = try Data(contentsOf: claudeURL)
        let claudeRoot = try #require(JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
        let claudeServers = try #require(claudeRoot["mcpServers"] as? [String: Any])
        let claudeExisting = try #require(claudeServers["existing"] as? [String: Any])
        let claudeJTS = try #require(claudeServers["jts-terminal"] as? [String: Any])

        #expect(claudeResult.client == .claudeCLI)
        #expect(claudeResult.configPath == claudeURL.path)
        #expect(claudeRoot["theme"] as? String == "dark")
        #expect(claudeRoot["numStartups"] as? Int == 42)
        #expect(claudeExisting["command"] as? String == "/bin/echo")
        #expect(claudeJTS["type"] as? String == "stdio")
        #expect(claudeJTS["command"] as? String == commandPath)
        #expect(claudeJTS["args"] as? [String] == MCPClientRegistrar.arguments(registrationID: claudeResult.registrationID))
        #expect((claudeRoot["projects"] as? [String: Any])?["/tmp/example"] != nil)
        let claudeConfig = try #require(String(data: claudeData, encoding: .utf8))
        #expect(occurrenceCount(of: #""jts-terminal""#, in: claudeConfig) == 1)

        // Re-registering must not duplicate the entry or drop unrelated keys.
        _ = try registrar.registerClaudeCLI(commandPath: commandPath)
        let claudeConfigAfterSecondRegister = try String(contentsOf: claudeURL, encoding: .utf8)
        #expect(occurrenceCount(of: #""jts-terminal""#, in: claudeConfigAfterSecondRegister) == 1)
        let claudeRootAfterSecond = try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: claudeURL)) as? [String: Any])
        #expect(claudeRootAfterSecond["theme"] as? String == "dark")
        #expect(claudeRootAfterSecond["numStartups"] as? Int == 42)

        #expect(registrar.registrationStatus(for: .claudeCLI, commandPath: commandPath).state == .registered)

        // Codex CLI writes the same ~/.codex/config.toml as Codex Desktop.
        let codexURL = registrar.codexConfigURL
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        model = "gpt-5.5"

        [mcp_servers.existing]
        command = "/bin/echo"
        args = ["ok"]
        """.write(to: codexURL, atomically: true, encoding: .utf8)

        let codexResult = try registrar.registerCodexCLI(commandPath: commandPath)
        let codexConfig = try String(contentsOf: codexURL, encoding: .utf8)

        #expect(codexResult.client == .codexCLI)
        #expect(codexResult.configPath == codexURL.path)
        #expect(codexConfig.contains("model = \"gpt-5.5\""))
        #expect(codexConfig.contains("[mcp_servers.existing]"))
        #expect(codexConfig.contains("[mcp_servers.jts-terminal]"))
        #expect(codexConfig.contains("command = \(MCPClientRegistrar.tomlStringLiteral(commandPath))"))
        #expect(codexConfig.contains("args = [\"--mcp\", \"--mcp-client-registration\", \"\(codexResult.registrationID)\"]"))
        #expect(codexConfig.components(separatedBy: "[mcp_servers.jts-terminal]").count - 1 == 1)

        // Both codex entries read the shared file, so both report registered.
        #expect(registrar.registrationStatus(for: .codexCLI, commandPath: commandPath).state == .registered)
        #expect(registrar.registrationStatus(for: .codexDesktop, commandPath: commandPath).state == .registered)

        // A stale codex config flips both codex entries to needsUpdate (shared file).
        try """
        [mcp_servers.jts-terminal]
        command = "/tmp/old"
        args = []
        """.write(to: codexURL, atomically: true, encoding: .utf8)
        #expect(registrar.registrationStatus(for: .codexCLI, commandPath: commandPath).state == .needsUpdate)
        #expect(registrar.registrationStatus(for: .codexDesktop, commandPath: commandPath).state == .needsUpdate)

        // Grok CLI uses its own ~/.grok/config.toml TOML endpoint.
        let grokURL = registrar.grokCLIConfigURL
        try FileManager.default.createDirectory(
            at: grokURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [cli]
        installer = "internal"

        [mcp_servers.existing]
        command = "/bin/echo"
        args = ["ok"]
        enabled = true
        """.write(to: grokURL, atomically: true, encoding: .utf8)

        let grokResult = try registrar.registerGrokCLI(commandPath: commandPath)
        let grokConfig = try String(contentsOf: grokURL, encoding: .utf8)

        #expect(grokResult.client == .grokCLI)
        #expect(grokResult.configPath == grokURL.path)
        #expect(grokConfig.contains("[cli]"))
        #expect(grokConfig.contains("installer = \"internal\""))
        #expect(grokConfig.contains("[mcp_servers.existing]"))
        #expect(grokConfig.contains("[mcp_servers.jts-terminal]"))
        #expect(grokConfig.contains("command = \(MCPClientRegistrar.tomlStringLiteral(commandPath))"))
        #expect(grokConfig.contains("args = [\"--mcp\", \"--mcp-client-registration\", \"\(grokResult.registrationID)\"]"))
        #expect(grokConfig.components(separatedBy: "[mcp_servers.jts-terminal]").count - 1 == 1)
        #expect(registrar.registrationStatus(for: .grokCLI, commandPath: commandPath).state == .registered)

        // Re-register must not duplicate the Grok section or drop unrelated keys.
        _ = try registrar.registerGrokCLI(commandPath: commandPath)
        let grokConfigAfterSecondRegister = try String(contentsOf: grokURL, encoding: .utf8)
        #expect(grokConfigAfterSecondRegister.components(separatedBy: "[mcp_servers.jts-terminal]").count - 1 == 1)
        #expect(grokConfigAfterSecondRegister.contains("[cli]"))
        #expect(grokConfigAfterSecondRegister.contains("[mcp_servers.existing]"))

        // Grok is a distinct physical endpoint from Codex.
        #expect(MCPClientKind.grokCLI.configurationEndpoint != .codex)
        #expect(registrar.defaultConfigURL(for: .grokCLI) != registrar.defaultConfigURL(for: .codexCLI))

        // Cursor uses its own ~/.cursor/mcp.json JSON endpoint.
        let cursorURL = registrar.cursorConfigURL
        try FileManager.default.createDirectory(
            at: cursorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "mcpServers": {
            "existing": {
              "command": "/bin/echo",
              "args": ["ok"]
            }
          }
        }
        """.write(to: cursorURL, atomically: true, encoding: .utf8)

        let cursorResult = try registrar.registerCursor(commandPath: commandPath)
        let cursorData = try Data(contentsOf: cursorURL)
        let cursorRoot = try #require(JSONSerialization.jsonObject(with: cursorData) as? [String: Any])
        let cursorServers = try #require(cursorRoot["mcpServers"] as? [String: Any])
        let cursorExisting = try #require(cursorServers["existing"] as? [String: Any])
        let cursorJTS = try #require(cursorServers["jts-terminal"] as? [String: Any])

        #expect(cursorResult.client == .cursor)
        #expect(cursorResult.configPath == cursorURL.path)
        #expect(cursorExisting["command"] as? String == "/bin/echo")
        #expect(cursorJTS["type"] as? String == "stdio")
        #expect(cursorJTS["command"] as? String == commandPath)
        #expect(cursorJTS["args"] as? [String] == MCPClientRegistrar.arguments(registrationID: cursorResult.registrationID))
        #expect(registrar.registrationStatus(for: .cursor, commandPath: commandPath).state == .registered)
        #expect(MCPClientKind.cursor.configurationEndpoint == .cursor)
        #expect(registrar.defaultConfigURL(for: .cursor) != registrar.defaultConfigURL(for: .claudeCLI))
    }

    @Test func mcpClientRegistrarRestrictsExistingConfigBeforeWritingRegistrationIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-permissions-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let registrar = MCPClientRegistrar(homeDirectory: root)
        let commandPath = try makeFakeJTSExecutable(
            in: root.appendingPathComponent("Installed", isDirectory: true)
        )
        let configURL = registrar.codexConfigURL
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "model = \"gpt-5.5\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: configURL.path
        )

        let result = try registrar.registerCodexCLI(commandPath: commandPath)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
        )
        let stored = try String(contentsOf: configURL, encoding: .utf8)

        #expect(permissions.intValue & 0o777 == 0o600)
        #expect(stored.contains(result.registrationID))
    }

    @Test func mcpClientConfigurationBuildsAppLevelStdioConfig() async throws {
        #expect(
            MCPClientRegistrar.allowsUnregisteredDirectConfiguration
                == !AppReleasePolicy.includesNativeRDP
        )
        let commandPath = "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal"
        let text = MCPClientConfiguration.stdioJSONText(
            commandPath: commandPath,
            arguments: MCPClientRegistrar.directArguments
        )
        let object = try decodedJSONObject(text)
        let servers = try #require(object["mcpServers"] as? [String: Any])
        let jts = try #require(servers[MCPClientRegistrar.serverName] as? [String: Any])

        #expect(jts["type"] as? String == "stdio")
        #expect(jts["command"] as? String == commandPath)
        #expect(jts["args"] as? [String] == ["--mcp"])
    }

    @Test func mcpClientDefaultConfigurationPathsAndEndpointSharingAreCanonical() {
        let root = URL(
            fileURLWithPath: "/Users/example",
            isDirectory: true
        )
        let registrar = MCPClientRegistrar(homeDirectory: root)

        #expect(
            registrar.defaultConfigURL(for: .codexDesktop).path
                == "/Users/example/.codex/config.toml"
        )
        #expect(
            registrar.defaultConfigURL(for: .codexCLI)
                == registrar.defaultConfigURL(for: .codexDesktop)
        )
        #expect(
            registrar.defaultConfigURL(for: .claudeDesktop).path
                == "/Users/example/Library/Application Support/Claude/claude_desktop_config.json"
        )
        #expect(
            registrar.defaultConfigURL(for: .claudeCLI).path
                == "/Users/example/.claude.json"
        )
        #expect(
            registrar.defaultConfigURL(for: .antigravity).path
                == "/Users/example/.gemini/antigravity/mcp_config.json"
        )
        #expect(
            registrar.defaultConfigURL(for: .grokCLI).path
                == "/Users/example/.grok/config.toml"
        )
        #expect(
            registrar.defaultConfigURL(for: .cursor).path
                == "/Users/example/.cursor/mcp.json"
        )

        let endpointURLs = MCPClientKind.registrationDisplayOrder.map {
            registrar.defaultConfigURL(for: $0)
        }
        #expect(Set(endpointURLs.map(\.path)).count == 6)
        #expect(MCPClientKind.codexDesktop.configurationEndpoint == .codex)
        #expect(MCPClientKind.codexCLI.configurationEndpoint == .codex)
        #expect(MCPClientKind.grokCLI.configurationEndpoint == .grok)
        #expect(MCPClientKind.cursor.configurationEndpoint == .cursor)
        #expect(
            MCPClientKind.claudeDesktop.configurationEndpoint
                != MCPClientKind.claudeCLI.configurationEndpoint
        )
        #expect(
            registrar.canonicalConfigurationDirectoryURL(
                for: .codexDesktop
            ).path == "/Users/example/.codex"
        )
        #expect(
            registrar.canonicalConfigurationDirectoryURL(
                for: .grokCLI
            ).path == "/Users/example/.grok"
        )
        #expect(
            registrar.canonicalConfigurationDirectoryURL(
                for: .cursor
            ).path == "/Users/example/.cursor"
        )
    }

    @Test func mcpClientRegistrationStatusReportsMissingRegisteredStaleAndInvalidConfigs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-status-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let registrar = MCPClientRegistrar(homeDirectory: root)
        let commandPath = try makeFakeJTSExecutable(
            in: root.appendingPathComponent("Installed", isDirectory: true)
        )
        let missingStatuses = registrar.registrationStatuses(commandPath: commandPath)
        #expect(missingStatuses.map(\.client) == MCPClientKind.registrationDisplayOrder)
        #expect(missingStatuses.map(\.state) == Array(repeating: .notRegistered, count: MCPClientKind.registrationDisplayOrder.count))

        for client in MCPClientKind.registrationDisplayOrder {
            _ = try registrar.register(client, commandPath: commandPath)
        }

        let registeredStatuses = registrar.registrationStatuses(commandPath: commandPath)
        #expect(registeredStatuses.map(\.state) == Array(repeating: .registered, count: MCPClientKind.registrationDisplayOrder.count))

        try """
        [mcp_servers.jts-terminal]
        command = "/tmp/old"
        args = []
        """.write(to: registrar.codexConfigURL, atomically: true, encoding: .utf8)

        var codexStatus = registrar.registrationStatus(for: .codexDesktop, commandPath: commandPath)
        #expect(codexStatus.state == .needsUpdate)

        try #"{"mcpServers":{"jts-terminal":{"type":"stdio","command":"/tmp/old","args":[]}}}"#
            .write(to: registrar.claudeDesktopConfigURL, atomically: true, encoding: .utf8)
        let claudeStatus = registrar.registrationStatus(for: .claudeDesktop, commandPath: commandPath)
        #expect(claudeStatus.state == .needsUpdate)

        try #"{"mcpServers":{"existing":{"command":"/bin/echo","args":["ok"]}}}"#
            .write(to: registrar.antigravityConfigURL, atomically: true, encoding: .utf8)
        let antigravityStatus = registrar.registrationStatus(for: .antigravity, commandPath: commandPath)
        #expect(antigravityStatus.state == .notRegistered)

        try #"{"mcpServers":{"existing":{"command":"/bin/echo","args":["ok"]}}}"#
            .write(to: registrar.cursorConfigURL, atomically: true, encoding: .utf8)
        let cursorStatus = registrar.registrationStatus(for: .cursor, commandPath: commandPath)
        #expect(cursorStatus.state == .notRegistered)

        _ = try registrar.registerCodex(commandPath: commandPath)
        codexStatus = registrar.registrationStatus(for: .codexDesktop, commandPath: commandPath)
        #expect(codexStatus.state == .registered)

        let storedRegistration = try registrar.registrationRegistry.record(for: registrar.codexConfigURL)
        let registration = try #require(storedRegistration)
        let exactArgs = MCPClientRegistrar.arguments(registrationID: registration.registrationID)
            .map(MCPClientRegistrar.tomlStringLiteral)
            .joined(separator: ", ")
        try """
        [mcp_servers.jts-terminal]
        command = \(MCPClientRegistrar.tomlStringLiteral(commandPath))
        args = [\(exactArgs)]
        """.write(to: registrar.codexConfigURL, atomically: true, encoding: .utf8)
        #expect(registrar.registrationStatus(for: .codexDesktop, commandPath: commandPath).state == .registered)

        try """
        [mcp_servers.jts-terminal]
        command = \(MCPClientRegistrar.tomlStringLiteral(commandPath))
        args = []
        """.write(to: registrar.codexConfigURL, atomically: true, encoding: .utf8)
        #expect(registrar.registrationStatus(for: .codexDesktop, commandPath: commandPath).state == .needsUpdate)

        try #"{invalid-json"#.write(to: registrar.claudeDesktopConfigURL, atomically: true, encoding: .utf8)
        let invalidClaudeStatus = registrar.registrationStatus(for: .claudeDesktop, commandPath: commandPath)
        let isInvalidConfiguration: Bool
        if case .invalidConfiguration = invalidClaudeStatus.state {
            isInvalidConfiguration = true
        } else {
            isInvalidConfiguration = false
        }
        #expect(isInvalidConfiguration)
    }

    @Test func mcpClientRegistrationStatusRequiresCurrentDirectExecutablePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-proxy-path-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let registrar = MCPClientRegistrar(homeDirectory: root)
        let registeredCommandPath = try makeFakeJTSExecutable(in: root.appendingPathComponent("Registered", isDirectory: true))
        let currentCommandPath = root
            .appendingPathComponent("Current", isDirectory: true)
            .appendingPathComponent("JTS Terminal.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("JTS Terminal")
            .path

        for client in MCPClientKind.registrationDisplayOrder {
            _ = try registrar.register(client, commandPath: registeredCommandPath)
        }

        let registeredStatuses = registrar.registrationStatuses(commandPath: registeredCommandPath)
        #expect(registeredStatuses.map(\.state) == Array(repeating: .registered, count: MCPClientKind.registrationDisplayOrder.count))

        let movedStatuses = registrar.registrationStatuses(commandPath: currentCommandPath)
        #expect(movedStatuses.map(\.state) == Array(repeating: .needsUpdate, count: MCPClientKind.registrationDisplayOrder.count))

        try """
        [mcp_servers.jts-terminal]
        command = "/tmp/missing-jts-terminal"
        args = []
        """.write(to: registrar.codexConfigURL, atomically: true, encoding: .utf8)
        #expect(registrar.registrationStatus(for: .codexDesktop, commandPath: currentCommandPath).state == .needsUpdate)

        try #"""
        {"mcpServers":{"jts-terminal":{"command":"/tmp/other-proxy","args":[]}}}
        """#.write(to: registrar.antigravityConfigURL, atomically: true, encoding: .utf8)
        #expect(registrar.registrationStatus(for: .antigravity, commandPath: currentCommandPath).state == .needsUpdate)
    }

    @Test func mcpClientRegistrationStatusRejectsLegacyAlternateBookmarkAcrossRegistrarInstances() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-terminal-mcp-selected-config-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let suiteName = "com.lljts.JTSTerminalTests.mcp-access.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let accessStore = MCPClientConfigurationAccessStore(defaults: defaults)
        let sandboxHome = root.appendingPathComponent("SandboxHome", isDirectory: true)
        let selectedConfigURL = root
            .appendingPathComponent("AccountHome", isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: selectedConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "model = \"gpt-5.5\"\n".write(
            to: selectedConfigURL,
            atomically: true,
            encoding: .utf8
        )
        let registryURL = root
            .appendingPathComponent("Private", isDirectory: true)
            .appendingPathComponent("mcp-client-registrations-v1.json")
        let commandPath = try makeFakeJTSExecutable(
            in: root.appendingPathComponent("Installed", isDirectory: true)
        )

        let registrar = MCPClientRegistrar(
            homeDirectory: sandboxHome,
            registrationRegistryURL: registryURL,
            configurationAccessStore: accessStore
        )
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: commandPath,
            destinationURL: selectedConfigURL
        )
        _ = try registrar.register(preview)
        let preparedAccess = try accessStore.prepareAccess(
            for: .codexDesktop,
            configurationURL: selectedConfigURL,
            scopeURL: selectedConfigURL.deletingLastPathComponent()
        )
        try accessStore.persist(preparedAccess)

        let relaunchedRegistrar = MCPClientRegistrar(
            homeDirectory: sandboxHome,
            registrationRegistryURL: registryURL,
            configurationAccessStore: MCPClientConfigurationAccessStore(
                defaults: defaults
            )
        )
        #expect(relaunchedRegistrar.codexConfigURL.path != selectedConfigURL.path)

        let desktopStatus = relaunchedRegistrar.registrationStatus(
            for: .codexDesktop,
            commandPath: commandPath
        )
        let cliStatus = relaunchedRegistrar.registrationStatus(
            for: .codexCLI,
            commandPath: commandPath
        )
        #expect(desktopStatus.state == .notRegistered)
        #expect(
            desktopStatus.configPath
                == relaunchedRegistrar.codexConfigURL
                    .standardizedFileURL.path
        )
        #expect(cliStatus.state == .notRegistered)
        #expect(cliStatus.configPath == desktopStatus.configPath)
    }

    @Test func mcpClientRegistrationStatusUsesCompletedInstallEvidenceWithoutBookmark() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-terminal-mcp-access-required-\(UUID().uuidString)",
                isDirectory: true
            )
        let accountHome = root.appendingPathComponent(
            "AccountHome",
            isDirectory: true
        )
        let configurationDirectory = accountHome.appendingPathComponent(
            ".codex",
            isDirectory: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: configurationDirectory.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let selectedConfigURL = configurationDirectory
            .appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: configurationDirectory,
            withIntermediateDirectories: true
        )
        let registryURL = root
            .appendingPathComponent("Private", isDirectory: true)
            .appendingPathComponent("mcp-client-registrations-v1.json")
        let commandPath = try makeFakeJTSExecutable(
            in: root.appendingPathComponent("Installed", isDirectory: true)
        )
        let registrar = MCPClientRegistrar(
            homeDirectory: accountHome,
            registrationRegistryURL: registryURL
        )
        _ = try registrar.register(
            .codexDesktop,
            commandPath: commandPath,
            destinationURL: selectedConfigURL
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: configurationDirectory.path
        )

        let status = registrar.registrationStatus(
            for: .codexDesktop,
            commandPath: commandPath
        )
        #expect(status.state == .registered)
        #expect(status.verification == .completedInstall)
        #expect(status.configPath == selectedConfigURL.path)
    }

    @Test func mcpClientLegacyRegistryWithoutInstallOrRuntimeEvidenceStillRequiresAccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-terminal-mcp-dormant-registry-\(UUID().uuidString)",
                isDirectory: true
            )
        let accountHome = root.appendingPathComponent(
            "AccountHome",
            isDirectory: true
        )
        let configurationDirectory = accountHome.appendingPathComponent(
            ".codex",
            isDirectory: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: configurationDirectory.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let selectedConfigURL = configurationDirectory
            .appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: configurationDirectory,
            withIntermediateDirectories: true
        )
        let registryURL = root
            .appendingPathComponent("Private", isDirectory: true)
            .appendingPathComponent("mcp-client-registrations-v1.json")
        let commandPath = try makeFakeJTSExecutable(
            in: root.appendingPathComponent("Installed", isDirectory: true)
        )
        let registrar = MCPClientRegistrar(
            homeDirectory: accountHome,
            registrationRegistryURL: registryURL
        )
        let preview = try registrar.registrationPreview(
            for: .codexDesktop,
            commandPath: commandPath,
            destinationURL: selectedConfigURL
        )
        try registrar.activateRegistration(preview)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: configurationDirectory.path
        )

        let dormantStatus = registrar.registrationStatus(
            for: .codexDesktop,
            commandPath: commandPath
        )
        #expect(dormantStatus.state == .accessRequired)
        #expect(dormantStatus.verification == nil)
        #expect(dormantStatus.configPath == selectedConfigURL.path)

        try registrar.recordObservedRuntime(
            registration: preview.registration,
            commandPath: commandPath
        )
        let observedStatus = registrar.registrationStatus(
            for: .codexCLI,
            commandPath: commandPath
        )
        #expect(observedStatus.state == .registered)
        #expect(observedStatus.verification == .observedRuntime)
        #expect(observedStatus.configPath == selectedConfigURL.path)
    }

    @Test func mcpClientConfigurationAccessBookmarksCanonicalDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-terminal-mcp-new-config-access-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let suiteName = "com.lljts.JTSTerminalTests.mcp-new-access.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = MCPClientConfigurationAccessStore(defaults: defaults)
        let configURL = root.appendingPathComponent("config.toml")
        try "{}\n".write(to: configURL, atomically: true, encoding: .utf8)
        let prepared = try store.prepareAccess(
            for: .claudeDesktop,
            configurationURL: configURL,
            scopeURL: root
        )
        try store.persist(prepared)

        let result = store.withAccess(for: .claudeDesktop) {
            $0.standardizedFileURL.path
        }
        guard case .value(let restoredPath) = result else {
            Issue.record("Expected the canonical directory bookmark to reconstruct the config path")
            return
        }
        #expect(restoredPath == configURL.standardizedFileURL.path)

        try store.removeAccess(for: .claudeDesktop)
        #expect(store.storedPath(for: .claudeDesktop) == nil)
    }

    @Test func mcpClientRegistrationAcceptsOnlyCanonicalConfigurationDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-terminal-mcp-canonical-scope-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let canonicalDirectory = root.appendingPathComponent(
            ".codex",
            isDirectory: true
        )
        let alternateDirectory = root.appendingPathComponent(
            "alternate",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: canonicalDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: alternateDirectory,
            withIntermediateDirectories: true
        )
        let registrar = MCPClientRegistrar(homeDirectory: root)
        let configurationURL = registrar.defaultConfigURL(
            for: .codexDesktop
        )

        #expect(
            try registrar.validateCanonicalConfigurationDirectory(
                canonicalDirectory,
                for: configurationURL
            ) == canonicalDirectory.standardizedFileURL
        )
        #expect(
            throws: MCPClientRegistrationError.self
        ) {
            try registrar.validateCanonicalConfigurationDirectory(
                alternateDirectory,
                for: configurationURL
            )
        }
    }

    #if JTS_UI_TEST_SUPPORT
    @Test func uiTestMCPRegistrationFixtureIsIsolatedAndSharesCodexEndpointState() {
        let environment = [
            "JTS_TERMINAL_UI_TESTING": "1",
            UITestMCPRegistrationEnvironment.fixtureKey:
                UITestMCPRegistrationEnvironment
                    .registeredCodexEndpointFixture,
        ]

        let desktopStatus = UITestMCPRegistrationEnvironment
            .registrationStatus(
                for: .codexDesktop,
                environment: environment,
                bundleIdentifier:
                    UITestAppLanguageBootstrap
                        .isolatedApplicationBundleIdentifier
            )
        let cliStatus = UITestMCPRegistrationEnvironment
            .registrationStatus(
                for: .codexCLI,
                environment: environment,
                bundleIdentifier:
                    UITestAppLanguageBootstrap
                        .isolatedApplicationBundleIdentifier
            )
        let claudeStatus = UITestMCPRegistrationEnvironment
            .registrationStatus(
                for: .claudeDesktop,
                environment: environment,
                bundleIdentifier:
                    UITestAppLanguageBootstrap
                        .isolatedApplicationBundleIdentifier
            )

        #expect(desktopStatus?.state == .registered)
        #expect(cliStatus?.state == .registered)
        #expect(desktopStatus?.configPath == cliStatus?.configPath)
        #expect(claudeStatus?.state == .notRegistered)
        #expect(
            UITestMCPRegistrationEnvironment.registrationStatus(
                for: .codexDesktop,
                environment: environment,
                bundleIdentifier: "com.lljts.JTSTerminal"
            ) == nil
        )
        #expect(
            UITestMCPRegistrationEnvironment.registrationStatus(
                for: .codexDesktop,
                environment: [
                    UITestMCPRegistrationEnvironment.fixtureKey:
                        UITestMCPRegistrationEnvironment
                            .registeredCodexEndpointFixture,
                ],
                bundleIdentifier:
                    UITestAppLanguageBootstrap
                        .isolatedApplicationBundleIdentifier
            ) == nil
        )
    }
    #endif

    @Test func sessionGroupNameGeneratesUniqueNonBlankNames() async throws {
        #expect(SessionGroupName.unique(base: "", existing: []) == "New Group")
        #expect(SessionGroupName.unique(base: "Production", existing: ["Development"]) == "Production")
        #expect(SessionGroupName.unique(base: "Production", existing: ["Production"]) == "Production 2")
        #expect(SessionGroupName.unique(base: "Production", existing: ["Production", "Production 2"]) == "Production 3")
    }

    @Test func renameRemoteEntryQuotesSourceAndDestination() async throws {
        let command = SSHCommandBuilder.renameRemoteEntryCommand(
            directory: "/srv/app releases",
            oldName: "old config's.json",
            newName: "new config.json"
        )

        #expect(command == "mv -- '/srv/app releases/old config'\\''s.json' '/srv/app releases/new config.json'")
    }

    @Test func scpUploadArgumentsUseUppercasePortIdentityJumpHostAndRemoteTarget() async throws {
        let session = RemoteSession(
            host: "example.com",
            username: "deploy",
            port: 2200,
            identityFile: "~/.ssh/deploy",
            jumpHost: "bastion.example.com"
        )

        let arguments = SSHCommandBuilder.scpUploadArguments(
            for: session,
            localPath: "~/artifact.zip",
            remotePath: "~/artifact.zip"
        )

        #expect(arguments.prefix(2).elementsEqual(["-P", "2200"]))
        #expect(arguments.contains("-i"))
        #expect(arguments.contains("\(NSHomeDirectory())/.ssh/deploy"))
        #expect(arguments.contains("-o"))
        #expect(arguments.contains("ProxyJump=bastion.example.com"))
        expectManagedHostKeyOptions(in: arguments)
        #expect(arguments.contains("\(NSHomeDirectory())/artifact.zip"))
        #expect(arguments.contains("deploy@example.com:'~/artifact.zip'"))
    }

    @Test func scpPasswordArgumentsAllowAskpassCompatibleAuthentication() async throws {
        let session = RemoteSession(
            host: "example.com",
            username: "deploy",
            port: 2200,
            identityFile: "~/.ssh/deploy",
            jumpHost: "bastion.example.com"
        )

        let arguments = SSHCommandBuilder.scpUploadArguments(
            for: session,
            localPath: "~/artifact.zip",
            remotePath: "~/artifact.zip",
            batchMode: false,
            passwordAuthentication: true
        )

        #expect(arguments.contains("-P"))
        #expect(arguments.contains("2200"))
        expectSavedPasswordIsolation(in: arguments)
        #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
        expectManagedHostKeyOptions(in: arguments)
        #expect(!arguments.contains("BatchMode=yes"))
        #expect(!arguments.contains("-i"))
        #expect(!arguments.contains("-J"))
        #expect(!arguments.contains("bastion.example.com"))
    }

    @Test func scpRecursiveArgumentsIncludeRecursiveFlag() async throws {
        let session = RemoteSession(host: "example.com", username: "deploy", port: 2200)

        let arguments = SSHCommandBuilder.scpDownloadArguments(
            for: session,
            remotePath: "~/logs",
            localPath: "~/Downloads",
            batchMode: true,
            passwordAuthentication: false,
            recursive: true
        )

        #expect(arguments.contains("-r"))
        #expect(arguments.contains("deploy@example.com:'~/logs'"))
    }

    @Test func sftpBatchArgumentsUseSubsystemBatchModeAndTarget() async throws {
        let session = RemoteSession(
            host: "files.example.com",
            username: "deploy",
            port: 2200,
            identityFile: "~/.ssh/files",
            jumpHost: "bastion.example.com"
        )

        let arguments = SSHCommandBuilder.sftpBatchArguments(for: session)

        #expect(arguments.contains("-b"))
        #expect(arguments.contains("-"))
        #expect(arguments.contains("-P"))
        #expect(arguments.contains("2200"))
        #expect(arguments.contains("-J"))
        #expect(arguments.contains("bastion.example.com"))
        #expect(arguments.contains("\(NSHomeDirectory())/.ssh/files"))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(!arguments.contains("RequestTTY=force"))
        expectManagedHostKeyOptions(in: arguments)
        #expect(arguments.last == "deploy@files.example.com")
    }

    @Test func sftpPasswordArgumentsAllowAskpassAuthentication() async throws {
        let session = RemoteSession(
            host: "files.example.com",
            username: "deploy",
            port: 22,
            identityFile: "~/.ssh/files",
            jumpHost: "bastion.example.com"
        )

        let arguments = SSHCommandBuilder.sftpBatchArguments(
            for: session,
            batchMode: false,
            passwordAuthentication: true
        )

        expectSavedPasswordIsolation(in: arguments)
        #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
        expectManagedHostKeyOptions(in: arguments)
        #expect(!arguments.contains("BatchMode=yes"))
        #expect(!arguments.contains("-i"))
        #expect(!arguments.contains("-J"))
        #expect(!arguments.contains("bastion.example.com"))
    }

    @Test func sftpBatchScriptsQuotePathsAndUseRecursiveTransferFlags() async throws {
        let upload = SSHCommandBuilder.sftpUploadScript(
            localPath: "~/local folder",
            remotePath: "~/remote folder/it.txt",
            recursive: true
        )
        let rename = SSHCommandBuilder.sftpRenameScript(
            oldPath: "~/old file.txt",
            newPath: "~/new file.txt"
        )

        #expect(upload.contains("@put -R "))
        #expect(upload.contains("'\(NSHomeDirectory())/local folder'"))
        #expect(upload.contains("'remote folder/it.txt'"))
        #expect(upload.hasSuffix("@quit\n"))
        #expect(rename.contains("@rename 'old file.txt' 'new file.txt'"))
    }

    @Test func sftpResumeScriptsUseRegetAndReputForSingleFiles() async throws {
        let upload = SSHCommandBuilder.sftpUploadScript(
            localPath: "/tmp/big.iso",
            remotePath: "/srv/big.iso",
            resume: true
        )
        let download = SSHCommandBuilder.sftpDownloadScript(
            remotePath: "/srv/big.iso",
            localPath: "/tmp/big.iso",
            resume: true
        )
        let recursiveDownload = SSHCommandBuilder.sftpDownloadScript(
            remotePath: "/srv/folder",
            localPath: "/tmp/folder",
            recursive: true,
            resume: true
        )

        #expect(upload.contains("@reput '/tmp/big.iso' '/srv/big.iso'"))
        #expect(download.contains("@reget '/srv/big.iso' '/tmp/big.iso'"))
        #expect(recursiveDownload.contains("@get -R '/srv/folder' '/tmp/folder'"))
    }

    @Test func sftpResumeUploadFallsBackWhenRemoteFileDoesNotExist() async throws {
        let result = CommandResult(
            command: "/usr/bin/sftp",
            exitCode: 1,
            standardOutput: "sftp> reput '/tmp/big.iso' '/srv/big.iso'\nstat remote: No such file or directory\nsftp> quit\n",
            standardError: ""
        )

        #expect(RemoteSFTPTransport.shouldFallbackFromResumeUploadToFreshUpload(result))
    }

    @Test func sftpFailureOutputOverridesZeroExitStatus() async throws {
        let result = CommandResult(
            command: "/usr/bin/sftp",
            exitCode: 0,
            standardOutput: "sftp> @put '/tmp/missing.txt' '/srv/missing.txt'\nstat /tmp/missing.txt: No such file or directory\nsftp> @quit\n",
            standardError: ""
        )

        let normalized = RemoteSFTPTransport.resultByRecognizingSFTPFailureOutput(result)

        #expect(!normalized.succeeded)
        #expect(normalized.exitCode == 1)
        #expect(normalized.displayText.contains("No such file or directory"))
    }

    @Test func sftpSuccessfulOutputKeepsZeroExitStatus() async throws {
        let result = CommandResult(
            command: "/usr/bin/sftp",
            exitCode: 0,
            standardOutput: "Uploading /tmp/report.txt to /srv/report.txt\nreport.txt 100% 58 0.1KB/s 00:00\n",
            standardError: ""
        )

        let normalized = RemoteSFTPTransport.resultByRecognizingSFTPFailureOutput(result)

        #expect(normalized.succeeded)
        #expect(normalized.exitCode == 0)
    }

    @MainActor
    @Test func remoteTransferTaskTracksResumeableFailureAndRetryState() async throws {
        let session = RemoteSession(name: "Prod", host: "files.example.com", username: "ubuntu")
        let task = RemoteTransferTask(
            session: session,
            direction: .download,
            remotePath: "/srv/big.iso",
            localPath: "/tmp/big.iso",
            expectedByteCount: 1_000
        )

        #expect(task.status == .queued)
        #expect(task.status.canResume)
        #expect(task.shouldRemainVisibleInQueue)
        #expect(!task.shouldResumeTransferOnNextAttempt)
        #expect(task.resumeSupported)
        #expect(task.summary == "/srv/big.iso -> /tmp/big.iso")
        #expect(task.progressFraction == 0)

        task.markRunning()
        #expect(task.status == .running)
        #expect(!task.status.canResume)
        #expect(task.shouldRemainVisibleInQueue)

        task.updateTransferredByteCount(250)
        #expect(task.progressFraction == 0.25)
        #expect(task.progressLabel.contains("25%"))

        task.markFailed("Network disconnected")
        #expect(task.status == .failed)
        #expect(task.shouldResumeTransferOnNextAttempt)
        #expect(task.status.canResume)
        #expect(task.shouldRemainVisibleInQueue)
        #expect(task.lastError == "Network disconnected")

        task.markQueued()
        #expect(task.status == .queued)
        #expect(task.lastError.isEmpty)

        task.markFinished(result: CommandResult(command: "sftp", exitCode: 0, standardOutput: "", standardError: ""))
        #expect(task.status == .succeeded)
        #expect(!task.shouldRemainVisibleInQueue)
        #expect(task.progressFraction == 1.0)
    }

    @MainActor
    @Test func remoteTransferTaskRefreshesDownloadProgressFromLocalFile() async throws {
        let session = RemoteSession(name: "Prod", host: "files.example.com", username: "ubuntu")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")
        try Data(repeating: 0x41, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let task = RemoteTransferTask(
            session: session,
            direction: .download,
            remotePath: "/srv/big.iso",
            localPath: url.path,
            expectedByteCount: 512
        )

        task.refreshTransferredByteCountFromLocalFile()
        #expect(task.transferredByteCount == 128)
        #expect(task.progressFraction == 0.25)
    }

    @MainActor
    @Test func remoteTransferTaskPersistsSecurityScopedBookmarkPayload() async throws {
        let session = RemoteSession(name: "Prod", host: "files.example.com", username: "ubuntu")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("jts".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let bookmark = try #require(RemoteTransferTask.securityScopedBookmark(for: url))
        let task = RemoteTransferTask(
            session: session,
            direction: .upload,
            remotePath: "/srv/archive.tar",
            localPath: url.path,
            expectedByteCount: 3,
            localSecurityScopedBookmark: bookmark
        )

        #expect(task.localSecurityScopedBookmark == bookmark)
        task.startAccessingLocalSecurityScopedResource()()
    }

    @Test func sftpRemotePathNormalizesHomeForBatchMode() async throws {
        #expect(SSHCommandBuilder.normalizedSFTPRemotePath("~") == ".")
        #expect(SSHCommandBuilder.normalizedSFTPRemotePath("~/logs/app.log") == "logs/app.log")
        #expect(SSHCommandBuilder.sftpListScript(path: "~").contains("@ls -la '.'"))
    }

    @Test func sftpFailureMessageExplainsConnectionClosed() async throws {
        let result = CommandResult(
            command: "sftp",
            exitCode: 255,
            standardOutput: "",
            standardError: "Connection closed"
        )

        #expect(RemoteSFTPTransport.failureMessage(for: result).contains("Server Properties"))
    }

    @Test func sftpListingFallsBackToSSHWhenSubsystemCloses() async throws {
        let result = CommandResult(
            command: "sftp",
            exitCode: 255,
            standardOutput: "",
            standardError: "Connection closed"
        )

        #expect(RemoteSFTPTransport.shouldAttemptSSHListingFallback(result: result, parsedEntries: []))
    }

    @Test func sftpListingFallsBackWhenSuccessfulOutputHasNoRows() async throws {
        let result = CommandResult(
            command: "sftp",
            exitCode: 0,
            standardOutput: "Connected to files.example.com.\nsftp> ls -la '.'\nsftp>",
            standardError: ""
        )

        #expect(RemoteSFTPTransport.shouldAttemptSSHListingFallback(result: result, parsedEntries: []))
    }

    @Test func sftpListingDoesNotFallbackForAuthenticationDenied() async throws {
        let result = CommandResult(
            command: "sftp",
            exitCode: 255,
            standardOutput: "",
            standardError: "Permission denied (publickey,password)."
        )

        #expect(!RemoteSFTPTransport.shouldAttemptSSHListingFallback(result: result, parsedEntries: []))
    }

    @Test func remoteEditWorkspaceCreatesSafeLocalDrafts() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jts-terminal-edit-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let id = try #require(UUID(uuidString: "A1F79D56-4C04-4A2D-8DA8-6BDE7D279045"))
        let draft = try RemoteEditWorkspace.makeDraft(
            sessionKey: "deploy@example.com:2222",
            remotePath: "~/app logs/config:prod\n.json",
            rootDirectory: root,
            fileManager: fileManager,
            date: Date(timeIntervalSince1970: 0),
            id: id
        )

        #expect(draft.id == id)
        #expect(draft.sessionKey == "deploy@example.com:2222")
        #expect(draft.remotePath == "~/app logs/config:prod\n.json")
        #expect(draft.localURL.lastPathComponent == "config_prod_.json")
        #expect(draft.localURL.deletingLastPathComponent().lastPathComponent == id.uuidString)
        #expect(draft.localURL.path.contains("deploy_example.com_2222"))
        #expect(fileManager.fileExists(atPath: draft.localURL.deletingLastPathComponent().path))
    }

    @Test func remoteEditWorkspaceFallsBackForBlankRemoteNames() async throws {
        #expect(RemoteEditWorkspace.safeFilename(forRemotePath: "/") == "remote-file")
        #expect(RemoteEditWorkspace.safeFilename(forRemotePath: "") == "remote-file")
        #expect(RemoteEditWorkspace.safeDirectoryName(forSessionKey: "  \n") == "session")
    }

    @Test func tunnelArgumentsBuildLocalForwardWithIdentityFileAndJumpHost() async throws {
        let session = RemoteSession(
            host: "bastion.example.com",
            username: "deploy",
            port: 22,
            identityFile: "~/.ssh/tunnel",
            jumpHost: "edge.example.com"
        )
        let tunnel = SSHTunnelConfiguration(
            name: "Database",
            kind: .local,
            bindAddress: "127.0.0.1",
            localPort: 15432,
            destinationHost: "db.internal",
            destinationPort: 5432
        )

        let arguments = SSHCommandBuilder.tunnelArguments(for: session, tunnel: tunnel)

        #expect(arguments.contains("-N"))
        #expect(arguments.contains("ExitOnForwardFailure=yes"))
        #expect(arguments.contains("-L"))
        #expect(arguments.contains("127.0.0.1:15432:db.internal:5432"))
        #expect(arguments.contains("-i"))
        #expect(arguments.contains("\(NSHomeDirectory())/.ssh/tunnel"))
        #expect(arguments.contains("-J"))
        #expect(arguments.contains("edge.example.com"))
        #expect(arguments.contains("deploy@bastion.example.com"))
        #expect(arguments.contains("BatchMode=yes"))
        expectManagedHostKeyOptions(in: arguments)
    }

    @Test func tunnelPasswordArgumentsAllowAskpassAuthentication() async throws {
        let session = RemoteSession(
            host: "bastion.example.com",
            username: "deploy",
            port: 22,
            identityFile: "~/.ssh/tunnel",
            jumpHost: "edge.example.com"
        )
        let tunnel = SSHTunnelConfiguration(kind: .dynamic, localPort: 1080)

        let arguments = SSHCommandBuilder.tunnelArguments(
            for: session,
            tunnel: tunnel,
            batchMode: false,
            passwordAuthentication: true
        )

        #expect(arguments.contains("-N"))
        #expect(arguments.contains("-D"))
        #expect(arguments.contains("127.0.0.1:1080"))
        expectSavedPasswordIsolation(in: arguments)
        #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
        expectManagedHostKeyOptions(in: arguments)
        #expect(!arguments.contains("BatchMode=yes"))
        #expect(!arguments.contains("-i"))
        #expect(!arguments.contains("-J"))
        #expect(!arguments.contains("edge.example.com"))
        #expect(!arguments.contains("RequestTTY=force"))
    }

    @Test func tunnelFailureMessageGuidesCredentialFixes() async throws {
        let message = SSHTunnelManager.failureMessage(
            errorText: "ubuntu@example.com: Permission denied (publickey,password).",
            terminationStatus: 255
        )

        #expect(message.contains("Server Properties"))
        #expect(message.contains("save the correct SSH password"))
    }

    @Test func tunnelAuthenticationFailureIsTerminalForAutoReconnect() async throws {
        #expect(SSHTunnelManager.hasTerminalAuthenticationFailure(
            errorText: "deploy@example.com: Permission denied (publickey,password).",
            terminationStatus: 255
        ))
        #expect(!SSHTunnelManager.hasTerminalAuthenticationFailure(
            errorText: "Connection timed out",
            terminationStatus: 255
        ))
        #expect(!SSHTunnelManager.hasTerminalAuthenticationFailure(
            errorText: "deploy@example.com: Permission denied (publickey,password).",
            terminationStatus: 1
        ))
    }

    @MainActor
    @Test func stoppingTunnelInvalidatesPendingCredentialReadBeforeProcessLaunch() async throws {
        let manager = SSHTunnelManager(credentialReader: { _ in
            // Return a value even when cancellation wakes the sleep. The
            // request generation and cancellation checks must still discard it.
            try? await Task.sleep(for: .milliseconds(250))
            return "late-password"
        })
        let session = RemoteSession(
            host: "example.invalid",
            username: "deploy",
            port: 22
        )
        let configuration = SSHTunnelConfiguration(
            name: "Cancelled Start",
            kind: .dynamic,
            bindAddress: "127.0.0.1",
            localPort: 10_980,
            destinationHost: "",
            destinationPort: 22
        )

        manager.start(session: session, configuration: configuration)
        manager.stop()
        try await Task.sleep(for: .milliseconds(350))

        #expect(manager.processLaunchAttemptCountForTesting == 0)
        #expect(!manager.isRunning)
        #expect(manager.pid == nil)
        #expect(manager.lastMessage == "Tunnel stopped.")
    }

    @Test func tunnelFailureMessageGuidesKnownHostsPermissionFixes() async throws {
        let message = SSHTunnelManager.failureMessage(
            errorText: "hostkeys_find_by_key_hostfile: hostkeys_foreach failed for /Users/example/.ssh/known_hosts: Operation not permitted\nHost key verification failed.",
            terminationStatus: 255
        )

        #expect(message.contains("managed host key store"))
        #expect(message.contains("Verify the server fingerprint"))
        #expect(SSHTunnelManager.hasTerminalHostKeyFailure(
            errorText: message,
            terminationStatus: 255
        ))
    }

    @MainActor
    @Test func tunnelStopsAutoReconnectForUnknownStrictCheckingHost() async throws {
        let manager = SSHTunnelManager(credentialReader: { _ in nil })
        let session = RemoteSession(
            host: "unknown.example.invalid",
            username: "deploy",
            port: 22
        )
        var configuration = SSHTunnelConfiguration(
            name: "Strict Host",
            kind: .dynamic,
            bindAddress: "127.0.0.1",
            localPort: 10_981,
            destinationHost: "",
            destinationPort: 22
        )
        configuration.autoReconnect = true
        let strictFailure = """
        No ED25519 host key is known for unknown.example.invalid and you have requested strict checking.
        Host key verification failed.
        """

        manager.simulateFinishedProcessForTesting(
            session: session,
            configuration: configuration,
            errorText: strictFailure,
            terminationStatus: 255
        )

        #expect(!manager.isRunning)
        #expect(!manager.isReconnectScheduled)
        #expect(manager.activeConfiguration == nil)
        #expect(manager.lastMessage.contains("Auto reconnect stopped"))
        #expect(manager.lastMessage.contains("Verify the server fingerprint"))
        #expect(SSHTunnelManager.hasTerminalHostKeyFailure(
            errorText: strictFailure,
            terminationStatus: 255
        ))
        #expect(!SSHTunnelManager.hasTerminalHostKeyFailure(
            errorText: strictFailure,
            terminationStatus: 1
        ))
    }

    @Test func tunnelFailureMessageGuidesLocalPortConflicts() async throws {
        let message = SSHTunnelManager.failureMessage(
            errorText: "bind [127.0.0.1]:5432: Address already in use",
            terminationStatus: 255
        )

        #expect(message.contains("already in use"))
        #expect(message.contains("different local port"))
    }

    @Test func savedTunnelRoundTripsConfigurationAndTracksSession() async throws {
        let session = RemoteSession(host: "bastion.example.com", username: "deploy", port: 2200)
        let configuration = SSHTunnelConfiguration(
            name: "Redis SOCKS",
            kind: .dynamic,
            bindAddress: "127.0.0.1",
            localPort: 1080,
            destinationHost: "ignored.for.dynamic",
            destinationPort: 6379,
            autoReconnect: true
        )

        let savedTunnel = SavedSSHTunnel(session: session, configuration: configuration)

        #expect(savedTunnel.sessionConnectionKey == "deploy@bastion.example.com:2200")
        #expect(savedTunnel.configuration == configuration)
        #expect(savedTunnel.configuration.summary == "SOCKS 127.0.0.1:1080")
        #expect(savedTunnel.autoReconnect)

        let updated = SSHTunnelConfiguration(
            name: "Postgres",
            kind: .local,
            bindAddress: "127.0.0.1",
            localPort: 15432,
            destinationHost: "db.internal",
            destinationPort: 5432,
            autoReconnect: false
        )

        savedTunnel.update(from: updated, session: session)

        #expect(savedTunnel.name == "Postgres")
        #expect(savedTunnel.kind == .local)
        #expect(savedTunnel.configuration == updated)
        #expect(savedTunnel.configuration.summary == "127.0.0.1:15432 -> db.internal:5432")
        #expect(!savedTunnel.autoReconnect)
    }

    @Test func tunnelAutoReconnectDelayUsesCappedBackoff() async throws {
        #expect(SSHTunnelManager.reconnectDelaySeconds(forAttempt: 1) == 1)
        #expect(SSHTunnelManager.reconnectDelaySeconds(forAttempt: 2) == 2)
        #expect(SSHTunnelManager.reconnectDelaySeconds(forAttempt: 7) == 60)
    }

    @Test func tunnelConfigurationValidationCatchesInvalidPortsAndAllowsDynamicWithoutDestination() async throws {
        var invalidLocalPort = SSHTunnelConfiguration(localPort: 70000)
        #expect(invalidLocalPort.validationMessage == "Local port must be between 1 and 65535.")

        invalidLocalPort.localPort = 5432
        invalidLocalPort.destinationHost = "   "
        #expect(invalidLocalPort.validationMessage == "Destination host is required for local and remote tunnels.")

        let dynamicTunnel = SSHTunnelConfiguration(
            name: "SOCKS",
            kind: .dynamic,
            bindAddress: "127.0.0.1",
            localPort: 1080,
            destinationHost: "",
            destinationPort: 0
        )

        #expect(dynamicTunnel.validationMessage == nil)
        #expect(dynamicTunnel.supportsLocalReadinessCheck)
        #expect(dynamicTunnel.localEndpointSummary == "127.0.0.1:1080")
    }

    @Test func localEndpointReadinessRejectsInvalidPort() async throws {
        let isReady = await SSHTunnelManager.waitForLocalEndpoint(host: "127.0.0.1", port: 70000)

        #expect(!isReady)
    }

    @Test func commandHistoryAndMacroTrackSessionCommands() async throws {
        let session = RemoteSession(name: "Prod", host: "api.example.com", username: "deploy", port: 22)
        let history = CommandHistoryEntry(session: session, command: "uptime", exitCode: 0)
        let failedHistory = CommandHistoryEntry(session: session, command: "systemctl status missing", exitCode: 3)

        #expect(history.sessionConnectionKey == "deploy@api.example.com:22")
        #expect(history.sessionName == "Prod")
        #expect(history.succeeded)
        #expect(!failedHistory.succeeded)
        #expect(session.folderDisplayName == "Ungrouped")

        let macro = SavedCommandMacro(session: session, name: "Health", command: "uptime && df -h")

        #expect(macro.sessionConnectionKey == session.connectionKey)
        #expect(macro.name == "Health")
        #expect(macro.command == "uptime && df -h")

        macro.update(name: "Logs", command: "tail -n 200 /var/log/app.log")

        #expect(macro.name == "Logs")
        #expect(macro.command == "tail -n 200 /var/log/app.log")
        #expect(macro.updatedAt >= macro.createdAt)
    }

    @Test func sshArgumentsIncludeJumpHostAndX11() async throws {
        let session = RemoteSession(
            host: "internal.example.com",
            username: "deploy",
            jumpHost: "bastion.example.com",
            enableX11Forwarding: true
        )

        let arguments = SSHCommandBuilder.sshArguments(for: session, remoteCommand: "xeyes")

        #expect(arguments.contains("-X"))
        #expect(arguments.contains("ForwardX11=yes"))
        #expect(arguments.contains("-J"))
        #expect(arguments.contains("bastion.example.com"))
        #expect(arguments.contains("deploy@internal.example.com"))
        expectManagedHostKeyOptions(in: arguments)
    }

    @Test func x11SupportFindsXQuartzXAuthLocationWhenAvailable() async throws {
        let location = X11Support.xauthLocation { path in
            path == "/opt/X11/bin/xauth"
        }

        #expect(location == "/opt/X11/bin/xauth")
    }

    @Test func ptySessionAppliesRequestedSizeBeforeProcessStarts() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        await MainActor.run {
            session.resize(columns: 100, rows: 40)
            session.start(
                executable: "/usr/bin/perl",
                arguments: [
                    "-e",
                    "my $size = pack('S4', 0, 0, 0, 0); ioctl(STDIN, 0x40087468, $size) or die \"TIOCGWINSZ: $!\\n\"; my ($rows, $columns) = unpack('S4', $size); print \"$rows $columns\\n\";",
                ],
                label: "pty size test"
            )
        }

        let deadline = Date().addingTimeInterval(2)
        var transcript = ""
        while Date() < deadline {
            transcript = await MainActor.run {
                session.transcript
            }
            if transcript.contains("40 100") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        await MainActor.run {
            session.stop()
        }

        #expect(transcript.contains("40 100"))
    }

    @Test func ptyLaunchGateRequiresExactExplicitReleaseToken() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-pty-launch-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, release) in [
            ("eof", nil),
            ("wrong-token", "JTS_PTY_NOT_READY\n"),
        ] {
            let marker = root.appendingPathComponent(name)
            let status = try runPTYLaunchGate(
                release: release,
                marker: marker
            )
            #expect(status == 126)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }

        let releasedMarker = root.appendingPathComponent("released")
        let releasedStatus = try runPTYLaunchGate(
            release: String(decoding: TerminalProcessLaunchGate.releaseBytes, as: UTF8.self),
            marker: releasedMarker
        )
        #expect(releasedStatus == 125)
        #expect(!FileManager.default.fileExists(atPath: releasedMarker.path))
    }

    @Test func ptySessionAcceptsRawKeystrokesWithoutSendButton() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: ["-lc", "IFS= read value; printf 'RAW:%s\\n' \"$value\""],
                label: "raw input test"
            )
        }

        try await Task.sleep(for: .milliseconds(200))

        await MainActor.run {
            session.sendRaw("raw")
        }

        try await Task.sleep(for: .milliseconds(100))

        await MainActor.run {
            session.sendRaw("\r")
        }

        let deadline = Date().addingTimeInterval(2)
        var transcript = ""
        while Date() < deadline {
            transcript = await MainActor.run {
                session.transcript
            }
            if transcript.contains("RAW:raw") {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        await MainActor.run {
            session.stop()
        }

        #expect(transcript.contains("RAW:raw"))
    }

    @Test func ptySessionRunsQueuedMCPCommandsAndTruncatesOutput() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: [],
                label: "mcp terminal command test"
            )
            session.setMCPControlEnabled(true)
        }

        let first = Task {
            try await session.runMCPCommand(
                command: "printf 'one'; sleep 0.15",
                timeoutSeconds: 3,
                maxOutputBytes: 64
            )
        }
        let second = Task {
            try await session.runMCPCommand(
                command: "printf 'two-three'",
                timeoutSeconds: 3,
                maxOutputBytes: 3
            )
        }

        let firstResult = try await first.value
        let secondResult = try await second.value
        let transcript = await MainActor.run {
            session.transcript
        }

        await MainActor.run {
            session.stop()
        }

        #expect(firstResult.exitCode == 0)
        #expect(firstResult.stdout == "one")
        #expect(!firstResult.truncated)
        #expect(secondResult.exitCode == 0)
        #expect(secondResult.stdout == "two")
        #expect(secondResult.truncated)
        #expect(transcript.contains("one"))
        #expect(transcript.contains("two-three"))
        #expect(!transcript.contains("__jts_mcp_cmd"))
        #expect(!transcript.contains("__JTS_MCP_START"))
        #expect(!transcript.contains("__JTS_MCP_END"))
    }

    @Test func ptySessionRunsLongMCPCommandThroughChunkedInput() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession()
        }
        let longValue = String(repeating: "L", count: 5_000)

        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: [],
                label: "long mcp terminal command test"
            )
            session.setMCPControlEnabled(true)
        }

        let result = try await session.runMCPCommand(
            command: "value=\(SSHCommandBuilder.shellQuote(longValue)); printf '%s' \"$value\"",
            timeoutSeconds: 30,
            maxOutputBytes: 6_000
        )

        await MainActor.run {
            session.stop()
        }

        #expect(result.exitCode == 0)
        #expect(result.stdout == longValue)
        #expect(!result.truncated)
    }

    @Test func ptySessionMCPCommandTimeoutPausesAutomationWithoutRevokingControl() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: [],
                label: "mcp timeout test"
            )
            session.setMCPControlEnabled(true)
        }

        let result = try await session.runMCPCommand(
            command: "sleep 2",
            timeoutSeconds: 1,
            maxOutputBytes: 64
        )
        let (isEnabled, recovery) = await MainActor.run {
            (session.isMCPControlEnabled, session.structuredCommandRecovery)
        }

        #expect(result.timedOut)
        #expect(result.exitCode == -1)
        #expect(isEnabled)
        #expect(recovery?.reason == .timedOut)

        do {
            _ = try await session.runMCPCommand(
                command: "printf 'MUST_NOT_RUN'",
                timeoutSeconds: 2,
                maxOutputBytes: 64
            )
            Issue.record("Expected recovery quarantine to reject the next MCP command")
        } catch let error as TerminalMCPCommandError {
            guard case .rejected(let reason) = error else {
                Issue.record("Expected a recovery rejection, got \(error)")
                await MainActor.run { session.stop() }
                return
            }
            #expect(reason.contains("paused"))
        }

        await MainActor.run {
            session.stop()
        }
    }

    @MainActor
    @Test func cancelledEchoOffProbeRestoresPTYEchoBeforeReturningControl() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-echo-recovery-\(UUID().uuidString)", isDirectory: true)
        let markerURL = temporaryRoot.appendingPathComponent("echo-off-entered")
        let releaseURL = temporaryRoot.appendingPathComponent("release-echo-probe")
        let rcFileURL = temporaryRoot.appendingPathComponent("bashrc")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let rcFile = """
        printf() {
          if [[ "${2-}" == __JTS_MCP_ECHO_OFF_* ]]; then
            builtin printf 'ready' > \(SSHCommandBuilder.shellQuote(markerURL.path))
            while [[ ! -e \(SSHCommandBuilder.shellQuote(releaseURL.path)) ]]; do
              command sleep 0.02
            done
          fi
          builtin printf "$@"
        }
        """
        try rcFile.write(to: rcFileURL, atomically: true, encoding: .utf8)

        let process = InteractiveProcessSession()
        process.start(
            executable: "/bin/bash",
            arguments: ["--noprofile", "--rcfile", rcFileURL.path, "-i"],
            label: "echo recovery shell"
        )
        process.setMCPControlEnabled(true)
        let generation = try #require(process.executionGeneration)

        let commandTask = Task {
            try await process.runMCPCommand(
                command: "printf 'COMMAND_MUST_NOT_RUN'",
                timeoutSeconds: 10,
                maxOutputBytes: 64
            )
        }

        let didSendEchoProbe = await waitForStructuredCommandActivity(
            in: process
        ) { activity in
            activity.launchID == generation && activity.didSendEchoProbe
        }
        guard didSendEchoProbe else {
            commandTask.cancel()
            process.stop()
            Issue.record("The structured command never sent its echo-off probe")
            return
        }
        let markerDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: markerURL.path),
              Date() < markerDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            commandTask.cancel()
            process.stop()
            Issue.record("The echo-off probe fixture did not reach its cancellation point")
            return
        }

        commandTask.cancel()
        do {
            _ = try await commandTask.value
            Issue.record("Expected cancellation during the echo-off probe")
        } catch let error as TerminalMCPCommandError {
            guard case .executionInterrupted(_, let didWriteCommandBytes) = error else {
                process.stop()
                Issue.record("Expected a structured cancellation, got \(error)")
                return
            }
            #expect(!didWriteCommandBytes)
        }
        try Data().write(to: releaseURL)

        let idleDeadline = Date().addingTimeInterval(2)
        while process.isStructuredCommandBusy, Date() < idleDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let recovery = try #require(process.structuredCommandRecovery)
        #expect(recovery.reason == .interrupted)

        process.sendRaw(
            "if stty -a | grep -Eq '(^|[;[:space:]])-echo([;[:space:]]|$)'; then printf 'ECHO_STATE:%s\\n' O\"\"FF; else printf 'ECHO_STATE:%s\\n' O\"\"N; fi\r"
        )
        // The interactive shell may leave its prompt on the same rendered
        // line as command output. ON/OFF are deliberately split in the input
        // above, so only the executed diagnostic can produce either complete
        // marker and substring matching cannot be satisfied by local echo.
        let transcriptContainsMarker: (String) -> Bool = { marker in
            process.transcript.contains(marker)
        }
        let echoDeadline = Date().addingTimeInterval(3)
        while !transcriptContainsMarker("ECHO_STATE:ON"),
              !transcriptContainsMarker("ECHO_STATE:OFF"),
              Date() < echoDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(transcriptContainsMarker("ECHO_STATE:ON"))
        #expect(!transcriptContainsMarker("ECHO_STATE:OFF"))
        #expect(process.confirmStructuredCommandRecovery(id: recovery.id))
        process.stop()
    }

    @MainActor
    @Test func structuredPasswordTextNeverArmsManualCredentialCapture() async throws {
        let process = InteractiveProcessSession()
        process.start(
            executable: "/bin/sh",
            arguments: [],
            label: "structured password text shell",
            credentialSaveAccount: "ssh:user@example.test:22",
            credentialSaveLabel: "example.test"
        )
        process.setMCPControlEnabled(true)

        let result = try await process.runMCPCommand(
            command: "printf 'password:'; sleep 0.15; printf '\\nSTRUCTURED_DONE\\n'",
            timeoutSeconds: 3,
            maxOutputBytes: 256
        )
        #expect(result.stdout.contains("password:"))
        #expect(result.stdout.contains("STRUCTURED_DONE"))
        #expect(process.pendingCredentialSaveRequest == nil)

        process.sendRaw("printf 'POST_STRUCTURED_OK\\n'\r")
        let outputDeadline = Date().addingTimeInterval(2)
        while !process.transcript.contains("POST_STRUCTURED_OK"),
              Date() < outputDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(process.transcript.contains("POST_STRUCTURED_OK"))
        #expect(process.pendingCredentialSaveRequest == nil)
        process.stop()
    }

    @MainActor
    @Test func persistentMCPTimeoutRequiresExplicitRecoveryOrNewPTYGeneration() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let profile = RemoteSession(
            name: "Persistent Local",
            connectionType: .localShell
        )
        profile.mcpEnabled = true
        profile.mcpAlwaysAllowTerminalControl = true
        context.insert(profile)
        try context.save()

        let store = TerminalWorkspaceStore()
        let opened = try #require(store.openPreferredTerminal(for: profile))
        let process = opened.processSession
        #expect(store.authorizedOpenTerminals(sessions: [profile]).count == 1)

        let firstTimeout = try await process.runMCPCommand(
            command: "trap '' INT; sleep 2",
            timeoutSeconds: 1,
            maxOutputBytes: 64
        )
        #expect(firstTimeout.timedOut)
        #expect(process.requiresStructuredCommandRecovery)
        #expect(store.authorizedOpenTerminals(sessions: [profile]).count == 1)

        do {
            _ = try await process.runMCPCommand(
                command: "printf 'QUARANTINE_BYPASSED'",
                timeoutSeconds: 2,
                maxOutputBytes: 64
            )
            Issue.record("Persistent authorization must not bypass recovery quarantine")
        } catch let error as TerminalMCPCommandError {
            guard case .rejected(let reason) = error else {
                process.stop()
                Issue.record("Expected a recovery rejection, got \(error)")
                return
            }
            #expect(reason.contains("paused"))
        }

        let firstIdleDeadline = Date().addingTimeInterval(2)
        while process.isStructuredCommandBusy, Date() < firstIdleDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        // The fixture deliberately ignores the timeout's Ctrl-C. Wait for its
        // foreground sleep to finish, mirroring a user who visibly waits for
        // the prompt before pressing the recovery button.
        try await Task.sleep(for: .milliseconds(1_200))
        let firstRecovery = try #require(process.structuredCommandRecovery)
        #expect(process.confirmStructuredCommandRecovery(id: firstRecovery.id))
        let resumed = try await process.runMCPCommand(
            command: "printf 'RECOVERY_CONFIRMED'",
            timeoutSeconds: 3,
            maxOutputBytes: 64
        )
        #expect(resumed.stdout == "RECOVERY_CONFIRMED")

        let secondTimeout = try await process.runMCPCommand(
            command: "sleep 2",
            timeoutSeconds: 1,
            maxOutputBytes: 64
        )
        #expect(secondTimeout.timedOut)
        let oldGeneration = process.executionGeneration
        #expect(process.requiresStructuredCommandRecovery)

        process.stop()
        process.start(
            executable: "/bin/sh",
            arguments: [],
            label: "replacement persistent shell"
        )
        #expect(process.executionGeneration != oldGeneration)
        #expect(!process.requiresStructuredCommandRecovery)
        #expect(store.authorizedOpenTerminals(sessions: [profile]).count == 1)
        let restarted = try await process.runMCPCommand(
            command: "printf 'NEW_GENERATION_READY'",
            timeoutSeconds: 3,
            maxOutputBytes: 64
        )
        #expect(restarted.stdout == "NEW_GENERATION_READY")
        process.stop()
    }

    @MainActor
    @Test func staleRecoveryTokenCannotClearRecoveryFromReplacementGeneration() async throws {
        let process = InteractiveProcessSession()
        defer {
            process.stop()
        }

        process.start(
            executable: "/bin/sh",
            arguments: [],
            label: "first recovery generation"
        )
        process.setMCPControlEnabled(true)
        let firstGeneration = try #require(process.executionGeneration)
        let firstTimeout = try await process.runMCPCommand(
            command: "trap '' INT; sleep 2",
            timeoutSeconds: 1,
            maxOutputBytes: 64
        )
        #expect(firstTimeout.timedOut)
        let staleRecovery = try #require(process.structuredCommandRecovery)
        #expect(staleRecovery.launchID == firstGeneration)

        process.stop()
        process.start(
            executable: "/bin/sh",
            arguments: [],
            label: "replacement recovery generation"
        )
        process.setMCPControlEnabled(true)
        let replacementGeneration = try #require(process.executionGeneration)
        #expect(replacementGeneration != firstGeneration)
        #expect(!process.requiresStructuredCommandRecovery)

        let secondTimeout = try await process.runMCPCommand(
            command: "trap '' INT; sleep 2",
            timeoutSeconds: 1,
            maxOutputBytes: 64
        )
        #expect(secondTimeout.timedOut)
        let currentRecovery = try #require(process.structuredCommandRecovery)
        #expect(currentRecovery.id != staleRecovery.id)
        #expect(currentRecovery.launchID == replacementGeneration)

        let idleDeadline = Date().addingTimeInterval(2)
        while process.isStructuredCommandBusy, Date() < idleDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(1_200))

        #expect(!process.canConfirmStructuredCommandRecovery(id: staleRecovery.id))
        #expect(!process.confirmStructuredCommandRecovery(id: staleRecovery.id))
        #expect(process.structuredCommandRecovery == currentRecovery)
        #expect(process.canConfirmStructuredCommandRecovery(id: currentRecovery.id))
        #expect(process.confirmStructuredCommandRecovery(id: currentRecovery.id))
        #expect(process.structuredCommandRecovery == nil)
    }

    @Test func ptySessionOffersToSavePasswordEnteredAfterPrompt() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: ["-lc", "printf 'password:'; stty -echo; IFS= read value; stty echo; if [ \"$value\" = 's3et' ]; then printf 'AUTH:OK\\n'; else printf 'AUTH:BAD\\n'; fi"],
                label: "password capture test",
                credentialSaveAccount: "ssh:user@example.test:22",
                credentialSaveLabel: "example.test"
            )
        }

        let promptDeadline = Date().addingTimeInterval(2)
        while Date() < promptDeadline {
            let transcript = await MainActor.run {
                session.transcript
            }
            if transcript.contains("password:") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        await MainActor.run {
            session.sendRaw("s3eX")
            session.sendRaw("\u{7f}")
            session.sendRaw("t\r")
        }

        let requestDeadline = Date().addingTimeInterval(2)
        var request: InteractiveProcessSession.PendingCredentialSaveRequest?
        var transcript = ""
        while Date() < requestDeadline {
            (request, transcript) = await MainActor.run {
                (session.pendingCredentialSaveRequest, session.transcript)
            }
            if request != nil, transcript.contains("AUTH:OK") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        transcript = await MainActor.run {
            session.stop()
            return session.transcript
        }

        #expect(transcript.contains("AUTH:OK"))
        #expect(request?.account == "ssh:user@example.test:22")
        #expect(request?.label == "example.test")
        #expect(request?.secret == "s3et")
        #expect(!transcript.contains("s3et"))
    }

    @Test func ptySessionOffersToSavePasswordWhenPromptArrivesInChunks() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: ["-lc", "stty -echo; printf 'pass'; sleep 0.15; printf 'word:'; IFS= read value; stty echo; if [ \"$value\" = 'split-secret' ]; then printf 'AUTH:OK\\n'; else printf 'AUTH:BAD\\n'; fi"],
                label: "split password prompt test",
                credentialSaveAccount: "ssh:user@example.test:22",
                credentialSaveLabel: "example.test"
            )
        }

        let promptDeadline = Date().addingTimeInterval(2)
        while Date() < promptDeadline {
            let transcript = await MainActor.run {
                session.transcript
            }
            if transcript.contains("password:") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        await MainActor.run {
            session.sendRaw("split-")
        }
        try await Task.sleep(for: .milliseconds(50))
        await MainActor.run {
            session.sendRaw("secret")
        }
        try await Task.sleep(for: .milliseconds(50))
        await MainActor.run {
            session.sendRaw("\r")
        }

        let requestDeadline = Date().addingTimeInterval(2)
        var request: InteractiveProcessSession.PendingCredentialSaveRequest?
        var transcript = ""
        while Date() < requestDeadline {
            (request, transcript) = await MainActor.run {
                (session.pendingCredentialSaveRequest, session.transcript)
            }
            if request != nil, transcript.contains("AUTH:OK") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        transcript = await MainActor.run {
            session.stop()
            return session.transcript
        }

        #expect(transcript.contains("AUTH:OK"))
        #expect(request?.account == "ssh:user@example.test:22")
        #expect(request?.label == "example.test")
        #expect(request?.secret == "split-secret")
        #expect(!transcript.contains("split-secret"))
    }

    @Test func sensitivePTYEchoRedactorHandlesChunkBoundariesAndRepeatedPrefixes() async throws {
        var redactor = TerminalSensitiveInputEchoRedactor()
        redactor.recordInput("repeat-repeat\r")
        redactor.submit(secret: "repeat-repeat")

        #expect(redactor.redact("repeat-").isEmpty)
        #expect(!redactor.redact("repeat\r").contains("repeat"))
        let safeOutput = redactor.redact("\nAUTH:OK\r\n")

        #expect(redactor.isComplete)
        #expect(safeOutput.contains("AUTH:OK"))
        #expect(!safeOutput.contains("repeat"))
    }

    @Test func sensitivePTYEchoRedactorCoversEditedInputWithoutSwallowingNormalOutput() async throws {
        var editedInputRedactor = TerminalSensitiveInputEchoRedactor()
        editedInputRedactor.recordInput("s3eX\u{7f}t\r")
        editedInputRedactor.submit(secret: "s3et")
        let editedOutput = editedInputRedactor.redact("s3eX\u{8} \u{8}t\r\nAUTH:OK\r\n")

        #expect(editedOutput.contains("AUTH:OK"))
        #expect(!editedOutput.contains("s3eX"))
        #expect(!editedOutput.contains("s3et"))

        var normalOutputRedactor = TerminalSensitiveInputEchoRedactor()
        normalOutputRedactor.recordInput("unrelated-secret\r")
        normalOutputRedactor.submit(secret: "unrelated-secret")
        let normalOutput = "Permission denied, please try again.\r\n"
        #expect(normalOutputRedactor.redact(normalOutput) == normalOutput)

        var emptySecretRedactor = TerminalSensitiveInputEchoRedactor()
        emptySecretRedactor.recordInput("\r")
        emptySecretRedactor.submit(secret: "")
        let emptySecretOutput = "Authentication cancelled.\r\n"
        #expect(emptySecretRedactor.redact(emptySecretOutput) == emptySecretOutput)
    }

    @Test func sensitivePTYEchoRedactorProtectsUnsubmittedInputOnTermination() async throws {
        var redactor = TerminalSensitiveInputEchoRedactor()
        redactor.recordInput("partial-secret")

        #expect(redactor.redact("partial-").isEmpty)
        #expect(redactor.finish().isEmpty)
        #expect(redactor.isComplete)

        var submittedRedactor = TerminalSensitiveInputEchoRedactor()
        submittedRedactor.recordInput("submitted-secret\r")
        submittedRedactor.submit(secret: "submitted-secret")
        #expect(submittedRedactor.redact("submitted-").isEmpty)
        #expect(submittedRedactor.finish().isEmpty)
        #expect(submittedRedactor.isComplete)
    }

    @Test func sensitivePTYEchoRedactorReleasesNormalUnterminatedPrompt() async throws {
        var redactor = TerminalSensitiveInputEchoRedactor()
        redactor.recordInput("saved-secret\r")
        redactor.submit(secret: "saved-secret")

        let prompt = "ubuntu@example.test:~$ "
        #expect(redactor.redact(prompt) == prompt)
        #expect(redactor.isComplete)

        var substringRedactor = TerminalSensitiveInputEchoRedactor()
        substringRedactor.recordInput("denied\r")
        substringRedactor.submit(secret: "denied")
        let failure = "Permission denied, please try again.\r\n"
        #expect(substringRedactor.redact(failure) == failure)
        #expect(substringRedactor.isComplete)
    }

    @Test func cancelledAsyncSSHStartCannotLaunchAfterCredentialReadCompletes() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession(credentialReader: { _ in
                // Intentionally return a secret even when sleep is cancelled;
                // the request generation guard must still reject this result.
                try? await Task.sleep(for: .milliseconds(250))
                return "late-stored-secret"
            })
        }
        let profile = RemoteSession(
            host: "example.invalid",
            username: "deploy",
            port: 22
        )

        await MainActor.run {
            session.startSSH(session: profile)
            session.stop()
        }
        try await Task.sleep(for: .milliseconds(350))

        let state = await MainActor.run {
            (session.hasStarted, session.isRunning, session.pid, session.transcript)
        }
        #expect(!state.0)
        #expect(!state.1)
        #expect(state.2 == nil)
        #expect(!state.3.contains("late-stored-secret"))
        #expect(!state.3.contains("started PTY session"))
    }

    @Test func ptySessionNeverInjectsSavedSecretFromTranscriptPasswordText() async throws {
        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: [
                    "-lc",
                    "printf 'Password:'; if IFS= read -r -t 0.5 value; then printf '\\nBANNER:ANSWERED\\n'; else printf '\\nBANNER:UNANSWERED\\n'; fi"
                ],
                label: "fake password banner isolation test"
            )
        }

        let deadline = Date().addingTimeInterval(2)
        var transcript = ""
        while Date() < deadline {
            transcript = await MainActor.run {
                session.transcript
            }
            if transcript.contains("BANNER:") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        await MainActor.run { session.stop() }

        #expect(transcript.contains("BANNER:UNANSWERED"))
        #expect(!transcript.contains("BANNER:ANSWERED"))
        #expect(!transcript.contains("stored-secret"))
    }

    @Test func savedServerPasswordIsNeverSentToPrivateKeyPassphrasePrompt() async throws {
        #expect(InteractiveProcessSession.containsServerPasswordPrompt("ubuntu@example.test's password: "))
        #expect(InteractiveProcessSession.containsServerPasswordPrompt("Password:"))
        #expect(!InteractiveProcessSession.containsServerPasswordPrompt("Enter passphrase for key '/tmp/id_ed25519': "))
        #expect(!InteractiveProcessSession.containsServerPasswordPrompt("[sudo] password for ubuntu: "))

        let session = await MainActor.run {
            InteractiveProcessSession()
        }
        await MainActor.run {
            session.start(
                executable: "/bin/bash",
                arguments: [
                    "-lc",
                    "stty -echo; printf \"Enter passphrase for key '/tmp/id_ed25519':\"; if IFS= read -r -t 0.5 value; then printf '\\nKEY_PROMPT:ANSWERED\\n'; else printf '\\nKEY_PROMPT:UNANSWERED\\n'; fi; stty echo"
                ],
                label: "private key passphrase isolation test"
            )
        }

        let deadline = Date().addingTimeInterval(2)
        var transcript = ""
        while Date() < deadline {
            transcript = await MainActor.run { session.transcript }
            if transcript.contains("KEY_PROMPT:") {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        await MainActor.run { session.stop() }

        #expect(transcript.contains("KEY_PROMPT:UNANSWERED"))
        #expect(!transcript.contains("KEY_PROMPT:ANSWERED"))
        #expect(!transcript.contains("saved-server-password"))
    }

    @Test func ptySessionKeepsPaneMCPControlAcrossAutomaticReconnect() async throws {
        let outcome = try await runPaneThatDropsOnce(turnMCPControlOffWhileReconnecting: false)

        #expect(outcome.reconnected)
        #expect(outcome.mcpControlAfterReconnect)
        #expect(!outcome.mcpControlAfterStop)
    }

    @Test func ptySessionDoesNotRestorePaneMCPControlTurnedOffBeforeReconnect() async throws {
        let outcome = try await runPaneThatDropsOnce(turnMCPControlOffWhileReconnecting: true)

        #expect(outcome.reconnected)
        #expect(!outcome.mcpControlAfterReconnect)
    }

    /// Starts a pane whose first launch drops like a lost connection and whose
    /// automatic reconnect stays up, with the pane-level MCP switch turned on.
    private func runPaneThatDropsOnce(
        turnMCPControlOffWhileReconnecting: Bool
    ) async throws -> (reconnected: Bool, mcpControlAfterReconnect: Bool, mcpControlAfterStop: Bool) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-reconnect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = SSHCommandBuilder.shellQuote(root.appendingPathComponent("first-launch").path)
        let label = "MCP reconnect test"

        let session = await MainActor.run { InteractiveProcessSession() }
        let controlAfterStart: Bool = await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "if [ -e \(marker) ]; then exec sleep 30; fi; : > \(marker); sleep 0.3; exit 7"
                ],
                label: label,
                autoReconnect: true
            )
            session.setMCPControlEnabled(true)
            return session.isMCPControlEnabled
        }
        #expect(controlAfterStart)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var didTurnOff = false
        var reconnected = false
        while clock.now < deadline {
            let (transcript, isRunning, isReconnectScheduled) = await MainActor.run {
                (session.transcript, session.isRunning, session.isReconnectScheduled)
            }
            if turnMCPControlOffWhileReconnecting, !didTurnOff, isReconnectScheduled {
                await MainActor.run { session.setMCPControlEnabled(false) }
                didTurnOff = true
            }
            if isRunning,
               transcript.components(separatedBy: "started PTY session \(label)").count - 1 == 2 {
                reconnected = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        if turnMCPControlOffWhileReconnecting {
            #expect(didTurnOff)
        }

        let controlAfterReconnect = await MainActor.run { session.isMCPControlEnabled }
        let controlAfterStop: Bool = await MainActor.run {
            session.stop()
            return session.isMCPControlEnabled
        }
        return (reconnected, controlAfterReconnect, controlAfterStop)
    }

    @Test func ptySessionStopsAutoReconnectAfterTerminalSSHAuthenticationFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-auth-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeSSH = root.appendingPathComponent("ssh")
        try FileManager.default.createSymbolicLink(
            at: fakeSSH,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )
        let markerURL = root.appendingPathComponent("launches")
        let session = await MainActor.run { InteractiveProcessSession() }

        await MainActor.run {
            session.start(
                executable: fakeSSH.path,
                arguments: [
                    "-lc",
                    "printf 'run\\n' >> \(SSHCommandBuilder.shellQuote(markerURL.path)); printf '%s\\n' 'Permission denied, please try again.' 'ubuntu@example.test: Permission denied (publickey,password).'; exit 255"
                ],
                label: "SSH authentication failure test",
                autoReconnect: true
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var transcript = ""
        while clock.now < deadline {
            let snapshot = await MainActor.run {
                (session.transcript, session.isRunning, session.isReconnectScheduled)
            }
            transcript = snapshot.0
            if transcript.contains("Auto reconnect stopped"),
               !snapshot.1,
               !snapshot.2 {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let (finalTranscript, isRunning, reconnectScheduled) = await MainActor.run {
            (session.transcript, session.isRunning, session.isReconnectScheduled)
        }
        transcript = finalTranscript
        let runCount = ((try? String(contentsOf: markerURL, encoding: .utf8)) ?? "")
            .split(whereSeparator: \Character.isNewline)
            .count
        await MainActor.run { session.stop() }

        #expect(transcript.contains("Permission denied (publickey,password)."))
        #expect(transcript.contains("Auto reconnect stopped"))
        #expect(transcript.contains("Verify the saved username, password, or SSH key"))
        #expect(!transcript.contains("Auto reconnect in"))
        #expect(!isRunning)
        #expect(!reconnectScheduled)
        #expect(runCount == 1)

        #expect(!InteractiveProcessSession.isTerminalSSHAuthenticationFailure(
            executable: "/bin/sh",
            status: 255 << 8,
            output: "ubuntu@example.test: Permission denied (publickey,password)."
        ))
        #expect(!InteractiveProcessSession.isTerminalSSHAuthenticationFailure(
            executable: "/usr/bin/ssh",
            status: 1 << 8,
            output: "ubuntu@example.test: Permission denied (publickey,password)."
        ))
    }

    @Test func ptySessionAutoReconnectsAfterUnexpectedExitWithoutViewReappearing() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-pty-reconnect-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }

        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        await MainActor.run {
            let markerPath = SSHCommandBuilder.shellQuote(markerURL.path)
            session.start(
                executable: "/bin/sh",
                arguments: [
                    "-lc",
                    "marker=\(markerPath); printf 'operator log: Host key verification failed.\\n'; if [ -f \"$marker\" ]; then printf 'run\\n' >> \"$marker\"; sleep 30; else printf 'run\\n' > \"$marker\"; exit 9; fi"
                ],
                label: "auto reconnect test",
                autoReconnect: true
            )
        }

        let deadline = Date().addingTimeInterval(4)
        var runCount = 0
        var sawReconnect = false
        while Date() < deadline {
            let text = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? ""
            runCount = text.split(separator: "\n").count
            sawReconnect = await MainActor.run {
                session.transcript.contains("Auto reconnect") || session.isReconnectScheduled
            }
            if runCount >= 2, sawReconnect {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let reconnectState = await MainActor.run {
            (
                isRunning: session.isRunning,
                isReconnectScheduled: session.isReconnectScheduled,
                reconnectStatus: session.reconnectStatus
            )
        }
        await MainActor.run {
            session.stop()
        }

        #expect(runCount >= 2)
        #expect(sawReconnect)
        #expect(reconnectState.isRunning)
        #expect(!reconnectState.isReconnectScheduled)
        #expect(reconnectState.reconnectStatus.isEmpty)
        #expect(InteractiveProcessSession.reconnectDelaySeconds(forAttempt: 1) == 1)
        #expect(InteractiveProcessSession.reconnectDelaySeconds(forAttempt: 7) == 60)
    }

    @Test func ptySessionStopsAutoReconnectAfterKnownHostsPermissionFailure() async throws {
        let fileManager = FileManager.default
        let fixtureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("jts-terminal-host-key-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: fixtureDirectory)
        }
        let sshFixture = fixtureDirectory.appendingPathComponent("ssh")
        try fileManager.createSymbolicLink(
            at: sshFixture,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )
        let session = await MainActor.run {
            InteractiveProcessSession()
        }

        let strictFailure = "No ED25519 host key is known for unknown.example.invalid and you have requested strict checking."
        await MainActor.run {
            session.start(
                executable: sshFixture.path,
                arguments: [
                    "-lc",
                    "printf '%s\\n' '\(strictFailure)' 'Host key verification failed.'; sleep 0.1; exit 255"
                ],
                label: "strict host key failure test",
                autoReconnect: true
            )
        }

        let deadline = Date().addingTimeInterval(3)
        var transcript = ""
        var isReconnectScheduled = false
        while Date() < deadline {
            (transcript, isReconnectScheduled) = await MainActor.run {
                (session.transcript, session.isReconnectScheduled)
            }
            if transcript.contains("Auto reconnect stopped") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        await MainActor.run {
            session.stop()
        }

        #expect(transcript.contains(strictFailure))
        #expect(transcript.contains("Host key verification failed."))
        #expect(transcript.contains("Auto reconnect stopped"))
        #expect(!transcript.contains("Auto reconnect in"))
        #expect(!isReconnectScheduled)
        #expect(InteractiveProcessSession.isTerminalSSHHostKeyFailure(
            executable: "/usr/bin/ssh",
            status: 255,
            output: "REMOTE HOST IDENTIFICATION HAS CHANGED!"
        ))
        #expect(!InteractiveProcessSession.isTerminalSSHHostKeyFailure(
            executable: "/bin/sh",
            status: 255,
            output: "\(strictFailure)\nHost key verification failed."
        ))
    }

    @Test func terminalWorkspaceAddsTabsAndClosesSafely() async throws {
        let workspace = await MainActor.run {
            TerminalWorkspaceState(initialKind: .ssh)
        }

        await MainActor.run {
            #expect(workspace.tabs.count == 1)
            #expect(workspace.selectedTabID == workspace.tabs[0].id)
        }

        await MainActor.run {
            workspace.addTab(kind: .localShell)
            #expect(workspace.tabs.count == 2)
            #expect(workspace.selectedTabID == workspace.tabs[1].id)
            #expect(workspace.tabs[1].panes.count == 1)
            #expect(workspace.tabs[1].panes[0].kind == .localShell)
        }

        await MainActor.run {
            let selectedTabID = workspace.selectedTabID
            let backgroundTabID = workspace.tabs[0].id

            workspace.closeTab(id: backgroundTabID)
            #expect(workspace.tabs.count == 1)
            #expect(workspace.selectedTabID == selectedTabID)
            #expect(workspace.tabs[0].id == selectedTabID)
        }

        await MainActor.run {
            workspace.closeSelectedTab()
            #expect(workspace.tabs.isEmpty)
            #expect(workspace.selectedTabID == nil)
            #expect(workspace.selectedTab == nil)
        }

        await MainActor.run {
            workspace.ensureTabIfEmpty(kind: .ssh)
            #expect(workspace.tabs.count == 1)
            #expect(workspace.selectedTabID == workspace.tabs[0].id)
            #expect(workspace.tabs[0].panes[0].kind == .ssh)
        }
    }

    @MainActor
    @Test func terminalWorkspaceSplitsFocusesAndClosesPanesDeterministically() async throws {
        let workspace = TerminalWorkspaceState(initialKind: .ssh)
        let originalPane = try #require(workspace.selectedPane)

        let rightPane = try #require(
            workspace.splitSelectedPane(axis: .horizontal)
        )
        #expect(workspace.tabs.count == 1)
        #expect(workspace.selectedTab?.panes.map(\.id) == [originalPane.id, rightPane.id])
        #expect(workspace.selectedTab?.layout.paneIDs == [originalPane.id, rightPane.id])
        #expect(workspace.selectedPane?.id == rightPane.id)
        #expect(rightPane.kind == .ssh)

        workspace.focusPane(id: originalPane.id)
        let lowerPane = try #require(
            workspace.splitSelectedPane(axis: .vertical)
        )
        #expect(workspace.selectedTab?.panes.map(\.id) == [
            originalPane.id,
            lowerPane.id,
            rightPane.id
        ])
        let nestedLayout = try #require(workspace.selectedTab?.layout)
        guard case .split(_, .horizontal, let leftBranch, .pane(let rightPaneID)) = nestedLayout,
              case .split(_, .vertical, .pane(let originalPaneID), .pane(let lowerPaneID)) = leftBranch else {
            Issue.record("Expected a horizontal root with a nested vertical split")
            return
        }
        #expect(rightPaneID == rightPane.id)
        #expect(originalPaneID == originalPane.id)
        #expect(lowerPaneID == lowerPane.id)
        #expect(workspace.selectedPane?.id == lowerPane.id)

        _ = workspace.splitSelectedPane(axis: .horizontal)
        #expect(workspace.selectedTab?.panes.count == TerminalWorkspaceState.maximumPanesPerTab)
        #expect(!workspace.canSplitSelectedPane)
        #expect(workspace.splitSelectedPane(axis: .vertical) == nil)

        workspace.closePane(id: lowerPane.id)
        #expect(workspace.selectedTab?.panes.count == 3)
        #expect(workspace.selectedPane?.id != lowerPane.id)

        while let paneID = workspace.selectedPane?.id {
            workspace.closePane(id: paneID)
        }
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.selectedTabID == nil)
    }

    @MainActor
    @Test func closingSplitPaneStopsOnlyItsProcessAndPreservesSiblingSurface() async throws {
        let workspace = TerminalWorkspaceState(initialKind: .localShell)
        let firstPane = try #require(workspace.selectedPane)
        let secondPane = try #require(
            workspace.splitSelectedPane(axis: .horizontal)
        )
        let firstProcess = try #require(workspace.processSession(for: firstPane))
        let secondProcess = try #require(workspace.processSession(for: secondPane))
        let firstSurface = NSObject()
        let secondSurface = NSObject()

        #expect(workspace.terminalSurface(for: firstPane) { firstSurface } === firstSurface)
        #expect(workspace.terminalSurface(for: secondPane) { secondSurface } === secondSurface)

        firstProcess.start(
            executable: "/bin/sh",
            arguments: ["-lc", "sleep 5"],
            label: "first split pane"
        )
        secondProcess.start(
            executable: "/bin/sh",
            arguments: ["-lc", "sleep 5"],
            label: "second split pane"
        )
        #expect(firstProcess.isRunning)
        #expect(secondProcess.isRunning)

        workspace.closePane(id: firstPane.id)

        #expect(!firstProcess.isRunning)
        #expect(secondProcess.isRunning)
        #expect(workspace.selectedPane?.id == secondPane.id)
        #expect(workspace.terminalSurface(for: secondPane) { NSObject() } === secondSurface)

        secondProcess.stop()
    }

    @MainActor
    @Test func closedPaneCannotRecreateInvisibleProcessOrSurface() async throws {
        let workspace = TerminalWorkspaceState(initialKind: .localShell)
        let stalePane = try #require(workspace.selectedPane)
        let process = try #require(workspace.processSession(for: stalePane))
        let surface = NSObject()
        #expect(workspace.terminalSurface(for: stalePane) { surface } === surface)

        process.start(
            executable: "/bin/sh",
            arguments: ["-lc", "sleep 5"],
            label: "stale pane process"
        )
        #expect(process.isRunning)

        workspace.closePane(id: stalePane.id)

        #expect(!process.isRunning)
        #expect(workspace.processSession(for: stalePane) == nil)
        #expect(workspace.terminalSurface(for: stalePane) { NSObject() } == nil)
        #expect(workspace.runningProcessSummaries.isEmpty)
    }

    @MainActor
    @Test func focusingTheActivePaneDoesNotRepublishTheWorkspace() throws {
        let workspace = TerminalWorkspaceState(initialKind: .localShell)
        let firstPane = try #require(workspace.selectedPane)
        var publicationCount = 0
        let observation = workspace.objectWillChange.sink {
            publicationCount += 1
        }

        workspace.focusPane(id: firstPane.id)
        workspace.focusPane(id: firstPane.id)
        #expect(publicationCount == 0)

        let secondPane = try #require(
            workspace.splitSelectedPane(axis: .horizontal)
        )
        publicationCount = 0
        workspace.focusPane(id: firstPane.id)
        #expect(publicationCount == 1)
        workspace.focusPane(id: firstPane.id)
        #expect(publicationCount == 1)
        workspace.focusPane(id: secondPane.id)
        #expect(publicationCount == 2)

        withExtendedLifetime(observation) {}
    }

    @MainActor
    @Test func removingWorkspaceStopsEverySplitProcessAndCreatesFreshWorkspace() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let profile = RemoteSession(name: "Disposable", connectionType: .localShell)
        context.insert(profile)
        try context.save()

        let store = TerminalWorkspaceStore()
        let workspace = store.workspace(
            for: profile.persistentModelID,
            initialKind: .localShell
        )
        let firstPane = try #require(workspace.selectedPane)
        let secondPane = try #require(
            workspace.splitSelectedPane(axis: .horizontal)
        )
        let firstProcess = try #require(workspace.processSession(for: firstPane))
        let secondProcess = try #require(workspace.processSession(for: secondPane))
        _ = workspace.terminalSurface(for: firstPane) { NSObject() }
        _ = workspace.terminalSurface(for: secondPane) { NSObject() }

        firstProcess.start(
            executable: "/bin/sh",
            arguments: ["-lc", "sleep 5"],
            label: "disposable first"
        )
        secondProcess.start(
            executable: "/bin/sh",
            arguments: ["-lc", "sleep 5"],
            label: "disposable second"
        )
        _ = store.openPreferredTerminal(for: profile)
        #expect(store.navigationRequest?.sessionID == profile.persistentModelID)

        store.removeWorkspace(for: profile.persistentModelID)

        #expect(!firstProcess.isRunning)
        #expect(!secondProcess.isRunning)
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.processSession(for: firstPane) == nil)
        #expect(workspace.processSession(for: secondPane) == nil)
        #expect(store.navigationRequest == nil)
        let replacement = store.workspace(
            for: profile.persistentModelID,
            initialKind: .localShell
        )
        #expect(replacement !== workspace)
        #expect(replacement.tabs.count == 1)
    }

    @MainActor
    @Test func terminalMultiExecRunsReviewedCommandAcrossReadyLocalPanes() async throws {
        let profile = RemoteSession(name: "Local Batch", connectionType: .localShell)
        let workspace = TerminalWorkspaceState(initialKind: .localShell)
        let firstPane = try #require(workspace.selectedPane)
        let secondPane = try #require(
            workspace.splitSelectedPane(axis: .horizontal)
        )
        let firstProcess = try #require(workspace.processSession(for: firstPane))
        let secondProcess = try #require(workspace.processSession(for: secondPane))
        defer {
            firstProcess.stop()
            secondProcess.stop()
        }
        for process in [firstProcess, secondProcess] {
            process.start(
                executable: "/bin/sh",
                arguments: [],
                label: "multi-exec local shell"
            )
            process.setBroadcastReady(true)
        }

        let targets = workspace.broadcastTargets(for: profile)
        #expect(targets.count == 2)
        #expect(targets.allSatisfy { $0.availability == .ready })

        let coordinator = TerminalBroadcastCoordinator()
        coordinator.open(targets: targets)
        coordinator.selectAllEligible()
        coordinator.command = "printf 'MULTI_EXEC_RESULT'"
        coordinator.review()
        #expect(coordinator.phase == .review)
        coordinator.didConfirmPromptState = true
        let runID = try #require(coordinator.runConfirmedBatch())
        #expect(coordinator.phase == .running)

        let didComplete = await coordinator.waitForBatchCompletion(
            runID: runID,
            timeout: .seconds(30)
        )

        #expect(didComplete)
        #expect(coordinator.phase == .results)
        #expect(coordinator.results.count == 2)
        #expect(coordinator.results.allSatisfy { $0.status == .succeeded })
        #expect(coordinator.results.allSatisfy { $0.exitCode == 0 })
        #expect(coordinator.results.allSatisfy { $0.stdout == "MULTI_EXEC_RESULT" })
        #expect(coordinator.results.allSatisfy { $0.didWriteCommandBytes })
        #expect(!firstProcess.transcript.contains("MULTI_EXEC_RESULT"))
        #expect(!secondProcess.transcript.contains("MULTI_EXEC_RESULT"))
        #expect(!firstProcess.isStructuredCommandBusy)
        #expect(!secondProcess.isStructuredCommandBusy)

        coordinator.close()
    }

    @MainActor
    @Test func terminalMultiExecRejectsCommandOrTargetMutationAfterReview() async throws {
        let profile = RemoteSession(name: "Frozen Batch", connectionType: .localShell)
        let workspace = TerminalWorkspaceState(initialKind: .localShell)
        _ = workspace.splitSelectedPane(axis: .horizontal)
        let panes = workspace.tabs.flatMap(\.panes)
        let processes = try panes.map { pane in
            try #require(workspace.processSession(for: pane))
        }
        for process in processes {
            process.start(executable: "/bin/sh", arguments: [], label: "frozen review shell")
            process.setBroadcastReady(true)
        }

        let coordinator = TerminalBroadcastCoordinator()
        coordinator.open(targets: workspace.broadcastTargets(for: profile))
        coordinator.selectAllEligible()
        coordinator.command = "printf 'REVIEWED_COMMAND'"
        coordinator.review()
        coordinator.command = "printf 'MUTATED_COMMAND'"
        coordinator.didConfirmPromptState = true

        #expect(!coordinator.canRun)
        coordinator.runConfirmedBatch()
        #expect(coordinator.phase == .review)
        #expect(coordinator.errorMessage.contains("changed after review"))
        #expect(processes.allSatisfy { !$0.isStructuredCommandBusy })
        #expect(processes.allSatisfy { !$0.transcript.contains("REVIEWED_COMMAND") })
        #expect(processes.allSatisfy { !$0.transcript.contains("MUTATED_COMMAND") })

        coordinator.close()
        for process in processes {
            process.stop()
        }
    }

    @MainActor
    @Test func terminalMultiExecTimeoutDisablesReadinessButPreservesMCPControl() async throws {
        let process = InteractiveProcessSession()
        process.start(executable: "/bin/sh", arguments: [], label: "broadcast timeout shell")
        process.setMCPControlEnabled(true)
        process.setBroadcastReady(true)
        let generation = try #require(process.executionGeneration)
        let batchID = UUID()
        #expect(process.reserveBroadcast(batchID: batchID, expectedGeneration: generation))

        let result = try await process.runBroadcastCommand(
            command: "sleep 2",
            batchID: batchID,
            expectedGeneration: generation,
            timeoutSeconds: 1,
            maxOutputBytes: 64
        )
        process.releaseBroadcastReservation(batchID: batchID)

        let recovery = try #require(process.structuredCommandRecovery)
        #expect(result.timedOut)
        #expect(result.didWriteCommandBytes)
        #expect(!process.isBroadcastReady)
        #expect(process.isMCPControlEnabled)
        #expect(process.requiresStructuredCommandRecovery)
        #expect(recovery.reason == .timedOut)
        #expect(!process.isStructuredCommandBusy)
        #expect(!process.transcript.contains("sleep 2"))
        #expect(process.confirmStructuredCommandRecovery(id: recovery.id))
        #expect(!process.requiresStructuredCommandRecovery)
        process.setBroadcastReady(true)
        #expect(process.isBroadcastReady)

        process.stop()
    }

    @MainActor
    @Test func terminalMultiExecRollsBackEveryReservationWhenOneTargetCannotReserve() async throws {
        let process = InteractiveProcessSession()
        process.start(executable: "/bin/sh", arguments: [], label: "reservation rollback shell")
        process.setBroadcastReady(true)
        let generation = try #require(process.executionGeneration)
        let targets = [
            TerminalBroadcastTarget(
                id: UUID(),
                profileName: "Duplicate A",
                address: "local",
                paneTitle: "Pane A",
                kind: .localShell,
                reviewedPID: process.pid,
                reviewedGeneration: generation,
                processSession: process
            ),
            TerminalBroadcastTarget(
                id: UUID(),
                profileName: "Duplicate B",
                address: "local",
                paneTitle: "Pane B",
                kind: .localShell,
                reviewedPID: process.pid,
                reviewedGeneration: generation,
                processSession: process
            ),
        ]

        let coordinator = TerminalBroadcastCoordinator()
        coordinator.open(targets: targets)
        coordinator.selectAllEligible()
        coordinator.command = "printf 'SHOULD_NOT_RUN'"
        coordinator.review()
        coordinator.didConfirmPromptState = true
        coordinator.runConfirmedBatch()

        #expect(coordinator.phase == .review)
        #expect(coordinator.errorMessage.contains("Nothing was sent"))
        #expect(!process.isStructuredCommandBusy)
        #expect(process.isBroadcastReady)
        #expect(!process.transcript.contains("SHOULD_NOT_RUN"))

        coordinator.close()
        process.stop()
    }

    @MainActor
    @Test func terminalBroadcastReservationExcludesMCPAndHumanInputUntilRelease() async throws {
        let process = InteractiveProcessSession()
        process.start(executable: "/bin/sh", arguments: [], label: "exclusive broadcast shell")
        process.setMCPControlEnabled(true)
        process.setBroadcastReady(true)
        let generation = try #require(process.executionGeneration)
        let batchID = UUID()
        #expect(process.reserveBroadcast(batchID: batchID, expectedGeneration: generation))

        process.sendRaw("printf 'BLOCKED_HUMAN_INPUT'\r")
        do {
            _ = try await process.runMCPCommand(
                command: "printf 'BLOCKED_MCP_INPUT'",
                timeoutSeconds: 2,
                maxOutputBytes: 64
            )
            Issue.record("Expected a reserved terminal to reject MCP execution")
        } catch let error as TerminalMCPCommandError {
            guard case .rejected(let reason) = error else {
                Issue.record("Expected a reservation rejection, got \(error)")
                process.stop()
                return
            }
            #expect(reason.contains("reserved"))
        }
        #expect(!process.transcript.contains("BLOCKED_HUMAN_INPUT"))
        #expect(!process.transcript.contains("BLOCKED_MCP_INPUT"))

        process.releaseBroadcastReservation(batchID: batchID)
        let result = try await process.runMCPCommand(
            command: "printf 'MCP_AFTER_RELEASE'",
            timeoutSeconds: 2,
            maxOutputBytes: 64
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "MCP_AFTER_RELEASE")
        #expect(result.didWriteCommandBytes)
        #expect(!process.isStructuredCommandBusy)

        process.stop()
    }

    @MainActor
    @Test func terminalBroadcastBoundsCapturedOutputAndHidesItFromThePane() async throws {
        let process = InteractiveProcessSession()
        process.start(executable: "/bin/sh", arguments: [], label: "bounded broadcast output shell")
        process.setBroadcastReady(true)
        let generation = try #require(process.executionGeneration)
        let batchID = UUID()
        #expect(process.reserveBroadcast(batchID: batchID, expectedGeneration: generation))

        let result = try await process.runBroadcastCommand(
            command: "i=0; while [ \"$i\" -lt 1024 ]; do printf Z; i=$((i + 1)); done",
            batchID: batchID,
            expectedGeneration: generation,
            timeoutSeconds: 3,
            maxOutputBytes: 128
        )
        process.releaseBroadcastReservation(batchID: batchID)

        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 128)
        #expect(result.truncated)
        #expect(result.didWriteCommandBytes)
        #expect(!process.transcript.contains(String(repeating: "Z", count: 32)))
        #expect(!process.isStructuredCommandBusy)

        process.stop()
    }

    @MainActor
    @Test func structuredCommandReportsPartialSendWhenItsPTYGenerationStops() async throws {
        let process = InteractiveProcessSession()
        process.start(executable: "/bin/sh", arguments: [], label: "partial send shell")
        process.setBroadcastReady(true)
        let generation = try #require(process.executionGeneration)
        let batchID = UUID()
        #expect(process.reserveBroadcast(batchID: batchID, expectedGeneration: generation))

        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-partial-send-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }
        let commandTask = Task {
            try await process.runBroadcastCommand(
                command: "printf ready > \(SSHCommandBuilder.shellQuote(markerURL.path)); sleep 5",
                batchID: batchID,
                expectedGeneration: generation,
                timeoutSeconds: 10,
                maxOutputBytes: 64
            )
        }

        let didWriteCommandBytes = await waitForStructuredCommandActivity(
            in: process
        ) { activity in
            activity.launchID == generation &&
                activity.didWriteCommandBytes
        }
        guard didWriteCommandBytes else {
            commandTask.cancel()
            process.stop()
            _ = try? await commandTask.value
            Issue.record("The broadcast command never wrote bytes to its reviewed PTY generation")
            return
        }
        let markerDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: markerURL.path),
              Date() < markerDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        process.stop()

        do {
            _ = try await commandTask.value
            Issue.record("Expected the stopped PTY generation to interrupt the command")
        } catch let error as TerminalMCPCommandError {
            guard case .executionInterrupted(let reason, let didWriteCommandBytes) = error else {
                Issue.record("Expected a structured interruption, got \(error)")
                return
            }
            #expect(reason.contains("process changed"))
            #expect(didWriteCommandBytes)
        }
        #expect(!process.isStructuredCommandBusy)
    }

    @MainActor
    @Test func cancellingBroadcastPropagatesAfterWriteAndAllowsReservationRelease() async throws {
        let process = InteractiveProcessSession()
        process.start(executable: "/bin/sh", arguments: [], label: "cancelled broadcast shell")
        process.setBroadcastReady(true)
        let generation = try #require(process.executionGeneration)
        let batchID = UUID()
        #expect(process.reserveBroadcast(batchID: batchID, expectedGeneration: generation))

        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-cancelled-send-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }
        let commandTask = Task {
            try await process.runBroadcastCommand(
                command: "printf ready > \(SSHCommandBuilder.shellQuote(markerURL.path)); sleep 5",
                batchID: batchID,
                expectedGeneration: generation,
                timeoutSeconds: 10,
                maxOutputBytes: 64
            )
        }

        let didWriteCommandBytes = await waitForStructuredCommandActivity(
            in: process
        ) { activity in
            activity.launchID == generation &&
                activity.didWriteCommandBytes
        }
        guard didWriteCommandBytes else {
            commandTask.cancel()
            process.stop()
            _ = try? await commandTask.value
            Issue.record("The cancellable broadcast never wrote command bytes")
            return
        }
        let markerDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: markerURL.path),
              Date() < markerDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        commandTask.cancel()

        do {
            _ = try await commandTask.value
            Issue.record("Expected cancellation to interrupt the broadcast command")
        } catch let error as TerminalMCPCommandError {
            guard case .executionInterrupted(let reason, let didWriteCommandBytes) = error else {
                Issue.record("Expected a structured cancellation, got \(error)")
                process.stop()
                return
            }
            #expect(reason.contains("cancelled"))
            #expect(didWriteCommandBytes)
        }

        process.releaseBroadcastReservation(batchID: batchID)
        let recovery = try #require(process.structuredCommandRecovery)
        #expect(recovery.reason == .interrupted)
        #expect(!process.isStructuredCommandBusy)
        #expect(process.confirmStructuredCommandRecovery(id: recovery.id))
        #expect(!process.requiresStructuredCommandRecovery)
        process.stop()
    }

    @MainActor
    @Test func stoppedStructuredCommandCannotWriteIntoReplacementPTYGeneration() async throws {
        let process = InteractiveProcessSession()
        process.start(executable: "/bin/sh", arguments: [], label: "old generation")
        process.setMCPControlEnabled(true)
        let oldMarker = "OLD_GENERATION_SHOULD_NOT_APPEAR"
        let longPadding = String(repeating: "x", count: 12_000)
        let oldTask = Task {
            try await process.runMCPCommand(
                command: "value=\(SSHCommandBuilder.shellQuote(longPadding)); printf '\(oldMarker)'",
                timeoutSeconds: 5,
                maxOutputBytes: 64
            )
        }

        try await Task.sleep(for: .milliseconds(70))
        process.stop()
        process.start(executable: "/bin/sh", arguments: [], label: "replacement generation")
        process.sendRaw("printf 'NEW_GENERATION_READY\\n'\r")

        _ = try? await oldTask.value
        let deadline = Date().addingTimeInterval(2)
        while !process.transcript.contains("NEW_GENERATION_READY"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(process.transcript.contains("NEW_GENERATION_READY"))
        #expect(!process.transcript.contains(oldMarker))
        #expect(!process.transcript.contains("__jts_mcp_cmd"))
        #expect(!process.isStructuredCommandBusy)

        process.stop()
    }

    @MainActor
    @Test func terminalWorkspaceStoreCreatesTabForEmptyWorkspaceOnSidebarOpen() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Sidebar", host: "sidebar.example.com", username: "ubuntu")
        context.insert(session)

        let store = TerminalWorkspaceStore()
        let workspace = store.workspace(for: session.persistentModelID)
        workspace.closeSelectedTab()

        #expect(workspace.tabs.isEmpty)
        #expect(workspace.selectedTabID == nil)
        #expect(TerminalWorkspaceState.Kind.preferredTerminalKind(for: session) == .ssh)
        #expect(TerminalWorkspaceState.Kind.ssh.isAvailable(for: .ssh))
        #expect(!TerminalWorkspaceState.Kind.ssh.isAvailable(for: .rdp))

        let reopenedWorkspace = store.ensureTabIfEmpty(
            for: session.persistentModelID,
            kind: .ssh
        )

        #expect(reopenedWorkspace === workspace)
        #expect(reopenedWorkspace.tabs.count == 1)
        #expect(reopenedWorkspace.selectedTabID == reopenedWorkspace.tabs[0].id)
        #expect(reopenedWorkspace.tabs[0].panes[0].kind == .ssh)

        let legacyRDP = RemoteSession(name: "Legacy RDP", host: "rdp.example.com", username: "ubuntu")
        legacyRDP.connectionTypeRawValue = "RDP"
        #if ENABLE_RDP_2
        #expect(legacyRDP.connectionType == .rdp)
        #expect(TerminalWorkspaceState.Kind.preferredTerminalKind(for: legacyRDP) == nil)
        #else
        #expect(legacyRDP.connectionType == .ssh)
        #expect(TerminalWorkspaceState.Kind.preferredTerminalKind(for: legacyRDP) == .ssh)
        #endif

        let local = RemoteSession(name: "Local Shell", connectionType: .localShell)
        #expect(local.isConnectable)
        #expect(local.address == "Local shell")
        #expect(TerminalWorkspaceState.Kind.preferredTerminalKind(for: local) == .localShell)
        #expect(TerminalWorkspaceState.Kind.localShell.isAvailable(for: .localShell))
        #expect(!TerminalWorkspaceState.Kind.localShell.isAvailable(for: .rdp))
    }

    @MainActor
    @Test func terminalWorkspaceListsOnlyAuthorizedMCPMatchingPanes() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let enabled = RemoteSession(name: "Root Shell", host: "root.example.com", username: "ubuntu")
        enabled.mcpEnabled = true
        enabled.mcpAlias = "root-shell"
        let local = RemoteSession(name: "Local Root", connectionType: .localShell)
        local.mcpEnabled = true
        local.mcpAlias = "local-root"
        let disabled = RemoteSession(name: "Disabled", host: "disabled.example.com", username: "ubuntu")
        disabled.mcpEnabled = false
        context.insert(enabled)
        context.insert(local)
        context.insert(disabled)
        try context.save()

        let store = TerminalWorkspaceStore()
        let enabledWorkspace = store.workspace(for: enabled.persistentModelID)
        let enabledPane = try #require(enabledWorkspace.selectedTab?.panes.first)
        let enabledProcess = try #require(enabledWorkspace.processSession(for: enabledPane))
        enabledProcess.start(executable: "/bin/sh", arguments: [], label: "enabled shell")
        enabledProcess.setMCPControlEnabled(true)

        let disabledWorkspace = store.workspace(for: disabled.persistentModelID)
        let disabledPane = try #require(disabledWorkspace.selectedTab?.panes.first)
        let disabledProcess = try #require(disabledWorkspace.processSession(for: disabledPane))
        disabledProcess.start(executable: "/bin/sh", arguments: [], label: "disabled shell")
        disabledProcess.setMCPControlEnabled(true)

        let localWorkspace = store.workspace(for: local.persistentModelID, initialKind: .localShell)
        let localPane = try #require(localWorkspace.selectedTab?.panes.first)
        let localProcess = try #require(localWorkspace.processSession(for: localPane))
        localProcess.start(executable: "/bin/sh", arguments: [], label: "local root shell")
        localProcess.setMCPControlEnabled(true)

        enabledWorkspace.addTab(kind: .localShell)
        let sshProfileLocalPane = try #require(enabledWorkspace.selectedTab?.panes.first)
        let sshProfileLocalProcess = try #require(
            enabledWorkspace.processSession(for: sshProfileLocalPane)
        )
        sshProfileLocalProcess.start(executable: "/bin/sh", arguments: [], label: "unmatched local shell")
        sshProfileLocalProcess.setMCPControlEnabled(true)

        let terminals = store.authorizedOpenTerminals(sessions: [enabled, disabled, local])

        enabledProcess.stop()
        disabledProcess.stop()
        localProcess.stop()
        sshProfileLocalProcess.stop()

        #expect(terminals.map(\.info.serverAlias) == ["root-shell", "local-root"])
        #expect(terminals.map(\.info.connectionType) == [RemoteConnectionType.ssh.rawValue, RemoteConnectionType.localShell.rawValue])
        #expect(terminals.first?.info.terminalID == enabledPane.id.uuidString)
        #expect(terminals.last?.info.terminalID == localPane.id.uuidString)
    }

    @MainActor
    @Test func terminalWorkspaceRevokesTemporaryMCPControlWithoutStoppingSession() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Temporary", host: "temporary.example.com", username: "ubuntu")
        session.mcpEnabled = true
        context.insert(session)
        try context.save()

        let store = TerminalWorkspaceStore()
        let workspace = store.workspace(for: session.persistentModelID)
        let pane = try #require(workspace.selectedTab?.panes.first)
        let process = try #require(workspace.processSession(for: pane))
        process.start(executable: "/bin/sh", arguments: [], label: "temporary mcp control")
        process.setMCPControlEnabled(true)

        #expect(process.isRunning)
        #expect(process.isMCPControlEnabled)
        #expect(store.authorizedOpenTerminals(sessions: [session]).count == 1)

        store.revokeAllMCPControl()

        #expect(process.isRunning)
        #expect(!process.isMCPControlEnabled)
        #expect(store.authorizedOpenTerminals(sessions: [session]).isEmpty)

        process.stop()
    }

    @MainActor
    @Test func terminalWorkspaceAuthorizesAllRunningPanesForPersistentMCPControl() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Persistent", host: "persistent.example.com", username: "ubuntu")
        session.mcpEnabled = true
        session.mcpAlwaysAllowTerminalControl = true
        session.mcpAlias = "persistent"
        context.insert(session)
        try context.save()

        let store = TerminalWorkspaceStore()
        let workspace = store.workspace(for: session.persistentModelID)
        workspace.addTab(kind: .ssh)
        let firstPane = try #require(workspace.tabs.first?.panes.first)
        workspace.setMCPName("prod-root", for: firstPane.id)

        var processes: [InteractiveProcessSession] = []
        for tab in workspace.tabs {
            guard let pane = tab.panes.first else { continue }
            let process = try #require(workspace.processSession(for: pane))
            process.start(executable: "/bin/sh", arguments: [], label: "persistent mcp control")
            processes.append(process)
            #expect(!process.isMCPControlEnabled)
        }

        let terminals = store.authorizedOpenTerminals(sessions: [session])

        store.revokeAllMCPControl()
        let terminalsAfterTemporaryRevoke = store.authorizedOpenTerminals(sessions: [session])
        for process in processes {
            process.stop()
        }

        #expect(terminals.count == 2)
        #expect(terminals.map(\.info.serverAlias) == ["persistent", "persistent"])
        #expect(terminals.map(\.info.mcpName) == ["prod-root", "persistent · Terminal tab 2"])
        #expect(terminals.map { $0.info.dictionary["mcpName"] as? String } == ["prod-root", "persistent · Terminal tab 2"])
        #expect(terminalsAfterTemporaryRevoke.count == 2)
    }

    @MainActor
    @Test func terminalMCPBridgeServesAuthorizedPTYCommandsOverSocket() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let remote = RemoteSession(name: "Bridge", host: "bridge.example.com", username: "ubuntu")
        remote.mcpEnabled = true
        remote.mcpAlias = "bridge"
        context.insert(remote)
        try context.save()

        let store = TerminalWorkspaceStore()
        let workspace = store.workspace(for: remote.persistentModelID)
        let pane = try #require(workspace.selectedTab?.panes.first)
        let process = try #require(workspace.processSession(for: pane))
        process.start(executable: "/bin/sh", arguments: [], label: "bridge shell")
        process.setMCPControlEnabled(true)

        let server = TerminalMCPBridgeServer(runtimeRoot: root)
        server.start(terminalWorkspaceStore: store, modelContext: context)
        defer {
            process.stop()
            server.stop()
        }

        let client = TerminalMCPBridgeClient(runtimeRoot: root)
        let terminals = try await Task.detached {
            try client.listOpenTerminals()
        }.value
        let terminal = try #require(terminals.first)
        let terminalID = try #require(terminal["terminalId"] as? String)

        let result = try await Task.detached {
            try client.executeTerminal(
                terminalID: terminalID,
                command: "printf bridge-ok # PRIVATE_TOKEN_should_not_persist",
                timeoutSeconds: 3,
                maxOutputBytes: 64,
                clientID: "codex@2.0"
            )
        }.value
        let audit = try #require(context.fetch(FetchDescriptor<MCPAuditEntry>()).last)

        #expect(terminals.count == 1)
        #expect(terminal["serverAlias"] as? String == "bridge")
        #expect(terminal["connectionType"] as? String == RemoteConnectionType.ssh.rawValue)
        #expect(result["connectionType"] as? String == RemoteConnectionType.ssh.rawValue)
        #expect(result["exitCode"] as? Int == 0)
        #expect(result["stdout"] as? String == "bridge-ok")
        #expect(result["timedOut"] as? Bool == false)
        #expect(audit.clientID == "codex@2.0")
        #expect(audit.operationSummary == "command")
        #expect(!audit.operationSummary.contains("PRIVATE_TOKEN"))
    }

    @MainActor
    @Test func terminalMCPBridgeServesAuthorizedLocalShellPTYCommandsOverSocket() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-local-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let local = RemoteSession(name: "Root Local", connectionType: .localShell)
        local.mcpEnabled = true
        local.mcpAlias = "root-local"
        context.insert(local)
        try context.save()

        let store = TerminalWorkspaceStore()
        let workspace = store.workspace(for: local.persistentModelID, initialKind: .localShell)
        let pane = try #require(workspace.selectedTab?.panes.first)
        let process = try #require(workspace.processSession(for: pane))
        process.start(executable: "/bin/sh", arguments: [], label: "local root shell")
        process.setMCPControlEnabled(true)

        let server = TerminalMCPBridgeServer(runtimeRoot: root)
        server.start(terminalWorkspaceStore: store, modelContext: context)
        defer {
            process.stop()
            server.stop()
        }

        let client = TerminalMCPBridgeClient(runtimeRoot: root)
        let terminals = try await Task.detached {
            try client.listOpenTerminals()
        }.value
        let terminal = try #require(terminals.first)
        let terminalID = try #require(terminal["terminalId"] as? String)

        let result = try await Task.detached {
            try client.executeTerminal(
                terminalID: terminalID,
                command: "printf local-shell-ok",
                timeoutSeconds: 3,
                maxOutputBytes: 64
            )
        }.value

        #expect(terminals.count == 1)
        #expect(terminal["serverAlias"] as? String == "root-local")
        #expect(terminal["connectionType"] as? String == RemoteConnectionType.localShell.rawValue)
        #expect(result["connectionType"] as? String == RemoteConnectionType.localShell.rawValue)
        #expect(result["exitCode"] as? Int == 0)
        #expect(result["stdout"] as? String == "local-shell-ok")
        #expect(result["timedOut"] as? Bool == false)
    }

    @MainActor
    @Test func terminalMCPBridgeOpensAuthorizedSSHTerminalOverSocket() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-open-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let remote = RemoteSession(name: "Open Bridge", host: "203.0.113.1", username: "ubuntu")
        remote.mcpEnabled = true
        remote.mcpAlwaysAllowTerminalControl = true
        remote.mcpAlias = "open-bridge"
        context.insert(remote)
        try context.save()

        let store = TerminalWorkspaceStore()
        let server = TerminalMCPBridgeServer(runtimeRoot: root)
        server.start(terminalWorkspaceStore: store, modelContext: context)
        defer {
            store.stopAllProcesses()
            server.stop()
        }

        let client = TerminalMCPBridgeClient(runtimeRoot: root)
        let opened = try await Task.detached {
            try client.openTerminal(serverAlias: "open-bridge", waitSeconds: 3)
        }.value
        let navigationRequest = store.navigationRequest

        #expect(opened["serverAlias"] as? String == "open-bridge")
        #expect((opened["terminalId"] as? String)?.isEmpty == false)
        #expect(opened["didStart"] as? Bool == true)
        #expect(opened["persistentMCPControl"] as? Bool == true)
        #expect(opened["mcpControlAuthorized"] as? Bool == true)
        #expect(navigationRequest?.sessionID == remote.persistentModelID)
    }

    @MainActor
    @Test func terminalMCPBridgeOpensAuthorizedLocalShellOverSocket() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-terminal-local-open-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let local = RemoteSession(name: "Root Local", connectionType: .localShell)
        local.mcpEnabled = true
        local.mcpAlwaysAllowTerminalControl = true
        local.mcpAlias = "root-local"
        context.insert(local)
        try context.save()

        let store = TerminalWorkspaceStore()
        let server = TerminalMCPBridgeServer(runtimeRoot: root)
        server.start(terminalWorkspaceStore: store, modelContext: context)
        defer {
            store.stopAllProcesses()
            server.stop()
        }

        let client = TerminalMCPBridgeClient(runtimeRoot: root)
        let opened = try await Task.detached {
            try client.openTerminal(serverAlias: "root-local", waitSeconds: 3)
        }.value
        let navigationRequest = store.navigationRequest

        #expect(opened["serverAlias"] as? String == "root-local")
        #expect((opened["terminalId"] as? String)?.isEmpty == false)
        #expect(opened["connectionType"] as? String == RemoteConnectionType.localShell.rawValue)
        #expect(opened["didStart"] as? Bool == true)
        #expect(opened["persistentMCPControl"] as? Bool == true)
        #expect(opened["mcpControlAuthorized"] as? Bool == true)
        #expect(opened["running"] as? Bool == true)
        #expect(navigationRequest?.sessionID == local.persistentModelID)
    }

    @Test func terminalWorkspaceKeepsPaneProcessesStableAcrossViewRebuilds() async throws {
        let workspace = await MainActor.run {
            TerminalWorkspaceState(initialKind: .ssh)
        }

        await MainActor.run {
            guard let pane = workspace.selectedTab?.panes.first else {
                Issue.record("Expected initial terminal pane")
                return
            }

            let first = workspace.processSession(for: pane)
            let second = workspace.processSession(for: pane)
            #expect(first === second)
        }
    }

    @Test func terminalWorkspaceKeepsPaneTerminalSurfaceAcrossFeatureSwitches() async throws {
        let workspace = await MainActor.run {
            TerminalWorkspaceState(initialKind: .ssh)
        }

        await MainActor.run {
            guard let pane = workspace.selectedTab?.panes.first else {
                Issue.record("Expected initial terminal pane")
                return
            }

            let first = workspace.terminalSurface(for: pane) { NSObject() }
            let second = workspace.terminalSurface(for: pane) { NSObject() }

            #expect(first === second)
        }
    }

    @Test func terminalGridMetricsClampTransientTinySwiftUISizes() async throws {
        let tinyGrid = TerminalGridMetrics.clampedGrid(columns: 2, rows: 1)
        let tinyPixelSize = TerminalGridMetrics.clampedPixelSize(CGSize(width: 1, height: 1))

        #expect(tinyGrid.columns == TerminalGridMetrics.minimumColumns)
        #expect(tinyGrid.rows == TerminalGridMetrics.minimumRows)
        #expect(tinyPixelSize.width == TerminalGridMetrics.minimumPixelSize.width)
        #expect(tinyPixelSize.height == TerminalGridMetrics.minimumPixelSize.height)

        let largePixelSize = TerminalGridMetrics.clampedPixelSize(CGSize(width: 1200, height: 800))
        #expect(largePixelSize.width == 1200)
        #expect(largePixelSize.height == 800)
    }

    @Test func terminalRightClickPolicyShowsCopyMenuForSelectedTextOtherwisePastes() async throws {
        #expect(TerminalRightClickPolicy.action(selectedText: "uptime") == .showCopyMenu)
        #expect(TerminalRightClickPolicy.action(selectedText: " ") == .showCopyMenu)
        #expect(TerminalRightClickPolicy.action(selectedText: "") == .pasteClipboard)
        #expect(TerminalRightClickPolicy.action(selectedText: nil) == .pasteClipboard)
    }

    @Test func mainWindowPolicyKeepsTerminalWorkspaceAboveSafeMinimum() async throws {
        #expect(MainWindowSizePolicy.minimumContentSize == CGSize(width: 900, height: 600))
        #expect(MainWindowSizePolicy.preferredContentSize == CGSize(width: 1_320, height: 820))
        #expect(MainWindowSizePolicy.minimumContentSize.width >= TerminalGridMetrics.minimumPixelSize.width + 240)
        #expect(!MainWindowSizePolicy.shouldGrow(contentSize: MainWindowSizePolicy.minimumContentSize))
        #expect(MainWindowSizePolicy.shouldGrow(contentSize: CGSize(width: 899, height: 600)))
        #expect(MainWindowSizePolicy.shouldGrow(contentSize: CGSize(width: 900, height: 599)))

        await MainActor.run {
            let window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.collectionBehavior.insert(.fullScreenNone)

            MainWindowSizePolicy.apply(to: window)
            let minimumFrameSize = MainWindowSizePolicy.minimumFrameSize(for: window)
            let fixedFrameSize = MainWindowSizePolicy.fixedFrameSize(for: window)
            let largeFrameSize = CGSize(width: fixedFrameSize.width + 320, height: fixedFrameSize.height + 180)
            let clampedSmallFrameSize = MainWindowSizePolicy.clampedFrameSize(
                CGSize(width: 640, height: 420),
                for: window
            )
            let clampedLargeFrameSize = MainWindowSizePolicy.clampedFrameSize(
                largeFrameSize,
                for: window
            )
            let boundedRemoteFrameSize = MainWindowSizePolicy.boundedFrameSize(
                CGSize(width: 1_920, height: 1_291),
                minimumSize: MainWindowSizePolicy.minimumContentSize,
                maximumSize: CGSize(width: 1_512, height: 894)
            )
            let zoomFrame = NSRect(x: 0, y: 0, width: 1600, height: 980)
            let standardFrame = MainWindowSizePolicy.standardFrame(for: window, defaultFrame: zoomFrame)
            let toolbarWindow = NSWindow(
                contentRect: NSRect(
                    origin: .zero,
                    size: MainWindowSizePolicy.minimumContentSize
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            toolbarWindow.toolbar = NSToolbar(
                identifier: NSToolbar.Identifier("main-window-size-policy-test")
            )
            toolbarWindow.toolbarStyle = .unified
            toolbarWindow.contentMinSize = MainWindowSizePolicy.minimumContentSize
            toolbarWindow.minSize = MainWindowSizePolicy.minimumFrameSize(
                for: toolbarWindow
            )
            toolbarWindow.setContentSize(MainWindowSizePolicy.minimumContentSize)
            let toolbarContentSize = MainWindowSizePolicy.contentSize(
                for: toolbarWindow
            )
            MainWindowSizePolicy.snapToFixedFrameIfNeeded(toolbarWindow)

            #expect(window.contentMinSize == MainWindowSizePolicy.minimumContentSize)
            #expect(window.minSize == minimumFrameSize)
            #expect(window.frame.size == minimumFrameSize)
            #expect(clampedSmallFrameSize == minimumFrameSize)
            #expect(clampedLargeFrameSize == MainWindowSizePolicy.boundedFrameSize(
                largeFrameSize,
                minimumSize: minimumFrameSize,
                maximumSize: window.screen?.visibleFrame.size
            ))
            #expect(boundedRemoteFrameSize == CGSize(width: 1_512, height: 894))
            if let visibleFrame = window.screen?.visibleFrame {
                #expect(standardFrame == visibleFrame)
            } else {
                #expect(standardFrame == zoomFrame)
            }
            #expect(MainWindowSizePolicy.allowsFrameSize(standardFrame.size, for: window))
            #expect(
                MainWindowSizePolicy.approximately(
                    toolbarContentSize,
                    matches: MainWindowSizePolicy.minimumContentSize
                )
            )
            #expect(
                MainWindowSizePolicy.approximately(
                    MainWindowSizePolicy.contentSize(for: toolbarWindow),
                    matches: MainWindowSizePolicy.minimumContentSize
                )
            )
            #expect(window.collectionBehavior.contains(.fullScreenPrimary))
            #expect(!window.collectionBehavior.contains(.fullScreenNone))
        }
    }

    @Suite(.serialized)
    @MainActor
    struct MainWindowLifecycleTests {

    @MainActor
    @Test func mainWindowLifecycleConfiguresWindowMenuIdentity() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        MainWindowLifecycle.configure(window)

        #expect(window.title == MainWindowLifecycle.title)
        #expect(window.identifier == MainWindowLifecycle.identifier)
        #expect(window.tabbingIdentifier == MainWindowLifecycle.identifier.rawValue)
        #expect(MainWindowLifecycle.isMainWindow(window))
        #expect(MainWindowLifecycle.showMainWindowCommandTitle(language: .english) == "Show Main Window")
        #expect(MainWindowLifecycle.showMainWindowCommandTitle(language: .simplifiedChinese) == "显示主窗口")
        #expect(MainWindowLifecycle.showMainWindowCommandTitle(language: .english) != MainWindowLifecycle.title)
        #expect(MainWindowLifecycle.launchActivationRetryDelays.count >= 3)
        #expect(MainWindowLifecycle.launchActivationRetryDelays == MainWindowLifecycle.launchActivationRetryDelays.sorted())
        #expect(MainWindowLifecycle.launchActivationRetryDelays.first ?? 1 < 0.5)
    }

    @MainActor
    @Test func mainWindowLifecycleBringsExistingMainWindowForward() async throws {
        let competingWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        competingWindow.isReleasedWhenClosed = false
        window.isReleasedWhenClosed = false
        defer {
            competingWindow.orderOut(nil)
            competingWindow.close()
            window.orderOut(nil)
            window.close()
        }

        MainWindowLifecycle.configure(competingWindow)
        competingWindow.orderOut(nil)
        MainWindowLifecycle.configure(window)
        window.orderOut(nil)

        #expect(MainWindowLifecycle.bringExistingMainWindowToFront())
        #expect(window.isVisible)
    }

    @MainActor
    @Test func mainWindowLifecycleResolvesConfiguredWindowInsteadOfTransientKeyWindow() async throws {
        let mainWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let competingWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.isReleasedWhenClosed = false
        competingWindow.isReleasedWhenClosed = false
        defer {
            competingWindow.orderOut(nil)
            competingWindow.close()
            mainWindow.orderOut(nil)
            mainWindow.close()
        }

        MainWindowLifecycle.configure(mainWindow)
        mainWindow.orderFront(nil)
        competingWindow.makeKeyAndOrderFront(nil)
        mainWindow.collectionBehavior.remove(.fullScreenPrimary)
        mainWindow.collectionBehavior.insert(.fullScreenNone)

        #expect(MainWindowLifecycle.resolvedMainWindow() === mainWindow)
        MainWindowLifecycle.prepareForFullScreen(mainWindow)
        #expect(mainWindow.isVisible)
        #expect(!mainWindow.isMiniaturized)
        #expect(mainWindow.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!mainWindow.collectionBehavior.contains(.fullScreenNone))
        #expect(MainWindowLifecycle.resolvedMainWindow() === mainWindow)
    }

    @MainActor
    @Test func mainWindowLifecycleCoalescesPendingFullScreenTogglesOnTheResolvedWindow() async throws {
        final class FullScreenTrackingWindow: NSWindow {
            var toggleCount = 0

            override func toggleFullScreen(_ sender: Any?) {
                toggleCount += 1
            }
        }

        let mainWindow = FullScreenTrackingWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let competingWindow = FullScreenTrackingWindow(
            contentRect: NSRect(x: 120, y: 120, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.isReleasedWhenClosed = false
        competingWindow.isReleasedWhenClosed = false
        defer {
            competingWindow.orderOut(nil)
            competingWindow.close()
            mainWindow.orderOut(nil)
            mainWindow.close()
        }

        MainWindowLifecycle.configure(mainWindow)
        mainWindow.orderFront(nil)
        competingWindow.makeKeyAndOrderFront(nil)

        #expect(MainWindowLifecycle.toggleFullScreen())
        #expect(MainWindowLifecycle.toggleFullScreen())
        try await Task.sleep(for: .milliseconds(150))

        #expect(mainWindow.toggleCount == 1)
        #expect(competingWindow.toggleCount == 0)

        // AppKit has accepted the toggle call, but its will-transition callback
        // has not arrived yet. Do not enqueue a second toggle in that gap.
        #expect(!MainWindowLifecycle.toggleFullScreen())
        MainWindowLifecycle.fullScreenTransitionWillBegin(for: mainWindow)
        #expect(!MainWindowLifecycle.toggleFullScreen())
        try await Task.sleep(for: .milliseconds(100))
        #expect(mainWindow.toggleCount == 1)
        #expect(competingWindow.toggleCount == 0)

        MainWindowLifecycle.fullScreenTransitionDidEnd(for: mainWindow)
        #expect(MainWindowLifecycle.toggleFullScreen())
        try await Task.sleep(for: .milliseconds(100))
        #expect(mainWindow.toggleCount == 2)
        MainWindowLifecycle.fullScreenTransitionDidEnd(for: mainWindow)
    }

    @MainActor
    @Test func mainWindowLifecycleUnlocksAfterFullScreenTransitionFailure() async throws {
        final class FullScreenTrackingWindow: NSWindow {
            var toggleCount = 0

            override func toggleFullScreen(_ sender: Any?) {
                toggleCount += 1
            }
        }

        let window = FullScreenTrackingWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            MainWindowLifecycle.fullScreenTransitionDidEnd(for: window)
            window.orderOut(nil)
            window.close()
        }

        MainWindowLifecycle.configure(window)
        window.orderFront(nil)
        #expect(MainWindowLifecycle.toggleFullScreen())
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.toggleCount == 1)

        MainWindowLifecycle.fullScreenTransitionWillBegin(for: window)
        #expect(!MainWindowLifecycle.toggleFullScreen())
        MainWindowLifecycle.fullScreenTransitionDidFail(for: window)
        #expect(MainWindowLifecycle.toggleFullScreen())
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.toggleCount == 2)
    }

    }

    @Test func appStoreReviewLinksUseHTTPSURLs() async throws {
        for link in AppStoreReviewLinks.allCases {
            #expect(link.url.scheme == "https")
            #expect(link.url.host == "www.lljts.com")
            #expect(!link.url.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func workspaceToolbarFeaturesExposeHoverNames() async throws {
        let helpLabels = WorkspaceFeature.allCases.map(\.toolbarHelp)
        let chineseHelpLabels = WorkspaceFeature.allCases.map { $0.toolbarHelp(language: .simplifiedChinese) }

        #expect(helpLabels.count == WorkspaceFeature.allCases.count)
        #expect(!helpLabels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
        #expect(Set(helpLabels).count == WorkspaceFeature.allCases.count)
        #expect(helpLabels.contains("Terminal"))
        #expect(helpLabels.contains("Files"))
        #expect(helpLabels.contains("Tunnels"))
        #expect(helpLabels.contains("Password"))
        #expect(helpLabels.contains("Import / Export"))
        #expect(chineseHelpLabels.contains("终端"))
        #expect(chineseHelpLabels.contains("文件"))
        #expect(chineseHelpLabels.contains("隧道"))
        #expect(chineseHelpLabels.contains("密码"))
        #expect(chineseHelpLabels.contains("导入导出"))
    }

    @Test func workspaceFeaturesMatchConnectionCapabilitiesAndResolveInvalidSelections() {
        #expect(WorkspaceFeature.available(for: .ssh) == [
            .command,
            .files,
            .tunnels,
            .credentials,
            .profiles
        ])
        #expect(WorkspaceFeature.available(for: .localShell) == [
            .command,
            .profiles
        ])
        #if ENABLE_RDP_2
        #expect(WorkspaceFeature.available(for: .rdp) == [
            .desktop,
            .profiles
        ])
        #expect(WorkspaceFeature.defaultFeature(for: .rdp) == .desktop)
        #expect(WorkspaceFeature.resolvedSelection(.files, for: .rdp) == .desktop)
        #else
        #expect(WorkspaceFeature.available(for: .rdp) == [.profiles])
        #expect(WorkspaceFeature.defaultFeature(for: .rdp) == .profiles)
        #expect(WorkspaceFeature.resolvedSelection(.files, for: .rdp) == .profiles)
        #endif
        #expect(WorkspaceFeature.defaultFeature(for: .ssh) == .command)
        #expect(WorkspaceFeature.defaultFeature(for: .localShell) == .command)
        #expect(WorkspaceFeature.resolvedSelection(.files, for: .ssh) == .files)
        #expect(WorkspaceFeature.resolvedSelection(.files, for: .localShell) == .command)
        #expect(WorkspaceFeature.resolvedSelection(.desktop, for: .ssh) == .command)
        #expect(WorkspaceFeature.resolvedSelection(.profiles, for: .localShell) == .profiles)
    }

    @Test func grantManagementEntryRemainsVisibleForEveryConnectionType() {
        #expect(RemoteGrantManagementEntryPolicy.isVisible(for: .ssh, mcpEnabled: false))
        #expect(RemoteGrantManagementEntryPolicy.isVisible(for: .ssh, mcpEnabled: true))
        #expect(RemoteGrantManagementEntryPolicy.isVisible(for: .localShell, mcpEnabled: false))
        #expect(RemoteGrantManagementEntryPolicy.isVisible(for: .localShell, mcpEnabled: true))
        #expect(RemoteGrantManagementEntryPolicy.isVisible(for: .rdp, mcpEnabled: false))
        #expect(RemoteGrantManagementEntryPolicy.isVisible(for: .rdp, mcpEnabled: true))
    }

    @Test func selectedServerOpenCommandMatchesConnectionTypeAndLanguage() {
        #expect(
            JTSTerminalServerOpenCommand.resolved(for: nil)
                == .interactiveTerminal
        )
        #expect(
            JTSTerminalServerOpenCommand.resolved(for: .ssh)
                == .interactiveTerminal
        )
        #expect(
            JTSTerminalServerOpenCommand.resolved(for: .localShell)
                == .interactiveTerminal
        )
        #expect(
            JTSTerminalServerOpenCommand.resolved(for: .rdp)
                == .desktop
        )
        #expect(
            JTSTerminalServerOpenCommand.interactiveTerminal.title(
                language: .english
            ) == "Open Interactive Terminal"
        )
        #expect(
            JTSTerminalServerOpenCommand.interactiveTerminal.title(
                language: .simplifiedChinese
            ) == "打开交互式终端"
        )
        #expect(
            JTSTerminalServerOpenCommand.desktop.title(language: .english)
                == "Open Desktop"
        )
        #expect(
            JTSTerminalServerOpenCommand.desktop.title(
                language: .simplifiedChinese
            ) == "打开桌面"
        )
    }

    @Test func appLanguageDefaultsToEnglishAndTranslatesCoreLabels() async throws {
        #expect(AppLanguage.resolved(from: "") == .english)
        #expect(AppLanguage.defaultLanguage == .english)
        #expect(AppLanguage.english.localized("New Server", "新建服务器") == "New Server")
        #expect(AppLanguage.simplifiedChinese.localized("New Server", "新建服务器") == "新建服务器")
        #expect(RemoteConnectionType.ssh.displayName(language: .english) == "SSH")
        #expect(RemoteConnectionType.ssh.displayName(language: .simplifiedChinese) == "SSH")
        #expect(RemoteConnectionType.localShell.displayName(language: .english) == "Local Shell")
        #expect(RemoteConnectionType.localShell.displayName(language: .simplifiedChinese) == "本地 Shell")
        #expect(WorkspaceFeature.command.title == "Terminal")
        #expect(WorkspaceFeature.command.title(language: .simplifiedChinese) == "终端")
    }

    @Test func uiTestLanguageBootstrapUsesMutableDefaultsInsteadOfArgumentDomain() throws {
        let suiteName = "jts-ui-language-bootstrap-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            AppLanguage.simplifiedChinese.rawValue,
            forKey: AppLanguage.storageKey
        )

        #expect(!UITestAppLanguageBootstrap.apply(
            environment: [
                UITestAppLanguageBootstrap.initialLanguageEnvironmentKey: "en",
            ],
            bundleIdentifier: UITestAppLanguageBootstrap.isolatedApplicationBundleIdentifier,
            defaults: defaults
        ))
        #expect(
            defaults.string(forKey: AppLanguage.storageKey)
                == AppLanguage.simplifiedChinese.rawValue
        )

        #expect(UITestAppLanguageBootstrap.apply(
            environment: [
                "JTS_TERMINAL_UI_TESTING": "1",
                UITestAppLanguageBootstrap.initialLanguageEnvironmentKey: "en",
            ],
            bundleIdentifier: UITestAppLanguageBootstrap.isolatedApplicationBundleIdentifier,
            defaults: defaults
        ))
        #expect(
            defaults.string(forKey: AppLanguage.storageKey)
                == AppLanguage.english.rawValue
        )

        #expect(!UITestAppLanguageBootstrap.apply(
            environment: [
                "JTS_TERMINAL_UI_TESTING": "1",
                UITestAppLanguageBootstrap.initialLanguageEnvironmentKey: "invalid",
            ],
            bundleIdentifier: UITestAppLanguageBootstrap.isolatedApplicationBundleIdentifier,
            defaults: defaults
        ))
        #expect(
            defaults.string(forKey: AppLanguage.storageKey)
                == AppLanguage.english.rawValue
        )

        #expect(!UITestAppLanguageBootstrap.apply(
            environment: [
                "JTS_TERMINAL_UI_TESTING": "1",
                UITestAppLanguageBootstrap.initialLanguageEnvironmentKey: "zh-Hans",
            ],
            bundleIdentifier: "com.lljts.JTSTerminal",
            defaults: defaults
        ))
        #expect(
            defaults.string(forKey: AppLanguage.storageKey)
                == AppLanguage.english.rawValue
        )
    }

    @Test func applicationTerminationPolicyBypassesOnlyIsolatedTestProcesses() {
        #expect(!ApplicationTerminationPolicy.bypassesRemoteProcessConfirmation(
            environment: [:],
            bundleIdentifier: UITestAppLanguageBootstrap.isolatedApplicationBundleIdentifier
        ))
        #expect(!ApplicationTerminationPolicy.bypassesRemoteProcessConfirmation(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            bundleIdentifier: UITestAppLanguageBootstrap.isolatedApplicationBundleIdentifier
        ))
        #expect(ApplicationTerminationPolicy.bypassesRemoteProcessConfirmation(
            environment: [
                "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
                "XCTestBundlePath": "/tmp/JTSTerminalRDP2Tests.xctest",
            ],
            bundleIdentifier: UITestAppLanguageBootstrap.isolatedApplicationBundleIdentifier
        ))
        #expect(ApplicationTerminationPolicy.bypassesRemoteProcessConfirmation(
            environment: ["JTS_TERMINAL_UI_TESTING": "1"],
            bundleIdentifier: UITestAppLanguageBootstrap.isolatedApplicationBundleIdentifier
        ))
        #expect(!ApplicationTerminationPolicy.bypassesRemoteProcessConfirmation(
            environment: [
                "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
                "XCTestBundlePath": "/tmp/JTSTerminalRDP2Tests.xctest",
                "JTS_TERMINAL_UI_TESTING": "1",
            ],
            bundleIdentifier: "com.lljts.JTSTerminal"
        ))
    }

    @Test func localShellLaunchConfigurationUsesInteractiveUserShell() {
        #expect(LocalShellLaunchConfiguration.resolved(environment: ["SHELL": "/bin/bash"]) == LocalShellLaunchConfiguration(
            executable: "/bin/bash",
            arguments: ["-i"],
            label: "local shell"
        ))
        #expect(LocalShellLaunchConfiguration.resolved(environment: ["SHELL": "  "]) == LocalShellLaunchConfiguration(
            executable: "/bin/zsh",
            arguments: ["+m", "-i"],
            label: "local shell"
        ))
        #expect(LocalShellLaunchConfiguration.resolved(environment: ["SHELL": "/bin/zsh"]) == LocalShellLaunchConfiguration(
            executable: "/bin/zsh",
            arguments: ["+m", "-i"],
            label: "local shell"
        ))
    }

    @Test func toolbarTooltipTimingIsFastEnoughForPointerHover() async throws {
        #expect(ToolbarTooltipTiming.showDelayMilliseconds <= 200)
        #expect(ToolbarTooltipTiming.showDelaySeconds < 0.25)
    }

    @Test func welcomeGuideShowsOnceAndCoversMCPSetup() async throws {
        #expect(WelcomeGuidePolicy.shouldShow(hasSeenGuide: false, environment: [:]))
        #expect(!WelcomeGuidePolicy.shouldShow(hasSeenGuide: true, environment: [:]))
        #expect(!WelcomeGuidePolicy.shouldShow(
            hasSeenGuide: false,
            environment: ["JTS_TERMINAL_UI_TESTING": "1"]
        ))

        let mcpText = WelcomeGuideItem.mcpSteps(language: .english)
            .map { "\($0.title) \($0.message)" }
            .joined(separator: "\n")

        #expect(mcpText.contains("MCP"))
        #expect(mcpText.contains("top-level MCP menu"))
        #expect(mcpText.contains("canonical endpoint"))
        #expect(mcpText.contains("without asking for a filename or path"))
        #expect(mcpText.contains("Claude Desktop or CLI"))
        #expect(mcpText.contains("Cursor"))
        #expect(mcpText.contains("Codex Desktop or CLI"))
        #expect(mcpText.contains("Antigravity"))
        #expect(mcpText.contains("allowlist"))

        let connectionText = WelcomeGuideItem.primarySteps(language: .english)
            .map { "\($0.title) \($0.message)" }
            .joined(separator: "\n")
        let chineseConnectionText = WelcomeGuideItem.primarySteps(language: .simplifiedChinese)
            .map { "\($0.title) \($0.message)" }
            .joined(separator: "\n")

        #expect(connectionText.contains("SSH"))
        #expect(connectionText.contains("Local Shell"))
        #expect(connectionText.contains("Windows RDP"))
        #expect(connectionText.contains("certificate"))
        #expect(connectionText.contains("Companion is optional"))
        #expect(chineseConnectionText.contains("本地 Shell"))
        #expect(chineseConnectionText.contains("Windows RDP"))
        #expect(chineseConnectionText.contains("证书"))
        #expect(chineseConnectionText.contains("Companion 为可选"))
    }

    @Test func terminalFollowOutputPolicyKeepsStreamingOutputPinnedToBottom() async throws {
        #expect(TerminalFollowOutputPolicy.shouldFollowOutput(currentlyFollowing: true, canScroll: true, scrollPosition: 0.25, fedText: "line\n"))
        #expect(TerminalFollowOutputPolicy.shouldFollowOutput(currentlyFollowing: false, canScroll: false, scrollPosition: 0, fedText: "line\n"))
        #expect(TerminalFollowOutputPolicy.shouldFollowOutput(currentlyFollowing: false, canScroll: true, scrollPosition: 0.99, fedText: "line\n"))
        #expect(!TerminalFollowOutputPolicy.shouldFollowOutput(currentlyFollowing: false, canScroll: true, scrollPosition: 0.5, fedText: "line\n"))
        #expect(TerminalFollowOutputPolicy.shouldFollowAfterUserScroll(position: 1.0))
        #expect(!TerminalFollowOutputPolicy.shouldFollowAfterUserScroll(position: 0.4))
    }

    @Test func terminalFollowOutputPolicyDoesNotForceScrollForCarriageReturnRefreshes() async throws {
        #expect(!TerminalFollowOutputPolicy.shouldAutoScroll(after: "\rTesting: https://example.test/admin"))
        #expect(!TerminalFollowOutputPolicy.shouldFollowOutput(currentlyFollowing: true, canScroll: true, scrollPosition: 1.0, fedText: "\rTesting: https://example.test/admin"))
        #expect(TerminalFollowOutputPolicy.shouldAutoScroll(after: "\rTesting: https://example.test/admin\n"))
        #expect(TerminalFollowOutputPolicy.shouldFollowOutput(currentlyFollowing: true, canScroll: true, scrollPosition: 1.0, fedText: "\rTesting: https://example.test/admin\n"))
    }

    @Test func terminalOutputFeedPolicyPreservesDirectoryListingsAsRegularOutput() async throws {
        let listing = "total 2\r\ndrwxr-x--- 24 ubuntu ubuntu 4096 May 12 09:43 .\r\n-rw-r--r-- 1 ubuntu ubuntu 4 May 12 09:44 robot.tar\r\n"

        #expect(TerminalOutputFeedPolicy.isRefreshOnly("\rTesting: https://example.test/admin"))
        #expect(!TerminalOutputFeedPolicy.isRefreshOnly(listing))
        #expect(!TerminalFollowOutputPolicy.shouldFollowOutput(
            currentlyFollowing: true,
            canScroll: true,
            scrollPosition: 1.0,
            fedText: "\rTesting: https://example.test/admin",
            isRefreshOnly: TerminalOutputFeedPolicy.isRefreshOnly("\rTesting: https://example.test/admin")
        ))
        #expect(TerminalFollowOutputPolicy.shouldFollowOutput(
            currentlyFollowing: true,
            canScroll: true,
            scrollPosition: 1.0,
            fedText: listing,
            isRefreshOnly: TerminalOutputFeedPolicy.isRefreshOnly(listing)
        ))
    }

    @Test func terminalANSIParserPreservesColorRuns() async throws {
        let frame = TerminalANSIParser.render("ok \u{1b}[31mred\u{1b}[0m done", columns: 80)

        #expect(frame.plainText == "ok red done")
        #expect(frame.lines[0].runs.count == 3)
        #expect(frame.lines[0].runs[1].text == "red")
        #expect(frame.lines[0].runs[1].style.foreground == .basic(1))
    }

    @Test func terminalANSIParserHandlesCarriageReturnAndClearLine() async throws {
        let frame = TerminalANSIParser.render("abcdef\rxy\u{1b}[K", columns: 80)

        #expect(frame.plainText == "xy")
        #expect(frame.cursorColumn == 2)
    }

    @Test func terminalANSIParserHandlesClearScreenAndCursorHome() async throws {
        let frame = TerminalANSIParser.render("one\ntwo\u{1b}[2J\u{1b}[Hclean", columns: 80)

        #expect(frame.plainText == "clean")
        #expect(frame.cursorRow == 0)
        #expect(frame.cursorColumn == 5)
    }

    @Test func terminalTranscriptDeltaTrackerAppendsOnlyNewOutput() async throws {
        var tracker = TerminalTranscriptDeltaTracker()

        #expect(tracker.update("welcome") == .append("welcome"))
        #expect(tracker.update("welcome\n$ ") == .append("\n$ "))
        #expect(tracker.update("welcome\n$ ") == .none)
    }

    @Test func terminalTranscriptDeltaTrackerResetsWhenSessionReplacesTranscript() async throws {
        var tracker = TerminalTranscriptDeltaTracker()

        #expect(tracker.update("old shell output") == .append("old shell output"))
        #expect(tracker.update("") == .reset(""))
        #expect(tracker.update("new shell output") == .append("new shell output"))

        #expect(tracker.update("fresh prompt") == .reset("fresh prompt"))
        #expect(tracker.update("fresh prompt\n$ ") == .append("\n$ "))
    }

    @Test func remoteFileListParserExtractsDirectoryFileAndSymlink() async throws {
        let output = """
        total 8
        drwxr-xr-x  3 deploy staff  96 Apr 29 21:00 logs
        -rw-r--r--  1 deploy staff 128 Apr 29 21:01 app.log
        lrwxr-xr-x  1 deploy staff  11 Apr 29 21:02 current -> releases/42
        """

        let entries = RemoteFileListParser.parse(output)

        #expect(entries.count == 3)
        #expect(entries[0].name == "logs")
        #expect(entries[0].isDirectory)
        #expect(entries[0].kind == .directory)
        #expect(entries[1].name == "app.log")
        #expect(!entries[1].isDirectory)
        #expect(entries[1].kind == .file)
        #expect(entries[2].isSymbolicLink)
        #expect(entries[2].linkTarget == "releases/42")
    }

    @Test func structuredRemoteFileListParserDecodesJSONEntriesWithSpaces() async throws {
        let output = """
        [
          {
            "name": "app logs",
            "kind": "directory",
            "permissions": "drwxr-xr-x",
            "owner": "deploy",
            "group": "staff",
            "size": 4096,
            "modified": "2026-04-30 12:00:00",
            "linkTarget": null
          },
          {
            "name": "current",
            "kind": "symlink",
            "permissions": "lrwxrwxrwx",
            "owner": "deploy",
            "group": "staff",
            "size": 11,
            "modified": "2026-04-30 12:01:00",
            "linkTarget": "releases/42"
          }
        ]
        """

        let entries = RemoteStructuredFileListParser.parse(output)

        #expect(entries.count == 2)
        #expect(entries[0].name == "app logs")
        #expect(entries[0].isDirectory)
        #expect(entries[0].byteSize == 4096)
        #expect(entries[1].isSymbolicLink)
        #expect(entries[1].displayName == "current -> releases/42")
    }

    @Test func structuredRemoteFileListParserExtractsJSONFromLoginNoise() async throws {
        let output = """
        Welcome to Ubuntu
        [
          {
            "name": "visible.txt",
            "kind": "file",
            "permissions": "-rw-r--r--",
            "owner": "ubuntu",
            "group": "ubuntu",
            "size": 12,
            "modified": "2026-05-01 15:30:00",
            "linkTarget": null
          }
        ]
        """

        let entries = RemoteStructuredFileListParser.parse(output)

        #expect(entries.count == 1)
        #expect(entries[0].name == "visible.txt")
        #expect(entries[0].isRegularFile)
    }

    @MainActor
    @Test func sshTunnelManagerStoreKeepsManagersPerServer() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let first = RemoteSession(name: "First", host: "one.example.com", username: "ubuntu")
        let second = RemoteSession(name: "Second", host: "two.example.com", username: "ubuntu")
        context.insert(first)
        context.insert(second)

        let store = SSHTunnelManagerStore()
        let firstManager = store.manager(for: first.persistentModelID)

        #expect(firstManager === store.manager(for: first.persistentModelID))
        #expect(firstManager !== store.manager(for: second.persistentModelID))
    }

    @MainActor
    @Test func sshTunnelManagerStoreStopsScheduledReconnectsOnQuit() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Reconnect", host: "reconnect.example.com", username: "ubuntu")
        context.insert(session)

        var configuration = SSHTunnelConfiguration()
        configuration.name = "Auto Tunnel"
        configuration.autoReconnect = true

        let store = SSHTunnelManagerStore()
        let manager = store.manager(for: session.persistentModelID)
        manager.simulateReconnectScheduledForTesting(configuration: configuration)

        #expect(store.hasRunningTunnels)
        #expect(store.runningTunnelSummaries == ["Auto Tunnel on 127.0.0.1:5432 reconnect pending"])

        store.stopAllTunnels()

        #expect(!store.hasRunningTunnels)
        #expect(store.runningTunnelSummaries.isEmpty)
    }

    @MainActor
    @Test func remoteFilesWorkspaceStorePreservesDirectoryStateAcrossFeatureSwitches() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let session = RemoteSession(name: "Files", host: "files.example.com", username: "ubuntu", remotePath: "~")
        context.insert(session)

        let store = RemoteFilesWorkspaceStore()
        let workspace = store.workspace(for: session.persistentModelID)
        workspace.result = CommandResult(command: "sftp", exitCode: 0, standardOutput: "", standardError: "")
        workspace.entries = [
            RemoteFileEntry(
                id: "notes.txt",
                kind: .file,
                permissions: "-rw-r--r--",
                owner: "ubuntu",
                group: "ubuntu",
                size: "12",
                byteSize: 12,
                modified: "May  2 09:00",
                name: "notes.txt",
                linkTarget: nil
            )
        ]
        workspace.markLoaded(session: session, path: session.remotePath)

        #expect(workspace.hasLoadedCurrentDirectory(for: session))
        #expect(store.workspace(for: session.persistentModelID) === workspace)

        session.remotePath = "/var/log"
        #expect(!workspace.hasLoadedCurrentDirectory(for: session))
    }

    @Test func sftpFileListParserCleansPromptsAndParsesEntries() async throws {
        let output = """
        Connected to files.example.com.
        sftp> ls -la '/srv'
        drwxr-xr-x    2 deploy   staff        4096 Apr 30 12:00 logs
        -rw-r--r--    1 deploy   staff          42 Apr 30 12:01 app.log
        sftp> 
        """

        let entries = RemoteSFTPFileListParser.parse(output)

        #expect(entries.count == 2)
        #expect(entries[0].name == "logs")
        #expect(entries[0].isDirectory)
        #expect(entries[1].name == "app.log")
        #expect(entries[1].byteSize == 42)
    }

    @Test func sftpFileListParserIgnoresPromptsEchoedCommandsAndCarriageReturns() async throws {
        let output = "ubuntu@example.com's password:\r\nsftp> ls -la '~'\r\ndrwxr-xr-x    3 ubuntu   ubuntu       4096 May  1 09:00 projects\r\n-rw-r--r--    1 ubuntu   ubuntu         12 May  1 09:01 notes.txt\r\nsftp> "

        let entries = RemoteSFTPFileListParser.parse(output)

        #expect(entries.count == 2)
        #expect(entries[0].name == "projects")
        #expect(entries[0].isDirectory)
        #expect(entries[1].name == "notes.txt")
        #expect(entries[1].isRegularFile)
    }

    @MainActor
    @Test func sessionProfileCodecRoundTripsConnectionSettings() async throws {
        let session = RemoteSession(
            name: "Production API",
            host: "api.example.com",
            username: "deploy",
            port: 2222,
            identityFile: "~/.ssh/prod",
            jumpHost: "bastion.example.com",
            folder: "Production",
            enableX11Forwarding: true,
            remotePath: "/srv/api"
        )
        session.mcpEnabled = true
        session.mcpAlwaysAllowTerminalControl = true
        session.mcpAlias = "prod-api"

        let data = try SessionProfileCodec.encode(sessions: [session])
        let decoded = try SessionProfileCodec.decode(data)

        #expect(decoded.count == 1)
        #expect(decoded[0].name == "Production API")
        #expect(decoded[0].host == "api.example.com")
        #expect(decoded[0].username == "deploy")
        #expect(decoded[0].port == 2222)
        #expect(decoded[0].connectionType == .ssh)
        #expect(decoded[0].identityFile == "~/.ssh/prod")
        #expect(decoded[0].jumpHost == "bastion.example.com")
        #expect(decoded[0].folder == "Production")
        #expect(decoded[0].enableX11Forwarding)
        #expect(decoded[0].remotePath == "/srv/api")
        #expect(decoded[0].mcpEnabled)
        #expect(decoded[0].mcpAlwaysAllowTerminalControl)
        #expect(decoded[0].mcpAlias == "prod-api")

        let imported = decoded[0].makeSession()
        #expect(imported.connectionType == .ssh)
        #expect(imported.folder == "Production")
        #expect(imported.folderDisplayName == "Production")
        #expect(imported.mcpEnabled)
        #expect(imported.mcpAlwaysAllowTerminalControl)
    }

    @MainActor
    @Test func sessionProfileCodecRoundTripsLocalShellConnectionSettings() async throws {
        let session = RemoteSession(
            name: "Root Local",
            connectionType: .localShell,
            folder: "Local"
        )
        session.mcpEnabled = true
        session.mcpAlwaysAllowTerminalControl = true
        session.mcpAlias = "root-local"

        let data = try SessionProfileCodec.encode(sessions: [session])
        let decoded = try SessionProfileCodec.decode(data)
        let imported = decoded[0].makeSession()

        #expect(decoded.count == 1)
        #expect(decoded[0].name == "Root Local")
        #expect(decoded[0].connectionType == .localShell)
        #expect(decoded[0].folder == "Local")
        #expect(decoded[0].mcpEnabled)
        #expect(decoded[0].mcpAlwaysAllowTerminalControl)
        #expect(decoded[0].mcpAlias == "root-local")
        #expect(imported.connectionType == .localShell)
        #expect(imported.isConnectable)
        #expect(imported.address == "Local shell")
        #expect(imported.mcpEnabled)
        #expect(imported.mcpAlwaysAllowTerminalControl)
    }

    @MainActor
    @Test func sessionProfileCodecHandlesLegacyRDPForCurrentReleaseTrack() async throws {
        let legacyJSON = """
        {
          "version": 1,
          "exportedAt": "2026-04-30T00:00:00Z",
          "sessions": [
            {
              "id": "40F1E66E-08DA-4056-969D-84F284E8CF3F",
              "name": "Legacy Desktop",
              "host": "desktop.example.com",
              "username": "operator",
              "port": 22,
              "connectionType": "RDP",
              "identityFile": "",
              "jumpHost": "",
              "folder": "Workstations",
              "enableX11Forwarding": false,
              "rdpPort": 3391,
              "vncPort": 5900,
              "remotePath": "~",
              "mcpEnabled": true,
              "mcpAlwaysAllowTerminalControl": true,
              "mcpAlias": "legacy-desktop"
            }
          ]
        }
        """

        let decoded = try SessionProfileCodec.decode(Data(legacyJSON.utf8))
        let imported = decoded[0].makeSession()

        #expect(decoded.count == 1)
        #if ENABLE_RDP_2
        #expect(decoded[0].connectionType == .rdp)
        #expect(decoded[0].port == 3391)
        #expect(decoded[0].mcpEnabled)
        #expect(decoded[0].mcpAlwaysAllowTerminalControl == false)
        #expect(imported.connectionType == .rdp)
        #expect(imported.isConnectable)
        #expect(imported.address == "desktop.example.com:3391")
        #expect(imported.mcpEnabled)
        #else
        #expect(decoded[0].connectionType == .ssh)
        #expect(decoded[0].port == 22)
        #expect(decoded[0].mcpEnabled == false)
        #expect(decoded[0].mcpAlwaysAllowTerminalControl == false)
        #expect(imported.connectionType == .ssh)
        #expect(imported.isConnectable)
        #expect(imported.address == "operator@desktop.example.com:22")
        #expect(imported.mcpEnabled == false)
        #endif
    }

    @MainActor
    @Test func sessionProfileCodecDecodesOlderExportsWithoutFolder() async throws {
        let legacyJSON = """
        {
          "version": 1,
          "exportedAt": "2026-04-30T00:00:00Z",
          "sessions": [
            {
              "id": "40F1E66E-08DA-4056-969D-84F284E8CF3F",
              "name": "Legacy",
              "host": "legacy.example.com",
              "username": "deploy",
              "port": 22,
              "identityFile": "",
              "jumpHost": "",
              "enableX11Forwarding": false,
              "rdpPort": 3389,
              "vncPort": 5900,
              "remotePath": "~"
            }
          ]
        }
        """

        let decoded = try SessionProfileCodec.decode(Data(legacyJSON.utf8))

        #expect(decoded.count == 1)
        #expect(decoded[0].connectionType == .ssh)
        #expect(decoded[0].folder == "")
        #expect(decoded[0].makeSession().folderDisplayName == "Ungrouped")
        #expect(decoded[0].mcpEnabled == false)
        #expect(decoded[0].mcpAlwaysAllowTerminalControl == false)
    }

    private func decodedJSONObject(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func encodedJSONLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func occurrenceCount(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func expectManagedHostKeyOptions(in arguments: [String]) {
        #expect(arguments.contains(
            SSHCommandBuilder.userKnownHostsFileOption(SSHCommandBuilder.managedKnownHostsFilePath())
        ))
        #expect(arguments.contains("GlobalKnownHostsFile=/dev/null"))
        #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
    }

    private func expectSavedPasswordIsolation(in arguments: [String]) {
        #expect(arguments.indices.dropLast().contains { index in
            arguments[index] == "-F" && arguments[index + 1] == "/dev/null"
        })
        #expect(arguments.contains("BatchMode=no"))
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.contains("IdentityAgent=none"))
        #expect(arguments.contains("IdentityFile=none"))
        #expect(arguments.contains("CertificateFile=none"))
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("PasswordAuthentication=yes"))
        #expect(arguments.contains("KbdInteractiveAuthentication=yes"))
        #expect(arguments.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(arguments.contains("ProxyJump=none"))
        #expect(arguments.contains("ProxyCommand=none"))
        #expect(!arguments.contains("PreferredAuthentications=publickey,password,keyboard-interactive"))
    }

    private func runPTYLaunchGate(release: String?, marker: URL) throws -> Int32 {
        let process = Process()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            TerminalProcessLaunchGate.script,
            "jts-pty-launch-gate-test",
            "/usr/bin/touch",
            marker.path,
        ]
        process.standardInput = standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        if let release {
            try standardInput.fileHandleForWriting.write(contentsOf: Data(release.utf8))
        }
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeFakeJTSExecutable(
        in directory: URL,
        bundleIdentifier: String = "com.lljts.JTSTerminal"
    ) throws -> String {
        let contentsURL = directory
            .appendingPathComponent("JTS Terminal.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let executableURL = macOSURL.appendingPathComponent("JTS Terminal")
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return executableURL.path
    }

    private func toolTextPayload(from response: String) throws -> String {
        let object = try decodedJSONObject(response)
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

}
