//
//  InteractiveProcessSession.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import Combine
import Darwin
import Foundation
#if canImport(SwiftTerm)
import SwiftTerm
#endif

@MainActor
final class InteractiveProcessSession: ObservableObject {
    private static let maximumCurrentLaunchOutputCharacters = 16_384
    private static let maximumRawTranscriptCharacters = 262_144

    struct PendingCredentialSaveRequest: Identifiable {
        let id = UUID()
        let account: String
        let label: String
        let secret: String
    }

    struct StructuredCommandRecovery: Identifiable, Equatable {
        enum Reason: Equatable {
            case timedOut
            case interrupted
        }

        let id = UUID()
        let launchID: UUID
        let commandID: UUID
        let reason: Reason
    }

    struct StructuredCommandActivity: Equatable {
        enum Phase: Equatable {
            case idle
            case preparing
            case echoProbeSent
            case commandBytesWritten
        }

        let launchID: UUID?
        let commandID: UUID?
        let phase: Phase

        static let idle = StructuredCommandActivity(
            launchID: nil,
            commandID: nil,
            phase: .idle
        )

        var didSendEchoProbe: Bool {
            phase == .echoProbeSent || phase == .commandBytesWritten
        }

        var didWriteCommandBytes: Bool {
            phase == .commandBytesWritten
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var hasStarted = false
    @Published private(set) var transcript = "PTY-backed SSH session is stopped."
    @Published private(set) var pid: pid_t?
    @Published private(set) var pendingCredentialSaveRequest: PendingCredentialSaveRequest?
    @Published private(set) var pendingSSHCredentialPrompt: SSHCredentialPromptDescriptor?
    @Published private(set) var sshCredentialPromptError: String?
    @Published private(set) var isSubmittingSSHCredential = false
    @Published private(set) var isSSHStartPending = false
    @Published private(set) var isReconnectScheduled = false
    @Published private(set) var reconnectStatus = ""
    @Published private(set) var isMCPControlEnabled = false
    @Published private(set) var isBroadcastReady = false
    @Published private(set) var isStructuredCommandBusy = false
    @Published private(set) var structuredCommandRecovery: StructuredCommandRecovery?
    /// Non-sensitive synchronization state for the active structured command.
    /// It deliberately exposes neither command text nor terminal output.
    @Published private(set) var structuredCommandActivity = StructuredCommandActivity.idle

    private var backend: TerminalProcessBackend?
    private var desiredColumns: UInt16 = 120
    private var desiredRows: UInt16 = 32
    private var credentialSaveAccount: String?
    private var credentialSaveLabel: String?
    private var isCapturingPasswordInput = false
    private var capturedPasswordInput = ""
    private var sensitiveInputEchoRedactor: TerminalSensitiveInputEchoRedactor?
    private var outputDecoder = TerminalUTF8StreamDecoder()
    private var recentOutputForPrompt = ""
    private var lastLaunchConfiguration: LaunchConfiguration?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var queuedMCPCommands: [QueuedMCPCommand] = []
    private var activeStructuredCommandID: UUID?
    private var cancelledStructuredCommandIDs: Set<UUID> = []
    private var rawTranscript = "PTY-backed SSH session is stopped."
    private var currentLaunchOutput = ""
    private var mcpDisplaySuppression: MCPDisplaySuppression?
    private var activeLaunchID: UUID?
    private var broadcastReservationID: UUID?
    /// Retain the complete one-shot credential broker for the lifetime of the
    /// OpenSSH process using it. The broker never exposes password text in
    /// observable session state.
    private var activeAskpassContext: SSHCredentialAskpass.LaunchContext?
    private var pendingSSHStartTask: Task<Void, Never>?
    private var sshStartRequestID: UUID?
    private var pendingSSHLaunch: PendingSSHLaunch?
    private let credentialReader: @Sendable (String) async throws -> String?
    private let credentialWriter: @Sendable (_ secret: String, _ account: String) async throws -> Void
    private let askpassContextFactory: @Sendable (
        _ account: String,
        _ secret: String
    ) throws -> SSHCredentialAskpass.LaunchContext
    private let credentialDeliverySnapshotter: @MainActor @Sendable (
        SSHCredentialAskpass.LaunchContext?
    ) -> SSHCredentialDeliveryState
    private let sshExecutable: String

    /// Internal lifecycle observability for hosted regression tests. This is
    /// the private broker endpoint, never credential material.
    var activeCredentialBrokerSocketURL: URL? {
        guard let socketPath = activeAskpassContext?.environment[
            SSHCredentialAskpass.brokerSocketEnvironmentKey
        ], !socketPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: socketPath, isDirectory: false)
    }

    private enum StructuredCommandOrigin: Equatable {
        case mcp
        case humanBroadcast(batchID: UUID)

        var isMCP: Bool {
            if case .mcp = self {
                return true
            }
            return false
        }

        var displayName: String {
            switch self {
            case .mcp:
                return "MCP"
            case .humanBroadcast:
                return "Multi-Exec"
            }
        }
    }

    private final class StructuredCommandExecutionState {
        var echoMayBeDisabled = false
        var didSendEchoRestore = false
    }

    private struct QueuedMCPCommand {
        let id: UUID
        let request: TerminalMCPCommandRequest
        let origin: StructuredCommandOrigin
        let expectedLaunchID: UUID
        let continuation: CheckedContinuation<TerminalMCPCommandResult, Error>
    }

    private struct MCPDisplaySuppression {
        private static let trailingCharacterLimit = 8_192

        let commandID: UUID
        let startSentinel: String
        let endSentinel: String
        let maximumCaptureCharacters: Int
        let displaysOutputInTerminal: Bool
        var bufferedOutput = ""
        var trailingOutput = ""
        var didDropMiddle = false

        mutating func append(_ text: String) {
            guard !text.isEmpty else { return }
            if didDropMiddle {
                trailingOutput += text
                if trailingOutput.count > Self.trailingCharacterLimit {
                    trailingOutput = String(trailingOutput.suffix(Self.trailingCharacterLimit))
                }
                return
            }

            let remaining = maximumCaptureCharacters - bufferedOutput.count
            if text.count <= remaining {
                bufferedOutput += text
                return
            }

            if remaining > 0 {
                bufferedOutput += text.prefix(remaining)
            }
            let overflowStart = text.index(
                text.startIndex,
                offsetBy: max(remaining, 0),
                limitedBy: text.endIndex
            ) ?? text.endIndex
            trailingOutput =
                String(bufferedOutput.suffix(512)) +
                String(text[overflowStart...])
            if trailingOutput.count > Self.trailingCharacterLimit {
                trailingOutput = String(trailingOutput.suffix(Self.trailingCharacterLimit))
            }
            didDropMiddle = true
        }
    }

    var executionGeneration: UUID? {
        activeLaunchID
    }

    var requiresStructuredCommandRecovery: Bool {
        structuredCommandRecovery != nil
    }

    /// Frozen, non-secret launch data retained while the vault is read or the
    /// user is deciding how to authenticate. A stale prompt can therefore
    /// never combine an earlier account with a subsequently edited profile.
    private struct PendingSSHLaunch {
        let requestID: UUID
        let descriptor: SSHCredentialPromptDescriptor
        let manualArguments: [String]
        let savedPasswordArguments: [String]
        let label: String
    }

    /// Frozen non-secret launch data retained after a saved-password launch so
    /// an authentication rejection can offer a safe replacement without
    /// rebuilding argv from an editable profile.
    private struct SSHCredentialRecoveryTemplate {
        let credentialAccount: String
        let displayLabel: String
        let manualArguments: [String]
        let savedPasswordArguments: [String]
    }

    /// Distinguishes the unattended vault launch from the explicit recovery
    /// attempt the user just submitted. A rejected vault value may open one
    /// recovery prompt; a rejected replacement must stop instead of creating
    /// an unbounded modal retry loop.
    private enum SSHPasswordLaunchSource {
        case storedCredential
        case userEnteredCredential
    }

    private struct LaunchConfiguration {
        let executable: String
        let arguments: [String]
        let label: String
        let autoReconnect: Bool
        let askpassContext: SSHCredentialAskpass.LaunchContext?
        let askpassCredentialAccount: String?
        let passwordSource: SSHPasswordLaunchSource?
        let credentialSaveAccount: String?
        let credentialSaveLabel: String?
        let credentialRecoveryTemplate: SSHCredentialRecoveryTemplate?

        var reconnectTemplate: LaunchConfiguration {
            LaunchConfiguration(
                executable: executable,
                arguments: arguments,
                label: label,
                autoReconnect: autoReconnect,
                askpassContext: nil,
                askpassCredentialAccount: askpassCredentialAccount,
                passwordSource: passwordSource,
                credentialSaveAccount: credentialSaveAccount,
                credentialSaveLabel: credentialSaveLabel,
                credentialRecoveryTemplate: credentialRecoveryTemplate
            )
        }

        func withAskpassContext(
            _ context: SSHCredentialAskpass.LaunchContext?
        ) -> LaunchConfiguration {
            LaunchConfiguration(
                executable: executable,
                arguments: arguments,
                label: label,
                autoReconnect: autoReconnect,
                askpassContext: context,
                askpassCredentialAccount: askpassCredentialAccount,
                // A scheduled retry reloads this value from the vault. If a
                // previously established session later discovers that value
                // is stale, it may offer one fresh recovery prompt again.
                passwordSource: askpassCredentialAccount == nil
                    ? nil
                    : .storedCredential,
                credentialSaveAccount: credentialSaveAccount,
                credentialSaveLabel: credentialSaveLabel,
                credentialRecoveryTemplate: credentialRecoveryTemplate
            )
        }
    }

