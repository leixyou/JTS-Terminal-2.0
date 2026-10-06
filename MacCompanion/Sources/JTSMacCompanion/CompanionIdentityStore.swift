import Foundation
import CryptoKit
import LocalAuthentication
import Security

struct AuthorizedDesktopClient: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let credentialHash: Data
    let psk: Data
    let pairedAt: Date
}

struct CompanionIdentity: Codable {
    let serverID: UUID
    var clients: [AuthorizedDesktopClient]

    static func fresh() throws -> Self {
        Self(serverID: UUID(), clients: [])
    }

    static func randomBytes() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CompanionStoreError.status(status) }
        return Data(bytes)
    }

    static func newCredential() throws -> String {
        try randomBytes().base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ credential: String) -> Data { Data(SHA256.hash(data: Data(credential.utf8))) }

    func validate() throws {
        guard clients.count <= 64, Set(clients.map(\.id)).count == clients.count,
              clients.allSatisfy({
                  $0.psk.count == 32 && $0.credentialHash.count == 32 &&
                  !$0.name.isEmpty && $0.name.utf8.count <= 256 &&
                  !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }) else { throw CompanionStoreError.invalidIdentity }
    }

    func authorizedClient(deviceID: UUID, credential: String) -> AuthorizedDesktopClient? {
        guard let client = clients.first(where: { $0.id == deviceID }) else { return nil }
        let candidate = Self.hash(credential)
        guard candidate.count == client.credentialHash.count else { return nil }
        let difference = zip(candidate, client.credentialHash).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        return difference == 0 ? client : nil
    }
}

enum CompanionIdentityStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jtstools.mac-companion.identity",
         kSecAttrAccount as String: "desktop-host"]
    }

    static func load(allowAuthenticationUI: Bool = false) throws -> CompanionIdentity {
        let vault = CompanionCredentialVault(allowAuthenticationUI: allowAuthenticationUI)
        if let secret = try vault.read(account: "desktop-host-identity.v1") {
            let identity = try JSONDecoder().decode(CompanionIdentity.self, from: Data(secret.utf8))
            try identity.validate()
            return identity
        }
        // Keep the legacy item until a separately authorized cleanup. Never
        // replace an unreadable legacy identity with a new device identity.
        let identity = try readLegacy(allowAuthenticationUI: allowAuthenticationUI) ?? CompanionIdentity.fresh()
        try identity.validate()
        try save(identity, vault: vault)
        guard let saved = try vault.read(account: "desktop-host-identity.v1"),
              try JSONDecoder().decode(CompanionIdentity.self, from: Data(saved.utf8)).serverID == identity.serverID else {
            throw CompanionStoreError.invalidIdentity
        }
        return identity
    }

    static func save(_ identity: CompanionIdentity) throws {
        try save(identity, vault: CompanionCredentialVault())
    }

    private static func save(_ identity: CompanionIdentity, vault: CompanionCredentialVault) throws {
        try identity.validate()
        let data = try JSONEncoder().encode(identity)
        try vault.save(secret: String(decoding: data, as: UTF8.self), account: "desktop-host-identity.v1")
    }

    private static func readLegacy(allowAuthenticationUI: Bool) throws -> CompanionIdentity? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowAuthenticationUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            lookup[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CompanionStoreError.status(status) }
        guard let data = result as? Data else { throw CompanionStoreError.invalidIdentity }
        let identity = try JSONDecoder().decode(CompanionIdentity.self, from: data)
        try identity.validate()
        return identity
    }

}

enum CompanionStoreError: LocalizedError {
    case status(OSStatus), invalidIdentity
    var errorDescription: String? {
        switch self {
        case .status(let status): return "钥匙串操作失败（\(status)）。"
        case .invalidIdentity: return "设备身份无效。原有配对未被覆盖；请恢复保险库后重试。"
        }
    }
}
