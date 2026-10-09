//
//  MobileNativeSSHTransport.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import Foundation
@preconcurrency import Citadel
import Combine
import Crypto
import NIO
@preconcurrency import NIOSSH

enum MobileNativeSSHError: LocalizedError, Equatable {
    case incompleteProfile
    case missingAuthentication
    case unsupportedPrivateKey
    case connectionTimedOut(host: String, port: Int)
    case connectionFailed(String)
    case hostKeyNotTrusted(MobileHostKeyChallenge)

    var errorDescription: String? {
        switch self {
        case .incompleteProfile:
            return "Host, username, and port are required before connecting."
        case .missingAuthentication:
            return "Save an SSH password or import an OpenSSH private key before connecting."
        case .unsupportedPrivateKey:
            return "The private key could not be parsed. JTS Terminal iOS supports OpenSSH ED25519 and RSA private keys."
        case .connectionTimedOut(let host, let port):
            return "Connection timed out while reaching \(host):\(port). Check the address, VPN, firewall, and SSH port."
        case .connectionFailed(let message):
            return message
        case .hostKeyNotTrusted(let challenge):
            switch challenge.kind {
            case .unknown:
                return "Verify the host key of \(challenge.endpointDescription) before connecting. Fingerprint: \(challenge.fingerprint)"
            case .changed:
                return "The host key of \(challenge.endpointDescription) changed. The connection was stopped to protect your credentials."
            }
        }
    }

    var hostKeyChallenge: MobileHostKeyChallenge? {
        if case .hostKeyNotTrusted(let challenge) = self {
            return challenge
        }
        return nil
    }
}

struct MobileTerminalSize: Equatable, Sendable {
    static let initial = MobileTerminalSize(cols: 80, rows: 24)
    static let minimumColumns = 20
    static let minimumRows = 2

    let cols: Int
    let rows: Int

    var isUsable: Bool {
        cols >= Self.minimumColumns && rows >= Self.minimumRows
    }
}

enum MobileTerminalInput: Sendable {
    case bytes([UInt8])
    case resize(cols: Int, rows: Int)
}

struct MobileSSHClientLease: @unchecked Sendable {
    let id: UUID
    let client: SSHClient
}

actor MobileSSHSessionTransport {
    private struct PendingConnection {
        let id: UUID
        let task: Task<MobileSSHClientLease, Error>
    }

    private var activeLease: MobileSSHClientLease?
    private var pendingConnection: PendingConnection?

    func client(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials
    ) async throws -> MobileSSHClientLease {
        if let activeLease, activeLease.client.isConnected {
            return activeLease
        }

        if let staleLease = activeLease {
            activeLease = nil
            try? await staleLease.client.close()
        }

        if let pendingConnection {
            return try await finish(pendingConnection)
        }

        let connection = PendingConnection(
            id: UUID(),
            task: Task {
                MobileSSHClientLease(
                    id: UUID(),
                    client: try await MobileCitadelClientFactory.connect(
                        profile: profile,
                        credentials: credentials
                    )
                )
            }
        )
        pendingConnection = connection
        return try await finish(connection)
    }

    func invalidateIfDisconnected(_ leaseID: UUID) async {
        guard let activeLease,
              activeLease.id == leaseID,
              !activeLease.client.isConnected else {
            return
        }
        self.activeLease = nil
        try? await activeLease.client.close()
    }

    func disconnect() async {
        pendingConnection?.task.cancel()
        pendingConnection = nil

        guard let activeLease else { return }
        self.activeLease = nil
        try? await activeLease.client.close()
    }

    private func finish(_ connection: PendingConnection) async throws -> MobileSSHClientLease {
        do {
            let lease = try await connection.task.value
            if activeLease?.id == lease.id {
                return lease
            }

            guard pendingConnection?.id == connection.id else {
                try? await lease.client.close()
                throw CancellationError()
            }

            pendingConnection = nil
            activeLease = lease
            return lease
        } catch {
            if pendingConnection?.id == connection.id {
                pendingConnection = nil
            }
            throw error
        }
    }
}

