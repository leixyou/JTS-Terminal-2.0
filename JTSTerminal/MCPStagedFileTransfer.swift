import Foundation

nonisolated struct LocalTransferVerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { "LOCAL_TRANSFER_FAILED: \(message)" }
}

/// System sftp must only open container-owned paths. A selected folder's
/// sandbox extension belongs to JTS, and passing a path to sftp is insufficient.
struct MCPStagedFileTransfer {
    static func upload(
        session: RemoteSession, localPath: String, remotePath: String,
        recursive: Bool, resume: Bool
    ) async throws -> CommandResult {
        let connection = SSHSessionLaunchSnapshot(session: session).materializedSession()
        let local = URL(fileURLWithPath: localPath)
        let stage = try await Task.detached(priority: .userInitiated) {
            try LocalTransferFileIO.stageUpload(local, recursive: recursive)
        }.value
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        try Task.checkCancellation()
        return try await RemoteSFTPTransport().upload(
            session: connection, localPath: stage.path, remotePath: remotePath,
            recursive: recursive, resume: resume
        )
    }

    static func download(
        session: RemoteSession, remotePath: String, localPath: String,
        recursive: Bool, resume: Bool, expectedBytes: Int64?
    ) async throws -> CommandResult {
        let connection = SSHSessionLaunchSnapshot(session: session).materializedSession()
        let destination = LocalTransferFileIO.downloadDestination(
            localPath: localPath, remotePath: remotePath, recursive: recursive
        )
        let stage = try await Task.detached(priority: .userInitiated) {
            try LocalTransferFileIO.stageDownload(destination, recursive: recursive, resume: resume)
        }.value
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        try Task.checkCancellation()
        let result = try await RemoteSFTPTransport().download(
            session: connection, remotePath: remotePath, localPath: stage.path,
            recursive: recursive, resume: resume
        )
        guard result.succeeded else { return result }
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try LocalTransferFileIO.verifyDownload(stage, recursive: recursive, expectedBytes: expectedBytes)
            try LocalTransferFileIO.install(stage, at: destination)
        }.value
        return result
    }
}

nonisolated enum LocalTransferFileIO {
    static func downloadDestination(localPath: String, remotePath: String, recursive: Bool) -> URL {
        let local = URL(fileURLWithPath: localPath)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &directory),
           directory.boolValue {
            return local.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent)
        }
        return local
    }

    static func stageUpload(_ source: URL, recursive: Bool) throws -> URL {
        let stage = try makeStage(name: source.lastPathComponent)
        do {
            try validateTree(source, recursive: recursive)
            try FileManager.default.copyItem(at: source, to: stage)
            try validateTree(stage, recursive: recursive)
            return stage
        } catch {
            try? FileManager.default.removeItem(at: stage.deletingLastPathComponent())
            throw LocalTransferAccessRequired.explaining(error, path: source.path)
        }
    }

    static func stageDownload(_ destination: URL, recursive: Bool, resume: Bool) throws -> URL {
        let stage = try makeStage(name: destination.lastPathComponent)
        do {
            let exists = FileManager.default.fileExists(atPath: destination.path)
            if recursive, exists {
                guard try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw LocalTransferVerificationError(message: "The recursive download destination must be a folder.")
                }
            } else if resume, exists {
                try validateTree(destination, recursive: false)
                try FileManager.default.copyItem(at: destination, to: stage)
            }
            // Prepare same-volume staging without creating/truncating the user's target.
            let probe = try PrivateFileSecurity.createReplacementStagedFile(for: destination)
            defer { PrivateFileSecurity.removeStaging(probe) }
            let parent = destination.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path),
                  !exists || FileManager.default.isWritableFile(atPath: destination.path) else {
                throw LocalTransferAccessRequired(path: destination.path)
            }
            return stage
        } catch {
            try? FileManager.default.removeItem(at: stage.deletingLastPathComponent())
            throw LocalTransferAccessRequired.explaining(error, path: destination.path)
        }
    }

    static func verifyDownload(_ url: URL, recursive: Bool, expectedBytes: Int64?) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalTransferVerificationError(message: "SFTP exited without producing the local download.")
        }
        try validateTree(url, recursive: recursive)
        if recursive, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
            throw LocalTransferVerificationError(message: "SFTP did not produce the requested directory.")
        }
        if !recursive, let expectedBytes {
            let size = try byteCount(at: url)
            guard size == expectedBytes else {
                throw LocalTransferVerificationError(
                    message: "Downloaded \(size) bytes; expected \(expectedBytes). The destination was not replaced."
                )
            }
        }
    }

    static func byteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let count = values.fileSize else {
            throw LocalTransferVerificationError(message: "Expected a regular local file at \(url.path).")
        }
        return Int64(count)
    }

    static func install(_ source: URL, at destination: URL) throws {
        do {
            if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try install(child, at: destination.appendingPathComponent(child.lastPathComponent))
                }
                return
            }
            let staged = try PrivateFileSecurity.createReplacementStagedFile(for: destination)
            defer { PrivateFileSecurity.removeStaging(staged) }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try staged.handle.write(contentsOf: chunk)
                copied += Int64(chunk.count)
            }
            guard copied == (try byteCount(at: source)) else {
                throw LocalTransferVerificationError(message: "The local file changed while saving the download.")
            }
            try staged.handle.synchronize()
            try PrivateFileSecurity.installReplacing(staged, at: destination)
        } catch {
            throw LocalTransferAccessRequired.explaining(error, path: destination.path)
        }
    }

    private static func makeStage(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-mcp-transfer-\(UUID().uuidString)", isDirectory: true)
        try PrivateFileSecurity.secureDirectory(at: directory)
        return directory.appendingPathComponent(name.isEmpty ? "payload" : name)
    }

    private static func validateTree(_ url: URL, recursive: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else {
            throw LocalTransferVerificationError(message: "Select the original file or folder instead of a symbolic link: \(url.path)")
        }
        if values.isDirectory == true, recursive {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try validateTree(child, recursive: true)
            }
        } else if values.isRegularFile != true {
            throw LocalTransferVerificationError(message: "Expected a regular file\(recursive ? " or folder" : ""): \(url.path)")
        }
    }
}