    init(
        credentialReader: @escaping @Sendable (String) async throws -> String? = { account in
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
        credentialDeliverySnapshotter: @escaping @MainActor @Sendable (
            SSHCredentialAskpass.LaunchContext?
        ) -> SSHCredentialDeliveryState = SSHCredentialDeliveryState.snapshot,
        sshExecutable: String = "/usr/bin/ssh"
    ) {
        self.credentialReader = credentialReader
        self.credentialWriter = credentialWriter
        self.askpassContextFactory = askpassContextFactory
        self.credentialDeliverySnapshotter = credentialDeliverySnapshotter
        self.sshExecutable = sshExecutable
    }

    deinit {
        pendingSSHStartTask?.cancel()
        reconnectTask?.cancel()
        activeAskpassContext?.cleanup()
    }

    func startSSH(session: RemoteSession) {
        guard session.connectionType == .ssh else {
            cancelPendingSSHStart()
            cancelScheduledReconnect()
            appendSessionMessage(
                "This profile is \(session.connectionType.displayName), not SSH. Open its supported workspace instead."
            )
            return
        }
        guard !isSSHStartPending else { return }
        cancelPendingSSHStart()
        cancelScheduledReconnect()
        let requestID = UUID()
        sshStartRequestID = requestID
        sshCredentialPromptError = nil
        isSubmittingSSHCredential = false
        isSSHStartPending = true

        let snapshot = SSHSessionLaunchSnapshot(session: session)
        let frozenSession = snapshot.materializedSession()
        let descriptor = SSHCredentialPromptPolicy.descriptor(
            id: requestID,
            credentialAccount: snapshot.credentialAccount,
            displayLabel: session.address,
            jumpHost: snapshot.jumpHost
        )
        let pendingLaunch = PendingSSHLaunch(
            requestID: requestID,
            descriptor: descriptor,
            manualArguments: SSHCommandBuilder.interactiveSSHArguments(
                for: frozenSession
            ),
            savedPasswordArguments: SSHCommandBuilder.savedPasswordInteractiveSSHArguments(
                for: frozenSession
            ),
            label: session.address
        )
        let recoveryTemplate = SSHCredentialRecoveryTemplate(
            credentialAccount: snapshot.credentialAccount,
            displayLabel: session.address,
            manualArguments: pendingLaunch.manualArguments,
            savedPasswordArguments: pendingLaunch.savedPasswordArguments
        )
        pendingSSHLaunch = pendingLaunch

        // A ProxyJump session can emit indistinguishable prompts for two
        // different servers. Never read or offer the destination vault secret
        // on this route; require the user to continue with keys/agent or enter
        // the separate credentials manually in the PTY.
        guard descriptor.mode != .jumpHostManualOnly else {
            pendingSSHCredentialPrompt = descriptor
            return
        }

        pendingSSHStartTask = Task { [weak self] in
            guard let self else { return }
            let storedSecret: String?
            do {
                storedSecret = try await credentialReader(descriptor.credentialAccount)
            } catch {
                guard !Task.isCancelled,
                      isCurrentPendingSSHStart(requestID) else { return }
                failPendingSSHStart(
                    requestID: requestID,
                    message: "Could not read the local SSH credential vault: \(error.localizedDescription). No connection was started."
                )
                return
            }
            guard !Task.isCancelled,
                  isCurrentPendingSSHStart(requestID) else { return }
            pendingSSHStartTask = nil

            guard let storedSecret, !storedSecret.isEmpty else {
                pendingSSHCredentialPrompt = descriptor
                return
            }

            let askpassContext: SSHCredentialAskpass.LaunchContext
            do {
                askpassContext = try askpassContextFactory(
                    descriptor.credentialAccount,
                    storedSecret
                )
            } catch {
                failPendingSSHStart(
                    requestID: requestID,
                    message: "The saved SSH password could not be prepared securely: \(error.localizedDescription). No connection was started."
                )
                return
            }
            guard isCurrentPendingSSHStart(requestID) else {
                askpassContext.cleanup()
                return
            }

            let configuration = LaunchConfiguration(
                executable: sshExecutable,
                arguments: pendingLaunch.savedPasswordArguments,
                label: pendingLaunch.label,
                autoReconnect: true,
                askpassContext: askpassContext,
                askpassCredentialAccount: descriptor.credentialAccount,
                passwordSource: .storedCredential,
                credentialSaveAccount: nil,
                credentialSaveLabel: nil,
                credentialRecoveryTemplate: recoveryTemplate
            )
            completePendingSSHStart(requestID: requestID)
            start(configuration, replacingTranscript: true, resetReconnectAttempt: true)
        }
    }

    func connectOnceWithSSHPassword(_ secret: String, requestID: UUID) {
        guard let pendingLaunch = currentPendingSSHLaunch(requestID),
              pendingLaunch.descriptor.allowsPasswordSubmission,
              !isSubmittingSSHCredential else { return }
        guard let validationError = SSHCredentialPromptPolicy.validationError(for: secret) else {
            connectUsingSSHPassword(
                secret,
                pendingLaunch: pendingLaunch,
                saveBeforeConnecting: false
            )
            return
        }
        sshCredentialPromptError = validationError.localizedDescription
    }

    func saveAndConnectWithSSHPassword(_ secret: String, requestID: UUID) {
        guard let pendingLaunch = currentPendingSSHLaunch(requestID),
              pendingLaunch.descriptor.allowsPasswordSubmission,
              !isSubmittingSSHCredential else { return }
        guard let validationError = SSHCredentialPromptPolicy.validationError(for: secret) else {
            connectUsingSSHPassword(
                secret,
                pendingLaunch: pendingLaunch,
                saveBeforeConnecting: true
            )
            return
        }
        sshCredentialPromptError = validationError.localizedDescription
    }

    func continueSSHWithKeyOrAgent(requestID: UUID) {
        guard let pendingLaunch = currentPendingSSHLaunch(requestID),
              !isSubmittingSSHCredential else { return }
        let configuration = LaunchConfiguration(
            executable: sshExecutable,
            arguments: pendingLaunch.manualArguments,
            label: pendingLaunch.label,
            autoReconnect: true,
            askpassContext: nil,
            askpassCredentialAccount: nil,
            passwordSource: nil,
            credentialSaveAccount: nil,
            credentialSaveLabel: nil,
            credentialRecoveryTemplate: nil
        )
        completePendingSSHStart(requestID: requestID)
        start(configuration, replacingTranscript: true, resetReconnectAttempt: true)
    }

    func cancelSSHCredentialPrompt(requestID: UUID) {
        guard isCurrentPendingSSHStart(requestID) else { return }
        cancelPendingSSHStart()
    }

    private func connectUsingSSHPassword(
        _ secret: String,
        pendingLaunch: PendingSSHLaunch,
        saveBeforeConnecting: Bool
    ) {
        let requestID = pendingLaunch.requestID
        sshCredentialPromptError = nil

        guard saveBeforeConnecting else {
            do {
                let askpassContext = try askpassContextFactory(
                    pendingLaunch.descriptor.credentialAccount,
                    secret
                )
                guard isCurrentPendingSSHStart(requestID) else {
                    askpassContext.cleanup()
                    return
                }
                let configuration = LaunchConfiguration(
                    executable: sshExecutable,
                    arguments: pendingLaunch.savedPasswordArguments,
                    label: pendingLaunch.label,
                    // "Connect Once" is one launch only. Retaining this secret
                    // for an automatic retry would contradict the user's choice.
                    autoReconnect: false,
                    askpassContext: askpassContext,
                    askpassCredentialAccount: nil,
                    passwordSource: .userEnteredCredential,
                    credentialSaveAccount: nil,
                    credentialSaveLabel: nil,
                    credentialRecoveryTemplate: nil
                )
                completePendingSSHStart(requestID: requestID)
                start(configuration, replacingTranscript: true, resetReconnectAttempt: true)
            } catch {
                sshCredentialPromptError =
                    "The SSH password could not be prepared securely: \(error.localizedDescription)"
            }
            return
        }

        isSubmittingSSHCredential = true
        pendingSSHStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await credentialWriter(
                    secret,
                    pendingLaunch.descriptor.credentialAccount
                )
            } catch {
                guard !Task.isCancelled,
                      isCurrentPendingSSHStart(requestID) else { return }
                pendingSSHStartTask = nil
                isSubmittingSSHCredential = false
                sshCredentialPromptError =
                    "Could not save the SSH password to the local encrypted vault: \(error.localizedDescription). No connection was started."
                return
            }

            guard !Task.isCancelled,
                  isCurrentPendingSSHStart(requestID) else { return }

            let askpassContext: SSHCredentialAskpass.LaunchContext
            do {
                askpassContext = try askpassContextFactory(
                    pendingLaunch.descriptor.credentialAccount,
                    secret
                )
            } catch {
                pendingSSHStartTask = nil
                isSubmittingSSHCredential = false
                sshCredentialPromptError =
                    "The saved SSH password could not be prepared securely: \(error.localizedDescription). No connection was started."
                return
            }
            guard isCurrentPendingSSHStart(requestID) else {
                askpassContext.cleanup()
                return
            }

            let configuration = LaunchConfiguration(
                executable: sshExecutable,
                arguments: pendingLaunch.savedPasswordArguments,
                label: pendingLaunch.label,
                autoReconnect: true,
                askpassContext: askpassContext,
                askpassCredentialAccount: pendingLaunch.descriptor.credentialAccount,
                passwordSource: .userEnteredCredential,
                credentialSaveAccount: nil,
                credentialSaveLabel: nil,
                credentialRecoveryTemplate: SSHCredentialRecoveryTemplate(
                    credentialAccount: pendingLaunch.descriptor.credentialAccount,
                    displayLabel: pendingLaunch.descriptor.displayLabel,
                    manualArguments: pendingLaunch.manualArguments,
                    savedPasswordArguments: pendingLaunch.savedPasswordArguments
                )
            )
            completePendingSSHStart(requestID: requestID)
            start(configuration, replacingTranscript: true, resetReconnectAttempt: true)
        }
    }

    private func currentPendingSSHLaunch(_ requestID: UUID) -> PendingSSHLaunch? {
        guard sshStartRequestID == requestID,
              pendingSSHLaunch?.requestID == requestID else {
            return nil
        }
        return pendingSSHLaunch
    }

    private func isCurrentPendingSSHStart(_ requestID: UUID) -> Bool {
        currentPendingSSHLaunch(requestID) != nil
    }

    private func completePendingSSHStart(requestID: UUID) {
        guard isCurrentPendingSSHStart(requestID) else { return }
        pendingSSHStartTask = nil
        sshStartRequestID = nil
        pendingSSHLaunch = nil
        pendingSSHCredentialPrompt = nil
        sshCredentialPromptError = nil
        isSubmittingSSHCredential = false
        isSSHStartPending = false
    }

    private func failPendingSSHStart(requestID: UUID, message: String) {
        guard isCurrentPendingSSHStart(requestID) else { return }
        completePendingSSHStart(requestID: requestID)
        appendSessionMessage(message)
    }

    private func presentRejectedSavedPasswordPrompt(
        using template: SSHCredentialRecoveryTemplate
    ) {
        cancelPendingSSHStart()
        let requestID = UUID()
        let descriptor = SSHCredentialPromptDescriptor(
            id: requestID,
            credentialAccount: template.credentialAccount,
            displayLabel: template.displayLabel,
            mode: .passwordOrKeyAgent,
            reason: .rejectedSavedPassword
        )
        sshStartRequestID = requestID
        pendingSSHLaunch = PendingSSHLaunch(
            requestID: requestID,
            descriptor: descriptor,
            manualArguments: template.manualArguments,
            savedPasswordArguments: template.savedPasswordArguments,
            label: template.displayLabel
        )
        pendingSSHCredentialPrompt = descriptor
        sshCredentialPromptError = nil
        isSubmittingSSHCredential = false
        isSSHStartPending = true
    }

    func startLocalShell() {
        let configuration = LocalShellLaunchConfiguration.resolved()
        start(
            executable: configuration.executable,
            arguments: configuration.arguments,
            label: configuration.label
        )
    }

    func start(
        executable: String,
        arguments: [String],
        label: String,
        autoReconnect: Bool = false,
        credentialSaveAccount: String? = nil,
        credentialSaveLabel: String? = nil
    ) {
        cancelPendingSSHStart()
        let configuration = LaunchConfiguration(
            executable: executable,
            arguments: arguments,
            label: label,
            autoReconnect: autoReconnect,
            askpassContext: nil,
            askpassCredentialAccount: nil,
            passwordSource: nil,
            credentialSaveAccount: credentialSaveAccount,
            credentialSaveLabel: credentialSaveLabel,
            credentialRecoveryTemplate: nil
        )
        start(configuration, replacingTranscript: true, resetReconnectAttempt: true)
    }

    private func start(
        _ configuration: LaunchConfiguration,
        replacingTranscript: Bool,
        resetReconnectAttempt: Bool
    ) {
        cancelScheduledReconnect()
        stopActiveBackend()
        let launchID = UUID()
        activeLaunchID = launchID
        activeAskpassContext = configuration.askpassContext
        lastLaunchConfiguration = configuration.reconnectTemplate
        if resetReconnectAttempt {
            reconnectAttempt = 0
        }
        setMCPControlEnabled(false)
        isBroadcastReady = false
        broadcastReservationID = nil
        structuredCommandActivity = .idle
        updateStructuredCommandBusyState()
        hasStarted = true
        if replacingTranscript {
            transcript = ""
            rawTranscript = ""
        }
        mcpDisplaySuppression = nil
        self.credentialSaveAccount = configuration.credentialSaveAccount
        self.credentialSaveLabel = configuration.credentialSaveLabel
        isCapturingPasswordInput = false
        capturedPasswordInput = ""
        sensitiveInputEchoRedactor = nil
        outputDecoder = TerminalUTF8StreamDecoder()
        recentOutputForPrompt = ""
        currentLaunchOutput = ""

        let processBackend = TerminalProcessBackendFactory.makeBackend()
        do {
            try processBackend.start(
                executable: configuration.executable,
                arguments: configuration.arguments,
                environment: TerminalProcessEnvironment.defaultEnvironment(
                    overrides: configuration.askpassContext?.environment ?? [:]
                ),
                columns: desiredColumns,
                rows: desiredRows,
                output: { [weak self] bytes in
                    self?.handleOutput(bytes, launchID: launchID)
                },
                termination: { [weak self] status in
                    self?.finish(status: status, launchID: launchID)
                }
            )
        } catch {
            guard activeLaunchID == launchID else {
                configuration.askpassContext?.cleanup()
                return
            }
            appendSessionMessage("Failed to create PTY session: \(error.localizedDescription)")
            activeLaunchID = nil
            cleanupActiveAskpassContext()
            self.credentialSaveAccount = nil
            self.credentialSaveLabel = nil
            // Backend creation/configuration failures are local structural
            // failures. Retrying them cannot heal a remote connection and
            // previously produced an unbounded reconnect/zombie loop. Only a
            // session that successfully reached `isRunning` may reconnect
            // through the normal termination path.
            return
        }

        backend = processBackend
        pid = processBackend.pid
        isRunning = true
        let pidLabel = processBackend.pid.map { ", pid \($0)" } ?? ""
        appendSessionMessage("started PTY session \(configuration.label)\(pidLabel)")
    }

