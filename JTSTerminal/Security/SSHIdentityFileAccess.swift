//
//  SSHIdentityFileAccess.swift
//  JTSTerminal
//

import Foundation

/// App Sandbox lets `/usr/bin/ssh -i` read a private key outside the app
/// container only while this process holds a security-scoped grant for it.
/// The grant from the open panel ends with the process, and the MCP stdio
/// process never sees the panel at all, so the selection is persisted as an
/// app-scoped, read-only bookmark and restored before ssh is started.
nonisolated enum SSHIdentityFileAccess {
    static let defaultsKey = "sshIdentityFileBookmarks.v1"

    /// The path key shared by the editor and the ssh argument builders.
    static func storageKey(for identityFile: String) -> String? {
        let trimmed = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Saves read access to a key chosen in the open panel and keeps it
    /// active for the rest of this process.
    @discardableResult
    static func remember(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let key = storageKey(for: url.path),
              let bookmark = makeBookmark(for: url) else {
            return false
        }
        var stored = storedBookmarks(defaults: defaults)
        stored[key] = bookmark
        defaults.set(stored, forKey: defaultsKey)
        registry.activate(key: key, bookmark: bookmark, defaults: defaults)
        return true
    }

    /// Restores the saved grant for `identityFile` in this process. ssh
    /// processes started afterwards inherit it. A missing or stale bookmark is
    /// ignored; ssh then reports the unreadable key as before.
    static func activateIfNeeded(for identityFile: String, defaults: UserDefaults = .standard) {
        guard let key = storageKey(for: identityFile),
              let bookmark = storedBookmarks(defaults: defaults)[key] else {
            return
        }
        registry.activate(key: key, bookmark: bookmark, defaults: defaults)
    }

    static func hasStoredAccess(for identityFile: String, defaults: UserDefaults = .standard) -> Bool {
        guard let key = storageKey(for: identityFile) else { return false }
        return storedBookmarks(defaults: defaults)[key] != nil
    }

    fileprivate static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    fileprivate static func storedBookmarks(defaults: UserDefaults) -> [String: Data] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private static let registry = SSHIdentityFileAccessRegistry()
}

/// Process-wide set of active grants. Each key is started at most once and
/// intentionally stays active until the process exits, because ssh child
/// processes may still be reading the key.
nonisolated private final class SSHIdentityFileAccessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeURLs: [String: URL] = [:]

    func activate(key: String, bookmark: Data, defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        guard activeURLs[key] == nil else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), url.startAccessingSecurityScopedResource() else {
            return
        }
        activeURLs[key] = url

        if isStale, let refreshed = SSHIdentityFileAccess.makeBookmark(for: url) {
            var stored = SSHIdentityFileAccess.storedBookmarks(defaults: defaults)
            stored[key] = refreshed
            defaults.set(stored, forKey: SSHIdentityFileAccess.defaultsKey)
        }
    }
}
