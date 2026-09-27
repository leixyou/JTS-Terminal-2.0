#if ENABLE_RDP_2
import CryptoKit
import Foundation
import LocalAuthentication
import Security

nonisolated enum RDPKeychainStoreError: LocalizedError {
    case security(OSStatus)
    case invalidSecret

    var errorDescription: String? {
        switch self {
        case .security(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain operation failed: \(message ?? String(status))."
        case .invalidSecret:
            return "The Keychain item did not contain a valid UTF-8 secret."
        }
    }
}

/// Stores Companion identity material and exposes the obsolete direct-Keychain
/// RDP password item only for one-time migration into the encrypted vault.
/// New or updated RDP passwords must never be written here.
nonisolated enum RDPKeychainStore {
    private static let legacyPasswordService = "com.lljts.JTSTerminal.rdp-password.v1"
    private static let pairingService = "com.lljts.JTSTerminal.companion-pairing.v2"
    private static let legacyPairingServices = [
        "com.lljts.JTSTerminal.companion-pairing.v1",
    ]
    private static let clientDeviceService = "com.lljts.JTSTerminal.companion-client-device.v2"
    private static let legacyClientDeviceServices = [
        "com.lljts.JTSTerminal.companion-client-device.v1",
    ]
    private static let peerService = "com.lljts.JTSTerminal.companion-peer.v2"
    private static let legacyPeerServices = [
        "com.lljts.JTSTerminal.companion-peer.v1",
    ]

    private static func targetAccount(targetID: UUID) -> String {
        "target:\(targetID.uuidString.lowercased())"
    }

    static func readLegacyPassword(targetID: UUID) throws -> String? {
        guard let data = try read(
            service: legacyPasswordService,
            account: targetAccount(targetID: targetID)
        ) else {
            return nil
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw RDPKeychainStoreError.invalidSecret
        }
        return password
    }

    static func deleteLegacyPassword(targetID: UUID) throws {
        try delete(
            service: legacyPasswordService,
            account: targetAccount(targetID: targetID),
            authenticationUIAllowed: false
        )
    }

    fileprivate static func companionSigningKey(targetID: UUID) throws -> P256.Signing.PrivateKey {
        let account = targetAccount(targetID: targetID)
        if let data = try readMigratingLegacy(
            service: pairingService,
            legacyServices: legacyPairingServices,
            account: account
        ) {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = P256.Signing.PrivateKey()
        try save(key.rawRepresentation, service: pairingService, account: account)
        return key
    }

    fileprivate static func companionClientDeviceID(targetID: UUID) throws -> UUID {
        let account = targetAccount(targetID: targetID)
        if let data = try readMigratingLegacy(
            service: clientDeviceService,
            legacyServices: legacyClientDeviceServices,
            account: account
        ) {
            guard let value = String(data: data, encoding: .utf8),
                  let deviceID = UUID(uuidString: value) else {
                throw RDPKeychainStoreError.invalidSecret
            }
            return deviceID
        }
        let deviceID = UUID()
        try save(
            Data(deviceID.uuidString.lowercased().utf8),
            service: clientDeviceService,
            account: account
        )
        return deviceID
    }

    fileprivate static func deleteCompanionPairing(targetID: UUID) throws {
        let account = targetAccount(targetID: targetID)
        try delete(service: pairingService, account: account)
        try delete(service: clientDeviceService, account: account)
        for service in legacyPairingServices {
            try delete(service: service, account: account)
        }
        for service in legacyClientDeviceServices {
            try delete(service: service, account: account)
        }
    }

    fileprivate static func saveCompanionPeerFingerprint(_ fingerprint: String, targetID: UUID) throws {
        guard let normalized = RDPConnectionProfile.normalizedFingerprint(fingerprint) else {
            throw RDPKeychainStoreError.invalidSecret
        }
        try save(
            Data(normalized.utf8),
            service: peerService,
            account: targetAccount(targetID: targetID)
        )
    }

    fileprivate static func readCompanionPeerFingerprint(targetID: UUID) throws -> String? {
        guard let data = try readMigratingLegacy(
            service: peerService,
            legacyServices: legacyPeerServices,
            account: targetAccount(targetID: targetID)
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8),
              let normalized = RDPConnectionProfile.normalizedFingerprint(value) else {
            throw RDPKeychainStoreError.invalidSecret
        }
        return normalized
    }

    fileprivate static func deleteCompanionPeer(targetID: UUID) throws {
        let account = targetAccount(targetID: targetID)
        try delete(service: peerService, account: account)
        for service in legacyPeerServices {
            try delete(service: service, account: account)
        }
    }

    private static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw RDPKeychainStoreError.security(updateStatus)
        }

        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RDPKeychainStoreError.security(addStatus)
        }
    }

    private static func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RDPKeychainStoreError.security(status)
        }
        return data
    }

    private static func readMigratingLegacy(
        service: String,
        legacyServices: [String],
        account: String
    ) throws -> Data? {
        if let data = try read(service: service, account: account) {
            return data
        }
        for legacyService in legacyServices {
            guard let data = try read(service: legacyService, account: account) else {
                continue
            }
            try save(data, service: service, account: account)
            try? delete(
                service: legacyService,
                account: account,
                authenticationUIAllowed: false
            )
            return data
        }
        return nil
    }

    private static func delete(
        service: String,
        account: String,
        authenticationUIAllowed: Bool = true
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if !authenticationUIAllowed {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            if !authenticationUIAllowed,
               status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
                || status == errSecUserCanceled {
                return
            }
            throw RDPKeychainStoreError.security(status)
        }
    }
}