    func send(_ command: String) {
        sendRaw("\(command)\r")
    }

    func sendRaw(_ text: String) {
        // A reviewed Multi-Exec batch owns the PTY from reservation through
        // result parsing. Mixing human keystrokes into its sentinel envelope
        // could execute text on the wrong shell or corrupt the result.
        guard broadcastReservationID == nil,
              activeStructuredCommandID == nil else {
            return
        }
        capturePasswordInput(from: text)
        backend?.send(text)
    }

    func setMCPControlEnabled(_ enabled: Bool) {
        isMCPControlEnabled = enabled && isRunning
    }

    func setBroadcastReady(_ enabled: Bool) {
        if !enabled {
            guard broadcastReservationID == nil else { return }
            isBroadcastReady = false
            return
        }

        isBroadcastReady =
            isRunning &&
            backend != nil &&
            pendingSSHCredentialPrompt == nil &&
            !isSSHStartPending &&
            !requiresStructuredCommandRecovery &&
            broadcastReservationID == nil &&
            activeStructuredCommandID == nil &&
            queuedMCPCommands.isEmpty
    }

    func reserveBroadcast(batchID: UUID, expectedGeneration: UUID) -> Bool {
        guard isBroadcastReady,
              isRunning,
              backend != nil,
              activeLaunchID == expectedGeneration,
              pendingSSHCredentialPrompt == nil,
              !isSSHStartPending,
              !requiresStructuredCommandRecovery,
              !isCapturingPasswordInput,
              broadcastReservationID == nil,
              activeStructuredCommandID == nil,
              queuedMCPCommands.isEmpty else {
            return false
        }

        broadcastReservationID = batchID
        updateStructuredCommandBusyState()
        return true
    }

    func releaseBroadcastReservation(batchID: UUID) {
        guard broadcastReservationID == batchID else { return }
        broadcastReservationID = nil
        updateStructuredCommandBusyState()
    }

