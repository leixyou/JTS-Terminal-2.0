//
//  MobileCredentialStore.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import Foundation
import Security

enum MobileCredentialStore {
    enum SecretKind: String, CaseIterable {
        case password
        case privateKey
        case privateKeyPassphrase
    }

    private static let service = "com.lljts.JTSTerminal.iOS.credentials"
    static let migrationDefaultsKey = "jts-terminal-ios.credentials-keyed-by-profile.v2"

    static func save(_ secret: String, for profile: MobileServerProfile, kind: SecretKind) throws {
        try save(secret, account: account(for: profile, kind: kind))
    }

    private static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        try delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MobileCredentialError.keychain(status)
        }
    }

    static func read(for profile: MobileServerProfile, kind: SecretKind) throws -> String? {
        try read(account: account(for: profile, kind: kind))
    }

    private static func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MobileCredentialError.keychain(status)
        }
        guard let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw MobileCredentialError.invalidData
        }
        return secret
    }

    static func delete(for profile: MobileServerProfile, kind: SecretKind) {
        try? delete(account: account(for: profile, kind: kind))
    }

    static func deleteAll(for profile: MobileServerProfile) {
        for kind in SecretKind.allCases {
            delete(for: profile, kind: kind)
        }
    }

    static func deleteAllStoredSecrets() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func credentials(for profile: MobileServerProfile) -> MobileSSHCredentials {
        MobileSSHCredentials(
            password: try? read(for: profile, kind: .password),
            privateKey: try? read(for: profile, kind: .privateKey),
            privateKeyPassphrase: try? read(for: profile, kind: .privateKeyPassphrase)
        )
    }

    /// Secrets belong to one saved profile. Keying them by the profile ID
    /// keeps them through host or username edits and stops two profiles for
    /// the same endpoint from deleting each other's credentials.
    static func account(for profile: MobileServerProfile, kind: SecretKind) -> String {
        "profile:\(profile.id.uuidString.lowercased())#\(kind.rawValue)"
    }

    /// Account format used up to iOS 1.1, shared by every profile with the
    /// same `user@host:port`.
    static func legacyAccount(for profile: MobileServerProfile, kind: SecretKind) -> String {
        "\(profile.account)#\(kind.rawValue)"
    }

    /// Copies endpoint-keyed secrets from earlier versions to each profile
    /// that uses them. A legacy item is removed only after every profile that
    /// referenced it received its own copy; any failure keeps it and retries
    /// on the next launch.
    static func migrateLegacySecrets(
        for profiles: [MobileServerProfile],
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: migrationDefaultsKey) else { return }

        var copiedLegacyAccounts = Set<String>()
        var failedLegacyAccounts = Set<String>()
        for profile in profiles {
            for kind in SecretKind.allCases {
                let legacy = legacyAccount(for: profile, kind: kind)
                let secret: String?
                do {
                    secret = try read(account: legacy)
                } catch {
                    failedLegacyAccounts.insert(legacy)
                    continue
                }
                guard let secret else { continue }

                let target = account(for: profile, kind: kind)
                do {
                    if try read(account: target) == nil {
                        try save(secret, account: target)
                    }
                    copiedLegacyAccounts.insert(legacy)
                } catch {
                    failedLegacyAccounts.insert(legacy)
                }
            }
        }

        for legacy in copiedLegacyAccounts.subtracting(failedLegacyAccounts) {
            try? delete(account: legacy)
        }
        if failedLegacyAccounts.isEmpty {
            defaults.set(true, forKey: migrationDefaultsKey)
        }
    }

    private static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw MobileCredentialError.keychain(status)
        }
    }
}

enum MobileCredentialError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain operation failed with status \(status)."
        case .invalidData:
            return "Stored credential data is not valid UTF-8."
        }
    }
}
