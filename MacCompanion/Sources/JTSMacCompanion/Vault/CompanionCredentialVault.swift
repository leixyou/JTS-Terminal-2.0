import CryptoKit
import Darwin
import Foundation
import Security

// Adapted from this checkout's EncryptedCredentialVault. Host credentials use
// a separate database and master-key account; the main app vault is untouched.
final class CompanionCredentialVault: @unchecked Sendable {
    private static let algorithm = "AES-256-GCM+RSA-OAEP-SHA256"
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let databaseURL: URL
    private let masterKeys: any CompanionVaultMasterKeyStorage
    private let masterKeyLock = NSLock()
    private var cachedPrivateKey: SecKey?

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default,
         masterKeys: (any CompanionVaultMasterKeyStorage)? = nil, allowAuthenticationUI: Bool = false) {
        self.fileManager = fileManager
        let rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.rootDirectory = rootDirectory
        self.databaseURL = rootDirectory.appendingPathComponent("credentials.sqlite")
        let account = SHA256.hash(data: Data(rootDirectory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.masterKeys = masterKeys ?? CompanionKeychainMasterKeys(account: account, allowAuthenticationUI: allowAuthenticationUI)
    }

    /// Creates a durable record without replacing an existing identity or secret.
    /// A failed write never deletes its master key: the same key must survive an
    /// ambiguous commit and any later retry.
    func create(secret: String, account: String) throws {
        try write(secret: secret, account: account, createOnly: true)
    }

    func save(secret: String, account: String) throws {
        try write(secret: secret, account: account, createOnly: false)
    }

    /// Compare-and-swap an existing encrypted record. Neither a missing record
    /// nor a failed comparison may initialize a key or create a new record.
    func replace(secret: String, account: String, expectedSecret: String) throws {
        try prepareStorageDirectory()
        try protectCredentialFiles()
        let database = try CompanionSQLiteDatabase(url: databaseURL)
        try protectCredentialFiles()
        try database.withWriteTransaction {
            guard let existing = try database.fetch(account: account) else {
                throw CompanionVaultError.recordChanged
            }
            let privateKey = try loadOrCreatePrivateKey(allowCreation: false)
            let currentSecret = try decryptedSecret(existing, privateKey: privateKey)
            guard currentSecret.utf8.elementsEqual(expectedSecret.utf8) else {
                throw CompanionVaultError.recordChanged
            }
            let replacement = try encryptedRecord(secret: secret, account: account, privateKey: privateKey)
            try database.write(replacement, createOnly: false)
            try protectCredentialFiles()
        }
        try protectCredentialFiles()
    }

    private func write(secret: String, account: String, createOnly: Bool) throws {
        try prepareStorageDirectory()
        try protectCredentialFiles()
        let database = try CompanionSQLiteDatabase(url: databaseURL)
        try protectCredentialFiles()
        // Serialize key initialization and the row write across vault instances
        // and processes, not only across calls sharing this object's key cache.
        try database.withWriteTransaction {
            if createOnly, try database.fetch(account: account) != nil {
                throw CompanionVaultError.accountAlreadyExists
            }
            let privateKey = try loadOrCreatePrivateKey(
                allowCreation: !database.containsRecords()
            )
            let record = try encryptedRecord(secret: secret, account: account, privateKey: privateKey)
            try database.write(record, createOnly: createOnly)
            try protectCredentialFiles()
        }
        try protectCredentialFiles()
    }

    private func encryptedRecord(
        secret: String,
        account: String,
        privateKey: SecKey
    ) throws -> CompanionEncryptedRecord {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CompanionVaultError.crypto("Unable to derive RSA public key from local vault key.")
        }

        let secretData = Data(secret.utf8)
        let dataKey = SymmetricKey(size: .bits256)
        let dataKeyBytes = dataKey.withUnsafeBytes { Data($0) }
        let sealedBox = try AES.GCM.seal(secretData, using: dataKey)
        let wrappedKey = try rsaEncrypt(dataKeyBytes, publicKey: publicKey)
        let now = ISO8601DateFormatter().string(from: Date())

        return CompanionEncryptedRecord(
            account: account,
            wrappedKey: wrappedKey,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag,
            algorithm: Self.algorithm,
            createdAt: now,
            updatedAt: now
        )
    }

    func read(account: String) throws -> String? {
        try prepareStorageDirectory()
        try protectCredentialFiles()
        let database = try CompanionSQLiteDatabase(url: databaseURL)
        try protectCredentialFiles()
        guard let record = try database.fetch(account: account) else {
            try protectCredentialFiles()
            return nil
        }
        try protectCredentialFiles()
        return try decryptedSecret(record, privateKey: loadPrivateKey())
    }

    private func decryptedSecret(_ record: CompanionEncryptedRecord, privateKey: SecKey) throws -> String {
        guard record.algorithm == Self.algorithm else {
            throw CompanionVaultError.crypto("Unsupported credential envelope: \(record.algorithm).")
        }

        let dataKeyBytes = try rsaDecrypt(record.wrappedKey, privateKey: privateKey)
        let dataKey = SymmetricKey(data: dataKeyBytes)
        let nonce = try AES.GCM.Nonce(data: record.nonce)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: record.ciphertext,
            tag: record.tag
        )
        let plaintext = try AES.GCM.open(sealedBox, using: dataKey)
        guard let secret = String(data: plaintext, encoding: .utf8) else {
            throw CompanionVaultError.crypto("Credential plaintext is not valid UTF-8.")
        }
        return secret
    }

    func delete(account: String) throws {
        try prepareStorageDirectory()
        try protectCredentialFiles()
        let database = try CompanionSQLiteDatabase(url: databaseURL)
        try protectCredentialFiles()
        try database.delete(account: account)
        try protectCredentialFiles()
    }

    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("JTS Mac Companion", isDirectory: true)
            .appendingPathComponent("CredentialVault", isDirectory: true)
    }

    private func prepareStorageDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(
            rootDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw CompanionVaultError.boundary(
                "Credential vault directory could not be opened without following links."
            )
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid() else {
            throw CompanionVaultError.boundary(
                "Credential vault directory ownership or file type is invalid."
            )
        }
        guard Darwin.fchmod(descriptor, 0o700) == 0,
              Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & 0o777 == 0o700 else {
            throw CompanionVaultError.boundary(
                "Credential vault directory permissions could not be secured."
            )
        }
    }

    private func protectCredentialFiles() throws {
        let urls = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]

        for url in urls {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                guard errno == ENOENT else {
                    throw CompanionVaultError.boundary(
                        "Credential vault file could not be opened safely."
                    )
                }
                continue
            }
            defer { Darwin.close(descriptor) }

            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == getuid(),
                  metadata.st_nlink == 1 else {
                throw CompanionVaultError.boundary(
                    "Credential vault files must be owner-owned regular files with exactly one hard link."
                )
            }
            guard Darwin.fchmod(descriptor, 0o600) == 0,
                  Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & 0o777 == 0o600 else {
                throw CompanionVaultError.boundary(
                    "Credential vault file permissions could not be secured."
                )
            }
        }
    }

    private func loadOrCreatePrivateKey(allowCreation: Bool) throws -> SecKey {
        masterKeyLock.lock()
        defer { masterKeyLock.unlock() }

        // A cached key is enough to decrypt, but never proof that a new write
        // will remain readable after restart. Recheck durable storage each time.
        cachedPrivateKey = nil
        let privateKey = try loadOrCreatePrivateKeyUncached(allowCreation: allowCreation)
        cachedPrivateKey = privateKey
        return privateKey
    }

    private func loadOrCreatePrivateKeyUncached(allowCreation: Bool) throws -> SecKey {
        if let keyData = try readMasterKeyFromKeychain() {
            return try privateKey(from: keyData)
        }

        guard allowCreation else {
            throw CompanionVaultError.crypto("Local credential vault master key is missing from Keychain.")
        }

        var cfError: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 3072,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &cfError) else {
            throw CompanionVaultError.crypto(Self.errorDescription(cfError))
        }

        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &cfError) as Data? else {
            throw CompanionVaultError.crypto(Self.errorDescription(cfError))
        }

        // Never replace a key installed by another writer or a recovery action.
        try insertMasterKeyToKeychain(privateKeyData)
        return privateKey
    }

    private func loadPrivateKey() throws -> SecKey {
        masterKeyLock.lock()
        defer { masterKeyLock.unlock() }

        if let cachedPrivateKey {
            return cachedPrivateKey
        }

        let privateKey = try loadPrivateKeyUncached()
        cachedPrivateKey = privateKey
        return privateKey
    }

    private func loadPrivateKeyUncached() throws -> SecKey {
        if let keyData = try readMasterKeyFromKeychain() {
            return try privateKey(from: keyData)
        }

        throw CompanionVaultError.crypto("Local credential vault master key is missing from Keychain.")
    }

    private func privateKey(from data: Data) throws -> SecKey {
        var cfError: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 3072
        ]

        guard let privateKey = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &cfError) else {
            throw CompanionVaultError.crypto(Self.errorDescription(cfError))
        }
        return privateKey
    }

    private func readMasterKeyFromKeychain() throws -> Data? { try masterKeys.read() }
    private func insertMasterKeyToKeychain(_ data: Data) throws { try masterKeys.insert(data) }

    private func rsaEncrypt(_ data: Data, publicKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw CompanionVaultError.crypto("RSA-OAEP-SHA256 encryption is not supported by this key.")
        }

        var cfError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(publicKey, algorithm, data as CFData, &cfError) as Data? else {
            throw CompanionVaultError.crypto(Self.errorDescription(cfError))
        }
        return encrypted
    }

    private func rsaDecrypt(_ data: Data, privateKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw CompanionVaultError.crypto("RSA-OAEP-SHA256 decryption is not supported by this key.")
        }

        var cfError: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(privateKey, algorithm, data as CFData, &cfError) as Data? else {
            throw CompanionVaultError.crypto(Self.errorDescription(cfError))
        }
        return decrypted
    }

    private static func errorDescription(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else {
            return "Unknown Security framework error."
        }
        return CFErrorCopyDescription(error) as String
    }
}