    func runMCPCommand(
        command: String,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> TerminalMCPCommandResult {
        guard isRunning,
              backend != nil,
              let launchID = activeLaunchID else {
            throw TerminalMCPCommandError.notRunning
        }
        guard !requiresStructuredCommandRecovery else {
            throw TerminalMCPCommandError.rejected(
                Self.structuredCommandRecoveryMessage
            )
        }
        guard !isCapturingPasswordInput else {
            throw TerminalMCPCommandError.rejected(
                "Terminal automation is unavailable while an interactive password prompt is active."
            )
        }
        guard broadcastReservationID == nil else {
            throw TerminalMCPCommandError.rejected(
                "This terminal is reserved by a confirmed Multi-Exec batch."
            )
        }
        let request = try TerminalMCPCommandRequest(
            command: command,
            timeoutSeconds: timeoutSeconds,
            maxOutputBytes: maxOutputBytes
        )
        return try await enqueueStructuredCommand(
            request,
            origin: .mcp,
            expectedLaunchID: launchID
        )
    }

    func runBroadcastCommand(
        command: String,
        batchID: UUID,
        expectedGeneration: UUID,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> TerminalMCPCommandResult {
        guard broadcastReservationID == batchID,
              activeLaunchID == expectedGeneration,
              isRunning,
              backend != nil else {
            throw TerminalMCPCommandError.rejected(
                "The terminal changed after Multi-Exec review. No command was sent to this pane."
            )
        }
        guard !requiresStructuredCommandRecovery else {
            throw TerminalMCPCommandError.rejected(
                Self.structuredCommandRecoveryMessage
            )
        }
        guard !isCapturingPasswordInput else {
            throw TerminalMCPCommandError.rejected(
                "Terminal automation is unavailable while an interactive password prompt is active."
            )
        }

        let request = try TerminalMCPCommandRequest(
            command: command,
            timeoutSeconds: timeoutSeconds,
            maxOutputBytes: maxOutputBytes
        )
        return try await enqueueStructuredCommand(
            request,
            origin: .humanBroadcast(batchID: batchID),
            expectedLaunchID: expectedGeneration
        )
    }

    func recentTranscriptTail(maxBytes: Int) -> (text: String, truncated: Bool) {
        TerminalMCPCommandEnvelope.truncate(transcript, maxBytes: maxBytes)
    }

    func resize(columns: UInt16 = 120, rows: UInt16 = 32) {
        desiredColumns = columns
        desiredRows = rows
        backend?.resize(columns: columns, rows: rows)
    }

    /// A timed-out or partially written structured command may leave the
    /// shell inside a foreground program. Keep trusted automation authorized
    /// but paused until the user has manually returned this pane to a prompt.
    func canConfirmStructuredCommandRecovery(id recoveryID: UUID) -> Bool {
        guard let recovery = structuredCommandRecovery,
              recovery.id == recoveryID,
              isRunning,
              backend != nil,
              activeLaunchID == recovery.launchID,
              broadcastReservationID == nil,
              activeStructuredCommandID == nil,
              queuedMCPCommands.isEmpty,
              !isCapturingPasswordInput else {
            return false
        }
        return true
    }

    @discardableResult
    func confirmStructuredCommandRecovery(id recoveryID: UUID) -> Bool {
        guard canConfirmStructuredCommandRecovery(id: recoveryID) else {
            return false
        }
        structuredCommandRecovery = nil
        recentOutputForPrompt = ""
        appendSessionMessage(
            "Terminal automation resumed after the user confirmed this pane is back at a shell prompt."
        )
        return true
    }

    func stop() {
        cancelPendingSSHStart()
        cancelScheduledReconnect()
        lastLaunchConfiguration = nil
        reconnectAttempt = 0
        stopActiveBackend()
        reconnectStatus = ""

        if transcript.isEmpty {
            transcript = "PTY-backed SSH session is stopped."
        }
        if rawTranscript.isEmpty {
            rawTranscript = transcript
        }
    }

    private func stopActiveBackend() {
        // Give the backend a synchronous opportunity to flush any bytes it
        // has already accepted before invalidating this launch. In particular,
        // the ordered PTY adapter may still be holding a split gate token or the
        // final bytes of a split UTF-8 scalar.
        backend?.stop()
        flushPendingDecodedOutput()
        flushPendingSensitiveOutput()
        activeLaunchID = nil
        backend = nil
        cleanupActiveAskpassContext()
        isRunning = false
        pid = nil
        isMCPControlEnabled = false
        isBroadcastReady = false
        structuredCommandRecovery = nil
        broadcastReservationID = nil
        activeStructuredCommandID = nil
        structuredCommandActivity = .idle
        updateStructuredCommandBusyState()
        mcpDisplaySuppression = nil
        credentialSaveAccount = nil
        credentialSaveLabel = nil
        isCapturingPasswordInput = false
        capturedPasswordInput = ""
        sensitiveInputEchoRedactor = nil
        outputDecoder = TerminalUTF8StreamDecoder()
        recentOutputForPrompt = ""
        currentLaunchOutput = ""
        failQueuedMCPCommands(TerminalMCPCommandError.notRunning)
    }

    /// A saved server password must never be offered to an SSH private-key
    /// passphrase prompt. Match only a password prompt at the active line tail.
    nonisolated static func containsServerPasswordPrompt(_ text: String) -> Bool {
        let activeLine = text
            .split(whereSeparator: \Character.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return activeLine.hasSuffix("password:")
            && !activeLine.contains("passphrase for key")
    }

    /// ProxyJump authentication shares the destination PTY. An automatic
    /// response cannot safely determine which server requested the password.
    nonisolated static func allowsSavedServerPasswordAutofill(jumpHost: String) -> Bool {
        jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleOutput(_ bytes: [UInt8], launchID: UUID) {
        guard activeLaunchID == launchID else { return }
        let text = outputDecoder.decode(bytes[...])
        appendDecodedProcessOutput(text, detectCredentialPrompt: true)
    }

    private func appendDecodedProcessOutput(
        _ text: String,
        detectCredentialPrompt: Bool
    ) {
        guard !text.isEmpty else { return }
        let safeText = redactSensitiveInputEcho(in: text)
        appendProcessOutput(safeText, detectCredentialPrompt: detectCredentialPrompt)
    }

    private func flushPendingDecodedOutput() {
        let finalText = outputDecoder.finish()
        appendDecodedProcessOutput(finalText, detectCredentialPrompt: false)
    }

    private func appendProcessOutput(
        _ text: String,
        detectCredentialPrompt: Bool
    ) {
        guard !text.isEmpty else { return }
        if mcpDisplaySuppression == nil {
            appendRawTranscript(text)
        }
        appendCurrentLaunchOutput(text)

        if detectCredentialPrompt,
           mcpDisplaySuppression == nil,
           activeStructuredCommandID == nil,
           broadcastReservationID == nil {
            let promptText = outputTailForPromptDetection(appending: text)
            if credentialSaveAccount != nil,
               !isCapturingPasswordInput,
               Self.containsServerPasswordPrompt(promptText) {
                beginPasswordCapture()
            }
        }

        if var suppression = mcpDisplaySuppression {
            suppression.append(text)
            mcpDisplaySuppression = suppression
        } else {
            transcript += text
        }
    }

    private func redactSensitiveInputEcho(in text: String) -> String {
        guard var redactor = sensitiveInputEchoRedactor else { return text }
        let safeText = redactor.redact(text)
        sensitiveInputEchoRedactor = redactor.isComplete ? nil : redactor
        return safeText
    }

    private func flushPendingSensitiveOutput() {
        guard var redactor = sensitiveInputEchoRedactor else { return }
        sensitiveInputEchoRedactor = nil
        let safeText = redactor.finish()
        appendProcessOutput(safeText, detectCredentialPrompt: false)
    }

    private func appendCurrentLaunchOutput(_ text: String) {
        currentLaunchOutput += text
        if currentLaunchOutput.count > Self.maximumCurrentLaunchOutputCharacters {
            currentLaunchOutput = String(
                currentLaunchOutput.suffix(Self.maximumCurrentLaunchOutputCharacters)
            )
        }
    }

    private func appendRawTranscript(_ text: String) {
        rawTranscript += text
        if rawTranscript.count > Self.maximumRawTranscriptCharacters {
            rawTranscript = String(
                rawTranscript.suffix(Self.maximumRawTranscriptCharacters)
            )
        }
    }

    private func outputTailForPromptDetection(appending text: String) -> String {
        recentOutputForPrompt += text
        if recentOutputForPrompt.count > 512 {
            recentOutputForPrompt = String(recentOutputForPrompt.suffix(512))
        }
        return recentOutputForPrompt
    }

    private func beginPasswordCapture() {
        isCapturingPasswordInput = true
        capturedPasswordInput = ""
        sensitiveInputEchoRedactor = TerminalSensitiveInputEchoRedactor()
        recentOutputForPrompt = ""
        failQueuedMCPCommands(
            TerminalMCPCommandError.rejected(
                "Terminal automation is unavailable while an interactive password prompt is active."
            )
        )
    }

    private func capturePasswordInput(from text: String) {
        guard isCapturingPasswordInput else { return }

        sensitiveInputEchoRedactor?.recordInput(text)

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 10, 13:
                finishPasswordCapture()
                return
            case 8, 127:
                if !capturedPasswordInput.isEmpty {
                    capturedPasswordInput.removeLast()
                }
            case 0..<32:
                continue
            default:
                capturedPasswordInput.unicodeScalars.append(scalar)
            }
        }
    }

    private func finishPasswordCapture() {
        isCapturingPasswordInput = false
        let capturedSecret = capturedPasswordInput
        capturedPasswordInput = ""
        sensitiveInputEchoRedactor?.submit(secret: capturedSecret)

        guard !capturedSecret.isEmpty,
              let account = credentialSaveAccount else {
            return
        }

        pendingCredentialSaveRequest = PendingCredentialSaveRequest(
            account: account,
            label: credentialSaveLabel ?? account,
            secret: capturedSecret
        )
    }

    func savePendingCredential() {
        guard let request = pendingCredentialSaveRequest else { return }
        pendingCredentialSaveRequest = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SSHCredentialVaultAccess.save(
                        secret: request.secret,
                        account: request.account
                    )
                }.value
            } catch {
                appendSessionMessage("failed to save password: \(error.localizedDescription)")
            }
        }
    }

    func discardPendingCredentialSaveRequest() {
        pendingCredentialSaveRequest = nil
    }

    private func finish(status: Int32?, launchID: UUID) {
        guard activeLaunchID == launchID else { return }
        finalizeTermination(status: status, launchID: launchID)
    }

    private func finalizeTermination(status: Int32?, launchID: UUID) {
        guard activeLaunchID == launchID else { return }
        flushPendingDecodedOutput()
        flushPendingSensitiveOutput()
        let launchOutput = currentLaunchOutput
        let credentialDeliveryState = credentialDeliverySnapshotter(
            activeAskpassContext
        )
        activeLaunchID = nil
        cleanupActiveAskpassContext()
        isRunning = false
        pid = nil
        isMCPControlEnabled = false
        isBroadcastReady = false
        structuredCommandRecovery = nil
        broadcastReservationID = nil
        activeStructuredCommandID = nil
        structuredCommandActivity = .idle
        updateStructuredCommandBusyState()
        mcpDisplaySuppression = nil
        credentialSaveAccount = nil
        credentialSaveLabel = nil
        isCapturingPasswordInput = false
        capturedPasswordInput = ""
        sensitiveInputEchoRedactor = nil
        outputDecoder = TerminalUTF8StreamDecoder()
        recentOutputForPrompt = ""
        currentLaunchOutput = ""
        backend = nil
        let statusLabel = status.map(String.init) ?? "unknown"
        appendSessionMessage("PTY session exited with status \(statusLabel)")
        if let configuration = lastLaunchConfiguration,
           status != 0 {
            let isAuthenticationFailure = Self.isTerminalSSHAuthenticationFailure(
                executable: configuration.executable,
                status: status,
                output: launchOutput
            )
            if isAuthenticationFailure {
                appendCredentialDeliveryDiagnostic(credentialDeliveryState)
            }
            if configuration.passwordSource == .userEnteredCredential {
                let message: String
                if isAuthenticationFailure,
                   credentialDeliveryState == .helperCompletedResponse {
                    message = "Server rejected password authentication after JTS Terminal sent the complete password. JTS Terminal will not open another password prompt automatically. Verify the exact characters, username, server address, and server authentication settings, then reconnect when ready."
                } else {
                    // Final PTY bytes can arrive after process termination
                    // under heavy scheduler load. Even when the exact SSH
                    // error is not yet classifiable, never turn one explicit
                    // user submission into an unattended retry loop.
                    message = "The SSH attempt using the password you just entered ended before the connection was established. JTS Terminal will not open another password prompt automatically. Review the terminal error and reconnect when ready."
                }
                stopAutomaticReconnect(message: message)
                return
            }
            if configuration.autoReconnect, isAuthenticationFailure {
                if credentialDeliveryState == .helperCompletedResponse,
                   configuration.passwordSource == .storedCredential,
                   let account = configuration.askpassCredentialAccount,
                   let recoveryTemplate = configuration.credentialRecoveryTemplate,
                   recoveryTemplate.credentialAccount == account {
                    stopAutomaticReconnect(
                        message: "Auto reconnect stopped: SSH rejected password authentication after the saved credential was supplied. The saved password was retained. Replace it in the password prompt, or verify the username and server settings."
                    )
                    presentRejectedSavedPasswordPrompt(using: recoveryTemplate)
                } else if credentialDeliveryState == .helperNotCompleted {
                    stopAutomaticReconnect(
                        message: "Auto reconnect stopped: the local password helper did not complete password delivery. This does not prove the password was wrong. The saved credential was retained; check the app/helper installation and signing before retrying."
                    )
                } else {
                    stopAutomaticReconnect(
                        message: "Auto reconnect stopped: SSH authentication was rejected. Verify the saved username, password, or SSH key in Server Properties before reconnecting."
                    )
                }
                return
            }
            if configuration.autoReconnect,
               Self.isTerminalSSHHostKeyFailure(
                   executable: configuration.executable,
                   status: status,
                   output: launchOutput
               ) {
                stopAutomaticReconnect(
                    message: "Auto reconnect stopped: SSH host key verification failed. Verify the server identity and reconnect this tab so JTS Terminal can retry its private managed host key store."
                )
                return
            }
        }
        if shouldReconnect(after: status),
           let configuration = lastLaunchConfiguration {
            scheduleReconnect(after: status, configuration: configuration)
        }
    }

    private func appendCredentialDeliveryDiagnostic(
        _ state: SSHCredentialDeliveryState
    ) {
        switch state {
        case .notApplicable:
            return
        case .helperNotCompleted:
            appendSessionMessage(
                "OpenSSH ended authentication before the signed JTS Terminal helper confirmed a complete password response; no password rejection is inferred."
            )
        case .helperCompletedResponse:
            appendSessionMessage(
                "JTS Terminal sent the complete one-time password to OpenSSH; the server still rejected authentication for this account."
            )
        }
    }

    private func drainMCPCommandQueue() {
        guard activeStructuredCommandID == nil,
              !queuedMCPCommands.isEmpty else {
            return
        }

        let queued = queuedMCPCommands.removeFirst()
        if let error = structuredCommandAvailabilityError(
            origin: queued.origin,
            expectedLaunchID: queued.expectedLaunchID
        ) {
            queued.continuation.resume(throwing: error)
            drainMCPCommandQueue()
            return
        }
        activeStructuredCommandID = queued.id
        structuredCommandActivity = StructuredCommandActivity(
            launchID: queued.expectedLaunchID,
            commandID: queued.id,
            phase: .preparing
        )
        updateStructuredCommandBusyState()
        Task { @MainActor in
            let outcome: Result<TerminalMCPCommandResult, Error>
            do {
                outcome = .success(
                    try await performMCPCommand(
                        queued.request,
                        origin: queued.origin,
                        expectedLaunchID: queued.expectedLaunchID,
                        commandID: queued.id
                    )
                )
            } catch {
                outcome = .failure(error)
            }
            cancelledStructuredCommandIDs.remove(queued.id)
            if activeStructuredCommandID == queued.id {
                activeStructuredCommandID = nil
                structuredCommandActivity = .idle
                updateStructuredCommandBusyState()
            }
            switch outcome {
            case .success(let result):
                queued.continuation.resume(returning: result)
            case .failure(let error):
                queued.continuation.resume(throwing: error)
            }
            drainMCPCommandQueue()
        }
    }

    private func enqueueStructuredCommand(
        _ request: TerminalMCPCommandRequest,
        origin: StructuredCommandOrigin,
        expectedLaunchID: UUID
    ) async throws -> TerminalMCPCommandResult {
        let commandID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(
                        throwing: TerminalMCPCommandError.executionInterrupted(
                            reason: "Terminal command execution was cancelled.",
                            didWriteCommandBytes: false
                        )
                    )
                    return
                }
                if let error = structuredCommandAvailabilityError(
                    origin: origin,
                    expectedLaunchID: expectedLaunchID
                ) {
                    continuation.resume(throwing: error)
                    return
                }
                queuedMCPCommands.append(QueuedMCPCommand(
                    id: commandID,
                    request: request,
                    origin: origin,
                    expectedLaunchID: expectedLaunchID,
                    continuation: continuation
                ))
                drainMCPCommandQueue()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelStructuredCommand(commandID: commandID)
            }
        }
    }

    private func structuredCommandAvailabilityError(
        origin: StructuredCommandOrigin,
        expectedLaunchID: UUID
    ) -> TerminalMCPCommandError? {
        guard isRunning,
              backend != nil,
              activeLaunchID == expectedLaunchID else {
            return .executionInterrupted(
                reason: "The terminal process changed before the command started.",
                didWriteCommandBytes: false
            )
        }
        if requiresStructuredCommandRecovery {
            return .rejected(Self.structuredCommandRecoveryMessage)
        }
        if isCapturingPasswordInput {
            return .rejected(
                "Terminal automation is unavailable while an interactive password prompt is active."
            )
        }
        switch origin {
        case .mcp:
            guard broadcastReservationID == nil else {
                return .rejected(
                    "This terminal is reserved by a confirmed Multi-Exec batch."
                )
            }
        case .humanBroadcast(let batchID):
            guard broadcastReservationID == batchID else {
                return .executionInterrupted(
                    reason: "The Multi-Exec reservation expired before the command started.",
                    didWriteCommandBytes: false
                )
            }
        }
        return nil
    }

    private func cancelStructuredCommand(commandID: UUID) {
        if let queuedIndex = queuedMCPCommands.firstIndex(where: { $0.id == commandID }) {
            let queued = queuedMCPCommands.remove(at: queuedIndex)
            queued.continuation.resume(
                throwing: TerminalMCPCommandError.executionInterrupted(
                    reason: "Terminal command execution was cancelled.",
                    didWriteCommandBytes: false
                )
            )
            return
        }

        guard activeStructuredCommandID == commandID else { return }
        cancelledStructuredCommandIDs.insert(commandID)
        backend?.send("\u{3}")
    }

    private func performMCPCommand(
        _ request: TerminalMCPCommandRequest,
        origin: StructuredCommandOrigin,
        expectedLaunchID: UUID,
        commandID: UUID
    ) async throws -> TerminalMCPCommandResult {
        var didWriteCommandBytes = false
        var didReturnToShellPrompt = false
        let executionState = StructuredCommandExecutionState()
        try validateStructuredCommandExecution(
            commandID: commandID,
            origin: origin,
            expectedLaunchID: expectedLaunchID,
            didWriteCommandBytes: didWriteCommandBytes
        )

        let startSentinel = "__JTS_MCP_START_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let endSentinel = "__JTS_MCP_END_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let started = Date()
        mcpDisplaySuppression = MCPDisplaySuppression(
            commandID: commandID,
            startSentinel: startSentinel,
            endSentinel: endSentinel,
            maximumCaptureCharacters: max(request.maxOutputBytes + 65_536, 131_072),
            displaysOutputInTerminal: origin.isMCP
        )
        recentOutputForPrompt = ""
        defer {
            cleanupInterruptedStructuredCommand(
                commandID: commandID,
                expectedLaunchID: expectedLaunchID,
                executionState: executionState
            )
            if (executionState.echoMayBeDisabled || didWriteCommandBytes),
               !didReturnToShellPrompt {
                requireStructuredCommandRecovery(
                    expectedLaunchID: expectedLaunchID,
                    commandID: commandID,
                    reason: .interrupted
                )
            }
        }

        try await suppressMCPInputEcho(
            commandID: commandID,
            origin: origin,
            expectedLaunchID: expectedLaunchID,
            didWriteCommandBytes: didWriteCommandBytes,
            executionState: executionState
        )
        let wrappedCommand = TerminalMCPCommandEnvelope.wrappedCommand(
            command: request.command,
            startSentinel: startSentinel,
            endSentinel: endSentinel,
            restoreEcho: executionState.echoMayBeDisabled
        )
        for chunk in TerminalMCPCommandEnvelope.inputChunks(for: wrappedCommand) {
            try validateStructuredCommandExecution(
                commandID: commandID,
                origin: origin,
                expectedLaunchID: expectedLaunchID,
                didWriteCommandBytes: didWriteCommandBytes
            )
            didWriteCommandBytes = true
            structuredCommandActivity = StructuredCommandActivity(
                launchID: expectedLaunchID,
                commandID: commandID,
                phase: .commandBytesWritten
            )
            backend?.send(chunk)
            try await waitForStructuredCommandPoll(
                .milliseconds(10),
                commandID: commandID,
                origin: origin,
                expectedLaunchID: expectedLaunchID,
                didWriteCommandBytes: didWriteCommandBytes
            )
        }

        let deadline = Date().addingTimeInterval(request.timeoutSeconds)
        while Date() < deadline {
            try validateStructuredCommandExecution(
                commandID: commandID,
                origin: origin,
                expectedLaunchID: expectedLaunchID,
                didWriteCommandBytes: didWriteCommandBytes
            )
            if let parsed = parsedStructuredCommandCapture(commandID: commandID) {
                let output = TerminalMCPCommandEnvelope.truncate(
                    parsed.stdout,
                    maxBytes: request.maxOutputBytes
                )
                completeStructuredCommandCapture(
                    commandID: commandID,
                    output: parsed.stdout,
                    captureWasTruncated: parsed.captureWasTruncated
                )
                didReturnToShellPrompt = true
                return TerminalMCPCommandResult(
                    exitCode: parsed.exitCode,
                    stdout: output.text,
                    truncated: output.truncated || parsed.captureWasTruncated,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    timedOut: false,
                    didWriteCommandBytes: didWriteCommandBytes
                )
            }

            try await waitForStructuredCommandPoll(
                .milliseconds(50),
                commandID: commandID,
                origin: origin,
                expectedLaunchID: expectedLaunchID,
                didWriteCommandBytes: didWriteCommandBytes
            )
        }

        try validateStructuredCommandExecution(
            commandID: commandID,
            origin: origin,
            expectedLaunchID: expectedLaunchID,
            didWriteCommandBytes: didWriteCommandBytes
        )
        backend?.send("\u{3}")
        restoreMCPInputEchoIfNeeded(
            commandID: commandID,
            expectedLaunchID: expectedLaunchID,
            executionState: executionState
        )
        let timedOutOutput = capturedStructuredCommandOutput(commandID: commandID)
        let limitedTimedOutOutput = TerminalMCPCommandEnvelope.truncate(
            timedOutOutput.text,
            maxBytes: request.maxOutputBytes
        )
        switch origin {
        case .mcp:
            discardSuppressedMCPDisplayOutput(
                commandID: commandID,
                message: "MCP command timed out; terminal automation is paused until this pane is manually returned to a shell prompt."
            )
        case .humanBroadcast:
            isBroadcastReady = false
            discardSuppressedMCPDisplayOutput(
                commandID: commandID,
                message: "Multi-Exec command timed out; terminal automation is paused until this pane is manually returned to a shell prompt."
            )
        }
        requireStructuredCommandRecovery(
            expectedLaunchID: expectedLaunchID,
            commandID: commandID,
            reason: .timedOut
        )
        return TerminalMCPCommandResult(
            exitCode: -1,
            stdout: limitedTimedOutOutput.text,
            truncated: limitedTimedOutOutput.truncated || timedOutOutput.captureWasTruncated,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            timedOut: true,
            didWriteCommandBytes: didWriteCommandBytes
        )
    }

    private func suppressMCPInputEcho(
        commandID: UUID,
        origin: StructuredCommandOrigin,
        expectedLaunchID: UUID,
        didWriteCommandBytes: Bool,
        executionState: StructuredCommandExecutionState
    ) async throws {
        try validateStructuredCommandExecution(
            commandID: commandID,
            origin: origin,
            expectedLaunchID: expectedLaunchID,
            didWriteCommandBytes: didWriteCommandBytes
        )
        let sentinel = "__JTS_MCP_ECHO_OFF_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        // This state change and the PTY write are one non-suspending
        // MainActor operation. Cancellation can never hide an echo-off write
        // from the command-owned cleanup state.
        executionState.echoMayBeDisabled = true
        structuredCommandActivity = StructuredCommandActivity(
            launchID: expectedLaunchID,
            commandID: commandID,
            phase: .echoProbeSent
        )
        backend?.send("stty -echo 2>/dev/null || true; printf '\\n%s\\n' \(SSHCommandBuilder.shellQuote(sentinel))\r")

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if structuredCommandCaptureContainsLine(sentinel, commandID: commandID) {
                return
            }
            try validateStructuredCommandExecution(
                commandID: commandID,
                origin: origin,
                expectedLaunchID: expectedLaunchID,
                didWriteCommandBytes: didWriteCommandBytes
            )
            try await waitForStructuredCommandPoll(
                .milliseconds(25),
                commandID: commandID,
                origin: origin,
                expectedLaunchID: expectedLaunchID,
                didWriteCommandBytes: didWriteCommandBytes
            )
        }
        // A stalled shell may not have reached the echo-off command. Never
        // queue user command bytes behind an unconfirmed probe on timeout.
        throw TerminalMCPCommandError.executionInterrupted(
            reason: "Terminal input echo suppression could not be confirmed.",
            didWriteCommandBytes: didWriteCommandBytes
        )
    }

    private func waitForStructuredCommandPoll(
        _ duration: Duration,
        commandID: UUID,
        origin: StructuredCommandOrigin,
        expectedLaunchID: UUID,
        didWriteCommandBytes: Bool
    ) async throws {
        do {
            try await Task.sleep(for: duration)
        } catch is CancellationError {
            throw TerminalMCPCommandError.executionInterrupted(
                reason: "Terminal command execution was cancelled.",
                didWriteCommandBytes: didWriteCommandBytes
            )
        }
        try validateStructuredCommandExecution(
            commandID: commandID,
            origin: origin,
            expectedLaunchID: expectedLaunchID,
            didWriteCommandBytes: didWriteCommandBytes
        )
    }

    private func restoreMCPInputEchoIfNeeded(
        commandID: UUID,
        expectedLaunchID: UUID,
        executionState: StructuredCommandExecutionState
    ) {
        guard executionState.echoMayBeDisabled,
              !executionState.didSendEchoRestore,
              isRunning,
              backend != nil,
              activeLaunchID == expectedLaunchID,
              activeStructuredCommandID == commandID else {
            return
        }
        executionState.didSendEchoRestore = true
        // Cancellation already writes one VINTR byte, but it may land while
        // the foreground program is transitioning between children. Send one
        // final bounded interrupt before queuing the shell-side echo restore;
        // otherwise the restore can remain behind a still-running foreground
        // command and leave the terminal non-echoing when manual control
        // resumes.
        backend?.send("\u{3}")
        backend?.send("stty echo 2>/dev/null || true\r")
    }

    private func validateStructuredCommandExecution(
        commandID: UUID,
        origin: StructuredCommandOrigin,
        expectedLaunchID: UUID,
        didWriteCommandBytes: Bool
    ) throws {
        if Task.isCancelled || cancelledStructuredCommandIDs.contains(commandID) {
            throw TerminalMCPCommandError.executionInterrupted(
                reason: "Terminal command execution was cancelled.",
                didWriteCommandBytes: didWriteCommandBytes
            )
        }
        guard activeStructuredCommandID == commandID,
              activeLaunchID == expectedLaunchID,
              isRunning,
              backend != nil else {
            throw TerminalMCPCommandError.executionInterrupted(
                reason: "The terminal process changed while the command was running.",
                didWriteCommandBytes: didWriteCommandBytes
            )
        }
        if case .humanBroadcast(let batchID) = origin,
           broadcastReservationID != batchID {
            throw TerminalMCPCommandError.executionInterrupted(
                reason: "The Multi-Exec reservation expired while the command was running.",
                didWriteCommandBytes: didWriteCommandBytes
            )
        }
    }

    private func structuredCommandCaptureContainsLine(
        _ text: String,
        commandID: UUID
    ) -> Bool {
        guard let suppression = mcpDisplaySuppression,
              suppression.commandID == commandID else {
            return false
        }
        let captured = suppression.didDropMiddle
            ? suppression.bufferedOutput + suppression.trailingOutput
            : suppression.bufferedOutput
        return captured
            .split(whereSeparator: { $0.isNewline })
            .contains { line in
                line == text
            }
    }

    private func parsedStructuredCommandCapture(
        commandID: UUID
    ) -> (stdout: String, exitCode: Int, captureWasTruncated: Bool)? {
        guard let suppression = mcpDisplaySuppression,
              suppression.commandID == commandID else {
            return nil
        }
        let captured = suppression.didDropMiddle
            ? suppression.bufferedOutput + suppression.trailingOutput
            : suppression.bufferedOutput
        guard let parsed = TerminalMCPCommandEnvelope.parse(
            transcript: captured,
            baselineCharacterCount: 0,
            startSentinel: suppression.startSentinel,
            endSentinel: suppression.endSentinel
        ) else {
            return nil
        }
        return (
            stdout: parsed.stdout,
            exitCode: parsed.exitCode,
            captureWasTruncated: suppression.didDropMiddle
        )
    }

    private func capturedStructuredCommandOutput(
        commandID: UUID
    ) -> (text: String, captureWasTruncated: Bool) {
        guard let suppression = mcpDisplaySuppression,
              suppression.commandID == commandID else {
            return ("", false)
        }
        let captured = suppression.didDropMiddle
            ? suppression.bufferedOutput + suppression.trailingOutput
            : suppression.bufferedOutput
        return (
            TerminalMCPCommandEnvelope.displayTranscript(
                from: captured,
                startSentinel: suppression.startSentinel,
                endSentinel: suppression.endSentinel
            ),
            suppression.didDropMiddle
        )
    }

    private func completeStructuredCommandCapture(
        commandID: UUID,
        output: String,
        captureWasTruncated: Bool
    ) {
        guard let suppression = mcpDisplaySuppression,
              suppression.commandID == commandID else {
            return
        }
        mcpDisplaySuppression = nil
        if suppression.displaysOutputInTerminal {
            if !transcriptEndsWithLineBreak {
                transcript += "\r\n"
            }
            transcript += output
            if captureWasTruncated {
                appendSessionMessage("Terminal command display output was truncated.")
            }
        } else {
            appendSessionMessage(
                "Multi-Exec command completed; captured output is available only in the current results panel."
            )
        }
    }

    private func cleanupInterruptedStructuredCommand(
        commandID: UUID,
        expectedLaunchID: UUID,
        executionState: StructuredCommandExecutionState
    ) {
        guard mcpDisplaySuppression?.commandID == commandID else { return }
        restoreMCPInputEchoIfNeeded(
            commandID: commandID,
            expectedLaunchID: expectedLaunchID,
            executionState: executionState
        )
        mcpDisplaySuppression = nil
    }

    private func requireStructuredCommandRecovery(
        expectedLaunchID: UUID,
        commandID: UUID,
        reason: StructuredCommandRecovery.Reason
    ) {
        guard isRunning,
              backend != nil,
              activeLaunchID == expectedLaunchID else {
            return
        }
        let didAlreadyRequireRecovery = requiresStructuredCommandRecovery
        if !didAlreadyRequireRecovery {
            structuredCommandRecovery = StructuredCommandRecovery(
                launchID: expectedLaunchID,
                commandID: commandID,
                reason: reason
            )
        }
        isBroadcastReady = false
        failQueuedMCPCommands(
            TerminalMCPCommandError.rejected(
                Self.structuredCommandRecoveryMessage
            )
        )
        if !didAlreadyRequireRecovery {
            appendSessionMessage(
                "Terminal automation paused because a structured command may not have returned to the shell prompt. Use the terminal manually, then confirm recovery in the pane header."
            )
        }
    }

    private func discardSuppressedMCPDisplayOutput(
        commandID: UUID,
        message: String
    ) {
        guard mcpDisplaySuppression?.commandID == commandID else { return }
        mcpDisplaySuppression = nil
        appendSessionMessage(message)
    }

    private var transcriptEndsWithLineBreak: Bool {
        guard let last = transcript.unicodeScalars.last else { return true }
        return last.value == 10 || last.value == 13
    }

    private func failQueuedMCPCommands(
        _ error: Error,
        where shouldFail: (QueuedMCPCommand) -> Bool = { _ in true }
    ) {
        guard !queuedMCPCommands.isEmpty else { return }
        let failed = queuedMCPCommands.filter(shouldFail)
        queuedMCPCommands.removeAll(where: shouldFail)
        for command in failed {
            command.continuation.resume(throwing: error)
        }
    }

    private func updateStructuredCommandBusyState() {
        isStructuredCommandBusy =
            activeStructuredCommandID != nil ||
            broadcastReservationID != nil
    }

    private func shouldReconnect(after status: Int32?) -> Bool {
        guard let configuration = lastLaunchConfiguration,
              configuration.autoReconnect else {
            return false
        }

        return status != 0
    }

    nonisolated static func isTerminalSSHHostKeyFailure(
        executable: String,
        status: Int32?,
        output: String
    ) -> Bool {
        guard URL(fileURLWithPath: executable).lastPathComponent == "ssh",
              status == 255 || status == (255 << 8) else {
            return false
        }

        // Only inspect the terminal tail from an actual ssh(1) exit. A user
        // may legitimately print or view these phrases earlier in an
        // interactive shell; that content must not disable reconnect later.
        let recentOutput = output
            .split(whereSeparator: \Character.isNewline)
            .suffix(16)
            .joined(separator: "\n")
            .lowercased()
        if recentOutput.contains("remote host identification has changed") {
            return true
        }
        guard recentOutput.contains("host key verification failed") else {
            return false
        }
        return recentOutput.contains("hostkeys_find_by_key_hostfile")
            || recentOutput.contains("known_hosts")
            || recentOutput.contains("operation not permitted")
            || (
                recentOutput.contains("host key is known for")
                    && recentOutput.contains("requested strict checking")
            )
    }

    nonisolated static func isTerminalSSHAuthenticationFailure(
        executable: String,
        status: Int32?,
        output: String
    ) -> Bool {
        guard URL(fileURLWithPath: executable).lastPathComponent == "ssh",
              status == 255 || status == (255 << 8) else {
            return false
        }

        let recentLines = output
            .split(whereSeparator: \Character.isNewline)
            .suffix(12)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }

        return recentLines.contains { line in
            line == "permission denied, please try again."
                || (line.contains(": permission denied (") && line.hasSuffix(")."))
                || line.contains("too many authentication failures")
                || line.contains("no supported authentication methods available")
                || line == "authentication failed."
        }
    }

    private func stopAutomaticReconnect(message: String) {
        cancelScheduledReconnect()
        reconnectStatus = ""
        appendSessionMessage(message)
    }

    private func scheduleReconnect(after status: Int32?, configuration: LaunchConfiguration) {
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delaySeconds = Self.reconnectDelaySeconds(forAttempt: reconnectAttempt)
        let statusLabel = status.map { "status \($0)" } ?? "launch failure"
        reconnectStatus = "Auto reconnect in \(Int(delaySeconds))s (attempt \(reconnectAttempt))"
        isReconnectScheduled = true
        appendSessionMessage("\(statusLabel). \(reconnectStatus).")

        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }

            let askpassContext: SSHCredentialAskpass.LaunchContext?
            if let account = configuration.askpassCredentialAccount {
                let secret: String?
                do {
                    secret = try await credentialReader(account)
                } catch {
                    guard !Task.isCancelled else { return }
                    stopAutomaticReconnect(
                        message: "Auto reconnect stopped because the local SSH credential vault could not be read: \(error.localizedDescription)."
                    )
                    return
                }
                guard !Task.isCancelled else { return }
                guard let secret, !secret.isEmpty else {
                    stopAutomaticReconnect(
                        message: "Auto reconnect stopped because the saved SSH password no longer exists. Start the connection again to choose another authentication method."
                    )
                    return
                }
                do {
                    askpassContext = try askpassContextFactory(account, secret)
                } catch {
                    stopAutomaticReconnect(
                        message: "Auto reconnect stopped because the saved SSH password could not be prepared securely: \(error.localizedDescription)."
                    )
                    return
                }
            } else {
                askpassContext = nil
            }

            guard !Task.isCancelled else {
                askpassContext?.cleanup()
                return
            }

            let nextConfiguration = configuration.withAskpassContext(askpassContext)
            reconnectStatus = "Reconnecting \(nextConfiguration.label)..."
            isReconnectScheduled = false
            start(
                nextConfiguration,
                replacingTranscript: false,
                resetReconnectAttempt: false
            )
        }
    }

    private func cancelScheduledReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnectScheduled = false
        reconnectStatus = ""
    }

    private func cancelPendingSSHStart() {
        pendingSSHStartTask?.cancel()
        pendingSSHStartTask = nil
        sshStartRequestID = nil
        pendingSSHLaunch = nil
        pendingSSHCredentialPrompt = nil
        sshCredentialPromptError = nil
        isSubmittingSSHCredential = false
        isSSHStartPending = false
    }

    private func cleanupActiveAskpassContext() {
        let context = activeAskpassContext
        activeAskpassContext = nil
        context?.cleanup()
    }

    private func appendSessionMessage(_ message: String) {
        transcript += TerminalSessionDiagnosticFormatter.suffix(
            for: message,
            after: transcript
        )
        appendRawTranscript(TerminalSessionDiagnosticFormatter.suffix(
            for: message,
            after: rawTranscript
        ))
    }

    private static let structuredCommandRecoveryMessage =
        "Terminal automation is paused because the previous command may still own the shell. Return the pane to a shell prompt manually, then confirm recovery in the pane header."

    nonisolated static func reconnectDelaySeconds(forAttempt attempt: Int) -> Double {
        min(pow(2.0, Double(max(attempt - 1, 0))), 60)
    }
}

