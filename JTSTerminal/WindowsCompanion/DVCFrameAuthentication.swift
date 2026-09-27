#if ENABLE_RDP_2
import CryptoKit
import Foundation

nonisolated enum DVCFrameDirection: UInt8, Sendable {
    case macToWindows = 1
    case windowsToMac = 2
}

/// Cryptographically binds every post-authorization DVC frame to one fresh
/// hello/authorize exchange. The wire signature is fixed-width P-256 P1363
/// (`r || s`) so Swift CryptoKit and .NET interoperate without DER ambiguity.
nonisolated struct DVCFrameAuthenticator: Sendable {
    static let frameDomain = Data("JTS-COMPANION-DVC-FRAME-AUTH-V1\0".utf8)
    static let sessionDomain = Data("JTS-COMPANION-DVC-SESSION-V1\0".utf8)

    private let sessionBinding: Data
    private let signingKey: P256.Signing.PrivateKey
    private let peerPublicKey: P256.Signing.PublicKey

    init(
        sessionBinding: Data,
        signingKey: P256.Signing.PrivateKey,
        peerPublicKeyDER: Data
    ) throws {
        guard sessionBinding.count == SHA256.byteCount else {
            throw DVCProtocolError.invalidFrameAuthentication
        }
        self.sessionBinding = sessionBinding
        self.signingKey = signingKey
        self.peerPublicKey = try P256.Signing.PublicKey(derRepresentation: peerPublicKeyDER)
    }

    func sign(_ frame: DVCFrame, direction: DVCFrameDirection) throws -> DVCFrame {
        guard frame.authentication == nil else {
            throw DVCProtocolError.invalidFrameAuthentication
        }
        let metadata = try DVCWireCodec.applicationMetadata(for: frame)
        let authenticatedFlags = metadata.flags.union(.authenticated)
        let canonical = Self.canonicalPayload(
            protocolVersion: metadata.version,
            direction: direction,
            frameType: metadata.kind,
            flags: authenticatedFlags.rawValue,
            sequence: metadata.sequence,
            applicationPayload: metadata.payload,
            sessionBinding: sessionBinding
        )
        let signature = try signingKey.signature(for: canonical).rawRepresentation
        return try frame.settingAuthentication(
            DVCFrameAuthenticationEnvelope(signature: signature),
            flags: authenticatedFlags
        )
    }

    func verify(_ frame: DVCFrame, direction: DVCFrameDirection) throws -> DVCFrame {
        guard let authentication = frame.authentication else {
            throw DVCProtocolError.missingFrameAuthentication
        }
        let metadata = try DVCWireCodec.applicationMetadata(for: frame)
        guard metadata.flags.contains(.authenticated) else {
            throw DVCProtocolError.invalidFrameAuthentication
        }
        let canonical = Self.canonicalPayload(
            protocolVersion: metadata.version,
            direction: direction,
            frameType: metadata.kind,
            flags: metadata.flags.rawValue,
            sequence: metadata.sequence,
            applicationPayload: metadata.payload,
            sessionBinding: sessionBinding
        )
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: authentication.signature
        )
        guard peerPublicKey.isValidSignature(signature, for: canonical) else {
            throw DVCProtocolError.invalidFrameAuthentication
        }
        return frame
    }

    static func deriveSessionBinding(
        windowsDeviceID: UUID,
        clientDeviceID: UUID,
        helloChallenge: Data,
        authorizationChallenge: Data
    ) throws -> Data {
        guard helloChallenge.count == 32, authorizationChallenge.count == 32 else {
            throw DVCProtocolError.invalidFrameAuthentication
        }
        var material = Data(capacity: sessionDomain.count + 16 + 16 + 32 + 32)
        material.append(sessionDomain)
        material.append(contentsOf: WindowsCompanionAuthorizationProof.dotNetGuidBytes(windowsDeviceID))
        material.append(contentsOf: WindowsCompanionAuthorizationProof.dotNetGuidBytes(clientDeviceID))
        material.append(helloChallenge)
        material.append(authorizationChallenge)
        return Data(SHA256.hash(data: material))
    }

    /// Canonical layout (all integers big-endian):
    /// domain || UInt16 protocol || UInt8 direction || UInt8 type ||
    /// UInt8 flags || UInt8 reserved(0) || UInt64 sequence ||
    /// UInt32 applicationLength || 32-byte sessionBinding || SHA256(payload).
    static func canonicalPayload(
        protocolVersion: Int,
        direction: DVCFrameDirection,
        frameType: UInt8,
        flags: UInt8,
        sequence: UInt64,
        applicationPayload: Data,
        sessionBinding: Data
    ) -> Data {
        precondition(protocolVersion >= 0 && protocolVersion <= Int(UInt16.max))
        precondition(applicationPayload.count <= Int(UInt32.max))
        precondition(sessionBinding.count == SHA256.byteCount)
        var canonical = Data(capacity: frameDomain.count + 2 + 4 + 8 + 4 + 32 + 32)
        canonical.append(frameDomain)
        canonical.appendFrameBigEndian(UInt16(protocolVersion))
        canonical.append(direction.rawValue)
        canonical.append(frameType)
        canonical.append(flags)
        canonical.append(0)
        canonical.appendFrameBigEndian(sequence)
        canonical.appendFrameBigEndian(UInt32(applicationPayload.count))
        canonical.append(sessionBinding)
        canonical.append(contentsOf: SHA256.hash(data: applicationPayload))
        return canonical
    }
}

private extension DVCFrame {
    nonisolated func settingAuthentication(
        _ authentication: DVCFrameAuthenticationEnvelope,
        flags: DVCFrameFlags
    ) throws -> DVCFrame {
        switch self {
        case .control(var frame):
            frame.flags = flags
            frame.authentication = authentication
            try frame.validate()
            return .control(frame)
        case .binary(var frame):
            frame.flags = flags
            frame.authentication = authentication
            try frame.validate()
            return .binary(frame)
        case .ping(var frame):
            frame.flags = flags
            frame.authentication = authentication
            try frame.validate()
            return .ping(frame)
        case .pong(var frame):
            frame.flags = flags
            frame.authentication = authentication
            try frame.validate()
            return .pong(frame)
        }
    }
}

private extension Data {
    nonisolated mutating func appendFrameBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
#endif
