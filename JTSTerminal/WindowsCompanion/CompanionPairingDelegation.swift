#if ENABLE_RDP_2
import CryptoKit
import Foundation

nonisolated enum CompanionPairingAuthorizationSource: String, Codable, Sendable {
    case interactive
    case ownerDelegated
}

/// Device AI control includes this delegation. The short enrollment deadline
/// only limits importing its public request; the installed grant lasts until
/// revoked. Neither record contains the Mac signing key or a bearer credential.
nonisolated struct CompanionPairingDelegationGrant: Codable, Equatable, Identifiable, Sendable {
    var grantID: UUID
    var targetID: UUID
    var targetBinding: String
    var macDeviceID: UUID
    var macFingerprintSHA256: String
    var windowsDeviceID: UUID
    var windowsFingerprintSHA256: String
    var authorizationSource: CompanionPairingAuthorizationSource = .ownerDelegated
    var createdAt: Date
    var revokedAt: Date?
    var pendingRemoteRevocation = false
    /// Every explicit revocation advances this value, even when the grant was
    /// already revoked. It invalidates restores waiting for Keychain access.
    var revocationRevision: UInt64 = 0

    var id: UUID { grantID }
    var isRevoked: Bool { revokedAt != nil }

    func matches(targetID: UUID, targetBinding: String, peer: WindowsCompanionPeerIdentity) -> Bool {
        self.targetID == targetID && self.targetBinding == targetBinding
            && macDeviceID == peer.clientDeviceID
            && macFingerprintSHA256 == peer.clientFingerprintSHA256
            && windowsDeviceID == peer.deviceID
            && windowsFingerprintSHA256 == peer.fingerprintSHA256
    }

    func validate() throws {
        guard grantID != .companionEmpty, targetID != .companionEmpty,
              macDeviceID != .companionEmpty, windowsDeviceID != .companionEmpty,
              authorizationSource == .ownerDelegated,
              Self.validTargetBinding(targetBinding),
              Self.validFingerprint(macFingerprintSHA256),
              Self.validFingerprint(windowsFingerprintSHA256),
              createdAt.timeIntervalSince1970.isFinite,
              revokedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              !pendingRemoteRevocation || isRevoked else {
            throw CompanionPairingDelegationFailure.invalidRecord
        }
    }

    static func validTargetBinding(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 512
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case grantID, targetID, targetBinding, macDeviceID, macFingerprintSHA256
        case windowsDeviceID, windowsFingerprintSHA256, authorizationSource
        case createdAt, revokedAt, pendingRemoteRevocation, revocationRevision
    }
}

extension CompanionPairingDelegationGrant {
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grantID = try values.decode(UUID.self, forKey: .grantID)
        targetID = try values.decode(UUID.self, forKey: .targetID)
        targetBinding = try values.decode(String.self, forKey: .targetBinding)
        macDeviceID = try values.decode(UUID.self, forKey: .macDeviceID)
        macFingerprintSHA256 = try values.decode(String.self, forKey: .macFingerprintSHA256)
        windowsDeviceID = try values.decode(UUID.self, forKey: .windowsDeviceID)
        windowsFingerprintSHA256 = try values.decode(String.self, forKey: .windowsFingerprintSHA256)
        authorizationSource = try values.decode(CompanionPairingAuthorizationSource.self, forKey: .authorizationSource)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        revokedAt = try values.decodeIfPresent(Date.self, forKey: .revokedAt)
        pendingRemoteRevocation = try values.decode(Bool.self, forKey: .pendingRemoteRevocation)
        // Existing records predate the persistent revocation event counter.
        revocationRevision = try values.decodeIfPresent(UInt64.self, forKey: .revocationRevision) ?? 0
    }
}

nonisolated struct CompanionPairingDelegationEnrollmentRequest: Encodable, Sendable {
    struct MacIdentity: Encodable, Sendable {
        var deviceId: UUID
        var publicKeyBase64: String
        var fingerprintSha256: String
    }
    struct ExpectedWindows: Encodable, Sendable {
        var deviceId: UUID
        var fingerprintSha256: String
    }

    let schemaVersion = 1
    let authorizationSource = CompanionPairingAuthorizationSource.ownerDelegated
    let authorizationReference = "device-ai-control-enabled"
    var grantId: UUID
    var targetId: UUID
    var targetBinding: String
    var macIdentity: MacIdentity
    var expectedWindows: ExpectedWindows
    var issuedAtUtc: Date
    var expiresAtUtc: Date

    init(
        grant: CompanionPairingDelegationGrant,
        localIdentity: RDPCompanionLocalIdentity,
        issuedAt: Date,
        validFor: TimeInterval
    ) throws {
        try grant.validate()
        let publicKey = localIdentity.signingKey.publicKey.derRepresentation
        guard !grant.isRevoked,
              validFor.isFinite, validFor >= 1, validFor <= 30 * 60,
              issuedAt.timeIntervalSince1970.isFinite,
              localIdentity.clientDeviceID == grant.macDeviceID,
              WindowsCompanionAuthorizationProof.fingerprint(publicKeyDER: publicKey)
                == grant.macFingerprintSHA256 else {
            throw CompanionPairingDelegationFailure.invalidEnrollment
        }
        grantId = grant.grantID
        targetId = grant.targetID
        targetBinding = grant.targetBinding
        macIdentity = MacIdentity(
            deviceId: grant.macDeviceID,
            publicKeyBase64: publicKey.base64EncodedString(),
            fingerprintSha256: grant.macFingerprintSHA256
        )
        expectedWindows = ExpectedWindows(
            deviceId: grant.windowsDeviceID,
            fingerprintSha256: grant.windowsFingerprintSHA256
        )
        issuedAtUtc = issuedAt
        expiresAtUtc = issuedAt.addingTimeInterval(validFor)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

nonisolated struct CompanionPairingDelegationExport: Sendable {
    var grant: CompanionPairingDelegationGrant
    var requestJSON: Data
    var requestBase64: String { requestJSON.base64EncodedString() }
}

nonisolated enum CompanionPairingDelegationFailure: LocalizedError {
    case invalidRecord
    case invalidEnrollment
    case identityChanged
    case grantMissing
    case grantRevoked
    case receiptMismatch
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The device pairing delegation record is invalid."
        case .invalidEnrollment: "The device pairing enrollment request is invalid or exceeds its 30-minute lifetime."
        case .identityChanged: "The Mac or Windows device identity changed. Reconnect and verify the device before enrollment."
        case .grantMissing: "No matching device AI pairing delegation is stored on this Mac."
        case .grantRevoked: "Device AI pairing delegation was revoked. Explicitly re-enable device AI control before enrolling again."
        case .receiptMismatch: "The authenticated Windows pairing receipt does not match this device delegation."
        case .storageUnavailable: "Device pairing delegation storage is unavailable or unsafe. Access remains blocked."
        }
    }
}

private extension UUID {
    nonisolated static let companionEmpty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
#endif
