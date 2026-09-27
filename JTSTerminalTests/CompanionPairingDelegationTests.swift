#if ENABLE_RDP_2
import CryptoKit
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct CompanionPairingDelegationTests {
    private let targetID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-444444444444")!
    private let binding = "rdp://reviewer@192.0.2.198:3389"
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func exportUsesExactWindowsContractAndOnlyPublicIdentity() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory, fixture)
        let exported = try await store.createExport(
            targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date
        )
        let json = try #require(JSONSerialization.jsonObject(with: exported.requestJSON) as? [String: Any])
        #expect(Set(json.keys) == Set([
            "schemaVersion", "grantId", "authorizationSource", "targetId", "targetBinding",
            "macIdentity", "expectedWindows", "issuedAtUtc", "expiresAtUtc", "authorizationReference",
        ]))
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["authorizationSource"] as? String == "ownerDelegated")
        #expect(json["authorizationReference"] as? String == "device-ai-control-enabled")
        #expect((json["targetId"] as? String).flatMap(UUID.init(uuidString:)) == targetID)
        #expect((json["grantId"] as? String).flatMap(UUID.init(uuidString:)) == exported.grant.grantID)
        let mac = try #require(json["macIdentity"] as? [String: Any])
        #expect(Set(mac.keys) == Set(["deviceId", "fingerprintSha256", "publicKeyBase64"]))
        let publicKey = fixture.identity.signingKey.publicKey.derRepresentation
        #expect(mac["publicKeyBase64"] as? String == publicKey.base64EncodedString())
        #expect(mac["fingerprintSha256"] as? String == fixture.peer.clientFingerprintSHA256)
        let windows = try #require(json["expectedWindows"] as? [String: Any])
        #expect(Set(windows.keys) == Set(["deviceId", "fingerprintSha256"]))
        #expect(windows["fingerprintSha256"] as? String == fixture.peer.fingerprintSHA256)
        let formatter = ISO8601DateFormatter()
        let issued = try #require((json["issuedAtUtc"] as? String).flatMap(formatter.date(from:)))
        let expires = try #require((json["expiresAtUtc"] as? String).flatMap(formatter.date(from:)))
        #expect(expires.timeIntervalSince(issued) == 1_800)
        #expect(Data(base64Encoded: exported.requestBase64) == exported.requestJSON)
        #expect(!String(decoding: exported.requestJSON, as: UTF8.self).contains(
            fixture.identity.signingKey.rawRepresentation.base64EncodedString()
        ))
        try PrivateFileSecurity.verifyPrivateDirectory(at: directory)
        try PrivateFileSecurity.verifyPrivateFile(at: storageURL(directory))
    }

    @Test func invalidEnrollmentDoesNotPersistAnActiveGrant() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory, fixture)
        for lifetime in [0.0, 0.5, -1.0, 1_801.0, Double.infinity, Double.nan] {
            await #expect(throws: (any Error).self) {
                try await store.createExport(
                    targetID: targetID, targetBinding: binding, peer: fixture.peer,
                    at: date, validFor: lifetime
                )
            }
        }
        for invalidBinding in ["", " leading", "embedded\nnewline", String(repeating: "a", count: 513)] {
            await #expect(throws: (any Error).self) {
                try await store.createExport(
                    targetID: targetID, targetBinding: invalidBinding, peer: fixture.peer, at: date
                )
            }
        }
        try store.refresh()
        #expect(store.grants.isEmpty)
    }

    @Test func exportReusesActiveGrantButNeverChangesItsDeviceScope() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory, fixture)
        let first = try await store.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        let second = try await store.createExport(
            targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date.addingTimeInterval(10)
        )
        #expect(first.grant == second.grant)
        #expect(first.requestJSON != second.requestJSON)
        var changedWindows = fixture.peer
        changedWindows.deviceID = UUID()
        var changedMac = fixture.peer
        changedMac.clientDeviceID = UUID()
        for changed in [changedWindows, changedMac] {
            await #expect(throws: (any Error).self) {
                try await store.createExport(targetID: targetID, targetBinding: binding, peer: changed, at: date)
            }
        }
        await #expect(throws: (any Error).self) {
            try await store.createExport(targetID: targetID, targetBinding: "another-profile-binding", peer: fixture.peer, at: date)
        }
        #expect(store.grants.count == 1)
    }

    @Test func tombstoneSurvivesReloadAndRequiresExplicitAIControlReenable() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = makeStore(directory, fixture)
        let exported = try await original.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        let revoked = try original.revoke(grantID: exported.grant.grantID, at: date.addingTimeInterval(1))
        #expect(revoked.isRevoked)
        #expect(revoked.pendingRemoteRevocation)

        let reopened = makeStore(directory, fixture)
        #expect(reopened.grants == [revoked])
        await #expect(throws: (any Error).self) {
            try await reopened.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        }
        #expect(try reopened.activeGrant(targetID: targetID, targetBinding: binding, peer: fixture.peer) == nil)
        try reopened.markRemoteRevocationConfirmed(grantID: revoked.grantID)
        #expect(reopened.grants[0].isRevoked)
        #expect(!reopened.grants[0].pendingRemoteRevocation)

        let renewed = try await reopened.createExport(
            targetID: targetID, targetBinding: binding, peer: fixture.peer,
            at: date.addingTimeInterval(2), allowReplacingRevokedGrant: true
        )
        #expect(renewed.grant.grantID != revoked.grantID)
        #expect(reopened.grants.count == 2)
        #expect(reopened.grants[0].isRevoked)
        let repeated = try await reopened.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        #expect(repeated.grant.grantID == renewed.grant.grantID)
    }

    @Test func staleStoreCannotOverwriteAnotherStoresRevocation() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeStore(directory, fixture)
        let exported = try await first.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        let stale = makeStore(directory, fixture)
        try first.revoke(grantID: exported.grant.grantID, at: date)
        await #expect(throws: (any Error).self) {
            try await stale.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        }
        #expect(throws: (any Error).self) {
            try stale.validateAuthorization(receipt(exported.grant), targetID: targetID, targetBinding: binding, peer: fixture.peer)
        }
    }

    @Test(arguments: [false, true])
    func restoreCannotOutliveAnotherRevocationDuringIdentityLoad(alreadyRevoked: Bool) async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = makeStore(directory, fixture)
        let exported = try await owner.createExport(
            targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date
        )
        if alreadyRevoked {
            try owner.revoke(grantID: exported.grant.grantID, at: date)
        }
        let previousRevision = try #require(owner.grants.first?.revocationRevision)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        defer {
            releaseContinuation.finish()
            startedContinuation.finish()
        }
        let restoringStore = CompanionPairingDelegationStore(
            directoryURL: directory,
            localIdentityLoader: { _ in
                startedContinuation.yield(())
                for await _ in release { break }
                return fixture.identity
            }
        )
        let restore = Task {
            try await restoringStore.createExport(
                targetID: targetID, targetBinding: binding, peer: fixture.peer,
                at: date, allowReplacingRevokedGrant: true
            )
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        // Keep the same timestamp so a repeated revocation is observable only
        // through the persisted event revision, including across store instances.
        try owner.revoke(grantID: exported.grant.grantID, at: date)
        releaseContinuation.yield(())
        await #expect(throws: (any Error).self) { try await restore.value }
        let reopened = makeStore(directory, fixture)
        #expect(reopened.grants.count == 1)
        #expect(reopened.grants.first?.isRevoked == true)
        #expect(reopened.grants.first?.revocationRevision == previousRevision + 1)
        #expect(try reopened.activeGrant(targetID: targetID, targetBinding: binding, peer: fixture.peer) == nil)
    }

    @Test func olderPersistedRecordsDefaultRevocationRevisionToZero() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory, fixture)
        let exported = try await store.createExport(
            targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date
        )
        let encoded = try JSONEncoder().encode(exported.grant)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "revocationRevision")
        let decoded = try JSONDecoder().decode(
            CompanionPairingDelegationGrant.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.revocationRevision == 0)
        #expect(decoded == exported.grant)
    }

    @Test func authenticatedReceiptMustMatchEveryBindingAndRemainUnrevoked() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory, fixture)
        let exported = try await store.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        let result = receipt(exported.grant)
        try store.validateAuthorization(result, targetID: targetID, targetBinding: binding, peer: fixture.peer)
        var wrongGrant = result
        wrongGrant.delegationGrantID = UUID()
        var wrongMac = result
        wrongMac.clientDeviceID = UUID()
        var wrongMacFingerprint = result
        wrongMacFingerprint.clientFingerprintSHA256 = String(repeating: "D", count: 64)
        var downgraded = result
        downgraded.authorizationSource = .interactive
        downgraded.delegationGrantID = nil
        for invalid in [wrongGrant, wrongMac, wrongMacFingerprint, downgraded] {
            #expect(throws: (any Error).self) {
                try store.validateAuthorization(invalid, targetID: targetID, targetBinding: binding, peer: fixture.peer)
            }
        }
        for (id, targetBinding) in [(UUID(), binding), (targetID, "other")] {
            #expect(throws: (any Error).self) {
                try store.validateAuthorization(result, targetID: id, targetBinding: targetBinding, peer: fixture.peer)
            }
        }
        var wrongWindows = fixture.peer
        wrongWindows.fingerprintSHA256 = String(repeating: "C", count: 64)
        #expect(throws: (any Error).self) {
            try store.validateAuthorization(result, targetID: targetID, targetBinding: binding, peer: wrongWindows)
        }
        try store.revoke(grantID: exported.grant.grantID, at: date)
        #expect(throws: (any Error).self) {
            try store.validateAuthorization(result, targetID: targetID, targetBinding: binding, peer: fixture.peer)
        }
    }

    @Test func legacyInteractivePairingWorksButMissingDelegationNeverDoes() throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory, fixture)
        var result = WindowsCompanionAuthorizationResult(
            newlyPaired: false, clientDeviceID: fixture.peer.clientDeviceID,
            clientFingerprintSHA256: fixture.peer.clientFingerprintSHA256, stateRevision: 3
        )
        try store.validateAuthorization(result, targetID: targetID, targetBinding: binding, peer: fixture.peer)
        result.authorizationSource = .ownerDelegated
        result.delegationGrantID = UUID()
        #expect(throws: (any Error).self) {
            try store.validateAuthorization(result, targetID: targetID, targetBinding: binding, peer: fixture.peer)
        }
    }

    @Test func wireReceiptDefaultsOnlyMissingSourceToInteractive() throws {
        let fixture = makeFixture()
        let valid: [String: Any] = [
            "authorized": true, "newlyPaired": true,
            "clientDeviceId": fixture.peer.clientDeviceID.uuidString,
            "clientFingerprintSha256": fixture.peer.clientFingerprintSHA256,
            "stateRevision": UInt64(2),
        ]
        func parse(_ payload: [String: Any]) throws -> WindowsCompanionAuthorizationResult {
            try WindowsCompanionClient.verifyAuthorizationResult(
                payload, expectedClientDeviceID: fixture.peer.clientDeviceID,
                expectedClientFingerprint: fixture.peer.clientFingerprintSHA256
            )
        }
        #expect(try parse(valid).authorizationSource == .interactive)
        var delegated = valid
        delegated["authorizationSource"] = "ownerDelegated"
        let grantID = UUID()
        delegated["delegationGrantId"] = grantID.uuidString
        #expect(try parse(delegated).delegationGrantID == grantID)
        for source: Any in [NSNull(), "unknown", true] {
            var invalid = valid
            invalid["authorizationSource"] = source
            #expect(throws: (any Error).self) { try parse(invalid) }
        }
        for grant: Any in [NSNull(), "not-a-guid", "00000000-0000-0000-0000-000000000000", 1] {
            var invalid = delegated
            invalid["delegationGrantId"] = grant
            #expect(throws: (any Error).self) { try parse(invalid) }
        }
        var missingGrant = delegated
        missingGrant.removeValue(forKey: "delegationGrantId")
        #expect(throws: (any Error).self) { try parse(missingGrant) }
        var unexpectedGrant = valid
        unexpectedGrant["delegationGrantId"] = grantID.uuidString
        #expect(throws: (any Error).self) { try parse(unexpectedGrant) }
        for revision: Any in [true, -1, 1.5, NSNumber(value: UInt64.max)] {
            var changed = valid
            changed["stateRevision"] = revision
            if revision is NSNumber, (revision as? NSNumber)?.stringValue == String(UInt64.max) {
                #expect(try parse(changed).stateRevision == UInt64.max)
            } else {
                #expect(throws: (any Error).self) { try parse(changed) }
            }
        }
    }

    @Test func failedRevocationPersistenceStaysBlockedAndRetriesTombstone() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory, fixture)
        let exported = try await store.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        let file = storageURL(directory)
        let previous = try Data(contentsOf: file)
        try Data("corrupt".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.revoke(grantID: exported.grant.grantID, at: date) }
        #expect(store.grants.first?.isRevoked == true)
        try previous.write(to: file)
        #expect(throws: (any Error).self) {
            try store.validateAuthorization(receipt(exported.grant), targetID: targetID, targetBinding: binding, peer: fixture.peer)
        }
        let reopened = makeStore(directory, fixture)
        #expect(reopened.grants.first?.isRevoked == true)
    }

    @Test func symlinkStateIsRejectedWithoutChangingItsDestination() async throws {
        let fixture = makeFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try PrivateFileSecurity.secureDirectory(at: directory)
        let target = directory.appendingPathComponent("unrelated.json")
        let original = Data("untouched".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: storageURL(directory), withDestinationURL: target)
        let store = makeStore(directory, fixture)
        #expect(store.persistenceError != nil)
        await #expect(throws: (any Error).self) {
            try await store.createExport(targetID: targetID, targetBinding: binding, peer: fixture.peer, at: date)
        }
        #expect(try Data(contentsOf: target) == original)
    }

    private func receipt(_ grant: CompanionPairingDelegationGrant) -> WindowsCompanionAuthorizationResult {
        WindowsCompanionAuthorizationResult(
            newlyPaired: true, clientDeviceID: grant.macDeviceID,
            clientFingerprintSHA256: grant.macFingerprintSHA256, stateRevision: 2,
            authorizationSource: .ownerDelegated, delegationGrantID: grant.grantID
        )
    }

    private func makeStore(_ directory: URL, _ fixture: Fixture) -> CompanionPairingDelegationStore {
        CompanionPairingDelegationStore(directoryURL: directory, localIdentityLoader: { _ in fixture.identity })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("companion-delegation-\(UUID())", isDirectory: true)
    }

    private func storageURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("device-pairing-delegations-v1.json")
    }

    private struct Fixture: Sendable {
        var identity: RDPCompanionLocalIdentity
        var peer: WindowsCompanionPeerIdentity
    }

    private func makeFixture() -> Fixture {
        let identity = RDPCompanionLocalIdentity(signingKey: P256.Signing.PrivateKey(), clientDeviceID: UUID())
        let windowsKey = P256.Signing.PrivateKey().publicKey.derRepresentation
        return Fixture(identity: identity, peer: WindowsCompanionPeerIdentity(
            deviceID: UUID(),
            fingerprintSHA256: WindowsCompanionAuthorizationProof.fingerprint(publicKeyDER: windowsKey),
            publicKeyDER: windowsKey, agentVersion: "2.0.0", capabilities: [],
            clientDeviceID: identity.clientDeviceID,
            clientFingerprintSHA256: WindowsCompanionAuthorizationProof.fingerprint(
                publicKeyDER: identity.signingKey.publicKey.derRepresentation
            ),
            clientAuthorization: WindowsCompanionClientAuthorization(
                challenge: Data(repeating: 1, count: 32), expiresAtUnixMilliseconds: 1_900_000_000_000,
                pairingRequired: false
            ),
            sessionBinding: Data(repeating: 2, count: 32)
        ))
    }
}
#endif
