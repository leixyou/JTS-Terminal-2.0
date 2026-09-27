import Foundation
import Darwin

#if JTS_UI_TEST_SUPPORT
nonisolated struct UITestSSHSessionIdentity: Equatable, Sendable {
    let host: String
    let username: String
}

nonisolated struct UITestSSHSmokeStatus: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case ready
        case started
        case succeeded
        case failed
    }

    let phase: Phase
    let nonce: String
    let exitCode: Int32?
    let markerMatched: Bool?
    let credentialConsumed: Bool?

    static func ready(nonce: String) -> Self {
        Self(
            phase: .ready,
            nonce: nonce,
            exitCode: nil,
            markerMatched: nil,
            credentialConsumed: nil
        )
    }

    static func started(nonce: String) -> Self {
        Self(
            phase: .started,
            nonce: nonce,
            exitCode: nil,
            markerMatched: nil,
            credentialConsumed: nil
        )
    }

    static func completed(
        nonce: String,
        result: CommandResult,
        expectedMarker: String,
        credentialConsumed: Bool
    ) -> Self {
        let markerMatched = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines) == expectedMarker
        return Self(
            phase: result.succeeded && markerMatched && credentialConsumed
                ? .succeeded
                : .failed,
            nonce: nonce,
            exitCode: result.exitCode,
            markerMatched: markerMatched,
            credentialConsumed: credentialConsumed
        )
    }

    static func failed(nonce: String) -> Self {
        Self(
            phase: .failed,
            nonce: nonce,
            exitCode: nil,
            markerMatched: false,
            credentialConsumed: false
        )
    }

    func isSuccessful(matching expectedNonce: String) -> Bool {
        phase == .succeeded
            && nonce == expectedNonce
            && exitCode == 0
            && markerMatched == true
            && credentialConsumed == true
    }
}

nonisolated enum UITestSSHSmokeStatusEncodingError: Error, Equatable, Sendable {
    case invalidAccessibilityIdentifier
}

nonisolated enum UITestSSHSessionEnvironmentError: LocalizedError, Equatable, Sendable {
    case invalidKnownHostsFile
    case invalidImportedProfileFixture

    var errorDescription: String? {
        switch self {
        case .invalidKnownHostsFile:
            return "The formal SSH smoke known_hosts boundary is unavailable or insecure."
        case .invalidImportedProfileFixture:
            return "The UI test imported-profile fixture is invalid."
        }
    }
}

