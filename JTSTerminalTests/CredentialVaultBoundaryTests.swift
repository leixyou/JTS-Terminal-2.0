import Darwin
import Foundation
import Testing
@testable import JTSTerminal

@Suite("Credential vault filesystem boundary")
struct CredentialVaultBoundaryTests {
    @Test("First missing-account read creates only private vault files")
    func firstReadProtectsCreatedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-vault-first-read-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await MainActor.run {
            try EncryptedCredentialVault(rootDirectory: directory)
                .read(account: "missing@example.test:22")
        }
        #expect(result == nil)
        #expect(try permissions(at: directory) == 0o700)

        let candidates = [
            "credentials.sqlite",
            "credentials.sqlite-wal",
            "credentials.sqlite-shm",
        ]
        var observedDatabase = false
        for filename in candidates {
            let url = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            observedDatabase = observedDatabase || filename == "credentials.sqlite"
            #expect(try permissions(at: url) == 0o600)
            #expect(try hardLinkCount(at: url) == 1)
        }
        #expect(observedDatabase)
    }

    @Test("Symbolic-link database is rejected before SQLite opens it")
    func rejectsSymbolicLinkDatabase() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-vault-symlink-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("vault", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.sqlite")
        defer { try? FileManager.default.removeItem(at: parent) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("outside-must-remain-unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("credentials.sqlite"),
            withDestinationURL: outside
        )

        #expect(throws: CredentialStoreError.self) {
            _ = try EncryptedCredentialVault(rootDirectory: directory)
                .read(account: "missing@example.test:22")
        }
        #expect(try Data(contentsOf: outside) == Data("outside-must-remain-unchanged".utf8))
    }

    @Test("Hard-linked database is rejected before SQLite opens it")
    func rejectsHardLinkedDatabase() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-vault-hardlink-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("vault", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.sqlite")
        defer { try? FileManager.default.removeItem(at: parent) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("outside-must-remain-unchanged".utf8).write(to: outside)
        try FileManager.default.linkItem(
            at: outside,
            to: directory.appendingPathComponent("credentials.sqlite")
        )

        #expect(throws: CredentialStoreError.self) {
            _ = try EncryptedCredentialVault(rootDirectory: directory)
                .read(account: "missing@example.test:22")
        }
        #expect(try Data(contentsOf: outside) == Data("outside-must-remain-unchanged".utf8))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }

    private func hardLinkCount(at url: URL) throws -> UInt64 {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw CredentialStoreError.boundary("Test could not inspect vault metadata.")
        }
        return UInt64(metadata.st_nlink)
    }
}
