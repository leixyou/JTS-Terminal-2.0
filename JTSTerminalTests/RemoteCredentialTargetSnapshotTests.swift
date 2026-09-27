import Foundation
import Testing
@testable import JTSTerminal

private actor RemoteCommandInvocationRecorder {
    private var values: [RemoteCommandInvocation] = []

    func append(_ invocation: RemoteCommandInvocation) {
        values.append(invocation)
    }

    func all() -> [RemoteCommandInvocation] {
        values
    }
}

@MainActor
struct RemoteCredentialTargetSnapshotTests {
    @Test func sshCredentialReadCannotRedirectOriginalSecretToEditedTarget() async throws {
        let (readStarted, readStartedContinuation) = AsyncStream<String>.makeStream()
        let (releaseRead, releaseReadContinuation) = AsyncStream<Void>.makeStream()
        let recorder = RemoteCommandInvocationRecorder()
        let runner = AuthenticatedRemoteCommandRunner(
            credentialReader: { account in
                readStartedContinuation.yield(account)
                for await _ in releaseRead { break }
                return "credential-for-original-target"
            },
            commandExecutor: { invocation in
                await recorder.append(invocation)
                return Self.successResult(for: invocation)
            }
        )
        let session = Self.originalSession()

        let operation = Task {
            try await runner.runSSH(session: session, remoteCommand: "hostname")
        }
        var startedIterator = readStarted.makeAsyncIterator()
        #expect(await startedIterator.next() == "original-user@original.example:2222")

        Self.redirect(session)
        releaseReadContinuation.yield()
        _ = try await operation.value

        let invocation = try #require(await recorder.all().only)
        Self.expectOriginalTarget(in: invocation)
        #expect(invocation.executable == "/usr/bin/ssh")
        Self.expectOneShotCredentialBroker(in: invocation)
    }

    @Test func scpUploadCredentialReadCannotRedirectOriginalSecretToEditedTarget() async throws {
        let (readStarted, readStartedContinuation) = AsyncStream<String>.makeStream()
        let (releaseRead, releaseReadContinuation) = AsyncStream<Void>.makeStream()
        let recorder = RemoteCommandInvocationRecorder()
        let runner = AuthenticatedRemoteCommandRunner(
            credentialReader: { account in
                readStartedContinuation.yield(account)
                for await _ in releaseRead { break }
                return "credential-for-original-target"
            },
            commandExecutor: { invocation in
                await recorder.append(invocation)
                return Self.successResult(for: invocation)
            }
        )
        let session = Self.originalSession()

        let operation = Task {
            try await runner.runSCPUpload(
                session: session,
                localPath: "/tmp/local.txt",
                remotePath: "/srv/remote.txt"
            )
        }
        var startedIterator = readStarted.makeAsyncIterator()
        #expect(await startedIterator.next() == "original-user@original.example:2222")

        Self.redirect(session)
        releaseReadContinuation.yield()
        _ = try await operation.value

        let invocation = try #require(await recorder.all().only)
        Self.expectOriginalTarget(in: invocation)
        #expect(invocation.executable == "/usr/bin/scp")
        Self.expectOneShotCredentialBroker(in: invocation)
    }

    @Test func scpDownloadCredentialReadCannotRedirectOriginalSecretToEditedTarget() async throws {
        let (readStarted, readStartedContinuation) = AsyncStream<String>.makeStream()
        let (releaseRead, releaseReadContinuation) = AsyncStream<Void>.makeStream()
        let recorder = RemoteCommandInvocationRecorder()
        let runner = AuthenticatedRemoteCommandRunner(
            credentialReader: { account in
                readStartedContinuation.yield(account)
                for await _ in releaseRead { break }
                return "credential-for-original-target"
            },
            commandExecutor: { invocation in
                await recorder.append(invocation)
                return Self.successResult(for: invocation)
            }
        )
        let session = Self.originalSession()

        let operation = Task {
            try await runner.runSCPDownload(
                session: session,
                remotePath: "/srv/remote.txt",
                localPath: "/tmp/local.txt"
            )
        }
        var startedIterator = readStarted.makeAsyncIterator()
        #expect(await startedIterator.next() == "original-user@original.example:2222")

        Self.redirect(session)
        releaseReadContinuation.yield()
        _ = try await operation.value

        let invocation = try #require(await recorder.all().only)
        Self.expectOriginalTarget(in: invocation)
        #expect(invocation.executable == "/usr/bin/scp")
        Self.expectOneShotCredentialBroker(in: invocation)
    }

