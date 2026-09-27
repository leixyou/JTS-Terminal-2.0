//
//  UITestMCPRegistrationEnvironment.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/29.
//

#if JTS_UI_TEST_SUPPORT
import Foundation

/// Supplies deterministic MCP client state only to the isolated UI-test app.
/// Production identities and ordinary launches always use the real registrar.
nonisolated enum UITestMCPRegistrationEnvironment {
    static let fixtureKey = "JTS_TERMINAL_UI_MCP_REGISTRATION_FIXTURE"
    static let registeredCodexEndpointFixture = "registered-codex-endpoint"
    static let registeredAllEndpointsFixture = "registered-all-endpoints"
    static let resetPersistentStateKey =
        "JTS_TERMINAL_UI_RESET_MCP_REGISTRATION_STATE"
    static let canonicalConfigurationPathKey =
        "JTS_TERMINAL_UI_MCP_CANONICAL_CONFIG_PATH"

    static func resetPersistentStateIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard environment["JTS_TERMINAL_UI_TESTING"] == "1",
              environment[resetPersistentStateKey] == "1",
              bundleIdentifier
                == UITestAppLanguageBootstrap
                    .isolatedApplicationBundleIdentifier else {
            return
        }

        defaults.removeObject(
            forKey: MCPClientConfigurationAccessStore.storageKey
        )
        try? fileManager.removeItem(
            at: MCPClientHostEnvironment.privateRegistrationRegistryURL(
                fileManager: fileManager
            )
        )
        try? fileManager.removeItem(
            at: MCPClientHostEnvironment.privateRegistrationRegistryURL(
                fileManager: fileManager
            )
            .deletingLastPathComponent()
            .appendingPathComponent(
                "MCPRegistrationEvidence",
                isDirectory: true
            )
        )
    }

    static func registrationStatus(
        for client: MCPClientKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> MCPClientRegistrationStatus? {
        guard environment["JTS_TERMINAL_UI_TESTING"] == "1",
              bundleIdentifier
                == UITestAppLanguageBootstrap
                    .isolatedApplicationBundleIdentifier,
              let fixture = environment[fixtureKey],
              fixture == registeredCodexEndpointFixture
                || fixture == registeredAllEndpointsFixture else {
            return nil
        }

        let isSharedCodexEndpoint =
            client == .codexDesktop || client == .codexCLI
        let isRegistered = fixture == registeredAllEndpointsFixture
            || isSharedCodexEndpoint
        return MCPClientRegistrationStatus(
            client: client,
            configPath: fixtureConfigurationPath(for: client),
            state: isRegistered ? .registered : .notRegistered
        )
    }

    static func canonicalConfigurationURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL? {
        guard environment["JTS_TERMINAL_UI_TESTING"] == "1",
              bundleIdentifier
                == UITestAppLanguageBootstrap
                    .isolatedApplicationBundleIdentifier,
              let path = environment[canonicalConfigurationPathKey],
              path.hasPrefix("/") else {
            return nil
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path else { return nil }
        return url
    }

    private static func fixtureConfigurationPath(
        for client: MCPClientKind
    ) -> String {
        switch client {
        case .codexDesktop, .codexCLI:
            return "/tmp/jts-terminal-ui-fixtures/.codex/config.toml"
        case .claudeDesktop:
            return "/tmp/jts-terminal-ui-fixtures/claude_desktop_config.json"
        case .claudeCLI:
            return "/tmp/jts-terminal-ui-fixtures/.claude.json"
        case .grokCLI:
            return "/tmp/jts-terminal-ui-fixtures/.grok/config.toml"
        case .antigravity:
            return "/tmp/jts-terminal-ui-fixtures/antigravity/mcp_config.json"
        case .cursor:
            return "/tmp/jts-terminal-ui-fixtures/.cursor/mcp.json"
        }
    }
}
#endif
