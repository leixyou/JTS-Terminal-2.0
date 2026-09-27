//
//  MCPClientConfigurationAccess.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/29.
//

import Darwin
import Foundation

nonisolated enum MCPClientConfigurationEndpoint: String, Codable {
    case codex
    case claudeDesktop
    case claudeCLI
    case antigravity
    case grok
    case cursor
}

nonisolated extension MCPClientKind {
    var configurationEndpoint: MCPClientConfigurationEndpoint {
        switch self {
        case .codexDesktop, .codexCLI:
            return .codex
        case .claudeDesktop:
            return .claudeDesktop
        case .claudeCLI:
            return .claudeCLI
        case .antigravity:
            return .antigravity
        case .grokCLI:
            return .grok
        case .cursor:
            return .cursor
        }
    }
}

/// The app sandbox rewrites Foundation's home directory to the app container.
/// MCP client configuration files still live in the login account's real home.
nonisolated enum MCPClientHostEnvironment {
    static func accountHomeDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        var account = passwd()
        var resolvedAccount: UnsafeMutablePointer<passwd>?
        let suggestedBufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = suggestedBufferSize > 0
            ? max(Int(suggestedBufferSize), 1_024)
            : 16_384
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            getpwuid_r(
                getuid(),
                &account,
                pointer.baseAddress,
                pointer.count,
                &resolvedAccount
            )
        }
        if result == 0,
           resolvedAccount != nil,
           let homePointer = account.pw_dir,
           let resolved = validatedAccountHome(
               String(cString: homePointer)
           ) {
            return resolved
        }

        if let lookupHome = NSHomeDirectoryForUser(NSUserName()),
           let resolved = validatedAccountHome(lookupHome) {
            return resolved
        }

        let conventionalHome = URL(
            fileURLWithPath: "/Users",
            isDirectory: true
        ).appendingPathComponent(NSUserName(), isDirectory: true)
        if fileManager.fileExists(atPath: conventionalHome.path) {
            return conventionalHome.standardizedFileURL
        }

        return fileManager.homeDirectoryForCurrentUser
            .standardizedFileURL
    }

    static func privateRegistrationRegistryURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("JTS Terminal/Security", isDirectory: true)
            .appendingPathComponent("mcp-client-registrations-v1.json")
    }

    private static func validatedAccountHome(
        _ path: String
    ) -> URL? {
        guard path.hasPrefix("/"),
              !path.contains("/Library/Containers/") else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
    }
}

nonisolated struct MCPClientPreparedConfigurationAccess {
    fileprivate let endpoint: MCPClientConfigurationEndpoint
    fileprivate let record: MCPClientConfigurationAccessStore.Record
}

nonisolated enum MCPClientScopedConfigurationAccess<Value> {
    case notStored
    case accessRequired(path: String)
    case invalid(message: String)
    case value(Value)
}

/// Classifies configuration mutations that macOS can resolve by granting the
/// canonical client configuration directory through Powerbox.
///
/// PrivateFileSecurityError is a native Swift error with an associated errno.
/// Bridging it to NSError does not preserve that errno as a POSIX error code,
/// so it must be inspected before traversing the bridged NSError chain.
nonisolated enum MCPClientConfigurationAuthorizationErrorClassifier {
    static func requiresAuthorization(_ error: Error) -> Bool {
        if let privateFileError = error as? PrivateFileSecurityError,
           case .operationFailed(_, let code) = privateFileError,
           isPermissionDenied(code) {
            return true
        }

        var pending = [error as NSError]
        var visited = Set<ObjectIdentifier>()
        while let current = pending.popLast() {
            let identifier = ObjectIdentifier(current)
            guard visited.insert(identifier).inserted else {
                continue
            }
            if current.domain == NSPOSIXErrorDomain,
               isPermissionDenied(current.code) {
                return true
            }
            if current.domain == NSCocoaErrorDomain,
               current.code == CocoaError.fileReadNoPermission.rawValue
                || current.code
                    == CocoaError.fileWriteNoPermission.rawValue {
                return true
            }
            if let underlying = current.userInfo[
                NSUnderlyingErrorKey
            ] as? NSError {
                pending.append(underlying)
            }
            if let detailed = current.userInfo[
                detailedErrorsUserInfoKey
            ] as? [NSError] {
                pending.append(contentsOf: detailed)
            }
        }
        return false
    }

    private static func isPermissionDenied(_ code: Int32) -> Bool {
        code == EACCES || code == EPERM
    }

    private static func isPermissionDenied(_ code: Int) -> Bool {
        code == Int(EACCES) || code == Int(EPERM)
    }

    /// Foundation does not export Core Data's NSDetailedErrorsKey unless the
    /// client imports CoreData. NSError stores it under this stable userInfo key.
    private static let detailedErrorsUserInfoKey = "NSDetailedErrorsKey"
}

