import Foundation
import Testing
@testable import JTSMacCompanion

struct CompanionIdentityTests {
    @Test func authorizationRequiresMatchingDeviceAndToken() throws {
        let id = UUID()
        let credential = try CompanionIdentity.newCredential()
        let identity = CompanionIdentity(serverID: UUID(), clients: [AuthorizedDesktopClient(
            id: id, name: "Test Mac", credentialHash: CompanionIdentity.hash(credential),
            psk: try CompanionIdentity.randomBytes(), pairedAt: Date())])
        #expect(identity.authorizedClient(deviceID: id, credential: credential) != nil)
        #expect(identity.authorizedClient(deviceID: UUID(), credential: credential) == nil)
        #expect(identity.authorizedClient(deviceID: id, credential: "wrong") == nil)
    }

    @Test func revocationRemovesAuthorizationAndTransportKey() throws {
        let credential = try CompanionIdentity.newCredential()
        let client = AuthorizedDesktopClient(id: UUID(), name: "Test", credentialHash: CompanionIdentity.hash(credential),
            psk: try CompanionIdentity.randomBytes(), pairedAt: Date())
        var identity = CompanionIdentity(serverID: UUID(), clients: [client])
        identity.clients.removeAll { $0.id == client.id }
        #expect(identity.authorizedClient(deviceID: client.id, credential: credential) == nil)
        #expect(identity.clients.isEmpty)
    }

    @Test func credentialsUseIndependentRandomKeys() throws {
        let first = try CompanionIdentity.newCredential()
        let second = try CompanionIdentity.newCredential()
        #expect(first.count == 43)
        #expect(first != second)
        #expect(!first.contains("+") && !first.contains("/") && !first.contains("="))
    }

    @Test func persistedIdentityRejectsDuplicateDevicesAndMalformedKeys() throws {
        let client = AuthorizedDesktopClient(id: UUID(), name: "Test", credentialHash: Data(repeating: 1, count: 32),
            psk: Data(repeating: 2, count: 32), pairedAt: Date())
        try CompanionIdentity(serverID: UUID(), clients: [client]).validate()
        #expect(throws: (any Error).self) { try CompanionIdentity(serverID: UUID(), clients: [client, client]).validate() }
        let invalid = AuthorizedDesktopClient(id: UUID(), name: "Test", credentialHash: Data(), psk: Data(), pairedAt: Date())
        #expect(throws: (any Error).self) { try CompanionIdentity(serverID: UUID(), clients: [invalid]).validate() }
    }
}