@MainActor
final class MobileTerminalController: ObservableObject {
    @Published private(set) var state: MobileConnectionState = .disconnected
    @Published private(set) var credentialPromptReason: MobileCredentialPromptReason?
    @Published private(set) var hostKeyChallenge: MobileHostKeyChallenge?

    private let connection: MobileCitadelTerminalConnection
    private var terminalAttachment: (id: UUID, feed: ([UInt8]) -> Void)?
    private var terminalHistory: [UInt8] = []
    private var terminalSize = MobileTerminalSize.initial
    private let maximumTerminalHistoryBytes = 2 * 1_024 * 1_024

    init(sessionTransport: MobileSSHSessionTransport = MobileSSHSessionTransport()) {
        connection = MobileCitadelTerminalConnection(sessionTransport: sessionTransport)
    }

    @discardableResult
    func attachTerminal(feed: @escaping ([UInt8]) -> Void) -> UUID {
        let attachmentID = UUID()
        terminalAttachment = (attachmentID, feed)
        if !terminalHistory.isEmpty {
            feed(terminalHistory)
        }
        return attachmentID
    }

    func detachTerminal(_ attachmentID: UUID) {
        guard terminalAttachment?.id == attachmentID else { return }
        terminalAttachment = nil
    }

    func connect(profile: MobileServerProfile) {
        switch state {
        case .connecting, .connected:
            return
        case .disconnected, .failed:
            break
        }

        guard profile.isConnectable else {
            state = .failed(MobileNativeSSHError.incompleteProfile.localizedDescription)
            return
        }

        let credentials = MobileCredentialStore.credentials(for: profile)
        guard credentials.hasPassword || credentials.hasPrivateKey else {
            credentialPromptReason = .missing
            return
        }

        credentialPromptReason = nil
        hostKeyChallenge = nil
        terminalHistory.removeAll(keepingCapacity: true)
        state = .connecting
        connection.start(
            profile: profile,
            credentials: credentials,
            cols: terminalSize.cols,
            rows: terminalSize.rows,
            onOutput: { [weak self] bytes in
                self?.receive(bytes)
            },
            onStateChange: { [weak self] newState in
                self?.state = newState
            },
            onCredentialRequired: { [weak self] reason in
                self?.credentialPromptReason = reason
            },
            onHostKeyRequired: { [weak self] challenge in
                self?.hostKeyChallenge = challenge
            }
        )
    }

    func clearCredentialPrompt() {
        credentialPromptReason = nil
    }

    func clearHostKeyChallenge() {
        hostKeyChallenge = nil
    }

    func disconnect() {
        connection.stop()
        state = .disconnected
    }

    func send(_ data: ArraySlice<UInt8>) {
        connection.send(Array(data))
    }

    func resize(cols: Int, rows: Int) {
        let newSize = MobileTerminalSize(cols: cols, rows: rows)
        guard newSize.isUsable, newSize != terminalSize else { return }
        terminalSize = newSize
        connection.resize(cols: cols, rows: rows)
    }

    private func receive(_ bytes: [UInt8]) {
        terminalHistory.append(contentsOf: bytes)
        if terminalHistory.count > maximumTerminalHistoryBytes {
            terminalHistory.removeFirst(terminalHistory.count - maximumTerminalHistoryBytes)
        }
        terminalAttachment?.feed(bytes)
    }
}

@MainActor
private final class MobileCitadelTerminalConnection {
    private let sessionTransport: MobileSSHSessionTransport
    private var task: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<MobileTerminalInput>.Continuation?

    init(sessionTransport: MobileSSHSessionTransport) {
        self.sessionTransport = sessionTransport
    }

