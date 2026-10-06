import Foundation
import Security
import Testing
@testable import JTSMacCompanion

private final class MemoryMasterKeys: CompanionVaultMasterKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    func insert(_ key: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { throw CompanionVaultError.accountAlreadyExists }
        value = key
    }
}

struct CompanionCredentialVaultTests {
    @Test func durableEncryptedIdentitySurvivesNewVaultInstanceWithoutPlaintext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JTSMacVaultTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MemoryMasterKeys()
        let vault = CompanionCredentialVault(rootDirectory: directory, masterKeys: keys)
        let secret = "private-relay-key-and-pairing-\(UUID())"
        try vault.create(secret: secret, account: "host")
        let reloaded = CompanionCredentialVault(rootDirectory: directory, masterKeys: keys)
        #expect(try reloaded.read(account: "host") == secret)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data(secret.utf8)) == nil)
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("vault-rsa-private.der").path))
    }

    @Test func missingMasterKeyCannotReplaceExistingRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JTSMacVaultTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MemoryMasterKeys()
        let vault = CompanionCredentialVault(rootDirectory: directory, masterKeys: keys)
        try vault.create(secret: "original identity", account: "host")
        let missingKeys = CompanionCredentialVault(rootDirectory: directory, masterKeys: MemoryMasterKeys())
        #expect(throws: (any Error).self) { try missingKeys.save(secret: "replacement", account: "host") }
        #expect(try vault.read(account: "host") == "original identity")
    }

    @Test func symlinkDirectoryIsRejected() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("JTSMacVaultTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let real = parent.appendingPathComponent("real")
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let vault = CompanionCredentialVault(rootDirectory: link, masterKeys: MemoryMasterKeys())
        #expect(throws: (any Error).self) { try vault.create(secret: "must not write", account: "host") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }
}
