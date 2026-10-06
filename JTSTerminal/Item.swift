//
//  Item.swift
//  JTSTerminal
//
//  Created by tester on 2026/4/29.
//

import Foundation
import SwiftData

nonisolated enum AppReleasePolicy {
    static let appStoreMarketingVersion = "1.2"

    #if ENABLE_RDP_2
    static let includesNativeRDP = true
    #else
    static let includesNativeRDP = false
    #endif
}

nonisolated enum RemoteConnectionType: String, CaseIterable, Identifiable, Codable, Sendable {
    case ssh = "SSH"
    case localShell = "Local Shell"
    case rdp = "RDP"
    case macDesktop = "Mac Desktop"

    var id: String { rawValue }

    var isIncludedInCurrentRelease: Bool {
        switch self {
        case .ssh, .localShell:
            return true
        case .rdp, .macDesktop:
            return AppReleasePolicy.includesNativeRDP
        }
    }

    static var selectableCases: [RemoteConnectionType] {
        allCases.filter(\.isIncludedInCurrentRelease)
    }

    var displayName: String {
        switch self {
        case .ssh:
            return "SSH"
        case .localShell:
            return "Local Shell"
        case .macDesktop:
            return AppReleasePolicy.includesNativeRDP ? "Mac Desktop" : "Unsupported"
        case .rdp:
            #if ENABLE_RDP_2
            return "RDP"
            #else
            return "Unsupported"
            #endif
        }
    }

    var defaultPort: Int {
        switch self {
        case .ssh, .localShell:
            return 22
        case .macDesktop:
            return 49_871
        case .rdp:
            return 3_389
        }
    }

    static func resolved(rawValue: String?) -> (type: RemoteConnectionType, isSupported: Bool) {
        guard let rawValue else {
            return (.ssh, true)
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let type = RemoteConnectionType(rawValue: trimmed) {
            return type.isIncludedInCurrentRelease ? (type, true) : (.ssh, false)
        }

        switch trimmed.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "local-shell", "localshell":
            return (.localShell, true)
        case "mac-desktop", "mac desktop":
            return AppReleasePolicy.includesNativeRDP ? (.macDesktop, true) : (.ssh, false)
        case "rdp":
            return AppReleasePolicy.includesNativeRDP ? (.rdp, true) : (.ssh, false)
        default:
            return (.ssh, false)
        }
    }
}

