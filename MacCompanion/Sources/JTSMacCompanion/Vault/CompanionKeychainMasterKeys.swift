import Foundation
import LocalAuthentication
import Security

protocol CompanionVaultMasterKeyStorage: Sendable {
    func read() throws -> Data?
    func insert(_ key: Data) throws
}

/// Only the wrapping master key is stored in Keychain. Identity, PSKs, private
/// relay keys, grants and enrollment attempts are encrypted SQLite records.
struct CompanionKeychainMasterKeys: CompanionVaultMasterKeyStorage {
    let account: String
    let allowAuthenticationUI: Bool
    private let service = "com.jtstools.mac-companion.vault-master-key.v1"

    func read() throws -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowAuthenticationUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let key = item as? Data else {
            throw CompanionVaultError.crypto("无法读取保险库主密钥（\(status)）；请在窗口中重新读取设备身份。")
        }
        return key
    }

    func insert(_ key: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: key, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CompanionVaultError.crypto("无法创建保险库主密钥（\(status)）；原有密钥未被替换。")
        }
    }
}
