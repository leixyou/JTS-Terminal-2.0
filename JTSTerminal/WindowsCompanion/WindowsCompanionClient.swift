#if ENABLE_RDP_2
import CryptoKit
import Foundation

nonisolated struct WindowsCompanionPeerIdentity: Equatable, Sendable {
    var deviceID: UUID
    var fingerprintSHA256: String
    var publicKeyDER: Data
    var agentVersion: String
    var capabilities: Set<String>
    var clientDeviceID: UUID
    var clientFingerprintSHA256: String
    var clientAuthorization: WindowsCompanionClientAuthorization
    var sessionBinding: Data
}

nonisolated struct WindowsCompanionClientAuthorization: Equatable, Sendable {
    var challenge: Data
    var expiresAtUnixMilliseconds: Int64
    var pairingRequired: Bool
}

nonisolated struct WindowsCompanionAuthorizationResult: Equatable, Sendable {
    var newlyPaired: Bool
    var clientDeviceID: UUID
    var clientFingerprintSHA256: String
    var stateRevision: UInt64
    var authorizationSource: CompanionPairingAuthorizationSource = .interactive
    var delegationGrantID: UUID?
}

nonisolated enum WindowsCompanionAuthorizationProof {
    static func parameters(
        windowsDeviceID: UUID,
        clientDeviceID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        challenge: Data,
        signingKey: P256.Signing.PrivateKey
    ) throws -> [String: Any] {
        guard sequence > 0, challenge.count == 32 else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_AUTHORIZATION_INVALID",
                message: "The Companion authorization proof parameters are invalid.",
                retryable: false
            )
        }
        let publicKeyDER = signingKey.publicKey.derRepresentation
        let signature = try signingKey.signature(for: canonicalPayload(
            windowsDeviceID: windowsDeviceID,
            clientDeviceID: clientDeviceID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            challenge: challenge
        ))
        return [
            "deviceId": clientDeviceID.uuidString.lowercased(),
            "fingerprintSha256": fingerprint(publicKeyDER: publicKeyDER),
            "publicKeyBase64": publicKeyDER.base64EncodedString(),
            "challengeBase64": challenge.base64EncodedString(),
            "sequence": sequence,
            "issuedAtUnixMilliseconds": issuedAtUnixMilliseconds,
            "signatureBase64": signature.rawRepresentation.base64EncodedString(),
        ]
    }

    static func canonicalPayload(
        windowsDeviceID: UUID,
        clientDeviceID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        challenge: Data
    ) -> Data {
        var payload = Data("JTS-MAC-COMPANION-AUTHORIZATION-V1\0".utf8)
        payload.append(contentsOf: dotNetGuidBytes(windowsDeviceID))
        payload.append(contentsOf: dotNetGuidBytes(clientDeviceID))
        payload.appendLittleEndian(sequence)
        payload.appendLittleEndian(issuedAtUnixMilliseconds)
        payload.append(challenge)
        return payload
    }

    static func fingerprint(publicKeyDER: Data) -> String {
        SHA256.hash(data: publicKeyDER)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    static func dotNetGuidBytes(_ uuid: UUID) -> [UInt8] {
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        return [
            bytes[3], bytes[2], bytes[1], bytes[0],
            bytes[5], bytes[4],
            bytes[7], bytes[6],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        ]
    }
}

nonisolated struct WindowsCompanionRequestFailure: LocalizedError, Sendable {
    var code: String
    var message: String
    var retryable: Bool

    var errorDescription: String? { "\(code): \(message)" }
}

nonisolated enum WindowsCompanionCancellationFrame {
    static func encode(
        targetRequestID: UUID,
        cancellationRequestID: UUID,
        sequence: UInt64,
        deadlineUnixMilliseconds: Int64,
        authenticator: DVCFrameAuthenticator
    ) throws -> Data {
        let request = DVCCompanionRequest(
            requestID: cancellationRequestID,
            method: DVCOperation.companionCancel.rawValue,
            deadlineUnixMilliseconds: deadlineUnixMilliseconds,
            idempotencyKey: nil,
            expectedStateRevision: nil,
            parameters: .object([
                "requestId": .string(targetRequestID.uuidString.lowercased()),
            ])
        )
        let frame = DVCFrame.control(try DVCControlFrame(request: request, sequence: sequence))
        return try DVCWireCodec.encode(
            authenticator.sign(frame, direction: .macToWindows)
        )
    }
}