/// Incrementally decodes a PTY byte stream without replacing a valid Unicode
/// scalar merely because its UTF-8 sequence crosses a read callback boundary.
/// Invalid complete sequences are emitted using Swift's standard replacement
/// semantics; only a syntactically viable 1...3 byte suffix is retained.
struct TerminalUTF8StreamDecoder {
    private var pendingBytes: [UInt8] = []

    mutating func decode(_ bytes: ArraySlice<UInt8>) -> String {
        pendingBytes.append(contentsOf: bytes)
        let completeCount = Self.completePrefixByteCount(in: pendingBytes)
        guard completeCount > 0 else { return "" }

        let text = String(
            decoding: pendingBytes.prefix(completeCount),
            as: UTF8.self
        )
        pendingBytes.removeFirst(completeCount)
        return text
    }

    mutating func finish() -> String {
        defer { pendingBytes.removeAll(keepingCapacity: false) }
        return String(decoding: pendingBytes, as: UTF8.self)
    }

    private static func completePrefixByteCount(in bytes: [UInt8]) -> Int {
        var index = 0
        while index < bytes.count {
            guard let length = sequenceLength(for: bytes[index]) else {
                index += 1
                continue
            }

            let remainingCount = bytes.count - index
            if remainingCount < length {
                if isViableIncompleteSequence(
                    bytes[index...],
                    expectedLength: length
                ) {
                    break
                }
                index += 1
                continue
            }

            let end = index + length
            if isValidSequence(bytes[index..<end], expectedLength: length) {
                index = end
            } else {
                // Let `String(decoding:as:)` replace this invalid lead now;
                // later valid bytes must not be held behind malformed input.
                index += 1
            }
        }
        return index
    }

