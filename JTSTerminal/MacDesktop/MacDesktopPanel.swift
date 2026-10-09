#if ENABLE_RDP_2
import SwiftData
import SwiftUI

struct MacDesktopPanel: View {
    @Environment(\.appLanguage) private var language
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
                    Toggle(language.localized("Auto Reconnect", "自动重连"), isOn: Binding(get: { workspace.autoReconnect }, set: workspace.setAutoReconnect))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(language.localized(
                            "Connects when this Mac profile opens and reconnects with the approved device credential after network interruptions. Disconnect or Cancel stops reconnecting.",
                            "打开此 Mac 配置时自动连接；网络中断后使用已批准的设备凭证重连。断开或取消会停止本次重连。"
                        ))
                        .accessibilityIdentifier("mac-desktop-auto-reconnect-toggle")
                }
                if workspace.isConnected {
                    Toggle(language.localized("Control", "控制"), isOn: $workspace.controlsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!workspace.canControl)
                        .help(language.localized(
                            "When off, you only view the desktop; keyboard and mouse stay on this Mac.",
                            "关闭后只查看桌面；键盘和鼠标留在当前 Mac。"
                        ))
                    Button(language.localized("Disconnect", "断开"), systemImage: "xmark.circle") { workspace.disconnect() }
                        .accessibilityIdentifier("mac-desktop-disconnect-button")
                } else if workspace.isBusy {
                    ProgressView().controlSize(.small)
                    Button(language.localized("Cancel", "取消")) { workspace.disconnect() }
                } else if workspace.hasSavedPairing {
                    Button(language.localized("Connect Desktop", "连接桌面"), systemImage: "display.2") { connect() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mac-desktop-connect-button")
                }
                Button(language.localized("Pairing", "配对"), systemImage: "link") { showsPairing.toggle() }
                    .help(language.localized(
                        "Connect a new Mac or manage the pairing saved in the encrypted vault.",
                        "连接新的 Mac 或管理保存在加密凭据库中的配对。"
                    ))
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
                        Text(waitingMessage)
                    } else {
                        Image(systemName: "display.2").font(.system(size: 42)).foregroundStyle(.secondary)
                        Text(language.localized("Bring another Mac into this workspace", "把另一台 Mac 放进当前工作区"))
                            .font(.title3.weight(.medium))
                        Text(language.localized(
                            "Install and open JTS Mac Companion on the other Mac, then paste its pairing invitation here.",
                            "在对方 Mac 安装并开启 JTS Mac Companion，将它的配对邀请粘贴到这里。"
                        ))
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
                Label(language.localized("Encrypted connection", "加密连接"), systemImage: "lock.shield")
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

    private var waitingMessage: String {
        switch workspace.status {
        case .awaitingApproval:
            return language.localized("Approve the request on the other Mac.", "请在对方 Mac 点击批准。")
        case .reconnecting:
            return language.localized("Waiting to reconnect to the other Mac…", "正在等待重连对方 Mac…")
        default:
            return language.localized("Waiting for the other Mac's desktop image…", "等待对方 Mac 的桌面画面…")
        }
    }

    private var inputStatus: String {
        if workspace.isConnected && !workspace.canControl {
            return language.localized(
                "View only · Grant Accessibility access on the other Mac to control it",
                "仅查看 · 在对方 Mac 授予辅助功能权限后可控制"
            )
        }
        if !workspace.controlsEnabled { return language.localized("View only", "仅查看桌面") }
        return hasInputFocus
            ? language.localized("Keyboard controls the other Mac · Control-Option-Esc releases it", "键盘正在控制对方 · Control Option Esc 释放")
            : language.localized("Click the desktop to control the other Mac", "点击桌面控制对方 Mac")
    }

    private func connect() { workspace.connect(session: session, persistEndpoint: { try modelContext.save() }) }
}

struct MacDesktopPairingPanel: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.modelContext) private var modelContext
    @Bindable var session: RemoteSession
    @ObservedObject var workspace: MacDesktopWorkspaceState
    @State private var confirmsForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.localized("Mac Desktop Pairing", "Mac 桌面配对"), systemImage: "link")
                .font(.headline)
            Text(language.localized(
                "Turn on Companion sharing on the other Mac and copy its pairing invitation. The first connection needs approval on that Mac; later connections reuse the device credential saved in the encrypted vault.",
                "在对方 Mac 开启 Companion 共享，复制配对邀请。首次连接需要对方 Mac 批准；之后可使用保存在加密凭据库的设备凭证重新连接。"
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField(language.localized("Paste the jtsmac:// pairing invitation", "粘贴 jtsmac:// 配对邀请"), text: $workspace.invitationCode)
                .textFieldStyle(.roundedBorder)
                .disabled(workspace.isBusy || workspace.isConnected)
                .onSubmit(connect)
                .accessibilityIdentifier("mac-desktop-invitation-field")
            HStack {
                Button(language.localized("Pair and Connect", "配对并连接"), systemImage: "display.2", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.invitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isBusy || workspace.isConnected)
                    .accessibilityIdentifier("mac-desktop-pair-button")
                if workspace.hasSavedPairing {
                    Label(language.localized("Device pairing saved", "已保存设备配对"), systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(language.localized("Forget Pairing", "忘记配对"), role: .destructive) { confirmsForget = true }
                        .disabled(workspace.isBusy && workspace.status != .reconnecting)
                }
            }
            Text(language.localized(
                "The invitation contains a temporary pairing key. Share it only over a trusted channel; invitations and device credentials are never included in profile exports.",
                "邀请包含临时配对密钥。请通过可信方式传递；邀请和设备凭证均不会进入配置导出。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { workspace.prepare(for: session) }
        .confirmationDialog(
            language.localized("Remove the pairing from this Mac?", "从此 Mac 移除配对？"),
            isPresented: $confirmsForget
        ) {
            Button(language.localized("Forget Pairing", "忘记配对"), role: .destructive) { workspace.forgetPairing(session: session) }
        } message: {
            Text(language.localized(
                "The current connection closes. Connecting again requires a new invitation and approval on the other Mac.",
                "当前连接将断开。之后连接需要对方 Mac 重新生成邀请并批准。"
            ))
        }
    }

    private func connect() { workspace.connect(session: session, persistEndpoint: { try modelContext.save() }) }
}

#endif
