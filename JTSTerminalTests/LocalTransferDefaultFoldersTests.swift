import Foundation
import Testing
@testable import JTSTerminal

struct LocalTransferDefaultFoldersTests {
    @Test func defaultFoldersCoverOnlyStandardLoginHomeLocations() {
        let home = URL(fileURLWithPath: "/Users/jts-default-folder-test")
        for name in ["Downloads", "Pictures", "Music", "Movies"] {
            #expect(LocalTransferDefaultFolders.contains(home.appendingPathComponent(name), accountHome: home))
            #expect(LocalTransferDefaultFolders.contains(home.appendingPathComponent("\(name)/nested/file.bin"), accountHome: home))
        }
        for name in ["Desktop", "Documents", "Downloads-other", "Pictures-other", ".ssh"] {
            #expect(!LocalTransferDefaultFolders.contains(home.appendingPathComponent("\(name)/file.bin"), accountHome: home))
        }
        #expect(!LocalTransferDefaultFolders.contains(URL(fileURLWithPath: "/Users/another/Downloads/file.bin"), accountHome: home))
    }

    @Test func defaultFolderDoesNotTreatEscapingSymlinkAsBuiltInAccess() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("default-folders-\(UUID())")
        let downloads = home.appendingPathComponent("Downloads")
        let outside = home.appendingPathComponent("Documents")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: outside.appendingPathComponent("file.bin"))
        let link = downloads.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!LocalTransferDefaultFolders.contains(link.appendingPathComponent("file.bin"), accountHome: home))
    }

    @Test func brokenCustomGrantCannotBlockDefaultFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("default-grants-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFileSecurity.secureDirectory(at: root)
        let record = root.appendingPathComponent("broken.json")
        try Data("invalid saved record".utf8).write(to: record)
        try PrivateFileSecurity.securePrivateFile(at: record)
        let store = LocalTransferAccessStore(directory: root)
        let downloads = MCPClientHostEnvironment.accountHomeDirectory().appendingPathComponent("Downloads/future.bin")
        let lease = try store.beginAccess(to: downloads)
        lease.stop()
        #expect(throws: (any Error).self) { _ = try store.folders() }
    }
}