    private static func sequenceLength(for lead: UInt8) -> Int? {
        switch lead {
        case 0x00...0x7F: 1
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: nil
        }
    }

    private static func isViableIncompleteSequence(
        _ bytes: ArraySlice<UInt8>,
        expectedLength: Int
    ) -> Bool {
        guard let lead = bytes.first,
              bytes.count < expectedLength else {
            return false
        }
        for (offset, byte) in bytes.dropFirst().enumerated() {
            guard isValidContinuation(
                byte,
                offsetAfterLead: offset + 1,
                lead: lead
            ) else {
                return false
            }
        }
        return true
    }

    private static func isValidSequence(
        _ bytes: ArraySlice<UInt8>,
        expectedLength: Int
    ) -> Bool {
        guard bytes.count == expectedLength,
              let lead = bytes.first else {
            return false
        }
        return bytes.dropFirst().enumerated().allSatisfy { offset, byte in
            isValidContinuation(
                byte,
                offsetAfterLead: offset + 1,
                lead: lead
            )
        }
    }

    private static func isValidContinuation(
        _ byte: UInt8,
        offsetAfterLead: Int,
        lead: UInt8
    ) -> Bool {
        guard (0x80...0xBF).contains(byte) else { return false }
        guard offsetAfterLead == 1 else { return true }

        switch lead {
        case 0xE0: return byte >= 0xA0
        case 0xED: return byte <= 0x9F
        case 0xF0: return byte >= 0x90
        case 0xF4: return byte <= 0x8F
        default: return true
        }
    }
}

/// Buffers the first PTY line after a password entry and removes it when the
/// terminal driver echoed any part of the sensitive input. This is a defense in
/// depth layer for sandbox or remote-terminal failures that prevent `ssh`/`stty`
/// from disabling kernel echo. The filter runs before both the user-visible and
/// MCP/raw transcripts, and it deliberately supports output split at arbitrary
/// UTF-8 chunk boundaries.
struct TerminalSensitiveInputEchoRedactor {
    private static let maximumBufferedBytes = 65_536

    private var pendingOutput = ""
    private var finalSecret = ""
    private var printableInputRuns: [String] = []
    private var currentPrintableInputRun = ""
    private var isSubmitted = false
    private var discardedOverflow = false

    private(set) var isComplete = false

    mutating func recordInput(_ text: String) {
        guard !isSubmitted, !isComplete else { return }

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 10, 13:
                finishPrintableInputRun()
                return
            case 0..<32, 127:
                finishPrintableInputRun()
            default:
                currentPrintableInputRun.unicodeScalars.append(scalar)
            }
        }
    }

    mutating func submit(secret: String) {
        guard !isSubmitted, !isComplete else { return }
        finishPrintableInputRun()
        finalSecret = secret
        isSubmitted = true
    }

    mutating func redact(_ output: String) -> String {
        guard !isComplete else { return output }
        pendingOutput += output
        guard isSubmitted else {
            let safeOutput = drainUnsubmittedOutputWhenItCannotBeSensitiveEcho()
            enforceBufferLimit()
            return safeOutput
        }

        guard let boundary = firstLineBoundary(in: pendingOutput) else {
            let safeOutput = releaseUnterminatedOutputWhenItCannotBeSensitiveEcho()
            if !isComplete {
                enforceBufferLimit()
            }
            return safeOutput
        }

        let firstLine = String(pendingOutput[..<boundary])
        let remainder = String(pendingOutput[boundary...])
        let suppressFirstLine = discardedOverflow || couldContainSensitiveEchoAtStart(firstLine)
        isComplete = true
        pendingOutput = ""
        clearSensitiveState()
        return suppressFirstLine
            ? trailingLineEnding(in: firstLine) + remainder
            : firstLine + remainder
    }

    mutating func finish() -> String {
        guard !isComplete else { return "" }
        // Input can be echoed before Return is pressed. Include the currently
        // typed run in the termination decision so a connection closing while
        // the user is still typing cannot flush that secret into a transcript.
        finishPrintableInputRun()
        if firstLineBoundary(in: pendingOutput) != nil {
            // A short-lived process can deliver the echoed password and its
            // response in the final callback. Process the completed echo line
            // before falling back to the conservative unterminated-line path.
            return finishCompletedLine()
        }
        if !discardedOverflow {
            let safeOutput = releaseUnterminatedOutputWhenItCannotBeSensitiveEcho()
            if isComplete {
                return safeOutput
            }
        }
        return complete(with: "")
    }

    /// Once Return has been submitted, PTY echo (when enabled) begins with the
    /// typed input and ends with a line break. If an unterminated response no
    /// longer matches any possible echoed-input prefix, it is normal remote
    /// output (commonly the first shell prompt) and can be shown immediately.
    /// This avoids holding a successful login prompt until the user types a
    /// command merely because the prompt itself has no trailing newline.
    private mutating func releaseUnterminatedOutputWhenItCannotBeSensitiveEcho() -> String {
        guard !discardedOverflow else { return "" }
        let candidates = sensitiveInputCandidates.sorted { $0.count > $1.count }
        guard !candidates.isEmpty else {
            return complete(with: pendingOutput)
        }

        if candidates.contains(where: { $0.hasPrefix(pendingOutput) }) {
            return ""
        }

        var remainder = pendingOutput
        var removedSensitivePrefix = false
        while let candidate = candidates.first(where: { remainder.hasPrefix($0) }) {
            remainder.removeFirst(candidate.count)
            removedSensitivePrefix = true
        }
        if removedSensitivePrefix {
            guard !remainder.isEmpty else { return "" }
            return complete(with: remainder)
        }

        return complete(with: pendingOutput)
    }

    /// Password capture begins as soon as the prompt is visible, before the
    /// user necessarily types anything. Do not retain unrelated server output
    /// throughout that entire interval. This variant keeps the redactor armed
    /// for later keystrokes while draining only bytes that cannot be the echo
    /// of input already sent to the PTY.
    private mutating func drainUnsubmittedOutputWhenItCannotBeSensitiveEcho() -> String {
        guard !discardedOverflow, !pendingOutput.isEmpty else { return "" }
        let candidates = activeInputCandidates.sorted { $0.count > $1.count }
        guard !candidates.isEmpty else {
            let safeOutput = pendingOutput
            pendingOutput = ""
            return safeOutput
        }

        if candidates.contains(where: { $0.hasPrefix(pendingOutput) }) {
            return ""
        }

        var remainder = pendingOutput
        var removedSensitivePrefix = false
        while let candidate = candidates.first(where: { remainder.hasPrefix($0) }) {
            remainder.removeFirst(candidate.count)
            removedSensitivePrefix = true
        }
        if removedSensitivePrefix {
            pendingOutput = ""
            return remainder
        }

        let safeOutput = pendingOutput
        pendingOutput = ""
        return safeOutput
    }

    private mutating func finishCompletedLine() -> String {
        guard let boundary = firstLineBoundary(in: pendingOutput) else {
            return complete(with: pendingOutput)
        }
        let firstLine = String(pendingOutput[..<boundary])
        let remainder = String(pendingOutput[boundary...])
        let safeOutput = discardedOverflow || couldContainSensitiveEchoAtStart(firstLine)
            ? trailingLineEnding(in: firstLine) + remainder
            : firstLine + remainder
        return complete(with: safeOutput)
    }

    private mutating func complete(with output: String) -> String {
        isComplete = true
        pendingOutput = ""
        clearSensitiveState()
        return output
    }

    private mutating func finishPrintableInputRun() {
        guard !currentPrintableInputRun.isEmpty else { return }
        printableInputRuns.append(currentPrintableInputRun)
        currentPrintableInputRun = ""
    }

    private mutating func enforceBufferLimit() {
        guard pendingOutput.utf8.count > Self.maximumBufferedBytes else { return }
        // Once the sensitive window exceeds the defensive bound, discard it
        // instead of risking a partial secret at the retained boundary. Normal
        // output resumes immediately after the first post-submit line break.
        pendingOutput = String(
            decoding: pendingOutput.utf8.suffix(Self.maximumBufferedBytes),
            as: UTF8.self
        )
        discardedOverflow = true
    }

    private var sensitiveInputCandidates: [String] {
        var candidates = printableInputRuns.filter { !$0.isEmpty }
        if !finalSecret.isEmpty {
            candidates.append(finalSecret)
        }
        return Array(Set(candidates))
    }

    private var activeInputCandidates: [String] {
        var candidates = sensitiveInputCandidates
        if !currentPrintableInputRun.isEmpty {
            candidates.append(currentPrintableInputRun)
        }
        return Array(Set(candidates))
    }

    private func couldContainSensitiveEchoAtStart(_ text: String) -> Bool {
        let content: String
        if text.hasSuffix("\r\n") {
            content = String(text.dropLast(2))
        } else if text.hasSuffix("\r") || text.hasSuffix("\n") {
            content = String(text.dropLast())
        } else {
            content = text
        }
        guard !content.isEmpty else { return false }
        return sensitiveInputCandidates.contains { candidate in
            content.hasPrefix(candidate) || candidate.hasPrefix(content)
        }
    }

    private func firstLineBoundary(in text: String) -> String.Index? {
        let scalars = text.unicodeScalars
        guard let lineEnding = scalars.firstIndex(where: {
            $0.value == 10 || $0.value == 13
        }) else {
            return nil
        }
        var boundary = scalars.index(after: lineEnding)
        if scalars[lineEnding].value == 13,
           boundary < scalars.endIndex,
           scalars[boundary].value == 10 {
            boundary = scalars.index(after: boundary)
        }
        return boundary
    }

    private func trailingLineEnding(in line: String) -> String {
        if line.hasSuffix("\r\n") { return "\r\n" }
        if line.hasSuffix("\r") { return "\r" }
        if line.hasSuffix("\n") { return "\n" }
        return ""
    }

    private mutating func clearSensitiveState() {
        finalSecret = ""
        printableInputRuns.removeAll(keepingCapacity: false)
        currentPrintableInputRun = ""
    }
}

