//
//  JTSTerminaliOSTests.swift
//  JTSTerminaliOSTests
//
//  Created by Codex on 2026/6/26.
//

import Foundation
import Testing
@testable import JTSTerminaliOS

struct JTSTerminaliOSTests {
    @Test func profileCodecRoundTripsSSHProfiles() throws {
        let profiles = [
            MobileServerProfile(
                name: "Prod API",
                host: "api.example.com",
                username: "deploy",
                port: 2200,
                remotePath: "/srv/api",
                identityFile: "id_ed25519"
            )
        ]

        let data = try MobileServerProfileCodec.encode(profiles)
        let decoded = try MobileServerProfileCodec.decode(data)

        #expect(decoded.count == 1)
        #expect(decoded[0].name == "Prod API")
        #expect(decoded[0].host == "api.example.com")
        #expect(decoded[0].username == "deploy")
        #expect(decoded[0].port == 2200)
        #expect(decoded[0].remotePath == "/srv/api")
        #expect(decoded[0].identityFile == "id_ed25519")
    }

    @Test func profileCodecFiltersMacOnlyConnectionTypes() throws {
        let json = """
        {
          "version": 1,
          "exportedAt": "2026-06-26T00:00:00Z",
          "sessions": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "name": "Local Root",
              "connectionType": "Local Shell",
              "host": "",
              "username": "tester",
              "port": 22,
              "remotePath": "~"
            },
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "name": "Prod",
              "connectionType": "SSH",
              "host": "prod.example.com",
              "username": "ubuntu",
              "port": 22,
              "remotePath": "/var/www"
            }
          ]
        }
        """

        let decoded = try MobileServerProfileCodec.decode(Data(json.utf8))

        #expect(decoded.map(\.name) == ["Prod"])
        #expect(decoded[0].isConnectable)
    }

    @Test func remotePathHelpersHandleRootHomeAndChildren() {
        #expect(MobileRemotePath.child("app.log", in: "/var/log") == "/var/log/app.log")
        #expect(MobileRemotePath.child("app.log", in: "/") == "/app.log")
        #expect(MobileRemotePath.parent(of: "/var/log/app.log") == "/var/log")
        #expect(MobileRemotePath.parent(of: "/") == "~")
        #expect(MobileRemotePath.parent(of: "~") == "~")
    }

    @Test func profileConnectabilityRequiresSSHAddressParts() {
        #expect(!MobileServerProfile(host: "", username: "deploy").isConnectable)
        #expect(!MobileServerProfile(host: "host.example.com", username: "", port: 22).isConnectable)
        #expect(!MobileServerProfile(host: "host.example.com", username: "deploy", port: 0).isConnectable)
        #expect(MobileServerProfile(host: "host.example.com", username: "deploy", port: 22).isConnectable)
    }

    @Test func mobileSSHErrorMessageClassifiesCommonTransportFailures() {
        let profile = MobileServerProfile(host: "127.0.0.1", username: "tester", port: 2222)
        let refused = NSError(
            domain: "NIOPosix.NIOConnectionError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed. (NIOPosix.NIOConnectionError error 1.)"]
        )
        let denied = NSError(
            domain: "NIOSSH",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied (publickey,password)."]
        )
        let timeout = MobileNativeSSHError.connectionTimedOut(host: profile.host, port: profile.port)

