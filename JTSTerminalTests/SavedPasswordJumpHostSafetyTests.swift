import Foundation
import Testing
@testable import JTSTerminal

private actor JumpHostInvocationRecorder {
    private var invocations: [RemoteCommandInvocation] = []

    func append(_ invocation: RemoteCommandInvocation) {
        invocations.append(invocation)
    }

    func count() -> Int {
        invocations.count
    }
}

@MainActor
struct SavedPasswordJumpHostSafetyTests {
    @Test func sshSavedPasswordFailsClosedWithoutLaunchingAroundJumpHost() async {
        let recorder = JumpHostInvocationRecorder()
        let runner = Self.runner(recorder: recorder)

        await Self.expectJumpHostRejection {
            try await runner.runSSH(
                session: Self.jumpHostSession(),
                remoteCommand: "hostname"
            )
        }

        #expect(await recorder.count() == 0)
    }

    @Test func scpUploadSavedPasswordFailsClosedWithoutLaunchingAroundJumpHost() async {
        let recorder = JumpHostInvocationRecorder()
        let runner = Self.runner(recorder: recorder)

        await Self.expectJumpHostRejection {
            try await runner.runSCPUpload(
                session: Self.jumpHostSession(),
                localPath: "/tmp/local.txt",
                remotePath: "/srv/remote.txt"
            )
        }

        #expect(await recorder.count() == 0)
    }

    @Test func scpDownloadSavedPasswordFailsClosedWithoutLaunchingAroundJumpHost() async {
        let recorder = JumpHostInvocationRecorder()
        let runner = Self.runner(recorder: recorder)

        await Self.expectJumpHostRejection {
            try await runner.runSCPDownload(
                session: Self.jumpHostSession(),
                remotePath: "/srv/remote.txt",
                localPath: "/tmp/local.txt"
            )
        }

        #expect(await recorder.count() == 0)
    }

    @Test func sftpSavedPasswordFailsClosedWithoutLaunchingAroundJumpHost() async {
        let recorder = JumpHostInvocationRecorder()
        let transport = RemoteSFTPTransport(
            credentialReader: { _ in "saved-password" },
            commandExecutor: { invocation in
                await recorder.append(invocation)
                return Self.successResult(for: invocation)
            }
        )

        await Self.expectJumpHostRejection {
            try await transport.listDirectory(
                session: Self.jumpHostSession(),
                path: "/srv"
            )
        }

        #expect(await recorder.count() == 0)
    }

    @Test func cancelledCredentialReadCannotLaunchSSHAfterReturningSecret() async {
        let recorder = JumpHostInvocationRecorder()
        let (readStarted, startedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseRead, releaseContinuation) = AsyncStream<Void>.makeStream()
        let runner = AuthenticatedRemoteCommandRunner(
            credentialReader: { _ in
                startedContinuation.yield()
                for await _ in releaseRead { break }
                return "saved-password"
            },
            commandExecutor: { invocation in
                await recorder.append(invocation)
                return Self.successResult(for: invocation)
            }
        )
        let operation = Task {
            try await runner.runSSH(
                session: RemoteSession(host: "target.example", username: "deploy", port: 22),
                remoteCommand: "hostname"
            )
        }
        var startedIterator = readStarted.makeAsyncIterator()
        _ = await startedIterator.next()

        operation.cancel()
        releaseContinuation.yield()

        do {
            _ = try await operation.value
            Issue.record("A cancelled credential read must not launch SSH")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await recorder.count() == 0)
    }

    @Test func cancelledCredentialReadCannotLaunchSFTPAfterReturningSecret() async {
        let recorder = JumpHostInvocationRecorder()
        let (readStarted, startedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseRead, releaseContinuation) = AsyncStream<Void>.makeStream()
        let transport = RemoteSFTPTransport(
            credentialReader: { _ in
                startedContinuation.yield()
                for await _ in releaseRead { break }
                return "saved-password"
            },
            commandExecutor: { invocation in
                await recorder.append(invocation)
                return Self.successResult(for: invocation)
            }
        )
        let operation = Task {
            try await transport.listDirectory(
                session: RemoteSession(host: "target.example", username: "deploy", port: 22),
                path: "/srv"
            )
        }
        var startedIterator = readStarted.makeAsyncIterator()
        _ = await startedIterator.next()

        operation.cancel()
        releaseContinuation.yield()

        do {
            _ = try await operation.value
            Issue.record("A cancelled credential read must not launch SFTP")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await recorder.count() == 0)
    }

    @Test func tunnelSavedPasswordFailsClosedWithoutLaunchingAroundJumpHost() async throws {
        let manager = SSHTunnelManager(credentialReader: { _ in "saved-password" })
        let configuration = SSHTunnelConfiguration(
            name: "Jump Host Tunnel",
            kind: .dynamic,
            bindAddress: "127.0.0.1",
            localPort: 10_981,
            destinationHost: "",
            destinationPort: 22
        )

        manager.start(session: Self.jumpHostSession(), configuration: configuration)

        for _ in 0..<50 where manager.lastMessage == "Tunnel is stopped." {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(manager.processLaunchAttemptCountForTesting == 0)
        #expect(!manager.isRunning)
        #expect(manager.pid == nil)
        #expect(manager.lastMessage.contains("jump host"))
        #expect(manager.lastMessage.contains("SSH key or ssh-agent"))
    }

    private static func runner(recorder: JumpHostInvocationRecorder) -> AuthenticatedRemoteCommandRunner {
        AuthenticatedRemoteCommandRunner(
            credentialReader: { _ in "saved-password" },
            commandExecutor: { invocation in
                await recorder.append(invocation)
                return successResult(for: invocation)
            }
        )
    }

    private static func jumpHostSession() -> RemoteSession {
        RemoteSession(
            host: "target.example",
            username: "deploy",
            port: 22,
            jumpHost: "bastion.example"
        )
    }

    private static func expectJumpHostRejection(
        _ operation: () async throws -> CommandResult
    ) async {
        do {
            _ = try await operation()
            Issue.record("Saved-password authentication must fail closed when a jump host is configured")
        } catch let error as RemoteCredentialRoutingError {
            #expect(error == .savedPasswordCannotUseJumpHost)
            #expect(error.localizedDescription.contains("jump host"))
        } catch {
            Issue.record("Expected RemoteCredentialRoutingError, got \(error)")
        }
    }

    nonisolated private static func successResult(
        for invocation: RemoteCommandInvocation
    ) -> CommandResult {
        CommandResult(
            command: invocation.executable,
            exitCode: 0,
            standardOutput: "ok",
            standardError: ""
        )
    }
}
