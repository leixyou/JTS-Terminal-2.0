//
//  PrivateFileSecurity.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/17.
//

import Darwin
import Foundation

nonisolated enum PrivateFileSecurityError: LocalizedError {
    case operationFailed(path: String, code: Int32)
    case insecureObject(path: String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let path, let code):
            let message = String(cString: strerror(code))
            return "Could not secure private storage at \(path): \(message)"
        case .insecureObject(let path):
            return "Private storage is not owner-only, ACL-free, and structurally safe: \(path)"
        }
    }
}

nonisolated struct PrivateFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

nonisolated struct PrivateStagedFile {
    let directoryURL: URL
    let fileURL: URL
    let handle: FileHandle
    let identity: PrivateFileIdentity
}

/// Shared fail-closed filesystem hardening for local bearer identities,
/// consent grants, audits, image handoffs, and other private runtime state.
nonisolated enum PrivateFileSecurity {
    static let filePermissions: mode_t = 0o600
    static let directoryPermissions: mode_t = 0o700

    static func secureDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try verifyDirectoryMutationBoundary(at: parent)

        if !fileManager.fileExists(atPath: url.path) {
            let security = try makeCreationSecurity(
                permissions: directoryPermissions
            )
            defer { filesec_free(security) }
            let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return EINVAL }
                if mkdirx_np(path, security) == 0 {
                    return 0
                }
                return errno
            }
            if result != 0, result != EEXIST {
                throw PrivateFileSecurityError.operationFailed(path: url.path, code: result)
            }
        }

        let descriptor = try openDescriptor(
            at: url,
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        defer { close(descriptor) }
        try securePrivateDirectoryDescriptor(descriptor, path: url.path)
    }

    static func verifyPrivateDirectory(at url: URL) throws {
        let descriptor = try openDescriptor(
            at: url,
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        defer { close(descriptor) }
        try verifyPrivateDirectoryDescriptor(descriptor, path: url.path)
    }

    static func verifyPrivateFile(at url: URL) throws {
        let descriptor = try openDescriptor(
            at: url,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        defer { close(descriptor) }
        try verifyPrivateFileDescriptor(descriptor, path: url.path)
    }

    static func securePrivateFile(at url: URL) throws {
        let descriptor = try openDescriptor(
            at: url,
            flags: O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        defer { close(descriptor) }
        try securePrivateFileDescriptor(descriptor, path: url.path)
    }

    static func securePrivateFileDescriptor(
        _ descriptor: Int32,
        permissions: mode_t = filePermissions,
        path: String = "<file descriptor>"
    ) throws {
        try preflightDescriptor(
            descriptor,
            kind: .regularFile,
            requiresSingleLink: true,
            path: path
        )
        if isDescriptorPrivate(
            descriptor,
            kind: .regularFile,
            permissions: permissions,
            requiresSingleLink: true,
            path: path
        ) {
            return
        }
        try applyPrivateMetadata(
            to: descriptor,
            permissions: permissions,
            path: path
        )
        try verifyDescriptor(
            descriptor,
            kind: .regularFile,
            permissions: permissions,
            requiresSingleLink: true,
            path: path
        )
    }

    static func verifyPrivateFileDescriptor(
        _ descriptor: Int32,
        permissions: mode_t = filePermissions,
        path: String = "<file descriptor>"
    ) throws {
        try verifyDescriptor(
            descriptor,
            kind: .regularFile,
            permissions: permissions,
            requiresSingleLink: true,
            path: path
        )
    }

    static func securePrivateDirectoryDescriptor(
        _ descriptor: Int32,
        permissions: mode_t = directoryPermissions,
        path: String = "<directory descriptor>"
    ) throws {
        try preflightDescriptor(
            descriptor,
            kind: .directory,
            requiresSingleLink: false,
            path: path
        )
        if isDescriptorPrivate(
            descriptor,
            kind: .directory,
            permissions: permissions,
            requiresSingleLink: false,
            path: path
        ) {
            return
        }
        try applyPrivateMetadata(
            to: descriptor,
            permissions: permissions,
            path: path
        )
        try verifyDescriptor(
            descriptor,
            kind: .directory,
            permissions: permissions,
            requiresSingleLink: false,
            path: path
        )
    }

    static func verifyPrivateDirectoryDescriptor(
        _ descriptor: Int32,
        permissions: mode_t = directoryPermissions,
        path: String = "<directory descriptor>"
    ) throws {
        try verifyDescriptor(
            descriptor,
            kind: .directory,
            permissions: permissions,
            requiresSingleLink: false,
            path: path
        )
    }

    static func createStagedFile(
        adjacentTo destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> PrivateStagedFile {
        let directoryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).jts-private-\(UUID().uuidString)",
            isDirectory: true
        )
        try secureDirectory(at: directoryURL, fileManager: fileManager)

        return try createStagedPayload(
            in: directoryURL,
            fileManager: fileManager
        )
    }

    /// Creates a private staging file on the destination's volume without
    /// requiring permission to create arbitrary siblings beside the target.
    ///
    /// A sandboxed app receives access to the exact file selected through a
    /// save panel, not its parent directory. Foundation's replacement directory
    /// API supplies a temporary location suitable for an atomic same-volume
    /// install while keeping that file-scoped grant narrow.
    static func createReplacementStagedFile(
        for destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> PrivateStagedFile {
        let directoryURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )

        do {
            let descriptor = try openDescriptor(
                at: directoryURL,
                flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            defer { close(descriptor) }
            try securePrivateDirectoryDescriptor(
                descriptor,
                path: directoryURL.path
            )
            return try createStagedPayload(
                in: directoryURL,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    private static func createStagedPayload(
        in directoryURL: URL,
        fileManager: FileManager
    ) throws -> PrivateStagedFile {

        let fileURL = directoryURL.appendingPathComponent("payload")
        let security = try makeCreationSecurity(
            permissions: filePermissions
        )
        defer { filesec_free(security) }
        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return openx_np(
                path,
                O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                security
            )
        }
        guard descriptor >= 0 else {
            let error = currentOperationError(path: fileURL.path)
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }

        do {
            try securePrivateFileDescriptor(descriptor, path: fileURL.path)
            let identity = try identity(of: descriptor, path: fileURL.path)
            return PrivateStagedFile(
                directoryURL: directoryURL,
                fileURL: fileURL,
                handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                identity: identity
            )
        } catch {
            close(descriptor)
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    static func removeStaging(
        _ stagedFile: PrivateStagedFile,
        fileManager: FileManager = .default
    ) {
        try? stagedFile.handle.close()
        try? fileManager.removeItem(at: stagedFile.directoryURL)
    }

    static func identity(at url: URL) throws -> PrivateFileIdentity {
        let descriptor = try openDescriptor(
            at: url,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        defer { close(descriptor) }
        return try identity(of: descriptor, path: url.path)
    }

    static func identity(
        of descriptor: Int32,
        path: String = "<file descriptor>"
    ) throws -> PrivateFileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw currentOperationError(path: path)
        }
        return PrivateFileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    static func renameError(
        from sourceURL: URL,
        to destinationURL: URL,
        flags: UInt32
    ) -> Int32? {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            guard let sourcePath else {
                errno = EINVAL
                return -1
            }
            return destinationURL.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let destinationPath else {
                    errno = EINVAL
                    return -1
                }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
        return result == 0 ? nil : errno
    }

    static func installReplacing(
        _ stagedFile: PrivateStagedFile,
        at destinationURL: URL
    ) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            if let code = renameError(
                from: stagedFile.fileURL,
                to: destinationURL,
                flags: UInt32(RENAME_SWAP)
            ) {
                throw PrivateFileSecurityError.operationFailed(
                    path: destinationURL.path,
                    code: code
                )
            }
        } else if let code = renameError(
            from: stagedFile.fileURL,
            to: destinationURL,
            flags: UInt32(RENAME_EXCL)
        ) {
            throw PrivateFileSecurityError.operationFailed(
                path: destinationURL.path,
                code: code
            )
        }
        try verifyPrivateFile(at: destinationURL)
    }

    static func securePrivateSocket(at url: URL) throws {
        try preflightSocket(at: url)
        if isSocketPrivate(at: url) {
            return
        }
        let security = try makeUpdateSecurity(permissions: filePermissions)
        defer { filesec_free(security) }
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return chmodx_np(path, security)
        }
        if result != 0 {
            let fallbackResult = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errno = EINVAL
                    return -1
                }
                return chmod(path, filePermissions)
            }
            guard fallbackResult == 0 else {
                throw currentOperationError(path: url.path)
            }
        }
        try verifyPrivateSocket(at: url)
    }

    static func verifyPrivateSocket(at url: URL) throws {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return lstat(path, &status)
        }
        guard result == 0 else {
            throw currentOperationError(path: url.path)
        }
        guard status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              status.st_mode & mode_t(0o777) == filePermissions else {
            throw PrivateFileSecurityError.insecureObject(path: url.path)
        }
        try verifyNoExtendedACL(at: url)
    }

    private enum ObjectKind {
        case regularFile
        case directory

        var mode: mode_t {
            switch self {
            case .regularFile: return mode_t(S_IFREG)
            case .directory: return mode_t(S_IFDIR)
            }
        }
    }

    private static func verifyDescriptor(
        _ descriptor: Int32,
        kind: ObjectKind,
        permissions: mode_t,
        requiresSingleLink: Bool,
        path: String
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw currentOperationError(path: path)
        }
        guard status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) == kind.mode,
              status.st_mode & mode_t(0o777) == permissions,
              !requiresSingleLink || status.st_nlink == 1 else {
            throw PrivateFileSecurityError.insecureObject(path: path)
        }
        try verifyNoExtendedACL(descriptor, path: path)
    }

    private static func preflightDescriptor(
        _ descriptor: Int32,
        kind: ObjectKind,
        requiresSingleLink: Bool,
        path: String
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw currentOperationError(path: path)
        }
        guard status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) == kind.mode,
              !requiresSingleLink || status.st_nlink == 1 else {
            throw PrivateFileSecurityError.insecureObject(path: path)
        }
    }

    private static func preflightSocket(at url: URL) throws {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return lstat(path, &status)
        }
        guard result == 0 else {
            throw currentOperationError(path: url.path)
        }
        guard status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw PrivateFileSecurityError.insecureObject(path: url.path)
        }
    }

    /// App Sandbox may deny the ACL-mutating `fchmodx_np`/`chmodx_np` calls
    /// even for an object owned by the current user inside its temporary
    /// container. A POSIX mode-only fallback is safe here because every caller
    /// performs a complete owner, kind, mode, link-count, and extended-ACL
    /// verification before returning. If an ACL actually remains, verification
    /// still fails closed.
    private static func applyPrivateMetadata(
        to descriptor: Int32,
        permissions: mode_t,
        path: String
    ) throws {
        let security = try makeUpdateSecurity(permissions: permissions)
        defer { filesec_free(security) }
        if fchmodx_np(descriptor, security) != 0,
           fchmod(descriptor, permissions) != 0 {
            throw currentOperationError(path: path)
        }
    }

    private static func isDescriptorPrivate(
        _ descriptor: Int32,
        kind: ObjectKind,
        permissions: mode_t,
        requiresSingleLink: Bool,
        path: String
    ) -> Bool {
        do {
            try verifyDescriptor(
                descriptor,
                kind: kind,
                permissions: permissions,
                requiresSingleLink: requiresSingleLink,
                path: path
            )
            return true
        } catch {
            return false
        }
    }

    private static func isSocketPrivate(at url: URL) -> Bool {
        do {
            try verifyPrivateSocket(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func verifyDirectoryMutationBoundary(at url: URL) throws {
        let descriptor = try openDescriptor(
            at: url,
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw currentOperationError(path: url.path)
        }
        let isOwnerBoundary = status.st_uid == geteuid()
            && status.st_mode & mode_t(0o022) == 0
        let isRootStickyBoundary = status.st_uid == 0
            && status.st_mode & mode_t(S_ISVTX) != 0
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              isOwnerBoundary || isRootStickyBoundary else {
            throw PrivateFileSecurityError.insecureObject(path: url.path)
        }
        try verifyNoMutatingExtendedACL(descriptor, path: url.path)
    }

    private static func verifyNoExtendedACL(_ descriptor: Int32, path: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return
            }
            throw currentOperationError(path: path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        if result == 0 || entry != nil {
            throw PrivateFileSecurityError.insecureObject(path: path)
        }
        if errno != EINVAL, errno != ENOENT {
            throw currentOperationError(path: path)
        }
    }

    private static func verifyNoMutatingExtendedACL(
        _ descriptor: Int32,
        path: String
    ) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return
            }
            throw currentOperationError(path: path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, entryID, &entry) == 0 {
            guard let currentEntry = entry else {
                throw PrivateFileSecurityError.insecureObject(path: path)
            }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(currentEntry, &tag) == 0 else {
                throw currentOperationError(path: path)
            }
            if tag == ACL_EXTENDED_ALLOW {
                var permissions: acl_permset_t?
                guard acl_get_permset(currentEntry, &permissions) == 0,
                      let permissions else {
                    throw currentOperationError(path: path)
                }
                let mutatingPermissions: [acl_perm_t] = [
                    ACL_WRITE_DATA,
                    ACL_ADD_FILE,
                    ACL_DELETE,
                    ACL_APPEND_DATA,
                    ACL_DELETE_CHILD,
                    ACL_WRITE_ATTRIBUTES,
                    ACL_WRITE_EXTATTRIBUTES,
                    ACL_WRITE_SECURITY,
                    ACL_CHANGE_OWNER,
                ]
                if mutatingPermissions.contains(where: {
                    acl_get_perm_np(permissions, $0) == 1
                }) {
                    throw PrivateFileSecurityError.insecureObject(path: path)
                }
            }
            entryID = ACL_NEXT_ENTRY.rawValue
            entry = nil
        }
        if errno != EINVAL, errno != ENOENT {
            throw currentOperationError(path: path)
        }
    }

    private static func verifyNoExtendedACL(at url: URL) throws {
        errno = 0
        let acl = url.withUnsafeFileSystemRepresentation { path -> acl_t? in
            guard let path else {
                errno = EINVAL
                return nil
            }
            return acl_get_link_np(path, ACL_TYPE_EXTENDED)
        }
        guard let acl else {
            if errno == ENOENT {
                return
            }
            throw currentOperationError(path: url.path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        if result == 0 || entry != nil {
            throw PrivateFileSecurityError.insecureObject(path: url.path)
        }
        if errno != EINVAL, errno != ENOENT {
            throw currentOperationError(path: url.path)
        }
    }

    private static func makeCreationSecurity(
        permissions: mode_t
    ) throws -> filesec_t {
        guard let security = filesec_init() else {
            throw currentOperationError(path: "<filesec>")
        }
        guard let emptyACL = acl_init(0) else {
            filesec_free(security)
            throw currentOperationError(path: "<filesec>")
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        var permissions = permissions
        let modeResult = withUnsafePointer(to: &permissions) {
            filesec_set_property(security, FILESEC_MODE, $0)
        }
        var aclValue = emptyACL
        let aclResult = withUnsafePointer(to: &aclValue) {
            filesec_set_property(security, FILESEC_ACL, $0)
        }
        guard modeResult == 0, aclResult == 0 else {
            let error = currentOperationError(path: "<filesec>")
            filesec_free(security)
            throw error
        }
        return security
    }

    private static func makeUpdateSecurity(permissions: mode_t) throws -> filesec_t {
        guard let security = filesec_init() else {
            throw currentOperationError(path: "<filesec>")
        }
        var permissions = permissions
        let modeResult = withUnsafePointer(to: &permissions) {
            filesec_set_property(security, FILESEC_MODE, $0)
        }
        let aclResult = filesec_set_property(
            security,
            FILESEC_ACL,
            UnsafeRawPointer(bitPattern: 1)
        )
        guard modeResult == 0, aclResult == 0 else {
            let error = currentOperationError(path: "<filesec>")
            filesec_free(security)
            throw error
        }
        return security
    }

    private static func openDescriptor(at url: URL, flags: Int32) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return open(path, flags)
        }
        guard descriptor >= 0 else {
            throw currentOperationError(path: url.path)
        }
        return descriptor
    }

    private static func currentOperationError(path: String) -> PrivateFileSecurityError {
        PrivateFileSecurityError.operationFailed(
            path: path,
            code: errno == 0 ? EIO : errno
        )
    }
}
