//
//  SSHConnectionTestCoordinator.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/17.
//

import Combine
import Foundation

/// Owns the ordinary (non-App-Review) SSH connection-test lifecycle.
///
/// The coordinator freezes all launch data before its first suspension point,
/// keeps password text out of observable state, and never invokes SSH until a
/// vault read or explicit user credential decision has completed successfully.
@MainActor
final class SSHConnectionTestCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isSubmittingCredential = false
    @Published private(set) var status: CommandResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingCredentialPrompt: SSHCredentialPromptDescriptor?

    private struct PendingTest {
        let id: UUID
        let snapshot: SSHConnectionTestLaunchSnapshot
        let displayLabel: String
    }

    private let credentialReader: RemoteCredentialReader
    private let credentialWriter: @Sendable (_ secret: String, _ account: String) async throws -> Void
    private let askpassContextFactory: @Sendable (
        _ account: String,
        _ secret: String
    ) throws -> SSHCredentialAskpass.LaunchContext
    private let commandExecutor: RemoteCommandExecutor
    private let timeoutSeconds: TimeInterval

    private var requestID: UUID?
    private var pendingTest: PendingTest?
    private var task: Task<Void, Never>?

    init(
        timeoutSeconds: TimeInterval = 20,
        credentialReader: @escaping RemoteCredentialReader = { account in
            return try await Task.detached(priority: .userInitiated) {
                try SSHCredentialVaultAccess.read(account: account)
            }.value
        },
        credentialWriter: @escaping @Sendable (
            _ secret: String,
            _ account: String
        ) async throws -> Void = { secret, account in
            try await Task.detached(priority: .userInitiated) {
                try SSHCredentialVaultAccess.save(secret: secret, account: account)
            }.value
        },
        askpassContextFactory: @escaping @Sendable (
            _ account: String,
            _ secret: String
        ) throws -> SSHCredentialAskpass.LaunchContext = { account, secret in
            try SSHCredentialAskpass.launchContext(account: account, secret: secret)
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
        self.timeoutSeconds = timeoutSeconds
        self.credentialReader = credentialReader
        self.credentialWriter = credentialWriter
        self.askpassContextFactory = askpassContextFactory
        self.commandExecutor = commandExecutor
    }

    deinit {
        task?.cancel()
    }

    func begin(snapshot: SSHConnectionTestLaunchSnapshot, displayLabel: String) {
        cancel()

        let id = UUID()
        let pending = PendingTest(id: id, snapshot: snapshot, displayLabel: displayLabel)
        requestID = id
        pendingTest = pending
        isRunning = true
        status = nil
        errorMessage = nil

        guard snapshot.allowsSavedPasswordAutofill else {
            pendingCredentialPrompt = descriptor(for: pending, mode: .jumpHostManualOnly)
            return
        }

        let credentialReader = self.credentialReader
        task = Task { [weak self] in
            let storedSecret: String?
            do {
                storedSecret = try await credentialReader(snapshot.credentialAccount)
            } catch {
                guard let self else { return }
                guard isCurrent(id), !Task.isCancelled else { return }
                finish(id: id, error: error.localizedDescription)
                return
            }

            guard let self else { return }
            guard isCurrent(id), !Task.isCancelled else { return }
            task = nil
            guard let storedSecret, !storedSecret.isEmpty else {
                pendingCredentialPrompt = descriptor(for: pending, mode: .passwordOrKeyAgent)
                return
            }
            runPasswordTest(secret: storedSecret, pending: pending)
        }
    }

    func connectOnce(secret: String, requestID: UUID) {
        guard let pending = currentPendingTest(requestID),
              pending.snapshot.allowsSavedPasswordAutofill,
              !isSubmittingCredential else { return }
        guard let validationError = SSHCredentialPromptPolicy.validationError(for: secret) else {
            errorMessage = nil
            pendingCredentialPrompt = nil
            runPasswordTest(secret: secret, pending: pending)
            return
        }
        errorMessage = validationError.localizedDescription
    }

    func saveAndTest(secret: String, requestID: UUID) {
        guard let pending = currentPendingTest(requestID),
              pending.snapshot.allowsSavedPasswordAutofill,
              !isSubmittingCredential else { return }
        guard let validationError = SSHCredentialPromptPolicy.validationError(for: secret) else {
            isSubmittingCredential = true
            errorMessage = nil
            let credentialWriter = self.credentialWriter
            task = Task { [weak self] in
                do {
                    try await credentialWriter(secret, pending.snapshot.credentialAccount)
                } catch {
                    guard let self else { return }
                    guard isCurrent(requestID), !Task.isCancelled else { return }
                    task = nil
                    isSubmittingCredential = false
                    errorMessage = error.localizedDescription
                    return
                }
                guard let self else { return }
                guard isCurrent(requestID), !Task.isCancelled else { return }
                isSubmittingCredential = false
                pendingCredentialPrompt = nil
                runPasswordTest(secret: secret, pending: pending)
            }
            return
        }
        errorMessage = validationError.localizedDescription
    }

    func useKeyOrAgent(requestID: UUID) {
        guard let pending = currentPendingTest(requestID),
              !isSubmittingCredential else { return }
        pendingCredentialPrompt = nil
        errorMessage = nil
        runInvocation(
            RemoteCommandInvocation(
                executable: "/usr/bin/ssh",
                arguments: pending.snapshot.keyArguments,
                environment: nil,
                standardInput: nil,
                timeoutSeconds: timeoutSeconds
            ),
            pending: pending,
            askpassContext: nil
        )
    }

    func cancel(requestID: UUID? = nil) {
        if let requestID, self.requestID != requestID { return }
        task?.cancel()
        task = nil
        self.requestID = nil
        pendingTest = nil
        pendingCredentialPrompt = nil
        isRunning = false
        isSubmittingCredential = false
        errorMessage = nil
    }

    private func descriptor(
        for pending: PendingTest,
        mode: SSHCredentialPromptDescriptor.Mode
    ) -> SSHCredentialPromptDescriptor {
        SSHCredentialPromptDescriptor(
            id: pending.id,
            credentialAccount: pending.snapshot.credentialAccount,
            displayLabel: pending.displayLabel,
            mode: mode
        )
    }

    private func runPasswordTest(secret: String, pending: PendingTest) {
        guard isCurrent(pending.id) else { return }
        let context: SSHCredentialAskpass.LaunchContext
        do {
            context = try askpassContextFactory(pending.snapshot.credentialAccount, secret)
        } catch {
            finish(id: pending.id, error: error.localizedDescription)
            return
        }
        runInvocation(
            RemoteCommandInvocation(
                executable: "/usr/bin/ssh",
                arguments: pending.snapshot.savedPasswordArguments,
                environment: context.environment,
                standardInput: nil,
                timeoutSeconds: timeoutSeconds
            ),
            pending: pending,
            askpassContext: context
        )
    }

    private func runInvocation(
        _ invocation: RemoteCommandInvocation,
        pending: PendingTest,
        askpassContext: SSHCredentialAskpass.LaunchContext?
    ) {
        guard isCurrent(pending.id) else {
            askpassContext?.cleanup()
            return
        }
        let commandExecutor = self.commandExecutor
        task = Task { [weak self] in
            defer { askpassContext?.cleanup() }
            do {
                let result = try await commandExecutor(invocation)
                guard let self else { return }
                guard isCurrent(pending.id), !Task.isCancelled else { return }
                finish(id: pending.id, result: result)
            } catch {
                guard let self else { return }
                guard isCurrent(pending.id), !Task.isCancelled else { return }
                finish(id: pending.id, error: error.localizedDescription)
            }
        }
    }

    private func currentPendingTest(_ id: UUID) -> PendingTest? {
        guard requestID == id, pendingTest?.id == id else { return nil }
        return pendingTest
    }

    private func isCurrent(_ id: UUID) -> Bool {
        currentPendingTest(id) != nil
    }

    private func finish(id: UUID, result: CommandResult? = nil, error: String? = nil) {
        guard isCurrent(id) else { return }
        task = nil
        requestID = nil
        pendingTest = nil
        pendingCredentialPrompt = nil
        isRunning = false
        isSubmittingCredential = false
        status = result
        errorMessage = error
    }
}