nonisolated enum UITestSSHSessionEnvironment {
    static let smokeStatusAccessibilityIdentifierPrefix = "app-review-ssh-smoke-status.v1."
    static let isUITestingKey = "JTS_TERMINAL_UI_TESTING"
    static let sessionHostKey = "JTS_TERMINAL_UI_TEST_SESSION_HOST"
    static let sessionUserKey = "JTS_TERMINAL_UI_TEST_SESSION_USER"
    static let importedProfileFixtureKey = "JTS_TERMINAL_UI_TEST_IMPORTED_PROFILE_BASE64"
    static let disableAutoStartKey = "JTS_TERMINAL_UI_TEST_DISABLE_SSH_AUTOSTART"
    static let smokeHostKey = "JTS_TERMINAL_UI_SMOKE_HOST"
    static let smokeUserKey = "JTS_TERMINAL_UI_SMOKE_USER"
    static let smokeCredentialAccountKey = "JTS_TERMINAL_UI_SMOKE_CREDENTIAL_ACCOUNT"
    static let smokeNonceKey = "JTS_TERMINAL_UI_SMOKE_NONCE"
    static let smokeKnownHostsFileKey = "JTS_TERMINAL_UI_SMOKE_KNOWN_HOSTS_FILE"
    static let smokeKnownHostsSHA256Key = "JTS_TERMINAL_UI_SMOKE_KNOWN_HOSTS_SHA256"
    static let smokeBrokerPortKey = "JTS_TERMINAL_UI_SMOKE_BROKER_PORT"
    static let smokeBrokerChallengeKey = "JTS_TERMINAL_UI_SMOKE_BROKER_CHALLENGE"
    static let syntheticSmokeStatusKey = "JTS_TERMINAL_UI_SYNTHETIC_SMOKE_STATUS"
    static let formalSmokeMarker = "JTS_APP_REVIEW_SSH_OK_V1"

    static func seededSession(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UITestSSHSessionIdentity? {
        guard environment[isUITestingKey] == "1" else { return nil }

        if let profile = try? importedProfiles(environment: environment)?.first {
            return UITestSSHSessionIdentity(host: profile.host, username: profile.username)
        }

        if let structuralSession = identity(
            hostKey: sessionHostKey,
            userKey: sessionUserKey,
            environment: environment
        ) {
            return structuralSession
        }

        return identity(
            hostKey: smokeHostKey,
            userKey: smokeUserKey,
            environment: environment
        )
    }

    static func importedProfiles(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [RemoteSessionProfile]? {
        guard environment[isUITestingKey] == "1",
              let encoded = environment[importedProfileFixtureKey] else {
            return nil
        }
        guard !encoded.isEmpty,
              encoded.utf8.count <= 64 * 1024,
              let data = Data(base64Encoded: encoded),
              data.count <= 48 * 1024 else {
            throw UITestSSHSessionEnvironmentError.invalidImportedProfileFixture
        }

        do {
            let profiles = try SessionProfileCodec.decode(data)
            guard !profiles.isEmpty, profiles.count <= 16 else {
                throw UITestSSHSessionEnvironmentError.invalidImportedProfileFixture
            }
            return profiles
        } catch is UITestSSHSessionEnvironmentError {
            throw UITestSSHSessionEnvironmentError.invalidImportedProfileFixture
        } catch {
            throw UITestSSHSessionEnvironmentError.invalidImportedProfileFixture
        }
    }

    /// Structural UI fixtures must never open the real encrypted credential
    /// vault that belongs to the installed app. They use an in-memory store
    /// while exercising the same prompt, save, and reconnect decisions. The
    /// isolation applies to the whole fixture process so editing the imported
    /// host or username cannot fall through to a real credential account.
    static func isolatesCredentialVault(
        account _: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[isUITestingKey] == "1"
            && environment[importedProfileFixtureKey] != nil
    }

    static func formalSmokeBrokerRequest(
        forHost host: String,
        username: String,
        credentialAccount: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppReviewSSHCredentialBrokerRequest? {
        try AppReviewSSHCredentialBrokerClient.configuredRequest(
            forHost: host,
            username: username,
            credentialAccount: credentialAccount,
            environment: environment
        )
    }

    static func smokeNonce(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard environment[isUITestingKey] == "1" else { return nil }
        return trimmedNonempty(environment[smokeNonceKey])
    }

    static func appReviewSmokeNonce(
        forHost host: String,
        username: String,
        credentialAccount: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let credentialAccount,
           let request = try? formalSmokeBrokerRequest(
               forHost: host,
               username: username,
               credentialAccount: credentialAccount,
               environment: environment
           ) {
            return request.nonce
        }
        guard environment[isUITestingKey] == "1",
              environment[syntheticSmokeStatusKey] == "1",
              host == "example.invalid",
              username == "appreview" else {
            return nil
        }
        return smokeNonce(environment: environment)
    }

    static func cleanSession(for identity: UITestSSHSessionIdentity) -> RemoteSession {
        RemoteSession(
            name: "UI Test \(identity.host)",
            host: identity.host,
            username: identity.username,
            port: 22,
            connectionType: .ssh,
            identityFile: "",
            jumpHost: "",
            folder: "",
            enableX11Forwarding: false,
            remotePath: "~"
        )
    }

    static func smokeStatusData(_ status: UITestSSHSmokeStatus) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(status)
    }

    static func decodeSmokeStatus(from data: Data) throws -> UITestSSHSmokeStatus {
        try JSONDecoder().decode(UITestSSHSmokeStatus.self, from: data)
    }

    static func smokeStatusAccessibilityIdentifier(
        _ status: UITestSSHSmokeStatus
    ) throws -> String {
        let payload = try smokeStatusData(status)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return smokeStatusAccessibilityIdentifierPrefix + payload
    }

    static func decodeSmokeStatus(
        accessibilityIdentifier identifier: String
    ) throws -> UITestSSHSmokeStatus {
        guard identifier.hasPrefix(smokeStatusAccessibilityIdentifierPrefix) else {
            throw UITestSSHSmokeStatusEncodingError.invalidAccessibilityIdentifier
        }

        let payload = String(identifier.dropFirst(smokeStatusAccessibilityIdentifierPrefix.count))
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !payload.isEmpty,
              payload.unicodeScalars.allSatisfy(allowedCharacters.contains),
              payload.count % 4 != 1 else {
            throw UITestSSHSmokeStatusEncodingError.invalidAccessibilityIdentifier
        }

        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64) else {
            throw UITestSSHSmokeStatusEncodingError.invalidAccessibilityIdentifier
        }
        return try decodeSmokeStatus(from: data)
    }

    static func suppressesAutoStart(
        forHost host: String,
        username: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard environment[isUITestingKey] == "1",
              environment[disableAutoStartKey] == "1",
              let seededSession = seededSession(environment: environment) else {
            return false
        }

        return seededSession.host == host && seededSession.username == username
    }

    /// Formal UI smoke profiles are ephemeral and receive their credential
    /// directly from the one-shot broker. Opening Server Properties must not
    /// even read (and thereby initialize) the persistent credential vault.
    static func bypassesPersistentCredentialVault(
        forHost host: String,
        username: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard environment[isUITestingKey] == "1",
              environment[smokeBrokerPortKey] != nil,
              let smokeIdentity = identity(
                  hostKey: smokeHostKey,
                  userKey: smokeUserKey,
                  environment: environment
              ) else {
            return false
        }
        return smokeIdentity.host == host && smokeIdentity.username == username
    }

    private static func identity(
        hostKey: String,
        userKey: String,
        environment: [String: String]
    ) -> UITestSSHSessionIdentity? {
        guard let host = trimmedNonempty(environment[hostKey]),
              let username = trimmedNonempty(environment[userKey]) else {
            return nil
        }

        return UITestSSHSessionIdentity(host: host, username: username)
    }

    static func isPrivateFormalKnownHostsFile(
        at path: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        guard !path.contains("\n"), !path.contains("\r") else { return false }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        let containerTemporaryDirectory = directoryURL.deletingLastPathComponent()
        let expectedTemporaryDirectory = temporaryDirectory.standardizedFileURL
        let directoryName = directoryURL.lastPathComponent
        let randomSuffix = directoryName.dropFirst(2)
        guard fileURL.path == path,
              fileURL.lastPathComponent == "known_hosts",
              directoryName.hasPrefix("k."),
              randomSuffix.count == 8,
              randomSuffix.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
              }),
              containerTemporaryDirectory == expectedTemporaryDirectory else {
            return false
        }

        var fileMetadata = stat()
        var directoryMetadata = stat()
        guard Darwin.lstat(fileURL.path, &fileMetadata) == 0,
              Darwin.lstat(directoryURL.path, &directoryMetadata) == 0 else {
            return false
        }
        return fileMetadata.st_uid == getuid()
            && fileMetadata.st_mode & S_IFMT == S_IFREG
            && fileMetadata.st_mode & 0o777 == 0o600
            && fileMetadata.st_nlink == 1
            && fileMetadata.st_size > 0
            && fileMetadata.st_size <= 64 * 1024
            && directoryMetadata.st_uid == getuid()
            && directoryMetadata.st_mode & S_IFMT == S_IFDIR
            && directoryMetadata.st_mode & 0o777 == 0o700
    }

    /// Formal smoke routing now names a not-yet-created destination. The
    /// sandboxed app materializes the authenticated pinned host-key bytes at
    /// this exact path after the loopback broker handoff.
    static func isFormalKnownHostsDestination(
        _ path: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        guard !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r") else {
            return false
        }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        let directoryName = directoryURL.lastPathComponent
        let randomSuffix = directoryName.dropFirst(2)
        return fileURL.path == path
            && fileURL.lastPathComponent == "known_hosts"
            && directoryName.hasPrefix("k.")
            && randomSuffix.count == 8
            && randomSuffix.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
            && directoryURL.deletingLastPathComponent()
                == temporaryDirectory.standardizedFileURL
    }

    private static func trimmedNonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated final class UITestSSHCredentialStore: @unchecked Sendable {
    static let shared = UITestSSHCredentialStore()

    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func read(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func save(secret: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}
#endif
