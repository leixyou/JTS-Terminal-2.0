//
//  RemoteSFTPTransport.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/30.
//

import Foundation

struct RemoteSFTPTransport {
    private struct ConnectionSnapshot: Sendable {
        let credentialAccount: String
        let keyArguments: [String]
        let savedPasswordArguments: [String]
        let allowsSavedPasswordAutofill: Bool

        init(session: RemoteSession) {
            let destination = SSHSessionLaunchSnapshot(session: session)
            let frozenSession = destination.materializedSession()
            credentialAccount = destination.credentialAccount
            keyArguments = SSHCommandBuilder.sftpBatchArguments(for: frozenSession)
            savedPasswordArguments = SSHCommandBuilder.sftpBatchArguments(
                for: frozenSession,
                batchMode: false,
                passwordAuthentication: true
            )
            allowsSavedPasswordAutofill = destination.allowsSavedPasswordAutofill
        }
    }

    private let credentialReader: RemoteCredentialReader
    private let commandExecutor: RemoteCommandExecutor

    init(
        credentialReader: @escaping RemoteCredentialReader = { account in
            try await Task.detached(priority: .userInitiated) {
                try SSHCredentialVaultAccess.read(account: account)
            }.value
        },
        commandExecutor: @escaping RemoteCommandExecutor = { invocation in
            try await ProcessExecutor().run(
                executable: invocation.executable,
                arguments: invocation.arguments,
                environment: invocation.environment,
                standardInput: invocation.standardInput,
                timeoutSeconds: invocation.timeoutSeconds
            )
        }
    ) {
        self.credentialReader = credentialReader
        self.commandExecutor = commandExecutor
    }

    nonisolated static func resultByRecognizingSFTPFailureOutput(_ result: CommandResult) -> CommandResult {
        guard result.succeeded else { return result }

        let failureLine = result.displayText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("sftp>") {
                    value.removeFirst("sftp>".count)
                    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return value
            }
            .first(where: isSFTPFailureLine(_:))

        guard let failureLine else { return result }

        let message = [result.standardError, failureLine]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return CommandResult(
            command: result.command,
            exitCode: 1,
            standardOutput: result.standardOutput,
            standardError: message.isEmpty ? result.standardError : message
        )
    }

    nonisolated static func shouldFallbackFromResumeUploadToFreshUpload(_ result: CommandResult) -> Bool {
        let display = result.displayText.lowercased()
        return !result.succeeded &&
            display.contains("stat remote: no such file or directory")
    }