    func start(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials,
        cols: Int,
        rows: Int,
        onOutput: @escaping @MainActor ([UInt8]) -> Void,
        onStateChange: @escaping @MainActor (MobileConnectionState) -> Void,
        onCredentialRequired: @escaping @MainActor (MobileCredentialPromptReason) -> Void,
        onHostKeyRequired: @escaping @MainActor (MobileHostKeyChallenge) -> Void
    ) {
        stopPTY()
        let pendingDisconnect = disconnectTask

        let inputStream = AsyncStream<MobileTerminalInput> { continuation in
            inputContinuation = continuation
        }

        task = Task {
            do {
                await pendingDisconnect?.value
                try Task.checkCancellation()

                let lease = try await sessionTransport.client(
                    profile: profile,
                    credentials: credentials
                )

                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1])
                )

                try await lease.client.withPTY(request) { inbound, outbound in
                    onStateChange(.connected)

                    async let writer: Void = Self.consume(inputStream, outbound: outbound)
                    do {
                        for try await event in inbound {
                            switch event {
                            case .stdout(var buffer), .stderr(var buffer):
                                let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                                if !bytes.isEmpty {
                                    onOutput(bytes)
                                }
                            }
                        }
                        inputContinuation?.finish()
                        try await writer
                    } catch {
                        inputContinuation?.finish()
                        throw error
                    }
                }

                onStateChange(.disconnected)
            } catch is CancellationError {
                onStateChange(.disconnected)
            } catch {
                let message = MobileCitadelClientFactory.userFacingMessage(for: error)
                onStateChange(.failed(message))
                if let challenge = (error as? MobileNativeSSHError)?.hostKeyChallenge {
                    onHostKeyRequired(challenge)
                } else if let reason = MobileCitadelClientFactory.credentialPromptReason(for: error) {
                    onCredentialRequired(reason)
                }
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        inputContinuation?.yield(.bytes(bytes))
    }

    func resize(cols: Int, rows: Int) {
        inputContinuation?.yield(.resize(cols: cols, rows: rows))
    }

    func stop() {
        stopPTY()
        let previousDisconnect = disconnectTask
        disconnectTask = Task {
            await previousDisconnect?.value
            await sessionTransport.disconnect()
        }
    }

    private func stopPTY() {
        inputContinuation?.finish()
        inputContinuation = nil
        task?.cancel()
        task = nil
    }

    private static func consume(
        _ inputStream: AsyncStream<MobileTerminalInput>,
        outbound: TTYStdinWriter
    ) async throws {
        for await input in inputStream {
            switch input {
            case .bytes(let bytes):
                try await outbound.write(ByteBuffer(bytes: bytes))
            case .resize(let cols, let rows):
                try await outbound.changeSize(
                    cols: cols,
                    rows: rows,
                    pixelWidth: 0,
                    pixelHeight: 0
                )
            }
        }
    }
}

