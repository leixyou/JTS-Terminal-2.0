import AppKit
import SwiftUI

struct CompanionView: View {
    @ObservedObject var server: CompanionServer
    @ObservedObject var nativeServer: NativeRelayHostRuntime
    @AppStorage("companion.preferred-sharing-mode.v1") private var sharingMode = "native"
    @State private var copied = false
    @State private var showingInvitation = false
    @State private var confirmingAutomaticSharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("将这台 Mac 接入 JTS Terminal").font(.title2.weight(.semibold))
                    Label(sharingMode == "native" ? nativeServer.status : server.status,
                          systemImage: (sharingMode == "native" ? nativeServer.enabled : server.isSharing) ? "circle.fill" : "circle")
                        .font(.callout).foregroundStyle((sharingMode == "native" ? nativeServer.enabled : server.isSharing) ? .green : .secondary)
                }
                Spacer()
                if sharingMode == "embedded" {
                Button(server.isSharing ? "停止共享" : "开始共享") {
                    if server.isSharing { server.stop() } else { server.start() }
                }
                .buttonStyle(.borderedProminent).disabled(server.isStarting)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                } else if nativeServer.trust != nil {
                    Button(nativeServer.enabled ? "停止系统连接" : "恢复系统连接") { nativeServer.setEnabled(!nativeServer.enabled) }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(20)
            Divider()
            Form {
                Section {
                    Picker("连接方式", selection: $sharingMode) {
                        Text("Apple 系统屏幕共享 · 公网").tag("native")
                        Text("内嵌桌面 · 局域网/VPN").tag("embedded")
                    }.pickerStyle(.segmented)
                }
                if sharingMode == "native" {
                    NativeRelayHostView(runtime: nativeServer, server: server)
                } else {
                CompanionSetupView(server: server) { confirmingAutomaticSharing = true }
                Section("系统权限") {
                    permissionRow("屏幕录制", enabled: server.screenPermission,
                        detail: "用于把这台 Mac 的主显示器传给已授权客户端。") {
                        if !server.screenPermission { CompanionPermissions.requestScreenRecording() }
                        CompanionPermissions.openPrivacy("Privacy_ScreenCapture")
                    }
                    permissionRow("辅助功能", enabled: server.controlPermission,
                        detail: "用于远程键鼠控制；未授权时仍可查看桌面。") {
                        if !server.controlPermission { CompanionPermissions.requestAccessibility() }
                        CompanionPermissions.openPrivacy("Privacy_Accessibility")
                    }
                    Toggle("允许已授权客户端操作键盘和鼠标", isOn: $server.allowRemoteControl)
                }
                Section("连接") {
                    Picker("这台 Mac 的地址", selection: $server.host) {
                        ForEach(LocalDesktopAddresses.available(), id: \.self) { address in
                            Text(address == "127.0.0.1" ? "127.0.0.1（仅本机测试）" : address).tag(address)
                        }
                    }.disabled(server.isSharing)
                    TextField("端口", value: $server.port, format: .number.grouping(.never))
                        .disabled(server.isSharing)
                    Text("在另一台 Mac 的 JTS Terminal 中新建“Mac Desktop”，粘贴配对邀请。首次连接需要在这里确认。")
                        .font(.callout).foregroundStyle(.secondary)
                    if let expiry = server.invitationExpiresAt {
                        HStack {
                            Text("邀请有效至 \(expiry.formatted(date: .omitted, time: .shortened))").font(.callout)
                            Spacer()
                            Button(copied ? "已复制" : "复制配对邀请") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(server.invitationCode, forType: .string)
                                copied = true
                            }.disabled(server.invitationCode.isEmpty)
                            Button(showingInvitation ? "隐藏" : "显示") { showingInvitation.toggle() }
                        }
                        if showingInvitation {
                            Text(server.invitationCode).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).lineLimit(5)
                        }
                    }
                    Button("生成新的配对邀请") { server.renewInvitation(); copied = false }
                        .disabled(!server.isSharing)
                    Text("邀请五分钟后失效，只能授权一次。请只交给你要连接的电脑。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let pending = server.pendingClient {
                    Section("新的连接请求") {
                        Text("允许“\(pending.clientName)”查看\(server.allowRemoteControl ? "并操作" : "")这台 Mac 的桌面？")
                        HStack {
                            Button("拒绝") { server.rejectPendingClient() }
                            Button("允许此电脑") { server.approvePendingClient() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                Section("已授权的电脑") {
                    if server.clients.isEmpty {
                        Text("尚无已授权的电脑。完成首次配对后，可直接重连。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(server.clients) { client in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(client.name)
                                Text("授权于 \(client.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("撤销", role: .destructive) { server.revoke(client) }
                        }
                    }
                    if server.connectedClientName != nil {
                        Button("断开当前桌面") { server.disconnectActive() }
                    }
                }
                Section("自动启动与共享") {
                    Toggle("权限有效时自动共享给已授权电脑", isOn: Binding(
                        get: { server.automaticSharing },
                        set: { enabled in
                            if enabled { confirmingAutomaticSharing = true }
                            else { server.disableAutomaticSharing() }
                        }))
                        .disabled(!server.canEnableAutomaticSharing && !server.automaticSharing)
                    Text(server.automaticSharingDetail).font(.caption).foregroundStyle(.secondary)
                    Toggle("登录时打开程序", isOn: Binding(
                        get: { server.startsAtLogin || server.loginStatus == .requiresApproval },
                        set: server.setStartsAtLogin))
                    Text(server.loginStatus.detail).font(.caption).foregroundStyle(.secondary)
                    if let loginError = server.loginError {
                        Label(loginError, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                        Button("重新启用登录项") { server.setStartsAtLogin(true) }
                    }
                    if server.loginStatus == .requiresApproval {
                        Button("前往系统设置允许登录项") { CompanionPermissions.openLoginSettings() }
                    }
                    Text("自动共享只接受已配对电脑，不会自动生成新邀请。点击“停止共享”会持续暂停，重新开始后才恢复。关闭窗口后可从菜单栏管理共享。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = server.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                        if !server.identityAvailable {
                            Button("重新读取设备身份") { server.reloadIdentity() }
                        }
                    }
                }
                }
            }.formStyle(.grouped)
        }
        .frame(minWidth: 580, minHeight: 520)
        .confirmationDialog("启用自动启动与共享？", isPresented: $confirmingAutomaticSharing,
                            titleVisibility: .visible) {
            Button("启用自动启动与共享") { server.enableAutomaticSharing() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("登录此 Mac 后，程序会自动打开；屏幕录制权限有效时，已授权电脑可直接查看桌面。开启远程控制且已授权辅助功能时也可操作键鼠。你可以随时在菜单栏停止共享。")
        }
        .onChange(of: server.invitationCode) { _, _ in copied = false; showingInvitation = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            server.refreshPermissions()
        }
    }

    private func permissionRow(_ title: String, enabled: Bool, detail: String, request: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: enabled ? "checkmark.circle.fill" : "circle")
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(enabled ? "设置" : "授权", action: request)
        }
    }
}