    nonisolated private static func isSFTPFailureLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.contains("permission denied") ||
            lowercased.contains("operation not permitted") ||
            lowercased.contains("read-only file system") ||
            lowercased.contains("no space left on device") ||
            lowercased.contains("disk quota exceeded") ||
            lowercased.contains("input/output error") ||
            lowercased.contains("no such file or directory") ||
            lowercased.contains("not a regular file") ||
            lowercased.contains("connection closed") ||
            lowercased.hasPrefix("couldn't ") ||
            lowercased.hasPrefix("cannot ") ||
            lowercased.hasPrefix("stat ") ||
            lowercased.hasPrefix("file ") && lowercased.contains(" not found") ||
            lowercased == "failure" ||
            lowercased.hasSuffix(": failure")
    }

    static func failureMessage(for result: CommandResult) -> String {
        let display = result.displayText
        let lowercased = display.lowercased()

        if lowercased.contains("permission denied") {
            return "SFTP authentication failed. Open Server Properties from the sidebar, save/check the SSH password or identity file, then refresh files."
        }

        if lowercased.contains("connection closed") {
            return "SFTP connection closed before the file list loaded. This usually means password/key authentication failed or the server SFTP subsystem is unavailable. Check Server Properties, then refresh."
        }

        return display
    }

    static func shouldAttemptSSHListingFallback(result: CommandResult, parsedEntries: [RemoteFileEntry]) -> Bool {
        if result.succeeded {
            return parsedEntries.isEmpty
        }

        let lowercased = result.displayText.lowercased()
        return lowercased.contains("connection closed")
            || lowercased.contains("subsystem request failed")
            || lowercased.contains("couldn't read packet")
            || lowercased.contains("received message too long")
    }

    func listDirectory(session: RemoteSession, path: String) async throws -> CommandResult {
        let connection = ConnectionSnapshot(session: session)
        return try await runBatch(
            connection: connection,
            script: SSHCommandBuilder.sftpListScript(path: path)
        )
    }

    func makeDirectory(session: RemoteSession, path: String) async throws -> CommandResult {
        let connection = ConnectionSnapshot(session: session)
        return try await runBatch(
            connection: connection,
            script: SSHCommandBuilder.sftpMkdirScript(path: path)
        )
    }

    func removeFile(session: RemoteSession, path: String) async throws -> CommandResult {
        let connection = ConnectionSnapshot(session: session)
        return try await runBatch(
            connection: connection,
            script: SSHCommandBuilder.sftpRemoveFileScript(path: path)
        )
    }

    func removeDirectory(session: RemoteSession, path: String) async throws -> CommandResult {
        let connection = ConnectionSnapshot(session: session)
        return try await runBatch(
            connection: connection,
            script: SSHCommandBuilder.sftpRemoveDirectoryScript(path: path)
        )
    }

    func rename(session: RemoteSession, oldPath: String, newPath: String) async throws -> CommandResult {
        let connection = ConnectionSnapshot(session: session)
        return try await runBatch(
            connection: connection,
            script: SSHCommandBuilder.sftpRenameScript(oldPath: oldPath, newPath: newPath)
        )
    }

    func upload(
        session: RemoteSession,
        localPath: String,
        remotePath: String,
        recursive: Bool = false,
        resume: Bool = false
    ) async throws -> CommandResult {
        // Reuse one immutable destination for both resume and fresh-upload
        // attempts. A profile edit after the first attempt must not redirect
        // the fallback half of the same user operation.
        let connection = ConnectionSnapshot(session: session)
        let result = try await runBatch(
            connection: connection,
            script: SSHCommandBuilder.sftpUploadScript(
                localPath: localPath,
                remotePath: remotePath,
                recursive: recursive,
                resume: resume
            )
        )

        guard resume,
              !recursive,
              Self.shouldFallbackFromResumeUploadToFreshUpload(result)
        else {
            return result
        }

        return try await runBatch(
            connection: connection,
            script: SSHCommandBuilder.sftpUploadScript(
                localPath: localPath,
                remotePath: remotePath,
                recursive: false,
                resume: false
            )
        )
    }

    func download(
        session: RemoteSession,
        remotePath: String,
        localPath: String,
        recursive: Bool = false,
        resume: Bool = false
    ) async throws -> CommandResult {
        let connection = ConnectionSnapshot(session: session)
        return try await runBatch(
            connection: connection,
            script: SSHCommandBuilder.sftpDownloadScript(
                remotePath: remotePath,
                localPath: localPath,
                recursive: recursive,
                resume: resume
            )
        )
    }

    private func runBatch(
        connection: ConnectionSnapshot,
        script: String
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        let secret = try await credentialReader(connection.credentialAccount)
        try Task.checkCancellation()

        if let secret {
            guard connection.allowsSavedPasswordAutofill else {
                throw RemoteCredentialRoutingError.savedPasswordCannotUseJumpHost
            }
            let askpassContext = try SSHCredentialAskpass.launchContext(
                account: connection.credentialAccount,
                secret: secret
            )
            defer { askpassContext.cleanup() }
            let result = try await commandExecutor(RemoteCommandInvocation(
                executable: "/usr/bin/sftp",
                arguments: connection.savedPasswordArguments,
                environment: askpassContext.environment,
                standardInput: script,
                timeoutSeconds: nil
            ))
            return Self.resultByRecognizingSFTPFailureOutput(result)
        }

        let result = try await commandExecutor(RemoteCommandInvocation(
            executable: "/usr/bin/sftp",
            arguments: connection.keyArguments,
            environment: nil,
            standardInput: script,
            timeoutSeconds: nil
        ))
        return Self.resultByRecognizingSFTPFailureOutput(result)
    }
}

enum RemoteSFTPFileListParser {
    static func parse(_ output: String) -> [RemoteFileEntry] {
        RemoteFileListParser.parse(clean(output))
    }

    static func clean(_ output: String) -> String {
        output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var value = String(line)
                if value.hasPrefix("sftp>") {
                    value.removeFirst("sftp>".count)
                }
                return value.trimmingCharacters(in: .whitespaces)
            }
            .filter { line in
                guard !line.isEmpty,
                      !line.hasPrefix("Connected to "),
                      !line.hasPrefix("Changing to: "),
                      !line.hasPrefix("Fetching "),
                      !line.hasPrefix("Uploading "),
                      !line.hasPrefix("Enter passphrase"),
                      !line.localizedCaseInsensitiveContains("password:") else {
                    return false
                }

                return !line.hasPrefix("ls ")
            }
            .joined(separator: "\n")
    }
}
