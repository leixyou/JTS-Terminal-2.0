import SwiftUI

struct NativeRelayHostView: View {
    @ObservedObject var runtime: NativeRelayHostRuntime
    @ObservedObject var server: CompanionServer
    @State private var confirmingConsent = false
    @State private var confirmingRevocation = false
    @State private var confirmingDiscard = false

    var body: some View {
        Group {
        Section("1 · 开启此 Mac 的系统屏幕共享") {
            Text("在系统设置 → 通用 → 共享中开启“屏幕共享”，并允许你的 Mac 账户。连接时由 Apple 屏幕共享验证账户；Companion 不接收或保存系统登录密码。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("打开共享设置") { CompanionPermissions.openSharingSettings() }
                Button("检查是否已开启") { runtime.checkNativeService() }
                if let available = runtime.nativeServiceAvailable {
                    Label(available ? "共享服务已响应" : "共享服务尚未响应",
                          systemImage: available ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(available ? .green : .secondary).font(.caption)
                }
            }
        }
        Section("2 · 授权你的管理电脑") {
            if let trust = runtime.trust {
                LabeledContent("已授权电脑", value: trust.name)
                LabeledContent("中继站", value: trust.relayOrigin)
                identity(trust.controllerDeviceID)
                Button("撤销此电脑", role: .destructive) { confirmingRevocation = true }
                    .disabled(runtime.busy)
            } else if let preview = runtime.preview {
                TextField("这台管理电脑的名称", text: $runtime.controllerName)
                LabeledContent("中继站", value: preview.relayOrigin)
                identity(preview.controllerDeviceID)
                DisclosureGroup("桌面授权信息") {
                    Text("配对：\(preview.pairingID.uuidString)")
                    Text("桌面授权：\(preview.rdpGrantID.uuidString)")
                }.font(.caption).textSelection(.enabled)
                Text("请在管理电脑上核对身份指纹，再允许连接。允许后，这台电脑可以经中继站连接系统屏幕共享；系统账户权限仍由 macOS 管理。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("取消配对", role: .destructive) { confirmingDiscard = true }
                    Button("允许此电脑并启用自动连接") { confirmingConsent = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(runtime.busy)
                }
            } else {
                Text("在新版 JTS Terminal 的 Mac 系统共享配置中生成配对邀请，粘贴到这里。公网配对与内嵌桌面的局域网邀请分别授权。")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("粘贴管理电脑生成的公网配对邀请", text: $runtime.invitationCode)
                    .disabled(runtime.busy)
                Button("读取邀请并核对身份") { runtime.prepareEnrollment() }
                    .disabled(!runtime.identityAvailable || runtime.busy || runtime.invitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if runtime.busy { ProgressView().controlSize(.small) }
            }
            Text(runtime.status).font(.caption).foregroundStyle(.secondary)
        }
        Section("3 · 自动启动与连接") {
            Toggle("自动接受已授权电脑的系统共享连接", isOn: Binding(get: { runtime.enabled }, set: runtime.setEnabled))
                .disabled(!runtime.identityAvailable || runtime.trust == nil)
            Toggle("登录此 Mac 时打开 Companion", isOn: Binding(
                get: { server.startsAtLogin || server.loginStatus == .requiresApproval }, set: server.setStartsAtLogin))
            Text(server.loginStatus.detail).font(.caption).foregroundStyle(.secondary)
            if server.loginStatus == .requiresApproval {
                Button("前往登录项设置允许") { CompanionPermissions.openLoginSettings() }
            }
            if let loginError = server.loginError {
                Label(loginError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            Text("公网连接使用 Apple 标准屏幕共享。高性能模式需要额外的 UDP 网络条件。关闭窗口后连接仍运行；停止或撤销后不再接受连接，已保存设置在重新登录后保留。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error = runtime.error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                if !runtime.identityAvailable {
                    Button("重新读取加密身份") { runtime.reload() }
                }
            }
        }
        }
            .confirmationDialog("允许这台管理电脑？", isPresented: $confirmingConsent, titleVisibility: .visible) {
                Button("允许并开启自动连接") {
                    runtime.approveEnrollment()
                    server.setStartsAtLogin(true)
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("确认后会保存此电脑的身份和桌面授权，并注册登录项。配对完成后自动接受它的系统屏幕共享连接。你可以随时停止或撤销。")
            }
            .confirmationDialog("撤销管理电脑？", isPresented: $confirmingRevocation) {
                Button("撤销并断开连接", role: .destructive) { runtime.revoke() }
            } message: { Text("此电脑的本机桌面授权会被移除；再次连接必须重新配对并确认。") }
            .confirmationDialog("取消此次配对？", isPresented: $confirmingDiscard) {
                Button("取消配对", role: .destructive) { runtime.discardEnrollment() }
            } message: { Text("此 Mac 不再接受此次邀请的确认。管理电脑上的邀请可以单独取消或等待过期。") }
    }

    private func identity(_ pin: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("管理电脑身份指纹（SHA-256）").font(.caption).foregroundStyle(.secondary)
            Text(pin).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}