        #expect(MobileCitadelClientFactory.userFacingMessage(for: refused, profile: profile).contains("Cannot reach"))
        #expect(MobileCitadelClientFactory.userFacingMessage(for: denied, profile: profile).contains("Authentication failed"))
        #expect(MobileCitadelClientFactory.userFacingMessage(for: timeout, profile: profile).contains("Connection timed out"))
    }

    @Test func credentialPromptClassifiesMissingAndRejectedAuthentication() {
        let missing = MobileNativeSSHError.missingAuthentication
        let rejected = MobileNativeSSHError.connectionFailed(
            "Authentication failed for server.example.com:22."
        )
        let citadelRejected = TestAuthenticationError()
        let unreachable = MobileNativeSSHError.connectionFailed(
            "Cannot reach the SSH service at server.example.com:22."
        )

        #expect(MobileCitadelClientFactory.credentialPromptReason(for: missing) == .missing)
        #expect(MobileCitadelClientFactory.credentialPromptReason(for: rejected) == .authenticationFailed)
        #expect(MobileCitadelClientFactory.credentialPromptReason(for: citadelRejected) == .authenticationFailed)
        #expect(MobileCitadelClientFactory.userFacingMessage(for: citadelRejected).contains("Authentication failed"))
        #expect(MobileCitadelClientFactory.credentialPromptReason(for: unreachable) == nil)
    }

    @Test func terminalSizeRejectsTransientLayoutMeasurements() {
        #expect(!MobileTerminalSize(cols: 1, rows: 24).isUsable)
        #expect(!MobileTerminalSize(cols: 80, rows: 1).isUsable)
        #expect(MobileTerminalSize(cols: 20, rows: 2).isUsable)
        #expect(MobileTerminalSize(cols: 80, rows: 24).isUsable)
    }

    @Test @MainActor func sessionStoreRetainsWorkspaceUntilExplicitlyClosed() {
        let suiteName = "JTSTerminaliOSTests.session-retention.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MobileSessionStore(userDefaults: defaults, resetPersistentState: true)
        let profile = MobileServerProfile(
            name: "Retained",
            host: "server.example.com",
            username: "tester"
        )
        store.upsert(profile)

        let firstSession = store.session(for: store.profiles[0])
        firstSession.selectedPanel = .files
        firstSession.isHeaderExpanded = false
        let resumedSession = store.session(for: store.profiles[0])

        #expect(firstSession === resumedSession)
        #expect(resumedSession.selectedPanel == .files)
        #expect(!resumedSession.isHeaderExpanded)
        #expect(store.hasSession(for: store.profiles[0]))

        store.endSession(for: store.profiles[0])
        let replacementSession = store.session(for: store.profiles[0])

        #expect(firstSession !== replacementSession)
    }

    @Test @MainActor func editingAProfileClosesItsRetainedSession() {
        let suiteName = "JTSTerminaliOSTests.session-edit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MobileSessionStore(userDefaults: defaults, resetPersistentState: true)
        var profile = MobileServerProfile(
            name: "Original",
            host: "server.example.com",
            username: "tester"
        )
        store.upsert(profile)
        let originalSession = store.session(for: store.profiles[0])

        profile.name = "Edited"
        store.upsert(profile)
        let replacementSession = store.session(for: store.profiles[0])

        #expect(originalSession !== replacementSession)
    }

    @Test func knownHostsTrustOnFirstUseAndRejectChangedKeys() {
        let suiteName = "JTSTerminaliOSTests.known-hosts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"
        let replacementKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC"

        guard case .untrusted(let firstChallenge) = MobileKnownHostsStore.evaluate(
            host: "Server.Example.com",
            port: 2222,
            presentedKey: firstKey,
            defaults: defaults
        ) else {
            Issue.record("An unknown host key must not be trusted automatically.")
            return
        }
        #expect(firstChallenge.kind == .unknown)
        #expect(firstChallenge.fingerprint == "SHA256:RXm/ruZ0eTzRXKwi1AQEDynB0VgHQ2ac9KPSFdf/YnA")
        #expect(firstChallenge.keyAlgorithm == "ssh-ed25519")

        MobileKnownHostsStore.trust(firstChallenge, defaults: defaults)
        #expect(MobileKnownHostsStore.evaluate(
            host: "server.example.com",
            port: 2222,
            presentedKey: firstKey + " comment",
            defaults: defaults
        ) == .trusted)

        guard case .untrusted(let changedChallenge) = MobileKnownHostsStore.evaluate(
            host: "server.example.com",
            port: 2222,
            presentedKey: replacementKey,
            defaults: defaults
        ) else {
            Issue.record("A different key for a trusted endpoint must be rejected.")
            return
        }
        #expect(changedChallenge.kind == .changed(
            previousFingerprint: "SHA256:RXm/ruZ0eTzRXKwi1AQEDynB0VgHQ2ac9KPSFdf/YnA"
        ))
        #expect(changedChallenge.fingerprint == "SHA256:baqJQcVDEweKmw1OiZxGooCG2MGxYtwsQQzzOstxmiA")

        // Trust is bound to the port as well as the host.
        if case .trusted = MobileKnownHostsStore.evaluate(
            host: "server.example.com",
            port: 22,
            presentedKey: firstKey,
            defaults: defaults
        ) {
            Issue.record("A key trusted for one port must not be trusted for another.")
        }
    }

    @Test func hostKeyErrorsAskForVerificationInsteadOfAPassword() {
        let challenge = MobileHostKeyChallenge(
            host: "server.example.com",
            port: 22,
            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB",
            fingerprint: "SHA256:RXm/ruZ0eTzRXKwi1AQEDynB0VgHQ2ac9KPSFdf/YnA",
            kind: .unknown
        )
        let error = MobileNativeSSHError.hostKeyNotTrusted(challenge)

        #expect(error.hostKeyChallenge == challenge)
        #expect(MobileCitadelClientFactory.credentialPromptReason(for: error) == nil)
        #expect(MobileCitadelClientFactory.userFacingMessage(for: error).contains(challenge.fingerprint))
    }

    @Test func credentialsAreKeyedByProfileNotByEndpoint() {
        let first = MobileServerProfile(name: "One", host: "server.example.com", username: "deploy")
        let second = MobileServerProfile(name: "Two", host: "server.example.com", username: "deploy")
        var edited = first
        edited.host = "renamed.example.com"

        #expect(
            MobileCredentialStore.account(for: first, kind: .password)
                != MobileCredentialStore.account(for: second, kind: .password)
        )
        #expect(
            MobileCredentialStore.account(for: first, kind: .privateKey)
                == MobileCredentialStore.account(for: edited, kind: .privateKey)
        )
        #expect(
            MobileCredentialStore.legacyAccount(for: first, kind: .password)
                == "deploy@server.example.com:22#password"
        )
    }
}

private struct TestAuthenticationError: LocalizedError {
    var errorDescription: String? { "allAuthenticationOptionsFailed" }
}
