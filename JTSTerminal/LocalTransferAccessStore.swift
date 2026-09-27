import Foundation

/// These standard directories are covered by the main app's signed sandbox
/// entitlements. They do not need a persisted Powerbox bookmark.
nonisolated enum LocalTransferDefaultFolders {
    static let names = ["Downloads", "Pictures", "Music", "Movies"]

    static func contains(_ url: URL, accountHome: URL = MCPClientHostEnvironment.accountHomeDirectory()) -> Bool {
        let candidate = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return names.contains { name in
            let folder = accountHome.appendingPathComponent(name, isDirectory: true)
            return LocalTransferAccessStore.contains(candidate, in: folder.standardizedFileURL.path)
                && LocalTransferAccessStore.contains(resolved, in: folder.resolvingSymlinksInPath().path)
        }
    }
}

nonisolated struct LocalTransferAccessRequired: LocalizedError {
    let path: String

    var errorDescription: String? {
        "LOCAL_FILE_ACCESS_REQUIRED: JTS Terminal cannot access \(path). Downloads, Pictures, Music and Movies are available by default. For another folder, choose MCP > Local Transfer Folders… (本地传输文件夹…), authorize its folder, then retry. Saved folder access is reused by MCP."
    }

    static func explaining(_ error: Error, path: String) -> Error {
        MCPClientConfigurationAuthorizationErrorClassifier.requiresAuthorization(error)
            ? LocalTransferAccessRequired(path: path) : error
    }
}

/// Holds the original security-scoped URL, not a URL rebuilt from its path.
nonisolated final class LocalTransferAccessLease {
    private var urls: [URL] = []

    func start(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { urls.append(url) }
    }

    func stop() {
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
        urls.removeAll()
    }

    deinit { urls.forEach { $0.stopAccessingSecurityScopedResource() } }
}

/// One private record per explicitly selected folder. Read from disk on every
/// operation so an already-running MCP process sees GUI grants and revocations.
nonisolated struct LocalTransferAccessStore {
    struct Folder: Codable, Identifiable {
        let id: UUID
        let path: String
        let bookmark: Data
    }

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? MCPClientHostEnvironment
            .privateRegistrationRegistryURL().deletingLastPathComponent()
            .appendingPathComponent("LocalTransferFolders", isDirectory: true)
    }

    func folders() throws -> [Folder] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try PrivateFileSecurity.verifyPrivateDirectory(at: directory)
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.map { url in
            try PrivateFileSecurity.verifyPrivateFile(at: url)
            return try JSONDecoder().decode(Folder.self, from: Data(contentsOf: url))
        }.sorted { $0.path < $1.path }
    }

    func authorize(_ url: URL) throws {
        let lease = LocalTransferAccessLease()
        lease.start(url)
        defer { lease.stop() }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let existing = try folders().first { $0.path == path }
        let folder = Folder(
            id: existing?.id ?? UUID(), path: path,
            bookmark: try url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            )
        )
        try PrivateFileSecurity.secureDirectory(at: directory)
        let destination = directory.appendingPathComponent("\(folder.id.uuidString).json")
        let staged = try PrivateFileSecurity.createStagedFile(adjacentTo: destination)
        defer { PrivateFileSecurity.removeStaging(staged) }
        try staged.handle.write(contentsOf: JSONEncoder().encode(folder))
        try staged.handle.synchronize()
        try PrivateFileSecurity.installReplacing(staged, at: destination)
    }

    func revoke(_ folder: Folder) throws {
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(folder.id.uuidString).json")
        )
    }

    func beginAccess(to url: URL) throws -> LocalTransferAccessLease {
        let lease = LocalTransferAccessLease()
        // A stale custom bookmark must not block built-in file access.
        if LocalTransferDefaultFolders.contains(url) { return lease }
        let candidate = url.standardizedFileURL.path
        for folder in try folders() where Self.contains(candidate, in: folder.path) {
            var stale = false
            let resolved: URL
            do {
                resolved = try URL(
                    resolvingBookmarkData: folder.bookmark,
                    options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            } catch {
                throw LocalTransferAccessRequired(path: folder.path)
            }
            lease.start(resolved)
            // Never redirect an MCP request when a bookmarked directory moves,
            // or use a folder grant to traverse a symlink outside that folder.
            guard resolved.resolvingSymlinksInPath().standardizedFileURL.path == folder.path,
                  Self.contains(url.resolvingSymlinksInPath().path, in: folder.path) else {
                throw LocalTransferAccessRequired(path: url.path)
            }
        }
        return lease
    }

    static func contains(_ path: String, in folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }
}