@Model
final class RemoteSession {
    /// Optional storage makes the SwiftData migration safe for existing 1.1
    /// rows. Access lazily assigns each legacy row its own stable UUID.
    var targetIDRawValue: UUID?
    var name: String
    var host: String
    var username: String
    var port: Int
    var connectionTypeRawValue: String?
    var identityFile: String
    var jumpHost: String
    var folder: String
    var enableX11Forwarding: Bool
    var remotePath: String
    var rdpProfileData: Data?
    var mcpEnabled: Bool = false
    var mcpAlwaysAllowTerminalControl: Bool = false
    var mcpAlias: String = ""
    var mcpUpdatedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        targetID: UUID = UUID(),
        name: String = "New Server",
        host: String = "",
        username: String = NSUserName(),
        port: Int? = nil,
        connectionType: RemoteConnectionType = .ssh,
        identityFile: String = "",
        jumpHost: String = "",
        folder: String = "",
        enableX11Forwarding: Bool = false,
        remotePath: String = "~"
    ) {
        let effectiveConnectionType = connectionType.isIncludedInCurrentRelease ? connectionType : .ssh
        self.targetIDRawValue = targetID
        self.name = name
        self.host = host
        self.username = username
        self.port = port ?? effectiveConnectionType.defaultPort
        self.connectionTypeRawValue = effectiveConnectionType.rawValue
        self.identityFile = identityFile
        self.jumpHost = jumpHost
        self.folder = folder
        self.enableX11Forwarding = enableX11Forwarding
        self.remotePath = remotePath
        self.rdpProfileData = nil
        self.mcpEnabled = false
        self.mcpAlwaysAllowTerminalControl = false
        self.mcpAlias = ""
        self.mcpUpdatedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var connectionType: RemoteConnectionType {
        get { RemoteConnectionType.resolved(rawValue: connectionTypeRawValue).type }
        set {
            let newValue = newValue.isIncludedInCurrentRelease ? newValue : .ssh
            let previousType = RemoteConnectionType.resolved(rawValue: connectionTypeRawValue).type
            if previousType != newValue, port == previousType.defaultPort {
                port = newValue.defaultPort
            }
            connectionTypeRawValue = newValue.rawValue
        }
    }

    var targetID: UUID {
        get {
            if let targetIDRawValue {
                return targetIDRawValue
            }
            let generated = UUID()
            targetIDRawValue = generated
            updatedAt = Date()
            return generated
        }
        set {
            targetIDRawValue = newValue
            updatedAt = Date()
        }
    }

    var rdpProfile: RDPConnectionProfile {
        RDPConnectionProfileCodec.decode(rdpProfileData)
    }

    func setRDPProfile(_ profile: RDPConnectionProfile) throws {
        rdpProfileData = try RDPConnectionProfileCodec.encode(profile)
        updatedAt = Date()
    }

    var address: String {
        switch connectionType {
        case .ssh:
            guard !host.isEmpty else { return "Host not configured" }
            return "\(username)@\(host):\(port)"
        case .localShell:
            return "Local shell"
        case .rdp, .macDesktop:
            guard !host.isEmpty else { return "Host not configured" }
            return "\(host):\(port)"
        }
    }

    var connectionKey: String {
        switch connectionType {
        case .ssh:
            return "\(username.trimmingCharacters(in: .whitespacesAndNewlines))@\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"
        case .localShell:
            return "local-shell"
        case .macDesktop:
            return "mac-desktop:\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
        case .rdp:
            #if ENABLE_RDP_2
            let domain = rdpProfile.domain
            let qualifiedUser = domain.isEmpty ? username : "\(domain)\\\(username)"
            return "rdp://\(qualifiedUser)@\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"
            #else
            return "unsupported-\(targetID.uuidString)"
            #endif
        }
    }

    var isConnectable: Bool {
        switch connectionType {
        case .ssh:
            return SSHConnectionIdentity(username: username, host: host).isValidForSSHCommand
                && (1...65_535).contains(port)
        case .localShell:
            return true
        case .macDesktop:
            return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65_535).contains(port)
        case .rdp:
            let hasHost = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasUsername = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasHost && hasUsername && port > 0 && port <= 65_535
        }
    }

    var folderDisplayName: String {
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFolder.isEmpty ? "Ungrouped" : trimmedFolder
    }

    var effectiveMCPAlias: String {
        let explicitAlias = mcpAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitAlias.isEmpty {
            return MCPAlias.normalized(explicitAlias)
        }

        let source = (name.nilIfBlank ?? host.nilIfBlank ?? connectionKey)
        return MCPAlias.normalized(source)
    }
}

enum MCPAlias {
    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasSeparator = false

        for scalar in trimmed.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
            if isAllowed {
                output.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                output.append("-")
                previousWasSeparator = true
            }
        }

        let normalized = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "server" : normalized
    }
}

@Model
final class MCPAuditEntry {
    var clientID: String = "unidentified-mcp-client"
    var toolName: String
    var serverAlias: String
    var operationSummary: String
    var exitCode: Int
    var outputTruncated: Bool
    var startedAt: Date
    var finishedAt: Date