/// Persists the Powerbox-authorized canonical MCP configuration directory as a
/// security-scoped bookmark. The bookmark is keyed by the physical client
/// configuration endpoint, so Codex Desktop and Codex CLI correctly share one
/// `~/.codex/config.toml` grant.
///
/// JTS Terminal always derives the configuration filename itself. The user
/// authorizes only the known parent directory; no user-selected filename or
/// alternate path is accepted. Directory scope is required because registration
/// uses an adjacent staged file and atomic replacement instead of rewriting a
/// live client configuration in place.
nonisolated struct MCPClientConfigurationAccessStore {
    fileprivate struct Record: Codable, Equatable {
        var path: String
        var scopePath: String?
        var bookmarkData: Data
    }

    private struct PersistedState: Codable {
        var formatVersion: Int
        var records: [String: Record]
    }

    static let storageKey = "mcpClientConfigurationAccess.v1"
    private static let formatVersion = 1
    private static let lock = NSLock()

    private let defaults: UserDefaults?
    private let fileManager: FileManager

    init(
        defaults: UserDefaults? = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    static var disabled: MCPClientConfigurationAccessStore {
        MCPClientConfigurationAccessStore(defaults: nil)
    }

    func prepareAccess(
        for client: MCPClientKind,
        configurationURL: URL,
        scopeURL: URL? = nil
    ) throws -> MCPClientPreparedConfigurationAccess {
        let standardizedURL = configurationURL.standardizedFileURL
        let standardizedScopeURL = (
            scopeURL ?? standardizedURL
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: standardizedScopeURL.path,
            isDirectory: &isDirectory
        ) else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: standardizedScopeURL.path]
            )
        }
        if standardizedScopeURL != standardizedURL {
            guard isDirectory.boolValue,
                  standardizedURL.deletingLastPathComponent()
                    == standardizedScopeURL else {
                throw CocoaError(
                    .fileReadInvalidFileName,
                    userInfo: [
                        NSFilePathErrorKey: standardizedURL.path,
                        "JTSScopePath": standardizedScopeURL.path,
                    ]
                )
            }
        } else if isDirectory.boolValue {
            throw CocoaError(
                .fileReadInvalidFileName,
                userInfo: [NSFilePathErrorKey: standardizedURL.path]
            )
        }
        let bookmarkData = try standardizedScopeURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return MCPClientPreparedConfigurationAccess(
            endpoint: client.configurationEndpoint,
            record: Record(
                path: standardizedURL.path,
                scopePath: standardizedScopeURL.path,
                bookmarkData: bookmarkData
            )
        )
    }

    func persist(_ prepared: MCPClientPreparedConfigurationAccess) throws {
        guard let defaults else { return }
        try Self.lock.withLock {
            var state = try loadState(defaults: defaults)
            state.records[prepared.endpoint.rawValue] = prepared.record
            try persist(state, defaults: defaults)
        }
    }

    func storedPath(for client: MCPClientKind) -> String? {
        guard let defaults else { return nil }
        return try? Self.lock.withLock {
            try loadState(defaults: defaults)
                .records[client.configurationEndpoint.rawValue]?
                .path
        }
    }

    func removeAccess(for client: MCPClientKind) throws {
        guard let defaults else { return }
        try Self.lock.withLock {
            var state = try loadState(defaults: defaults)
            state.records.removeValue(
                forKey: client.configurationEndpoint.rawValue
            )
            try persist(state, defaults: defaults)
        }
    }

    func withAccess<Value>(
        for client: MCPClientKind,
        _ body: (URL) -> Value
    ) -> MCPClientScopedConfigurationAccess<Value> {
        guard let defaults else { return .notStored }

        let storedRecord: Record
        do {
            guard let record = try Self.lock.withLock({
                try loadState(defaults: defaults)
                    .records[client.configurationEndpoint.rawValue]
            }) else {
                return .notStored
            }
            storedRecord = record
        } catch {
            return .invalid(message: error.localizedDescription)
        }

        var isStale = false
        let resolvedScopeURL: URL
        do {
            resolvedScopeURL = try URL(
                resolvingBookmarkData: storedRecord.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
        } catch {
            return .accessRequired(path: storedRecord.path)
        }

        let didStartAccess = resolvedScopeURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                resolvedScopeURL.stopAccessingSecurityScopedResource()
            }
        }

        let storedScopePath = storedRecord.scopePath ?? storedRecord.path
        let resolvedConfigurationURL: URL
        if storedScopePath == storedRecord.path {
            resolvedConfigurationURL = resolvedScopeURL
        } else {
            resolvedConfigurationURL = resolvedScopeURL
                .appendingPathComponent(
                    URL(fileURLWithPath: storedRecord.path).lastPathComponent
                )
                .standardizedFileURL
        }

        if isStale {
            do {
                let refreshedScopeURL = storedScopePath == storedRecord.path
                    ? nil
                    : resolvedScopeURL
                let refreshed = try prepareAccess(
                    for: client,
                    configurationURL: resolvedConfigurationURL,
                    scopeURL: refreshedScopeURL
                )
                try persist(refreshed)
            } catch {
                return .accessRequired(path: storedRecord.path)
            }
        }

        return .value(body(resolvedConfigurationURL))
    }

    private func loadState(defaults: UserDefaults) throws -> PersistedState {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return PersistedState(
                formatVersion: Self.formatVersion,
                records: [:]
            )
        }
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        guard state.formatVersion == Self.formatVersion else {
            throw CocoaError(.coderReadCorrupt)
        }
        return state
    }

    private func persist(
        _ state: PersistedState,
        defaults: UserDefaults
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(state), forKey: Self.storageKey)
    }
}
