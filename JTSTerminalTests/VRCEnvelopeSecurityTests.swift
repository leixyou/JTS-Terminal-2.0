#if ENABLE_RDP_2
import CryptoKit
import Foundation
import Testing
@testable import JTSTerminal

struct VRCEnvelopeSecurityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let windowsDeviceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let clientDeviceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let jobID = "avatar-pilot-001"
    private let totalBytes: Int64 = 12_345
    private let bundleSHA256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    @Test func canonicalBytesMatchDotNetFixturesExactly() throws {
        let job = VRCJobEnvelope(
            schemaVersion: VRCJobEnvelope.schemaVersion,
            windowsDeviceId: windowsDeviceID,
            clientDeviceId: clientDeviceID,
            clientFingerprintSha256: String(repeating: "a", count: 64),
            jobId: jobID,
            totalBytes: totalBytes,
            bundleSha256: bundleSHA256,
            issuedAtUnixMilliseconds: 1_800_000_000_000,
            signatureBase64: ""
        )
        let result = VRCResultEnvelope(
            schemaVersion: VRCResultEnvelope.schemaVersion,
            windowsDeviceId: windowsDeviceID,
            windowsFingerprintSha256: String(repeating: "b", count: 64),
            clientDeviceId: clientDeviceID,
            clientFingerprintSha256: String(repeating: "a", count: 64),
            jobId: jobID,
            state: "collected",
            totalBytes: totalBytes,
            bundleSha256: bundleSHA256,
            issuedAtUnixMilliseconds: 1_800_000_000_000,
            signatureBase64: ""
        )

        #expect(Self.sha256(try VRCEnvelopeCanonicalizer.job(job))
            == "c46a1fc9519ae1e61ff7136ac41e7d9fa51b3e4e047722bee66d29e9ce1e88e3")
        #expect(Self.sha256(try VRCEnvelopeCanonicalizer.result(result))
            == "43ef803a1c88f7084cd0fa324eed4f122baa6d633fbe820ba24d4bc7d17422ed")
    }

    @Test func jobEnvelopeUsesTheProfileSigningIdentityAndBindsArtifact() throws {
        let windowsKey = P256.Signing.PrivateKey()
        let clientKey = P256.Signing.PrivateKey()
        let peer = peer(windowsKey: windowsKey, clientKey: clientKey)

        let envelope = try VRCEnvelopeSecurity.signJob(
            peer: peer,
            jobID: jobID,
            totalBytes: totalBytes,
            bundleSHA256: bundleSHA256,
            signingKey: clientKey,
            issuedAt: now
        )
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: #require(Data(base64Encoded: envelope.signatureBase64))
        )

        #expect(envelope.windowsDeviceId == windowsDeviceID)
        #expect(envelope.clientDeviceId == clientDeviceID)
        #expect(envelope.clientFingerprintSha256 == peer.clientFingerprintSHA256)
        #expect(clientKey.publicKey.isValidSignature(
            signature,
            for: try VRCEnvelopeCanonicalizer.job(envelope)
        ))
    }

    @Test func resultEnvelopeVerifiesWindowsSignatureIdentitiesAndArtifactBeforeUse() throws {
        let windowsKey = P256.Signing.PrivateKey()
        let clientKey = P256.Signing.PrivateKey()
        let peer = peer(windowsKey: windowsKey, clientKey: clientKey)
        let envelope = try signedResult(
            windowsKey: windowsKey,
            peer: peer,
            issuedAt: now
        )

        let verified = try VRCEnvelopeSecurity.verifyResult(
            envelope.foundationValue,
            peer: peer,
            expectedJobID: jobID,
            expectedTotalBytes: totalBytes,
            expectedBundleSHA256: bundleSHA256,
            now: now
        )

        #expect(verified == envelope)
    }

    @Test func resultEnvelopeRejectsTamperingAndUnsignedExtraFields() throws {
        let windowsKey = P256.Signing.PrivateKey()
        let clientKey = P256.Signing.PrivateKey()
        let peer = peer(windowsKey: windowsKey, clientKey: clientKey)
        let envelope = try signedResult(windowsKey: windowsKey, peer: peer, issuedAt: now)

        var tampered = envelope.foundationValue
        tampered["bundleSha256"] = String(repeating: "f", count: 64)
        #expect(throws: VRCEnvelopeSecurityError.self) {
            try VRCEnvelopeSecurity.verifyResult(
                tampered,
                peer: peer,
                expectedJobID: jobID,
                expectedTotalBytes: totalBytes,
                expectedBundleSHA256: String(repeating: "f", count: 64),
                now: now
            )
        }

        var expanded = envelope.foundationValue
        expanded["shell"] = "not accepted"
        #expect(throws: VRCEnvelopeSecurityError.invalidResultEnvelope) {
            try VRCEnvelopeSecurity.verifyResult(
                expanded,
                peer: peer,
                expectedJobID: jobID,
                expectedTotalBytes: totalBytes,
                expectedBundleSHA256: bundleSHA256,
                now: now
            )
        }

        var typeConfused = envelope.foundationValue
        typeConfused["totalBytes"] = true
        #expect(throws: VRCEnvelopeSecurityError.invalidResultEnvelope) {
            try VRCEnvelopeSecurity.verifyResult(
                typeConfused,
                peer: peer,
                expectedJobID: jobID,
                expectedTotalBytes: 1,
                expectedBundleSHA256: bundleSHA256,
                now: now
            )
        }
    }

    @Test func resultEnvelopeRejectsOldReplayAndExcessiveFutureSkew() throws {
        let windowsKey = P256.Signing.PrivateKey()
        let clientKey = P256.Signing.PrivateKey()
        let peer = peer(windowsKey: windowsKey, clientKey: clientKey)
        let old = try signedResult(
            windowsKey: windowsKey,
            peer: peer,
            issuedAt: now.addingTimeInterval(-10 * 60 - 0.001)
        )
        let future = try signedResult(
            windowsKey: windowsKey,
            peer: peer,
            issuedAt: now.addingTimeInterval(60.001)
        )

        for envelope in [old, future] {
            #expect(throws: VRCEnvelopeSecurityError.invalidResultEnvelope) {
                try VRCEnvelopeSecurity.verifyResult(
                    envelope.foundationValue,
                    peer: peer,
                    expectedJobID: jobID,
                    expectedTotalBytes: totalBytes,
                    expectedBundleSHA256: bundleSHA256,
                    now: now
                )
            }
        }
    }

    @Test func resultEnvelopeRejectsAnotherWindowsKeyAndClientIdentity() throws {
        let windowsKey = P256.Signing.PrivateKey()
        let clientKey = P256.Signing.PrivateKey()
        let peer = peer(windowsKey: windowsKey, clientKey: clientKey)
        let envelope = try signedResult(windowsKey: windowsKey, peer: peer, issuedAt: now)
        let differentPeer = self.peer(
            windowsKey: P256.Signing.PrivateKey(),
            clientKey: clientKey
        )

        #expect(throws: VRCEnvelopeSecurityError.self) {
            try VRCEnvelopeSecurity.verifyResult(
                envelope.foundationValue,
                peer: differentPeer,
                expectedJobID: jobID,
                expectedTotalBytes: totalBytes,
                expectedBundleSHA256: bundleSHA256,
                now: now
            )
        }
    }

    private func signedResult(
        windowsKey: P256.Signing.PrivateKey,
        peer: WindowsCompanionPeerIdentity,
        issuedAt: Date
    ) throws -> VRCResultEnvelope {
        var envelope = VRCResultEnvelope(
            schemaVersion: VRCResultEnvelope.schemaVersion,
            windowsDeviceId: peer.deviceID,
            windowsFingerprintSha256: peer.fingerprintSHA256,
            clientDeviceId: peer.clientDeviceID,
            clientFingerprintSha256: peer.clientFingerprintSHA256,
            jobId: jobID,
            state: "collected",
            totalBytes: totalBytes,
            bundleSha256: bundleSHA256,
            issuedAtUnixMilliseconds: Int64(issuedAt.timeIntervalSince1970 * 1_000),
            signatureBase64: ""
        )
        envelope.signatureBase64 = try windowsKey.signature(
            for: VRCEnvelopeCanonicalizer.result(envelope)
        ).rawRepresentation.base64EncodedString()
        return envelope
    }

    private func peer(
        windowsKey: P256.Signing.PrivateKey,
        clientKey: P256.Signing.PrivateKey
    ) -> WindowsCompanionPeerIdentity {
        let windowsPublicKey = windowsKey.publicKey.derRepresentation
        let clientPublicKey = clientKey.publicKey.derRepresentation
        return WindowsCompanionPeerIdentity(
            deviceID: windowsDeviceID,
            fingerprintSHA256: WindowsCompanionAuthorizationProof.fingerprint(
                publicKeyDER: windowsPublicKey
            ),
            publicKeyDER: windowsPublicKey,
            agentVersion: "2.0.0-test",
            capabilities: ["worker"],
            clientDeviceID: clientDeviceID,
            clientFingerprintSHA256: WindowsCompanionAuthorizationProof.fingerprint(
                publicKeyDER: clientPublicKey
            ),
            clientAuthorization: WindowsCompanionClientAuthorization(
                challenge: Data(repeating: 0xA5, count: 32),
                expiresAtUnixMilliseconds: 1_800_000_060_000,
                pairingRequired: false
            ),
            sessionBinding: Data(repeating: 0x5A, count: 32)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
