//
//  AuthenticatedRemoteCommandRunner.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/30.
//

import Foundation

nonisolated struct RemoteCommandInvocation: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]?
    let standardInput: String?
    let timeoutSeconds: TimeInterval?
}

typealias RemoteCredentialReader = @Sendable (String) async throws -> String?
typealias RemoteCommandExecutor = @Sendable (RemoteCommandInvocation) async throws -> CommandResult

nonisolated enum RemoteCredentialRoutingError: LocalizedError, Equatable, Sendable {
    case savedPasswordCannotUseJumpHost

    var errorDescription: String? {
        switch self {
        case .savedPasswordCannotUseJumpHost:
            return "Saved-password authentication cannot be used while a jump host is configured because that would bypass the requested jump route. Use an SSH key or ssh-agent for this profile, or remove the jump host before using a saved password."
        }
    }
}

/// A value-only copy of every `RemoteSession` field consumed by the SSH
/// command builders. Build this synchronously, then derive the vault account
/// and every possible argv from it before the first suspension point.
nonisolated struct SSHSessionLaunchSnapshot: Equatable, Sendable {
    let host: String
    let username: String
    let port: Int
    let identityFile: String
    let jumpHost: String
    let enableX11Forwarding: Bool

    init(session: RemoteSession) {
        host = session.host
        username = session.username
        port = session.port
        identityFile = session.identityFile
        jumpHost = session.jumpHost
        enableX11Forwarding = session.enableX11Forwarding
    }

    var credentialAccount: String {
        CredentialStore.account(username: username, host: host, port: port)
    }

    var allowsSavedPasswordAutofill: Bool {
        InteractiveProcessSession.allowsSavedServerPasswordAutofill(
            jumpHost: jumpHost
        )
    }

    /// `SSHCommandBuilder` deliberately accepts the persisted model. Give it
    /// a detached model populated only from this immutable value so every argv
    /// variant is guaranteed to describe the same destination.
    func materializedSession() -> RemoteSession {
        RemoteSession(
            name: "SSH launch snapshot",
            host: host,
            username: username,
            port: port,
            connectionType: .ssh,
            identityFile: identityFile,
            jumpHost: jumpHost,
            enableX11Forwarding: enableX11Forwarding
        )
    }
}

nonisolated struct CredentialBoundCommandSnapshot: Sendable {
    let credentialAccount: String
    let keyArguments: [String]
    let savedPasswordArguments: [String]
    let allowsSavedPasswordAutofill: Bool
}

/// Immutable launch data for the Server Properties connection test. The view
/// creates this value before scheduling asynchronous credential access so an
/// edit to the SwiftData model cannot pair an old account secret with a new
/// destination.
struct SSHConnectionTestLaunchSnapshot: Sendable {
    let credentialAccount: String
    let keyArguments: [String]
    let savedPasswordArguments: [String]
    let allowsSavedPasswordAutofill: Bool
    #if JTS_UI_TEST_SUPPORT
    let appReviewBrokerRequest: AppReviewSSHCredentialBrokerRequest?
    let appReviewBrokerConfigurationError: String?
    let appReviewSmokeNonce: String?
    let appReviewKnownHostsFilePath: String?
    let appReviewPasswordArguments: [String]?
    #endif

    init(
        session: RemoteSession,
        remoteCommand: String,
        uiTestEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let destination = SSHSessionLaunchSnapshot(session: session)
        let frozenSession = destination.materializedSession()
        credentialAccount = destination.credentialAccount
        keyArguments = SSHCommandBuilder.sshArguments(
            for: frozenSession,
            remoteCommand: remoteCommand
        )
        savedPasswordArguments = SSHCommandBuilder.passwordSSHArguments(
            for: frozenSession,
            remoteCommand: remoteCommand
        )
        allowsSavedPasswordAutofill = destination.allowsSavedPasswordAutofill
        #if JTS_UI_TEST_SUPPORT
        do {
            appReviewBrokerRequest = try UITestSSHSessionEnvironment.formalSmokeBrokerRequest(
                forHost: destination.host,
                username: destination.username,
                credentialAccount: destination.credentialAccount,
                environment: uiTestEnvironment
            )
            appReviewBrokerConfigurationError = nil
        } catch {
            appReviewBrokerRequest = nil
            appReviewBrokerConfigurationError = error.localizedDescription
        }
        appReviewSmokeNonce = appReviewBrokerRequest?.nonce
            ?? UITestSSHSessionEnvironment.appReviewSmokeNonce(
                forHost: destination.host,
                username: destination.username,
                credentialAccount: destination.credentialAccount,
                environment: uiTestEnvironment
            )
        appReviewKnownHostsFilePath = appReviewBrokerRequest?.expectedKnownHostsFilePath
        appReviewPasswordArguments = appReviewKnownHostsFilePath.map {
            SSHCommandBuilder.appReviewPasswordSmokeArguments(
                for: frozenSession,
                knownHostsFilePath: $0
            )
        }
        #endif
    }
}

struct AuthenticatedRemoteCommandRunner {
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

