#if ENABLE_RDP_2
import AppKit
import SwiftUI

struct RDPDesktopLauncher: View {
    let target: RemoteSession
    let openProperties: () -> Void
    @Environment(\.appLanguage) private var language
    @ObservedObject private var windows = RDPDesktopWindowCoordinator.shared
    @ObservedObject private var runtime = RDPDesktopRuntimeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(target.name, systemImage: "desktopcomputer").font(.title2)
            Text(language.localized(
                "Open this Windows workspace in its own window. Closing that window keeps the connection and authorized work running; use Disconnect to end the desktop session.",
                "在独立窗口中打开此 Windows 工作区。关闭窗口会保留连接和已授权的工作；使用“断开”结束桌面会话。"))
                .foregroundStyle(.secondary)
            HStack {
                Button(language.localized("Open Desktop Window", "打开桌面窗口")) {
                    windows.open(target, openProperties: openProperties)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("rdp-open-window-button")
                Button(language.localized("Server Properties", "服务器属性"), action: openProperties)
            }
            if let state = runtime.statesByTargetID[target.targetID] {
                Text(state.phase.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RDPDesktopMenu: View {
    @ObservedObject private var windows = RDPDesktopWindowCoordinator.shared
    @ObservedObject private var runtime = RDPDesktopRuntimeStore.shared
    @Environment(\.appLanguage) private var language

    var body: some View {
        if windows.targets.isEmpty {
            Text(language.localized("No Windows desktops open", "尚未打开 Windows 桌面"))
        }
        ForEach(windows.targets, id: \.targetID) { target in
            let presentation = runtime.presentation(for: target)
            Menu(target.name) {
                if presentation.isAIControlActive {
                    Text(language.localized("AI is controlling this desktop", "AI 正在操作此桌面"))
                } else if presentation.isAIViewing {
                    Text(language.localized("AI is viewing this desktop", "AI 正在查看此桌面"))
                }
                Button(language.localized("Show Desktop", "显示桌面")) { windows.show(targetID: target.targetID) }
                Button(language.localized("Take Control", "接管")) { presentation.takeManualControl?() }
                Button(language.localized("Emergency Stop", "紧急停止")) { presentation.emergencyStop?() }
                Divider()
                Button(language.localized("Disconnect", "断开")) { presentation.disconnect?() }
            }
        }
        Divider()
        Button(language.localized("Show JTS Terminal", "显示 JTS Terminal")) {
            MainWindowLifecycle.ensureMainWindowVisible()
        }
    }
}

struct RDPDesktopMenuLabel: View {
    @ObservedObject private var windows = RDPDesktopWindowCoordinator.shared
    @ObservedObject private var runtime = RDPDesktopRuntimeStore.shared
    var body: some View {
        let activeCount = windows.targets.filter {
            let state = runtime.presentation(for: $0)
            return state.isAIControlActive || state.isAIViewing || state.isAIControlStopping
        }.count
        Label(activeCount > 0 ? "JTS · AI \(activeCount)" : "JTS", systemImage: "desktopcomputer")
    }
}

/// Strong application lifetime for the bridge and workspace models. SwiftUI
/// view disappearance must not stop background desktops or drop the MCP bridge.
@MainActor
final class ApplicationWorkspaceRuntime {
    static let shared = ApplicationWorkspaceRuntime()
    let terminals = TerminalWorkspaceStore()
    let broadcasts = TerminalBroadcastCoordinator()
    let tunnels = SSHTunnelManagerStore()
    let files = RemoteFilesWorkspaceStore()
    let transfers = RemoteTransferQueueManager()
    let bridge = TerminalMCPBridgeServer()
    private init() {}
}
#endif
