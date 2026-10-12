//
//  JTSTerminalApp.swift
//  JTSTerminal
//
//  Created by tester on 2026/4/29.
//

import Darwin
import AppKit
import SwiftUI
import SwiftData

@main
struct JTSTerminalApp: App {
    @NSApplicationDelegateAdaptor(JTSTerminalApplicationDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer = {
        ModelContainerFactory.makeSharedContainer()
    }()

    init() {
        #if JTS_UI_TEST_SUPPORT
        UITestMCPRegistrationEnvironment
            .resetPersistentStateIfRequested()
        UITestAppLanguageBootstrap.apply()
        SignedAskpassHostedSelfTest.runAndExitIfRequested()
        #endif
        if MCPStdioServer.isRequested {
            MCPStdioServer.runAndExit()
        }
    }

    var body: some Scene {
        WindowGroup("JTS Terminal", id: MainWindowLifecycle.sceneID) {
            #if JTS_UI_TEST_SUPPORT
            if UnitTestHostPolicy.isActive {
                UnitTestHostView()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
        .defaultSize(
            width: MainWindowSizePolicy.preferredContentSize.width,
            height: MainWindowSizePolicy.preferredContentSize.height
        )
        .modelContainer(sharedModelContainer)
        .commands {
            JTSTerminalCommands()
        }
        #if ENABLE_RDP_2
        MenuBarExtra {
            RDPDesktopMenu().environment(\.appLanguage, AppLanguage.stored)
        } label: {
            RDPDesktopMenuLabel()
        }
        Window("Companion Devices", id: CompanionDevicesModel.windowID) {
            CompanionDevicesView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 920, height: 640)
        .windowResizability(.contentMinSize)
        #endif
        Settings {
            AppSettingsView()
        }
    }
}

@MainActor
final class RemoteProcessShutdownGuard {
    static let shared = RemoteProcessShutdownGuard()

    private weak var terminalWorkspaceStore: TerminalWorkspaceStore?
    private weak var tunnelManagerStore: SSHTunnelManagerStore?
    private weak var rdpDesktopRuntimeStore: RDPDesktopRuntimeStore?

    private init() {}

    func register(
        terminalWorkspaceStore: TerminalWorkspaceStore,
        tunnelManagerStore: SSHTunnelManagerStore,
        rdpDesktopRuntimeStore: RDPDesktopRuntimeStore? = nil
    ) {
        self.terminalWorkspaceStore = terminalWorkspaceStore
        self.tunnelManagerStore = tunnelManagerStore
        self.rdpDesktopRuntimeStore = rdpDesktopRuntimeStore
    }

    var report: RemoteProcessShutdownReport {
        RemoteProcessShutdownReport(
            terminals: terminalWorkspaceStore?.runningProcessSummaries ?? [],
            tunnels: tunnelManagerStore?.runningTunnelSummaries ?? [],
            rdpDesktops: rdpDesktopRuntimeStore?.runningDesktopSummaries ?? []
        )
    }

    func confirmClose(kind: RemoteProcessShutdownKind) -> Bool {
        let language = AppLanguage.stored
        let report = report
        guard !report.isEmpty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.messageText(for: kind, language: language)
        alert.informativeText = report.informativeText(language: language)
        alert.addButton(withTitle: kind.confirmButtonTitle(language: language))
        alert.addButton(withTitle: language.localized("Cancel", "取消"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        #if ENABLE_RDP_2
        if case .app = kind { RDPDesktopWindowCoordinator.shared.prepareForTermination() }
        #endif
        stopAll()
        return true
    }

    func stopAll() {
        terminalWorkspaceStore?.revokeAllMCPControl()
        terminalWorkspaceStore?.stopAllProcesses()
        tunnelManagerStore?.stopAllTunnels()
        rdpDesktopRuntimeStore?.stopAllImmediately()
    }
}

enum RemoteProcessShutdownKind {
    case window
    case app

    var confirmButtonTitle: String {
        confirmButtonTitle(language: .defaultLanguage)
    }

    func confirmButtonTitle(language: AppLanguage) -> String {
        switch self {
        case .window:
            return language.localized("Close Sessions", "关闭会话")
        case .app:
            return language.localized("Quit and Close Sessions", "退出并关闭会话")
        }
    }

    var actionName: String {
        actionName(language: .defaultLanguage)
    }

    func actionName(language: AppLanguage) -> String {
        switch self {
        case .window:
            return language.localized("closing this window", "关闭此窗口")
        case .app:
            return language.localized("quitting JTS Terminal", "退出 JTS Terminal")
        }
    }
}

struct RemoteProcessShutdownReport: Equatable {
    var terminals: [String]
    var tunnels: [String]
    var rdpDesktops: [String] = []

    var isEmpty: Bool {
        terminals.isEmpty && tunnels.isEmpty && rdpDesktops.isEmpty
    }

    func messageText(for kind: RemoteProcessShutdownKind) -> String {
        messageText(for: kind, language: .defaultLanguage)
    }

    func messageText(for kind: RemoteProcessShutdownKind, language: AppLanguage) -> String {
        language.localized(
            "Close running remote sessions and tunnels before \(kind.actionName(language: language))?",
            "在\(kind.actionName(language: language))前关闭正在运行的远程会话和隧道？"
        )
    }

    var informativeText: String {
        informativeText(language: .defaultLanguage)
    }

    func informativeText(language: AppLanguage) -> String {
        var lines: [String] = [
            language.localized(
                "The following remote sessions are still running. Closing them will disconnect active SSH and RDP sessions and stop port forwarding.",
                "以下远程会话仍在运行。关闭它们会断开活动 SSH 与 RDP 会话并停止端口转发。"
            )
        ]

        if !terminals.isEmpty {
            lines.append("")
            lines.append(language.localized("SSH / Terminal:", "SSH / 终端："))
            lines.append(contentsOf: terminals.prefix(6).map { "• \($0)" })
            if terminals.count > 6 {
                lines.append(language.localized("• \(terminals.count - 6) more terminal sessions", "• 还有 \(terminals.count - 6) 个终端会话"))
            }
        }

        if !tunnels.isEmpty {
            lines.append("")
            lines.append(language.localized("Tunnels:", "隧道："))
            lines.append(contentsOf: tunnels.prefix(6).map { "• \($0)" })
            if tunnels.count > 6 {
                lines.append(language.localized("• \(tunnels.count - 6) more tunnels", "• 还有 \(tunnels.count - 6) 个隧道"))
            }
        }

        if !rdpDesktops.isEmpty {
            lines.append("")
            lines.append(language.localized("Windows desktops:", "Windows 桌面："))
            lines.append(contentsOf: rdpDesktops.prefix(6).map { "• \($0)" })
            if rdpDesktops.count > 6 {
                lines.append(language.localized("• \(rdpDesktops.count - 6) more desktops", "• 还有 \(rdpDesktops.count - 6) 个桌面会话"))
            }
        }

        lines.append("")
        lines.append(language.localized("Choose Cancel to keep everything running.", "选择取消可保持所有进程继续运行。"))
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class JTSTerminalApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if ENABLE_RDP_2
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { CompanionRevocationModel.shared.start() }
        #endif
        MainWindowLifecycle.scheduleLaunchActivationRecovery()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MCPClientRegistrationStatusRefresh.bump()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainWindowLifecycle.ensureMainWindowVisible()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ApplicationTerminationPolicy.bypassesRemoteProcessConfirmation() {
            return .terminateNow
        }
        return RemoteProcessShutdownGuard.shared.confirmClose(kind: .app)
            ? NSApplication.TerminateReply.terminateNow
            : NSApplication.TerminateReply.terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if ENABLE_RDP_2
        RDPDesktopWindowCoordinator.shared.prepareForTermination()
        #endif
        RemoteProcessShutdownGuard.shared.stopAll()
        #if ENABLE_RDP_2
        RDPDesktopWindowCoordinator.shared.closeAllWindows()
        CompanionDevicesModel.shared.disconnectAll()
        ApplicationWorkspaceRuntime.shared.macDesktops.disconnectAll()
        MacSystemScreenSharingStore.shared.disconnectAll()
        ApplicationWorkspaceRuntime.shared.bridge.stop()
        #endif
    }
}

struct JTSTerminalCommandHandlers {
    var newServer: () -> Void
    var showServerProperties: () -> Void
    var openSelectedServer: () -> Void
    var showDesktop: () -> Void
    var showTerminal: () -> Void
    var showFiles: () -> Void
    var showTunnels: () -> Void
    var showCredentials: () -> Void
    var showProfiles: () -> Void
    var availableWorkspaceFeatures: [WorkspaceFeature]
    var hasSelectedServer: Bool
    var selectedServerOpenCommand: JTSTerminalServerOpenCommand
    var canOpenSelectedServer: Bool
}

enum JTSTerminalServerOpenCommand: Equatable {
    case interactiveTerminal
    case desktop

    static func resolved(
        for connectionType: RemoteConnectionType?
    ) -> JTSTerminalServerOpenCommand {
        connectionType == .rdp ? .desktop : .interactiveTerminal
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .interactiveTerminal:
            return language.localized(
                "Open Interactive Terminal",
                "打开交互式终端"
            )
        case .desktop:
            return language.localized("Open Desktop", "打开桌面")
        }
    }
}

private struct JTSTerminalCommandHandlersKey: FocusedValueKey {
    typealias Value = JTSTerminalCommandHandlers
}

extension FocusedValues {
    var jtsTerminalCommandHandlers: JTSTerminalCommandHandlers? {
        get { self[JTSTerminalCommandHandlersKey.self] }
        set { self[JTSTerminalCommandHandlersKey.self] = newValue }
    }
}

private struct JTSTerminalCommands: Commands {
    @FocusedValue(\.jtsTerminalCommandHandlers) private var handlers
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.defaultLanguage.rawValue
    @AppStorage(MCPClientRegistrationStatusRefresh.storageKey) private var mcpRegistrationRefreshToken = ""

    private var language: AppLanguage {
        AppLanguage.resolved(from: languageRawValue)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(language.localized("About JTS Terminal", "关于 JTS Terminal")) {
                AppAboutPanel.show(language: language)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(language.localized("New Server", "新建服务器")) {
                handlers?.newServer()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(handlers == nil)
        }

        CommandMenu(language.localized("Server", "服务器")) {
            #if ENABLE_RDP_2
            Button(language.localized("Companion Devices…", "Companion 设备…")) {
                openWindow(id: CompanionDevicesModel.windowID)
            }
            SettingsLink { Text(language.localized("Relay Stations…", "中转站…")) }
            Divider()
            #endif
            Button(language.localized("Server Properties", "服务器属性")) {
                handlers?.showServerProperties()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(handlers?.hasSelectedServer != true)

            Button(
                (
                    handlers?.selectedServerOpenCommand
                        ?? .interactiveTerminal
                ).title(language: language)
            ) {
                handlers?.openSelectedServer()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(handlers?.canOpenSelectedServer != true)
        }

        CommandMenu("MCP") {
            ForEach(MCPClientKind.registrationDisplayOrder, id: \.self) { client in
                let status = mcpRegistrationStatus(for: client)
                if status.isRegistered {
                    Menu {
                        Button(language.localized("Reconfigure", "重新配置")) {
                            MCPMenuActions.configure(client, language: language)
                        }
                        Button(language.localized("Remove Registration…", "移除注册…")) {
                            MCPMenuActions.remove(client, language: language)
                        }
                    } label: {
                        Label(
                            mcpRegistrationMenuTitle(for: status),
                            systemImage: mcpRegistrationMenuSymbol(for: status)
                        )
                    }
                    .help(mcpRegistrationMenuHelp(for: status))
                } else {
                    Button {
                        MCPMenuActions.perform(
                            client,
                            status: status,
                            language: language
                        )
                    } label: {
                        Label(
                            mcpRegistrationMenuTitle(for: status),
                            systemImage: mcpRegistrationMenuSymbol(for: status)
                        )
                    }
                    .help(mcpRegistrationMenuHelp(for: status))
                }
            }

            Divider()

            SettingsLink {
                Text(language.localized("MCP Settings…", "MCP 设置…"))
            }
            .help(language.localized(
                "Claude Code permission, Terminal Bridge, local transfer folders and registration recovery.",
                "Claude Code 权限、终端 Bridge、本地传输文件夹和注册恢复。"
            ))

            if MCPClientRegistrar.allowsUnregisteredDirectConfiguration {
                Divider()

                Button(language.localized("Copy MCP Config", "复制 MCP 配置")) {
                    MCPMenuActions.copyConfig(language: language)
                }
            }
        }

        CommandMenu(language.localized("Workspace", "工作区")) {
            if supportsWorkspaceFeature(.desktop) {
                Button(language.localized("Show Desktop", "显示桌面")) {
                    handlers?.showDesktop()
                }
                .keyboardShortcut("1", modifiers: .command)
            }

            if supportsWorkspaceFeature(.command) {
                Button(language.localized("Show Terminal", "显示终端")) {
                    handlers?.showTerminal()
                }
                .keyboardShortcut("1", modifiers: .command)
            }

            if supportsWorkspaceFeature(.files) {
                Button(language.localized("Show Files", "显示文件")) {
                    handlers?.showFiles()
                }
                .keyboardShortcut("2", modifiers: .command)
            }

            if supportsWorkspaceFeature(.tunnels) {
                Button(language.localized("Show Tunnels", "显示隧道")) {
                    handlers?.showTunnels()
                }
                .keyboardShortcut("3", modifiers: .command)
            }

            if supportsWorkspaceFeature(.credentials) {
                Button(language.localized("Show Password", "显示密码")) {
                    handlers?.showCredentials()
                }
                .keyboardShortcut("4", modifiers: .command)
            }

            if supportsWorkspaceFeature(.profiles) {
                if (handlers?.availableWorkspaceFeatures.count ?? 0) > 1 {
                    Divider()
                }
                Button(language.localized("Show Import/Export", "显示导入导出")) {
                    handlers?.showProfiles()
                }
                .keyboardShortcut("5", modifiers: .command)
            }

            if handlers?.availableWorkspaceFeatures.isEmpty != false {
                Button(language.localized("Select a Server", "请选择服务器")) {}
                    .disabled(true)
            }
        }

        CommandGroup(after: .windowArrangement) {
            Divider()

            Button(MainWindowLifecycle.showMainWindowCommandTitle(language: language)) {
                MainWindowLifecycle.showMainWindow {
                    openWindow(id: MainWindowLifecycle.sceneID)
                }
            }
            .keyboardShortcut("0", modifiers: .command)
            .help(language.localized(
                "Show or bring the main JTS Terminal window to the front.",
                "显示或置前 JTS Terminal 主窗口。"
            ))
        }

        CommandGroup(after: .help) {
            Divider()

            Button(language.localized("JTS Terminal Support", "JTS Terminal 技术支持")) {
                AppStoreReviewLinks.open(.support)
            }

            Button(language.localized("Privacy Policy", "隐私政策")) {
                AppStoreReviewLinks.open(.privacyPolicy)
            }
        }
    }

    private func mcpRegistrationStatus(for client: MCPClientKind) -> MCPClientRegistrationStatus {
        _ = mcpRegistrationRefreshToken
        let registrar = MCPClientRegistrar()
        let commandPath = MCPClientConfiguration.commandPath()
        #if JTS_UI_TEST_SUPPORT
        if let fixtureStatus = UITestMCPRegistrationEnvironment
            .registrationStatus(for: client) {
            return fixtureStatus
        }
        if client.configurationEndpoint == .codex,
           let canonicalURL = UITestMCPRegistrationEnvironment
            .canonicalConfigurationURL() {
            let scopedStatus = registrar.configurationAccessStore
                .withAccess(for: client) { url in
                    registrar.registrationStatus(
                        for: client,
                        commandPath: commandPath,
                        configurationURL: url
                    )
                }
            if case .value(let status) = scopedStatus {
                return status
            }
            return registrar.registrationStatus(
                for: client,
                commandPath: commandPath,
                configurationURL: canonicalURL
            )
        }
        #endif
        return registrar.registrationStatus(
            for: client,
            commandPath: commandPath
        )
    }

    private func supportsWorkspaceFeature(_ feature: WorkspaceFeature) -> Bool {
        handlers?.availableWorkspaceFeatures.contains(feature) == true
    }

    private func mcpRegistrationMenuTitle(
        for status: MCPClientRegistrationStatus
    ) -> String {
        let client = status.client
        switch status.state {
        case .registered:
            return language.localized("\(client.displayName) - Registered", "\(client.displayName) - 已注册")
        case .needsUpdate:
            return language.localized("Configure \(client.displayName)", "配置 \(client.displayName)")
        case .accessRequired:
            return language.localized("Configure \(client.displayName)", "配置 \(client.displayName)")
        case .invalidConfiguration:
            return language.localized("Configure \(client.displayName)", "配置 \(client.displayName)")
        case .notRegistered:
            return language.localized("Configure \(client.displayName)", "配置 \(client.displayName)")
        }
    }

    private func mcpRegistrationMenuSymbol(
        for status: MCPClientRegistrationStatus
    ) -> String {
        switch status.state {
        case .registered:
            return "checkmark.circle.fill"
        case .needsUpdate:
            return "arrow.triangle.2.circlepath.circle"
        case .accessRequired:
            return "folder.badge.questionmark"
        case .invalidConfiguration:
            return "exclamationmark.triangle.fill"
        case .notRegistered:
            return "plus.circle"
        }
    }

    private func mcpRegistrationMenuHelp(
        for status: MCPClientRegistrationStatus
    ) -> String {
        let client = status.client
        switch status.state {
        case .registered where status.verification != nil && status.verification != .configuration:
            return language.localized(
                "JTS Terminal registered \(client.displayName) earlier but cannot read its configuration right now to confirm the entry is still there. If \(client.displayName) no longer shows JTS tools, choose Reconfigure.",
                "JTS Terminal 之前已注册 \(client.displayName)，但目前无法读取其配置来确认条目仍在。如果 \(client.displayName) 里看不到 JTS 工具，请选择“重新配置”。"
            )
        case .registered:
            return language.localized(
                "\(client.displayName) already has the jts-terminal MCP server registered. Choose Reconfigure to write it again, or Remove Registration to take it out.",
                "\(client.displayName) 已注册 jts-terminal MCP 服务器。可选择“重新配置”重新写入，或“移除注册”将其删除。"
            )
        case .needsUpdate:
            return language.localized(
                "JTS Terminal detected an older registration and will update the canonical \(client.displayName) configuration automatically.",
                "JTS Terminal 检测到旧注册，将自动更新 \(client.displayName) 的标准配置。"
            )
        case .accessRequired:
            return language.localized(
                "JTS Terminal already knows the canonical \(client.displayName) configuration. macOS may require one system authorization before JTS Terminal can verify or update it.",
                "JTS Terminal 已知道 \(client.displayName) 的标准配置位置；macOS 可能要求一次系统授权，之后即可自动核验或更新。"
            )
        case .invalidConfiguration(let message):
            return language.localized(
                "JTS Terminal will inspect the canonical \(client.displayName) configuration and report the exact problem without replacing unrelated settings: \(message)",
                "JTS Terminal 将检查 \(client.displayName) 的标准配置，并在不替换无关设置的前提下报告具体问题：\(message)"
            )
        case .notRegistered:
            return language.localized(
                "JTS Terminal will locate and configure \(client.displayName) automatically. No configuration filename or path is required.",
                "JTS Terminal 将自动定位并配置 \(client.displayName)，无需填写配置文件名或路径。"
            )
        }
    }
}

enum AppStoreReviewLinks: String, CaseIterable {
    case support = "https://www.lljts.com/jts-support"
    case privacyPolicy = "https://www.lljts.com/privacy"

    var url: URL {
        URL(string: rawValue)!
    }

    @MainActor
    static func open(_ link: AppStoreReviewLinks) {
        NSWorkspace.shared.open(link.url)
    }
}

@MainActor
enum MainWindowLifecycle {
    private enum FullScreenToggleState: Equatable {
        case scheduled(requestID: UUID, windowID: ObjectIdentifier)
        case awaitingTransition(requestID: UUID, windowID: ObjectIdentifier)
        case transitioning(windowID: ObjectIdentifier)

        var windowID: ObjectIdentifier {
            switch self {
            case .scheduled(_, let windowID),
                 .awaitingTransition(_, let windowID),
                 .transitioning(let windowID):
                return windowID
            }
        }
    }

    static let sceneID = "main"
    static let title = "JTS Terminal"
    static let identifier = NSUserInterfaceItemIdentifier("com.lljts.JTSTerminal.main-window")
    static let launchActivationRetryDelays: [TimeInterval] = [0.15, 0.45, 0.9, 1.6]
    private static let fullScreenTransitionStartTimeout: TimeInterval = 1
    private static weak var configuredWindow: NSWindow?
    private static var fullScreenToggleState: FullScreenToggleState?

    static func showMainWindowCommandTitle(language: AppLanguage) -> String {
        language.localized("Show Main Window", "显示主窗口")
    }

    static func configure(_ window: NSWindow) {
        window.title = title
        window.identifier = identifier
        window.tabbingIdentifier = identifier.rawValue
        #if JTS_UI_TEST_SUPPORT
        UITestMainWindowSizeStabilizer.scheduleIfRequested(to: window)
        #endif
        if fullScreenToggleState?.windowID != ObjectIdentifier(window) {
            fullScreenToggleState = nil
        }
        configuredWindow = window
    }

    static func showMainWindow(createIfNeeded: () -> Void) {
        if bringExistingMainWindowToFront() {
            return
        }

        createIfNeeded()
        DispatchQueue.main.async {
            _ = bringExistingMainWindowToFront()
        }
    }

    @discardableResult
    static func bringExistingMainWindowToFront() -> Bool {
        let window = resolvedMainWindow()
        guard let window else {
            return false
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    static func resolvedMainWindow() -> NSWindow? {
        configuredWindow.flatMap { window in
            isMainWindow(window) ? window : nil
        } ?? NSApp.windows.first(where: isMainWindow)
    }

    @discardableResult
    static func toggleFullScreen() -> Bool {
        guard let window = resolvedMainWindow() else {
            return false
        }
        let windowID = ObjectIdentifier(window)
        if let currentState = fullScreenToggleState {
            if currentState.windowID != windowID {
                fullScreenToggleState = nil
            } else {
                switch currentState {
                case .scheduled:
                    break
                case .awaitingTransition, .transitioning:
                    return false
                }
            }
        }

        prepareForFullScreen(window)
        let toggleID = UUID()
        fullScreenToggleState = .scheduled(
            requestID: toggleID,
            windowID: windowID
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
            guard fullScreenToggleState == .scheduled(
                requestID: toggleID,
                windowID: windowID
            ) else {
                return
            }
            guard let window, isMainWindow(window), window.isVisible else {
                fullScreenToggleState = nil
                return
            }
            // Enter the guarded state before calling AppKit because
            // windowWillEnter/ExitFullScreen may arrive synchronously.
            fullScreenToggleState = .awaitingTransition(
                requestID: toggleID,
                windowID: windowID
            )
            window.toggleFullScreen(nil)
            scheduleFullScreenTransitionStartRecovery(
                requestID: toggleID,
                windowID: windowID
            )
        }
        return true
    }

    static func fullScreenTransitionWillBegin(for window: NSWindow) {
        guard isMainWindow(window) else { return }
        fullScreenToggleState = .transitioning(
            windowID: ObjectIdentifier(window)
        )
    }

    static func fullScreenTransitionDidEnd(for window: NSWindow) {
        guard fullScreenToggleState?.windowID == ObjectIdentifier(window) else {
            return
        }
        fullScreenToggleState = nil
    }

    static func fullScreenTransitionDidFail(for window: NSWindow) {
        fullScreenTransitionDidEnd(for: window)
    }

    static func prepareForFullScreen(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        // SwiftUI may restore `.fullScreenNone` after the initial AppKit
        // window attachment. Repair the capability at the moment the user
        // requests full screen, after all scene-level window mutations.
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func scheduleFullScreenTransitionStartRecovery(
        requestID: UUID,
        windowID: ObjectIdentifier
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + fullScreenTransitionStartTimeout
        ) {
            guard fullScreenToggleState == .awaitingTransition(
                requestID: requestID,
                windowID: windowID
            ) else {
                return
            }
            // If AppKit declines the request and never emits a will-transition
            // callback, allow a later explicit retry instead of wedging the
            // control indefinitely. Once will-transition arrives, only the
            // matching did-transition callback releases the guard.
            fullScreenToggleState = nil
        }
    }

    static func ensureMainWindowVisible() {
        if bringExistingMainWindowToFront() {
            return
        }

        if triggerShowMainWindowCommand() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                _ = bringExistingMainWindowToFront()
            }
        }
    }

    static func scheduleLaunchActivationRecovery() {
        guard !JTSBackgroundLaunchPolicy.isBackgroundLaunch else { return }
        for delay in launchActivationRetryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                ensureMainWindowVisible()
            }
        }
    }

    static var hasVisibleMainWindow: Bool {
        NSApp.windows.contains { window in
            isMainWindow(window) && window.isVisible && !window.isMiniaturized
        }
    }

    @discardableResult
    static func triggerShowMainWindowCommand() -> Bool {
        let titles = [
            showMainWindowCommandTitle(language: .english),
            showMainWindowCommandTitle(language: .simplifiedChinese)
        ]
        guard let windowMenu = NSApp.mainMenu?.items.first(where: {
            $0.title == "Window" || $0.title == "窗口"
        })?.submenu,
              let item = windowMenu.items.first(where: { titles.contains($0.title) }),
              let action = item.action else {
            return false
        }

        return NSApp.sendAction(action, to: item.target, from: item)
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier == identifier || window.title == title
    }
}

#if JTS_UI_TEST_SUPPORT
/// Keeps UI fixtures deterministic without changing production resizing. A
/// min-only one-shot is insufficient because SwiftUI may restore its preferred
/// content size later in launch; matching max bounds prevent that second grow.
@MainActor
private enum UITestMainWindowSizeStabilizer {
    private static let launchRetryDelays: [TimeInterval] = [0, 0.15, 0.5, 1]

    static func scheduleIfRequested(
        to window: NSWindow,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard environment[UITestSSHSessionEnvironment.isUITestingKey] == "1" else {
            return
        }

        for delay in launchRetryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window else { return }
                apply(to: window, environment: environment)
            }
        }
    }

    private static func apply(
        to window: NSWindow,
        environment: [String: String]
    ) {

        let requestedContentSize: CGSize
        #if ENABLE_RDP_2
        requestedContentSize = UITestRDPFixtureEnvironment.requestsNarrowWindow(
            environment: environment
        )
            ? MainWindowSizePolicy.minimumContentSize
            : MainWindowSizePolicy.preferredContentSize
        #else
        requestedContentSize = MainWindowSizePolicy.preferredContentSize
        #endif

        let requestedFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: requestedContentSize)
        ).size
        let targetFrameSize = MainWindowSizePolicy.boundedFrameSize(
            requestedFrameSize,
            minimumSize: MainWindowSizePolicy.minimumFrameSize(for: window),
            maximumSize: (window.screen ?? NSScreen.main)?.visibleFrame.size
        )
        let targetContentSize = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: targetFrameSize)
        ).size