    @Test func sftpCredentialReadCannotRedirectOriginalSecretToEditedTarget() async throws {
        let (readStarted, readStartedContinuation) = AsyncStream<String>.makeStream()
        let (releaseRead, releaseReadContinuation) = AsyncStream<Void>.makeStream()
        let recorder = RemoteCommandInvocationRecorder()
        let transport = RemoteSFTPTransport(
            credentialReader: { account in
                readStartedContinuation.yield(account)
                for await _ in releaseRead { break }
                return "credential-for-original-target"
            },
            commandExecutor: { invocation in
                await recorder.append(invocation)
                return Self.successResult(for: invocation)
            }
        )
        let session = Self.originalSession()

        let operation = Task {
            try await transport.listDirectory(session: session, path: "/srv")
        }
        var startedIterator = readStarted.makeAsyncIterator()
        #expect(await startedIterator.next() == "original-user@original.example:2222")

        Self.redirect(session)
        releaseReadContinuation.yield()
        _ = try await operation.value

        let invocation = try #require(await recorder.all().only)
        Self.expectOriginalTarget(in: invocation)
        #expect(invocation.executable == "/usr/bin/sftp")
        Self.expectOneShotCredentialBroker(in: invocation)
    }

    @Test func connectionTestSnapshotDoesNotFollowLaterProfileEdits() throws {
        let session = Self.originalSession()
        let snapshot = SSHConnectionTestLaunchSnapshot(
            session: session,
            remoteCommand: "hostname",
            uiTestEnvironment: [:]
        )

        Self.redirect(session)

        #expect(snapshot.credentialAccount == "original-user@original.example:2222")
        #expect(snapshot.allowsSavedPasswordAutofill)
        Self.expectOriginalTarget(in: snapshot.savedPasswordArguments)
        Self.expectOriginalTarget(in: snapshot.keyArguments)
    }

    @Test func appReviewConnectionSnapshotAtomicallyFreezesIdentityCredentialAndKnownHosts() throws {
        let knownHostsFile = try Self.makePrivateKnownHostsFile()
        defer {
            try? FileManager.default.removeItem(
                at: knownHostsFile.deletingLastPathComponent()
            )
        }
        let session = RemoteSession(
            host: "8.8.8.8",
            username: "appreview",
            port: 22
        )
        let credentialAccount = "appreview@8.8.8.8:22"
        var environment = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.smokeHostKey: "8.8.8.8",
            UITestSSHSessionEnvironment.smokeUserKey: "appreview",
            UITestSSHSessionEnvironment.smokeCredentialAccountKey: credentialAccount,
            UITestSSHSessionEnvironment.smokeNonceKey: String(repeating: "n", count: 32),
            UITestSSHSessionEnvironment.smokeKnownHostsFileKey: knownHostsFile.path,
            UITestSSHSessionEnvironment.smokeKnownHostsSHA256Key:
                String(repeating: "a", count: 64),
            UITestSSHSessionEnvironment.smokeBrokerPortKey: "49152",
            UITestSSHSessionEnvironment.smokeBrokerChallengeKey: String(repeating: "c", count: 32),
        ]
        let snapshot = SSHConnectionTestLaunchSnapshot(
            session: session,
            remoteCommand: "hostname",
            uiTestEnvironment: environment
        )

