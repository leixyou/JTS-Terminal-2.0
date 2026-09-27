import XCTest

final class AppReviewSSHSmokeConfigurationEnvironmentTests: XCTestCase {
    func testMissingConfigurationIsNotAFormalSmoke() throws {
        XCTAssertNil(
            try AppReviewSSHSmokeConfigurationEnvironment.loadIfAvailable(
                environment: [:]
            )
        )
    }

    func testCompleteConfigurationContainsNoPassword() throws {
        let environment = completeEnvironment()
        let configuration = try XCTUnwrap(
            AppReviewSSHSmokeConfigurationEnvironment.loadIfAvailable(
                environment: environment
            )
        )

        XCTAssertEqual(configuration.host, "8.8.8.8")
        XCTAssertEqual(configuration.username, "appreview")
        XCTAssertEqual(configuration.credentialAccount, "appreview@8.8.8.8:22")
        XCTAssertEqual(configuration.brokerPort, 49_152)
        XCTAssertEqual(configuration.knownHostsSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(configuration.nonce, String(repeating: "n", count: 32))
        XCTAssertFalse(environment.keys.contains(where: { $0.contains("PASSWORD") }))
        XCTAssertFalse(
            Mirror(reflecting: configuration).children.contains {
                $0.label?.localizedCaseInsensitiveContains("password") == true
            }
        )
    }

    func testPartialOrUnsafeConfigurationFailsClosed() {
        var partial = completeEnvironment()
        partial.removeValue(
            forKey: AppReviewSSHSmokeConfigurationEnvironment.challengeKey
        )
        XCTAssertThrowsError(
            try AppReviewSSHSmokeConfigurationEnvironment.loadIfAvailable(
                environment: partial
            )
        )

        var unsafe = completeEnvironment()
        unsafe[AppReviewSSHSmokeConfigurationEnvironment.brokerPortKey] = "0"
        XCTAssertThrowsError(
            try AppReviewSSHSmokeConfigurationEnvironment.loadIfAvailable(
                environment: unsafe
            )
        )
    }

    private func completeEnvironment() -> [String: String] {
        [
            AppReviewSSHSmokeConfigurationEnvironment.hostKey: "8.8.8.8",
            AppReviewSSHSmokeConfigurationEnvironment.usernameKey: "appreview",
            AppReviewSSHSmokeConfigurationEnvironment.credentialAccountKey:
                "appreview@8.8.8.8:22",
            AppReviewSSHSmokeConfigurationEnvironment.knownHostsFileKey:
                "/private/tmp/k.12345678/known_hosts",
            AppReviewSSHSmokeConfigurationEnvironment.knownHostsSHA256Key:
                String(repeating: "a", count: 64),
            AppReviewSSHSmokeConfigurationEnvironment.brokerPortKey: "49152",
            AppReviewSSHSmokeConfigurationEnvironment.challengeKey:
                String(repeating: "c", count: 32),
            AppReviewSSHSmokeConfigurationEnvironment.nonceKey:
                String(repeating: "n", count: 32),
        ]
    }
}
