//
//  MCPClientRegistrar.swift
//  JTSTerminal
//
//  Created by Codex on 2026/5/19.
//

import CryptoKit
import Darwin
import Foundation

nonisolated enum MCPClientKind: CaseIterable, Equatable, Hashable {
    case codexDesktop
    case codexCLI
    case antigravity
    case claudeDesktop
    case claudeCLI
    case grokCLI
    case cursor

    static let registrationDisplayOrder: [MCPClientKind] = [
        .claudeDesktop,
        .claudeCLI,
        .cursor,
        .codexDesktop,
        .codexCLI,
        .grokCLI,
        .antigravity
    ]

    var displayName: String {
        switch self {
        case .codexDesktop:
            return "Codex Desktop"
        case .codexCLI:
            return "Codex CLI"
        case .antigravity:
            return "Antigravity"
        case .claudeDesktop:
            return "Claude Desktop"
        case .claudeCLI:
            return "Claude CLI"
        case .grokCLI:
            return "Grok CLI"
        case .cursor:
            return "Cursor"
        }
    }

    var identifier: String {
        switch self {
        case .codexDesktop:
            return "codex"
        case .codexCLI:
            return "codex-cli"
        case .antigravity:
            return "antigravity"
        case .claudeDesktop:
            return "claude"
        case .claudeCLI:
            return "claude-cli"
        case .grokCLI:
            return "grok-cli"
        case .cursor:
            return "cursor"
        }
    }
}

nonisolated enum MCPClientRegistrationState: Equatable {
    case notRegistered
    case registered
    case needsUpdate
    case accessRequired
    case invalidConfiguration(String)
}

nonisolated struct MCPClientRegistrationStatus: Equatable {
    let client: MCPClientKind
    let configPath: String
    let state: MCPClientRegistrationState
    let verification: MCPClientRegistrationVerification?

    init(
        client: MCPClientKind,
        configPath: String,
        state: MCPClientRegistrationState,
        verification: MCPClientRegistrationVerification? = nil
    ) {
        self.client = client
        self.configPath = configPath
        self.state = state
        self.verification = verification
    }

    var isRegistered: Bool {
        state == .registered
    }
}

nonisolated enum MCPClientRegistrationStatusRefresh {
    static let storageKey = "mcpClientRegistrationStatusRefreshToken.v1"

    @MainActor
    static func bump(defaults: UserDefaults = .standard) {
        defaults.set(UUID().uuidString, forKey: storageKey)
    }
}

nonisolated struct MCPClientRegistrationResult: Equatable {
    let client: MCPClientKind
    let configPath: String
    let registrationID: String

    var displayMessage: String {
        "JTS Terminal configured \(client.displayName) automatically. Restart \(client.displayName) or start a new session to reload tools."
    }

    @MainActor
    func displayMessage(language: AppLanguage) -> String {
        language.localized(
            displayMessage,
            "JTS Terminal 已自动完成 \(client.displayName) 配置。请重启 \(client.displayName) 或开启新会话以重新加载工具。"
        )
    }
}

nonisolated struct MCPClientConfigurationSnapshot: Equatable, Sendable {
    let exists: Bool
    let sha256: String
    let byteCount: Int
}

nonisolated struct MCPClientRegistrationPreview: Equatable {
    let client: MCPClientKind
    let destinationURL: URL
    let registration: MCPClientRegistrationRecord
    let configurationSnapshot: MCPClientConfigurationSnapshot
    let commandPath: String
    let arguments: [String]
    let configurationSnippet: String
    let focusedDiff: String

    var commandAndArguments: String {
        ([commandPath] + arguments).map(MCPClientRegistrar.shellDisplayLiteral).joined(separator: " ")
    }
}

nonisolated enum MCPClientDisplayIdentity {
    static func registered(clientLabel: String, registrationID: String) -> String {
        let label = sanitized(clientLabel) ?? "Registered MCP client"
        return "\(label) · …\(registrationID.suffix(8))"
    }

    static func resolved(_ value: String?, authorizationID: String) -> String {
        sanitized(value) ?? fallback(authorizationID: authorizationID)
    }

    static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(128)
        let result = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func fallback(authorizationID: String) -> String {
        let suffix = authorizationID
            .split(separator: ":")
            .last
            .map(String.init) ?? authorizationID
        if authorizationID.hasPrefix("mcp-registration:") {
            return "Registered MCP client · …\(suffix.suffix(8))"
        }
        return sanitized(authorizationID) ?? "Unidentified MCP client"
    }
}

/// An opaque identity issued by JTS Terminal for one concrete MCP configuration
/// file. The MCP peer's self-reported `initialize.clientInfo` is deliberately
/// not part of this identity.
nonisolated struct MCPClientRegistrationRecord: Codable, Equatable, Sendable {
    let registrationID: String
    let configurationKey: String
    let clientLabel: String
    let createdAt: Date

    var authorizationClientID: String {
        "mcp-registration:\(registrationID)"
    }

    var displayIdentity: String {
        MCPClientDisplayIdentity.registered(
            clientLabel: clientLabel,
            registrationID: registrationID
        )
    }
}

nonisolated enum MCPClientRegistrationRegistryError: LocalizedError, Equatable {
    case corruptRegistry
    case insecurePermissions
    case invalidRecord
    case previewChanged

    var errorDescription: String? {
        switch self {
        case .corruptRegistry:
            return "The MCP client registration registry is damaged. Access remains disabled until registrations are recreated."
        case .insecurePermissions:
            return "The MCP client registration registry is not private (0600). Access remains disabled."
        case .invalidRecord:
            return "The MCP client registration registry contains an invalid or duplicate identity. Access remains disabled."
        case .previewChanged:
            return "The MCP client configuration changed while JTS Terminal was preparing the update. Choose Configure again so JTS Terminal can merge the latest settings safely."
        }
    }
}

