import Foundation
import Testing
@testable import JTSTerminal

@MainActor
@Suite("SSH connection test credential routing")
struct SSHConnectionTestCoordinatorTests {
    private enum TestError: LocalizedError {
        case vaultRead
        case vaultWrite

        var errorDescription: String? {
            switch self {
            case .vaultRead: "test vault read failed"
            case .vaultWrite: "test vault write failed"
            }
        }
    }

    private actor InvocationRecorder {
        private(set) var invocations: [RemoteCommandInvocation] = []

        func record(_ invocation: RemoteCommandInvocation) -> CommandResult {
            invocations.append(invocation)
            return CommandResult(
                command: "synthetic SSH test",
                exitCode: 0,
                standardOutput: "connected",
                standardError: ""
            )
        }

        func snapshot() -> [RemoteCommandInvocation] { invocations }
    }

    private actor EventRecorder {
        private var events: [String] = []

        func append(_ event: String) {
            events.append(event)
        }

        func snapshot() -> [String] { events }
    }

    @Test("A missing or empty vault value prompts before any executor call")
    func missingCredentialPromptsBeforeExecution() async throws {
        for storedSecret in [String?.none, ""] {
            let recorder = InvocationRecorder()
            let coordinator = SSHConnectionTestCoordinator(
                credentialReader: { _ in storedSecret },
                commandExecutor: { invocation in await recorder.record(invocation) }
            )
            coordinator.begin(snapshot: makeSnapshot(), displayLabel: "deploy@example.test:22")
            await waitUntil { coordinator.pendingCredentialPrompt != nil }

            let prompt = try #require(coordinator.pendingCredentialPrompt)
            #expect(prompt.mode == .passwordOrKeyAgent)
            #expect(coordinator.isRunning)
            let invocations = await recorder.snapshot()
            #expect(invocations.isEmpty)
            coordinator.cancel(requestID: prompt.id)
            #expect(!coordinator.isRunning)
        }
    }

    @Test("Vault read errors fail visibly without invoking SSH")
    func vaultReadFailureIsFailClosed() async {
        let recorder = InvocationRecorder()
        let coordinator = SSHConnectionTestCoordinator(
            credentialReader: { _ in throw TestError.vaultRead },
            commandExecutor: { invocation in await recorder.record(invocation) }
        )

        coordinator.begin(snapshot: makeSnapshot(), displayLabel: "deploy@example.test:22")
        await waitUntil { !coordinator.isRunning }

        #expect(coordinator.errorMessage == "test vault read failed")
        #expect(coordinator.pendingCredentialPrompt == nil)
        let invocations = await recorder.snapshot()
        #expect(invocations.isEmpty)
    }

    @Test("Key or agent testing is explicit and preserves the frozen key argv")
    func explicitKeyRouteExecutesOnce() async throws {
        let recorder = InvocationRecorder()
        let snapshot = makeSnapshot()
        let coordinator = SSHConnectionTestCoordinator(
            credentialReader: { _ in nil },
            commandExecutor: { invocation in await recorder.record(invocation) }
        )
        coordinator.begin(snapshot: snapshot, displayLabel: "deploy@example.test:22")
        await waitUntil { coordinator.pendingCredentialPrompt != nil }
        let requestID = try #require(coordinator.pendingCredentialPrompt?.id)

        coordinator.useKeyOrAgent(requestID: requestID)
        await waitUntil { !coordinator.isRunning }

        let invocations = await recorder.snapshot()
        #expect(invocations.count == 1)
        #expect(invocations.first?.arguments == snapshot.keyArguments)
        #expect(invocations.first?.environment == nil)
        #expect(coordinator.status?.succeeded == true)
    }

    @Test("Jump-host tests never read or auto-fill the destination password")
    func jumpHostRequiresExplicitKeyRoute() async throws {
        let recorder = InvocationRecorder()
        let snapshot = makeSnapshot(jumpHost: "bastion.example")
        let coordinator = SSHConnectionTestCoordinator(
            credentialReader: { _ in throw TestError.vaultRead },
            commandExecutor: { invocation in await recorder.record(invocation) }
        )

        coordinator.begin(snapshot: snapshot, displayLabel: "deploy@internal.example:22")
        let prompt = try #require(coordinator.pendingCredentialPrompt)
        #expect(prompt.mode == .jumpHostManualOnly)
        #expect(coordinator.errorMessage == nil)
        let beforeChoice = await recorder.snapshot()
        #expect(beforeChoice.isEmpty)

        coordinator.useKeyOrAgent(requestID: prompt.id)
        await waitUntil { !coordinator.isRunning }
        let invocations = await recorder.snapshot()
        let invocation = try #require(invocations.first)
        #expect(invocation.arguments == snapshot.keyArguments)
        #expect(invocation.arguments.contains("-J"))
        #expect(invocation.environment == nil)
    }

    @Test("A save failure keeps the prompt and executes nothing")
    func saveFailureKeepsPrompt() async throws {
        let recorder = InvocationRecorder()
        let coordinator = SSHConnectionTestCoordinator(
            credentialReader: { _ in nil },
            credentialWriter: { _, _ in throw TestError.vaultWrite },
            commandExecutor: { invocation in await recorder.record(invocation) }
        )
        coordinator.begin(snapshot: makeSnapshot(), displayLabel: "deploy@example.test:22")
        await waitUntil { coordinator.pendingCredentialPrompt != nil }
        let requestID = try #require(coordinator.pendingCredentialPrompt?.id)

        coordinator.saveAndTest(secret: "temporary-secret", requestID: requestID)
        await waitUntil { !coordinator.isSubmittingCredential }

        #expect(coordinator.pendingCredentialPrompt?.id == requestID)
        #expect(coordinator.isRunning)
        #expect(coordinator.errorMessage == "test vault write failed")
        let invocations = await recorder.snapshot()
        #expect(invocations.isEmpty)
        coordinator.cancel(requestID: requestID)
    }

