import Foundation
import SwiftData
import Testing
@testable import JTSTerminal

@MainActor
struct MCPLocalTransferTests {
    @Test(arguments: [
        "open local \"/Users/example/file.txt\": Operation not permitted",
        "open local \"/Users/example/file.txt\": Permission denied",
        "write local: No space left on device",
        "write local: Read-only file system"
    ]) func localFailureCannotReportUploadedBytes(_ failure: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("upload.txt")
        try Data("nonempty".utf8).write(to: url)
        let runner = MCPFileTransferRunner(
            upload: { _, _, _, _, _ in
                CommandResult(command: "sftp", exitCode: 0, standardOutput: "", standardError: failure)
            },
            download: { _, _, _, _, _, _ in fatalError("unexpected download") }
        )
        let response = try await fixture.call("jts_upload_file", local: url, runner: runner)
        #expect(response.isError)
        #expect(response.text.contains(failure))
        let task = try #require(fixture.context.fetch(FetchDescriptor<RemoteTransferTask>()).first)
        #expect(task.status == .failed)
        #expect(task.exitCode != 0)
        #expect(task.transferredByteCount == 0)
    }

    @Test func emptyDownloadCannotBeReportedAsExpectedBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("download.txt")
        let runner = MCPFileTransferRunner(
            upload: { _, _, _, _, _ in fatalError("unexpected upload") },
            download: { _, _, local, _, _, _ in
                try Data().write(to: URL(fileURLWithPath: local))
                return CommandResult(command: "sftp", exitCode: 0, standardOutput: "", standardError: "")
            }
        )
        let response = try await fixture.call("jts_download_file", local: url, runner: runner, expected: 62)
        #expect(response.isError)
        #expect(response.text.contains("Downloaded 0 bytes; expected 62"))
        let task = try #require(fixture.context.fetch(FetchDescriptor<RemoteTransferTask>()).first)
        #expect(task.status == .failed)
        #expect(task.transferredByteCount == 0)
        #expect(task.exitCode != 0)
    }

    @Test func uploadStageContainsCompleteIndependentCopy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.root.appendingPathComponent("source.txt")
        let contents = Data(repeating: 0x41, count: 262_144)
        try contents.write(to: original)
        let stage = try LocalTransferFileIO.stageUpload(original, recursive: false)
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        try Data("changed".utf8).write(to: original)
        #expect(try Data(contentsOf: stage) == contents)
        #expect(stage.lastPathComponent == original.lastPathComponent)
        #expect(stage.deletingLastPathComponent() != original.deletingLastPathComponent())
    }

    @Test func incompleteStagedDownloadPreservesExistingDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("keep.txt")
        try Data("keep me".utf8).write(to: destination)
        let stage = try LocalTransferFileIO.stageDownload(destination, recursive: false, resume: false)
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        try Data().write(to: stage)
        #expect(throws: LocalTransferVerificationError.self) {
            try LocalTransferFileIO.verifyDownload(stage, recursive: false, expectedBytes: 62)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep me")
    }

    @Test func resumedDownloadCopiesPrefixAndAtomicallyInstallsVerifiedResult() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("resume.txt")
        try Data("prefix".utf8).write(to: destination)
        let stage = try LocalTransferFileIO.stageDownload(destination, recursive: false, resume: true)
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        #expect(try String(contentsOf: stage, encoding: .utf8) == "prefix")
        let content = Data(repeating: 0x41, count: 2_000_000)
        try content.write(to: stage)
        try LocalTransferFileIO.verifyDownload(stage, recursive: false, expectedBytes: Int64(content.count))
        try LocalTransferFileIO.install(stage, at: destination)
        #expect(try Data(contentsOf: destination) == content)
    }

    @Test func zeroLengthSourceIsAValidDownloadWhenExpectedSizeIsZero() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let empty = fixture.root.appendingPathComponent("empty")
        try Data().write(to: empty)
        try LocalTransferFileIO.verifyDownload(empty, recursive: false, expectedBytes: 0)
    }

    @Test func recursiveInstallPreservesUnrelatedDestinationFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("unrelated.txt"))
        let stage = try LocalTransferFileIO.stageDownload(destination, recursive: true, resume: false)
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        let child = stage.appendingPathComponent("remote/nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("download".utf8).write(to: child.appendingPathComponent("new.txt"))
        try LocalTransferFileIO.verifyDownload(stage, recursive: true, expectedBytes: nil)
        try LocalTransferFileIO.install(stage, at: destination)
        #expect(try Data(contentsOf: destination.appendingPathComponent("remote/nested/new.txt")) == Data("download".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("unrelated.txt")) == Data("keep".utf8))
    }

    @Test func uploadRejectsSymlinksOutsideSelectedTree() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("escape").path, withDestinationPath: "/etc/hosts")
        #expect(throws: LocalTransferVerificationError.self) {
            _ = try LocalTransferFileIO.stageUpload(source, recursive: true)
        }
    }

    @Test func savedFolderCanBeReadAndRevokedByAnotherStoreInstance() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = LocalTransferAccessStore(directory: fixture.root.appendingPathComponent("grants"))
        let folder = fixture.root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.authorize(folder)
        let reader = LocalTransferAccessStore(directory: store.directory)
        let saved = try #require(reader.folders().first)
        let lease = try reader.beginAccess(to: folder.appendingPathComponent("future.txt"))
        lease.stop()
        try reader.revoke(saved)
        #expect(try store.folders().isEmpty)
        #expect(!LocalTransferAccessStore.contains("/Users/me/downloads-other/a", in: "/Users/me/downloads"))
    }

    @Test func localFailureTaskDoesNotInflateByteCount() {
        let task = RemoteTransferTask(session: RemoteSession(), direction: .upload,
                                      remotePath: "/remote", localPath: "/local", expectedByteCount: 62)
        task.markFinished(result: CommandResult(command: "sftp", exitCode: 0, standardOutput: "",
                                                standardError: "open local: Operation not permitted"))
        #expect(task.status == .failed)
        #expect(task.transferredByteCount == 0)
        #expect(task.exitCode == 1)
    }

    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-transfer-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
            context = ModelContext(container)
            let session = RemoteSession(name: "Files", host: "files.example.com", username: "tester")
            session.mcpEnabled = true
            session.mcpAlias = "files"
            context.insert(session)
            try context.save()
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func call(_ tool: String, local: URL, runner: MCPFileTransferRunner, expected: Int? = nil) async throws -> (isError: Bool, text: String) {
            let registration = MCPClientRegistrationRecord(
                registrationID: UUID().uuidString, configurationKey: root.appendingPathComponent("client.json").path,
                clientLabel: "Local Transfer Tests", createdAt: Date()
            )
            let server = MCPStdioServer(
                modelContext: context, guiLauncher: .disabled, fileTransferRunner: runner,
                remoteGrantStore: RemoteClientGrantStore(storageURL: root.appendingPathComponent("security/grants.json")),
                clientRegistration: registration
            )
            var arguments: [String: Any] = ["server": "files", "localPath": local.path, "remotePath": "/srv/file.txt"]
            if let expected { arguments["expectedBytes"] = expected }
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                          "params": ["name": tool, "arguments": arguments]]
            let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            let response = try #require(await server.handleLine(line))
            let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            if let error = object["error"] as? [String: Any] {
                return (true, try #require(error["message"] as? String))
            }
            let result = try #require(object["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            return (result["isError"] as? Bool == true, try #require(content.first?["text"] as? String))
        }
    }
}
