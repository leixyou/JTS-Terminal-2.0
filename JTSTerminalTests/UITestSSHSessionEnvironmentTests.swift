import Foundation
import SwiftData
import Testing
@testable import JTSTerminal

@MainActor
struct UITestSSHSessionEnvironmentTests {
    @Test func unitAndUITestHostsNeverUseThePersistentUserStore() {
        #expect(UnitTestHostPolicy.isActive(environment: [
            "XCTestBundlePath": "Contents/PlugIns/JTSTerminalRDP2Tests.xctest",
        ]))
        #expect(UnitTestHostPolicy.isActive(environment: [
            "XCTestConfigurationFilePath": "",
        ]))
        #expect(!UnitTestHostPolicy.isActive(environment: [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
        ]))
        #expect(UnitTestHostPolicy.shouldUseInMemoryModelStore(environment: [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
        ]))
        #expect(!UnitTestHostPolicy.shouldUseInMemoryModelStore(environment: [:]))
        #expect(UnitTestHostPolicy.shouldUseInMemoryModelStore(
            environment: [:],
            arguments: [
                "JTS Terminal",
                "\(SignedAskpassHostedSelfTest.argumentPrefix)3b0a4b7f-cdf5-4ed6-9025-9cd8719dfe0e",
            ]
        ))
    }

    @Test func signedAskpassSelfTestUsesAValidatedTokenAndStrictSuccessReport() throws {
        let token = try #require(UUID(uuidString: "3b0a4b7f-cdf5-4ed6-9025-9cd8719dfe0e"))
        let argument = "\(SignedAskpassHostedSelfTest.argumentPrefix)\(token.uuidString)"

        #expect(SignedAskpassHostedSelfTest.requestToken(arguments: ["JTS Terminal", argument]) == token)
        #expect(SignedAskpassHostedSelfTest.requestToken(arguments: [
            "JTS Terminal",
            "\(SignedAskpassHostedSelfTest.argumentPrefix)not-a-uuid",
        ]) == nil)

        let passed = SignedAskpassHostedSelfTest.Report(
            version: 1,
            token: token.uuidString.lowercased(),
            sandboxed: true,
            acceptedPasswordPrompt: true,
            rejectedKeyPassphrasePrompt: true,
            rejectedRepeatedRequest: true,
            rejectedMismatchedChallenge: true,
            cleanedRuntimeArtifacts: true
        )
        var failed = passed
        failed = SignedAskpassHostedSelfTest.Report(
            version: failed.version,
            token: failed.token,
            sandboxed: failed.sandboxed,
            acceptedPasswordPrompt: false,
            rejectedKeyPassphrasePrompt: failed.rejectedKeyPassphrasePrompt,
            rejectedRepeatedRequest: failed.rejectedRepeatedRequest,
            rejectedMismatchedChallenge: failed.rejectedMismatchedChallenge,
            cleanedRuntimeArtifacts: failed.cleanedRuntimeArtifacts
        )

        #expect(passed.succeeded)
        #expect(passed.failedChecks.isEmpty)
        #expect(!failed.succeeded)
        #expect(failed.failedChecks == ["acceptedPasswordPrompt"])
    }

    @Test func importedFixtureUsesTheProductionCodecImporterAndAutoStartIdentity() throws {
        let profile = RemoteSessionProfile(
            name: "Imported SSH without password",
            host: "missing-password.invalid",
            username: "imported-user",
            folder: "Imported"
        )
        let document = RemoteSessionProfileDocument(
            exportedAt: Date(timeIntervalSince1970: 1_752_710_400),
            sessions: [profile]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fixture = try encoder.encode(document).base64EncodedString()
        let environment = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.importedProfileFixtureKey: fixture,
            UITestSSHSessionEnvironment.disableAutoStartKey: "1",
        ]

        let decoded = try #require(
            try UITestSSHSessionEnvironment.importedProfiles(environment: environment)
        )
        let identity = try #require(
            UITestSSHSessionEnvironment.seededSession(environment: environment)
        )
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let imported = SessionProfileImporter.insert(decoded, into: context)
        try context.save()

        #expect(decoded == [profile])
        #expect(identity == UITestSSHSessionIdentity(
            host: profile.host,
            username: profile.username
        ))
        #expect(UITestSSHSessionEnvironment.suppressesAutoStart(
            forHost: profile.host,
            username: profile.username,
            environment: environment
        ))
        #expect(imported.count == 1)
        #expect(imported.first?.targetID == profile.id)
        #expect(imported.first?.host == profile.host)
        #expect(imported.first?.username == profile.username)
        let credentialAccount = CredentialStore.account(
            username: profile.username,
            host: profile.host,
            port: profile.port
        )
        #expect(UITestSSHSessionEnvironment.isolatesCredentialVault(
            account: credentialAccount,
            environment: environment
        ))
        #expect(UITestSSHSessionEnvironment.isolatesCredentialVault(
            account: "different@example.invalid:22",
            environment: environment
        ))
    }

    @Test func malformedImportedFixtureFailsClosed() {
        let environment = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.importedProfileFixtureKey: "not-base64",
        ]

        #expect(throws: UITestSSHSessionEnvironmentError.invalidImportedProfileFixture) {
            try UITestSSHSessionEnvironment.importedProfiles(environment: environment)
        }
        #expect(UITestSSHSessionEnvironment.seededSession(environment: environment) == nil)
        #expect(UITestSSHSessionEnvironment.isolatesCredentialVault(
            account: "edited@example.invalid:22",
            environment: environment
        ))
    }

    @Test func importedFixtureRoutesSSHCredentialMutationsToProcessMemory() throws {
        let environment = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.importedProfileFixtureKey: "fixture-present",
        ]
        let account = "fixture-\(UUID().uuidString.lowercased())@example.invalid:22"
        let secret = "process-memory-only"

        try SSHCredentialVaultAccess.save(
            secret: secret,
            account: account,
            environment: environment
        )
        #expect(UITestSSHCredentialStore.shared.read(account: account) == secret)
        #expect(try SSHCredentialVaultAccess.read(
            account: account,
            environment: environment
        ) == secret)

        try SSHCredentialVaultAccess.delete(account: account, environment: environment)
        #expect(UITestSSHCredentialStore.shared.read(account: account) == nil)
        #expect(try SSHCredentialVaultAccess.read(
            account: account,
            environment: environment
        ) == nil)
    }

    @Test func syntheticSessionTakesPriorityAndCanSuppressAutoStart() throws {
        let environment = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.sessionHostKey: " example.invalid ",
            UITestSSHSessionEnvironment.sessionUserKey: " ui-test ",
            UITestSSHSessionEnvironment.disableAutoStartKey: "1",
            UITestSSHSessionEnvironment.smokeHostKey: "review.example.com",
            UITestSSHSessionEnvironment.smokeUserKey: "appreview",
        ]

        let session = try #require(
            UITestSSHSessionEnvironment.seededSession(environment: environment)
        )
        #expect(session == UITestSSHSessionIdentity(host: "example.invalid", username: "ui-test"))
        #expect(UITestSSHSessionEnvironment.suppressesAutoStart(
            forHost: session.host,
            username: session.username,
            environment: environment
        ))
    }

    @Test func syntheticSmokeStatusRequiresExactNonnetworkIdentity() throws {
        let environment = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.smokeHostKey: "example.invalid",
            UITestSSHSessionEnvironment.smokeUserKey: "appreview",
            UITestSSHSessionEnvironment.smokeNonceKey: "nonce-123",
            UITestSSHSessionEnvironment.syntheticSmokeStatusKey: "1",
        ]

        let session = try #require(
            UITestSSHSessionEnvironment.seededSession(environment: environment)
        )
        #expect(session == UITestSSHSessionIdentity(host: "example.invalid", username: "appreview"))
        #expect(UITestSSHSessionEnvironment.appReviewSmokeNonce(
            forHost: session.host,
            username: session.username,
            environment: environment
        ) == "nonce-123")
        #expect(UITestSSHSessionEnvironment.appReviewSmokeNonce(
            forHost: "other.example.com",
            username: session.username,
            environment: environment
        ) == nil)
        #expect(!UITestSSHSessionEnvironment.suppressesAutoStart(
            forHost: session.host,
            username: session.username,
            environment: environment
        ))

        var formalEnvironment = environment
        formalEnvironment[UITestSSHSessionEnvironment.disableAutoStartKey] = "1"
        #expect(UITestSSHSessionEnvironment.suppressesAutoStart(
            forHost: session.host,
            username: session.username,
            environment: formalEnvironment
        ))
    }

    @Test func productionAndIncompleteEnvironmentsCannotConfigureBroker() throws {
        let productionEnvironment = [
            UITestSSHSessionEnvironment.smokeHostKey: "review.example.com",
            UITestSSHSessionEnvironment.smokeUserKey: "appreview",
            UITestSSHSessionEnvironment.smokeBrokerPortKey: "49152",
        ]
        let incompleteEnvironment = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.smokeHostKey: "review.example.com",
            UITestSSHSessionEnvironment.smokeBrokerPortKey: "49152",
        ]

        #expect(UITestSSHSessionEnvironment.seededSession(environment: productionEnvironment) == nil)
        #expect(try UITestSSHSessionEnvironment.formalSmokeBrokerRequest(
            forHost: "review.example.com",
            username: "appreview",
            credentialAccount: "appreview@review.example.com:22",
            environment: productionEnvironment
        ) == nil)
        #expect(UITestSSHSessionEnvironment.seededSession(environment: incompleteEnvironment) == nil)
        #expect(throws: AppReviewSSHCredentialBrokerError.incompleteConfiguration) {
            try UITestSSHSessionEnvironment.formalSmokeBrokerRequest(
                forHost: "review.example.com",
                username: "appreview",
                credentialAccount: "appreview@review.example.com:22",
                environment: incompleteEnvironment
            )
        }
    }

    @Test func seededProfileIsAlwaysANewCleanSSHProfile() {
        let identity = UITestSSHSessionIdentity(
            host: "review.example.com",
            username: "appreview"
        )

        let first = UITestSSHSessionEnvironment.cleanSession(for: identity)
        let second = UITestSSHSessionEnvironment.cleanSession(for: identity)

        #expect(first !== second)
        #expect(first.targetID != second.targetID)
        #expect(first.connectionType == .ssh)
        #expect(first.host == identity.host)
        #expect(first.username == identity.username)
        #expect(first.port == 22)
        #expect(first.identityFile.isEmpty)
        #expect(first.jumpHost.isEmpty)
        #expect(first.folder.isEmpty)
        #expect(!first.enableX11Forwarding)
        #expect(first.remotePath == "~")
        #expect(first.rdpProfileData == nil)
        #expect(!first.mcpEnabled)
        #expect(!first.mcpAlwaysAllowTerminalControl)
        #expect(first.mcpAlias.isEmpty)
    }

    @Test func smokeStatusIsStructuredNonceBoundAndSuccessRequiresExitZero() throws {
        let nonce = "nonce-123"
        let successResult = CommandResult(
            command: "ssh",
            exitCode: 0,
            standardOutput: UITestSSHSessionEnvironment.formalSmokeMarker + "\n",
            standardError: ""
        )
        let failureResult = CommandResult(
            command: "ssh",
            exitCode: 255,
            standardOutput: UITestSSHSessionEnvironment.formalSmokeMarker,
            standardError: "authentication failed"
        )
        let markerFailureResult = CommandResult(
            command: "ssh",
            exitCode: 0,
            standardOutput: "unexpected-output",
            standardError: ""
        )

        let ready = UITestSSHSmokeStatus.ready(nonce: nonce)
        let started = UITestSSHSmokeStatus.started(nonce: nonce)
        let succeeded = UITestSSHSmokeStatus.completed(
            nonce: nonce,
            result: successResult,
            expectedMarker: UITestSSHSessionEnvironment.formalSmokeMarker,
            credentialConsumed: true
        )
        let failed = UITestSSHSmokeStatus.completed(
            nonce: nonce,
            result: failureResult,
            expectedMarker: UITestSSHSessionEnvironment.formalSmokeMarker,
            credentialConsumed: true
        )
        let markerFailed = UITestSSHSmokeStatus.completed(
            nonce: nonce,
            result: markerFailureResult,
            expectedMarker: UITestSSHSessionEnvironment.formalSmokeMarker,
            credentialConsumed: true
        )
        let helperNotConsumed = UITestSSHSmokeStatus.completed(
            nonce: nonce,
            result: successResult,
            expectedMarker: UITestSSHSessionEnvironment.formalSmokeMarker,
            credentialConsumed: false
        )
        let decoded = try UITestSSHSessionEnvironment.decodeSmokeStatus(
            from: UITestSSHSessionEnvironment.smokeStatusData(succeeded)
        )

        #expect(ready.phase == .ready)
        #expect(ready.exitCode == nil)
        #expect(ready.markerMatched == nil)
        #expect(ready.credentialConsumed == nil)
        #expect(!ready.isSuccessful(matching: nonce))
        #expect(started.phase == .started)
        #expect(started.exitCode == nil)
        #expect(started.markerMatched == nil)
        #expect(!started.isSuccessful(matching: nonce))
        #expect(succeeded.phase == .succeeded)
        #expect(succeeded.markerMatched == true)
        #expect(succeeded.credentialConsumed == true)
        #expect(succeeded.isSuccessful(matching: nonce))
        #expect(!succeeded.isSuccessful(matching: "different-nonce"))
        #expect(failed.phase == .failed)
        #expect(failed.exitCode == 255)
        #expect(failed.markerMatched == true)
        #expect(!failed.isSuccessful(matching: nonce))
        #expect(markerFailed.phase == .failed)
        #expect(markerFailed.exitCode == 0)
        #expect(markerFailed.markerMatched == false)
        #expect(!markerFailed.isSuccessful(matching: nonce))
        #expect(helperNotConsumed.phase == .failed)
        #expect(helperNotConsumed.credentialConsumed == false)
        #expect(!helperNotConsumed.isSuccessful(matching: nonce))
        #expect(decoded == succeeded)
    }

    @Test func smokeStatusAccessibilityIdentifierRoundTripsWithoutSecrets() throws {
        let secret = "fixture-password-never-publish"
        let status = UITestSSHSmokeStatus(
            phase: .succeeded,
            nonce: "nonce-123",
            exitCode: 0,
            markerMatched: true,
            credentialConsumed: true
        )

        let identifier = try UITestSSHSessionEnvironment.smokeStatusAccessibilityIdentifier(status)
        let decoded = try UITestSSHSessionEnvironment.decodeSmokeStatus(
            accessibilityIdentifier: identifier
        )

        #expect(identifier.hasPrefix(
            UITestSSHSessionEnvironment.smokeStatusAccessibilityIdentifierPrefix
        ))
        #expect(!identifier.contains(secret))
        #expect(decoded == status)
    }

    @Test func smokeStatusAccessibilityIdentifierRejectsInvalidPayloads() {
        #expect(throws: UITestSSHSmokeStatusEncodingError.invalidAccessibilityIdentifier) {
            try UITestSSHSessionEnvironment.decodeSmokeStatus(
                accessibilityIdentifier: "wrong-prefix.eyJub25jZSI6Im5vbmNlLTEyMyJ9"
            )
        }
        #expect(throws: UITestSSHSmokeStatusEncodingError.invalidAccessibilityIdentifier) {
            try UITestSSHSessionEnvironment.decodeSmokeStatus(
                accessibilityIdentifier: UITestSSHSessionEnvironment.smokeStatusAccessibilityIdentifierPrefix
            )
        }
        #expect(throws: UITestSSHSmokeStatusEncodingError.invalidAccessibilityIdentifier) {
            try UITestSSHSessionEnvironment.decodeSmokeStatus(
                accessibilityIdentifier: UITestSSHSessionEnvironment.smokeStatusAccessibilityIdentifierPrefix + "%%%"
            )
        }
        #expect(throws: (any Error).self) {
            try UITestSSHSessionEnvironment.decodeSmokeStatus(
                accessibilityIdentifier: UITestSSHSessionEnvironment.smokeStatusAccessibilityIdentifierPrefix + "e30"
            )
        }
    }

    @Test func smokeStatusPayloadContainsOnlyStructuredNonsecretFields() throws {
        let matchingStatus = UITestSSHSmokeStatus(
            phase: .succeeded,
            nonce: "nonce-123",
            exitCode: 0,
            markerMatched: true,
            credentialConsumed: true
        )
        let data = try UITestSSHSessionEnvironment.smokeStatusData(matchingStatus)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["phase", "nonce", "exitCode", "markerMatched", "credentialConsumed"])
        #expect(object["phase"] as? String == "succeeded")
        #expect(object["nonce"] as? String == "nonce-123")
        #expect(object["exitCode"] as? Int == 0)
        #expect(object["markerMatched"] as? Bool == true)
        #expect(object["credentialConsumed"] as? Bool == true)
    }
}
