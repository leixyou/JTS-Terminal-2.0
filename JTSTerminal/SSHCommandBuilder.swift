//
//  SSHCommandBuilder.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import Darwin
import Foundation

struct SSHCommandBuilder {
    static let applicationSupportFolderName = "JTS Terminal"

    static func sshArguments(
        for session: RemoteSession,
        remoteCommand: String? = nil,
        batchMode: Bool = true,
        extraOptions: [String] = [],
        includeSessionIdentity: Bool = true,
        includeJumpHost: Bool = true,
        ignoreUserConfiguration: Bool = false
    ) -> [String] {
        var arguments: [String] = []
        if ignoreUserConfiguration {
            // A saved destination password must only ever be offered to the
            // destination recorded in this profile. In particular, do not let
            // a Host/Match rule in ~/.ssh/config redirect it with HostName,
            // ProxyJump, or ProxyCommand.
            arguments += ["-F", "/dev/null"]
        }
        arguments += [
            "-p", String(session.port),
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]
        arguments += hostKeyVerificationOptions()

        arguments += ["-o", batchMode ? "BatchMode=yes" : "BatchMode=no"]

        if session.enableX11Forwarding {
            arguments.append("-X")
            arguments += ["-o", "ForwardX11=yes"]
            if let xauthLocation = X11Support.xauthLocation() {
                arguments += ["-o", "XAuthLocation=\(xauthLocation)"]
            }
        }

        if includeJumpHost {
            let jumpHost = session.jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !jumpHost.isEmpty {
                arguments += ["-J", jumpHost]
            }
        }

        arguments += extraOptions

        if includeSessionIdentity {
            let identityFile = session.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identityFile.isEmpty {
                SSHIdentityFileAccess.activateIfNeeded(for: identityFile)
                arguments += ["-i", expandedHomePath(identityFile)]
            }
        }

        arguments += ["--", sshDestination(for: session)]

        if let remoteCommand, !remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(remoteCommand)
        }

