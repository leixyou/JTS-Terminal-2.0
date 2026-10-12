import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct NativeInterfaceTests {
    @Test func pathBarSplitsHomeRelativePaths() {
        let components = RemotePathComponents.components(of: "~/projects/app/")

        #expect(components.map(\.title) == ["~", "projects", "app"])
        #expect(components.map(\.path) == ["~", "~/projects", "~/projects/app"])
    }

    @Test func pathBarSplitsAbsolutePaths() {
        let components = RemotePathComponents.components(of: "/var//log")

        #expect(components.map(\.title) == ["/", "var", "log"])
        #expect(components.map(\.path) == ["/", "/var", "/var/log"])
        #expect(RemotePathComponents.components(of: "/").map(\.path) == ["/"])
    }

    @Test func pathBarTreatsBlankAndHomeAsHome() {
        #expect(RemotePathComponents.components(of: "").map(\.path) == ["~"])
        #expect(RemotePathComponents.components(of: "  ~  ").map(\.path) == ["~"])
    }

    @Test func pathBarKeepsRelativePathsRelative() {
        let components = RemotePathComponents.components(of: "logs/today")

        #expect(components.map(\.path) == ["logs", "logs/today"])
    }

    @Test func terminalTabsShareTheBarWithinReadableBounds() {
        #expect(TerminalTabLayout.tabWidth(available: 600, count: 0) == 0)
        #expect(TerminalTabLayout.tabWidth(available: 600, count: 1) == TerminalTabLayout.maximumWidth)
        #expect(TerminalTabLayout.tabWidth(available: 602, count: 4) == 149)
        #expect(TerminalTabLayout.tabWidth(available: 300, count: 6) == TerminalTabLayout.minimumWidth)
    }

    @Test func removedWorkspacesAreNotSelectable() {
        let rawValues = WorkspaceFeature.allCases.map(\.rawValue)

        #expect(!rawValues.contains("credentials"))
        #expect(!rawValues.contains("profiles"))
    }

    @Test func serverExportNamesAreFileSafe() {
        let session = RemoteSession(name: "prod: api/1", host: "api.example.com", username: "deploy")
        let unnamed = RemoteSession(name: " ", host: "db.example.com", username: "deploy")

        #expect(ServerProfileTransfer.suggestedName(for: [session]) == "prod--api-1")
        #expect(ServerProfileTransfer.suggestedName(for: [unnamed]) == "db.example.com")
        #expect(ServerProfileTransfer.suggestedName(for: [session, unnamed]) == "jts-terminal-mac-sessions")
    }
}
