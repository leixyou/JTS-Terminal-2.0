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

    static func save(_ secret: String, for profile: MobileServerProfile, kind: SecretKind) throws {
        let data = Data(secret.utf8)
        let account = account(for: profile, kind: kind)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: profile, kind: kind),
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

    private static func account(for profile: MobileServerProfile, kind: SecretKind) -> String {
        "\(profile.account)#\(kind.rawValue)"
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
