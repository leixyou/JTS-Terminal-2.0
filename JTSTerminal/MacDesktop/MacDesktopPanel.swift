#if ENABLE_RDP_2
import SwiftData
import SwiftUI

struct MacDesktopPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var session: RemoteSession
    @ObservedObject var workspace: MacDesktopWorkspaceState
    @State private var hasInputFocus = false
    @State private var showsPairing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(workspace.hostName, systemImage: "display.2")
                    .font(.headline)
                    .lineLimit(1)
                Text(workspace.status.title)
                    .font(.caption)
                    .foregroundStyle(workspace.isConnected ? .green : .secondary)
                    .accessibilityIdentifier("mac-desktop-status")
                Spacer()
                if workspace.hasSavedPairing {
                    Toggle("自动重连", isOn: Binding(get: { workspace.autoReconnect }, set: workspace.setAutoReconnect))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("打开此 Mac 配置时自动连接；网络中断后使用已批准的设备凭证重连。断开或取消会停止本次重连。")
                        .accessibilityIdentifier("mac-desktop-auto-reconnect-toggle")
                }
                if workspace.isConnected {
                    Toggle("控制", isOn: $workspace.controlsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!workspace.canControl)
                        .help("关闭后只查看桌面；键盘和鼠标留在当前 Mac。")
                    Button("断开", systemImage: "xmark.circle") { workspace.disconnect() }
                        .accessibilityIdentifier("mac-desktop-disconnect-button")
                } else if workspace.isBusy {
                    ProgressView().controlSize(.small)
                    Button("取消") { workspace.disconnect() }
                } else if workspace.hasSavedPairing {
                    Button("连接桌面", systemImage: "display.2") { connect() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mac-desktop-connect-button")
                }
                Button("配对", systemImage: "link") { showsPairing.toggle() }
                    .help("连接新的 Mac 或管理保存在 加密凭据库中的配对。")
            }
            .padding(10)
            Divider()

            if let error = workspace.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("mac-desktop-error")
            }
            if let notice = workspace.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if showsPairing || (!workspace.hasSavedPairing && !workspace.isConnected) {
                MacDesktopPairingPanel(session: session, workspace: workspace)
                    .padding(16)
                Divider()
            }

            if let image = workspace.image {
                MacDesktopSurface(
                    image: image,
                    acceptsInput: workspace.acceptsInput,
                    onInput: workspace.send,
                    onRelease: workspace.releaseInput,
                    onFocusChange: { hasInputFocus = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("mac-desktop-surface")
            } else {
                VStack(spacing: 12) {
                    if workspace.isBusy || workspace.isConnected {
                        ProgressView()
                        Text(workspace.status == .awaitingApproval ? "请在对方 Mac 点击批准。" : workspace.status == .reconnecting ? "正在等待重连对方 Mac…" : "等待对方 Mac 的桌面画面…")
                    } else {
                        Image(systemName: "display.2").font(.system(size: 42)).foregroundStyle(.secondary)
                        Text("把另一台 Mac 放进当前工作区")
                            .font(.title3.weight(.medium))
                        Text("在 Mac mini 安装并开启 JTS Mac Companion，将它的配对邀请粘贴到这里。")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack(spacing: 10) {
                Label(inputStatus, systemImage: hasInputFocus ? "keyboard" : "cursorarrow")
                Spacer()
                if workspace.frameSize.width > 0 {
                    Text("\(Int(workspace.frameSize.width)) × \(Int(workspace.frameSize.height))")
                }
                Label("加密连接", systemImage: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { workspace.prepare(for: session) }
        .onChange(of: session.connectionKey) { _, _ in workspace.prepare(for: session) }
        .onChange(of: workspace.controlsEnabled) { _, enabled in if !enabled { workspace.releaseInput() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { workspace.releaseInput() } }
        .onDisappear { workspace.releaseInput() }
    }

    private var inputStatus: String {
        if workspace.isConnected && !workspace.canControl { return "仅查看 · 在对方 Mac 授予辅助功能权限后可控制" }
        if !workspace.controlsEnabled { return "仅查看桌面" }
        return hasInputFocus ? "键盘正在控制对方 · Control Option Esc 释放" : "点击桌面控制对方 Mac"
    }

    private func connect() { workspace.connect(session: session, persistEndpoint: { try modelContext.save() }) }
}

struct MacDesktopPairingPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var session: RemoteSession
    @ObservedObject var workspace: MacDesktopWorkspaceState
    @State private var confirmsForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Mac 桌面配对", systemImage: "link")
                .font(.headline)
            Text("在对方 Mac 开启 Companion 共享，复制配对邀请。首次连接需要对方 Mac 批准；之后可使用保存在 加密凭据库的设备凭证重新连接。")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("粘贴 jtsmac:// 配对邀请", text: $workspace.invitationCode)
                .textFieldStyle(.roundedBorder)
                .disabled(workspace.isBusy || workspace.isConnected)
                .onSubmit(connect)
                .accessibilityIdentifier("mac-desktop-invitation-field")
            HStack {
                Button("配对并连接", systemImage: "display.2", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.invitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isBusy || workspace.isConnected)
                    .accessibilityIdentifier("mac-desktop-pair-button")
                if workspace.hasSavedPairing {
                    Label("已保存设备配对", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("忘记配对", role: .destructive) { confirmsForget = true }
                        .disabled(workspace.isBusy && workspace.status != .reconnecting)
                }
            }
            Text("邀请包含临时配对密钥。请通过可信方式传递；邀请和设备凭证均不会进入配置导出。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { workspace.prepare(for: session) }
        .confirmationDialog("从此 Mac 移除配对？", isPresented: $confirmsForget) {
            Button("忘记配对", role: .destructive) { workspace.forgetPairing(session: session) }
        } message: {
            Text("当前连接将断开。之后连接需要对方 Mac 重新生成邀请并批准。")
        }
    }

    private func connect() { workspace.connect(session: session, persistEndpoint: { try modelContext.save() }) }
}

#endif