        func installFixedBounds() {
            window.isRestorable = false
            window.contentMinSize = targetContentSize
            window.contentMaxSize = targetContentSize
            window.minSize = targetFrameSize
            window.maxSize = targetFrameSize
        }
        installFixedBounds()

        var targetFrame = window.frame
        targetFrame.origin.y = targetFrame.maxY - targetFrameSize.height
        targetFrame.size = targetFrameSize
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            targetFrame = MainWindowSizePolicy.constrainedFrame(
                targetFrame,
                toVisibleFrame: visibleFrame
            )
        }
        window.setFrame(targetFrame, display: true, animate: false)
        // SwiftUI updates the hosting window's content constraints from inside
        // the resize transaction. Reinstall the UI-fixture bounds after that
        // synchronous layout pass so the restored preferred size cannot win.
        installFixedBounds()
    }
}
#endif

@MainActor
enum MCPMenuActions {
    static func perform(
        _ client: MCPClientKind,
        status: MCPClientRegistrationStatus,
        language: AppLanguage
    ) {
        configure(client, language: language)
    }

    /// Removes the jts-terminal entry from the client's configuration and
    /// revokes its registration ID after the user confirms.
    static func remove(_ client: MCPClientKind, language: AppLanguage) {
        let registrar = MCPClientRegistrar()
        let configurationURL = registrar.defaultConfigURL(for: client).standardizedFileURL
        let sharedNote = client.configurationEndpoint == .codex
            ? language.localized(
                " Codex Desktop and Codex CLI share this file, so both lose JTS tools.",
                " Codex Desktop 与 Codex CLI 共用这个文件，两者都会失去 JTS 工具。"
            )
            : ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = language.localized(
            "Remove JTS Terminal from \(client.displayName)?",
            "要从 \(client.displayName) 移除 JTS Terminal 吗？"
        )
        alert.informativeText = language.localized(
            "JTS Terminal removes the jts-terminal entry from \(configurationURL.path) and stops accepting this client's registration.\(sharedNote) A copy of the current file is kept as \(MCPClientRegistrar.backupURL(for: configurationURL).lastPathComponent).",
            "JTS Terminal 会从 \(configurationURL.path) 删除 jts-terminal 条目，并不再接受该客户端的注册。\(sharedNote)当前文件会另存一份 \(MCPClientRegistrar.backupURL(for: configurationURL).lastPathComponent)。"
        )
        alert.addButton(withTitle: language.localized("Remove", "移除"))
        alert.addButton(withTitle: language.localized("Cancel", "取消"))
        alert.buttons.first?.setAccessibilityIdentifier("mcp-registration-remove-button")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let scoped = registrar.configurationAccessStore.withAccess(for: client) { url in
            Result { try registrar.unregister(client, destinationURL: url) }
        }
        let outcome: Result<Bool, Error>
        if case .value(let result) = scoped {
            outcome = result
        } else {
            outcome = Result { try registrar.unregister(client, destinationURL: configurationURL) }
        }
        MCPClientRegistrationStatusRefresh.bump()
        switch outcome {
        case .success:
            showAlert(
                title: language.localized("Registration Removed", "已移除注册"),
                message: language.localized(
                    "Restart \(client.displayName) or start a new session so it stops loading JTS Terminal.",
                    "请重启 \(client.displayName) 或开启新会话，使其不再加载 JTS Terminal。"
                ),
                language: language,
                style: .informational
            )
        case .failure(let error):
            showAlert(
                title: language.localized("Registration Not Removed", "未能移除注册"),
                message: error.localizedDescription,
                language: language,
                style: .warning
            )
        }
    }

