#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices

/// The new identity/trust document never enters SwiftData, RDP profiles or UserDefaults.
actor CompanionVaultPersistence: CompanionDevicePersistence {
    private let account: String
    private let testVault: EncryptedCredentialVault?

    init(account: String = "jts.companion.devices.v1.authority", testVault: EncryptedCredentialVault? = nil) {
        self.account = account; self.testVault = testVault
    }

    func load() throws -> String? {
        do {
            if let testVault { return try testVault.read(account: account) }
            return try CredentialStore.read(account: account)
        } catch { throw CompanionDevicePersistenceError.unavailable }
    }

    func create(_ value: String) throws {
        do {
            if let testVault { try testVault.create(secret: value, account: account) }
            else { try CredentialStore.create(secret: value, account: account) }
        } catch CredentialStoreError.accountAlreadyExists {
            throw CompanionDevicePersistenceError.alreadyExists
        } catch { throw CompanionDevicePersistenceError.unavailable }
    }

    func replace(expected: String, with value: String) throws {
        do {
            if let testVault { try testVault.replace(secret: value, account: account, expectedSecret: expected) }
            else { try CredentialStore.replace(secret: value, account: account, expectedSecret: expected) }
        } catch CredentialStoreError.recordChanged {
            throw CompanionDevicePersistenceError.conflict
        } catch { throw CompanionDevicePersistenceError.unavailable }
    }
}
#endif
