//
//  CredentialStore.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import SQLite3

nonisolated struct SSHConnectionIdentity: Equatable, Sendable {
    let username: String
    let host: String

    init(username: String, host: String) {
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var destination: String {
        "\(username)@\(host)"
    }

    var isValidForSSHCommand: Bool {
        Self.isValidSSHOperandComponent(username)
            && Self.isValidSSHOperandComponent(host)
    }

    func credentialAccount(port: Int) -> String {
        "\(destination):\(port)"
    }

    private static func isValidSSHOperandComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              !value.contains("@") else {
            return false
        }

        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}

nonisolated enum CredentialStore {
    private static let vault = EncryptedCredentialVault()

    static func create(secret: String, account: String) throws {
        try vault.create(secret: secret, account: account)
    }

    static func replace(secret: String, account: String, expectedSecret: String) throws {
        try vault.replace(secret: secret, account: account, expectedSecret: expectedSecret)
    }

    static func save(secret: String, account: String) throws {
        try vault.save(secret: secret, account: account)
    }

    static func read(account: String) throws -> String? {
        try vault.read(account: account)
    }

    static func delete(account: String) throws {
        try vault.delete(account: account)
    }

    static func account(username: String, host: String, port: Int) -> String {
        SSHConnectionIdentity(username: username, host: host)
            .credentialAccount(port: port)
    }

    static func account(for session: RemoteSession) -> String {
        account(username: session.username, host: session.host, port: session.port)
    }
}

/// The single persistence boundary for SSH-family credentials.
///
/// Production calls are forwarded to the encrypted vault. Structural import
/// UI tests are instead routed to a process-local store so no SSH, SFTP, SCP,
/// tunnel, or credential-panel path can touch the installed app's vault.
nonisolated enum SSHCredentialVaultAccess {
    static func save(
        secret: String,
        account: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        #if JTS_UI_TEST_SUPPORT
        if UITestSSHSessionEnvironment.isolatesCredentialVault(
            account: account,
            environment: environment
        ) {
            UITestSSHCredentialStore.shared.save(secret: secret, account: account)
            return
        }
        #endif
        try CredentialStore.save(secret: secret, account: account)
    }

    static func read(
        account: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String? {
        #if JTS_UI_TEST_SUPPORT
        if UITestSSHSessionEnvironment.isolatesCredentialVault(
            account: account,
            environment: environment
        ) {
            return UITestSSHCredentialStore.shared.read(account: account)
        }
        #endif
        return try CredentialStore.read(account: account)
    }

    static func delete(
        account: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        #if JTS_UI_TEST_SUPPORT
        if UITestSSHSessionEnvironment.isolatesCredentialVault(
            account: account,
            environment: environment
        ) {
            UITestSSHCredentialStore.shared.delete(account: account)
            return
        }
        #endif
        try CredentialStore.delete(account: account)
    }
}

nonisolated final class EncryptedCredentialVault: @unchecked Sendable {
    private static let algorithm = "AES-256-GCM+RSA-OAEP-SHA256"
    private static let keychainService = "com.lljts.JTSTerminal.vault-master-key.v3"
    private static let legacyKeychainServices = [
        "com.lljts.JTSTerminal.vault-master-key.v2",
    ]
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let databaseURL: URL
    private let privateKeyURL: URL
    private let keychainAccount: String
    private let masterKeyLock = NSLock()
    private var cachedPrivateKey: SecKey?

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.rootDirectory = rootDirectory
        self.databaseURL = rootDirectory.appendingPathComponent("credentials.sqlite")
        self.privateKeyURL = rootDirectory.appendingPathComponent("vault-rsa-private.der")
        self.keychainAccount = SHA256.hash(data: Data(rootDirectory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
        let database = try SQLiteCredentialDatabase(url: databaseURL)
        try protectCredentialFiles()
        try database.withWriteTransaction {
            guard let existing = try database.fetch(account: account) else {
                throw CredentialStoreError.recordChanged
            }
            let privateKey = try loadOrCreatePrivateKey(allowCreation: false)
            let currentSecret = try decryptedSecret(existing, privateKey: privateKey)
            guard currentSecret.utf8.elementsEqual(expectedSecret.utf8) else {
                throw CredentialStoreError.recordChanged
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
        let database = try SQLiteCredentialDatabase(url: databaseURL)
        try protectCredentialFiles()
        // Serialize key initialization and the row write across vault instances
        // and processes, not only across calls sharing this object's key cache.
        try database.withWriteTransaction {
            if createOnly, try database.fetch(account: account) != nil {
                throw CredentialStoreError.accountAlreadyExists
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
    ) throws -> EncryptedCredentialRecord {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CredentialStoreError.crypto("Unable to derive RSA public key from local vault key.")
        }

        let secretData = Data(secret.utf8)
        let dataKey = SymmetricKey(size: .bits256)
        let dataKeyBytes = dataKey.withUnsafeBytes { Data($0) }
        let sealedBox = try AES.GCM.seal(secretData, using: dataKey)
        let wrappedKey = try rsaEncrypt(dataKeyBytes, publicKey: publicKey)
        let now = ISO8601DateFormatter().string(from: Date())

        return EncryptedCredentialRecord(
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
        let database = try SQLiteCredentialDatabase(url: databaseURL)
        try protectCredentialFiles()
        guard let record = try database.fetch(account: account) else {
            try protectCredentialFiles()
            return nil
        }
        try protectCredentialFiles()
        return try decryptedSecret(record, privateKey: loadPrivateKey())
    }

    private func decryptedSecret(_ record: EncryptedCredentialRecord, privateKey: SecKey) throws -> String {
        guard record.algorithm == Self.algorithm else {
            throw CredentialStoreError.crypto("Unsupported credential envelope: \(record.algorithm).")
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
            throw CredentialStoreError.crypto("Credential plaintext is not valid UTF-8.")
        }
        return secret
    }

    func delete(account: String) throws {
        try prepareStorageDirectory()
        try protectCredentialFiles()
        let database = try SQLiteCredentialDatabase(url: databaseURL)
        try protectCredentialFiles()
        try database.delete(account: account)
        try protectCredentialFiles()
    }

    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("JTS Terminal", isDirectory: true)
            .appendingPathComponent("CredentialVault", isDirectory: true)
    }

    private func prepareStorageDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(
            rootDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw CredentialStoreError.boundary(
                "Credential vault directory could not be opened without following links."
            )
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid() else {
            throw CredentialStoreError.boundary(
                "Credential vault directory ownership or file type is invalid."
            )
        }
        guard Darwin.fchmod(descriptor, 0o700) == 0,
              Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & 0o777 == 0o700 else {
            throw CredentialStoreError.boundary(
                "Credential vault directory permissions could not be secured."
            )
        }
    }

    private func protectCredentialFiles() throws {
        let urls = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            privateKeyURL
        ]

        for url in urls {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                guard errno == ENOENT else {
                    throw CredentialStoreError.boundary(
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
                throw CredentialStoreError.boundary(
                    "Credential vault files must be owner-owned regular files with exactly one hard link."
                )
            }
            guard Darwin.fchmod(descriptor, 0o600) == 0,
                  Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & 0o777 == 0o600 else {
                throw CredentialStoreError.boundary(
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

        // One-time migration from the 1.x file-backed vault key. Store the key
        // in Keychain before removing the legacy file so a failed migration can
        // never orphan existing encrypted credential records.
        if fileManager.fileExists(atPath: privateKeyURL.path) {
            return try migrateLegacyFilePrivateKey()
        }

        guard allowCreation else {
            throw CredentialStoreError.crypto("Local credential vault master key is missing from Keychain.")
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
            throw CredentialStoreError.crypto(Self.errorDescription(cfError))
        }

        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &cfError) as Data? else {
            throw CredentialStoreError.crypto(Self.errorDescription(cfError))
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

        // Reading an existing record may be the first operation after upgrade.
        // Reuse the same crash-safe legacy migration as key creation.
        if fileManager.fileExists(atPath: privateKeyURL.path) {
            return try migrateLegacyFilePrivateKey()
        }
        throw CredentialStoreError.crypto("Local credential vault master key is missing from Keychain.")
    }

    private func migrateLegacyFilePrivateKey() throws -> SecKey {
        let keyData = try Data(contentsOf: privateKeyURL)
        let privateKey = try privateKey(from: keyData)
        try saveMasterKeyToKeychain(keyData)
        try fileManager.removeItem(at: privateKeyURL)
        return privateKey
    }

    private func privateKey(from data: Data) throws -> SecKey {
        var cfError: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 3072
        ]

        guard let privateKey = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &cfError) else {
            throw CredentialStoreError.crypto(Self.errorDescription(cfError))
        }
        return privateKey
    }

    private func readMasterKeyFromKeychain() throws -> Data? {
        if let keyData = try readMasterKeyFromKeychain(service: Self.keychainService) {
            return keyData
        }

        // Builds before stable code signing stored the vault key under a
        // file-keychain ACL tied to a changing ad-hoc cdhash. Read that item at
        // most once, then recreate it under the stable application identity.
        // A user who chooses a one-time Allow action therefore does not see the
        // same prompt again on the next launch.
        for legacyService in Self.legacyKeychainServices {
            guard let keyData = try readMasterKeyFromKeychain(service: legacyService) else {
                continue
            }
            try saveMasterKeyToKeychain(keyData)
            deleteLegacyMasterKeyWithoutPrompt(service: legacyService)
            return keyData
        }
        return nil
    }

    private func readMasterKeyFromKeychain(service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialStoreError.crypto("Keychain read failed (OSStatus \(status)).")
        }
        return data
    }

    private func deleteLegacyMasterKeyWithoutPrompt(service: String) {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecUseAuthenticationContext as String: context,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private func saveMasterKeyToKeychain(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
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
            throw CredentialStoreError.crypto("Keychain update failed (OSStatus \(updateStatus)).")
        }
        try insertMasterKeyToKeychain(data)
    }

    private func insertMasterKeyToKeychain(_ data: Data) throws {
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.crypto("Keychain insert failed (OSStatus \(addStatus)).")
        }
    }

    private func rsaEncrypt(_ data: Data, publicKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw CredentialStoreError.crypto("RSA-OAEP-SHA256 encryption is not supported by this key.")
        }

        var cfError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(publicKey, algorithm, data as CFData, &cfError) as Data? else {
            throw CredentialStoreError.crypto(Self.errorDescription(cfError))
        }
        return encrypted
    }

    private func rsaDecrypt(_ data: Data, privateKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw CredentialStoreError.crypto("RSA-OAEP-SHA256 decryption is not supported by this key.")
        }

        var cfError: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(privateKey, algorithm, data as CFData, &cfError) as Data? else {
            throw CredentialStoreError.crypto(Self.errorDescription(cfError))
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

nonisolated struct EncryptedCredentialRecord {
    var account: String
    var wrappedKey: Data
    var nonce: Data
    var ciphertext: Data
    var tag: Data
    var algorithm: String
    var createdAt: String
    var updatedAt: String
}

nonisolated enum CredentialStoreError: LocalizedError, Equatable {
    case accountAlreadyExists
    case recordChanged
    case database(String)
    case crypto(String)
    case boundary(String)

    var errorDescription: String? {
        switch self {
        case .accountAlreadyExists:
            return "A credential record already exists. It was not replaced."
        case .recordChanged:
            return "The credential record changed or is missing. It was not replaced."
        case .database(let message):
            return "Credential database error: \(message)"
        case .crypto(let message):
            return "Credential vault encryption error: \(message)"
        case .boundary(let message):
            return "Credential vault security boundary error: \(message)"
        }
    }
}

nonisolated private final class SQLiteCredentialDatabase {
    private static let lockWaitMilliseconds: Int32 = 5_000
    private let handle: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            if let database {
                sqlite3_close(database)
            }
            throw CredentialStoreError.database(message)
        }

        self.handle = database
        // FULLMUTEX protects this connection, not the independent connections
        // used by RDP, Companion persistence, and other vault instances.
        guard sqlite3_busy_timeout(database, Self.lockWaitMilliseconds) == SQLITE_OK else {
            throw CredentialStoreError.database("Unable to configure the credential database lock wait.")
        }
        try executeSchema()
    }

    deinit {
        sqlite3_close(handle)
    }

    func withWriteTransaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try operation()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func containsRecords() throws -> Bool {
        let statement = try prepare("SELECT 1 FROM credentials LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw CredentialStoreError.database(lastErrorMessage)
        }
        return result == SQLITE_ROW
    }

    func write(_ record: EncryptedCredentialRecord, createOnly: Bool) throws {
        var sql = """
        INSERT INTO credentials (
            account, wrapped_key, nonce, ciphertext, tag, algorithm, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        if !createOnly {
            sql += """

        ON CONFLICT(account) DO UPDATE SET
            wrapped_key = excluded.wrapped_key,
            nonce = excluded.nonce,
            ciphertext = excluded.ciphertext,
            tag = excluded.tag,
            algorithm = excluded.algorithm,
            updated_at = excluded.updated_at;
        """
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(record.account, at: 1, in: statement)
        try bind(record.wrappedKey, at: 2, in: statement)
        try bind(record.nonce, at: 3, in: statement)
        try bind(record.ciphertext, at: 4, in: statement)
        try bind(record.tag, at: 5, in: statement)
        try bind(record.algorithm, at: 6, in: statement)
        try bind(record.createdAt, at: 7, in: statement)
        try bind(record.updatedAt, at: 8, in: statement)
        try stepDone(statement)
    }

    func fetch(account: String) throws -> EncryptedCredentialRecord? {
        let sql = """
        SELECT account, wrapped_key, nonce, ciphertext, tag, algorithm, created_at, updated_at
        FROM credentials
        WHERE account = ?
        LIMIT 1;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(account, at: 1, in: statement)
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE {
            return nil
        }
        guard stepResult == SQLITE_ROW else {
            throw CredentialStoreError.database(lastErrorMessage)
        }

        return EncryptedCredentialRecord(
            account: stringColumn(0, in: statement),
            wrappedKey: dataColumn(1, in: statement),
            nonce: dataColumn(2, in: statement),
            ciphertext: dataColumn(3, in: statement),
            tag: dataColumn(4, in: statement),
            algorithm: stringColumn(5, in: statement),
            createdAt: stringColumn(6, in: statement),
            updatedAt: stringColumn(7, in: statement)
        )
    }

    func delete(account: String) throws {
        let statement = try prepare("DELETE FROM credentials WHERE account = ?;")
        defer { sqlite3_finalize(statement) }

        try bind(account, at: 1, in: statement)
        try stepDone(statement)
    }

    private func executeSchema() throws {
        try configureJournalMode()
        try execute("PRAGMA synchronous=FULL;")
        try execute("PRAGMA fullfsync=ON;")
        try execute("PRAGMA foreign_keys=ON;")
        // Opening an initialized vault for a read must not acquire a writer
        // lock by updating an unchanged schema-version row.
        if try schemaIsInitialized() { return }
        try withWriteTransaction {
            // Another process may have initialized the empty database while
            // this connection waited for the writer lock.
            if try schemaIsInitialized() { return }
            try execute("""
            CREATE TABLE credentials (
                account TEXT PRIMARY KEY NOT NULL,
                wrapped_key BLOB NOT NULL,
                nonce BLOB NOT NULL,
                ciphertext BLOB NOT NULL,
                tag BLOB NOT NULL,
                algorithm TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            INSERT INTO metadata (key, value) VALUES ('schema_version', '1');
            """)
            guard try schemaIsInitialized() else {
                throw CredentialStoreError.database("Credential database initialization did not complete.")
            }
        }
    }

    private func configureJournalMode() throws {
        // Changing a fresh rollback-journal database to WAL can require a lock
        // upgrade for which SQLite skips its busy handler. Finalize each probe
        // before retrying so competing initializers can finish that transition.
        let deadline = ProcessInfo.processInfo.systemUptime + Double(Self.lockWaitMilliseconds) / 1_000
        defer { sqlite3_busy_timeout(handle, Self.lockWaitMilliseconds) }
        var failure = "Credential database journal initialization remained busy."
        while true {
            let remaining = Int32(max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
            guard remaining > 0 else { throw CredentialStoreError.database(failure) }
            sqlite3_busy_timeout(handle, remaining)
            var result = journalModeResult("PRAGMA journal_mode;")
            if result.code == SQLITE_ROW, result.mode == "wal" { return }
            if result.code == SQLITE_ROW {
                let transitionWait = Int32(max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
                guard transitionWait > 0 else { throw CredentialStoreError.database(failure) }
                sqlite3_busy_timeout(handle, transitionWait)
                result = journalModeResult("PRAGMA journal_mode=WAL;")
            }
            if result.code == SQLITE_ROW, result.mode == "wal" { return }
            failure = result.code == SQLITE_ROW
                ? "Credential database could not enable WAL journaling." : result.message
            let primaryCode = result.code & 0xff
            guard primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED else {
                throw CredentialStoreError.database(failure)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CredentialStoreError.database(failure)
            }
            sqlite3_sleep(10)
        }
    }

    private func journalModeResult(_ sql: String) -> (code: Int32, mode: String?, message: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { return (prepared, nil, lastErrorMessage) }
        let result = sqlite3_step(statement)
        return (result, result == SQLITE_ROW ? stringColumn(0, in: statement) : nil, lastErrorMessage)
    }

    /// Only an empty database may be initialized. Partial or unsupported schema
    /// is never repaired by overwriting its version or recreating missing tables.
    private func schemaIsInitialized() throws -> Bool {
        let objects = try prepare("SELECT name, type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        var names = Set<String>()
        var hasObjects = false
        do {
            defer { sqlite3_finalize(objects) }
            var result = sqlite3_step(objects)
            while result == SQLITE_ROW {
                hasObjects = true
                let name = stringColumn(0, in: objects)
                if name == "credentials" || name == "metadata" {
                    guard stringColumn(1, in: objects) == "table" else { throw invalidSchema }
                    names.insert(name)
                }
                result = sqlite3_step(objects)
            }
            guard result == SQLITE_DONE else { throw CredentialStoreError.database(lastErrorMessage) }
        }
        if !hasObjects { return false }
        guard names == ["credentials", "metadata"] else { throw invalidSchema }
        try validateColumns("credentials", expected: [
            ("account", "TEXT", 1), ("wrapped_key", "BLOB", 0), ("nonce", "BLOB", 0),
            ("ciphertext", "BLOB", 0), ("tag", "BLOB", 0), ("algorithm", "TEXT", 0),
            ("created_at", "TEXT", 0), ("updated_at", "TEXT", 0),
        ])
        try validateColumns("metadata", expected: [("key", "TEXT", 1), ("value", "TEXT", 0)])
        let version = try prepare("SELECT value FROM metadata WHERE key = 'schema_version';")
        defer { sqlite3_finalize(version) }
        let result = sqlite3_step(version)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { throw invalidSchema }
            throw CredentialStoreError.database(lastErrorMessage)
        }
        guard stringColumn(0, in: version) == "1", sqlite3_step(version) == SQLITE_DONE else { throw invalidSchema }
        return true
    }

    private func validateColumns(_ table: String, expected: [(String, String, Int32)]) throws {
        // table is one of the two fixed internal names above, never caller input.
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var index = 0
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard index < expected.count,
                  stringColumn(1, in: statement) == expected[index].0,
                  stringColumn(2, in: statement).uppercased() == expected[index].1,
                  sqlite3_column_int(statement, 3) == 1,
                  sqlite3_column_int(statement, 5) == expected[index].2 else { throw invalidSchema }
            index += 1
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw CredentialStoreError.database(lastErrorMessage) }
        guard index == expected.count else { throw invalidSchema }
    }

    private var invalidSchema: CredentialStoreError { .database("Credential database schema is incomplete or unsupported.") }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw CredentialStoreError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CredentialStoreError.database(lastErrorMessage)
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw CredentialStoreError.database(lastErrorMessage)
        }
    }

    private func bind(_ value: Data, at index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw CredentialStoreError.database(lastErrorMessage)
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CredentialStoreError.database(lastErrorMessage)
        }
    }

    private func stringColumn(_ index: Int32, in statement: OpaquePointer?) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func dataColumn(_ index: Int32, in statement: OpaquePointer?) -> Data {
        let byteCount = sqlite3_column_bytes(statement, index)
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: Int(byteCount))
    }

    private var lastErrorMessage: String {
        guard let handle, let message = sqlite3_errmsg(handle) else {
            return "Unknown SQLite error."
        }
        return String(cString: message)
    }
}
