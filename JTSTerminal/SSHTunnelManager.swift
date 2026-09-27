//
//  SSHTunnelManager.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import Combine
import Foundation
import Network

enum SSHTunnelKind: String, CaseIterable, Identifiable {
    case local = "Local"
    case remote = "Remote"
    case dynamic = "Dynamic SOCKS"

    var id: String { rawValue }
}

struct SSHTunnelConfiguration: Equatable {
    var name = "Postgres Tunnel"
    var kind = SSHTunnelKind.local
    var bindAddress = "127.0.0.1"
    var localPort = 5432
    var destinationHost = "127.0.0.1"
    var destinationPort = 5432
    var autoReconnect = false

    var summary: String {
        switch kind {
        case .local:
            return "\(bindAddress):\(localPort) -> \(destinationHost):\(destinationPort)"
        case .remote:
            return "\(bindAddress):\(localPort) <- \(destinationHost):\(destinationPort)"
        case .dynamic:
            return "SOCKS \(bindAddress):\(localPort)"
        }
    }

    var localEndpointSummary: String {
        "\(bindAddress):\(localPort)"
    }

    var supportsLocalReadinessCheck: Bool {
        kind == .local || kind == .dynamic
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Tunnel name is required."
        }

        if bindAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Bind address is required."
        }

        guard (1...65535).contains(localPort) else {
            return "Local port must be between 1 and 65535."
        }

        guard kind == .dynamic || !destinationHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Destination host is required for local and remote tunnels."
        }

        guard kind == .dynamic || (1...65535).contains(destinationPort) else {
            return "Destination port must be between 1 and 65535."
        }

        return nil
    }
}