    init(
        clientID: String = "unidentified-mcp-client",
        toolName: String,
        serverAlias: String,
        operationSummary: String,
        exitCode: Int,
        outputTruncated: Bool,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.clientID = MCPAuditRecordPolicy.clientIdentifier(clientID)
        self.toolName = toolName
        self.serverAlias = serverAlias
        self.operationSummary = operationSummary
        self.exitCode = exitCode
        self.outputTruncated = outputTruncated
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

@Model
final class SavedSSHTunnel {
    var sessionConnectionKey: String
    var name: String
    var kindRawValue: String
    var bindAddress: String
    var localPort: Int
    var destinationHost: String
    var destinationPort: Int
    var autoReconnect: Bool = false
    var createdAt: Date
    var updatedAt: Date

    init(
        sessionConnectionKey: String,
        name: String = "Postgres Tunnel",
        kind: SSHTunnelKind = .local,
        bindAddress: String = "127.0.0.1",
        localPort: Int = 5432,
        destinationHost: String = "127.0.0.1",
        destinationPort: Int = 5432,
        autoReconnect: Bool = false
    ) {
        self.sessionConnectionKey = sessionConnectionKey
        self.name = name
        self.kindRawValue = kind.rawValue
        self.bindAddress = bindAddress
        self.localPort = localPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.autoReconnect = autoReconnect
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    convenience init(session: RemoteSession, configuration: SSHTunnelConfiguration) {
        self.init(
            sessionConnectionKey: session.connectionKey,
            name: configuration.name,
            kind: configuration.kind,
            bindAddress: configuration.bindAddress,
            localPort: configuration.localPort,
            destinationHost: configuration.destinationHost,
            destinationPort: configuration.destinationPort,
            autoReconnect: configuration.autoReconnect
        )
    }

    var kind: SSHTunnelKind {
        get { SSHTunnelKind(rawValue: kindRawValue) ?? .local }
        set { kindRawValue = newValue.rawValue }
    }

    var configuration: SSHTunnelConfiguration {
        SSHTunnelConfiguration(
            name: name,
            kind: kind,
            bindAddress: bindAddress,
            localPort: localPort,
            destinationHost: destinationHost,
            destinationPort: destinationPort,
            autoReconnect: autoReconnect
        )
    }

    func update(from configuration: SSHTunnelConfiguration, session: RemoteSession) {
        sessionConnectionKey = session.connectionKey
        name = configuration.name
        kind = configuration.kind
        bindAddress = configuration.bindAddress
        localPort = configuration.localPort
        destinationHost = configuration.destinationHost
        destinationPort = configuration.destinationPort
        autoReconnect = configuration.autoReconnect
        updatedAt = Date()
    }
}

@Model
final class CommandHistoryEntry {
    var sessionConnectionKey: String
    var sessionName: String
    var command: String
    var exitCode: Int32
    var ranAt: Date

    init(
        session: RemoteSession,
        command: String,
        exitCode: Int32 = -1,
        ranAt: Date = Date()
    ) {
        self.sessionConnectionKey = session.connectionKey
        self.sessionName = session.name
        self.command = command
        self.exitCode = exitCode
        self.ranAt = ranAt
    }

    var succeeded: Bool {
        exitCode == 0
    }
}

@Model
final class SavedCommandMacro {
    var sessionConnectionKey: String
    var name: String
    var command: String
    var createdAt: Date
    var updatedAt: Date

    init(
        session: RemoteSession,
        name: String,
        command: String,
        createdAt: Date = Date()
    ) {
        self.sessionConnectionKey = session.connectionKey
        self.name = name
        self.command = command
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    func update(name: String, command: String) {
        self.name = name
        self.command = command
        updatedAt = Date()
    }
}

enum RemoteTransferDirection: String, CaseIterable, Codable, Equatable {
    case download
    case upload

    var label: String {
        switch self {
        case .download:
            return "Download"
        case .upload:
            return "Upload"
        }
    }
}

enum RemoteTransferStatus: String, CaseIterable, Codable, Equatable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    var label: String {
        switch self {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .succeeded:
            return "Done"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var canResume: Bool {
        self == .queued || self == .failed || self == .cancelled
    }

    var shouldRemainVisibleInQueue: Bool {
        self != .succeeded
    }
}

@Model
final class RemoteTransferTask {
    var sessionConnectionKey: String
    var sessionName: String
    var directionRawValue: String
    var remotePath: String
    var localPath: String
    var recursive: Bool
    var resumeSupported: Bool
    var statusRawValue: String
    var lastError: String
    var command: String
    var exitCode: Int
    var expectedByteCount: Int64?
    var transferredByteCount: Int64 = 0
    var localSecurityScopedBookmark: Data?
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    init(
        session: RemoteSession,
        direction: RemoteTransferDirection,
        remotePath: String,
        localPath: String,
        recursive: Bool = false,
        resumeSupported: Bool = true,
        expectedByteCount: Int64? = nil,
        localSecurityScopedBookmark: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.sessionConnectionKey = session.connectionKey
        self.sessionName = session.name
        self.directionRawValue = direction.rawValue
        self.remotePath = remotePath
        self.localPath = localPath
        self.recursive = recursive
        self.resumeSupported = resumeSupported
        self.statusRawValue = RemoteTransferStatus.queued.rawValue
        self.lastError = ""
        self.command = ""
        self.exitCode = 0
        self.expectedByteCount = expectedByteCount
        self.transferredByteCount = 0
        self.localSecurityScopedBookmark = localSecurityScopedBookmark
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.startedAt = nil
        self.finishedAt = nil
    }

    var direction: RemoteTransferDirection {
        get { RemoteTransferDirection(rawValue: directionRawValue) ?? .download }
        set { directionRawValue = newValue.rawValue }
    }

    var status: RemoteTransferStatus {
        get { RemoteTransferStatus(rawValue: statusRawValue) ?? .queued }
        set { statusRawValue = newValue.rawValue }
    }

    var displayName: String {
        let source = direction == .download ? remotePath : localPath
        let name = URL(fileURLWithPath: source).lastPathComponent
        return name.isEmpty ? source : name
    }

    var summary: String {
        switch direction {
        case .download:
            return "\(remotePath) -> \(localPath)"
        case .upload:
            return "\(localPath) -> \(remotePath)"
        }
    }

    var progressFraction: Double? {
        guard let expectedByteCount, expectedByteCount > 0 else { return nil }
        let clamped = min(max(transferredByteCount, 0), expectedByteCount)
        return Double(clamped) / Double(expectedByteCount)
    }

    var progressLabel: String {
        guard let expectedByteCount, expectedByteCount > 0 else {
            return recursive ? "Recursive transfer" : "Size unknown"
        }

        let transferred = ByteCountFormatter.string(
            fromByteCount: min(max(transferredByteCount, 0), expectedByteCount),
            countStyle: .file
        )
        let expected = ByteCountFormatter.string(fromByteCount: expectedByteCount, countStyle: .file)
        let percent = Int(((progressFraction ?? 0) * 100).rounded(.down))
        return "\(transferred) of \(expected) · \(percent)%"
    }

    var shouldRemainVisibleInQueue: Bool {
        status.shouldRemainVisibleInQueue
    }

    var shouldResumeTransferOnNextAttempt: Bool {
        resumeSupported && (status == .failed || status == .cancelled)
    }

    func markQueued() {
        status = .queued
        lastError = ""
        updatedAt = Date()
        finishedAt = nil
    }

    func markRunning() {
        status = .running
        lastError = ""
        startedAt = Date()
        finishedAt = nil
        updatedAt = Date()
    }

    func markFinished(result: CommandResult) {
        let result = RemoteSFTPTransport.resultByRecognizingSFTPFailureOutput(result)
        command = result.command
        exitCode = Int(result.exitCode)
        finishedAt = Date()
        updatedAt = finishedAt ?? Date()
        if result.succeeded {
            status = .succeeded
            lastError = ""
            if let expectedByteCount {
                transferredByteCount = max(transferredByteCount, expectedByteCount)
            }
        } else {
            status = .failed
            lastError = result.displayText
        }
    }

    func markFailed(_ message: String) {
        status = .failed
        if exitCode == 0 { exitCode = 1 }
        lastError = message
        finishedAt = Date()
        updatedAt = finishedAt ?? Date()
    }

    func updateTransferredByteCount(_ byteCount: Int64) {
        transferredByteCount = max(transferredByteCount, byteCount)
        updatedAt = Date()
    }

    func refreshTransferredByteCountFromLocalFile() {
        guard direction == .download else { return }
        let path = (localPath as NSString).expandingTildeInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber else {
            return
        }
        updateTransferredByteCount(fileSize.int64Value)
    }

    static func securityScopedBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func startAccessingLocalSecurityScopedResource() -> (() -> Void) {
        guard let localSecurityScopedBookmark else {
            return {}
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: localSecurityScopedBookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return {}
        }

        let didStart = url.startAccessingSecurityScopedResource()
        return {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