    func runSSH(
        session: RemoteSession,
        remoteCommand: String,
        standardInput: String? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> CommandResult {
        let destination = SSHSessionLaunchSnapshot(session: session)
        let frozenSession = destination.materializedSession()
        let launch = CredentialBoundCommandSnapshot(
            credentialAccount: destination.credentialAccount,
            keyArguments: SSHCommandBuilder.sshArguments(
                for: frozenSession,
                remoteCommand: remoteCommand
            ),
            savedPasswordArguments: SSHCommandBuilder.passwordSSHArguments(
                for: frozenSession,
                remoteCommand: remoteCommand
            ),
            allowsSavedPasswordAutofill: destination.allowsSavedPasswordAutofill
        )

        try Task.checkCancellation()
        let secret = try await credentialReader(launch.credentialAccount)
        try Task.checkCancellation()

        if let secret {
            guard launch.allowsSavedPasswordAutofill else {
                throw RemoteCredentialRoutingError.savedPasswordCannotUseJumpHost
            }
            let askpassContext = try SSHCredentialAskpass.launchContext(
                account: launch.credentialAccount,
                secret: secret
            )
            defer { askpassContext.cleanup() }
            return try await commandExecutor(RemoteCommandInvocation(
                executable: "/usr/bin/ssh",
                arguments: launch.savedPasswordArguments,
                environment: askpassContext.environment,
                standardInput: standardInput,
                timeoutSeconds: timeoutSeconds
            ))
        }

        return try await commandExecutor(RemoteCommandInvocation(
            executable: "/usr/bin/ssh",
            arguments: launch.keyArguments,
            environment: nil,
            standardInput: standardInput,
            timeoutSeconds: timeoutSeconds
        ))
    }

    func runSCPUpload(
        session: RemoteSession,
        localPath: String,
        remotePath: String,
        recursive: Bool = false
    ) async throws -> CommandResult {
        let destination = SSHSessionLaunchSnapshot(session: session)
        let frozenSession = destination.materializedSession()
        let launch = CredentialBoundCommandSnapshot(
            credentialAccount: destination.credentialAccount,
            keyArguments: SSHCommandBuilder.scpUploadArguments(
                for: frozenSession,
                localPath: localPath,
                remotePath: remotePath,
                batchMode: true,
                passwordAuthentication: false,
                recursive: recursive
            ),
            savedPasswordArguments: SSHCommandBuilder.scpUploadArguments(
                for: frozenSession,
                localPath: localPath,
                remotePath: remotePath,
                batchMode: false,
                passwordAuthentication: true,
                recursive: recursive
            ),
            allowsSavedPasswordAutofill: destination.allowsSavedPasswordAutofill
        )

        try Task.checkCancellation()
        let secret = try await credentialReader(launch.credentialAccount)
        try Task.checkCancellation()

        if let secret {
            guard launch.allowsSavedPasswordAutofill else {
                throw RemoteCredentialRoutingError.savedPasswordCannotUseJumpHost
            }
            let askpassContext = try SSHCredentialAskpass.launchContext(
                account: launch.credentialAccount,
                secret: secret
            )
            defer { askpassContext.cleanup() }
            return try await commandExecutor(RemoteCommandInvocation(
                executable: "/usr/bin/scp",
                arguments: launch.savedPasswordArguments,
                environment: askpassContext.environment,
                standardInput: nil,
                timeoutSeconds: nil
            ))
        }

        return try await commandExecutor(RemoteCommandInvocation(
            executable: "/usr/bin/scp",
            arguments: launch.keyArguments,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: nil
        ))
    }

    func runSCPDownload(
        session: RemoteSession,
        remotePath: String,
        localPath: String,
        recursive: Bool = false
    ) async throws -> CommandResult {
        let destination = SSHSessionLaunchSnapshot(session: session)
        let frozenSession = destination.materializedSession()
        let launch = CredentialBoundCommandSnapshot(
            credentialAccount: destination.credentialAccount,
            keyArguments: SSHCommandBuilder.scpDownloadArguments(
                for: frozenSession,
                remotePath: remotePath,
                localPath: localPath,
                batchMode: true,
                passwordAuthentication: false,
                recursive: recursive
            ),
            savedPasswordArguments: SSHCommandBuilder.scpDownloadArguments(
                for: frozenSession,
                remotePath: remotePath,
                localPath: localPath,
                batchMode: false,
                passwordAuthentication: true,
                recursive: recursive
            ),
            allowsSavedPasswordAutofill: destination.allowsSavedPasswordAutofill
        )

        try Task.checkCancellation()
        let secret = try await credentialReader(launch.credentialAccount)
        try Task.checkCancellation()

        if let secret {
            guard launch.allowsSavedPasswordAutofill else {
                throw RemoteCredentialRoutingError.savedPasswordCannotUseJumpHost
            }
            let askpassContext = try SSHCredentialAskpass.launchContext(
                account: launch.credentialAccount,
                secret: secret
            )
            defer { askpassContext.cleanup() }
            return try await commandExecutor(RemoteCommandInvocation(
                executable: "/usr/bin/scp",
                arguments: launch.savedPasswordArguments,
                environment: askpassContext.environment,
                standardInput: nil,
                timeoutSeconds: nil
            ))
        }

        return try await commandExecutor(RemoteCommandInvocation(
            executable: "/usr/bin/scp",
            arguments: launch.keyArguments,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: nil
        ))
    }
}