    /// Recovery for a damaged registry: moves it aside so each client can be
    /// configured again. Client configuration files are not changed.
    static func resetRegistrations(language: AppLanguage) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = language.localized(
            "Reset MCP client registrations?",
            "要重置 MCP 客户端注册吗？"
        )
        alert.informativeText = language.localized(
            "Every AI client loses access to JTS Terminal until you configure it again from the MCP menu. Client configuration files are not changed, and the old records are kept aside.",
            "所有 AI 客户端都会失去对 JTS Terminal 的访问，直到你从 MCP 菜单重新配置。客户端配置文件不会被修改，旧记录会另行保留。"
        )
        alert.addButton(withTitle: language.localized("Reset", "重置"))
        alert.addButton(withTitle: language.localized("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let registrar = MCPClientRegistrar()
            try registrar.registrationRegistry.moveAside()
            try registrar.registrationEvidenceStore.moveAside()
            MCPClientRegistrationStatusRefresh.bump()
            showAlert(
                title: language.localized("Registrations Reset", "注册已重置"),
                message: language.localized(
                    "Configure each AI client again from the MCP menu, then restart it.",
                    "请从 MCP 菜单重新配置每个 AI 客户端，然后重启它们。"
                ),
                language: language,
                style: .informational
            )
        } catch {
            showAlert(
                title: language.localized("Reset Failed", "重置失败"),
                message: error.localizedDescription,
                language: language,
                style: .warning
            )
        }
    }

