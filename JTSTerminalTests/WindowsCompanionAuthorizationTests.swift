#if ENABLE_RDP_2
import CryptoKit
import Foundation
import Testing
@testable import JTSTerminal

struct WindowsCompanionAuthorizationTests {
    @Test @MainActor
    func aPrecancelledCompanionSendNeverInvokesItsTransport() async {
        var transportCallCount = 0
        let sendTask = Task { @MainActor in
            try await WindowsCompanionClient.executeCancellableTransport(
                Data([0x4A, 0x54, 0x53]),
                using: { _ in
                    transportCallCount += 1
                }
            )
        }
        sendTask.cancel()

        do {
            try await sendTask.value
            Issue.record("A cancelled Companion send must stop before transport dispatch")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(transportCallCount == 0)
    }

    @Test @MainActor
    func aCompanionSendCannotCrossADVCChannelGeneration() async throws {
        let oldChannelID = UUID()
        let replacementChannelID = UUID()
        var currentChannelID: UUID? = replacementChannelID
        var transportCallCount = 0

        do {
            try await RDPCompanionChannelTransport.send(
                Data([0x4A]),
                expectedChannelID: oldChannelID,
                currentChannelID: { currentChannelID },
                transport: { _ in transportCallCount += 1 }
            )
            Issue.record("A delayed send from the closed DVC channel must not reach transport")
        } catch let failure as WindowsCompanionRequestFailure {
            #expect(failure.code == "COMPANION_CONNECTION_CHANGED")
        }
        #expect(transportCallCount == 0)

        currentChannelID = oldChannelID
        var releaseTransport: CheckedContinuation<Void, Never>?
        let inFlightSend = Task { @MainActor in
            try await RDPCompanionChannelTransport.send(
                Data([0x54]),
                expectedChannelID: oldChannelID,
                currentChannelID: { currentChannelID },
                transport: { _ in
                    transportCallCount += 1
                    await withCheckedContinuation { continuation in
                        releaseTransport = continuation
                    }
                }
            )
        }
        for _ in 0..<100 where releaseTransport == nil {
            await Task.yield()
        }
        let pendingTransport = try #require(releaseTransport)
        currentChannelID = replacementChannelID
        pendingTransport.resume()

        do {
            try await inFlightSend.value
            Issue.record("An in-flight send must reject a DVC channel replacement")
        } catch let failure as WindowsCompanionRequestFailure {
            #expect(failure.code == "COMPANION_CONNECTION_CHANGED")
        }
        #expect(transportCallCount == 1)
    }

    @Test @MainActor
    func helloTransportFailureDoesNotLoadCompanionIdentity() async {
        let client = WindowsCompanionClient(
            sessionID: UUID(),
            transport: { _ in
                throw WindowsCompanionRequestFailure(
                    code: "COMPANION_REQUIRED",
                    message: "No Companion channel is available.",
                    retryable: true
                )
            },
            localIdentityLoader: { _ in
                Issue.record("A missing Companion must not trigger a Keychain identity read")
                return RDPCompanionLocalIdentity(
                    signingKey: P256.Signing.PrivateKey(),
                    clientDeviceID: UUID()
                )
            }
        )

        do {
            _ = try await client.performHello(targetID: UUID(), timeoutMilliseconds: 100)
            Issue.record("Expected the missing Companion transport to fail")
        } catch let failure as WindowsCompanionRequestFailure {
            #expect(failure.code == "COMPANION_REQUIRED")
        } catch {
            Issue.record("Expected WindowsCompanionRequestFailure, got \(error)")
        }
    }

    @Test func macAuthorizationCanonicalPayloadMatchesDotNetByteOrder() throws {
        let windowsDeviceID = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let clientDeviceID = try #require(UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f"))
        let challenge = Data((0..<32).map(UInt8.init))
        let payload = WindowsCompanionAuthorizationProof.canonicalPayload(
            windowsDeviceID: windowsDeviceID,
            clientDeviceID: clientDeviceID,
            sequence: 0x0102_0304_0506_0708,
            issuedAtUnixMilliseconds: 0x1112_1314_1516_1718,
            challenge: challenge
        )

        var expected = Data("JTS-MAC-COMPANION-AUTHORIZATION-V1\0".utf8)
        expected.append(contentsOf: [
            0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
            0x43, 0x32, 0x21, 0x10, 0x65, 0x54, 0x87, 0x76,
            0x98, 0xA9, 0xBA, 0xCB, 0xDC, 0xED, 0xFE, 0x0F,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        ])
        expected.append(challenge)

        #expect(payload == expected)
    }

    @Test func macAuthorizationUsesSPKIFingerprintAndRawP1363Signature() throws {
        let signingKey = P256.Signing.PrivateKey()
        let windowsDeviceID = UUID()
        let clientDeviceID = UUID()
        let challenge = Data(repeating: 0xA5, count: 32)
        let sequence: UInt64 = 42
        let issuedAt: Int64 = 1_784_096_400_123
        let parameters = try WindowsCompanionAuthorizationProof.parameters(
            windowsDeviceID: windowsDeviceID,
            clientDeviceID: clientDeviceID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAt,
            challenge: challenge,
            signingKey: signingKey
        )

        let publicKeyBase64 = try #require(parameters["publicKeyBase64"] as? String)
        let signatureBase64 = try #require(parameters["signatureBase64"] as? String)
        let publicKeyDER = try #require(Data(base64Encoded: publicKeyBase64))
        let signatureData = try #require(Data(base64Encoded: signatureBase64))
        #expect(signatureData.count == 64)
        #expect(parameters["deviceId"] as? String == clientDeviceID.uuidString.lowercased())
        #expect(parameters["challengeBase64"] as? String == challenge.base64EncodedString())
        #expect(parameters["sequence"] as? UInt64 == sequence)
        #expect(parameters["issuedAtUnixMilliseconds"] as? Int64 == issuedAt)
        #expect(parameters["fingerprintSha256"] as? String
            == WindowsCompanionAuthorizationProof.fingerprint(publicKeyDER: publicKeyDER))

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let payload = WindowsCompanionAuthorizationProof.canonicalPayload(
            windowsDeviceID: windowsDeviceID,
            clientDeviceID: clientDeviceID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAt,
            challenge: challenge
        )
        #expect(signingKey.publicKey.isValidSignature(signature, for: payload))
    }

