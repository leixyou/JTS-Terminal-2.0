import CryptoKit
import Foundation
import Testing
@testable import JTSMacCompanion

struct NativeRelayHostConfigurationTests {
    @Test func nativeConfigurationRequiresIndependentVerifiedTrustBeforeEnabling() throws {
        var value = NativeRelayHostConfiguration()
        try value.validate()
        #expect(value.trust == nil)
        #expect(value.attempt == nil)
        #expect(!value.enabled)
        value.enabled = true
        #expect(throws: (any Error).self) { try value.validate() }
    }

    @Test func trustMustMatchTheStoredControllerPinAndCannotAuthorizeSelf() throws {
        var value = NativeRelayHostConfiguration()
        let controller = P256.Signing.PrivateKey()
        let spki = controller.publicKey.derRepresentation
        let identifier = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
        value.trust = try trust(spki: spki, identifier: identifier)
        value.enabled = true
        try value.validate()
        value.trust = try trust(spki: spki, identifier: String(repeating: "0", count: 64))
        #expect(throws: (any Error).self) { try value.validate() }
        let host = try value.identity
        value.trust = try trust(spki: host.publicKeySPKI, identifier: host.deviceID)
        #expect(throws: (any Error).self) { try value.validate() }
    }

    @Test func localRevocationRemovesTrustAndKeepsTheHostIdentityStable() throws {
        var value = NativeRelayHostConfiguration()
        let before = try value.identity.deviceID
        let controller = P256.Signing.PrivateKey()
        let spki = controller.publicKey.derRepresentation
        let identifier = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
        value.trust = try trust(spki: spki, identifier: identifier)
        value.enabled = true
        value.trust = nil
        value.enabled = false
        try value.validate()
        #expect(try value.identity.deviceID == before)
        #expect(value.trust == nil)
    }

    @Test func failedRevocationFenceSurvivesRelaunchAndCannotRestoreTheOldGrant() throws {
        let suite = "JTSNativeRecoveryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var value = NativeRelayHostConfiguration()
        let key = P256.Signing.PrivateKey().publicKey.derRepresentation
        let identifier = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        value.trust = try trust(spki: key, identifier: identifier)
        value.enabled = true
        let preferences = NativeRelayHostPreferences(defaults: defaults)
        preferences.beginRevocation()
        let reloaded = NativeRelayHostPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        let denied = reloaded.applying(to: value)
        try denied.validate()
        #expect(reloaded.pendingRevocation)
        #expect(denied.trust == nil)
        #expect(!denied.enabled)
        #expect(denied.privateKey == value.privateKey)
        #expect(Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("nativeSystemSharing.") }) ==
            ["nativeSystemSharing.paused", "nativeSystemSharing.pendingLocalRevocation"])
    }

    @Test func pauseFenceKeepsTheKnownPinButRequiresAnExplicitResume() throws {
        let suite = "JTSNativeRecoveryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var value = NativeRelayHostConfiguration()
        let key = P256.Signing.PrivateKey().publicKey.derRepresentation
        let identifier = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        value.trust = try trust(spki: key, identifier: identifier)
        value.enabled = true
        let preferences = NativeRelayHostPreferences(defaults: defaults)
        preferences.pause()
        let paused = preferences.applying(to: value)
        #expect(paused.trust == value.trust)
        #expect(!paused.enabled)
        preferences.resumeExplicitly()
        #expect(preferences.applying(to: value).enabled)
    }

    private func trust(spki: Data, identifier: String) throws -> NativeRelayHostTrust {
        let authorization: [String: Any] = ["relayOrigin": "https://relay.example.com",
            "controllerSPKI": spki.base64EncodedString(), "controllerDeviceID": identifier,
            "pairingID": UUID().uuidString, "controlGrantID": UUID().uuidString,
            "fileGrantID": UUID().uuidString, "rdpGrantID": UUID().uuidString, "allowWindows10TLS12": false]
        let object: [String: Any] = ["name": "管理电脑", "authorization": authorization]
        return try JSONDecoder().decode(NativeRelayHostTrust.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