    @Test("Connect Once clears validation errors, executes once, and cleans the one-shot broker")
    func connectOnceExecutesAndCleansBroker() async throws {
        let recorder = InvocationRecorder()
        let snapshot = makeSnapshot()
        let coordinator = SSHConnectionTestCoordinator(
            credentialReader: { _ in nil },
            credentialWriter: { _, _ in throw TestError.vaultWrite },
            commandExecutor: { invocation in await recorder.record(invocation) }
        )
        coordinator.begin(snapshot: snapshot, displayLabel: "deploy@example.test:22")
        await waitUntil { coordinator.pendingCredentialPrompt != nil }
        let requestID = try #require(coordinator.pendingCredentialPrompt?.id)

        coordinator.connectOnce(secret: "", requestID: requestID)
        #expect(coordinator.errorMessage != nil)
        coordinator.connectOnce(secret: "one-shot-test-secret", requestID: requestID)
        await waitUntil { !coordinator.isRunning }

        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.status?.succeeded == true)
        let invocations = await recorder.snapshot()
        let invocation = try #require(invocations.first)
        #expect(invocations.count == 1)
        #expect(invocation.arguments == snapshot.savedPasswordArguments)
        let socketPath = try #require(
            invocation.environment?[SSHCredentialAskpass.brokerSocketEnvironmentKey]
        )
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("Save and Test persists before executing exactly once")
    func saveAndTestOrdersPersistenceBeforeExecution() async throws {
        let events = EventRecorder()
        let recorder = InvocationRecorder()
        let snapshot = makeSnapshot()
        let coordinator = SSHConnectionTestCoordinator(
            credentialReader: { _ in nil },
            credentialWriter: { _, _ in await events.append("save") },
            commandExecutor: { invocation in
                await events.append("execute")
                return await recorder.record(invocation)
            }
        )
        coordinator.begin(snapshot: snapshot, displayLabel: "deploy@example.test:22")
        await waitUntil { coordinator.pendingCredentialPrompt != nil }
        let requestID = try #require(coordinator.pendingCredentialPrompt?.id)

        coordinator.saveAndTest(secret: "saved-test-secret", requestID: requestID)
        await waitUntil { !coordinator.isRunning }

        let recordedEvents = await events.snapshot()
        #expect(recordedEvents == ["save", "execute"])
        #expect(coordinator.status?.succeeded == true)
        #expect(coordinator.errorMessage == nil)
        let invocations = await recorder.snapshot()
        #expect(invocations.count == 1)
        #expect(invocations.first?.arguments == snapshot.savedPasswordArguments)
    }

    @Test("Cancelling a pending vault read cannot revive the test")
    func cancellingVaultReadPreventsStaleCompletion() async {
        let recorder = InvocationRecorder()
        let coordinator = SSHConnectionTestCoordinator(
            credentialReader: { _ in
                try? await Task.sleep(for: .milliseconds(120))
                return "late-test-secret"
            },
            commandExecutor: { invocation in await recorder.record(invocation) }
        )

        coordinator.begin(snapshot: makeSnapshot(), displayLabel: "deploy@example.test:22")
        coordinator.cancel()
        try? await Task.sleep(for: .milliseconds(180))

        #expect(!coordinator.isRunning)
        #expect(coordinator.pendingCredentialPrompt == nil)
        #expect(coordinator.status == nil)
        #expect(coordinator.errorMessage == nil)
        let invocations = await recorder.snapshot()
        #expect(invocations.isEmpty)
    }

    @Test("Cancelling an in-flight executor suppresses stale success")
    func cancellingExecutorSuppressesStaleResult() async throws {
        let recorder = InvocationRecorder()
        let coordinator = SSHConnectionTestCoordinator(
            credentialReader: { _ in nil },
            commandExecutor: { invocation in
                _ = await recorder.record(invocation)
                try? await Task.sleep(for: .milliseconds(150))
                return CommandResult(
                    command: "late synthetic SSH test",
                    exitCode: 0,
                    standardOutput: "late success",
                    standardError: ""
                )
            }
        )
        coordinator.begin(snapshot: makeSnapshot(), displayLabel: "deploy@example.test:22")
        await waitUntil { coordinator.pendingCredentialPrompt != nil }
        let requestID = try #require(coordinator.pendingCredentialPrompt?.id)
        coordinator.useKeyOrAgent(requestID: requestID)
        await waitForInvocation(recorder)

        coordinator.cancel()
        try? await Task.sleep(for: .milliseconds(220))

        #expect(!coordinator.isRunning)
        #expect(coordinator.status == nil)
        #expect(coordinator.errorMessage == nil)
        let invocations = await recorder.snapshot()
        #expect(invocations.count == 1)
    }

    private func makeSnapshot(jumpHost: String = "") -> SSHConnectionTestLaunchSnapshot {
        let session = RemoteSession(
            name: "Connection test",
            host: jumpHost.isEmpty ? "example.test" : "internal.example",
            username: "deploy",
            port: 22,
            jumpHost: jumpHost
        )
        return SSHConnectionTestLaunchSnapshot(
            session: session,
            remoteCommand: "printf connected",
            uiTestEnvironment: [:]
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        attempts: Int = 100
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForInvocation(
        _ recorder: InvocationRecorder,
        attempts: Int = 100
    ) async {
        for _ in 0..<attempts {
            if await !recorder.snapshot().isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
