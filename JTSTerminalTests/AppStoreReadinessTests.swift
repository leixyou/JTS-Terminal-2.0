import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct AppStoreReadinessTests {
    @Test func tomlRegistrationReplacesEquivalentHandWrittenHeader() {
        let existing = """
        model = "gpt-5.5"

        [mcp_servers."jts-terminal"] # added by hand
        command = "/tmp/old"
        args = ["--old"]

        [projects."/tmp/example"] # keep this table
        trust_level = "trusted"
        """
        let replacement = """
        [mcp_servers.jts-terminal]
        command = "/Applications/JTS Terminal.app/Contents/MacOS/JTS Terminal"
        args = ["--mcp"]
        """

        let updated = MCPClientRegistrar.replacingTOMLSection(
            named: "[mcp_servers.jts-terminal]",
            in: existing,
            with: replacement
        )

        #expect(!updated.contains("/tmp/old"))
        #expect(updated.components(separatedBy: "[mcp_servers.jts-terminal]").count - 1 == 1)
        #expect(!updated.contains("[mcp_servers.\"jts-terminal\"]"))
        // A following table with a trailing comment is a boundary, not content.
        #expect(updated.contains("[projects.\"/tmp/example\"] # keep this table"))
        #expect(updated.contains("trust_level = \"trusted\""))
        #expect(updated.contains("model = \"gpt-5.5\""))
    }

    @Test func tomlHeaderNormalizationKeepsDistinctTablesDistinct() {
        #expect(MCPClientRegistrar.normalizedTOMLTableHeader("[mcp_servers.jts-terminal]") == "[mcp_servers.jts-terminal]")
        #expect(MCPClientRegistrar.normalizedTOMLTableHeader("  [ mcp_servers . 'jts-terminal' ]  # note") == "[mcp_servers.jts-terminal]")
        #expect(MCPClientRegistrar.normalizedTOMLTableHeader("[[mcp_servers.jts-terminal]]") == "[[mcp_servers.jts-terminal]]")
        #expect(MCPClientRegistrar.normalizedTOMLTableHeader("[projects.\"/tmp/a.b\"]") == "[projects.\"/tmp/a.b\"]")
        #expect(MCPClientRegistrar.normalizedTOMLTableHeader("args = [\"--mcp\"]") == nil)
        #expect(MCPClientRegistrar.normalizedTOMLTableHeader("[mcp_servers.jts-terminal] trailing") == nil)
        #expect(MCPClientRegistrar.tomlSection(
            named: "[mcp_servers.jts-terminal]",
            in: "[mcp_servers.\"jts-terminal\"]\ncommand = \"/bin/echo\"\n[other]\nkey = 1"
        ) == ["command = \"/bin/echo\""])
    }

    @Test func identityFileAccessKeysMatchTheSSHArgumentPath() {
        let home = NSHomeDirectory()
        #expect(SSHIdentityFileAccess.storageKey(for: "  ") == nil)
        #expect(SSHIdentityFileAccess.storageKey(for: "~/.ssh/id_ed25519") == home + "/.ssh/id_ed25519")
        #expect(SSHIdentityFileAccess.storageKey(for: "/Users/example/.ssh/../.ssh/id_rsa ") == "/Users/example/.ssh/id_rsa")

        let suiteName = "AppStoreReadinessTests.identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!SSHIdentityFileAccess.hasStoredAccess(for: "~/.ssh/id_ed25519", defaults: defaults))
        // Without a stored bookmark, activation is a no-op rather than a failure.
        SSHIdentityFileAccess.activateIfNeeded(for: "~/.ssh/id_ed25519", defaults: defaults)
    }

    @Test func onlyTheLaunchdAgentSocketIsTreatedAsReachableFromTheSandbox() {
        // Paths and outcomes measured by scripts/sandbox_probes/run_ssh_agent_probe.sh.
        #expect(SSHAgentSandboxPolicy.isSystemAgentSocket("/var/run/com.apple.launchd.W9C3m1l0UE/Listeners"))
        #expect(SSHAgentSandboxPolicy.isSystemAgentSocket("/private/var/run/com.apple.launchd.W9C3m1l0UE/Listeners"))
        #expect(!SSHAgentSandboxPolicy.isSystemAgentSocket("/private/tmp/com.apple.launchd.YIqZGvE1s4/Listeners"))
        #expect(!SSHAgentSandboxPolicy.isSystemAgentSocket("/var/run/com.apple.launchd./Listeners"))
        #expect(!SSHAgentSandboxPolicy.isSystemAgentSocket("/var/run/com.apple.launchd.ABC/nested/Listeners"))
        #expect(!SSHAgentSandboxPolicy.isSystemAgentSocket("/Users/example/.ssh/agent.sock"))
        #expect(!SSHAgentSandboxPolicy.isSystemAgentSocket(
            "/Users/example/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        ))

        #expect(SSHAgentSandboxPolicy.availability(environment: [:]) == .notConfigured)
        #expect(SSHAgentSandboxPolicy.availability(environment: ["SSH_AUTH_SOCK": " "]) == .notConfigured)
        #expect(SSHAgentSandboxPolicy.availability(
            environment: ["SSH_AUTH_SOCK": "/var/run/com.apple.launchd.W9C3m1l0UE/Listeners"]
        ) == .systemAgent)
        #expect(SSHAgentSandboxPolicy.availability(
            environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock"]
        ) == .blockedBySandbox(socketPath: "/tmp/agent.sock"))
    }

    @Test func nonisolatedLocalizationFollowsTheSavedLanguage() {
        let suiteName = "AppStoreReadinessTests.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppLanguage.localizedForStoredLanguage("Ready", "就绪", defaults: defaults) == "Ready")
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.storageKey)
        #expect(AppLanguage.localizedForStoredLanguage("Ready", "就绪", defaults: defaults) == "就绪")
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        #expect(AppLanguage.localizedForStoredLanguage("Ready", "就绪", defaults: defaults) == "Ready")
    }

    @Test func persistenceNoticesAreLocalizedAndKeepDiagnostics() {
        let recovered = PersistenceNotice(
            kind: .recovered(backupName: "20261009-010203"),
            originalError: "disk I/O error"
        )
        #expect(recovered.title == "Local data store recovered")
        #expect(recovered.message.contains("20261009-010203"))
        #expect(recovered.localizedTitle(language: .simplifiedChinese) == "已恢复本地数据存储")
        #expect(recovered.localizedMessage(language: .simplifiedChinese).contains("disk I/O error"))

        let temporary = PersistenceNotice(
            kind: .temporary(recoveryError: "read-only volume"),
            originalError: "disk I/O error"
        )
        #expect(temporary.message.contains("read-only volume"))
        #expect(temporary.localizedTitle(language: .simplifiedChinese) == "服务器数据暂未保存")
    }

    @Test func remoteFileSortTitlesAreLocalized() {
        #expect(RemoteFileSortMode.modified.title(language: .english) == "Modified")
        #expect(RemoteFileSortMode.modified.title(language: .simplifiedChinese) == "修改时间")
        #expect(RemoteFileSortMode.allCases.allSatisfy { !$0.title(language: .simplifiedChinese).isEmpty })
    }
}