@MainActor
final class SSHTunnelManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastMessage = "Tunnel is stopped."
    @Published private(set) var pid: Int32?
    @Published private(set) var activeConfiguration: SSHTunnelConfiguration?
    @Published private(set) var isReconnectScheduled = false

    private var process: Process?
    private var errorPipe: Pipe?
    private var activeSession: RemoteSession?
    private var reconnectTask: Task<Void, Never>?
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStartRequestID: UUID?
    private var activeAskpassMarkerURL: URL?
    private var reconnectAttempt = 0
    private var manuallyStoppingProcessIdentifiers: Set<Int32> = []
    private let credentialReader: @Sendable (String) async -> String?

    /// Internal observability for the async-start generation regression test.
    /// Production behavior does not depend on this value.
    private(set) var processLaunchAttemptCountForTesting = 0

    init(
        credentialReader: @escaping @Sendable (String) async -> String? = { account in
            try? await Task.detached(priority: .userInitiated) {
                try SSHCredentialVaultAccess.read(account: account)
            }.value
        }
    ) {
        self.credentialReader = credentialReader
    }

    var hasActiveOrScheduledWork: Bool {
        isRunning || isReconnectScheduled
    }

    var runningSummary: String? {
        guard hasActiveOrScheduledWork else { return nil }
        let name = activeConfiguration?.name.nilIfBlank ?? "SSH Tunnel"
        let endpoint = activeConfiguration?.localEndpointSummary.nilIfBlank
        let pidLabel = pid.map { " pid \($0)" } ?? (isReconnectScheduled ? " reconnect pending" : "")
        if let endpoint {
            return "\(name) on \(endpoint)\(pidLabel)"
        }
        return "\(name)\(pidLabel)"
    }

    func start(session: RemoteSession, configuration: SSHTunnelConfiguration) {
        if isRunning, activeConfiguration == configuration {
            lastMessage = "Tunnel already running on \(configuration.localEndpointSummary) with PID \(pid.map(String.init) ?? "unknown")."
            return
        }

        stop(resetMessage: false)
        reconnectAttempt = 0

        if let validationMessage = configuration.validationMessage {
            isRunning = false
            pid = nil
            activeConfiguration = nil
            activeSession = nil
            lastMessage = "Cannot start tunnel: \(validationMessage)"
            return
        }

        // Keep reconnects bound to the exact destination the user started.
        // A later edit to the SwiftData model must not redirect an active or
        // scheduled tunnel to another host.
        let frozenSession = SSHSessionLaunchSnapshot(session: session).materializedSession()
        activeSession = frozenSession
        startProcessAfterLoadingCredential(session: frozenSession, configuration: configuration)
    }

    func stop() {
        stop(resetMessage: true)
    }

    private func startProcessAfterLoadingCredential(session: RemoteSession, configuration: SSHTunnelConfiguration) {
        cancelPendingStart()
        let requestID = UUID()
        pendingStartRequestID = requestID
        let destination = SSHSessionLaunchSnapshot(session: session)
        let frozenSession = destination.materializedSession()
        let account = destination.credentialAccount
        // Freeze both command variants before the vault read suspends. A model
        // edit while the read is pending must not alter the launch that was
        // explicitly requested.
        let keyArguments = SSHCommandBuilder.tunnelArguments(
            for: frozenSession,
            tunnel: configuration,
            batchMode: true,
            passwordAuthentication: false
        )
        let passwordArguments = SSHCommandBuilder.tunnelArguments(
            for: frozenSession,
            tunnel: configuration,
            batchMode: false,
            passwordAuthentication: true
        )
        let credentialReader = self.credentialReader

        pendingStartTask = Task { [weak self] in
            let secret = await credentialReader(account)
            guard let self,
                  !Task.isCancelled,
                  self.pendingStartRequestID == requestID else {
                return
            }
            self.pendingStartTask = nil
            self.pendingStartRequestID = nil
            if secret != nil, !destination.allowsSavedPasswordAutofill {
                self.isRunning = false
                self.isReconnectScheduled = false
                self.pid = nil
                self.activeConfiguration = nil
                self.activeSession = nil
                self.lastMessage = "Cannot start tunnel securely: \(RemoteCredentialRoutingError.savedPasswordCannotUseJumpHost.localizedDescription)"
                return
            }
            self.startProcess(
                session: frozenSession,
                configuration: configuration,
                account: account,
                secret: secret,
                arguments: secret == nil ? keyArguments : passwordArguments
            )
        }
    }

    private func startProcess(
        session: RemoteSession,
        configuration: SSHTunnelConfiguration,
        account: String,
        secret: String?,
        arguments: [String]
    ) {
        let process = Process()
        let errorPipe = Pipe()
        let askpassContext: SSHCredentialAskpass.LaunchContext?

        do {
            askpassContext = try secret.map {
                try SSHCredentialAskpass.launchContext(account: account, secret: $0)
            }
        } catch {
            isRunning = false
            pid = nil
            activeConfiguration = nil
            activeSession = nil
            lastMessage = "Failed to start tunnel securely: \(error.localizedDescription)"
            return
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardError = errorPipe
        if let askpassContext {
            process.environment = ProcessInfo.processInfo.environment
                .merging(askpassContext.environment) { _, new in new }
        }

        process.terminationHandler = { [weak self, errorPipe] finishedProcess in
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let terminationStatus = finishedProcess.terminationStatus
            let processIdentifier = finishedProcess.processIdentifier

            Task { @MainActor [weak self] in
                self?.finish(
                    processIdentifier: processIdentifier,
                    errorText: errorText,
                    terminationStatus: terminationStatus
                )
            }
        }

        do {
            processLaunchAttemptCountForTesting += 1
            try process.run()
            self.process = process
            self.errorPipe = errorPipe
            activeAskpassMarkerURL = askpassContext?.consumptionMarkerURL
            activeConfiguration = configuration
            activeSession = session
            isRunning = true
            isReconnectScheduled = false
            pid = process.processIdentifier
            reconnectTask?.cancel()
            reconnectTask = nil
            if configuration.supportsLocalReadinessCheck {
                lastMessage = "Tunnel process started with PID \(process.processIdentifier). Checking \(configuration.localEndpointSummary)..."
                checkReadiness(configuration: configuration, processIdentifier: process.processIdentifier)
            } else {
                lastMessage = "Tunnel started with PID \(process.processIdentifier). Remote tunnels cannot be locally probed."
            }
        } catch {
            askpassContext?.cleanup()
            isRunning = false
            pid = nil
            lastMessage = "Failed to start tunnel: \(error.localizedDescription)"
            if configuration.autoReconnect {
                scheduleReconnect(
                    session: session,
                    configuration: configuration,
                    baseMessage: lastMessage
                )
            } else {
                activeConfiguration = nil
                activeSession = nil
            }
        }
    }

    private func stop(resetMessage: Bool) {
        cancelPendingStart()
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnectScheduled = false
        if let process {
            manuallyStoppingProcessIdentifiers.insert(process.processIdentifier)
            cleanupActiveAskpassMarker()
            process.terminate()
        } else {
            cleanupActiveAskpassMarker()
        }
        self.process = nil
        errorPipe = nil
        isRunning = false
        pid = nil
        activeConfiguration = nil
        activeSession = nil
        reconnectAttempt = 0
        if resetMessage {
            lastMessage = "Tunnel stopped."
        }
    }

    private func checkReadiness(configuration: SSHTunnelConfiguration, processIdentifier: Int32) {
        Task {
            let isReady = await Self.waitForLocalEndpoint(
                host: configuration.bindAddress,
                port: configuration.localPort,
                attempts: 12,
                delayNanoseconds: 250_000_000
            )

            await MainActor.run {
                guard self.pid == processIdentifier, self.isRunning else { return }
                self.lastMessage = isReady
                    ? "Tunnel ready on \(configuration.localEndpointSummary) with PID \(processIdentifier)."
                    : "Tunnel process is running with PID \(processIdentifier), but \(configuration.localEndpointSummary) is not accepting connections yet."
            }
        }
    }

    private func finish(processIdentifier: Int32, errorText: String?, terminationStatus: Int32) {
        if manuallyStoppingProcessIdentifiers.remove(processIdentifier) != nil {
            // stop() already detached this process. A newer tunnel may have
            // launched before this callback reached MainActor, so the stale
            // callback must not clear the replacement's process or pipe.
            return
        }

        guard pid == processIdentifier || process?.processIdentifier == processIdentifier else {
            return
        }

        let finishedConfiguration = activeConfiguration
        let finishedSession = activeSession
        let message = Self.failureMessage(errorText: errorText, terminationStatus: terminationStatus)
        let hasHostKeyFailure = Self.hasTerminalHostKeyFailure(
            errorText: errorText,
            terminationStatus: terminationStatus
        )
        let hasAuthenticationFailure = Self.hasTerminalAuthenticationFailure(
            errorText: errorText,
            terminationStatus: terminationStatus
        )
        let shouldStopReconnect = hasHostKeyFailure || hasAuthenticationFailure
        cleanupActiveAskpassMarker()
        isRunning = false
        pid = nil
        if hasAuthenticationFailure {
            lastMessage = "\(message) Auto reconnect stopped to avoid repeated failed logins. Verify and save the SSH password in Server Properties, then start the tunnel again."
        } else if hasHostKeyFailure {
            lastMessage = "\(message) Auto reconnect stopped because this host key error needs a local configuration retry."
        } else {
            lastMessage = message
        }
        process = nil
        errorPipe = nil

        if let finishedConfiguration,
           let finishedSession,
           finishedConfiguration.autoReconnect,
           !shouldStopReconnect {
            scheduleReconnect(
                session: finishedSession,
                configuration: finishedConfiguration,
                baseMessage: message
            )
        } else {
            activeConfiguration = nil
            activeSession = nil
        }
    }

    private func scheduleReconnect(
        session: RemoteSession,
        configuration: SSHTunnelConfiguration,
        baseMessage: String
    ) {
        cancelPendingStart()
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delaySeconds = Self.reconnectDelaySeconds(forAttempt: reconnectAttempt)
        isReconnectScheduled = true
        activeConfiguration = configuration
        activeSession = session
        lastMessage = "\(baseMessage) Auto reconnect is enabled; retrying in \(Int(delaySeconds))s (attempt \(reconnectAttempt))."

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.isReconnectScheduled,
                      let activeSession = self.activeSession,
                      let activeConfiguration = self.activeConfiguration else {
                    return
                }
                self.isReconnectScheduled = false
                self.lastMessage = "Reconnecting tunnel \(activeConfiguration.name)..."
                self.startProcessAfterLoadingCredential(session: activeSession, configuration: activeConfiguration)
            }
        }
    }

    private func cancelPendingStart() {
        pendingStartTask?.cancel()
        pendingStartTask = nil
        pendingStartRequestID = nil
    }

    private func cleanupActiveAskpassMarker() {
        guard let markerURL = activeAskpassMarkerURL else { return }
        activeAskpassMarkerURL = nil
        try? FileManager.default.removeItem(at: markerURL)
    }

    nonisolated static func reconnectDelaySeconds(forAttempt attempt: Int) -> Double {
        min(pow(2.0, Double(max(attempt, 1) - 1)), 60)
    }

    #if DEBUG
    func simulateReconnectScheduledForTesting(configuration: SSHTunnelConfiguration) {
        reconnectTask?.cancel()
        reconnectTask = nil
        isRunning = false
        isReconnectScheduled = true
        activeConfiguration = configuration
        pid = nil
        lastMessage = "Auto reconnect is enabled; retrying in 1s (attempt 1)."
    }

    func simulateFinishedProcessForTesting(
        session: RemoteSession,
        configuration: SSHTunnelConfiguration,
        errorText: String?,
        terminationStatus: Int32
    ) {
        let simulatedPID: Int32 = 4242
        reconnectTask?.cancel()
        reconnectTask = nil
        pid = simulatedPID
        isRunning = true
        isReconnectScheduled = false
        activeSession = session
        activeConfiguration = configuration
        finish(
            processIdentifier: simulatedPID,
            errorText: errorText,
            terminationStatus: terminationStatus
        )
    }
    #endif

    static func failureMessage(errorText: String?, terminationStatus: Int32) -> String {
        guard let errorText = errorText?.nilIfBlank else {
            return "Tunnel exited with code \(terminationStatus)."
        }

        let lowercasedError = errorText.lowercased()
        if lowercasedError.contains("permission denied") {
            return "\(errorText) Check Server Properties: save the correct SSH password, verify the selected key, or confirm ssh-agent has the right identity."
        }

        if hasTerminalHostKeyFailure(
            errorText: errorText,
            terminationStatus: terminationStatus
        ) {
            return "\(errorText) SSH could not verify the server identity. Verify the server fingerprint, then restart the tunnel so JTS Terminal can retry its private managed host key store."
        }

        if lowercasedError.contains("address already in use") || lowercasedError.contains("bind") {
            return "\(errorText) The local bind address or port is already in use. Choose a different local port and start the tunnel again."
        }

        if lowercasedError.contains("forwarding failed") || lowercasedError.contains("administratively prohibited") {
            return "\(errorText) The server rejected port forwarding. Check sshd AllowTcpForwarding/PermitOpen settings or try another tunnel kind."
        }

        return errorText
    }

    nonisolated static func hasTerminalHostKeyFailure(
        errorText: String?,
        terminationStatus: Int32
    ) -> Bool {
        InteractiveProcessSession.isTerminalSSHHostKeyFailure(
            executable: "/usr/bin/ssh",
            status: terminationStatus,
            output: errorText ?? ""
        )
    }

    nonisolated static func hasTerminalAuthenticationFailure(
        errorText: String?,
        terminationStatus: Int32
    ) -> Bool {
        InteractiveProcessSession.isTerminalSSHAuthenticationFailure(
            executable: "/usr/bin/ssh",
            status: terminationStatus,
            output: errorText ?? ""
        )
    }

    static func waitForLocalEndpoint(
        host: String,
        port: Int,
        attempts: Int = 1,
        delayNanoseconds: UInt64 = 0
    ) async -> Bool {
        guard attempts > 0, (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        for attempt in 0..<attempts {
            if await canConnect(host: host, port: nwPort) {
                return true
            }

            if attempt < attempts - 1, delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        return false
    }

    private static func canConnect(host: String, port: NWEndpoint.Port) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let probeState = ConnectionProbeState()

            @Sendable func finish(_ value: Bool) {
                probeState.finish(value, connection: connection, continuation: continuation)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                finish(false)
            }
        }
    }
}

private final class ConnectionProbeState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var didResume = false

    nonisolated func finish(
        _ value: Bool,
        connection: NWConnection,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        connection.cancel()
        continuation.resume(returning: value)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
