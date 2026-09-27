#if ENABLE_RDP_2
import Foundation

nonisolated struct RDPPasswordStoreBackend: Sendable {
    let saveVault: @Sendable (_ secret: String, _ account: String) throws -> Void
    let readVault: @Sendable (_ account: String) throws -> String?
    let deleteVault: @Sendable (_ account: String) throws -> Void
    let readLegacyKeychain: @Sendable (_ targetID: UUID) throws -> String?
    let deleteLegacyKeychain: @Sendable (_ targetID: UUID) throws -> Void

    static let live = Self(
        saveVault: { secret, account in
            try CredentialStore.save(secret: secret, account: account)
        },
        readVault: { account in
            try CredentialStore.read(account: account)
        },
        deleteVault: { account in
            try CredentialStore.delete(account: account)
        },
        readLegacyKeychain: { targetID in
            try RDPKeychainStore.readLegacyPassword(targetID: targetID)
        },
        deleteLegacyKeychain: { targetID in
            try RDPKeychainStore.deleteLegacyPassword(targetID: targetID)
        }
    )
}

nonisolated struct RDPLegacyVaultAccount: Equatable, Sendable {
    let account: String
    /// Pre-target-ID RDP builds used the generic `username@host:port` account,
    /// which can also belong to an SSH profile. It may be copied for RDP
    /// compatibility but must not be deleted blindly.
    let deleteAfterMigration: Bool
}

/// RDP passwords use the same encrypted SQLite vault as SSH passwords, with a
/// stable target-specific account so editing a host, domain, or username does
/// not orphan the credential.
nonisolated enum RDPPasswordStore {
    static func account(targetID: UUID) -> String {
        "rdp-target:\(targetID.uuidString.lowercased())"
    }

    static func legacyVaultAccounts(
        username: String,
        host: String,
        port: Int,
        domain: String
    ) -> [RDPLegacyVaultAccount] {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let qualifiedUser = domain.isEmpty ? username : "\(domain)\\\(username)"
        return [
            RDPLegacyVaultAccount(
                account: "rdp://\(qualifiedUser)@\(host):\(port)",
                deleteAfterMigration: true
            ),
            RDPLegacyVaultAccount(
                account: "\(username)@\(host):\(port)",
                deleteAfterMigration: false
            ),
        ]
    }

    static func savePassword(
        _ password: String,
        targetID: UUID,
        legacyVaultAccounts: [RDPLegacyVaultAccount] = [],
        backend: RDPPasswordStoreBackend = .live
    ) throws {
        try backend.saveVault(password, account(targetID: targetID))
        try deleteLegacyCredentials(
            targetID: targetID,
            legacyVaultAccounts: legacyVaultAccounts,
            backend: backend
        )
    }

    static func readPassword(
        targetID: UUID,
        backend: RDPPasswordStoreBackend = .live
    ) throws -> String? {
        try backend.readVault(account(targetID: targetID))
    }

    static func readOrMigratePassword(
        targetID: UUID,
        legacyVaultAccounts: [RDPLegacyVaultAccount],
        backend: RDPPasswordStoreBackend = .live
    ) throws -> String? {
        let currentAccount = account(targetID: targetID)
        if let password = try backend.readVault(currentAccount) {
            try deleteLegacyCredentials(
                targetID: targetID,
                legacyVaultAccounts: legacyVaultAccounts,
                backend: backend
            )
            return password
        }

        if let password = try backend.readLegacyKeychain(targetID) {
            try backend.saveVault(password, currentAccount)
            try deleteLegacyCredentials(
                targetID: targetID,
                legacyVaultAccounts: legacyVaultAccounts,
                backend: backend
            )
            return password
        }

        for legacyAccount in normalizedLegacyAccounts(
            legacyVaultAccounts,
            excluding: currentAccount
        ) {
            guard let password = try backend.readVault(legacyAccount.account) else { continue }
            try backend.saveVault(password, currentAccount)
            try deleteLegacyCredentials(
                targetID: targetID,
                legacyVaultAccounts: legacyVaultAccounts,
                backend: backend
            )
            return password
        }
        return nil
    }

    static func deletePassword(
        targetID: UUID,
        legacyVaultAccounts: [RDPLegacyVaultAccount] = [],
        backend: RDPPasswordStoreBackend = .live
    ) throws {
        try backend.deleteVault(account(targetID: targetID))
        try deleteLegacyCredentials(
            targetID: targetID,
            legacyVaultAccounts: legacyVaultAccounts,
            backend: backend
        )
    }

    private static func deleteLegacyCredentials(
        targetID: UUID,
        legacyVaultAccounts: [RDPLegacyVaultAccount],
        backend: RDPPasswordStoreBackend
    ) throws {
        try backend.deleteLegacyKeychain(targetID)
        let currentAccount = account(targetID: targetID)
        for legacyAccount in normalizedLegacyAccounts(
            legacyVaultAccounts,
            excluding: currentAccount
        ) where legacyAccount.deleteAfterMigration {
            try backend.deleteVault(legacyAccount.account)
        }
    }

    private static func normalizedLegacyAccounts(
        _ accounts: [RDPLegacyVaultAccount],
        excluding currentAccount: String
    ) -> [RDPLegacyVaultAccount] {
        var seen = Set<String>()
        return accounts.compactMap { legacy in
            let account = legacy.account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty,
                  account != currentAccount,
                  seen.insert(account).inserted else {
                return nil
            }
            return RDPLegacyVaultAccount(
                account: account,
                deleteAfterMigration: legacy.deleteAfterMigration
            )
        }
    }
}

/// Serializes password-vault work away from the main actor. Vault operations
/// can enter Keychain while loading their master key, and legacy migration can
/// display a macOS authorization prompt. Neither may stall the app event loop.
///
/// Only value types cross this boundary. SwiftData models must be reduced to a
/// target ID and legacy account strings by their owning actor before calling.
nonisolated final class RDPPasswordAccess: @unchecked Sendable {
    static let shared = RDPPasswordAccess()

    private let queue: DispatchQueue
    private let backend: RDPPasswordStoreBackend

    init(
        queueLabel: String = "com.lljts.JTSTerminal.rdp-password-access",
        backend: RDPPasswordStoreBackend = .live
    ) {
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.backend = backend
    }

    func savePassword(
        _ password: String,
        targetID: UUID,
        legacyVaultAccounts: [RDPLegacyVaultAccount] = []
    ) async throws {
        let backend = backend
        try await perform {
            try RDPPasswordStore.savePassword(
                password,
                targetID: targetID,
                legacyVaultAccounts: legacyVaultAccounts,
                backend: backend
            )
        }
    }

    func readPassword(targetID: UUID) async throws -> String? {
        let backend = backend
        return try await perform {
            try RDPPasswordStore.readPassword(targetID: targetID, backend: backend)
        }
    }

    func readOrMigratePassword(
        targetID: UUID,
        legacyVaultAccounts: [RDPLegacyVaultAccount]
    ) async throws -> String? {
        let backend = backend
        return try await perform {
            try RDPPasswordStore.readOrMigratePassword(
                targetID: targetID,
                legacyVaultAccounts: legacyVaultAccounts,
                backend: backend
            )
        }
    }

    func deletePassword(
        targetID: UUID,
        legacyVaultAccounts: [RDPLegacyVaultAccount] = []
    ) async throws {
        let backend = backend
        try await perform {
            try RDPPasswordStore.deletePassword(
                targetID: targetID,
                legacyVaultAccounts: legacyVaultAccounts,
                backend: backend
            )
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