struct LocalShellLaunchConfiguration: Equatable {
    var executable: String
    var arguments: [String]
    var label: String

    static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> LocalShellLaunchConfiguration {
        let trimmedShell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shell = trimmedShell.isEmpty ? "/bin/zsh" : trimmedShell
        // App Sandbox can deny TIOCSCTTY. zsh otherwise prints a job-control
        // warning before the first prompt; disable monitor mode explicitly
        // while preserving the interactive shell experience.
        let arguments = URL(fileURLWithPath: shell).lastPathComponent == "zsh"
            ? ["+m", "-i"]
            : ["-i"]
        return LocalShellLaunchConfiguration(
            executable: shell,
            arguments: arguments,
            label: "local shell"
        )
    }
}

private typealias TerminalOutputHandler = @MainActor ([UInt8]) -> Void
private typealias TerminalTerminationHandler = @MainActor (Int32?) -> Void

private protocol TerminalProcessBackend: AnyObject {
    var pid: pid_t? { get }
    var isRunning: Bool { get }

    func start(
        executable: String,
        arguments: [String],
        environment: [String],
        columns: UInt16,
        rows: UInt16,
        output: @escaping TerminalOutputHandler,
        termination: @escaping TerminalTerminationHandler
    ) throws
    func send(_ text: String)
    func resize(columns: UInt16, rows: UInt16)
    func stop()
}

private enum TerminalProcessBackendFactory {
    static func makeBackend() -> TerminalProcessBackend {
        #if canImport(SwiftTerm)
        return OrderedPTYProcessBackend()
        #else
        return DarwinPTYProcessBackend()
        #endif
    }
}

private enum TerminalProcessEnvironment {
    static func defaultEnvironment(overrides: [String: String] = [:]) -> [String] {
        let inherited = ProcessInfo.processInfo.environment
        var values: [String: String] = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8"
        ]

        for key in [
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "PATH",
            "TMPDIR",
            "SSH_AUTH_SOCK",
            "DISPLAY",
            "XAUTHORITY",
            "LC_ALL",
            "LC_CTYPE"
        ] {
            if let value = inherited[key], !value.isEmpty {
                values[key] = value
            }
        }

        values.merge(overrides) { _, override in override }

        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }
}

private enum TerminalProcessBackendError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return message
        }
    }
}

enum SSHPTYTerminalMode {
    static func requiresRawPreconfiguration(
        for executable: String,
        arguments: [String]
    ) -> Bool {
        guard URL(fileURLWithPath: executable).standardizedFileURL.path == "/usr/bin/ssh",
              let optionTerminator = arguments.firstIndex(of: "--") else {
            return false
        }

        let options = arguments[..<optionTerminator]
        return zip(options, options.dropFirst()).contains { option, value in
            option == "-o" && value == "RequestTTY=force"
        }
    }

    /// The App Sandbox permits the parent to configure the PTY master with
    /// `TCSANOW`, but denies OpenSSH's later `TCSADRAIN` (`TIOCSETAW`) call in
    /// the inherited child sandbox. Establish the same raw byte-stream mode
    /// before exec so keyboard input remains interactive instead of falling
    /// back to canonical, locally echoed lines.
    static func configureRawMode(on masterDescriptor: Int32) throws {
        guard masterDescriptor >= 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "The SSH PTY master descriptor is invalid."
            )
        }

        var attributes = termios()
        guard Darwin.tcgetattr(masterDescriptor, &attributes) == 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "Could not read the SSH PTY terminal mode: \(String(cString: strerror(errno)))."
            )
        }
        // Match OpenSSH's `enter_raw_mode` terminal flags exactly. The
        // child later attempts the same transition with TCSADRAIN, which the
        // App Sandbox denies; using the permitted parent-side TCSANOW path
        // leaves the SSH transport with the intended byte-stream semantics.
        attributes.c_iflag |= tcflag_t(IGNPAR)
        attributes.c_iflag &= ~tcflag_t(ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXANY | IXOFF)
        attributes.c_lflag &= ~tcflag_t(ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHONL | IEXTEN)
        attributes.c_oflag &= ~tcflag_t(OPOST)
        attributes.c_cc.16 = 1 // VMIN
        attributes.c_cc.17 = 0 // VTIME
        guard Darwin.tcsetattr(masterDescriptor, TCSANOW, &attributes) == 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "Could not configure sandbox-compatible SSH PTY input: \(String(cString: strerror(errno)))."
            )
        }

        var observed = termios()
        guard Darwin.tcgetattr(masterDescriptor, &observed) == 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "Could not verify the SSH PTY terminal mode: \(String(cString: strerror(errno)))."
            )
        }
        let forbiddenInputFlags = tcflag_t(ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXANY | IXOFF)
        let forbiddenLocalFlags = tcflag_t(ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHONL | IEXTEN)
        guard observed.c_iflag & tcflag_t(IGNPAR) != 0,
              observed.c_iflag & forbiddenInputFlags == 0,
              observed.c_lflag & forbiddenLocalFlags == 0,
              observed.c_oflag & tcflag_t(OPOST) == 0,
              observed.c_cc.16 == 1,
              observed.c_cc.17 == 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "The SSH PTY did not retain the required raw input mode."
            )
        }
    }
}

enum TerminalProcessLaunchGate {
    static let releaseToken = "JTS_PTY_READY_V1"
    static let terminalIOReadyToken = "JTS_PTY_TERMINAL_IO_READY_V1"
    static let readyFileDescriptorEnvironmentKey = "JTS_PTY_READY_FD"
    static let script = """
    IFS= read -r __jts_launch_gate || exit 126
    [ "$__jts_launch_gate" = "\(releaseToken)" ] || exit 126
    if ! [ -t 0 ] || ! [ -t 1 ]; then
        printf '%s\n' '[PTY launch blocked: the child standard streams are not attached to a pseudo-terminal.]' >&2
        exit 125
    fi
    case "${\(readyFileDescriptorEnvironmentKey):-}" in
        ''|*[!0-9]*)
            printf '%s\n' '[PTY launch blocked: the private readiness channel is invalid.]' >&2
            exit 124
            ;;
    esac
    if ! eval "printf '%s\\n' '\(terminalIOReadyToken)' >&${\(readyFileDescriptorEnvironmentKey)}"; then
        printf '%s\n' '[PTY launch blocked: the child could not acknowledge terminal I/O readiness.]' >&2
        exit 124
    fi
    if ! eval "exec ${\(readyFileDescriptorEnvironmentKey)}>&-" 2>/dev/null; then
        printf '%s\n' '[PTY launch blocked: the private readiness channel could not be closed.]' >&2
        exit 124
    fi
    unset \(readyFileDescriptorEnvironmentKey)
    exec "$@"
    """

    static var releaseBytes: [UInt8] {
        Array("\(releaseToken)\n".utf8)
    }

    static var terminalIOReadyBytes: [UInt8] {
        Array("\(terminalIOReadyToken)\n".utf8)
    }
}

private struct TerminalProcessLaunchGateEchoFilter {
    private var pending: [UInt8] = []
    private var isFiltering = true

    mutating func filter(_ output: ArraySlice<UInt8>) -> [UInt8] {
        filter(Array(output))
    }

    mutating func filter(_ output: [UInt8]) -> [UInt8] {
        guard isFiltering else { return output }
        pending.append(contentsOf: output)

        let candidates = [
            Array("\(TerminalProcessLaunchGate.releaseToken)\r\n".utf8),
            Array("\(TerminalProcessLaunchGate.releaseToken)\n".utf8),
        ]
        if let echoedToken = candidates.first(where: { pending.starts(with: $0) }) {
            let safeOutput = Array(pending.dropFirst(echoedToken.count))
            pending.removeAll(keepingCapacity: false)
            isFiltering = false
            return safeOutput
        }
        if candidates.contains(where: { $0.starts(with: pending) }) {
            return []
        }

        // A PTY with echo disabled has no gate marker in its output. As soon
        // as real process output proves this is not a marker prefix, preserve
        // it verbatim and stop filtering.
        let safeOutput = pending
        pending.removeAll(keepingCapacity: false)
        isFiltering = false
        return safeOutput
    }

    mutating func finish() -> [UInt8] {
        defer {
            pending.removeAll(keepingCapacity: false)
            isFiltering = false
        }
        return pending
    }
}

