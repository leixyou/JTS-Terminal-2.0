import Foundation
import Testing
@testable import JTSTerminal

@MainActor
@Suite("SSH connection-time credential prompt")
struct SSHCredentialPromptFlowTests {
    private enum TestFailure: LocalizedError {
        case vaultRead
        case vaultWrite

        var errorDescription: String? {
            switch self {
            case .vaultRead:
                return "test vault read failure"
            case .vaultWrite:
                return "test vault write failure"
            }
        }
    }

    private actor SavedCredentialRecorder {
        private var value: (secret: String, account: String)?

        func record(secret: String, account: String) {
            value = (secret, account)
        }

        func snapshot() -> (secret: String, account: String)? { value }
    }

    private actor BlockingCredentialWriter {
        private var value: (secret: String, account: String)?
        private var continuation: CheckedContinuation<Void, Never>?

        func write(secret: String, account: String) async throws {
            value = (secret, account)
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            try Task.checkCancellation()
        }

        func hasStarted() -> Bool { value != nil }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor CredentialReadRecorder {
        private var count = 0

        func read(_ account: String) -> String? {
            count += 1
            return "should-not-be-read"
        }

        func readCount() -> Int { count }
    }

    private struct RecoveringSSHFixture {
        static let recoveredMarker = "SSH_RECOVERY_OK"

        let rootURL: URL
        let executableURL: URL
        let launchMarkerURL: URL
        let passwordDeliveryMarkerURL: URL
        let host: String

        init(
            rejectEveryLaunch: Bool = false,
            emitPasswordPrompt: Bool = true
        ) throws {
            let token = UUID().uuidString.lowercased()
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("jts-ssh-credential-recovery-\(token)", isDirectory: true)
            executableURL = try SleepingSSHTestFixture.recoveringExecutableURL()
            launchMarkerURL = rootURL.appendingPathComponent("launch-count", isDirectory: false)
            passwordDeliveryMarkerURL = rootURL.appendingPathComponent(
                "password-delivery-count",
                isDirectory: false
            )
            host = "jts-credential-recovery-\(token).example.test"
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            if rejectEveryLaunch {
                let rejectionMarkerURL = rootURL.appendingPathComponent(
                    "reject-every-launch",
                    isDirectory: false
                )
                try Data().write(to: rejectionMarkerURL, options: .atomic)
            }
            if !emitPasswordPrompt {
                let noPromptMarkerURL = rootURL.appendingPathComponent(
                    "reject-without-prompt",
                    isDirectory: false
                )
                try Data().write(to: noPromptMarkerURL, options: .atomic)
            }
        }

        func launchCount() -> Int {
            guard let text = try? String(contentsOf: launchMarkerURL, encoding: .utf8) else {
                return 0
            }
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        func passwordDeliveryCount() -> Int {
            guard let text = try? String(
                contentsOf: passwordDeliveryMarkerURL,
                encoding: .utf8
            ) else {
                return 0
            }
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    @Test("Prompt policy separates direct and jump-host routes and validates password input")
    func promptPolicy() {
        let direct = SSHCredentialPromptPolicy.descriptor(
            id: UUID(),
            credentialAccount: "deploy@example.test:22",
            displayLabel: "deploy@example.test:22",
            jumpHost: ""
        )
        let jump = SSHCredentialPromptPolicy.descriptor(
            id: UUID(),
            credentialAccount: "deploy@internal.example:22",
            displayLabel: "deploy@internal.example:22",
            jumpHost: "bastion.example"
        )

        #expect(direct.mode == .passwordOrKeyAgent)
        #expect(direct.allowsPasswordSubmission)
        #expect(jump.mode == .jumpHostManualOnly)
        #expect(!jump.allowsPasswordSubmission)
        #expect(SSHCredentialPromptPolicy.validationError(for: "") == .empty)
        #expect(SSHCredentialPromptPolicy.validationError(for: "line\nbreak") == .containsUnsupportedCharacters)
        #expect(SSHCredentialPromptPolicy.validationError(for: "nul\0byte") == .containsUnsupportedCharacters)
        #expect(
            SSHCredentialPromptPolicy.validationError(
                for: String(repeating: "x", count: SSHCredentialAskpass.maximumSecretBytes + 1)
            ) == .tooLarge(maximumBytes: SSHCredentialAskpass.maximumSecretBytes)
        )
        #expect(SSHCredentialPromptPolicy.validationError(for: "valid password") == nil)
        #expect(SSHCredentialPromptPolicy.inputAdvisory(for: "valid password") == nil)
        #expect(
            SSHCredentialPromptPolicy.inputAdvisory(for: "\"valid password\"") ==
                SSHCredentialInputAdvisory(
                    kind: .matchingASCIIQuote,
                    utf8ByteCount: 16
                )
        )
        #expect(
            SSHCredentialPromptPolicy.inputAdvisory(for: " valid password ") ==
                SSHCredentialInputAdvisory(
                    kind: .leadingOrTrailingWhitespace,
                    utf8ByteCount: 16
                )
        )
        #expect(
            SSHCredentialPromptPolicy.inputAdvisory(for: "Amoslv123-。+") ==
                SSHCredentialInputAdvisory(
                    kind: .nonASCIIPunctuation,
                    utf8ByteCount: 14
                )
        )
        #expect(SSHCredentialPromptPolicy.inputAdvisory(for: "Amoslv123-.+") == nil)
    }