actor MobileCitadelFileTransport {
    private struct ActiveSFTP {
        let leaseID: UUID
        let client: SFTPClient
    }

    private let sessionTransport: MobileSSHSessionTransport
    private var activeSFTP: ActiveSFTP?

    init(sessionTransport: MobileSSHSessionTransport = MobileSSHSessionTransport()) {
        self.sessionTransport = sessionTransport
    }

    func listDirectory(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials,
        path: String
    ) async throws -> [MobileRemoteFileEntry] {
        try await withSFTP(profile: profile, credentials: credentials) { sftp in
            let names = try await sftp.listDirectory(atPath: path)
            return names
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { component in
                    MobileRemoteFileEntry(
                        name: component.filename,
                        path: MobileRemotePath.child(component.filename, in: path),
                        kind: Self.kind(from: component.attributes.permissions),
                        byteSize: component.attributes.size,
                        permissions: component.attributes.permissions,
                        modifiedAt: component.attributes.accessModificationTime?.modificationTime
                    )
                }
                .sorted { left, right in
                    if left.isDirectory != right.isDirectory {
                        return left.isDirectory && !right.isDirectory
                    }
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
        }
    }

    func download(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials,
        remotePath: String
    ) async throws -> Data {
        try await withSFTP(profile: profile, credentials: credentials) { sftp in
            try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                var buffer = try await file.readAll()
                return Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
            }
        }
    }

    func upload(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials,
        data: Data,
        remotePath: String
    ) async throws {
        try await withSFTP(profile: profile, credentials: credentials) { sftp in
            try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
                try await file.write(ByteBuffer(bytes: data))
            }
        }
    }

    func makeDirectory(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials,
        path: String
    ) async throws {
        try await withSFTP(profile: profile, credentials: credentials) { sftp in
            try await sftp.createDirectory(atPath: path)
        }
    }

    func delete(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials,
        entry: MobileRemoteFileEntry
    ) async throws {
        try await withSFTP(profile: profile, credentials: credentials) { sftp in
            if entry.isDirectory {
                try await sftp.rmdir(at: entry.path)
            } else {
                try await sftp.remove(at: entry.path)
            }
        }
    }

    func rename(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials,
        entry: MobileRemoteFileEntry,
        newName: String
    ) async throws {
        try await withSFTP(profile: profile, credentials: credentials) { sftp in
            let newPath = MobileRemotePath.child(newName, in: MobileRemotePath.parent(of: entry.path))
            try await sftp.rename(at: entry.path, to: newPath)
        }
    }

    func disconnect() async {
        await closeSFTP()
    }

    private func withSFTP<T: Sendable>(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials,
        _ operation: @escaping @Sendable (SFTPClient) async throws -> T
    ) async throws -> T {
        let connection = try await sftpConnection(profile: profile, credentials: credentials)
        do {
            return try await operation(connection.client)
        } catch {
            await closeSFTP()
            await sessionTransport.invalidateIfDisconnected(connection.leaseID)
            throw error
        }
    }

    private func sftpConnection(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials
    ) async throws -> ActiveSFTP {
        let lease = try await sessionTransport.client(profile: profile, credentials: credentials)
        if let activeSFTP, activeSFTP.leaseID == lease.id {
            return activeSFTP
        }

        await closeSFTP()
        do {
            let connection = ActiveSFTP(
                leaseID: lease.id,
                client: try await lease.client.openSFTP()
            )
            activeSFTP = connection
            return connection
        } catch {
            await sessionTransport.invalidateIfDisconnected(lease.id)
            throw error
        }
    }

    private func closeSFTP() async {
        guard let activeSFTP else { return }
        self.activeSFTP = nil
        try? await activeSFTP.client.close()
    }

    private nonisolated static func kind(from permissions: UInt32?) -> MobileRemoteFileKind {
        guard let permissions else { return .other }
        switch permissions & 0o170000 {
        case 0o040000:
            return .directory
        case 0o100000:
            return .regular
        case 0o120000:
            return .symlink
        default:
            return .other
        }
    }
}

enum MobileCitadelClientFactory {
    nonisolated static func connect(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials
    ) async throws -> SSHClient {
        guard profile.isConnectable else {
            throw MobileNativeSSHError.incompleteProfile
        }

        let hostKeyValidator = MobileHostKeyValidator(host: profile.host, port: profile.port)
        let settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: {
                tryAuthenticationMethod(profile: profile, credentials: credentials)
            },
            hostKeyValidator: .custom(hostKeyValidator)
        )

