#if ENABLE_RDP_2
import CryptoKit
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct RDPCompanionDelegationPolicyTests {
    private struct Fixture: Sendable {
        let identity: RDPCompanionLocalIdentity
        let peer: WindowsCompanionPeerIdentity
    }

    private func fixture() -> Fixture {
        let identity = RDPCompanionLocalIdentity(signingKey: P256.Signing.PrivateKey(), clientDeviceID: UUID())
        let windowsKey = P256.Signing.PrivateKey().publicKey.derRepresentation
        return Fixture(identity: identity, peer: WindowsCompanionPeerIdentity(
            deviceID: UUID(),
            fingerprintSHA256: WindowsCompanionAuthorizationProof.fingerprint(publicKeyDER: windowsKey),
            publicKeyDER: windowsKey, agentVersion: "2.0.0", capabilities: [],
            clientDeviceID: identity.clientDeviceID,
            clientFingerprintSHA256: WindowsCompanionAuthorizationProof.fingerprint(
                publicKeyDER: identity.signingKey.publicKey.derRepresentation),
            clientAuthorization: WindowsCompanionClientAuthorization(
                challenge: Data(repeating: 1, count: 32), expiresAtUnixMilliseconds: 1_900_000_000_000,
                pairingRequired: true), sessionBinding: Data(repeating: 2, count: 32)))
    }

    private func target() throws -> RemoteSession {
        let target = RemoteSession(name: "Windows", host: "192.0.2.198",
            username: "operator", connectionType: .rdp)
        target.mcpEnabled = true
        try target.setRDPProfile(RDPConnectionProfile(
            permissionPolicy: RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl])))
        return target
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-delegation-policy-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func existingDeviceAIControlCreatesDelegationByDefaultAndReusesItsIdentity() async throws {
        let fixture = fixture(), target = try target(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var identityLoads = 0
        let store = CompanionPairingDelegationStore(directoryURL: directory, localIdentityLoader: { id in
            #expect(id == target.targetID)
            identityLoads += 1
            return fixture.identity
        })
        #expect(RDPCompanionDelegationPolicy.isEnabled(for: target))
        let exported = try await RDPCompanionDelegationPolicy.prepare(target: target, peer: fixture.peer, store: store)
        let again = try await RDPCompanionDelegationPolicy.prepare(target: target, peer: fixture.peer, store: store)
        #expect(exported.grant.grantID == again.grant.grantID)
        #expect(exported.grant.authorizationSource == .ownerDelegated)
        #expect(exported.grant.targetID == target.targetID)
        #expect(exported.grant.targetBinding == target.mcpGrantTargetBinding)
        #expect(exported.grant.matches(targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding, peer: fixture.peer))
        #expect(store.grants.count == 1)
        #expect(identityLoads == 2)
        let json = try #require(JSONSerialization.jsonObject(with: exported.requestJSON) as? [String: Any])
        #expect(json["authorizationReference"] as? String == "device-ai-control-enabled")
        #expect(json["authorizationSource"] as? String == "ownerDelegated")
    }

    @Test func disabledDeviceOrControlPermissionCannotCreateAnEnrollment() async throws {
        for mode in ["device-disabled", "persistent-control-disabled", "observation-only"] {
            let fixture = fixture(), target = try target(), directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            switch mode {
            case "device-disabled": target.mcpEnabled = false
            case "persistent-control-disabled":
                var profile = target.rdpProfile; profile.persistentMCPControlEnabled = false
                try target.setRDPProfile(profile)
            default:
                try target.setRDPProfile(RDPConnectionProfile(permissionPolicy:
                    RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopObserve])))
            }
            var identityLoads = 0
            let store = CompanionPairingDelegationStore(directoryURL: directory, localIdentityLoader: { _ in
                identityLoads += 1
                return fixture.identity
            })
            #expect(!RDPCompanionDelegationPolicy.isEnabled(for: target))
            do {
                _ = try await RDPCompanionDelegationPolicy.prepare(target: target, peer: fixture.peer, store: store)
                Issue.record("\(mode) must not create a pairing enrollment.")
            } catch let error as WindowsMCPToolError {
                #expect(error.code == .permissionDenied)
            }
            #expect(identityLoads == 0)
            #expect(store.grants.isEmpty)
        }
    }

    @Test func changedPermissionOrEndpointDuringIdentityLoadRejectsTheExport() async throws {
        for mode in ["device-disabled", "persistent-control-disabled", "endpoint-changed"] {
            let fixture = fixture(), target = try target(), directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let originalBinding = target.mcpGrantTargetBinding
            let (started, startedContinuation) = AsyncStream<Void>.makeStream()
            let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
            defer { startedContinuation.finish(); releaseContinuation.finish() }
            let store = CompanionPairingDelegationStore(directoryURL: directory, localIdentityLoader: { _ in
                startedContinuation.yield(())
                for await _ in release { break }
                return fixture.identity
            })
            let preparation = Task {
                try await RDPCompanionDelegationPolicy.prepare(target: target, peer: fixture.peer, store: store)
            }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            switch mode {
            case "device-disabled": target.mcpEnabled = false
            case "persistent-control-disabled":
                var profile = target.rdpProfile; profile.persistentMCPControlEnabled = false
                try target.setRDPProfile(profile)
            default: target.host = "192.0.2.199"
            }
            releaseContinuation.yield(())
            do {
                _ = try await preparation.value
                Issue.record("\(mode) must invalidate the prepared enrollment before it is returned.")
            } catch let error as WindowsMCPToolError {
                #expect(error.code == .permissionDenied)
            }
            // Persistence may finish while the identity loader yields. Such a
            // record must retain the old endpoint and cannot supply an export
            // for the changed device permission or endpoint.
            #expect(store.grants.allSatisfy { $0.targetBinding == originalBinding })
            if mode == "endpoint-changed" {
                #expect(throws: CompanionPairingDelegationFailure.self) {
                    _ = try store.activeGrant(targetID: target.targetID,
                        targetBinding: target.mcpGrantTargetBinding, peer: fixture.peer)
                }
            } else {
                #expect(!RDPCompanionDelegationPolicy.isEnabled(for: target))
            }
        }
    }

    @Test func defaultPolicyNeverReplacesAnExplicitlyRevokedGrant() async throws {
        let fixture = fixture(), target = try target(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionPairingDelegationStore(directoryURL: directory, localIdentityLoader: { _ in fixture.identity })
        let exported = try await RDPCompanionDelegationPolicy.prepare(target: target, peer: fixture.peer, store: store)
        try store.revoke(grantID: exported.grant.grantID)
        #expect(RDPCompanionDelegationPolicy.isEnabled(for: target))
        await #expect(throws: CompanionPairingDelegationFailure.self) {
            _ = try await RDPCompanionDelegationPolicy.prepare(target: target, peer: fixture.peer, store: store)
        }
        #expect(store.grants.count == 1)
        #expect(store.grants[0].isRevoked)
    }

    @Test func enrollmentMetadataUsesTheExactPublicRequestAndChecksum() async throws {
        let fixture = fixture(), target = try target(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionPairingDelegationStore(directoryURL: directory, localIdentityLoader: { _ in fixture.identity })
        let exported = try await RDPCompanionDelegationPolicy.prepare(target: target, peer: fixture.peer, store: store)
        let metadata = RDPCompanionDelegationPolicy.enrollmentMetadata(exported)
        #expect(Set(metadata.keys) == ["enrollmentRequestBase64", "enrollmentRequestSHA256"])
        let encoded = try #require(metadata["enrollmentRequestBase64"] as? String)
        #expect(Data(base64Encoded: encoded) == exported.requestJSON)
        let expected = SHA256.hash(data: exported.requestJSON).map { String(format: "%02x", $0) }.joined()
        #expect(metadata["enrollmentRequestSHA256"] as? String == expected)
        #expect(!String(decoding: exported.requestJSON, as: UTF8.self)
            .contains(fixture.identity.signingKey.rawRepresentation.base64EncodedString()))
    }
}
#endif