    @Test func macAuthorizationRejectsInvalidChallengeOrSequence() throws {
        let signingKey = P256.Signing.PrivateKey()
        for (sequence, challenge) in [
            (UInt64(0), Data(repeating: 0, count: 32)),
            (UInt64(1), Data(repeating: 0, count: 31)),
        ] {
            do {
                _ = try WindowsCompanionAuthorizationProof.parameters(
                    windowsDeviceID: UUID(),
                    clientDeviceID: UUID(),
                    sequence: sequence,
                    issuedAtUnixMilliseconds: 1,
                    challenge: challenge,
                    signingKey: signingKey
                )
                Issue.record("Expected invalid authorization proof parameters to fail")
            } catch let error as WindowsCompanionRequestFailure {
                #expect(error.code == "PAIRING_AUTHORIZATION_INVALID")
            } catch {
                Issue.record("Expected WindowsCompanionRequestFailure, got \(error)")
            }
        }
    }

    @Test func frameAuthenticationCanonicalFixtureMatchesDotNetByteForByte() throws {
        let windowsDeviceID = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let clientDeviceID = try #require(UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100"))
        let helloChallenge = Data((0..<32).map(UInt8.init))
        let authorizationChallenge = Data((32..<64).map(UInt8.init))
        let binding = try DVCFrameAuthenticator.deriveSessionBinding(
            windowsDeviceID: windowsDeviceID,
            clientDeviceID: clientDeviceID,
            helloChallenge: helloChallenge,
            authorizationChallenge: authorizationChallenge
        )
        let canonical = DVCFrameAuthenticator.canonicalPayload(
            protocolVersion: 1,
            direction: .macToWindows,
            frameType: 2,
            flags: DVCFrameFlags.final.union(.authenticated).rawValue,
            sequence: 0x0102_0304_0506_0708,
            applicationPayload: Data("fixture".utf8),
            sessionBinding: binding
        )

        #expect(binding.hexString ==
            "79d5063f1a130ac82991c3ad6d4f4f0cdb03bfee7805025074fc8af618c8bb40")
        #expect(canonical.hexString ==
            "4a54532d434f4d50414e494f4e2d4456432d4652414d452d415554482d56310000010102810001020304050607080000000779d5063f1a130ac82991c3ad6d4f4f0cdb03bfee7805025074fc8af618c8bb40f16d05ec6b29248d2c61adb1e9263f78e4f7bace1b955014a2d17872cfe4064d")
    }

    @Test func frameAuthenticationSignsAndVerifiesEveryFrameKind() throws {
        let macKey = P256.Signing.PrivateKey()
        let windowsKey = P256.Signing.PrivateKey()
        let binding = Data(SHA256.hash(data: Data("fresh-session".utf8)))
        let mac = try DVCFrameAuthenticator(
            sessionBinding: binding,
            signingKey: macKey,
            peerPublicKeyDER: windowsKey.publicKey.derRepresentation
        )
        let windows = try DVCFrameAuthenticator(
            sessionBinding: binding,
            signingKey: windowsKey,
            peerPublicKeyDER: macKey.publicKey.derRepresentation
        )
        let frames: [DVCFrame] = [
            .control(DVCControlFrame(sequence: 1, payloadJSON: Data("{}".utf8))),
            .binary(DVCBinaryFrame(
                transferID: UUID(),
                sequence: 2,
                offset: 0,
                data: Data("binary".utf8),
                isFinal: true
            )),
            .ping(DVCHeartbeatFrame(sequence: 3, payload: Data("ping".utf8))),
            .pong(DVCHeartbeatFrame(sequence: 4, payload: Data("pong".utf8))),
        ]

        for frame in frames {
            let signed = try mac.sign(frame, direction: .macToWindows)
            let encoded = try DVCWireCodec.encode(signed)
            let decoded = try #require(DVCWireCodec.decodeAvailable(from: encoded).frames.first)
            #expect(decoded.authentication?.signature.count == 64)
            #expect(try windows.verify(decoded, direction: .macToWindows) == decoded)
        }
    }

    @Test func frameAuthenticationRejectsUnsignedTamperedReflectedAndOldSessionFrames() throws {
        let macKey = P256.Signing.PrivateKey()
        let windowsKey = P256.Signing.PrivateKey()
        let binding = Data(repeating: 0xA5, count: 32)
        let mac = try DVCFrameAuthenticator(
            sessionBinding: binding,
            signingKey: macKey,
            peerPublicKeyDER: windowsKey.publicKey.derRepresentation
        )
        let windows = try DVCFrameAuthenticator(
            sessionBinding: binding,
            signingKey: windowsKey,
            peerPublicKeyDER: macKey.publicKey.derRepresentation
        )
        let unsigned = DVCFrame.control(DVCControlFrame(
            sequence: 7,
            payloadJSON: Data("{\"value\":1}".utf8)
        ))
        #expect(throws: DVCProtocolError.missingFrameAuthentication) {
            try windows.verify(unsigned, direction: .macToWindows)
        }

        let signed = try mac.sign(unsigned, direction: .macToWindows)
        #expect(throws: (any Error).self) {
            try windows.verify(signed, direction: .windowsToMac)
        }

        guard case .control(var tamperedControl) = signed else {
            Issue.record("Expected a signed control frame")
            return
        }
        tamperedControl.payloadJSON = Data("{\"value\":2}".utf8)
        #expect(throws: (any Error).self) {
            try windows.verify(.control(tamperedControl), direction: .macToWindows)
        }

        let oldSession = try DVCFrameAuthenticator(
            sessionBinding: Data(repeating: 0x5A, count: 32),
            signingKey: windowsKey,
            peerPublicKeyDER: macKey.publicKey.derRepresentation
        )
        #expect(throws: (any Error).self) {
            try oldSession.verify(signed, direction: .macToWindows)
        }
    }

    @Test func frameAuthenticationEnvelopeCountsAgainstBinaryWireLimit() throws {
        let macKey = P256.Signing.PrivateKey()
        let windowsKey = P256.Signing.PrivateKey()
        let authenticator = try DVCFrameAuthenticator(
            sessionBinding: Data(repeating: 0x11, count: 32),
            signingKey: macKey,
            peerPublicKeyDER: windowsKey.publicKey.derRepresentation
        )
        let maximum = DVCFrame.binary(DVCBinaryFrame(
            transferID: UUID(),
            sequence: 1,
            offset: 0,
            data: Data(repeating: 0xA5, count: WindowsCompanionDVC.maximumBinaryChunkBytes),
            isFinal: true
        ))
        let signed = try authenticator.sign(maximum, direction: .macToWindows)
        let encoded = try DVCWireCodec.encode(signed)
        #expect(encoded.count == WindowsCompanionDVC.headerLength + WindowsCompanionDVC.maximumBinaryPayloadBytes)

        let oversized = DVCFrame.binary(DVCBinaryFrame(
            transferID: UUID(),
            sequence: 2,
            offset: 0,
            data: Data(repeating: 0, count: WindowsCompanionDVC.maximumBinaryChunkBytes + 1),
            isFinal: true
        ))
        #expect(throws: (any Error).self) {
            try authenticator.sign(oversized, direction: .macToWindows)
        }
    }

    @Test func remoteCancellationFrameIsAuthenticatedAndTargetsTheExactRequestID() throws {
        let macKey = P256.Signing.PrivateKey()
        let windowsKey = P256.Signing.PrivateKey()
        let binding = Data(SHA256.hash(data: Data("cancellation-session".utf8)))
        let mac = try DVCFrameAuthenticator(
            sessionBinding: binding,
            signingKey: macKey,
            peerPublicKeyDER: windowsKey.publicKey.derRepresentation
        )
        let windows = try DVCFrameAuthenticator(
            sessionBinding: binding,
            signingKey: windowsKey,
            peerPublicKeyDER: macKey.publicKey.derRepresentation
        )
        let targetRequestID = UUID()
        let cancellationRequestID = UUID()
        let encoded = try WindowsCompanionCancellationFrame.encode(
            targetRequestID: targetRequestID,
            cancellationRequestID: cancellationRequestID,
            sequence: 47,
            deadlineUnixMilliseconds: 1_900_000_000_000,
            authenticator: mac
        )
        let decoded = try #require(DVCWireCodec.decodeAvailable(from: encoded).frames.first)
        let verified = try windows.verify(decoded, direction: .macToWindows)
        guard case .control(let control) = verified else {
            Issue.record("Expected an authenticated control cancellation frame")
            return
        }
        let request = try control.decodeRequest()

        #expect(control.authentication != nil)
        #expect(request.requestID == cancellationRequestID)
        #expect(request.method == DVCOperation.companionCancel.rawValue)
        guard case .object(let parameters) = request.parameters,
              case .string(let encodedTarget)? = parameters["requestId"] else {
            Issue.record("Expected an exact requestId cancellation target")
            return
        }
        #expect(encodedTarget == targetRequestID.uuidString.lowercased())
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
#endif