        do {
            return try await connect(
                settings: settings,
                timeoutSeconds: MobileSSHConnectionTuning.connectTimeoutSeconds,
                timeoutError: MobileNativeSSHError.connectionTimedOut(host: profile.host, port: profile.port)
            )
        } catch {
            // The validator records the rejected key independently of how
            // NIO wraps the failed handshake, so the user always gets the
            // fingerprint prompt instead of a generic negotiation error.
            if let challenge = hostKeyValidator.rejectedChallenge {
                throw MobileNativeSSHError.hostKeyNotTrusted(challenge)
            }
            if let nativeError = error as? MobileNativeSSHError {
                throw nativeError
            }
            throw MobileNativeSSHError.connectionFailed(userFacingMessage(for: error, profile: profile))
        }
    }

    nonisolated static func userFacingMessage(
        for error: Error,
        profile: MobileServerProfile? = nil
    ) -> String {
        if let nativeError = error as? MobileNativeSSHError,
           let description = nativeError.errorDescription {
            return description
        }

        let diagnosticMessage = String(describing: error)
        let localizedMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let rawMessage = localizedMessage.hasPrefix("The operation could not be completed.") ||
            localizedMessage.hasPrefix("The operation couldn") ||
            localizedMessage.hasPrefix("The operation couldn\u{2019}t be completed.")
            ? diagnosticMessage
            : localizedMessage
        let normalizedMessage = rawMessage.lowercased()
        let endpoint = profile.map { "\($0.host):\($0.port)" } ?? "the SSH server"

        if isAuthenticationFailureMessage(normalizedMessage) {
            return "Authentication failed for \(endpoint). Check the saved password, private key, or ssh-agent access."
        }

        if normalizedMessage.contains("connection refused") ||
            normalizedMessage.contains("nioconnectionerror error 1") ||
            normalizedMessage.contains("posix error 61") {
            return "Cannot reach the SSH service at \(endpoint). Check that SSH is running and the port is open."
        }

        if normalizedMessage.contains("timed out") ||
            normalizedMessage.contains("timeout") {
            return "Connection timed out while reaching \(endpoint). Check the address, VPN, firewall, and SSH port."
        }

        if normalizedMessage.contains("network is unreachable") ||
            normalizedMessage.contains("no route to host") ||
            normalizedMessage.contains("host is down") {
            return "Network path to \(endpoint) is unavailable. Check Wi-Fi, VPN, and firewall routing."
        }

        if normalizedMessage.contains("keyexchangenegotiationfailure") {
            return "SSH algorithm negotiation failed for \(endpoint). Check the server host key, key exchange, and cipher algorithms."
        }

        if normalizedMessage.contains("unknownpublickey") ||
            normalizedMessage.contains("invalidhostkeyforkeyexchange") ||
            normalizedMessage.contains("invalidexchangehashsignature") {
            return "SSH host key negotiation failed for \(endpoint). Check the server host key algorithm and signature support."
        }

        if normalizedMessage.contains("sftp") &&
            (normalizedMessage.contains("subsystem") || normalizedMessage.contains("open")) {
            return "SFTP is not available on \(endpoint). Check that the server enables the sftp subsystem."
        }

        return rawMessage.isEmpty ? "SSH connection failed. Check the server settings and try again." : rawMessage
    }

    nonisolated static func credentialPromptReason(for error: Error) -> MobileCredentialPromptReason? {
        if let nativeError = error as? MobileNativeSSHError {
            switch nativeError {
            case .missingAuthentication:
                return .missing
            case .connectionFailed(let message) where isAuthenticationFailureMessage(message):
                return .authenticationFailed
            default:
                break
            }
        }

        let combinedMessage = "\(String(describing: error)) \(error.localizedDescription)"
        let localizedErrorMessage = (error as? LocalizedError)?.errorDescription ?? ""
        return isAuthenticationFailureMessage("\(combinedMessage) \(localizedErrorMessage)")
            ? .authenticationFailed
            : nil
    }

    nonisolated static func isAuthenticationFailureMessage(_ message: String) -> Bool {
        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("authentication failed") ||
            normalizedMessage.contains("permission denied") ||
            normalizedMessage.contains("auth failed") ||
            normalizedMessage.contains("userauth") ||
            normalizedMessage.contains("invalid password") ||
            normalizedMessage.contains("allauthenticationoptionsfailed")
    }

    /// Returns as soon as either the connection or the deadline finishes.
    /// A task group would wait for the NIO connect to observe cancellation,
    /// so the deadline could not interrupt a stalled handshake. A connection
    /// that completes after the deadline is closed instead of leaking.
    private nonisolated static func connect(
        settings: SSHClientSettings,
        timeoutSeconds: Double,
        timeoutError: MobileNativeSSHError
    ) async throws -> SSHClient {
        let outcome = MobileConnectOutcome()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SSHClient, Error>) in
                outcome.install(continuation)

                let connectTask = Task {
                    do {
                        let client = try await SSHClient.connect(to: settings)
                        if !outcome.resume(with: .success(client)) {
                            try? await client.close()
                        }
                    } catch {
                        outcome.resume(with: .failure(error))
                    }
                }

                Task {
                    let nanoseconds = UInt64(max(timeoutSeconds, 0.25) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    if outcome.resume(with: .failure(timeoutError)) {
                        connectTask.cancel()
                    }
                }
                outcome.setCancellationTarget(connectTask)
            }
        } onCancel: {
            outcome.cancel()
        }
    }

    /// Offers every saved credential in order: the private key first, then
    /// the password, so a profile with both still connects when the server
    /// only accepts one of them.
    private nonisolated static func tryAuthenticationMethod(
        profile: MobileServerProfile,
        credentials: MobileSSHCredentials
    ) -> SSHAuthenticationMethod {
        var offers: [NIOSSHUserAuthenticationOffer.Offer] = []
        var keyParseFailed = false

        if let key = credentials.privateKey?.mobileNilIfBlank {
            let passphrase = credentials.privateKeyPassphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
            if let ed25519 = try? Curve25519.Signing.PrivateKey(
                sshEd25519: key,
                decryptionKey: passphrase
            ) {
                offers.append(.privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: ed25519))))
            } else if let rsa = try? Insecure.RSA.PrivateKey(
                sshRsa: key,
                decryptionKey: passphrase
            ) {
                offers.append(.privateKey(.init(privateKey: NIOSSHPrivateKey(custom: rsa))))
            } else {
                keyParseFailed = true
            }
        }

        if let password = credentials.password, !password.isEmpty {
            offers.append(.password(.init(password: password)))
        }

        guard !offers.isEmpty else {
            let error: MobileNativeSSHError = keyParseFailed ? .unsupportedPrivateKey : .missingAuthentication
            return .custom(FailingAuthenticationDelegate(error: error))
        }

        return .custom(OrderedAuthenticationDelegate(username: profile.username, offers: offers))
    }
}