    static func configure(
        _ client: MCPClientKind,
        language: AppLanguage
    ) {
        let commandPath = MCPClientConfiguration.commandPath()
        let registrar = MCPClientRegistrar()
        var configurationURL = registrar.defaultConfigURL(for: client)
        #if JTS_UI_TEST_SUPPORT
        configurationURL = UITestMCPRegistrationEnvironment
            .canonicalConfigurationURL() ?? configurationURL
        #endif
        configurationURL = configurationURL.standardizedFileURL

        if let storedPath = registrar.configurationAccessStore
            .storedPath(for: client),
           URL(fileURLWithPath: storedPath).standardizedFileURL
            != configurationURL {
            try? registrar.configurationAccessStore.removeAccess(
                for: client
            )
        }

        // The user confirms the exact change once; a later attempt after a
        // folder authorization asks again only if the change differs.
        var confirmedDiff: String?
        let confirm: (MCPClientRegistrationPreview) -> Bool = { preview in
            if preview.focusedDiff == confirmedDiff { return true }
            guard confirmRegistration(preview, language: language) else { return false }
            confirmedDiff = preview.focusedDiff
            return true
        }

        let scopedAccess = registrar.configurationAccessStore.withAccess(
            for: client
        ) { destination in
            Result {
                try requireCanonicalConfigurationURL(
                    destination,
                    expected: configurationURL
                )
                return try installRegistration(
                    for: client,
                    commandPath: commandPath,
                    destination: configurationURL,
                    registrar: registrar,
                    confirm: confirm
                )
            }
        }
        if case .value(let result) = scopedAccess {
            switch result {
            case .success(let registration):
                finishRegistration(
                    registration,
                    registrar: registrar,
                    language: language
                )
                return
            case .failure(let error):
                if error is CancellationError {
                    return
                }
                if isUnexpectedConfigurationAuthorization(error) {
                    try? registrar.configurationAccessStore.removeAccess(
                        for: client
                    )
                    break
                }
                if !MCPClientConfigurationAuthorizationErrorClassifier
                    .requiresAuthorization(error) {
                    showRegistrationFailure(error, language: language)
                    return
                }
            }
        }

        do {
            let registration = try installRegistration(
                for: client,
                commandPath: commandPath,
                destination: configurationURL,
                registrar: registrar,
                confirm: confirm
            )
            finishRegistration(registration, registrar: registrar, language: language)
            return
        } catch is CancellationError {
            return
        } catch {
            guard MCPClientConfigurationAuthorizationErrorClassifier
                .requiresAuthorization(error) else {
                showRegistrationFailure(error, language: language)
                return
            }
        }

        let authorizedDirectory: URL
        do {
            guard let selectedDirectory =
                authorizeCanonicalConfigurationDirectory(
                    for: client,
                    configurationURL: configurationURL,
                    registrar: registrar,
                    language: language
                ) else {
                return
            }
            authorizedDirectory = try registrar
                .validateCanonicalConfigurationDirectory(
                    selectedDirectory,
                    for: configurationURL
                )
        } catch {
            showRegistrationFailure(error, language: language)
            return
        }

        let didStartAccess = authorizedDirectory
            .startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                authorizedDirectory.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let registration = try installRegistration(
                for: client,
                commandPath: commandPath,
                destination: configurationURL,
                registrar: registrar,
                confirm: confirm
            )
            let preparedAccess = try registrar
                .configurationAccessStore
                .prepareAccess(
                    for: client,
                    configurationURL: configurationURL,
                    scopeURL: authorizedDirectory
                )
            try registrar.configurationAccessStore.persist(preparedAccess)
            finishRegistration(registration, registrar: registrar, language: language)
        } catch is CancellationError {
            return
        } catch {
            showRegistrationFailure(error, language: language)
        }
    }

    static func copyConfig(language: AppLanguage) {
        guard MCPClientRegistrar.allowsUnregisteredDirectConfiguration else {
            showAlert(
                title: language.localized("Registered MCP Client Required", "需要已注册的 MCP 客户端"),
                message: language.localized(
                    "JTS Terminal 2.0 configures named MCP clients automatically. Choose Configure for Claude, Cursor, Codex, Grok CLI, or Antigravity; JTS Terminal will determine the canonical endpoint, preserve unrelated settings, and request one macOS authorization only when required.",
                    "JTS Terminal 2.0 会自动配置指定的 MCP 客户端。请为 Claude、Cursor、Codex、Grok CLI 或 Antigravity 选择“配置”；JTS Terminal 会确定标准端点、保留无关设置，并仅在 macOS 必须授权时请求一次系统许可。"
                ),
                language: language,
                style: .warning
            )
            return
        }
        let appCommandPath = MCPClientConfiguration.commandPath()
        let text = MCPClientConfiguration.stdioJSONText(
            commandPath: appCommandPath,
            arguments: MCPClientRegistrar.directArguments
        )
        copy(text)
        showAlert(
            title: language.localized("MCP Config Copied", "MCP 配置已复制"),
            message: language.localized(
                "Copied a direct stdio configuration using the complete executable path and --mcp argument. No proxy or configuration file was created.",
                "已复制使用完整可执行文件路径和 --mcp 参数的直连 stdio 配置；未创建代理脚本，也未修改配置文件。"
            ),
            language: language,
            style: .informational
        )
    }

    private static func installRegistration(
        for client: MCPClientKind,
        commandPath: String,
        destination: URL,
        registrar: MCPClientRegistrar,
        confirm: (MCPClientRegistrationPreview) -> Bool
    ) throws -> MCPClientRegistrationResult {
        let preview = try registrar.registrationPreview(
            for: client,
            commandPath: commandPath,
            destinationURL: destination
        )
        guard confirm(preview) else { throw CancellationError() }
        return try registrar.register(preview)
    }

    /// Shows the exact entry change before anything is written.
    private static func confirmRegistration(
        _ preview: MCPClientRegistrationPreview,
        language: AppLanguage
    ) -> Bool {
        let backupName = MCPClientRegistrar.backupURL(for: preview.destinationURL).lastPathComponent
        let rewritesJSON = preview.client.configurationEndpoint != .codex
            && preview.client != .grokCLI
        var details = language.localized(
            "JTS Terminal will add or update only the jts-terminal entry in \(preview.destinationURL.path). Other servers and settings stay as they are.",
            "JTS Terminal 只会在 \(preview.destinationURL.path) 中添加或更新 jts-terminal 条目，其他服务器和设置保持不变。"
        )
        if preview.configurationSnapshot.exists {
            details += language.localized(
                " A copy of the current file is kept as \(backupName).",
                " 当前文件会另存一份 \(backupName)。"
            )
            if rewritesJSON {
                details += language.localized(
                    " The file is saved with sorted keys and standard indentation; values are unchanged.",
                    " 文件会按键名排序并使用标准缩进保存，内容值不变。"
                )
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = language.localized(
            "Configure \(preview.client.displayName)?",
            "要配置 \(preview.client.displayName) 吗？"
        )
        alert.informativeText = details

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        textView.string = preview.focusedDiff
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.setAccessibilityIdentifier("mcp-registration-diff")
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        alert.accessoryView = scrollView

        alert.addButton(withTitle: language.localized("Configure", "配置"))
        alert.addButton(withTitle: language.localized("Cancel", "取消"))
        alert.buttons.first?.setAccessibilityIdentifier("mcp-registration-confirm-button")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func finishRegistration(
        _ registration: MCPClientRegistrationResult,
        registrar: MCPClientRegistrar,
        language: AppLanguage
    ) {
        UserDefaults.standard.set(
            true,
            forKey: TerminalMCPBridgeLaunchPolicy.userDefaultsKey
        )
        MCPClientRegistrationStatusRefresh.bump()
        let title = language.localized("MCP Configured", "MCP 配置完成")
        let message = registration.displayMessage(language: language)
        if registration.client == .claudeCLI,
           claudeCodeAllowsAllTools(registrar: registrar) == false {
            offerClaudeCodeToolAllowRule(
                title: title,
                leadingMessage: message,
                registrar: registrar,
                language: language
            )
            return
        }
        showAlert(
            title: title,
            message: message,
            language: language,
            style: .informational
        )
    }

    /// Menu entry for a Claude CLI registration made earlier.
    static func allowAllToolsInClaudeCode(language: AppLanguage) {
        let registrar = MCPClientRegistrar()
        if claudeCodeAllowsAllTools(registrar: registrar) == true {
            showAlert(
                title: language.localized("Already Allowed", "已允许"),
                message: language.localized(
                    "Claude Code already runs JTS Terminal tools without asking (\(MCPClientRegistrar.claudeCodeToolAllowRule) in ~/.claude/settings.json).",
                    "Claude Code 已经无需确认即可使用 JTS Terminal 工具（~/.claude/settings.json 中已有 \(MCPClientRegistrar.claudeCodeToolAllowRule)）。"
                ),
                language: language,
                style: .informational
            )
            return
        }
        offerClaudeCodeToolAllowRule(
            title: language.localized(
                "Allow JTS Terminal Tools in Claude Code",
                "在 Claude Code 中允许 JTS Terminal 工具"
            ),
            leadingMessage: nil,
            registrar: registrar,
            language: language
        )
    }

    /// Whether Claude Code already runs JTS tools without asking; nil when
    /// its settings cannot be read.
    static func claudeCodeToolsAllowed() -> Bool? {
        claudeCodeAllowsAllTools(registrar: MCPClientRegistrar())
    }

    /// Reads Claude Code's user settings within the Claude CLI folder grant.
    /// Returns nil when the settings cannot be read.
    private static func claudeCodeAllowsAllTools(registrar: MCPClientRegistrar) -> Bool? {
        let scoped = registrar.configurationAccessStore.withAccess(for: .claudeCLI) { configurationURL in
            try? registrar.claudeCodeAllowsAllTools(
                settingsURL: MCPClientRegistrar.claudeCodeSettingsURL(
                    besideClaudeCLIConfiguration: configurationURL
                )
            )
        }
        if case .value(let allowed) = scoped {
            return allowed
        }
        return try? registrar.claudeCodeAllowsAllTools()
    }

    private static func offerClaudeCodeToolAllowRule(
        title: String,
        leadingMessage: String?,
        registrar: MCPClientRegistrar,
        language: AppLanguage
    ) {
        let offer = language.localized(
            "Claude Code asks before every JTS Terminal tool call. Allow all JTS Terminal tools without asking? This adds \"\(MCPClientRegistrar.claudeCodeToolAllowRule)\" to permissions.allow in ~/.claude/settings.json for every project. Claude Code will then run commands and change or delete files on your MCP-enabled servers without confirming each call. JTS Terminal's own server, pane and Windows permissions still apply. You can remove the rule later with /permissions in Claude Code.",
            "Claude Code 每次调用 JTS Terminal 工具前都会询问。要允许所有 JTS Terminal 工具无需确认吗？这会在 ~/.claude/settings.json 的 permissions.allow 中加入 \"\(MCPClientRegistrar.claudeCodeToolAllowRule)\"，对所有项目生效。之后 Claude Code 在已启用 MCP 的服务器上执行命令、修改或删除文件时都不会再逐次确认。JTS Terminal 自身的服务器、窗格和 Windows 权限仍然有效。以后可在 Claude Code 中用 /permissions 删除这条规则。"
        )
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = [leadingMessage, offer]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: language.localized("Keep Asking", "继续询问"))
        alert.addButton(withTitle: language.localized("Allow All Tools", "全部允许"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let scoped = registrar.configurationAccessStore.withAccess(for: .claudeCLI) { configurationURL in
            Result {
                try registrar.allowAllToolsInClaudeCode(
                    settingsURL: MCPClientRegistrar.claudeCodeSettingsURL(
                        besideClaudeCLIConfiguration: configurationURL
                    )
                )
            }
        }
        let outcome: Result<Bool, Error>
        if case .value(let result) = scoped {
            outcome = result
        } else {
            outcome = Result { try registrar.allowAllToolsInClaudeCode() }
        }

        switch outcome {
        case .success:
            showAlert(
                title: language.localized("Claude Code Updated", "Claude Code 已更新"),
                message: language.localized(
                    "Claude Code now runs JTS Terminal tools without asking. Start a new Claude Code session to apply it.",
                    "Claude Code 现在无需确认即可使用 JTS Terminal 工具。请开启新的 Claude Code 会话以生效。"
                ),
                language: language,
                style: .informational
            )
        case .failure(let error):
            showAlert(
                title: language.localized("Claude Code Not Updated", "未能更新 Claude Code"),
                message: language.localized(
                    "\(error.localizedDescription)\n\nYou can add the rule yourself: run /permissions in Claude Code and allow \(MCPClientRegistrar.claudeCodeToolAllowRule).",
                    "\(error.localizedDescription)\n\n也可以手动添加：在 Claude Code 中运行 /permissions，允许 \(MCPClientRegistrar.claudeCodeToolAllowRule)。"
                ),
                language: language,
                style: .warning
            )
        }
    }

    private static func showRegistrationFailure(
        _ error: Error,
        language: AppLanguage
    ) {
        showAlert(
            title: language.localized(
                "MCP Configuration Failed",
                "MCP 配置失败"
            ),
            message: error.localizedDescription,
            language: language,
            style: .warning
        )
    }

    private static func authorizeCanonicalConfigurationDirectory(
        for client: MCPClientKind,
        configurationURL: URL,
        registrar: MCPClientRegistrar,
        language: AppLanguage
    ) -> URL? {
        let expectedDirectory = configurationURL
            .standardizedFileURL
            .deletingLastPathComponent()
        do {
            _ = try registrar.validateCanonicalConfigurationDirectory(
                expectedDirectory,
                for: configurationURL
            )
        } catch {
            showRegistrationFailure(error, language: language)
            return nil
        }

        let panel = NSOpenPanel()
        panel.title = language.localized(
            "Allow JTS Terminal to Configure \(client.displayName)",
            "允许 JTS Terminal 配置 \(client.displayName)"
        )
        panel.prompt = language.localized("Allow", "允许")
        panel.message = language.localized(
            "JTS Terminal already determined the official configuration folder. Click Allow once; JTS Terminal will preserve unrelated settings and will not accept another folder.",
            "JTS Terminal 已自动确定官方配置目录。只需点击一次“允许”；JTS Terminal 会保留无关设置，也不会接受其他目录。"
        )
        panel.directoryURL = expectedDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func isUnexpectedConfigurationAuthorization(
        _ error: Error
    ) -> Bool {
        guard let registrationError =
            error as? MCPClientRegistrationError else {
            return false
        }
        if case .unexpectedConfigurationAuthorization =
            registrationError {
            return true
        }
        return false
    }

    private static func requireCanonicalConfigurationURL(
        _ actualURL: URL,
        expected expectedURL: URL
    ) throws {
        let actual = actualURL.standardizedFileURL
        let expected = expectedURL.standardizedFileURL
        guard actual == expected else {
            throw MCPClientRegistrationError
                .unexpectedConfigurationAuthorization(
                    expectedDirectory: expected
                        .deletingLastPathComponent()
                        .path,
                    selectedDirectory: actual
                        .deletingLastPathComponent()
                        .path
                )
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func showAlert(
        title: String,
        message: String,
        language: AppLanguage,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: language.localized("OK", "好"))
        alert.runModal()
    }
}

struct PersistenceNotice: Equatable {
    enum Kind: Equatable {
        /// An unreadable store was moved aside and replaced by a new one.
        case recovered(backupName: String)
        /// No persistent store could be opened; changes are not saved.
        case temporary(recoveryError: String)
    }

    var kind: Kind
    var originalError: String

    /// English text for diagnostics written to standard error.
    var title: String { localizedTitle(language: .english) }
    var message: String { localizedMessage(language: .english) }

    func localizedTitle(language: AppLanguage) -> String {
        switch kind {
        case .recovered:
            return language.localized("Local data store recovered", "已恢复本地数据存储")
        case .temporary:
            return language.localized("Server data is temporary", "服务器数据暂未保存")
        }
    }

    func localizedMessage(language: AppLanguage) -> String {
        switch kind {
        case .recovered(let backupName):
            return language.localized(
                "JTS Terminal reset an unreadable local data store and created a fresh persistent store. The old store was moved to \(backupName). Original error: \(originalError)",
                "JTS Terminal 重置了无法读取的本地数据存储并新建了存储。旧数据已移至 \(backupName)。原始错误：\(originalError)"
            )
        case .temporary(let recoveryError):
            return language.localized(
                "JTS Terminal persistent store failed, using a temporary in-memory store. Server changes will not persist until this is fixed. Original error: \(originalError). Recovery error: \(recoveryError)",
                "JTS Terminal 无法打开持久存储，正在使用临时内存存储。在问题解决前，服务器更改不会被保存。原始错误：\(originalError)。恢复错误：\(recoveryError)"
            )
        }
    }
}

enum ModelContainerFactory {
    private(set) static var persistenceNotice: PersistenceNotice?

    static let schema = Schema([
        RemoteSession.self,
        SavedSSHTunnel.self,
        CommandHistoryEntry.self,
        SavedCommandMacro.self,
        RemoteTransferTask.self,
        MCPAuditEntry.self,
    ])

    static func makeSharedContainer() -> ModelContainer {
        persistenceNotice = nil

        #if JTS_UI_TEST_SUPPORT
        if UnitTestHostPolicy.shouldUseInMemoryModelStore {
            do {
                return try makeContainer(isStoredInMemoryOnly: true)
            } catch {
                preconditionFailure("Could not create testing in-memory ModelContainer: \(error)")
            }
        }
        #endif

        do {
            return try makePersistentContainer()
        } catch {
            let firstError = error
            do {
                let backupURL = try quarantinePersistentStore()
                let container = try makePersistentContainer()
                if let backupURL {
                    let notice = PersistenceNotice(
                        kind: .recovered(backupName: backupURL.lastPathComponent),
                        originalError: firstError.localizedDescription
                    )
                    persistenceNotice = notice
                    fputs("\(notice.title): \(notice.message)\n", stderr)
                }
                return container
            } catch {
                let notice = PersistenceNotice(
                    kind: .temporary(recoveryError: error.localizedDescription),
                    originalError: firstError.localizedDescription
                )
                persistenceNotice = notice
                fputs("\(notice.title): \(notice.message)\n", stderr)
                return makeInMemoryFallback()
            }
        }
    }

    static func quarantinePersistentStore(
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL? {
        let storeURL = try persistentStoreURL()
        return try quarantinePersistentStoreFiles(
            storeURL: storeURL,
            now: now,
            fileManager: fileManager
        )
    }

    static func quarantinePersistentStoreFiles(
        storeURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL? {
        let candidateURLs = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]

        let existingURLs = candidateURLs.filter {
            fileManager.fileExists(atPath: $0.path)
        }
        guard !existingURLs.isEmpty else { return nil }

        let backupRoot = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("JTS Terminal Store Backups", isDirectory: true)
        let backupDirectory = backupRoot
            .appendingPathComponent(backupTimestamp(for: now), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )

        for url in existingURLs {
            try fileManager.moveItem(
                at: url,
                to: backupDirectory.appendingPathComponent(url.lastPathComponent)
            )
        }

        return backupDirectory
    }

    private static func backupTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func makeContainer(isStoredInMemoryOnly: Bool) throws -> ModelContainer {
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly)
        return try ModelContainer(for: schema, configurations: [modelConfiguration])
    }

    static func makePersistentContainer() throws -> ModelContainer {
        let storeURL = try persistentStoreURL()
        let modelConfiguration = ModelConfiguration(
            "JTS Terminal",
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
        return try ModelContainer(for: schema, configurations: [modelConfiguration])
    }

    static func persistentStoreURL(
        applicationSupportDirectory: URL? = nil
    ) throws -> URL {
        let supportDirectory: URL
        if let applicationSupportDirectory {
            supportDirectory = applicationSupportDirectory
        } else {
            supportDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }

        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        return supportDirectory.appendingPathComponent("JTS Terminal.store")
    }

    private static func makeInMemoryFallback() -> ModelContainer {
        do {
            return try makeContainer(isStoredInMemoryOnly: true)
        } catch {
            preconditionFailure("Could not create in-memory ModelContainer: \(error)")
        }
    }

}

#if JTS_UI_TEST_SUPPORT
private struct UnitTestHostView: View {
    var body: some View {
        let language = AppLanguage.stored

        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            Text(language.localized(
                "Running JTS Terminal 2.0 automated tests",
                "正在运行 JTS Terminal 2.0 自动化测试"
            ))
            .font(.headline)

            Text(language.localized(
                "This test-only window will close automatically.",
                "此窗口仅用于测试，完成后会自动关闭。"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("unit-test-host-status")
    }
}

nonisolated enum UnitTestHostPolicy {
    static var isActive: Bool {
        isActive(environment: ProcessInfo.processInfo.environment)
    }

    static var shouldUseInMemoryModelStore: Bool {
        shouldUseInMemoryModelStore(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func isActive(environment: [String: String]) -> Bool {
        environment["XCTestBundlePath"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
    }

    static func shouldUseInMemoryModelStore(
        environment: [String: String],
        arguments: [String] = []
    ) -> Bool {
        isActive(environment: environment)
            || environment[UITestSSHSessionEnvironment.isUITestingKey] == "1"
            || SignedAskpassHostedSelfTest.requestToken(arguments: arguments) != nil
    }
}
#endif