        session.host = "edited.example"
        session.username = "edited-user"
        environment[UITestSSHSessionEnvironment.smokeHostKey] = "edited.example"
        environment[UITestSSHSessionEnvironment.smokeUserKey] = "edited-user"
        environment[UITestSSHSessionEnvironment.smokeNonceKey] = "edited-nonce"
        environment[UITestSSHSessionEnvironment.smokeKnownHostsFileKey] = "/tmp/edited-known-hosts"

        #expect(snapshot.credentialAccount == credentialAccount)
        #expect(snapshot.appReviewBrokerRequest?.expectedHost == "8.8.8.8")
        #expect(snapshot.appReviewBrokerRequest?.expectedUsername == "appreview")
        #expect(snapshot.appReviewBrokerRequest?.expectedCredentialAccount == credentialAccount)
        #expect(snapshot.appReviewSmokeNonce == String(repeating: "n", count: 32))
        #expect(snapshot.appReviewKnownHostsFilePath == knownHostsFile.path)
        let arguments = try #require(snapshot.appReviewPasswordArguments)
        #expect(arguments.contains("appreview@8.8.8.8"))
        #expect(Self.argumentPair("-p", "22", existsIn: arguments))
        #expect(arguments.contains(SSHCommandBuilder.userKnownHostsFileOption(knownHostsFile.path)))
        #expect(arguments.last?.contains(UITestSSHSessionEnvironment.formalSmokeMarker) == true)
        #expect(!arguments.contains { $0.contains("edited.example") })
        #expect(!arguments.contains { $0.contains("edited-known-hosts") })
    }

    private static func originalSession() -> RemoteSession {
        RemoteSession(
            host: "original.example",
            username: "original-user",
            port: 2_222,
            identityFile: "/tmp/original-key",
            jumpHost: ""
        )
    }

    private static func redirect(_ session: RemoteSession) {
        session.host = "edited.example"
        session.username = "edited-user"
        session.port = 2_202
        session.identityFile = "/tmp/edited-key"
        session.jumpHost = "edited-jump.example"
    }

    private static func makePrivateKnownHostsFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "k.\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("known_hosts")
        try Data("original.example ssh-ed25519 AAAATEST\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        return file
    }

    nonisolated private static func successResult(for invocation: RemoteCommandInvocation) -> CommandResult {
        CommandResult(
            command: invocation.executable,
            exitCode: 0,
            standardOutput: "ok",
            standardError: ""
        )
    }

    private static func expectOriginalTarget(in invocation: RemoteCommandInvocation) {
        expectOriginalTarget(in: invocation.arguments)
    }

    private static func expectOriginalTarget(in arguments: [String]) {
        #expect(arguments.contains { $0.hasPrefix("original-user@original.example") })
        #expect(!arguments.contains { $0.hasPrefix("edited-user@edited.example") })
        #expect(argumentPair("-p", "2222", existsIn: arguments)
            || argumentPair("-P", "2222", existsIn: arguments))
        #expect(!argumentPair("-p", "2202", existsIn: arguments))
        #expect(!argumentPair("-P", "2202", existsIn: arguments))
    }

    private static func expectOneShotCredentialBroker(in invocation: RemoteCommandInvocation) {
        let environment = invocation.environment
        #expect(environment?[SSHCredentialAskpass.brokerSocketEnvironmentKey]?.hasSuffix("/s") == true)
        #expect(environment?[SSHCredentialAskpass.brokerChallengeEnvironmentKey]?.count == 64)
        #expect(environment?["JTS_TERMINAL_ASKPASS_SECRET"] == nil)
        #expect(environment?["JTS_TERMINAL_ASKPASS_CONSUMPTION_MARKER"] == nil)
        #expect(environment?["JTS_TERMINAL_CREDENTIAL_ACCOUNT"] == nil)
    }

    private static func argumentPair(_ first: String, _ second: String, existsIn arguments: [String]) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { $0 == first && $1 == second }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