    @Test("Missing saved password opens a prompt without launching SSH")
    func missingSavedPasswordPromptsWithoutLaunch() async throws {
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in nil },
            sshExecutable: "/path/that/must-not-run/ssh"
        )
        let profile = makeProfile()

        processSession.startSSH(session: profile)
        await waitUntil { processSession.pendingSSHCredentialPrompt != nil }

        let prompt = try #require(processSession.pendingSSHCredentialPrompt)
        #expect(prompt.mode == .passwordOrKeyAgent)
        #expect(prompt.credentialAccount == CredentialStore.account(username: "deploy", host: "example.test", port: 22))
        #expect(processSession.isSSHStartPending)
        expectNoLaunch(processSession)
        processSession.stop()
    }

    #if ENABLE_RDP_2
    @Test("RDP profiles are rejected before SSH credential lookup or launch")
    func rdpProfileDoesNotEnterSSHCredentialFlow() async throws {
        let reader = CredentialReadRecorder()
        let processSession = InteractiveProcessSession(
            credentialReader: { account in
                await reader.read(account)
            },
            sshExecutable: "/path/that/must-not-run/ssh"
        )
        let profile = RemoteSession(
            name: "RDP target",
            host: "192.168.10.20",
            username: "rodster",
            port: 3_389,
            connectionType: .rdp
        )

        processSession.startSSH(session: profile)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(await reader.readCount() == 0)
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.isSubmittingSSHCredential)
        #expect(processSession.transcript.contains("not SSH"))
        expectNoLaunch(processSession)
    }
    #endif

    @Test("An empty saved password is treated as missing and never prepared")
    func emptySavedPasswordPromptsWithoutLaunch() async throws {
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in "" },
            sshExecutable: "/path/that/must-not-run/ssh"
        )

        processSession.startSSH(session: makeProfile())
        await waitUntil { processSession.pendingSSHCredentialPrompt != nil }

        _ = try #require(processSession.pendingSSHCredentialPrompt)
        #expect(processSession.sshCredentialPromptError == nil)
        expectNoLaunch(processSession)
        processSession.stop()
    }

    @Test("Cancelling the prompt clears the pending request and launches nothing")
    func cancelPrompt() async throws {
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in nil },
            sshExecutable: "/path/that/must-not-run/ssh"
        )
        processSession.startSSH(session: makeProfile())
        await waitUntil { processSession.pendingSSHCredentialPrompt != nil }
        let requestID = try #require(processSession.pendingSSHCredentialPrompt?.id)

        processSession.cancelSSHCredentialPrompt(requestID: requestID)

        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        expectNoLaunch(processSession)
    }

    @Test("A vault read error is visible and fails closed before launch")
    func vaultReadErrorStopsLaunch() async {
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in throw TestFailure.vaultRead },
            sshExecutable: "/path/that/must-not-run/ssh"
        )

        processSession.startSSH(session: makeProfile())
        await waitUntil { processSession.transcript.contains("test vault read failure") }

        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(processSession.transcript.contains("No connection was started"))
        expectNoLaunch(processSession)
    }

    @Test("A stale vault result cannot revive a cancelled connection request")
    func staleResultAfterStopDoesNotLaunch() async {
        let secret = "late-test-secret"
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in
                try? await Task.sleep(for: .milliseconds(120))
                return secret
            },
            sshExecutable: "/path/that/must-not-run/ssh"
        )

        processSession.startSSH(session: makeProfile())
        processSession.stop()
        try? await Task.sleep(for: .milliseconds(180))

        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(processSession.sshCredentialPromptError == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.transcript.contains(secret))
        expectNoLaunch(processSession)
    }

    @Test("Jump-host profiles never read or auto-fill the destination password")
    func jumpHostUsesManualDescriptorWithoutVaultRead() async throws {
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in throw TestFailure.vaultRead },
            sshExecutable: "/path/that/must-not-run/ssh"
        )
        let profile = makeProfile(jumpHost: "bastion.example")

        processSession.startSSH(session: profile)
        try? await Task.sleep(for: .milliseconds(30))

        let prompt = try #require(processSession.pendingSSHCredentialPrompt)
        #expect(prompt.mode == .jumpHostManualOnly)
        #expect(!prompt.allowsPasswordSubmission)
        #expect(!processSession.transcript.contains("test vault read failure"))
        expectNoLaunch(processSession)
        processSession.stop()
    }

    @Test("Save failure leaves the prompt visible and starts no process")
    func saveFailureLeavesPromptForRecovery() async throws {
        let secret = "save-failure-secret"
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in nil },
            credentialWriter: { _, _ in throw TestFailure.vaultWrite },
            sshExecutable: "/path/that/must-not-run/ssh"
        )
        processSession.startSSH(session: makeProfile())
        await waitUntil { processSession.pendingSSHCredentialPrompt != nil }
        let requestID = try #require(processSession.pendingSSHCredentialPrompt?.id)

        processSession.saveAndConnectWithSSHPassword(secret, requestID: requestID)
        await waitUntil { !processSession.isSubmittingSSHCredential }

        #expect(processSession.pendingSSHCredentialPrompt?.id == requestID)
        #expect(processSession.isSSHStartPending)
        #expect(processSession.sshCredentialPromptError?.contains("test vault write failure") == true)
        #expect(!processSession.transcript.contains(secret))
        expectNoLaunch(processSession)
        processSession.stop()
    }

    @Test("Connect Once launches exactly one non-persistent password session")
    func connectOnceLaunchesWithoutSaving() async throws {
        let fakeSSH = try SleepingSSHTestFixture.executableURL()
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in nil },
            credentialWriter: { _, _ in throw TestFailure.vaultWrite },
            sshExecutable: fakeSSH.path
        )
        processSession.startSSH(session: makeProfile())
        await waitUntil { processSession.pendingSSHCredentialPrompt != nil }
        let requestID = try #require(processSession.pendingSSHCredentialPrompt?.id)

        processSession.connectOnceWithSSHPassword(
            "one-shot-interactive-secret",
            requestID: requestID
        )
        await waitUntil {
            processSession.isRunning
                && processSession.transcript.contains(SleepingSSHTestFixture.readyMarker)
        }

        #expect(processSession.isRunning)
        #expect(processSession.hasStarted)
        #expect(processSession.transcript.contains(SleepingSSHTestFixture.readyMarker))
        #expect(!processSession.isSSHStartPending)
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.transcript.contains("one-shot-interactive-secret"))
        processSession.stop()
        #expect(!processSession.isReconnectScheduled)
    }

    @Test("Save and Connect persists the frozen account before launch")
    func saveAndConnectPersistsThenLaunches() async throws {
        let fakeSSH = try SleepingSSHTestFixture.executableURL()
        let savedCredential = SavedCredentialRecorder()
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in nil },
            credentialWriter: { secret, account in
                await savedCredential.record(secret: secret, account: account)
            },
            sshExecutable: fakeSSH.path
        )
        let profile = makeProfile()
        processSession.startSSH(session: profile)
        await waitUntil { processSession.pendingSSHCredentialPrompt != nil }
        let requestID = try #require(processSession.pendingSSHCredentialPrompt?.id)

        processSession.saveAndConnectWithSSHPassword(
            "saved-interactive-secret",
            requestID: requestID
        )
        await waitUntil {
            processSession.isRunning
                && processSession.transcript.contains(SleepingSSHTestFixture.readyMarker)
        }

        let savedSnapshot = await savedCredential.snapshot()
        let saved = try #require(savedSnapshot)
        #expect(saved.secret == "saved-interactive-secret")
        #expect(saved.account == CredentialStore.account(for: profile))
        #expect(processSession.isRunning)
        #expect(processSession.transcript.contains(SleepingSSHTestFixture.readyMarker))
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSubmittingSSHCredential)
        processSession.stop()
    }

    @Test("Connect Once stops after one rejected helper-backed launch")
    func connectOnceStopsAfterOneRejectedLaunch() async throws {
        let fixture = try RecoveringSSHFixture(rejectEveryLaunch: true)
        defer { fixture.cleanup() }
        let secret = "valid-direct-pty-secret"
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in nil },
            credentialDeliverySnapshotter: { _ in .helperCompletedResponse },
            sshExecutable: fixture.executableURL.path
        )
        processSession.startSSH(session: makeProfile(host: fixture.host))
        await waitUntil { processSession.pendingSSHCredentialPrompt != nil }
        let requestID = try #require(processSession.pendingSSHCredentialPrompt?.id)

        processSession.connectOnceWithSSHPassword(secret, requestID: requestID)
        await waitUntil(
            {
                processSession.transcript.contains(
                    "JTS Terminal sent the complete one-time password"
                )
            }
        )
        #expect(fixture.launchCount() == 1)
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.transcript.contains(secret))
        processSession.stop()
    }

    @Test("Rejected saved password opens a replacement prompt without deleting the vault entry")
    func rejectedSavedPasswordCanConnectOnceWithoutOverwritingVault() async throws {
        let fixture = try RecoveringSSHFixture()
        defer { fixture.cleanup() }
        let savedCredential = SavedCredentialRecorder()
        let originalSecret = "synthetic-rejected-saved-secret"
        let replacementSecret = "synthetic-connect-once-replacement"
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in originalSecret },
            credentialWriter: { secret, account in
                await savedCredential.record(secret: secret, account: account)
            },
            credentialDeliverySnapshotter: { _ in .helperCompletedResponse },
            sshExecutable: fixture.executableURL.path
        )

        processSession.startSSH(session: makeProfile(host: fixture.host))
        await waitUntil {
            processSession.pendingSSHCredentialPrompt?.reason == .rejectedSavedPassword
        }

        let prompt = try #require(processSession.pendingSSHCredentialPrompt)
        #expect(prompt.reason == .rejectedSavedPassword)
        #expect(processSession.isSSHStartPending)
        #expect(!processSession.isReconnectScheduled)
        #expect(processSession.transcript.contains("saved credential was supplied"))
        #expect(!processSession.transcript.contains(originalSecret))

        processSession.connectOnceWithSSHPassword(replacementSecret, requestID: prompt.id)
        await waitUntil {
            processSession.transcript.contains(RecoveringSSHFixture.recoveredMarker)
        }

        let unexpectedlySaved = await savedCredential.snapshot()
        #expect(unexpectedlySaved == nil)
        #expect(fixture.launchCount() == 2)
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.transcript.contains(replacementSecret))
        processSession.stop()
    }

    @Test("Save and Reconnect overwrites the frozen vault account before retrying")
    func rejectedSavedPasswordCanBeOverwrittenBeforeReconnect() async throws {
        let fixture = try RecoveringSSHFixture()
        defer { fixture.cleanup() }
        let savedCredential = SavedCredentialRecorder()
        let replacementSecret = "synthetic-saved-replacement"
        let profile = makeProfile(host: fixture.host)
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in "synthetic-old-password" },
            credentialWriter: { secret, account in
                await savedCredential.record(secret: secret, account: account)
            },
            credentialDeliverySnapshotter: { _ in .helperCompletedResponse },
            sshExecutable: fixture.executableURL.path
        )

        processSession.startSSH(session: profile)
        await waitUntil {
            processSession.pendingSSHCredentialPrompt?.reason == .rejectedSavedPassword
        }
        let prompt = try #require(processSession.pendingSSHCredentialPrompt)

        processSession.saveAndConnectWithSSHPassword(replacementSecret, requestID: prompt.id)
        await waitUntil {
            processSession.transcript.contains(RecoveringSSHFixture.recoveredMarker)
        }

        let savedSnapshot = await savedCredential.snapshot()
        let saved = try #require(savedSnapshot)
        #expect(saved.secret == replacementSecret)
        #expect(saved.account == CredentialStore.account(for: profile))
        #expect(fixture.launchCount() == 2)
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSubmittingSSHCredential)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.transcript.contains(replacementSecret))
        processSession.stop()
    }

    @Test("A rejected user-entered password stops without opening another modal prompt")
    func rejectedReplacementDoesNotCreateAPromptLoop() async throws {
        let fixture = try RecoveringSSHFixture(rejectEveryLaunch: true)
        defer { fixture.cleanup() }
        let savedCredential = SavedCredentialRecorder()
        let originalSecret = "synthetic-loop-old-password"
        let replacementSecret = "synthetic-loop-replacement"
        let profile = makeProfile(host: fixture.host)
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in originalSecret },
            credentialWriter: { secret, account in
                await savedCredential.record(secret: secret, account: account)
            },
            credentialDeliverySnapshotter: { _ in .helperCompletedResponse },
            sshExecutable: fixture.executableURL.path
        )

        processSession.startSSH(session: profile)
        await waitUntil {
            processSession.pendingSSHCredentialPrompt?.reason == .rejectedSavedPassword
        }
        let prompt = try #require(processSession.pendingSSHCredentialPrompt)

        processSession.saveAndConnectWithSSHPassword(
            replacementSecret,
            requestID: prompt.id
        )
        await waitUntil(
            {
                processSession.transcript.contains(
                    "will not open another password prompt automatically"
                )
            }
        )
        try? await Task.sleep(for: .milliseconds(200))

        let expectedAccount = CredentialStore.account(for: profile)
        let saved = await savedCredential.snapshot()
        #expect(saved?.secret == replacementSecret)
        #expect(saved?.account == expectedAccount)
        #expect(fixture.launchCount() == 2)
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.isReconnectScheduled)
        #expect(!processSession.isRunning)
        processSession.stop()
    }

    @Test("Cancelling rejected-password recovery clears state and starts no retry")
    func cancellingRejectedSavedPasswordRecoveryStartsNothing() async throws {
        let fixture = try RecoveringSSHFixture()
        defer { fixture.cleanup() }
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in "synthetic-rejected-password" },
            credentialDeliverySnapshotter: { _ in .helperCompletedResponse },
            sshExecutable: fixture.executableURL.path
        )

        processSession.startSSH(session: makeProfile(host: fixture.host))
        let didPresentRecovery = await waitUntil {
            processSession.pendingSSHCredentialPrompt?.reason == .rejectedSavedPassword
        }
        #expect(didPresentRecovery)
        let requestID = try #require(processSession.pendingSSHCredentialPrompt?.id)

        processSession.cancelSSHCredentialPrompt(requestID: requestID)
        let didClearRecovery = await waitUntil {
            processSession.pendingSSHCredentialPrompt == nil
                && !processSession.isSSHStartPending
                && !processSession.isSubmittingSSHCredential
                && !processSession.isReconnectScheduled
        }

        #expect(didClearRecovery)
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.isSubmittingSSHCredential)
        #expect(!processSession.isReconnectScheduled)
        #expect(fixture.launchCount() == 1)
        processSession.stop()
    }

    @Test("A cancelled replacement write cannot launch a stale reconnect")
    func cancelledReplacementWriteCannotLaunchStaleReconnect() async throws {
        let fixture = try RecoveringSSHFixture()
        defer { fixture.cleanup() }
        let writer = BlockingCredentialWriter()
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in "synthetic-rejected-password" },
            credentialWriter: { secret, account in
                try await writer.write(secret: secret, account: account)
            },
            credentialDeliverySnapshotter: { _ in .helperCompletedResponse },
            sshExecutable: fixture.executableURL.path
        )

        processSession.startSSH(session: makeProfile(host: fixture.host))
        await waitUntil {
            processSession.pendingSSHCredentialPrompt?.reason == .rejectedSavedPassword
        }
        let requestID = try #require(processSession.pendingSSHCredentialPrompt?.id)
        processSession.saveAndConnectWithSSHPassword(
            "synthetic-delayed-replacement",
            requestID: requestID
        )
        for _ in 0..<200 {
            if await writer.hasStarted() {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let writerStarted = await writer.hasStarted()
        #expect(writerStarted)
        #expect(processSession.isSubmittingSSHCredential)

        processSession.cancelSSHCredentialPrompt(requestID: requestID)
        await writer.resume()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.isSubmittingSSHCredential)
        #expect(!processSession.isReconnectScheduled)
        #expect(fixture.launchCount() == 1)
        processSession.stop()
    }

    @Test("Authentication failure before a password prompt does not claim the saved password was supplied")
    func authFailureBeforePasswordPromptDoesNotOfferReplacement() async throws {
        let fixture = try RecoveringSSHFixture(emitPasswordPrompt: false)
        defer { fixture.cleanup() }
        let processSession = InteractiveProcessSession(
            credentialReader: { _ in "synthetic-undelivered-password" },
            sshExecutable: fixture.executableURL.path
        )

        processSession.startSSH(session: makeProfile(host: fixture.host))
        let didObserveAuthenticationFailure = await waitUntil {
            processSession.transcript.contains("the local password helper did not complete password delivery")
        }

        #expect(didObserveAuthenticationFailure)
        #expect(processSession.pendingSSHCredentialPrompt == nil)
        #expect(!processSession.isSSHStartPending)
        #expect(!processSession.isReconnectScheduled)
        #expect(!processSession.transcript.contains("saved credential was supplied"))
        #expect(processSession.transcript.contains("This does not prove the password was wrong"))
        #expect(!processSession.transcript.contains("Auto reconnect stopped: SSH authentication was rejected"))
        #expect(fixture.passwordDeliveryCount() == 0)
        #expect(fixture.launchCount() == 1)
        processSession.stop()
    }

    private func makeProfile(
        host: String = "example.test",
        jumpHost: String = ""
    ) -> RemoteSession {
        RemoteSession(
            name: "Credential prompt test",
            host: host,
            username: "deploy",
            port: 22,
            jumpHost: jumpHost
        )
    }

    private func expectNoLaunch(_ processSession: InteractiveProcessSession) {
        #expect(!processSession.hasStarted)
        #expect(!processSession.isRunning)
        #expect(processSession.pid == nil)
        #expect(!processSession.transcript.contains("started PTY session"))
    }

    @discardableResult
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(30)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard !Task.isCancelled, clock.now < deadline else {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return true
    }
}