        return arguments
    }

    static func passwordSSHArguments(for session: RemoteSession, remoteCommand: String) -> [String] {
        sshArguments(
            for: session,
            remoteCommand: remoteCommand,
            batchMode: false,
            extraOptions: savedPasswordAuthenticationOptions,
            includeSessionIdentity: false,
            includeJumpHost: false,
            ignoreUserConfiguration: true
        )
    }

    /// Interactive terminal panes always require a server-side PTY. Force the
    /// request explicitly so OpenSSH treats its redundant child-side terminal
    /// mode transition as quiet when App Sandbox denies `TIOCSETAW`; JTS has
    /// already established and verified the equivalent raw local PTY mode.
    static func interactiveSSHArguments(for session: RemoteSession) -> [String] {
        sshArguments(
            for: session,
            batchMode: false,
            extraOptions: interactiveTTYOptions
        )
    }

    /// Interactive PTY invocation for a profile whose encrypted-vault password was
    /// loaded successfully. Command-line options take precedence over user SSH config,
    /// so a local `BatchMode yes` or disabled password method cannot silently discard
    /// the saved credential. Password methods run before public-key fallback to avoid
    /// consuming the one automatic response at a private-key passphrase prompt.
    static func savedPasswordInteractiveSSHArguments(for session: RemoteSession) -> [String] {
        sshArguments(
            for: session,
            batchMode: false,
            extraOptions: interactiveTTYOptions + savedPasswordAuthenticationOptions,
            includeSessionIdentity: false,
            includeJumpHost: false,
            ignoreUserConfiguration: true
        )
    }

    #if JTS_UI_TEST_SUPPORT
    /// Builds the intentionally isolated SSH invocation used by the formal App Review
    /// credential smoke test. The test must prove the supplied password (or keyboard-
    /// interactive response) works, so it cannot inherit an agent, identity file,
    /// public-key authentication, jump host, or X11 setting from the saved profile or
    /// the user's SSH configuration.
    static func appReviewPasswordSmokeArguments(
        for session: RemoteSession,
        knownHostsFilePath: String
    ) -> [String] {
        var arguments = [
            "-F", "/dev/null",
            "-p", String(session.port),
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", userKnownHostsFileOption(knownHostsFilePath),
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no",
        ]
        arguments += [
            "-o", "BatchMode=no",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "IdentityFile=none",
            "-o", "CertificateFile=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=yes",
            "-o", "KbdInteractiveAuthentication=yes",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ProxyJump=none",
            "-o", "ProxyCommand=none",
            "-o", "ForwardX11=no",
            "-o", "ForwardX11Trusted=no",
            "--",
            sshDestination(for: session),
            "printf '%s\\n' \(shellQuote(UITestSSHSessionEnvironment.formalSmokeMarker))",
        ]

        return arguments
    }
    #endif

    static func tunnelArguments(for session: RemoteSession, tunnel: SSHTunnelConfiguration) -> [String] {
        tunnelArguments(
            for: session,
            tunnel: tunnel,
            batchMode: true,
            passwordAuthentication: false
        )
    }

    static func tunnelArguments(
        for session: RemoteSession,
        tunnel: SSHTunnelConfiguration,
        batchMode: Bool,
        passwordAuthentication: Bool
    ) -> [String] {
        var forwarding: [String]

        switch tunnel.kind {
        case .local:
            forwarding = ["-L", "\(tunnel.bindAddress):\(tunnel.localPort):\(tunnel.destinationHost):\(tunnel.destinationPort)"]
        case .remote:
            forwarding = ["-R", "\(tunnel.bindAddress):\(tunnel.localPort):\(tunnel.destinationHost):\(tunnel.destinationPort)"]
        case .dynamic:
            forwarding = ["-D", "\(tunnel.bindAddress):\(tunnel.localPort)"]
        }

        var extraOptions = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
        ] + forwarding
        if passwordAuthentication {
            extraOptions += savedPasswordAuthenticationOptions
        }

        return sshArguments(
            for: session,
            batchMode: batchMode,
            extraOptions: extraOptions,
            includeSessionIdentity: !passwordAuthentication,
            includeJumpHost: !passwordAuthentication,
            ignoreUserConfiguration: passwordAuthentication
        )
    }

    static func scpDownloadArguments(
        for session: RemoteSession,
        remotePath: String,
        localPath: String
    ) -> [String] {
        scpDownloadArguments(
            for: session,
            remotePath: remotePath,
            localPath: localPath,
            batchMode: true,
            passwordAuthentication: false
        )
    }

    static func scpDownloadArguments(
        for session: RemoteSession,
        remotePath: String,
        localPath: String,
        batchMode: Bool,
        passwordAuthentication: Bool
    ) -> [String] {
        scpDownloadArguments(
            for: session,
            remotePath: remotePath,
            localPath: localPath,
            batchMode: batchMode,
            passwordAuthentication: passwordAuthentication,
            recursive: false
        )
    }

    static func scpDownloadArguments(
        for session: RemoteSession,
        remotePath: String,
        localPath: String,
        batchMode: Bool,
        passwordAuthentication: Bool,
        recursive: Bool
    ) -> [String] {
        var arguments = commonSCPArguments(
            for: session,
            batchMode: batchMode,
            passwordAuthentication: passwordAuthentication,
            recursive: recursive
        )
        arguments.append("--")
        arguments.append("\(sshDestination(for: session)):\(shellQuote(remotePath))")
        arguments.append(expandedHomePath(localPath))
        return arguments
    }

    static func scpUploadArguments(
        for session: RemoteSession,
        localPath: String,
        remotePath: String
    ) -> [String] {
        scpUploadArguments(
            for: session,
            localPath: localPath,
            remotePath: remotePath,
            batchMode: true,
            passwordAuthentication: false
        )
    }

    static func scpUploadArguments(
        for session: RemoteSession,
        localPath: String,
        remotePath: String,
        batchMode: Bool,
        passwordAuthentication: Bool
    ) -> [String] {
        scpUploadArguments(
            for: session,
            localPath: localPath,
            remotePath: remotePath,
            batchMode: batchMode,
            passwordAuthentication: passwordAuthentication,
            recursive: false
        )
    }

    static func scpUploadArguments(
        for session: RemoteSession,
        localPath: String,
        remotePath: String,
        batchMode: Bool,
        passwordAuthentication: Bool,
        recursive: Bool
    ) -> [String] {
        var arguments = commonSCPArguments(
            for: session,
            batchMode: batchMode,
            passwordAuthentication: passwordAuthentication,
            recursive: recursive
        )
        arguments.append("--")
        arguments.append(expandedHomePath(localPath))
        arguments.append("\(sshDestination(for: session)):\(shellQuote(remotePath))")
        return arguments
    }

    static func sftpBatchArguments(
        for session: RemoteSession,
        batchMode: Bool = true,
        passwordAuthentication: Bool = false,
        quiet: Bool = true
    ) -> [String] {
        var arguments: [String] = []

        if quiet {
            arguments.append("-q")
        }

        if passwordAuthentication {
            arguments += ["-F", "/dev/null"]
        }

        if !passwordAuthentication {
            arguments += ["-b", "-"]
        }

        arguments += [
            "-P", String(session.port),
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]
        arguments += hostKeyVerificationOptions()

        if batchMode, !passwordAuthentication {
            arguments += ["-o", "BatchMode=yes"]
        }

        if passwordAuthentication {
            arguments += ["-o", "BatchMode=no"]
            arguments += savedPasswordAuthenticationOptions
        }

        if !passwordAuthentication {
            let identityFile = session.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identityFile.isEmpty {
                SSHIdentityFileAccess.activateIfNeeded(for: identityFile)
                arguments += ["-i", expandedHomePath(identityFile)]
            }

            let jumpHost = session.jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !jumpHost.isEmpty {
                arguments += ["-J", jumpHost]
            }
        }

        arguments += ["--", sshDestination(for: session)]
        return arguments
    }

    static func sftpListScript(path: String) -> String {
        sftpBatchScript(commands: ["ls -la \(sftpRemotePathArgument(path))"])
    }

    static func sftpMkdirScript(path: String) -> String {
        sftpBatchScript(commands: ["mkdir \(sftpRemotePathArgument(path))"])
    }

    static func sftpRemoveFileScript(path: String) -> String {
        sftpBatchScript(commands: ["rm \(sftpRemotePathArgument(path))"])
    }

    static func sftpRemoveDirectoryScript(path: String) -> String {
        sftpBatchScript(commands: ["rmdir \(sftpRemotePathArgument(path))"])
    }

    static func sftpRenameScript(oldPath: String, newPath: String) -> String {
        sftpBatchScript(commands: ["rename \(sftpRemotePathArgument(oldPath)) \(sftpRemotePathArgument(newPath))"])
    }

    static func sftpUploadScript(
        localPath: String,
        remotePath: String,
        recursive: Bool = false,
        resume: Bool = false
    ) -> String {
        let flag = recursive ? "-R " : ""
        let command = resume && !recursive ? "reput" : "put"
        return sftpBatchScript(commands: ["\(command) \(flag)\(sftpQuotePath(expandedHomePath(localPath))) \(sftpRemotePathArgument(remotePath))"])
    }

    static func sftpUploadScript(localPath: String, remotePath: String, recursive: Bool) -> String {
        sftpUploadScript(
            localPath: localPath,
            remotePath: remotePath,
            recursive: recursive,
            resume: false
        )
    }

    static func sftpDownloadScript(
        remotePath: String,
        localPath: String,
        recursive: Bool = false,
        resume: Bool = false
    ) -> String {
        let flag = recursive ? "-R " : ""
        let command = resume && !recursive ? "reget" : "get"
        return sftpBatchScript(commands: ["\(command) \(flag)\(sftpRemotePathArgument(remotePath)) \(sftpQuotePath(expandedHomePath(localPath)))"])
    }

    static func sftpDownloadScript(remotePath: String, localPath: String, recursive: Bool) -> String {
        sftpDownloadScript(
            remotePath: remotePath,
            localPath: localPath,
            recursive: recursive,
            resume: false
        )
    }

    static func sftpBatchScript(commands: [String]) -> String {
        (commands.map { "@\($0)" } + ["@quit"]).joined(separator: "\n") + "\n"
    }

    static func terminalSSHCommand(for session: RemoteSession) -> String {
        interactiveSSHArguments(for: session)
            .map { shellQuote($0) }
            .joined(separator: " ")
            .prepend("/usr/bin/ssh ")
    }

    static func listDirectoryCommand(path: String) -> String {
        "LC_ALL=C ls -la \(shellQuote(path.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "~"))"
    }

    static func structuredDirectoryListingCommand(path: String) -> String {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "~"

        return """
        /usr/bin/env python3 - \(shellQuote(targetPath)) <<'PY'
        import grp
        import json
        import os
        import pwd
        import stat
        import sys
        import time

        path = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~")
        entries = []

        with os.scandir(path) as iterator:
            for entry in iterator:
                item_stat = entry.stat(follow_symlinks=False)
                mode = item_stat.st_mode
                if stat.S_ISDIR(mode):
                    kind = "directory"
                elif stat.S_ISLNK(mode):
                    kind = "symlink"
                elif stat.S_ISREG(mode):
                    kind = "file"
                else:
                    kind = "other"

                try:
                    owner = pwd.getpwuid(item_stat.st_uid).pw_name
                except KeyError:
                    owner = str(item_stat.st_uid)

                try:
                    group = grp.getgrgid(item_stat.st_gid).gr_name
                except KeyError:
                    group = str(item_stat.st_gid)

                link_target = None
                if kind == "symlink":
                    try:
                        link_target = os.readlink(entry.path)
                    except OSError:
                        link_target = None

                entries.append({
                    "name": entry.name,
                    "kind": kind,
                    "permissions": stat.filemode(mode),
                    "owner": owner,
                    "group": group,
                    "size": item_stat.st_size,
                    "modified": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(item_stat.st_mtime)),
                    "linkTarget": link_target,
                })

        print(json.dumps(entries, ensure_ascii=False))
        PY
        """
    }

    static func readFileCommand(
        path: String,
        offset: Int,
        limitBytes: Int,
        encoding: String
    ) -> String {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "~"
        let safeOffset = max(offset, 0)
        let safeLimit = max(limitBytes, 1)
        let safeEncoding = encoding.lowercased() == "base64" ? "base64" : "utf8"

        let script = """
        import base64, json, os, sys
        path = os.path.expanduser(sys.argv[1])
        offset = max(int(sys.argv[2]), 0)
        limit = max(int(sys.argv[3]), 1)
        requested_encoding = sys.argv[4]
        with open(path, "rb") as handle:
            handle.seek(offset)
            data = handle.read(limit + 1)
        truncated = len(data) > limit
        data = data[:limit]
        encoding = requested_encoding
        if requested_encoding == "base64":
            content = base64.b64encode(data).decode("ascii")
        else:
            try:
                content = data.decode("utf-8")
                encoding = "utf8"
            except UnicodeDecodeError:
                content = base64.b64encode(data).decode("ascii")
                encoding = "base64"
        print(json.dumps({
            "path": path,
            "offset": offset,
            "bytes": len(data),
            "encoding": encoding,
            "content": content,
            "truncated": truncated
        }, ensure_ascii=False))
        """

        return pythonCommand(
            script,
            arguments: [targetPath, String(safeOffset), String(safeLimit), safeEncoding]
        )
    }

    static func writeFileCommand(
        path: String,
        createParents: Bool,
        mode: String?
    ) -> String {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "~"
        let safeMode = mode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let script = """
        import base64, json, os, sys, tempfile
        path = os.path.expanduser(sys.argv[1])
        create_parents = sys.argv[2] == "true"
        mode = sys.argv[3]
        payload = sys.stdin.read()
        data = base64.b64decode(payload.encode("ascii"), validate=True)
        directory = os.path.dirname(path) or "."
        if create_parents:
            os.makedirs(directory, exist_ok=True)
        fd, temp_path = tempfile.mkstemp(prefix=".jts-terminal-", dir=directory)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
            if mode:
                os.chmod(temp_path, int(mode, 8))
            os.replace(temp_path, path)
        except BaseException:
            try:
                os.unlink(temp_path)
            except OSError:
                pass
            raise
        print(json.dumps({
            "path": path,
            "bytes": len(data),
            "createdParents": create_parents,
            "mode": mode or None
        }, ensure_ascii=False))
        """

        return pythonCommand(
            script,
            arguments: [targetPath, createParents ? "true" : "false", safeMode]
        )
    }

    static func statCommand(path: String) -> String {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "~"
        let script = """
        import grp, json, os, pwd, stat, sys, time
        path = os.path.expanduser(sys.argv[1])
        item_stat = os.lstat(path)
        mode = item_stat.st_mode
        if stat.S_ISDIR(mode):
            kind = "directory"
        elif stat.S_ISLNK(mode):
            kind = "symlink"
        elif stat.S_ISREG(mode):
            kind = "file"
        else:
            kind = "other"
        try:
            owner = pwd.getpwuid(item_stat.st_uid).pw_name
        except KeyError:
            owner = str(item_stat.st_uid)
        try:
            group = grp.getgrgid(item_stat.st_gid).gr_name
        except KeyError:
            group = str(item_stat.st_gid)
        link_target = None
        if kind == "symlink":
            try:
                link_target = os.readlink(path)
            except OSError:
                link_target = None
        print(json.dumps({
            "path": path,
            "kind": kind,
            "size": item_stat.st_size,
            "mtime": int(item_stat.st_mtime),
            "modified": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(item_stat.st_mtime)),
            "owner": owner,
            "group": group,
            "permissions": stat.filemode(mode),
            "mode": oct(stat.S_IMODE(mode)),
            "linkTarget": link_target
        }, ensure_ascii=False))
        """

        return pythonCommand(script, arguments: [targetPath])
    }

    static func renameRemoteEntryCommand(directory: String, oldName: String, newName: String) -> String {
        let oldPath = remotePath(directory: directory, name: oldName)
        let newPath = remotePath(directory: directory, name: newName)
        return "mv -- \(shellQuote(oldPath)) \(shellQuote(newPath))"
    }

    static func remotePath(directory: String, name: String) -> String {
        let base = directory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "~"
        return base.hasSuffix("/") ? "\(base)\(name)" : "\(base)/\(name)"
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func sftpQuotePath(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return "'\(sanitized.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func sftpRemotePathArgument(_ value: String) -> String {
        sftpQuotePath(normalizedSFTPRemotePath(value))
    }

    static func normalizedSFTPRemotePath(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        guard !trimmed.isEmpty else { return "." }
        if trimmed == "~" { return "." }
        if trimmed.hasPrefix("~/") {
            let relative = String(trimmed.dropFirst(2))
            return relative.isEmpty ? "." : relative
        }
        return trimmed
    }

    static func expandedHomePath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func managedKnownHostsFilePath(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> String {
        let knownHostsURL = managedKnownHostsFileURL(
            applicationSupportDirectory: applicationSupportDirectory,
            fileManager: fileManager
        )
        do {
            try prepareManagedKnownHostsFile(
                at: knownHostsURL,
                fileManager: fileManager
            )
            return knownHostsURL.path
        } catch {
            return "/dev/null"
        }
    }

    private static func pythonCommand(_ script: String, arguments: [String]) -> String {
        (["/usr/bin/env", "python3", "-c", script] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
    }

    static func userKnownHostsFileOption(_ path: String) -> String {
        "UserKnownHostsFile=\(openSSHConfigQuotedValue(path))"
    }

    static func openSSHConfigQuotedValue(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            default:
                escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    static func hostKeyVerificationOptions(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        let knownHostsURL = managedKnownHostsFileURL(
            applicationSupportDirectory: applicationSupportDirectory,
            fileManager: fileManager
        )
        do {
            try prepareManagedKnownHostsFile(
                at: knownHostsURL,
                fileManager: fileManager
            )
            return [
                "-o", userKnownHostsFileOption(knownHostsURL.path),
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "StrictHostKeyChecking=accept-new"
            ]
        } catch {
            // Never downgrade to trust-on-first-use without a durable,
            // owner-only host-key store. `/dev/null` avoids touching an
            // attacker-controlled path while strict checking fails closed.
            return [
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "StrictHostKeyChecking=yes"
            ]
        }
    }

    private static var savedPasswordAuthenticationOptions: [String] {
        [
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "IdentityFile=none",
            "-o", "CertificateFile=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=yes",
            "-o", "KbdInteractiveAuthentication=yes",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ProxyJump=none",
            "-o", "ProxyCommand=none",
        ]
    }

    private static var interactiveTTYOptions: [String] {
        ["-o", "RequestTTY=force"]
    }

    private static func sshDestination(for session: RemoteSession) -> String {
        let identity = SSHConnectionIdentity(username: session.username, host: session.host)
        guard identity.isValidForSSHCommand else {
            return "invalid@invalid.invalid"
        }
        return identity.destination
    }

    private static func managedKnownHostsFileURL(
        applicationSupportDirectory: URL?,
        fileManager: FileManager
    ) -> URL {
        let supportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return supportDirectory
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("SSH", isDirectory: true)
            .appendingPathComponent("known_hosts", isDirectory: false)
    }

    private static func prepareManagedKnownHostsFile(
        at knownHostsURL: URL,
        fileManager: FileManager
    ) throws {
        let directoryURL = knownHostsURL.deletingLastPathComponent()
        try PrivateFileSecurity.secureDirectory(
            at: directoryURL,
            fileManager: fileManager
        )

        if !fileManager.fileExists(atPath: knownHostsURL.path) {
            let stagedFile = try PrivateFileSecurity.createStagedFile(
                adjacentTo: knownHostsURL,
                fileManager: fileManager
            )
            defer {
                PrivateFileSecurity.removeStaging(
                    stagedFile,
                    fileManager: fileManager
                )
            }
            try stagedFile.handle.close()
            if let renameError = PrivateFileSecurity.renameError(
                from: stagedFile.fileURL,
                to: knownHostsURL,
                flags: UInt32(RENAME_EXCL)
            ) {
                guard renameError == EEXIST else {
                    throw PrivateFileSecurityError.operationFailed(
                        path: knownHostsURL.path,
                        code: renameError
                    )
                }
                // A concurrent creator may have won the exclusive rename.
                // Accept it only if the descriptor-based verification below
                // proves that it is the same safe object shape we require.
                try PrivateFileSecurity.securePrivateFile(at: knownHostsURL)
            }
        }

        migrateLegacyUnquotedKnownHostsIfNeeded(
            to: knownHostsURL,
            fileManager: fileManager
        )

        // Descriptor-based hardening uses O_NOFOLLOW, rejects non-regular and
        // multiply-linked objects, removes extended ACLs when permitted, and
        // verifies the final 0600/0700 owner-only state before returning.
        try PrivateFileSecurity.securePrivateFile(at: knownHostsURL)
        try PrivateFileSecurity.verifyPrivateDirectory(at: directoryURL)
        try PrivateFileSecurity.verifyPrivateFile(at: knownHostsURL)
    }

    private static func migrateLegacyUnquotedKnownHostsIfNeeded(
        to knownHostsURL: URL,
        fileManager: FileManager
    ) {
        guard
            let legacyURL = legacyUnquotedKnownHostsFileURL(for: knownHostsURL),
            fileManager.fileExists(atPath: legacyURL.path),
            ((try? fileManager.attributesOfItem(atPath: knownHostsURL.path)[.size] as? NSNumber)?.uint64Value ?? 0) == 0
        else {
            return
        }

        do {
            try PrivateFileSecurity.securePrivateFile(at: legacyURL)
            let legacyData = try Data(contentsOf: legacyURL)
            guard !legacyData.isEmpty else { return }

            let handle = try FileHandle(forWritingTo: knownHostsURL)
            defer {
                try? handle.close()
            }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: legacyData)
        } catch {
            return
        }
    }

    private static func legacyUnquotedKnownHostsFileURL(for knownHostsURL: URL) -> URL? {
        let path = knownHostsURL.path
        guard let firstWhitespace = path.firstIndex(where: { $0.isWhitespace }) else {
            return nil
        }
        let legacyPath = String(path[..<firstWhitespace])
        guard !legacyPath.isEmpty, legacyPath != path else {
            return nil
        }
        return URL(fileURLWithPath: legacyPath, isDirectory: false)
    }

    private static func commonSCPArguments(
        for session: RemoteSession,
        batchMode: Bool,
        passwordAuthentication: Bool,
        recursive: Bool
    ) -> [String] {
        var arguments: [String] = []
        if passwordAuthentication {
            arguments += ["-F", "/dev/null"]
        }
        arguments += [
            "-P", String(session.port),
            "-o", "ConnectTimeout=12"
        ]
        arguments += hostKeyVerificationOptions()

        if recursive {
            arguments.append("-r")
        }

        if batchMode, !passwordAuthentication {
            arguments += ["-o", "BatchMode=yes"]
        }

        if passwordAuthentication {
            arguments += ["-o", "BatchMode=no"]
            arguments += savedPasswordAuthenticationOptions
        }

        if !passwordAuthentication {
            let identityFile = session.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identityFile.isEmpty {
                SSHIdentityFileAccess.activateIfNeeded(for: identityFile)
                arguments += ["-i", expandedHomePath(identityFile)]
            }

            let jumpHost = session.jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !jumpHost.isEmpty {
                arguments += ["-o", "ProxyJump=\(jumpHost)"]
            }
        }

        return arguments
    }
}

enum X11Support {
    static let commonXAuthPaths = [
        "/opt/X11/bin/xauth",
        "/usr/X11/bin/xauth",
        "/usr/X11R6/bin/xauth",
    ]

    static func xauthLocation(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        commonXAuthPaths.first(where: fileExists)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func prepend(_ prefix: String) -> String {
        prefix + self
    }
}
