//
//  MCPSettingsView.swift
//  JTSTerminal
//

import AppKit
import SwiftUI

/// Settings > MCP: AI client registration, Claude Code permission, the
/// terminal bridge and folders MCP may transfer files to and from.
struct MCPSettingsView: View {
    @Environment(\.appLanguage) private var language
    @AppStorage(MCPClientRegistrationStatusRefresh.storageKey) private var refreshToken = ""
    @AppStorage(TerminalMCPBridgeLaunchPolicy.userDefaultsKey) private var isTerminalBridgeEnabled = false
    @State private var statuses: [MCPClientRegistrationStatus] = []
    @State private var claudeCodeAllowsAllTools: Bool?
    @State private var folders: [LocalTransferAccessStore.Folder] = []
    @State private var selectedFolderID: UUID?
    @State private var folderError: String?

    var body: some View {
        Form {
            Section {
                ForEach(statuses, id: \.client) { status in
                    MCPClientStatusRow(status: status)
                }
            } header: {
                Text(language.localized("AI Clients", "AI 客户端"))
            } footer: {
                Text(language.localized(
                    "JTS Terminal adds only its own jts-terminal entry and shows the change before saving it. Restart a client after configuring it.",
                    "JTS Terminal 只添加自己的 jts-terminal 条目，并在保存前显示改动。配置后请重启对应客户端。"
                ))
            }
            .accessibilityIdentifier("mcp-client-registration-section")

            Section {
                LabeledContent("Claude Code") {
                    if claudeCodeAllowsAllTools == true {
                        Label(language.localized("Runs JTS tools without asking", "使用 JTS 工具时不再询问"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(language.localized("Allow JTS Tools…", "允许 JTS 工具…")) {
                            MCPMenuActions.allowAllToolsInClaudeCode(language: language)
                            refreshClaudeCodePermission()
                        }
                        .disabled(!isRegistered(.claudeCLI))
                        .accessibilityIdentifier("mcp-settings-claude-code-allow-button")
                    }
                }
            } footer: {
                Text(language.localized(
                    "Claude Code asks before each tool call unless you allow it. You can remove the rule later with /permissions in Claude Code.",
                    "除非你允许，否则 Claude Code 每次调用工具前都会询问。以后可在 Claude Code 中用 /permissions 删除这条规则。"
                ))
            }

            Section {
                Toggle(isOn: $isTerminalBridgeEnabled) {
                    Text(language.localized("Terminal Bridge", "终端 Bridge"))
                    Text(language.localized(
                        "Lets AI clients see and use terminals that are open in JTS Terminal and allowed for AI.",
                        "让 AI 客户端看到并使用在 JTS Terminal 中打开、且允许 AI 控制的终端。"
                    ))
                }
                .accessibilityIdentifier("mcp-settings-terminal-bridge-toggle")
            }

            Section {
                List(selection: $selectedFolderID) {
                    LabeledContent(
                        language.localized("Downloads, Pictures, Music, Movies", "下载、图片、音乐、影片"),
                        value: language.localized("Always available", "始终可用")
                    )
                    .selectionDisabled()

                    ForEach(folders) { folder in
                        Label(folder.path, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(folder.id)
                    }
                }
                .frame(minHeight: 96)

                HStack(spacing: 2) {
                    Button(action: addFolder) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 18)
                    }
                    .help(language.localized("Add Folder…", "添加文件夹…"))
                    .accessibilityLabel(language.localized("Add Folder…", "添加文件夹…"))
                    .accessibilityIdentifier("mcp-settings-add-folder-button")

                    Button(action: removeSelectedFolder) {
                        Image(systemName: "minus")
                            .frame(width: 20, height: 18)
                    }
                    .disabled(selectedFolder == nil)
                    .help(language.localized("Remove Folder", "移除文件夹"))
                    .accessibilityLabel(language.localized("Remove Folder", "移除文件夹"))
                    .accessibilityIdentifier("mcp-settings-remove-folder-button")

                    Spacer()
                }
                .buttonStyle(.borderless)

                if let folderError {
                    Label(folderError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(language.localized("Local Transfer Folders", "本地传输文件夹"))
            } footer: {
                Text(language.localized(
                    "AI uploads and downloads can use these folders on this Mac. Removing a folder stops future use; running transfers finish.",
                    "AI 上传和下载可以使用这台 Mac 上的这些文件夹。移除后不再允许后续使用，正在进行的传输会完成。"
                ))
            }

            Section {
                Button(language.localized("Reset MCP Client Registrations…", "重置 MCP 客户端注册…")) {
                    MCPMenuActions.resetRegistrations(language: language)
                }
                .accessibilityIdentifier("mcp-settings-reset-registrations-button")
            } footer: {
                Text(language.localized(
                    "Use this only if every AI client is refused or the registration records are damaged. You then configure each client again.",
                    "仅在所有 AI 客户端都被拒绝或注册记录损坏时使用，之后需要重新配置每个客户端。"
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
        .task(id: refreshToken) {
            await refreshStatuses()
            refreshClaudeCodePermission()
            reloadFolders()
        }
    }

    private var selectedFolder: LocalTransferAccessStore.Folder? {
        guard let selectedFolderID else { return nil }
        return folders.first { $0.id == selectedFolderID }
    }

    private func isRegistered(_ client: MCPClientKind) -> Bool {
        statuses.first { $0.client == client }?.isRegistered == true
    }

    private func refreshStatuses() async {
        #if JTS_UI_TEST_SUPPORT
        let fixtures = MCPClientKind.registrationDisplayOrder.compactMap {
            UITestMCPRegistrationEnvironment.registrationStatus(for: $0)
        }
        if fixtures.count == MCPClientKind.registrationDisplayOrder.count {
            statuses = fixtures
            return
        }
        #endif
        let commandPath = MCPClientConfiguration.commandPath()
        // Reading every client's configuration can take a moment; keep the
        // window responsive while it happens.
        statuses = await Task.detached(priority: .userInitiated) {
            MCPClientRegistrar().registrationStatuses(commandPath: commandPath)
        }.value
    }

    private func refreshClaudeCodePermission() {
        claudeCodeAllowsAllTools = MCPMenuActions.claudeCodeToolsAllowed()
    }

    private func reloadFolders() {
        do {
            folders = try LocalTransferAccessStore().folders()
            folderError = nil
        } catch {
            folders = []
            folderError = error.localizedDescription
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = language.localized("Allow", "允许")
        panel.message = language.localized(
            "Choose a folder AI uploads and downloads may use.",
            "选择允许 AI 上传和下载使用的文件夹。"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LocalTransferAccessStore().authorize(url)
        } catch {
            folderError = error.localizedDescription
        }
        reloadFolders()
    }

    private func removeSelectedFolder() {
        guard let selectedFolder else { return }
        do {
            try LocalTransferAccessStore().revoke(selectedFolder)
            selectedFolderID = nil
        } catch {
            folderError = error.localizedDescription
        }
        reloadFolders()
    }
}

/// One AI client: its state and the matching action.
private struct MCPClientStatusRow: View {
    @Environment(\.appLanguage) private var language
    let status: MCPClientRegistrationStatus

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Label(stateTitle, systemImage: stateSymbol)
                    .foregroundStyle(stateColor)
                    .accessibilityIdentifier("mcp-registration-state-\(status.client.identifier)")

                if status.isRegistered {
                    Menu(language.localized("Manage", "管理")) {
                        Button(language.localized("Reconfigure", "重新配置")) {
                            MCPMenuActions.configure(status.client, language: language)
                        }
                        Button(language.localized("Remove Registration…", "移除注册…")) {
                            MCPMenuActions.remove(status.client, language: language)
                        }
                    }
                    .fixedSize()
                } else {
                    Button(actionTitle) {
                        MCPMenuActions.configure(status.client, language: language)
                    }
                }
            }
        } label: {
            Text(status.client.displayName)
                .accessibilityIdentifier("mcp-registration-status-\(status.client.identifier)")
        }
        .help(helpText)
    }

    private var actionTitle: String {
        status.state == .needsUpdate
            ? language.localized("Update", "更新")
            : language.localized("Configure…", "配置…")
    }

    private var stateTitle: String {
        switch status.state {
        case .registered:
            return language.localized("Registered", "已注册")
        case .needsUpdate:
            return language.localized("Needs Update", "需要更新")
        case .accessRequired:
            return language.localized("Needs Access", "需要授权")
        case .invalidConfiguration:
            return language.localized("Config Invalid", "配置无效")
        case .notRegistered:
            return language.localized("Not Configured", "未配置")
        }
    }

    private var stateSymbol: String {
        switch status.state {
        case .registered:
            return "checkmark.circle.fill"
        case .needsUpdate:
            return "arrow.triangle.2.circlepath"
        case .accessRequired:
            return "folder.badge.questionmark"
        case .invalidConfiguration:
            return "exclamationmark.triangle.fill"
        case .notRegistered:
            return "circle.dashed"
        }
    }

    private var stateColor: Color {
        switch status.state {
        case .registered:
            return .green
        case .needsUpdate, .accessRequired:
            return .orange
        case .invalidConfiguration:
            return .red
        case .notRegistered:
            return .secondary
        }
    }

    private var helpText: String {
        if case .invalidConfiguration(let message) = status.state {
            return message
        }
        return status.configPath
    }
}