@MainActor
final class WindowsCompanionClient {
    typealias Transport = @MainActor (Data) async throws -> Void
    typealias LocalIdentityLoader = @Sendable (UUID) async throws -> RDPCompanionLocalIdentity

    private struct PendingReply {
        var method: String
        var continuation: CheckedContinuation<[String: Any], Error>
        var sendTask: Task<Void, Error>
        var timeoutTask: Task<Void, Never>
    }

    private struct PendingAuthorizationContext {
        var authenticator: DVCFrameAuthenticator
        var clientDeviceID: UUID
        var clientFingerprintSHA256: String
    }

    private let sessionID: UUID
    private let transport: Transport
    private let localIdentityLoader: LocalIdentityLoader
    private var decoder = DVCIncrementalDecoder()
    private var nextSequence: UInt64 = 1
    private var inboundReplayGuard = DVCSequenceReplayGuard()
    private var pendingReplies: [UUID: PendingReply] = [:]
    private var transferManager: WindowsCompanionBinaryTransferManager?
    private var protocolFailure: WindowsCompanionRequestFailure?
    private var frameAuthenticator: DVCFrameAuthenticator?
    private var pendingAuthorizationContext: PendingAuthorizationContext?

    private(set) var peerIdentity: WindowsCompanionPeerIdentity?

    init(
        sessionID: UUID,
        transport: @escaping Transport,
        localIdentityLoader: @escaping LocalIdentityLoader = { targetID in
            try await RDPCompanionKeychainAccess.shared.localIdentity(targetID: targetID)
        }
    ) {
        self.sessionID = sessionID
        self.transport = transport
        self.localIdentityLoader = localIdentityLoader
    }

    static func executeCancellableTransport(
        _ frame: Data,
        using transport: Transport
    ) async throws {
        try Task.checkCancellation()
        try await transport(frame)
    }

