import Foundation

/// Reads only non-secret routing data inherited by the UI-test process. The
/// password is never present here and is never copied into
/// `XCUIApplication.launchEnvironment`.
enum AppReviewSSHSmokeConfigurationEnvironment {
    static let hostKey = "JTS_TERMINAL_SMOKE_HOST"
    static let usernameKey = "JTS_TERMINAL_SMOKE_USER"
    static let credentialAccountKey = "JTS_TERMINAL_SMOKE_CREDENTIAL_ACCOUNT"
    static let knownHostsFileKey = "JTS_TERMINAL_SMOKE_KNOWN_HOSTS_FILE"
    static let knownHostsSHA256Key = "JTS_TERMINAL_SMOKE_KNOWN_HOSTS_SHA256"
    static let brokerPortKey = "JTS_TERMINAL_SMOKE_BROKER_PORT"
    static let challengeKey = "JTS_TERMINAL_SMOKE_BROKER_CHALLENGE"
    static let nonceKey = "JTS_TERMINAL_SMOKE_NONCE"

    enum ConfigurationError: LocalizedError {
        case incomplete

        var errorDescription: String? {
            "The formal App Review SSH smoke routing configuration is incomplete."
        }
    }

    static func loadIfAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SmokeConfiguration? {
        let keys = [
            hostKey,
            usernameKey,
            credentialAccountKey,
            knownHostsFileKey,
            knownHostsSHA256Key,
            brokerPortKey,
            challengeKey,
            nonceKey,
        ]
        guard keys.contains(where: { environment[$0] != nil }) else { return nil }

        guard let host = exactNonempty(environment[hostKey]),
              let username = exactNonempty(environment[usernameKey]),
              let credentialAccount = exactNonempty(environment[credentialAccountKey]),
              let knownHostsFilePath = exactNonempty(environment[knownHostsFileKey]),
              let knownHostsSHA256 = exactNonempty(environment[knownHostsSHA256Key]),
              let rawBrokerPort = exactNonempty(environment[brokerPortKey]),
              let brokerPort = UInt16(rawBrokerPort),
              brokerPort > 0,
              String(brokerPort) == rawBrokerPort,
              knownHostsSHA256.count == 64,
              knownHostsSHA256.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }),
              let challenge = exactNonempty(environment[challengeKey]),
              let nonce = exactNonempty(environment[nonceKey]),
              challenge.utf8.count >= 32,
              challenge.utf8.count <= 256,
              nonce.utf8.count >= 32,
              nonce.utf8.count <= 256 else {
            throw ConfigurationError.incomplete
        }

        return SmokeConfiguration(
            host: host,
            username: username,
            credentialAccount: credentialAccount,
            knownHostsFilePath: knownHostsFilePath,
            knownHostsSHA256: knownHostsSHA256,
            brokerPort: brokerPort,
            brokerChallenge: challenge,
            nonce: nonce
        )
    }

    private static func exactNonempty(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r") else {
            return nil
        }
        return value
    }
}