#if canImport(SwiftTerm)
private final class OrderedPTYProcessBackend: NSObject, TerminalProcessBackend, OrderedPTYProcessDelegate {
    /// `forkpty` has already allowed the requested executable to run when the
    /// parent receives its master descriptor. Starting through this tiny
    /// POSIX-shell gate keeps the real executable blocked in `read` until the
    /// parent has configured and verified the PTY. Arguments remain separate
    /// shell parameters, so no user-controlled value is interpolated into the
    /// script.
    private var process: OrderedPTYProcess?
    private var outputHandler: TerminalOutputHandler?
    private var terminationHandler: TerminalTerminationHandler?
    private var launchGateEchoFilter = TerminalProcessLaunchGateEchoFilter()
    private var windowSize = winsize(ws_row: 32, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    private let windowSizeLock = NSLock()
    var pid: pid_t? {
        guard let process, process.shellPid > 0 else { return nil }
        return process.shellPid
    }

    var isRunning: Bool {
        process?.running ?? false
    }

    deinit {
        _ = process?.terminate()
    }

    func start(
        executable: String,
        arguments: [String],
        environment: [String],
        columns: UInt16,
        rows: UInt16,
        output: @escaping TerminalOutputHandler,
        termination: @escaping TerminalTerminationHandler
    ) throws {
        stop()
        resize(columns: columns, rows: rows)
        outputHandler = output
        terminationHandler = termination
        launchGateEchoFilter = TerminalProcessLaunchGateEchoFilter()
        let requiresRawSSHMode = SSHPTYTerminalMode.requiresRawPreconfiguration(
            for: executable,
            arguments: arguments
        )

        var readyDescriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&readyDescriptors) == 0 else {
            outputHandler = nil
            terminationHandler = nil
            throw TerminalProcessBackendError.launchFailed(
                "Could not create the private PTY readiness channel: \(String(cString: strerror(errno)))."
            )
        }
        let readyReadDescriptor = readyDescriptors[0]
        var readyWriteDescriptor = readyDescriptors[1]
        defer {
            Darwin.close(readyReadDescriptor)
            if readyWriteDescriptor >= 0 {
                Darwin.close(readyWriteDescriptor)
            }
        }

        let readDescriptorFlags = Darwin.fcntl(readyReadDescriptor, F_GETFD)
        guard readDescriptorFlags >= 0,
              Darwin.fcntl(readyReadDescriptor, F_SETFD, readDescriptorFlags | FD_CLOEXEC) == 0 else {
            outputHandler = nil
            terminationHandler = nil
            throw TerminalProcessBackendError.launchFailed(
                "Could not secure the private PTY readiness channel: \(String(cString: strerror(errno)))."
            )
        }

        var gatedEnvironment = environment.filter {
            !$0.hasPrefix("\(TerminalProcessLaunchGate.readyFileDescriptorEnvironmentKey)=")
        }
        gatedEnvironment.append(
            "\(TerminalProcessLaunchGate.readyFileDescriptorEnvironmentKey)=\(readyWriteDescriptor)"
        )

        let localProcess = OrderedPTYProcess(delegate: self, dispatchQueue: .main)
        process = localProcess
        do {
            try localProcess.startProcess(
                executable: "/bin/sh",
                args: [
                    "-c",
                    TerminalProcessLaunchGate.script,
                    "jts-pty-launch-gate",
                    executable,
                ] + arguments,
                environment: gatedEnvironment,
                preservingDescriptor: readyWriteDescriptor
            ) { masterFileDescriptor, childPID in
                // Only the gated child may retain the write endpoint. Closing
                // the parent's copy also makes an early child exit observable
                // through the bounded liveness check below.
                Darwin.close(readyWriteDescriptor)
                readyWriteDescriptor = -1

                try configureAndVerifyWindowSizeBeforeExec(
                    columns: columns,
                    rows: rows,
                    on: masterFileDescriptor
                )
                if requiresRawSSHMode {
                    try SSHPTYTerminalMode.configureRawMode(
                        on: masterFileDescriptor
                    )
                }
                try releaseLaunchGate(
                    on: masterFileDescriptor,
                    bytes: TerminalProcessLaunchGate.releaseBytes
                )
                try waitForTerminalIOAcknowledgement(
                    on: readyReadDescriptor,
                    childPID: childPID
                )
            }
            guard localProcess.running else {
                throw TerminalProcessBackendError.launchFailed(
                    "The ordered PTY process could not launch \(executable)."
                )
            }
        } catch {
            _ = localProcess.terminate()
            process = nil
            outputHandler = nil
            terminationHandler = nil
            throw error
        }
    }

    func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let bytes = [UInt8](data)
        process?.send(data: bytes[...])
    }

    func resize(columns: UInt16, rows: UInt16) {
        windowSizeLock.lock()
        windowSize = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var size = windowSize
        windowSizeLock.unlock()

        process?.updateWindowSize(&size)
    }

    func stop() {
        let bufferedOutput = process?.terminate() ?? []
        if let outputHandler {
            for bytes in bufferedOutput {
                let filtered = launchGateEchoFilter.filter(bytes)
                if !filtered.isEmpty {
                    outputHandler(filtered)
                }
            }
            let finalBytes = launchGateEchoFilter.finish()
            if !finalBytes.isEmpty {
                outputHandler(finalBytes)
            }
        }
        outputHandler = nil
        terminationHandler = nil
        process = nil
    }

    func processTerminated(_ source: OrderedPTYProcess, exitCode: Int32?) {
        let output = outputHandler
        let handler = terminationHandler
        process = nil

        guard let handler else { return }
        let finalBytes = launchGateEchoFilter.finish()
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            if !finalBytes.isEmpty {
                output?(finalBytes)
            }
            handler(TerminalProcessExitStatus.exitCode(fromWaitStatus: exitCode))
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = launchGateEchoFilter.filter(slice)
        guard !bytes.isEmpty, let outputHandler else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            outputHandler(bytes)
        }
    }

    func getWindowSize() -> winsize {
        windowSizeLock.lock()
        let size = windowSize
        windowSizeLock.unlock()
        return size
    }

    /// SwiftTerm supplies `getWindowSize()` to `forkpty`, but the hosted,
    /// sandboxed process can still return a zero-sized master PTY. The real
    /// executable is waiting behind `launchGateScript` here, so applying the
    /// size is part of atomic launch configuration rather than a racy resize
    /// after user code has started.
    private func configureAndVerifyWindowSizeBeforeExec(
        columns: UInt16,
        rows: UInt16,
        on fileDescriptor: Int32
    ) throws {
        guard fileDescriptor >= 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "PTY startup did not return a valid master file descriptor."
            )
        }

        var requested = winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(fileDescriptor, TIOCSWINSZ, &requested) == 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "Could not configure the requested PTY size: \(String(cString: strerror(errno)))."
            )
        }

        var observed = winsize()
        guard ioctl(fileDescriptor, TIOCGWINSZ, &observed) == 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "Could not verify the requested PTY size: \(String(cString: strerror(errno)))."
            )
        }
        guard observed.ws_col == columns, observed.ws_row == rows else {
            throw TerminalProcessBackendError.launchFailed(
                "PTY size verification failed (requested \(columns)x\(rows), received \(observed.ws_col)x\(observed.ws_row))."
            )
        }
    }

    /// Write the exact fail-closed release token synchronously so any user
    /// keystroke sent after `start` is ordered behind the gate release. The
    /// terminal can echo this non-secret token; `dataReceived` removes only
    /// that single launch prefix before exposing process output.
    private func releaseLaunchGate(
        on fileDescriptor: Int32,
        bytes: [UInt8]
    ) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                let reason = written < 0
                    ? String(cString: strerror(errno))
                    : "the PTY accepted zero bytes"
                throw TerminalProcessBackendError.launchFailed(
                    "Could not release the configured PTY process: \(reason)."
                )
            }
        }
    }

    private static let terminalIOAcknowledgementAttemptCount = 40
    private static let terminalIOAcknowledgementPollMilliseconds: Int32 = 25

    /// App Sandbox can deny `TIOCSCTTY`, leaving the PTY master with a zero
    /// foreground group even though the child's standard streams are a fully
    /// usable pseudo-terminal. The gated shell therefore verifies its stdin
    /// and stdout are TTYs and acknowledges success over this private pipe
    /// before the requested executable can run. A plain pipe still fails
    /// closed without invoking terminal ioctls that App Sandbox rejects.
    private func waitForTerminalIOAcknowledgement(
        on fileDescriptor: Int32,
        childPID: pid_t
    ) throws {
        guard fileDescriptor >= 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "The private PTY readiness descriptor is invalid."
            )
        }
        guard childPID > 0 else {
            throw TerminalProcessBackendError.launchFailed(
                "The PTY child process identifier is invalid."
            )
        }

        var received: [UInt8] = []
        for _ in 1...Self.terminalIOAcknowledgementAttemptCount {
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Self.terminalIOAcknowledgementPollMilliseconds
            )
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw TerminalProcessBackendError.launchFailed(
                    "Could not wait for PTY terminal I/O readiness: \(String(cString: strerror(errno)))."
                )
            }
            if pollResult == 0 {
                if let reason = childLivenessFailureReason(childPID) {
                    throw TerminalProcessBackendError.launchFailed(
                        "PTY launch was blocked before terminal I/O acknowledgement: \(reason)."
                    )
                }
                continue
            }
            if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                throw TerminalProcessBackendError.launchFailed(
                    "The private PTY readiness channel failed before acknowledgement."
                )
            }

            var buffer = [UInt8](repeating: 0, count: 128)
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                received.append(contentsOf: buffer.prefix(Int(count)))
                if received.contains(10) { break }
                guard received.count <= TerminalProcessLaunchGate.terminalIOReadyBytes.count else {
                    break
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                throw TerminalProcessBackendError.launchFailed(
                    "Could not read PTY terminal I/O readiness: \(String(cString: strerror(errno)))."
                )
            }
            break
        }

        guard received == TerminalProcessLaunchGate.terminalIOReadyBytes else {
            throw TerminalProcessBackendError.launchFailed(
                "PTY launch was blocked because the child did not acknowledge verified terminal I/O."
            )
        }
    }

    private func childLivenessFailureReason(_ childPID: pid_t) -> String? {
        errno = 0
        guard Darwin.kill(childPID, 0) == 0 else {
            if errno == ESRCH {
                return "the child process exited before terminal I/O verification completed"
            }
            return "could not confirm that the child process is alive: \(String(cString: strerror(errno)))"
        }
        return nil
    }

}
#else
private final class DarwinPTYProcessBackend: TerminalProcessBackend {
    private var masterFileDescriptor: Int32 = -1
    private var childPID: pid_t = 0
    private var readerTask: Task<Void, Never>?
    private var terminationWatcher: Task<Void, Never>?

    var pid: pid_t? {
        childPID > 0 ? childPID : nil
    }

    var isRunning: Bool {
        childPID > 0
    }

    func start(
        executable: String,
        arguments: [String],
        environment: [String],
        columns: UInt16,
        rows: UInt16,
        output: @escaping TerminalOutputHandler,
        termination: @escaping TerminalTerminationHandler
    ) throws {
        stop()

        var initialSize = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var childEnvironment = ProcessInfo.processInfo.environment
        for entry in environment {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            childEnvironment[String(parts[0])] = String(parts[1])
        }
        let launch = try PTYProcessLauncher.launch(
            executable: executable,
            arguments: arguments,
            environment: childEnvironment.map { "\($0.key)=\($0.value)" },
            windowSize: &initialSize
        )
        let fileDescriptor = launch.masterFd
        let forkedPID = launch.pid

        masterFileDescriptor = fileDescriptor
        childPID = forkedPID

        let readTask = Task.detached { [fileDescriptor] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                let byteCount = Darwin.read(fileDescriptor, &buffer, buffer.count)
                guard byteCount > 0 else { break }
                await output(Array(buffer.prefix(Int(byteCount))))
            }
        }
        readerTask = readTask

        terminationWatcher = Task.detached { [forkedPID] in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = Darwin.waitpid(forkedPID, &status, 0)
            } while result < 0 && errno == EINTR
            await readTask.value
            await termination(TerminalProcessExitStatus.exitCode(
                fromWaitStatus: result == forkedPID ? status : nil
            ))
        }
    }

    func send(_ text: String) {
        guard let data = text.data(using: .utf8), masterFileDescriptor >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(
                    masterFileDescriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    break
                }
            }
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        guard masterFileDescriptor >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFileDescriptor, TIOCSWINSZ, &size)
    }

    func stop() {
        if childPID > 0 {
            kill(childPID, SIGTERM)
        }
        readerTask?.cancel()
        readerTask = nil
        terminationWatcher?.cancel()
        terminationWatcher = nil
        if masterFileDescriptor >= 0 {
            close(masterFileDescriptor)
            masterFileDescriptor = -1
        }
        childPID = 0
    }
}
#endif
