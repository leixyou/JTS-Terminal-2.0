import CryptoKit
import Foundation
import Security
import SQLite3
import Testing
@testable import JTSTerminal

@Suite("Credential vault create-only and compare-and-swap")
struct CredentialVaultCreateTests {
    @Test("Create survives restart and refuses replacement")
    func createIsEncryptedAndDoesNotOverwrite() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try fixture.vault.create(secret: "private-identity-material", account: "identity")
        let key = try fixture.masterKey()
        #expect(throws: CredentialStoreError.accountAlreadyExists) {
            try fixture.reopened().create(secret: "replacement", account: "identity")
        }
        #expect(try fixture.reopened().read(account: "identity") == "private-identity-material")
        #expect(try fixture.masterKey() == key)
        let bytes = try Data(contentsOf: fixture.databaseURL)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("private-identity-material"))
    }

    @Test("Independent concurrent creators cannot replace the winner")
    func concurrentCreateHasOneWinner() async throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        #expect(try fixture.vault.read(account: "identity") == nil)
        let winners = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for index in 0..<4 {
                group.addTask {
                    let candidate = "candidate-\(index)"
                    do {
                        try fixture.reopened().create(secret: candidate, account: "identity")
                        return candidate
                    } catch { return nil }
                }
            }
            var values: [String] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        #expect(winners.count == 1)
        #expect(try fixture.reopened().read(account: "identity") == winners.first)
    }

    @Test("Missing durable master blocks create, save and CAS despite a cached key")
    func missingMasterNeverRegeneratesOverRecords() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try fixture.vault.create(secret: "original", account: "identity")
        let originalKey = try #require(try fixture.masterKey())
        try fixture.removeMasterKey()
        #expect(throws: CredentialStoreError.self) {
            try fixture.vault.create(secret: "new", account: "another")
        }
        #expect(throws: CredentialStoreError.self) {
            try fixture.vault.save(secret: "replacement", account: "identity")
        }
        #expect(throws: CredentialStoreError.self) {
            try fixture.vault.replace(secret: "replacement", account: "identity", expectedSecret: "original")
        }
        #expect(try fixture.masterKey() == nil)
        #expect(throws: CredentialStoreError.self) { try fixture.reopened().read(account: "identity") }
        try fixture.installMasterKey(originalKey)
        #expect(try fixture.reopened().read(account: "identity") == "original")
        #expect(try fixture.reopened().read(account: "another") == nil)
    }

    @Test("Malformed master is retained and is not replaced")
    func malformedMasterFailsClosed() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try fixture.vault.create(secret: "original", account: "identity")
        try fixture.removeMasterKey()
        let corrupt = Data("not-an-rsa-master-key".utf8)
        try fixture.installMasterKey(corrupt)
        #expect(throws: CredentialStoreError.self) {
            try fixture.vault.create(secret: "new", account: "another")
        }
        #expect(try fixture.masterKey() == corrupt)
    }

    @Test("Unreadable database cannot cause master-key creation")
    func malformedDatabaseDoesNotCreateKey() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let corrupt = Data("not-a-sqlite-database".utf8)
        try corrupt.write(to: fixture.databaseURL)
        #expect(throws: CredentialStoreError.self) {
            try fixture.vault.create(secret: "new", account: "identity")
        }
        #expect(try fixture.masterKey() == nil)
        #expect(try Data(contentsOf: fixture.databaseURL) == corrupt)
    }

    @Test("Failed insert rolls back but preserves the new key for a safe retry")
    func failedInsertRetainsMasterAndRollsBack() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        _ = try fixture.vault.read(account: "identity")
        try fixture.sql("CREATE TRIGGER reject_insert BEFORE INSERT ON credentials BEGIN SELECT RAISE(ABORT, 'test-write-denied'); END;")
        #expect(throws: CredentialStoreError.self) {
            try fixture.vault.create(secret: "original", account: "identity")
        }
        let retainedKey = try #require(try fixture.masterKey())
        #expect(try fixture.reopened().read(account: "identity") == nil)
        try fixture.sql("DROP TRIGGER reject_insert;")
        try fixture.reopened().create(secret: "original", account: "identity")
        #expect(try fixture.masterKey() == retainedKey)
        #expect(try fixture.reopened().read(account: "identity") == "original")
    }

    @Test("Legacy master migration preserves existing records on create")
    func createMigratesExistingLegacyMaster() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try fixture.vault.save(secret: "old", account: "existing")
        let key = try #require(try fixture.masterKey())
        let legacyURL = fixture.directory.appendingPathComponent("vault-rsa-private.der")
        try key.write(to: legacyURL)
        try fixture.removeMasterKey()
        try fixture.reopened().create(secret: "new", account: "identity")
        #expect(try fixture.masterKey() == key)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(try fixture.reopened().read(account: "existing") == "old")
    }

    @Test("Ordinary save remains upsert and delete remains supported")
    func saveAndDeleteCompatibility() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try fixture.vault.save(secret: "first", account: "ssh-account")
        try fixture.vault.save(secret: "updated", account: "ssh-account")
        #expect(try fixture.reopened().read(account: "ssh-account") == "updated")
        try fixture.vault.delete(account: "ssh-account")
        #expect(try fixture.reopened().read(account: "ssh-account") == nil)
    }

    @Test("CAS persists the winner and rejects stale independent writers")
    func replaceRequiresCurrentValue() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try fixture.vault.create(secret: "initial", account: "registry")
        try fixture.reopened().replace(secret: "committed", account: "registry", expectedSecret: "initial")
        #expect(throws: CredentialStoreError.recordChanged) {
            try fixture.vault.replace(secret: "stale", account: "registry", expectedSecret: "initial")
        }
        #expect(try fixture.reopened().read(account: "registry") == "committed")
    }

    @Test("CAS missing account never creates a row or master key")
    func replaceMissingDoesNotCreate() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        #expect(throws: CredentialStoreError.recordChanged) {
            try fixture.vault.replace(secret: "new", account: "registry", expectedSecret: "missing")
        }
        #expect(try fixture.masterKey() == nil)
        #expect(try fixture.reopened().read(account: "registry") == nil)
    }

    @Test("CAS compares exact UTF-8 rather than Unicode-normalized equality")
    func replaceRequiresExactBytes() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try fixture.vault.create(secret: "\u{00e9}", account: "registry")
        #expect(throws: CredentialStoreError.recordChanged) {
            try fixture.vault.replace(secret: "new", account: "registry", expectedSecret: "e\u{0301}")
        }
        #expect(try fixture.reopened().read(account: "registry") == "\u{00e9}")
    }

    @Test("CAS write failure preserves the previously committed registry")
    func replaceFailureRollsBack() throws {
        let fixture = CredentialVaultWriteFixture()
        defer { fixture.cleanup() }
        try fixture.vault.create(secret: "original", account: "registry")
        try fixture.sql("CREATE TRIGGER reject_update BEFORE UPDATE ON credentials BEGIN SELECT RAISE(ABORT, 'test-write-denied'); END;")
        #expect(throws: CredentialStoreError.self) {
            try fixture.vault.replace(secret: "new", account: "registry", expectedSecret: "original")
        }
        #expect(try fixture.reopened().read(account: "registry") == "original")
    }
}