nonisolated struct RDPCompanionLocalIdentity: Sendable {
    let signingKey: P256.Signing.PrivateKey
    let clientDeviceID: UUID
}

/// Injectable synchronous Keychain operations. Production callers must use
/// `RDPCompanionKeychainAccess` so these potentially interactive operations
/// never execute on the main actor.
nonisolated struct RDPCompanionKeychainBackend: Sendable {
    let signingKey: @Sendable (_ targetID: UUID) throws -> P256.Signing.PrivateKey
    let clientDeviceID: @Sendable (_ targetID: UUID) throws -> UUID
    let deletePairing: @Sendable (_ targetID: UUID) throws -> Void
    let savePeerFingerprint: @Sendable (_ fingerprint: String, _ targetID: UUID) throws -> Void
    let readPeerFingerprint: @Sendable (_ targetID: UUID) throws -> String?
    let deletePeer: @Sendable (_ targetID: UUID) throws -> Void

    static let live = Self(
        signingKey: { targetID in
            try RDPKeychainStore.companionSigningKey(targetID: targetID)
        },
        clientDeviceID: { targetID in
            try RDPKeychainStore.companionClientDeviceID(targetID: targetID)
        },
        deletePairing: { targetID in
            try RDPKeychainStore.deleteCompanionPairing(targetID: targetID)
        },
        savePeerFingerprint: { fingerprint, targetID in
            try RDPKeychainStore.saveCompanionPeerFingerprint(fingerprint, targetID: targetID)
        },
        readPeerFingerprint: { targetID in
            try RDPKeychainStore.readCompanionPeerFingerprint(targetID: targetID)
        },
        deletePeer: { targetID in
            try RDPKeychainStore.deleteCompanionPeer(targetID: targetID)
        }
    )
}

/// Serializes all Companion identity and peer-pin Keychain access away from the
/// main actor. Keychain may synchronously wait for securityd or user approval,
/// while the RDP framebuffer and visual-only session must remain responsive.
///
/// Only `Sendable` value types cross this queue boundary. Companion protocol
/// and UI state remain owned by their existing main-actor callers.
nonisolated final class RDPCompanionKeychainAccess: @unchecked Sendable {
    static let shared = RDPCompanionKeychainAccess()

    private let queue: DispatchQueue
    private let backend: RDPCompanionKeychainBackend
    /// Queue-confined process cache. A hello followed by authorization must not
    /// re-open the same Keychain items or produce a second authorization UI.
    private var localIdentitiesByTargetID: [UUID: RDPCompanionLocalIdentity] = [:]

    init(
        queueLabel: String = "com.lljts.JTSTerminal.rdp-companion-keychain-access",
        backend: RDPCompanionKeychainBackend = .live
    ) {
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.backend = backend
    }

    func localIdentity(targetID: UUID) async throws -> RDPCompanionLocalIdentity {
        let backend = backend
        return try await perform { [self] in
            if let identity = localIdentitiesByTargetID[targetID] {
                return identity
            }
            let identity = RDPCompanionLocalIdentity(
                signingKey: try backend.signingKey(targetID),
                clientDeviceID: try backend.clientDeviceID(targetID)
            )
            localIdentitiesByTargetID[targetID] = identity
            return identity
        }
    }

    func signingKey(targetID: UUID) async throws -> P256.Signing.PrivateKey {
        try await localIdentity(targetID: targetID).signingKey
    }

    func deletePairing(targetID: UUID) async throws {
        let backend = backend
        try await perform { [self] in
            try backend.deletePairing(targetID)
            localIdentitiesByTargetID.removeValue(forKey: targetID)
        }
    }

    func savePeerFingerprint(_ fingerprint: String, targetID: UUID) async throws {
        let backend = backend
        try await perform {
            try backend.savePeerFingerprint(fingerprint, targetID)
        }
    }

    func readPeerFingerprint(targetID: UUID) async throws -> String? {
        let backend = backend
        return try await perform {
            try backend.readPeerFingerprint(targetID)
        }
    }

    func deletePeer(targetID: UUID) async throws {
        let backend = backend
        try await perform {
            try backend.deletePeer(targetID)
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
        try Task.checkCancellation()
        return value
    }
}

#endif