/// Resumes the connect continuation exactly once, whichever of the
/// connection, the deadline or task cancellation finishes first.
private final class MobileConnectOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SSHClient, Error>?
    private var isFinished = false
    private var cancellationTarget: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<SSHClient, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setCancellationTarget(_ task: Task<Void, Never>) {
        lock.lock()
        let finished = isFinished
        if !finished {
            cancellationTarget = task
        }
        lock.unlock()
        if finished {
            task.cancel()
        }
    }

    @discardableResult
    func resume(with result: Result<SSHClient, Error>) -> Bool {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return false
        }
        isFinished = true
        self.continuation = nil
        cancellationTarget = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }

    func cancel() {
        lock.lock()
        let target = cancellationTarget
        lock.unlock()
        if resume(with: .failure(CancellationError())) {
            target?.cancel()
        }
    }
}

private final class OrderedAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]

    init(username: String, offers: [NIOSSHUserAuthenticationOffer.Offer]) {
        self.username = username
        self.offers = offers
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            let isAvailable: Bool
            switch offer {
            case .privateKey:
                isAvailable = availableMethods.contains(.publicKey)
            case .password:
                isAvailable = availableMethods.contains(.password)
            case .hostBased, .none:
                isAvailable = false
            }
            if isAvailable {
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
                )
                return
            }
        }
        nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
    }
}

private enum MobileSSHConnectionTuning {
    nonisolated static var connectTimeoutSeconds: Double {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-mobile-ssh-timeout"),
           arguments.indices.contains(arguments.index(after: index)),
           let value = Double(arguments[arguments.index(after: index)]) {
            return value
        }

        if let value = ProcessInfo.processInfo.environment["JTS_TERMINAL_IOS_SSH_TIMEOUT_SECONDS"]
            .flatMap(Double.init) {
            return value
        }

        return 10
    }
}

private final class FailingAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.fail(error)
    }
}