/// Every Keychain operation is scoped to the SHA-256 of a freshly randomized
/// disposable root, never the default vault or any installed application's key.
nonisolated private final class CredentialVaultWriteFixture: @unchecked Sendable {
    let directory: URL
    let vault: EncryptedCredentialVault
    var databaseURL: URL { directory.appendingPathComponent("credentials.sqlite") }
    private var keyQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lljts.JTSTerminal.vault-master-key.v3",
            kSecAttrAccount as String: SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
                .map { String(format: "%02x", $0) }.joined(),
        ]
    }

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-vault-create-\(UUID().uuidString)", isDirectory: true)
        vault = EncryptedCredentialVault(rootDirectory: directory)
    }

    func reopened() -> EncryptedCredentialVault { EncryptedCredentialVault(rootDirectory: directory) }

    func masterKey() throws -> Data? {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw CredentialStoreError.crypto("Disposable test key could not be read.")
        }
        return data
    }

    func removeMasterKey() throws {
        let status = SecItemDelete(keyQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.crypto("Disposable test key could not be removed.")
        }
    }

    func installMasterKey(_ data: Data) throws {
        var query = keyQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw CredentialStoreError.crypto("Disposable test key could not be installed.")
        }
    }

    func sql(_ statement: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw CredentialStoreError.database("Disposable test database could not be opened.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw CredentialStoreError.database("Disposable test database operation failed.")
        }
    }

    func cleanup() {
        #expect(throws: Never.self) { try removeMasterKey() }
        if FileManager.default.fileExists(atPath: directory.path) {
            #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) }
        }
    }
}
