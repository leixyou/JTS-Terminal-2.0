#if JTS_UI_TEST_SUPPORT
import Darwin
import Foundation

/// A Debug-only, production-entitlement regression entered through Launch
/// Services or the signed app executable. XCTest bundle injection requires
/// temporary sandbox exceptions, so it cannot prove that the shipping
/// app/helper inheritance topology works.
nonisolated enum SignedAskpassHostedSelfTest {
    static let argumentPrefix = "--jts-signed-askpass-self-test="

    struct Report: Codable, Equatable, Sendable {
        let version: Int
        let token: String
        let sandboxed: Bool
        let acceptedPasswordPrompt: Bool
        let rejectedKeyPassphrasePrompt: Bool
        let rejectedRepeatedRequest: Bool
        let rejectedMismatchedChallenge: Bool
        let cleanedRuntimeArtifacts: Bool

        var succeeded: Bool {
            version == 1
                && sandboxed
                && acceptedPasswordPrompt
                && rejectedKeyPassphrasePrompt
                && rejectedRepeatedRequest
                && rejectedMismatchedChallenge
                && cleanedRuntimeArtifacts
        }

        var failedChecks: [String] {
            var failures: [String] = []
            if version != 1 { failures.append("version") }
            if !sandboxed { failures.append("sandboxed") }
            if !acceptedPasswordPrompt { failures.append("acceptedPasswordPrompt") }
            if !rejectedKeyPassphrasePrompt { failures.append("rejectedKeyPassphrasePrompt") }
            if !rejectedRepeatedRequest { failures.append("rejectedRepeatedRequest") }
            if !rejectedMismatchedChallenge { failures.append("rejectedMismatchedChallenge") }
            if !cleanedRuntimeArtifacts { failures.append("cleanedRuntimeArtifacts") }
            return failures
        }
    }

    private struct HelperResult {
        let status: Int32
        let output: Data
        let error: Data
    }

    static var isRequested: Bool {
        requestToken(arguments: ProcessInfo.processInfo.arguments) != nil
    }

    static func requestToken(arguments: [String]) -> UUID? {
        guard let argument = arguments.first(where: { $0.hasPrefix(argumentPrefix) }) else {
            return nil
        }
        return UUID(uuidString: String(argument.dropFirst(argumentPrefix.count)))
    }

    static func runAndExitIfRequested() {
        guard let token = requestToken(arguments: ProcessInfo.processInfo.arguments) else {
            return
        }

        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let passwordFlow = runPasswordFlow()
        let mismatchFlow = runMismatchedChallengeFlow()
        let report = Report(
            version: 1,
            token: token.uuidString.lowercased(),
            sandboxed: sandboxed,
            acceptedPasswordPrompt: passwordFlow.accepted,
            rejectedKeyPassphrasePrompt: passwordFlow.rejectedKeyPassphrase,
            rejectedRepeatedRequest: passwordFlow.rejectedRepeatedRequest,
            rejectedMismatchedChallenge: mismatchFlow.rejected,
            cleanedRuntimeArtifacts: passwordFlow.cleaned && mismatchFlow.cleaned
        )

        if !report.succeeded {
            let message = "Signed askpass self-test failed: \(report.failedChecks.joined(separator: ","))\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        }
        Darwin.exit(report.succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func runPasswordFlow() -> (
        accepted: Bool,
        rejectedKeyPassphrase: Bool,
        rejectedRepeatedRequest: Bool,
        cleaned: Bool
    ) {
        let syntheticSecret = "jts-synthetic-askpass-self-test"
        do {
            let context = try SSHCredentialAskpass.launchContext(
                account: "ubuntu@example.test:22",
                secret: syntheticSecret
            )
            let markerURL = context.consumptionMarkerURL
            let socketPath = context.environment[
                SSHCredentialAskpass.brokerSocketEnvironmentKey
            ] ?? ""
            let socketDirectoryPath = socketPath.isEmpty
                ? ""
                : URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
            defer { context.cleanup() }

            let rejected = runHelper(
                context: context,
                prompt: "Enter passphrase for key '/tmp/id_ed25519':"
            )
            let rejectedKeyPassphrase = rejected?.status != 0
                && rejected?.output.isEmpty == true
                && rejected?.error.isEmpty == true
                && FileManager.default.fileExists(atPath: markerURL.path)

            let accepted = runHelper(
                context: context,
                prompt: "ubuntu@example.test's password:"
            )
            let acceptedPassword = accepted?.status == 0
                && accepted?.output == Data("\(syntheticSecret)\n".utf8)
                && accepted?.error.isEmpty == true
                && !FileManager.default.fileExists(atPath: markerURL.path)

            let repeated = runHelper(
                context: context,
                prompt: "ubuntu@example.test's password:"
            )
            let rejectedRepeatedRequest = repeated?.status != 0
                && repeated?.output.isEmpty == true
                && repeated?.error.isEmpty == true

            context.cleanup()
            let cleaned = waitUntilMissing(paths: [
                markerURL.path,
                socketPath,
                socketDirectoryPath,
            ])
            return (
                acceptedPassword,
                rejectedKeyPassphrase,
                rejectedRepeatedRequest,
                cleaned
            )
        } catch {
            return (false, false, false, false)
        }
    }

    private static func runMismatchedChallengeFlow() -> (rejected: Bool, cleaned: Bool) {
        do {
            let context = try SSHCredentialAskpass.launchContext(
                account: "ubuntu@example.test:22",
                secret: "jts-synthetic-mismatch-self-test",
                challenge: Array(0..<UInt8(SSHCredentialAskpass.challengeByteCount))
            )
            let markerURL = context.consumptionMarkerURL
            let socketPath = context.environment[
                SSHCredentialAskpass.brokerSocketEnvironmentKey
            ] ?? ""
            let socketDirectoryPath = socketPath.isEmpty
                ? ""
                : URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
            defer { context.cleanup() }

            var environment = context.environment
            environment[SSHCredentialAskpass.brokerChallengeEnvironmentKey] = String(
                repeating: "ff",
                count: SSHCredentialAskpass.challengeByteCount
            )
            let result = runHelper(
                context: context,
                prompt: "ubuntu@example.test's password:",
                environment: environment
            )
            // The first connection is authoritative even when its challenge is
            // wrong. Prove the production Swift broker closes its listener and
            // private socket directory before owner cleanup is allowed to mask
            // that lifecycle behavior.
            let brokerSelfClosedBeforeCleanup = waitUntilMissing(paths: [
                socketPath,
                socketDirectoryPath,
            ])
            let rejected = result?.status != 0
                && result?.output.isEmpty == true
                && result?.error.isEmpty == true
                && !context.credentialConsumed
                && FileManager.default.fileExists(atPath: markerURL.path)
                && brokerSelfClosedBeforeCleanup

            context.cleanup()
            let cleaned = waitUntilMissing(paths: [
                markerURL.path,
                socketPath,
                socketDirectoryPath,
            ])
            return (rejected, cleaned)
        } catch {
            return (false, false)
        }
    }

    private static func runHelper(
        context: SSHCredentialAskpass.LaunchContext,
        prompt: String,
        environment: [String: String]? = nil
    ) -> HelperResult? {
        guard let helperPath = context.environment["SSH_ASKPASS"] else { return nil }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = [prompt]
        process.environment = (environment ?? context.environment).merging([
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]) { current, _ in current }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }
        for _ in 0..<100 where process.isRunning {
            usleep(50_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return HelperResult(
            status: process.terminationStatus,
            output: stdout.fileHandleForReading.readDataToEndOfFile(),
            error: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private static func waitUntilMissing(paths: [String]) -> Bool {
        for _ in 0..<40 {
            if paths.allSatisfy({ $0.isEmpty || !FileManager.default.fileExists(atPath: $0) }) {
                return true
            }
            usleep(25_000)
        }
        return paths.allSatisfy({ $0.isEmpty || !FileManager.default.fileExists(atPath: $0) })
    }
}
#endif