/// Small fail-closed registry shared by the GUI registrar and the stdio MCP
/// process. Writes are atomic and private; a malformed registry never falls
/// back to a self-reported client name.
nonisolated struct MCPClientRegistrationRegistry {
    private struct PersistedState: Codable {
        var formatVersion: Int
        var registrations: [MCPClientRegistrationRecord]
    }

    static let formatVersion = 1

    let storageURL: URL
    var fileManager: FileManager = .default

    func previewRecord(for client: MCPClientKind, configurationURL: URL) throws -> MCPClientRegistrationRecord {
        let key = Self.configurationKey(for: configurationURL)
        if let existing = try load().first(where: { $0.configurationKey == key }) {
            return existing
        }
        return MCPClientRegistrationRecord(
            registrationID: UUID().uuidString.lowercased(),
            configurationKey: key,
            clientLabel: Self.clientLabel(for: client),
            createdAt: Date()
        )
    }

    @discardableResult
    func activate(_ preview: MCPClientRegistrationRecord) throws -> MCPClientRegistrationRecord {
        var records = try load()
        if let existing = records.first(where: { $0.configurationKey == preview.configurationKey }) {
            guard existing.registrationID == preview.registrationID else {
                throw MCPClientRegistrationRegistryError.previewChanged
            }
            return existing
        }
        guard Self.isValid(preview),
              !records.contains(where: { $0.registrationID == preview.registrationID }) else {
            throw MCPClientRegistrationRegistryError.invalidRecord
        }
        records.append(preview)
        try persist(records)
        return preview
    }

    func resolve(registrationID: String) throws -> MCPClientRegistrationRecord? {
        let normalized = registrationID.lowercased()
        guard Self.isValidRegistrationID(normalized) else { return nil }
        return try load().first { $0.registrationID == normalized }
    }

    func record(for configurationURL: URL) throws -> MCPClientRegistrationRecord? {
        let key = Self.configurationKey(for: configurationURL)
        return try load().first { $0.configurationKey == key }
    }

    func records(for client: MCPClientKind) throws -> [MCPClientRegistrationRecord] {
        let label = Self.clientLabel(for: client)
        return try load()
            .filter { $0.clientLabel == label }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func load() throws -> [MCPClientRegistrationRecord] {
        guard fileManager.fileExists(atPath: storageURL.path) else { return [] }
        do {
            try PrivateFileSecurity.verifyPrivateDirectory(
                at: storageURL.deletingLastPathComponent()
            )
            try PrivateFileSecurity.verifyPrivateFile(at: storageURL)
        } catch {
            throw MCPClientRegistrationRegistryError.insecurePermissions
        }
        let data = try Data(contentsOf: storageURL)
        guard !data.isEmpty,
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.formatVersion == Self.formatVersion else {
            throw MCPClientRegistrationRegistryError.corruptRegistry
        }
        let ids = Set(state.registrations.map(\.registrationID))
        let keys = Set(state.registrations.map(\.configurationKey))
        guard ids.count == state.registrations.count,
              keys.count == state.registrations.count,
              state.registrations.allSatisfy(Self.isValid) else {
            throw MCPClientRegistrationRegistryError.invalidRecord
        }
        return state.registrations
    }

    private func persist(_ records: [MCPClientRegistrationRecord]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try PrivateFileSecurity.secureDirectory(
            at: directory,
            fileManager: fileManager
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(PersistedState(
            formatVersion: Self.formatVersion,
            registrations: records
        ))
        try writePrivateAtomically(data)
    }

    /// Creates the replacement with private permissions *before* it contains
    /// registry data, then atomically installs it. `Data.write(.atomic)` applies
    /// process-default permissions to its temporary file, which can briefly make
    /// a newly-created bearer identity group/world-readable before a later chmod.
    private func writePrivateAtomically(_ data: Data) throws {
        let stagedFile = try PrivateFileSecurity.createStagedFile(
            adjacentTo: storageURL,
            fileManager: fileManager
        )
        defer {
            PrivateFileSecurity.removeStaging(
                stagedFile,
                fileManager: fileManager
            )
        }

        do {
            try stagedFile.handle.write(contentsOf: data)
            try stagedFile.handle.synchronize()
            try stagedFile.handle.close()
        } catch {
            try? stagedFile.handle.close()
            throw error
        }
        try PrivateFileSecurity.installReplacing(stagedFile, at: storageURL)
        try PrivateFileSecurity.verifyPrivateFile(at: storageURL)
    }

    private static func configurationKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func clientLabel(for client: MCPClientKind) -> String {
        switch client {
        case .codexDesktop, .codexCLI:
            return "Codex"
        case .grokCLI:
            return "Grok CLI"
        case .cursor:
            return "Cursor"
        default:
            return client.displayName
        }
    }

    private static func isValid(_ record: MCPClientRegistrationRecord) -> Bool {
        isValidRegistrationID(record.registrationID) &&
            !record.configurationKey.isEmpty &&
            record.configurationKey.hasPrefix("/") &&
            URL(fileURLWithPath: record.configurationKey).standardizedFileURL.path == record.configurationKey &&
            !record.clientLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidRegistrationID(_ value: String) -> Bool {
        guard value == value.lowercased(), let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

nonisolated enum MCPClientConfiguration {
    static let fallbackApplicationPath = "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal"

    static func commandPath(bundle: Bundle = .main) -> String {
        bundle.executableURL?.path ?? fallbackApplicationPath
    }

    static func stdioJSONText(commandPath: String, arguments: [String]) -> String {
        let config: [String: Any] = [
            "mcpServers": [
                MCPClientRegistrar.serverName: [
                    "type": "stdio",
                    "command": commandPath,
                    "args": arguments
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? """
        {
          "mcpServers": {
              "\(MCPClientRegistrar.serverName)": {
                "type": "stdio",
                "command": "\(commandPath)",
                "args": []
              }
            }
          }
        """
    }
}

nonisolated enum MCPClientRegistrationError: LocalizedError {
    case invalidJSON(path: String)
    case invalidConfigShape(path: String)
    case unsafeConfigurationTopology(path: String)
    case insecurePermissions(path: String)
    case commitRecoveryRequired(path: String, recoveryPath: String)
    case unexpectedConfigurationAuthorization(
        expectedDirectory: String,
        selectedDirectory: String
    )

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let path):
            return "MCP config is not valid JSON: \(path)"
        case .invalidConfigShape(let path):
            return "MCP config must be a JSON object: \(path)"
        case .unsafeConfigurationTopology(let path):
            return "MCP config must be a regular file with exactly one hard link, not a symbolic link or linked alias: \(path)"
        case .insecurePermissions(let path):
            return "MCP config permissions could not be restricted to the current user: \(path)"
        case .commitRecoveryRequired(let path, let recoveryPath):
            return "MCP config changed during atomic commit and could not be restored safely: \(path). The displaced file was preserved at \(recoveryPath)."
        case .unexpectedConfigurationAuthorization(
            let expectedDirectory,
            let selectedDirectory
        ):
            return "JTS Terminal only accepts the MCP client's canonical configuration directory. Expected \(expectedDirectory), received \(selectedDirectory)."
        }
    }
}

nonisolated struct MCPClientRegistrar {
    private struct ConfigurationFileState {
        let data: Data?
        let snapshot: MCPClientConfigurationSnapshot
    }

    static let serverName = "jts-terminal"
    /// Bootstrap-only arguments. A process started with these arguments can
    /// initialize and list tool schemas, but cannot discover targets or invoke
    /// tools until an issued registration ID is also present.
    static let directArguments = ["--mcp"]
    static var allowsUnregisteredDirectConfiguration: Bool {
        !AppReleasePolicy.includesNativeRDP
    }

    var homeDirectory: URL
    var fileManager: FileManager
    var registrationRegistryURL: URL
    var configurationAccessStore: MCPClientConfigurationAccessStore
    var registrationEvidenceStore: MCPClientRegistrationEvidenceStore
    /// Deterministic test seam for changing the destination between preparation
    /// and registry activation.
    var beforeRegistrationActivationForTesting: (() throws -> Void)?
    /// Deterministic test seam for changing the destination after the reusable
    /// registry record is active but before the final configuration write.
    var afterRegistrationActivationForTesting: (() throws -> Void)?
    /// Deterministic test seam immediately before the atomic filesystem install.
    var beforeConfigurationInstallForTesting: (() throws -> Void)?
    /// Deterministic test seam after the atomic install but before the installed
    /// object is verified private and bound to the staged inode.
    var afterConfigurationInstallForTesting: (() throws -> Void)?

    init(
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default,
        registrationRegistryURL: URL? = nil,
        configurationAccessStore: MCPClientConfigurationAccessStore? = nil,
        registrationEvidenceStore: MCPClientRegistrationEvidenceStore? = nil,
        beforeRegistrationActivationForTesting: (() throws -> Void)? = nil,
        afterRegistrationActivationForTesting: (() throws -> Void)? = nil,
        beforeConfigurationInstallForTesting: (() throws -> Void)? = nil,
        afterConfigurationInstallForTesting: (() throws -> Void)? = nil
    ) {
        let isUsingProductionLocations = homeDirectory == nil
        let resolvedHomeDirectory = homeDirectory
            ?? MCPClientHostEnvironment.accountHomeDirectory(fileManager: fileManager)
        self.homeDirectory = resolvedHomeDirectory
        self.fileManager = fileManager
        if let registrationRegistryURL {
            self.registrationRegistryURL = registrationRegistryURL
        } else if isUsingProductionLocations {
            self.registrationRegistryURL = MCPClientHostEnvironment
                .privateRegistrationRegistryURL(fileManager: fileManager)
        } else {
            self.registrationRegistryURL = resolvedHomeDirectory
                .appendingPathComponent(
                    "Library/Application Support/JTS Terminal/Security",
                    isDirectory: true
                )
                .appendingPathComponent("mcp-client-registrations-v1.json")
        }
        self.configurationAccessStore = configurationAccessStore
            ?? (isUsingProductionLocations ? MCPClientConfigurationAccessStore() : .disabled)
        self.registrationEvidenceStore = registrationEvidenceStore
            ?? MCPClientRegistrationEvidenceStore(
                rootURL: self.registrationRegistryURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "MCPRegistrationEvidence",
                        isDirectory: true
                    ),
                fileManager: fileManager
            )
        self.beforeRegistrationActivationForTesting = beforeRegistrationActivationForTesting
        self.afterRegistrationActivationForTesting = afterRegistrationActivationForTesting
        self.beforeConfigurationInstallForTesting = beforeConfigurationInstallForTesting
        self.afterConfigurationInstallForTesting = afterConfigurationInstallForTesting
    }

    var registrationRegistry: MCPClientRegistrationRegistry {
        MCPClientRegistrationRegistry(storageURL: registrationRegistryURL, fileManager: fileManager)
    }

    static func arguments(registrationID: String) -> [String] {
        ["--mcp", "--mcp-client-registration", registrationID]
    }

    var codexConfigURL: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    /// User-scope Grok Build / Grok CLI config (`grok`).
    /// Official MCP entries live under `[mcp_servers.<name>]` in
    /// `~/.grok/config.toml` (or `$GROK_HOME/config.toml` when set by the user
    /// outside this sandboxed registrar path).
    var grokCLIConfigURL: URL {
        homeDirectory
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    var claudeDesktopConfigURL: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json")
    }

    /// User-scope MCP config for the Claude Code CLI (`claude`).
    /// A single large JSON object that also holds theme, startup counters,
    /// project state, etc. — registration must merge, never overwrite.
    var claudeCLIConfigURL: URL {
        homeDirectory
            .appendingPathComponent(".claude.json")
    }

    var antigravityConfigURL: URL {
        homeDirectory
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("mcp_config.json")
    }

    /// User-scope Cursor MCP config for the Cursor IDE and Cursor Agent CLI.
    /// Official global stdio entries live under `mcpServers` in `~/.cursor/mcp.json`.
    var cursorConfigURL: URL {
        homeDirectory
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("mcp.json")
    }

    func register(_ client: MCPClientKind, commandPath: String) throws -> MCPClientRegistrationResult {
        try register(client, commandPath: commandPath, destinationURL: defaultConfigURL(for: client))
    }

    func register(
        _ client: MCPClientKind,
        commandPath: String,
        destinationURL: URL
    ) throws -> MCPClientRegistrationResult {
        let preview = try registrationPreview(
            for: client,
            commandPath: commandPath,
            destinationURL: destinationURL
        )
        return try register(preview)
    }

    func register(_ preview: MCPClientRegistrationPreview) throws -> MCPClientRegistrationResult {
        let verifiedState = try requireCurrentConfigurationSnapshot(for: preview)
        let updatedData = try registeredConfigurationData(
            for: preview,
            existingData: verifiedState.data
        )

        try fileManager.createDirectory(
            at: preview.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try beforeRegistrationActivationForTesting?()
        try requireCurrentConfigurationSnapshot(for: preview)
        _ = try registrationRegistry.activate(preview.registration)
        try afterRegistrationActivationForTesting?()
        try requireCurrentConfigurationSnapshot(for: preview)
        try write(
            updatedData,
            to: preview.destinationURL,
            expectedSnapshot: preview.configurationSnapshot
        )
        // The external config may not remain readable after this Powerbox
        // scope ends. A private completion receipt lets the menu remember that
        // this exact validated command and identity finished installing.
        try? registrationEvidenceStore.recordCompletedInstall(
            registration: preview.registration,
            commandPath: preview.commandPath,
            installedConfiguration: updatedData
        )

        return MCPClientRegistrationResult(
            client: preview.client,
            configPath: preview.destinationURL.path,
            registrationID: preview.registration.registrationID
        )
    }

    func activateRegistration(_ preview: MCPClientRegistrationPreview) throws {
        try requireCurrentConfigurationSnapshot(for: preview)
        _ = try registrationRegistry.activate(preview.registration)
    }

    func defaultConfigURL(for client: MCPClientKind) -> URL {
        switch client {
        case .codexDesktop, .codexCLI: return codexConfigURL
        case .grokCLI: return grokCLIConfigURL
        case .antigravity: return antigravityConfigURL
        case .claudeDesktop: return claudeDesktopConfigURL
        case .claudeCLI: return claudeCLIConfigURL
        case .cursor: return cursorConfigURL
        }
    }

    func canonicalConfigurationDirectoryURL(
        for client: MCPClientKind
    ) -> URL {
        defaultConfigURL(for: client)
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    func validateCanonicalConfigurationDirectory(
        _ selectedURL: URL,
        for configurationURL: URL
    ) throws -> URL {
        let expectedDirectory = configurationURL
            .standardizedFileURL
            .deletingLastPathComponent()
        let selectedDirectory = selectedURL.standardizedFileURL
        guard selectedDirectory == expectedDirectory else {
            throw MCPClientRegistrationError
                .unexpectedConfigurationAuthorization(
                    expectedDirectory: expectedDirectory.path,
                    selectedDirectory: selectedDirectory.path
                )
        }
        return selectedDirectory
    }

    func registrationPreview(
        for client: MCPClientKind,
        commandPath: String,
        destinationURL: URL? = nil
    ) throws -> MCPClientRegistrationPreview {
        let url = destinationURL ?? defaultConfigURL(for: client)
        let configurationState = try configurationFileState(at: url)
        let registration = try registrationRegistry.previewRecord(for: client, configurationURL: url)
        let arguments = Self.arguments(registrationID: registration.registrationID)
        let proposed = focusedEntryText(
            for: client,
            commandPath: commandPath,
            arguments: arguments
        )
        let current = try focusedExistingEntry(
            for: client,
            data: configurationState.data,
            path: url.path
        ) ?? "<not configured>"
        return MCPClientRegistrationPreview(
            client: client,
            destinationURL: url,
            registration: registration,
            configurationSnapshot: configurationState.snapshot,
            commandPath: commandPath,
            arguments: arguments,
            configurationSnippet: proposed,
            focusedDiff: """
            Target: \(url.path)
            Target exists: \(configurationState.snapshot.exists)
            Target SHA-256: \(configurationState.snapshot.sha256)
            Target bytes: \(configurationState.snapshot.byteCount)
            Command: \(commandPath)
            Args: \(arguments)

            --- current jts-terminal entry
            \(current)
            +++ proposed jts-terminal entry
            \(proposed)
            """
        )
    }

    @discardableResult
    private func requireCurrentConfigurationSnapshot(
        for preview: MCPClientRegistrationPreview
    ) throws -> ConfigurationFileState {
        let state = try configurationFileState(at: preview.destinationURL)
        guard state.snapshot == preview.configurationSnapshot else {
            throw MCPClientRegistrationRegistryError.previewChanged
        }
        return state
    }

    private func configurationFileState(at url: URL) throws -> ConfigurationFileState {
        var pathStatus = stat()
        let statusResult = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return lstat(path, &pathStatus)
        }
        if statusResult != 0 {
            let code = errno
            if code == ENOENT {
                return ConfigurationFileState(
                    data: nil,
                    snapshot: configurationSnapshot(data: Data(), exists: false)
                )
            }
            throw PrivateFileSecurityError.operationFailed(path: url.path, code: code)
        }
        try requireSafeConfigurationTopology(pathStatus, path: url.path)

        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                return ConfigurationFileState(
                    data: nil,
                    snapshot: configurationSnapshot(data: Data(), exists: false)
                )
            }
            if code == ELOOP {
                throw MCPClientRegistrationError.unsafeConfigurationTopology(path: url.path)
            }
            throw PrivateFileSecurityError.operationFailed(path: url.path, code: code)
        }
        defer { close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0 else {
            throw PrivateFileSecurityError.operationFailed(
                path: url.path,
                code: errno == 0 ? EIO : errno
            )
        }
        try requireSafeConfigurationTopology(openedStatus, path: url.path)

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw PrivateFileSecurityError.operationFailed(
                path: url.path,
                code: errno == 0 ? EIO : errno
            )
        }
        try requireSafeConfigurationTopology(finalStatus, path: url.path)
        return ConfigurationFileState(
            data: data,
            snapshot: configurationSnapshot(data: data, exists: true)
        )
    }

    private func requireSafeConfigurationTopology(
        _ status: stat,
        path: String
    ) throws {
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1 else {
            throw MCPClientRegistrationError.unsafeConfigurationTopology(path: path)
        }
    }

    private func configurationSnapshot(
        data: Data,
        exists: Bool
    ) -> MCPClientConfigurationSnapshot {
        let sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return MCPClientConfigurationSnapshot(
            exists: exists,
            sha256: sha256,
            byteCount: data.count
        )
    }

    func registrationStatuses(commandPath: String) -> [MCPClientRegistrationStatus] {
        MCPClientKind.registrationDisplayOrder.map {
            registrationStatus(for: $0, commandPath: commandPath)
        }
    }

    func registrationStatus(
        for client: MCPClientKind,
        commandPath: String
    ) -> MCPClientRegistrationStatus {
        let defaultURL = defaultConfigURL(for: client)
            .standardizedFileURL
        let canonicalConfigurationKey = defaultURL.path
        var unavailablePath: String?
        let scopedStatus = configurationAccessStore.withAccess(for: client) {
            url -> MCPClientRegistrationStatus? in
            guard url.standardizedFileURL == defaultURL else {
                return nil
            }
            return registrationStatus(
                for: client,
                commandPath: commandPath,
                configurationURL: url
            )
        }
        switch scopedStatus {
        case .value(let status):
            if let status {
                return status
            }
        case .accessRequired(let path):
            if URL(fileURLWithPath: path).standardizedFileURL.path
                == canonicalConfigurationKey {
                unavailablePath = canonicalConfigurationKey
            }
        case .invalid(let message):
            return MCPClientRegistrationStatus(
                client: client,
                configPath: canonicalConfigurationKey,
                state: .invalidConfiguration(message)
            )
        case .notStored:
            break
        }

        let directStatus = registrationStatus(
            for: client,
            commandPath: commandPath,
            configurationURL: defaultURL
        )
        if directStatus.state != .notRegistered &&
            directStatus.state != .accessRequired {
            return directStatus
        }
        if directStatus.state == .notRegistered,
           let state = try? configurationFileState(at: defaultURL),
           state.data != nil {
            return directStatus
        }

        do {
            let records = try registrationRegistry.records(for: client)
                .filter {
                    $0.configurationKey == canonicalConfigurationKey
                }
            let prioritizedRecords = records.sorted { lhs, rhs in
                let preferredPaths = [
                    unavailablePath,
                    canonicalConfigurationKey
                ].compactMap { $0 }
                let lhsIndex = preferredPaths.firstIndex(
                    of: lhs.configurationKey
                ) ?? preferredPaths.count
                let rhsIndex = preferredPaths.firstIndex(
                    of: rhs.configurationKey
                ) ?? preferredPaths.count
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return lhs.createdAt > rhs.createdAt
            }
            for record in prioritizedRecords {
                if let verification = try registrationEvidenceStore
                    .verification(
                        for: record,
                        commandPath: commandPath
                    ) {
                    return MCPClientRegistrationStatus(
                        client: client,
                        configPath: record.configurationKey,
                        state: .registered,
                        verification: verification
                    )
                }
            }
            if let candidate = prioritizedRecords.first {
                if directStatus.state == .notRegistered,
                   candidate.configurationKey == canonicalConfigurationKey {
                    return directStatus
                }
                return MCPClientRegistrationStatus(
                    client: client,
                    configPath: candidate.configurationKey,
                    state: .accessRequired
                )
            }
        } catch {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: canonicalConfigurationKey,
                state: .invalidConfiguration(error.localizedDescription)
            )
        }
        if directStatus.state == .accessRequired {
            return directStatus
        }
        return MCPClientRegistrationStatus(
            client: client,
            configPath: canonicalConfigurationKey,
            state: .notRegistered
        )
    }

    func recordObservedRuntime(
        registration: MCPClientRegistrationRecord,
        commandPath: String
    ) throws {
        try registrationEvidenceStore.recordObservedRuntime(
            registration: registration,
            commandPath: commandPath
        )
    }

    func registrationStatus(
        for client: MCPClientKind,
        commandPath: String,
        configurationURL: URL
    ) -> MCPClientRegistrationStatus {
        switch client {
        case .codexDesktop:
            return tomlRegistrationStatus(
                client: .codexDesktop,
                url: configurationURL,
                commandPath: commandPath
            )
        case .codexCLI:
            return tomlRegistrationStatus(
                client: .codexCLI,
                url: configurationURL,
                commandPath: commandPath
            )
        case .grokCLI:
            return tomlRegistrationStatus(
                client: .grokCLI,
                url: configurationURL,
                commandPath: commandPath
            )
        case .antigravity:
            return jsonRegistrationStatus(
                client: .antigravity,
                url: configurationURL,
                commandPath: commandPath,
                requiresType: false
            )
        case .claudeDesktop:
            return jsonRegistrationStatus(
                client: .claudeDesktop,
                url: configurationURL,
                commandPath: commandPath,
                requiresType: true
            )
        case .claudeCLI:
            return jsonRegistrationStatus(
                client: .claudeCLI,
                url: configurationURL,
                commandPath: commandPath,
                requiresType: true
            )
        case .cursor:
            return jsonRegistrationStatus(
                client: .cursor,
                url: configurationURL,
                commandPath: commandPath,
                requiresType: true
            )
        }
    }

    func registerCodex(commandPath: String) throws -> MCPClientRegistrationResult {
        try register(.codexDesktop, commandPath: commandPath)
    }

    /// Codex CLI reads the same `~/.codex/config.toml` as Codex Desktop, so this
    /// writes the identical `[mcp_servers.jts-terminal]` section. It exists as a
    /// distinct menu entry so users can register by the name they know the tool by.
    func registerCodexCLI(commandPath: String) throws -> MCPClientRegistrationResult {
        try register(.codexCLI, commandPath: commandPath)
    }

    /// Registers jts-terminal into Grok Build / Grok CLI user config
    /// (`~/.grok/config.toml`) under `[mcp_servers.jts-terminal]`.
    func registerGrokCLI(commandPath: String) throws -> MCPClientRegistrationResult {
        try register(.grokCLI, commandPath: commandPath)
    }

    private func registeredConfigurationData(
        for preview: MCPClientRegistrationPreview,
        existingData: Data?
    ) throws -> Data {
        switch preview.client {
        case .codexDesktop, .codexCLI, .grokCLI:
            let existingText: String
            if let existingData {
                guard let decoded = String(data: existingData, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                existingText = decoded
            } else {
                existingText = ""
            }
            return Data(registeredTOMLText(for: preview, existingText: existingText).utf8)
        case .antigravity, .claudeDesktop, .claudeCLI, .cursor:
            return try registeredJSONData(for: preview, existingData: existingData)
        }
    }

    private func registeredTOMLText(
        for preview: MCPClientRegistrationPreview,
        existingText: String
    ) -> String {
        let replacement = """
        [mcp_servers.\(Self.serverName)]
        command = \(Self.tomlStringLiteral(preview.commandPath))
        args = [\(preview.arguments.map(Self.tomlStringLiteral).joined(separator: ", "))]
        """
        return Self.replacingTOMLSection(
            named: "[mcp_servers.\(Self.serverName)]",
            in: existingText,
            with: replacement
        )
    }

    func registerClaudeDesktop(commandPath: String) throws -> MCPClientRegistrationResult {
        try register(.claudeDesktop, commandPath: commandPath)
    }

    /// Registers the jts-terminal MCP server into the Claude Code CLI's user-scope
    /// config (`~/.claude.json`). Registration merges the verified JSON bytes and
    /// only replaces the `mcpServers.jts-terminal` entry, so unrelated keys
    /// (theme, numStartups, projects, etc.) are preserved.
    func registerClaudeCLI(commandPath: String) throws -> MCPClientRegistrationResult {
        try register(.claudeCLI, commandPath: commandPath)
    }

    func registerAntigravity(commandPath: String) throws -> MCPClientRegistrationResult {
        try register(.antigravity, commandPath: commandPath)
    }

    /// Registers the jts-terminal MCP server into Cursor's user-scope global
    /// config (`~/.cursor/mcp.json`). Registration merges the verified JSON
    /// bytes and only replaces the `mcpServers.jts-terminal` entry.
    func registerCursor(commandPath: String) throws -> MCPClientRegistrationResult {
        try register(.cursor, commandPath: commandPath)
    }

    private func registeredJSONData(
        for preview: MCPClientRegistrationPreview,
        existingData: Data?
    ) throws -> Data {
        var root = try readJSONObject(
            data: existingData ?? Data(),
            path: preview.destinationURL.path
        )
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        var server: [String: Any] = [
            "command": preview.commandPath,
            "args": preview.arguments
        ]
        if Self.jsonEntryRequiresType(preview.client) {
            server["type"] = "stdio"
        }
        mcpServers[Self.serverName] = server
        root["mcpServers"] = mcpServers

        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    private func readJSONObject(from url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        return try readJSONObject(data: data, path: url.path)
    }

    private func readJSONObject(data: Data, path: String) throws -> [String: Any] {
        guard !data.isEmpty else {
            return [:]
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MCPClientRegistrationError.invalidJSON(path: path)
        }

        guard let dictionary = object as? [String: Any] else {
            throw MCPClientRegistrationError.invalidConfigShape(path: path)
        }
        return dictionary
    }

    private func tomlRegistrationStatus(
        client: MCPClientKind,
        url: URL,
        commandPath: String
    ) -> MCPClientRegistrationStatus {
        let path = url.path
        let configurationState: ConfigurationFileState
        do {
            configurationState = try configurationFileState(at: url)
        } catch PrivateFileSecurityError.operationFailed(_, let code)
            where code == EACCES || code == EPERM {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .accessRequired
            )
        } catch {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .invalidConfiguration(error.localizedDescription)
            )
        }
        guard let data = configurationState.data else {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .notRegistered
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .invalidConfiguration(
                    CocoaError(.fileReadInapplicableStringEncoding).localizedDescription
                )
            )
        }

        guard let section = Self.tomlSection(named: "[mcp_servers.\(Self.serverName)]", in: text) else {
            return MCPClientRegistrationStatus(client: client, configPath: path, state: .notRegistered)
        }

        let expectedArguments: [String]
        do {
            guard let registration = try registrationRegistry.record(for: url) else {
                return MCPClientRegistrationStatus(client: client, configPath: path, state: .needsUpdate)
            }
            expectedArguments = Self.arguments(registrationID: registration.registrationID)
        } catch {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .invalidConfiguration(error.localizedDescription)
            )
        }

        let configuredCommand = Self.tomlStringValue(for: "command", in: section)
        let commandMatches = configuredCommand.map {
            Self.commandMatchesRegistration(
                configuredCommand: $0,
                expectedCommand: commandPath,
                fileManager: fileManager
            )
        } ?? false
        let hasExpectedArgs = section.contains {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
                == "args=[\(expectedArguments.map(Self.tomlStringLiteral).joined(separator: ","))]"
        }
        return MCPClientRegistrationStatus(
            client: client,
            configPath: path,
            state: commandMatches && hasExpectedArgs ? .registered : .needsUpdate,
            verification: commandMatches && hasExpectedArgs
                ? .configuration
                : nil
        )
    }

    private func jsonRegistrationStatus(
        client: MCPClientKind,
        url: URL,
        commandPath: String,
        requiresType: Bool
    ) -> MCPClientRegistrationStatus {
        let path = url.path
        let configurationState: ConfigurationFileState
        do {
            configurationState = try configurationFileState(at: url)
        } catch PrivateFileSecurityError.operationFailed(_, let code)
            where code == EACCES || code == EPERM {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .accessRequired
            )
        } catch {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .invalidConfiguration(error.localizedDescription)
            )
        }
        guard let data = configurationState.data else {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .notRegistered
            )
        }

        let root: [String: Any]
        do {
            root = try readJSONObject(data: data, path: path)
        } catch {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .invalidConfiguration(error.localizedDescription)
            )
        }

        guard let mcpServers = root["mcpServers"] as? [String: Any],
              let server = mcpServers[Self.serverName] as? [String: Any] else {
            return MCPClientRegistrationStatus(client: client, configPath: path, state: .notRegistered)
        }

        let configuredCommand = server["command"] as? String
        let commandMatches = configuredCommand.map {
            Self.commandMatchesRegistration(
                configuredCommand: $0,
                expectedCommand: commandPath,
                fileManager: fileManager
            )
        } ?? false
        let expectedArguments: [String]
        do {
            guard let registration = try registrationRegistry.record(for: url) else {
                return MCPClientRegistrationStatus(client: client, configPath: path, state: .needsUpdate)
            }
            expectedArguments = Self.arguments(registrationID: registration.registrationID)
        } catch {
            return MCPClientRegistrationStatus(
                client: client,
                configPath: path,
                state: .invalidConfiguration(error.localizedDescription)
            )
        }
        let argsMatch = server["args"] as? [String] == expectedArguments
        let configuredType = server["type"] as? String
        let typeMatches = !requiresType || configuredType == nil || configuredType == "stdio"
        return MCPClientRegistrationStatus(
            client: client,
            configPath: path,
            state: commandMatches && argsMatch && typeMatches ? .registered : .needsUpdate,
            verification: commandMatches && argsMatch && typeMatches
                ? .configuration
                : nil
        )
    }

    private func write(
        _ data: Data,
        to url: URL,
        expectedSnapshot: MCPClientConfigurationSnapshot
    ) throws {
        let installedSnapshot = configurationSnapshot(data: data, exists: true)
        let stagedFile = try PrivateFileSecurity.createReplacementStagedFile(
            for: url,
            fileManager: fileManager
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                PrivateFileSecurity.removeStaging(
                    stagedFile,
                    fileManager: fileManager
                )
            }
        }

        do {
            try stagedFile.handle.write(contentsOf: data)
            try stagedFile.handle.synchronize()
            try stagedFile.handle.close()
        } catch {
            try? stagedFile.handle.close()
            throw error
        }
        try beforeConfigurationInstallForTesting?()
        let currentState = try configurationFileState(at: url)
        guard currentState.snapshot == expectedSnapshot else {
            throw MCPClientRegistrationRegistryError.previewChanged
        }

        if expectedSnapshot.exists {
            if let code = PrivateFileSecurity.renameError(
                from: stagedFile.fileURL,
                to: url,
                flags: UInt32(RENAME_SWAP)
            ) {
                if code == ENOENT {
                    throw MCPClientRegistrationRegistryError.previewChanged
                }
                throw PrivateFileSecurityError.operationFailed(
                    path: url.path,
                    code: code
                )
            }

            let displacedState: ConfigurationFileState
            do {
                displacedState = try configurationFileState(at: stagedFile.fileURL)
            } catch {
                try restoreDisplacedConfiguration(
                    stagedFile,
                    destinationURL: url,
                    installedSnapshot: installedSnapshot,
                    shouldRemoveStaging: &shouldRemoveStaging
                )
                throw error
            }
            guard displacedState.snapshot == expectedSnapshot else {
                try restoreDisplacedConfiguration(
                    stagedFile,
                    destinationURL: url,
                    installedSnapshot: installedSnapshot,
                    shouldRemoveStaging: &shouldRemoveStaging
                )
                throw MCPClientRegistrationRegistryError.previewChanged
            }
        } else {
            if let code = PrivateFileSecurity.renameError(
                from: stagedFile.fileURL,
                to: url,
                flags: UInt32(RENAME_EXCL)
            ) {
                if code == EEXIST {
                    throw MCPClientRegistrationRegistryError.previewChanged
                }
                throw PrivateFileSecurityError.operationFailed(
                    path: url.path,
                    code: code
                )
            }
        }

        do {
            try afterConfigurationInstallForTesting?()
            try PrivateFileSecurity.verifyPrivateFile(at: url)
            guard try PrivateFileSecurity.identity(at: url) == stagedFile.identity else {
                throw MCPClientRegistrationError.insecurePermissions(path: url.path)
            }
        } catch {
            if expectedSnapshot.exists {
                try restoreDisplacedConfiguration(
                    stagedFile,
                    destinationURL: url,
                    installedSnapshot: installedSnapshot,
                    shouldRemoveStaging: &shouldRemoveStaging
                )
            } else {
                try removeNewConfigurationAfterFailedVerification(
                    stagedFile,
                    destinationURL: url,
                    installedSnapshot: installedSnapshot,
                    shouldRemoveStaging: &shouldRemoveStaging
                )
            }
            throw MCPClientRegistrationError.insecurePermissions(path: url.path)
        }
    }

    private func removeNewConfigurationAfterFailedVerification(
        _ stagedFile: PrivateStagedFile,
        destinationURL: URL,
        installedSnapshot: MCPClientConfigurationSnapshot,
        shouldRemoveStaging: inout Bool
    ) throws {
        guard (try? PrivateFileSecurity.identity(at: destinationURL))
                == stagedFile.identity,
              (try? configurationFileState(at: destinationURL).snapshot)
                == installedSnapshot else {
            throw MCPClientRegistrationError.insecurePermissions(
                path: destinationURL.path
            )
        }

        if let code = PrivateFileSecurity.renameError(
            from: destinationURL,
            to: stagedFile.fileURL,
            flags: UInt32(RENAME_EXCL)
        ) {
            if code == ENOENT {
                return
            }
            throw PrivateFileSecurityError.operationFailed(
                path: destinationURL.path,
                code: code
            )
        }

        let movedIdentity = try? PrivateFileSecurity.identity(at: stagedFile.fileURL)
        let movedSnapshot = try? configurationFileState(at: stagedFile.fileURL).snapshot
        guard movedIdentity == stagedFile.identity,
              movedSnapshot == installedSnapshot else {
            if PrivateFileSecurity.renameError(
                from: stagedFile.fileURL,
                to: destinationURL,
                flags: UInt32(RENAME_EXCL)
            ) != nil {
                shouldRemoveStaging = false
                throw MCPClientRegistrationError.commitRecoveryRequired(
                    path: destinationURL.path,
                    recoveryPath: stagedFile.fileURL.path
                )
            }
            throw MCPClientRegistrationError.insecurePermissions(
                path: destinationURL.path
            )
        }
    }

    private func restoreDisplacedConfiguration(
        _ stagedFile: PrivateStagedFile,
        destinationURL: URL,
        installedSnapshot: MCPClientConfigurationSnapshot,
        shouldRemoveStaging: inout Bool
    ) throws {
        guard let displacedIdentity = try? PrivateFileSecurity.identity(at: stagedFile.fileURL) else {
            shouldRemoveStaging = false
            throw MCPClientRegistrationError.commitRecoveryRequired(
                path: destinationURL.path,
                recoveryPath: stagedFile.fileURL.path
            )
        }
        let destinationIdentity = try? PrivateFileSecurity.identity(at: destinationURL)
        let destinationSnapshot = try? configurationFileState(at: destinationURL).snapshot
        guard destinationIdentity == stagedFile.identity,
              destinationSnapshot == installedSnapshot else {
            shouldRemoveStaging = false
            throw MCPClientRegistrationError.commitRecoveryRequired(
                path: destinationURL.path,
                recoveryPath: stagedFile.fileURL.path
            )
        }
        if let _ = PrivateFileSecurity.renameError(
            from: stagedFile.fileURL,
            to: destinationURL,
            flags: UInt32(RENAME_SWAP)
        ) {
            shouldRemoveStaging = false
            throw MCPClientRegistrationError.commitRecoveryRequired(
                path: destinationURL.path,
                recoveryPath: stagedFile.fileURL.path
            )
        }
        guard (try? PrivateFileSecurity.identity(at: stagedFile.fileURL))
                == stagedFile.identity,
              (try? PrivateFileSecurity.identity(at: destinationURL))
                == displacedIdentity else {
            shouldRemoveStaging = false
            throw MCPClientRegistrationError.commitRecoveryRequired(
                path: destinationURL.path,
                recoveryPath: stagedFile.fileURL.path
            )
        }
    }

    static func replacingTOMLSection(
        named sectionHeader: String,
        in text: String,
        with replacement: String
    ) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let targetHeader = normalizedTOMLTableHeader(sectionHeader) ?? sectionHeader
        var output: [String] = []
        var index = 0
        var didReplace = false

        while index < lines.count {
            if normalizedTOMLTableHeader(lines[index]) == targetHeader {
                if !didReplace {
                    if !output.isEmpty, output.last?.isEmpty == false {
                        output.append("")
                    }
                    output.append(contentsOf: replacement.split(separator: "\n").map(String.init))
                    didReplace = true
                }
                index += 1

                while index < lines.count {
                    if normalizedTOMLTableHeader(lines[index]) != nil {
                        break
                    }
                    index += 1
                }
            } else {
                output.append(lines[index])
                index += 1
            }
        }

        if !didReplace {
            if !output.isEmpty, output.last?.isEmpty == false {
                output.append("")
            }
            output.append(contentsOf: replacement.split(separator: "\n").map(String.init))
        }

        while output.last?.isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n") + "\n"
    }

    static func tomlSection(named sectionHeader: String, in text: String) -> [String]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let targetHeader = normalizedTOMLTableHeader(sectionHeader) ?? sectionHeader
        guard let start = lines.firstIndex(where: { normalizedTOMLTableHeader($0) == targetHeader }) else {
            return nil
        }

        var section: [String] = []
        var index = start + 1
        while index < lines.count {
            if normalizedTOMLTableHeader(lines[index]) != nil {
                break
            }
            section.append(lines[index])
            index += 1
        }
        return section
    }

    /// Canonical form of a TOML table header line, or nil for any other line.
    ///
    /// Equivalent spellings of the same table — a quoted bare key such as
    /// `[mcp_servers."jts-terminal"]`, whitespace inside the brackets, or a
    /// trailing comment — map to one value. Registration therefore replaces a
    /// hand-written entry instead of appending a duplicate table, which TOML
    /// readers reject, and a commented header is still seen as the start of
    /// the next table, so its content is never swallowed by a replacement.
    static func normalizedTOMLTableHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        let isArrayTable = trimmed.hasPrefix("[[")
        let opening = isArrayTable ? "[[" : "["
        let closing = isArrayTable ? "]]" : "]"

        var segments: [String] = []
        var current = ""
        var quote: Character?
        var index = trimmed.index(trimmed.startIndex, offsetBy: opening.count)
        var keyEnd: String.Index?
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "]" {
                keyEnd = index
                break
            } else if character == "." {
                segments.append(current)
                current = ""
            } else if character != " " && character != "\t" {
                current.append(character)
            }
            index = trimmed.index(after: index)
        }
        guard let keyEnd, quote == nil else { return nil }
        segments.append(current)

        let afterKey = trimmed[keyEnd...]
        guard afterKey.hasPrefix(closing) else { return nil }
        let remainder = afterKey.dropFirst(closing.count).trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty || remainder.hasPrefix("#") else { return nil }

        let bareKeyCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let normalizedSegments = segments.map { segment -> String in
            guard segment.count >= 2,
                  let first = segment.first, let last = segment.last,
                  first == last, first == "\"" || first == "'" else {
                return segment
            }
            let inner = String(segment.dropFirst().dropLast())
            guard !inner.isEmpty,
                  inner.unicodeScalars.allSatisfy { bareKeyCharacters.contains($0) } else {
                return segment
            }
            return inner
        }
        return opening + normalizedSegments.joined(separator: ".") + closing
    }

    static func tomlStringValue(for key: String, in section: [String]) -> String? {
        let keyPrefix = "\(key) ="
        guard let assignment = section
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix(keyPrefix) }) else {
            return nil
        }

        let value = assignment
            .dropFirst(keyPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        return decodeTOMLStringLiteral(value)
    }

    private static func decodeTOMLStringLiteral(_ literal: String) -> String? {
        guard literal.first == "\"" else { return nil }

        var output = ""
        var index = literal.index(after: literal.startIndex)
        while index < literal.endIndex {
            let character = literal[index]
            if character == "\"" {
                return output
            }
            if character == "\\" {
                let nextIndex = literal.index(after: index)
                guard nextIndex < literal.endIndex else { return nil }
                switch literal[nextIndex] {
                case "\\":
                    output.append("\\")
                case "\"":
                    output.append("\"")
                case "n":
                    output.append("\n")
                case "r":
                    output.append("\r")
                case "t":
                    output.append("\t")
                default:
                    return nil
                }
                index = literal.index(after: nextIndex)
            } else {
                output.append(character)
                index = literal.index(after: index)
            }
        }

        return nil
    }

    private static func commandMatchesRegistration(
        configuredCommand: String,
        expectedCommand: String,
        fileManager: FileManager
    ) -> Bool {
        configuredCommand == expectedCommand &&
            fileManager.isExecutableFile(atPath: configuredCommand)
    }

    private func focusedEntryText(for client: MCPClientKind, commandPath: String, arguments: [String]) -> String {
        switch client {
        case .codexDesktop, .codexCLI, .grokCLI:
            return """
            [mcp_servers.\(Self.serverName)]
            command = \(Self.tomlStringLiteral(commandPath))
            args = [\(arguments.map(Self.tomlStringLiteral).joined(separator: ", "))]
            """
        case .antigravity, .claudeDesktop, .claudeCLI, .cursor:
            var server: [String: Any] = [
                "command": commandPath,
                "args": arguments,
            ]
            if Self.jsonEntryRequiresType(client) {
                server["type"] = "stdio"
            }
            let data = (try? JSONSerialization.data(withJSONObject: server, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func focusedExistingEntry(
        for client: MCPClientKind,
        data: Data?,
        path: String
    ) throws -> String? {
        guard let data else { return nil }
        switch client {
        case .codexDesktop, .codexCLI, .grokCLI:
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            guard let section = Self.tomlSection(named: "[mcp_servers.\(Self.serverName)]", in: text) else {
                return nil
            }
            return (["[mcp_servers.\(Self.serverName)]"] + section).joined(separator: "\n")
        case .antigravity, .claudeDesktop, .claudeCLI, .cursor:
            let root = try readJSONObject(data: data, path: path)
            guard let servers = root["mcpServers"] as? [String: Any],
                  let server = servers[Self.serverName] else { return nil }
            let data = try JSONSerialization.data(withJSONObject: server, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func jsonEntryRequiresType(_ client: MCPClientKind) -> Bool {
        switch client {
        case .claudeDesktop, .claudeCLI, .cursor:
            return true
        case .antigravity, .codexDesktop, .codexCLI, .grokCLI:
            return false
        }
    }

    static func shellDisplayLiteral(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func tomlStringLiteral(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 92:
                escaped += "\\\\"
            case 34:
                escaped += "\\\""
            case 10:
                escaped += "\\n"
            case 13:
                escaped += "\\r"
            case 9:
                escaped += "\\t"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
    }
}
