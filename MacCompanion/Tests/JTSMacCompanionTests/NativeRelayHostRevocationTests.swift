import CryptoKit
import Foundation
import JTSRelayEnrollment
import Testing
@testable import JTSMacCompanion

private final class RevocationMasterKeys: CompanionVaultMasterKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return key }
    func insert(_ value: Data) throws { lock.lock(); defer { lock.unlock() }; key = value }
}

struct NativeRelayHostRevocationTests {
    @Test func initialIdentityCreationCannotOverwriteAnExistingEncryptedHostRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JTSHostIdentityTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeRelayHostStore(vault: CompanionCredentialVault(rootDirectory: directory, masterKeys: RevocationMasterKeys()))
        let existing = try RevocationFixture().value
        try store.create(existing)
        #expect(throws: (any Error).self) { try store.create(NativeRelayHostConfiguration()) }
        #expect(try store.load()?.privateKey == existing.privateKey)
        #expect(try store.load()?.trust == existing.trust)
    }

    @Test func signedRemoteRevocationDurablyDeniesTheGrantBeforeItsReceipt() throws {
        var fixture = try RevocationFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JTSHostRevocation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = CompanionCredentialVault(rootDirectory: directory, masterKeys: RevocationMasterKeys())
        let store = NativeRelayHostStore(vault: vault)
        try fixture.value.deny(fixture.request, authorization: fixture.authorization)
        try store.save(fixture.value)
        let restored = try #require(try store.load())
        #expect(restored.trust == nil)
        #expect(!restored.enabled)
        #expect(restored.hasPendingRevocations)
        #expect(restored.revocations.first?.request == fixture.request)
        #expect(restored.revocations.first?.receipt == nil)
        #expect(restored.revocations.first?.authorization == fixture.authorization)
    }

    @Test func exactSignedReceiptSurvivesRestartAndRevokedEpochCannotBeReenabled() async throws {
        var fixture = try RevocationFixture()
        try fixture.value.deny(fixture.request, authorization: fixture.authorization)
        let client = try EnrollmentHostRevocationClient(privateKey: fixture.value.privateKey,
            relayOrigin: fixture.authorization.relayOrigin)
        let receipt = try await client.prepareReceipt(for: fixture.request, authorization: fixture.authorization)
        fixture.value.revocations[0].receipt = receipt
        fixture.value.revocations[0].completed = true
        let restored = try JSONDecoder().decode(NativeRelayHostConfiguration.self,
            from: JSONEncoder().encode(fixture.value))
        try restored.validate()
        #expect(restored.revocations.first?.receipt == receipt)
        #expect(!restored.hasPendingRevocations)
        var replayed = restored
        replayed.trust = NativeRelayHostTrust(name: "old epoch", authorization: fixture.authorization)
        replayed.enabled = true
        #expect(throws: (any Error).self) { try replayed.validate() }
    }

    @Test func foreignGrantOrForgedControllerSignatureCannotDeleteCurrentTrust() throws {
        var fixture = try RevocationFixture()
        let before = fixture.value.trust
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.request)) as! [String: Any]
        object["rdpGrantId"] = UUID().uuidString.lowercased()
        let forged = try JSONDecoder().decode(EnrollmentRevocation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) { try fixture.value.deny(forged, authorization: fixture.authorization) }
        #expect(fixture.value.trust == before)
        #expect(fixture.value.enabled)
        #expect(fixture.value.revocations.isEmpty)
    }
}

private struct RevocationFixture {
    var value = NativeRelayHostConfiguration()
    let authorization: EnrollmentHostAuthorization
    let request: EnrollmentRevocation

    init() throws {
        let controller = P256.Signing.PrivateKey(), spki = controller.publicKey.derRepresentation
        let controllerID = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
        let origin = "https://relay.example.com"
        let pairing = UUID().uuidString.lowercased(), control = UUID().uuidString.lowercased()
        let file = UUID().uuidString.lowercased(), rdp = UUID().uuidString.lowercased()
        let object: [String: Any] = ["relayOrigin": origin, "controllerSPKI": spki.base64EncodedString(),
            "controllerDeviceID": controllerID, "pairingID": pairing, "controlGrantID": control,
            "fileGrantID": file, "rdpGrantID": rdp, "allowWindows10TLS12": false]
        authorization = try JSONDecoder().decode(EnrollmentHostAuthorization.self, from: JSONSerialization.data(withJSONObject: object))
        value.trust = NativeRelayHostTrust(name: "管理电脑", authorization: authorization)
        value.enabled = true
        let peer = try value.identity.deviceID, id = UUID().uuidString.lowercased(), at: Int64 = 1_790_000_000
        let transcript = Data(["JTS-PAIR-REVOKE-2", id, origin, controllerID, peer, pairing, control,
            file, rdp, String(at)].joined(separator: "\n").utf8)
        let requestObject: [String: Any] = ["version": 2, "revocationId": id, "relayOrigin": origin,
            "controllerDeviceId": controllerID, "peerDeviceId": peer, "pairingId": pairing, "grantId": control,
            "fileGrantId": file, "rdpGrantId": rdp, "requestedAtUnixSeconds": at,
            "signatureBase64": try controller.signature(for: transcript).rawRepresentation.base64EncodedString()]
        request = try JSONDecoder().decode(EnrollmentRevocation.self, from: JSONSerialization.data(withJSONObject: requestObject))
        try value.validate()
    }
}