    deinit {
        for pending in pendingReplies.values {
            pending.sendTask.cancel()
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: WindowsCompanionRequestFailure(
                code: "COMPANION_DISCONNECTED",
                message: "The Windows Companion channel closed.",
                retryable: true
            ))
        }
    }

    func receive(_ data: Data) {
        guard protocolFailure == nil else { return }
        do {
            for frame in try decoder.append(data) {
                let authenticated = frame.authentication != nil
                let verifiedFrame: DVCFrame
                if let frameAuthenticator {
                    verifiedFrame = try frameAuthenticator.verify(frame, direction: .windowsToMac)
                } else if authenticated, let pending = pendingAuthorizationContext {
                    verifiedFrame = try pending.authenticator.verify(frame, direction: .windowsToMac)
                } else {
                    guard !authenticated else {
                        throw DVCProtocolError.invalidFrameAuthentication
                    }
                    verifiedFrame = frame
                }
                try inboundReplayGuard.accept(verifiedFrame.sequence)
                switch verifiedFrame {
                case .control(let control):
                    try receiveControl(control, authenticated: authenticated)
                case .ping(let ping):
                    Task { @MainActor [weak self] in
                        try? await self?.sendPong(for: ping)
                    }
                case .binary(let binary):
                    try binaryTransferManager().receive(binary)
                case .pong:
                    break
                }
            }
        } catch {
            let failure = WindowsCompanionRequestFailure(
                code: "DVC_PROTOCOL_INVALID",
                message: error.localizedDescription,
                retryable: false
            )
            protocolFailure = failure
            frameAuthenticator = nil
            pendingAuthorizationContext = nil
            transferManager?.cancelAll()
            failAll(failure)
        }
    }

    func performHello(
        targetID: UUID,
        timeoutMilliseconds: Int = 10_000
    ) async throws -> WindowsCompanionPeerIdentity {
        peerIdentity = nil
        var challenge = Data(count: 32)
        let status = challenge.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_CHALLENGE_FAILED",
                message: "Could not generate a secure Companion pairing challenge.",
                retryable: true
            )
        }
        let proofSequence = takeSequence()
        let result = try await request(
            method: DVCOperation.companionHello.rawValue,
            parameters: [
                "challengeBase64": challenge.base64EncodedString(),
                "sequence": proofSequence,
            ],
            deadlineMilliseconds: timeoutMilliseconds,
            idempotencyKey: nil,
            expectedStateRevision: nil,
            frameSequence: proofSequence
        )
        // A successful hello response is signed with the previous context when
        // re-handshaking, but Windows has already invalidated that context.
        frameAuthenticator = nil
        pendingAuthorizationContext = nil
        // Do not enter Keychain until a real Companion has answered hello. A
        // normal visual-only RDP target has no Companion channel and must never
        // trigger identity authorization prompts while the retry loop probes it.
        let localIdentity = try await localIdentityLoader(targetID)
        let signingKey = localIdentity.signingKey
        let clientDeviceID = localIdentity.clientDeviceID
        let clientFingerprint = WindowsCompanionAuthorizationProof.fingerprint(
            publicKeyDER: signingKey.publicKey.derRepresentation
        )
        let identity = try Self.verifyHello(
            result,
            expectedChallenge: challenge,
            expectedProofSequence: proofSequence,
            clientDeviceID: clientDeviceID,
            clientFingerprintSHA256: clientFingerprint
        )
        peerIdentity = identity
        return identity
    }

    func authorize(
        targetID: UUID,
        targetBinding: String? = nil,
        delegationStore: CompanionPairingDelegationStore? = nil,
        timeoutMilliseconds: Int = 120_000
    ) async throws -> WindowsCompanionAuthorizationResult {
        guard pendingAuthorizationContext == nil else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_AUTHORIZATION_IN_PROGRESS",
                message: "A Companion authorization exchange is already in progress.",
                retryable: true
            )
        }
        guard let peerIdentity else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_HELLO_REQUIRED",
                message: "A verified Companion hello is required before authorization.",
                retryable: true
            )
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard peerIdentity.clientAuthorization.expiresAtUnixMilliseconds > now else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_HELLO_REQUIRED",
                message: "The Companion authorization challenge expired. Start hello again.",
                retryable: true
            )
        }

        let localIdentity = try await localIdentityLoader(targetID)
        let signingKey = localIdentity.signingKey
        let clientDeviceID = localIdentity.clientDeviceID
        let clientFingerprint = WindowsCompanionAuthorizationProof.fingerprint(
            publicKeyDER: signingKey.publicKey.derRepresentation
        )
        guard clientDeviceID == peerIdentity.clientDeviceID,
              clientFingerprint == peerIdentity.clientFingerprintSHA256 else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_LOCAL_IDENTITY_CHANGED",
                message: "The Mac Companion identity changed after hello. Start pairing again.",
                retryable: false
            )
        }

        let proofSequence = takeSequence()
        let issuedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let parameters = try WindowsCompanionAuthorizationProof.parameters(
            windowsDeviceID: peerIdentity.deviceID,
            clientDeviceID: clientDeviceID,
            sequence: proofSequence,
            issuedAtUnixMilliseconds: issuedAt,
            challenge: peerIdentity.clientAuthorization.challenge,
            signingKey: signingKey
        )
        let prospectiveAuthenticator = try DVCFrameAuthenticator(
            sessionBinding: peerIdentity.sessionBinding,
            signingKey: signingKey,
            peerPublicKeyDER: peerIdentity.publicKeyDER
        )
        pendingAuthorizationContext = PendingAuthorizationContext(
            authenticator: prospectiveAuthenticator,
            clientDeviceID: clientDeviceID,
            clientFingerprintSHA256: clientFingerprint
        )
        do {
            let result = try await request(
                method: DVCOperation.companionAuthorize.rawValue,
                parameters: parameters,
                deadlineMilliseconds: timeoutMilliseconds,
                idempotencyKey: nil,
                expectedStateRevision: nil,
                frameSequence: proofSequence
            )
            let authorization = try Self.verifyAuthorizationResult(
                result,
                expectedClientDeviceID: clientDeviceID,
                expectedClientFingerprint: clientFingerprint
            )
            guard frameAuthenticator != nil else {
                throw WindowsCompanionRequestFailure(
                    code: "PAIRING_AUTHORIZATION_RESPONSE_UNSIGNED",
                    message: "The successful Companion authorization response was not frame-authenticated.",
                    retryable: false
                )
            }
            if let targetBinding {
                try (delegationStore ?? .shared).validateAuthorization(
                    authorization,
                    targetID: targetID,
                    targetBinding: targetBinding,
                    peer: peerIdentity
                )
            } else if authorization.authorizationSource == .ownerDelegated {
                // Older callers may still authorize an interactive peer, but
                // delegated receipts always require the exact profile binding.
                throw CompanionPairingDelegationFailure.grantMissing
            }
            pendingAuthorizationContext = nil
            return authorization
        } catch {
            pendingAuthorizationContext = nil
            frameAuthenticator = nil
            throw error
        }
    }

    func request(
        method: String,
        parameters: [String: Any],
        deadlineMilliseconds: Int?,
        idempotencyKey: String?,
        expectedStateRevision: UInt64?,
        frameSequence: UInt64? = nil
    ) async throws -> [String: Any] {
        if let protocolFailure {
            throw protocolFailure
        }
        let requestID = UUID()
        let sequence = frameSequence ?? takeSequence()
        let boundedDeadline = min(max(deadlineMilliseconds ?? 30_000, 1), 1_800_000)
        let deadline = Int64(Date().timeIntervalSince1970 * 1_000) + Int64(boundedDeadline)
        let request = DVCCompanionRequest(
            requestID: requestID,
            method: method,
            deadlineUnixMilliseconds: deadline,
            idempotencyKey: idempotencyKey,
            expectedStateRevision: expectedStateRevision,
            parameters: try DVCJSONValue(foundationValue: parameters)
        )
        let frame = try encodeForTransport(.control(DVCControlFrame(request: request, sequence: sequence)))

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let sendTask = Task { @MainActor [weak self] in
                    try Task.checkCancellation()
                    guard let self else {
                        throw WindowsCompanionRequestFailure(
                            code: "COMPANION_DISCONNECTED",
                            message: "The Windows Companion channel closed.",
                            retryable: true
                        )
                    }
                    try await Self.executeCancellableTransport(
                        frame,
                        using: self.transport
                    )
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(boundedDeadline))
                    guard !Task.isCancelled else { return }
                    await self?.cancelPendingRequest(
                        requestID,
                        failure: WindowsCompanionRequestFailure(
                            code: "DEADLINE_EXCEEDED",
                            message: "The Windows Companion request deadline elapsed.",
                            retryable: true
                        )
                    )
                }
                pendingReplies[requestID] = PendingReply(
                    method: method,
                    continuation: continuation,
                    sendTask: sendTask,
                    timeoutTask: timeoutTask
                )
                Task { @MainActor [weak self] in
                    let result = await sendTask.result
                    guard case .failure(let error) = result else { return }
                    self?.finishPendingRequest(requestID, throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancelPendingRequest(
                    requestID,
                    failure: CancellationError()
                )
            }
        }
    }

    /// Cancels operations owned by this live authenticated peer without
    /// clearing pairing or the frame-authentication context. Manual takeover
    /// uses this before returning authority to the human user.
    func cancelPendingOperations(deadlineMilliseconds: Int = 2_000) async {
        guard frameAuthenticator != nil else { return }
        _ = try? await request(
            method: DVCOperation.companionCancelPending.rawValue,
            parameters: [:],
            deadlineMilliseconds: deadlineMilliseconds,
            idempotencyKey: nil,
            expectedStateRevision: nil
        )
    }

    func cancelAll() {
        transferManager?.cancelAll()
        frameAuthenticator = nil
        pendingAuthorizationContext = nil
        failAll(code: "COMPANION_DISCONNECTED", message: "The Windows Companion channel closed.")
    }

    func uploadBinary(
        _ data: Data,
        purpose: String,
        deadlineMilliseconds: Int?,
        maximumBytes: Int64 = WindowsCompanionBinaryTransferManager.maximumTransferBytes
    ) async throws -> DVCBinaryTransferDescriptor {
        try await binaryTransferManager().upload(
            data,
            purpose: purpose,
            deadlineMilliseconds: deadlineMilliseconds,
            maximumBytes: maximumBytes
        )
    }

    func downloadBinary(
        _ descriptor: DVCBinaryTransferDescriptor,
        deadlineMilliseconds: Int?,
        maximumBytes: Int64 = WindowsCompanionBinaryTransferManager.maximumTransferBytes
    ) async throws -> Data {
        try await binaryTransferManager().download(
            descriptor,
            deadlineMilliseconds: deadlineMilliseconds,
            maximumBytes: maximumBytes
        )
    }

    func releaseBinary(_ transferID: UUID, deadlineMilliseconds: Int?) async {
        try? await binaryTransferManager().release(
            transferID,
            deadlineMilliseconds: deadlineMilliseconds
        )
    }

    private func receiveControl(_ frame: DVCControlFrame, authenticated: Bool) throws {
        let response = try frame.decodeResponse()
        guard let pending = pendingReplies[response.requestID] else {
            return
        }
        if pending.method == DVCOperation.companionAuthorize.rawValue, response.success {
            guard authenticated, let transition = pendingAuthorizationContext else {
                throw DVCProtocolError.missingFrameAuthentication
            }
            let value = try response.result?.foundationValue() ?? NSNull()
            guard let result = value as? [String: Any] else {
                throw DVCProtocolError.invalidJSONValue
            }
            _ = try Self.verifyAuthorizationResult(
                result,
                expectedClientDeviceID: transition.clientDeviceID,
                expectedClientFingerprint: transition.clientFingerprintSHA256
            )
            frameAuthenticator = transition.authenticator
            pendingAuthorizationContext = nil
        }
        if response.success {
            let value = try response.result?.foundationValue() ?? NSNull()
            let dictionary: [String: Any]
            if let object = value as? [String: Any] {
                dictionary = object
            } else {
                dictionary = ["value": value]
            }
            pendingReplies.removeValue(forKey: response.requestID)
            pending.sendTask.cancel()
            pending.timeoutTask.cancel()
            if pending.method == DVCOperation.companionUnpair.rawValue {
                frameAuthenticator = nil
                pendingAuthorizationContext = nil
            }
            pending.continuation.resume(returning: dictionary)
        } else {
            pendingReplies.removeValue(forKey: response.requestID)
            pending.sendTask.cancel()
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: WindowsCompanionRequestFailure(
                code: response.error?.code ?? "COMPANION_REQUEST_FAILED",
                message: response.error?.message ?? "The Windows Companion request failed.",
                retryable: response.error?.retryable ?? false
            ))
        }
    }

    private func sendPong(for ping: DVCHeartbeatFrame) async throws {
        let pong = DVCHeartbeatFrame(
            sequence: takeSequence(),
            flags: ping.flags,
            payload: ping.payload
        )
        try await transport(encodeForTransport(.pong(pong)))
    }

    private func cancelPendingRequest(_ requestID: UUID, failure: Error) async {
        guard let pending = pendingReplies[requestID] else { return }
        let sendResult = await pending.sendTask.result
        guard pendingReplies[requestID] != nil else { return }
        if case .success = sendResult,
           canSendRemoteCancellation(for: pending.method) {
            try? await sendRemoteCancellation(targetRequestID: requestID)
        }
        finishPendingRequest(requestID, throwing: failure)
    }

    private func sendRemoteCancellation(targetRequestID: UUID) async throws {
        guard let frameAuthenticator else { return }
        let frame = try WindowsCompanionCancellationFrame.encode(
            targetRequestID: targetRequestID,
            cancellationRequestID: UUID(),
            sequence: takeSequence(),
            deadlineUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000) + 5_000,
            authenticator: frameAuthenticator
        )
        try await transport(frame)
    }

    private func finishPendingRequest(_ requestID: UUID, throwing error: Error) {
        guard let pending = pendingReplies.removeValue(forKey: requestID) else { return }
        pending.sendTask.cancel()
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func canSendRemoteCancellation(for method: String) -> Bool {
        frameAuthenticator != nil && method != DVCOperation.companionHello.rawValue
            && method != DVCOperation.companionAuthorize.rawValue
            && method != DVCOperation.companionCancel.rawValue
    }

    private func binaryTransferManager() -> WindowsCompanionBinaryTransferManager {
        if let transferManager {
            return transferManager
        }
        let manager = WindowsCompanionBinaryTransferManager(
            request: { [weak self] method, parameters, deadline in
                guard let self else {
                    throw WindowsCompanionRequestFailure(
                        code: "COMPANION_DISCONNECTED",
                        message: "The Windows Companion channel closed.",
                        retryable: true
                    )
                }
                return try await self.request(
                    method: method,
                    parameters: parameters,
                    deadlineMilliseconds: deadline,
                    idempotencyKey: nil,
                    expectedStateRevision: nil
                )
            },
            sendChunk: { [weak self] transferID, offset, data, isFinal in
                guard let self else {
                    throw WindowsCompanionRequestFailure(
                        code: "COMPANION_DISCONNECTED",
                        message: "The Windows Companion channel closed.",
                        retryable: true
                    )
                }
                let frame = DVCBinaryFrame(
                    transferID: transferID,
                    sequence: self.takeSequence(),
                    offset: offset,
                    data: data,
                    isFinal: isFinal
                )
                try await self.transport(self.encodeForTransport(.binary(frame)))
            }
        )
        transferManager = manager
        return manager
    }

    private func takeSequence() -> UInt64 {
        defer { nextSequence = nextSequence == UInt64.max ? 1 : nextSequence + 1 }
        return nextSequence
    }

    private func encodeForTransport(_ frame: DVCFrame) throws -> Data {
        let protectedFrame = if let frameAuthenticator {
            try frameAuthenticator.sign(frame, direction: .macToWindows)
        } else {
            frame
        }
        return try DVCWireCodec.encode(protectedFrame)
    }

    private func failAll(code: String, message: String) {
        failAll(WindowsCompanionRequestFailure(
            code: code,
            message: message,
            retryable: true
        ))
    }

    private func failAll(_ failure: WindowsCompanionRequestFailure) {
        let values = pendingReplies.values
        pendingReplies.removeAll()
        for pending in values {
            pending.sendTask.cancel()
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: failure)
        }
    }

    private static func verifyHello(
        _ result: [String: Any],
        expectedChallenge: Data,
        expectedProofSequence: UInt64,
        clientDeviceID: UUID,
        clientFingerprintSHA256: String
    ) throws -> WindowsCompanionPeerIdentity {
        guard let protocolVersion = integer(result["protocolVersion"]),
              protocolVersion == WindowsCompanionDVC.protocolVersion,
              let agentVersion = result["agentVersion"] as? String,
              let proof = result["pairingProof"] as? [String: Any],
              let deviceIDString = proof["deviceId"] as? String,
              let deviceID = UUID(uuidString: deviceIDString),
              let fingerprint = proof["fingerprintSha256"] as? String,
              let normalizedFingerprint = RDPConnectionProfile.normalizedFingerprint(fingerprint),
              let publicKeyBase64 = proof["publicKeyBase64"] as? String,
              let publicKeyDER = Data(base64Encoded: publicKeyBase64),
              let challengeBase64 = proof["challengeBase64"] as? String,
              let challenge = Data(base64Encoded: challengeBase64),
              challenge == expectedChallenge,
              let sequence = unsignedInteger(proof["sequence"]),
              sequence == expectedProofSequence,
              let issuedAt = signedInteger(proof["issuedAtUnixMilliseconds"]),
              let signatureBase64 = proof["signatureBase64"] as? String,
              let signatureData = Data(base64Encoded: signatureBase64),
              let clientAuthorization = result["clientAuthorization"] as? [String: Any],
              let clientChallengeBase64 = clientAuthorization["challengeBase64"] as? String,
              let clientChallenge = Data(base64Encoded: clientChallengeBase64),
              clientChallenge.count == 32,
              let clientChallengeExpiry = signedInteger(clientAuthorization["expiresAtUnixMilliseconds"]),
              let pairingRequired = clientAuthorization["pairingRequired"] as? Bool else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_PROOF_INVALID",
                message: "The Windows Companion returned an invalid pairing proof.",
                retryable: false
            )
        }

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard issuedAt <= now + 60_000, issuedAt >= now - 5 * 60_000 else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_PROOF_EXPIRED",
                message: "The Windows Companion pairing proof is outside the allowed time window.",
                retryable: true
            )
        }
        guard clientChallengeExpiry > now,
              clientChallengeExpiry <= now + 3 * 60_000 else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_AUTHORIZATION_CHALLENGE_INVALID",
                message: "The Windows Companion authorization challenge is invalid or expired.",
                retryable: true
            )
        }
        let actualFingerprint = SHA256.hash(data: publicKeyDER)
            .map { String(format: "%02X", $0) }
            .joined()
        guard actualFingerprint == normalizedFingerprint else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_FINGERPRINT_INVALID",
                message: "The Windows Companion public-key fingerprint does not match its proof.",
                retryable: false
            )
        }

        var signedPayload = Data("JTS-WINDOWS-COMPANION-PAIRING-V1\0".utf8)
        signedPayload.append(contentsOf: WindowsCompanionAuthorizationProof.dotNetGuidBytes(deviceID))
        signedPayload.appendLittleEndian(sequence)
        signedPayload.appendLittleEndian(issuedAt)
        signedPayload.append(challenge)

        let publicKey = try P256.Signing.PublicKey(derRepresentation: publicKeyDER)
        let signature: P256.Signing.ECDSASignature
        if let raw = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData) {
            signature = raw
        } else {
            signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        }
        guard publicKey.isValidSignature(signature, for: signedPayload) else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_SIGNATURE_INVALID",
                message: "The Windows Companion pairing signature could not be verified.",
                retryable: false
            )
        }

        let capabilities = Set((result["capabilities"] as? [String]) ?? [])
        let sessionBinding = try DVCFrameAuthenticator.deriveSessionBinding(
            windowsDeviceID: deviceID,
            clientDeviceID: clientDeviceID,
            helloChallenge: expectedChallenge,
            authorizationChallenge: clientChallenge
        )
        return WindowsCompanionPeerIdentity(
            deviceID: deviceID,
            fingerprintSHA256: normalizedFingerprint,
            publicKeyDER: publicKeyDER,
            agentVersion: agentVersion,
            capabilities: capabilities,
            clientDeviceID: clientDeviceID,
            clientFingerprintSHA256: clientFingerprintSHA256,
            clientAuthorization: WindowsCompanionClientAuthorization(
                challenge: clientChallenge,
                expiresAtUnixMilliseconds: clientChallengeExpiry,
                pairingRequired: pairingRequired
            ),
            sessionBinding: sessionBinding
        )
    }

    static func verifyAuthorizationResult(
        _ result: [String: Any],
        expectedClientDeviceID: UUID,
        expectedClientFingerprint: String
    ) throws -> WindowsCompanionAuthorizationResult {
        guard result["authorized"] as? Bool == true,
              let newlyPaired = result["newlyPaired"] as? Bool,
              let clientDeviceIDString = result["clientDeviceId"] as? String,
              let clientDeviceID = UUID(uuidString: clientDeviceIDString),
              clientDeviceID == expectedClientDeviceID,
              let fingerprint = result["clientFingerprintSha256"] as? String,
              let normalizedFingerprint = RDPConnectionProfile.normalizedFingerprint(fingerprint),
              normalizedFingerprint == expectedClientFingerprint,
              let stateRevision = unsignedInteger(result["stateRevision"]),
              stateRevision > 0 else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_AUTHORIZATION_RESPONSE_INVALID",
                message: "The Windows Companion returned an invalid authorization result.",
                retryable: false
            )
        }
        let source: CompanionPairingAuthorizationSource
        if let value = result["authorizationSource"] {
            guard let raw = value as? String,
                  let parsed = CompanionPairingAuthorizationSource(rawValue: raw) else {
                throw CompanionPairingDelegationFailure.receiptMismatch
            }
            source = parsed
        } else {
            source = .interactive
        }
        let delegationGrantID: UUID?
        if let value = result["delegationGrantId"], !(value is NSNull) {
            guard let raw = value as? String, let id = UUID(uuidString: raw),
                  id.uuidString != "00000000-0000-0000-0000-000000000000" else {
                throw CompanionPairingDelegationFailure.receiptMismatch
            }
            delegationGrantID = id
        } else {
            delegationGrantID = nil
        }
        guard (source == .ownerDelegated) == (delegationGrantID != nil) else {
            throw CompanionPairingDelegationFailure.receiptMismatch
        }
        return WindowsCompanionAuthorizationResult(
            newlyPaired: newlyPaired,
            clientDeviceID: clientDeviceID,
            clientFingerprintSHA256: normalizedFingerprint,
            stateRevision: stateRevision,
            authorizationSource: source,
            delegationGrantID: delegationGrantID
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
            return UInt64(number.stringValue)
        }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }

    private static func signedInteger(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }

}

private extension DVCJSONValue {
    init(foundationValue value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                self = .number(value.doubleValue)
            } else if value.int64Value < 0 {
                self = .integer(value.int64Value)
            } else {
                self = .unsignedInteger(value.uint64Value)
            }
        case let value as Int:
            self = .integer(Int64(value))
        case let value as Int64:
            self = .integer(value)
        case let value as UInt64:
            self = .unsignedInteger(value)
        case let value as Double:
            self = .number(value)
        case let value as [Any]:
            self = .array(try value.map(Self.init(foundationValue:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(Self.init(foundationValue:)))
        default:
            throw DVCProtocolError.invalidJSONValue
        }
    }

    func foundationValue() throws -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return value
        case .unsignedInteger(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return try values.map { try $0.foundationValue() }
        case .object(let values): return try values.mapValues { try $0.foundationValue() }
        }
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

#endif
