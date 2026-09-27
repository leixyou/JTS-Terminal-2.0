#if ENABLE_RDP_2
import AppKit
import SwiftUI
import JTSCompanionDevices

struct CompanionDevicesView: View {
    @State var model: CompanionDevicesModel = .shared
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.defaultLanguage.rawValue
    @State private var adding = false
    @State private var initializing = false
    @State private var revoking = false
    @State private var grantID = ""
    private var language: AppLanguage { .resolved(from: languageRawValue) }
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(t("Companion devices", "Companion 设备"), systemImage: "desktopcomputer")
                    .font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel(t("Working", "处理中")) }
                Button(t("Reload", "重新读取"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.busy)
                Button(t("Add device…", "添加设备…"), systemImage: "plus") { adding = true }
                    .disabled(!model.loaded || model.snapshot == nil || model.busy)
                    .accessibilityIdentifier("companion-add-device")
            }.padding()
            Divider()
            if let code = model.errorCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("The operation could not be verified. Reload local state or check the Windows approval and relay certificate.",
                           "操作未能确认。请重新读取本机状态，或检查 Windows 授权和中继连通性。"))
                    Text(code).font(.caption.monospaced()).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding().foregroundStyle(.red)
                Divider()
            }
            if let snapshot = model.snapshot {
                HSplitView {
                    sidebar(snapshot).frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "desktopcomputer.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary)
                    Text(t("Independent Windows connections", "独立的 Windows 连接")).font(.title2)
                    Text(t("Control does not need an open RDP desktop. Create a local identity, then verify a Windows device. Existing AI desktop control includes delegated pairing.",
                           "控制连接不依赖 RDP 窗口。先创建本机身份，再核对 Windows 设备；已有的 AI 桌面控制授权包含配对委托。"))
                        .multilineTextAlignment(.center).frame(maxWidth: 480).foregroundStyle(.secondary)
                    if model.loaded && model.errorCode == nil {
                        Button(t("Create local identity…", "创建本机身份…")) { initializing = true }
                            .buttonStyle(.borderedProminent).disabled(model.busy)
                            .accessibilityIdentifier("companion-create-identity")
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text(t("Closing this window keeps \(model.connectedCount) control connection(s). Disconnect explicitly to close them. The same saved target permissions apply to independent MCP operations.",
                   "关闭本窗口将保留 \(model.connectedCount) 个控制连接；请使用断开按钮结束连接。独立 MCP 操作继承已保存目标的权限。"))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(minWidth: 740, minHeight: 520)
        .task { await model.refresh() }
        .onChange(of: model.selectedID) { _, _ in grantID = "" }
        .sheet(isPresented: $adding) { CompanionAddDeviceView(model: model, language: language) }
        .alert(t("Create a new local identity?", "创建新的本机身份？"), isPresented: $initializing) {
            Button(t("Cancel", "取消"), role: .cancel) {}
            Button(t("Create identity", "创建身份")) { Task { await model.initialize() } }
        } message: {
            Text(t("Its private key stays in the encrypted local vault. This is not recovery of an old identity and does not authorize any Windows device.",
                   "私钥仅保存在本机加密凭据库中。此操作不会恢复旧身份，也不会授权任何 Windows 设备。"))
        }
        .alert(t("Revoke local trust?", "撤销本机信任？"), isPresented: $revoking) {
            Button(t("Cancel", "取消"), role: .cancel) {}
            Button(t("Revoke local trust", "撤销本机信任"), role: .destructive) { Task { await model.revokeSelected() } }
        } message: {
            Text(t("The local control connection will close and this record cannot reconnect. Windows permissions are NOT revoked here, and remote task termination is not confirmed. Revoke those permissions on Windows separately.",
                   "本机控制连接将关闭，此记录不能再次连接。这不会撤销 Windows 端权限，也不能确认远端任务已停止；请另行在 Windows 上撤销权限。"))
        }
    }

    private func sidebar(_ snapshot: CompanionDeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("This Mac", "本机身份")).font(.headline)
            CompanionPublicValue(value: snapshot.deviceID, copyLabel: t("Copy fingerprint", "复制指纹"))
            Button(t("Copy public key", "复制公钥")) { CompanionPublicValue.copy(snapshot.publicSPKI.base64EncodedString()) }
                .help(t("Only the public key is copied; the private key never leaves the vault for export.", "仅复制公钥，不导出私钥。"))
            Divider()
            Text(t("Saved devices", "已保存的设备")).font(.subheadline).foregroundStyle(.secondary)
            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(snapshot.devices, id: \.id) { device in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(device.name, systemImage: device.revokedAt == nil ? "desktopcomputer" : "lock.slash")
                        Text(model.routes[device.id]?.hasRoute == true ? t("Control connected", "控制已连接") : device.revokedAt == nil ? t("Local identity verified", "本机已核对身份") : t("Local trust revoked", "本机信任已撤销"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(device.id)
                }
            }.listStyle(.sidebar)
        }.padding(14)
    }

    @ViewBuilder private var detail: some View {
        if let device = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(device.name).font(.title2)
                    LabeledContent(t("Relay", "中继")) { Text(device.relayURL).textSelection(.enabled) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("Windows identity fingerprint", "Windows 身份指纹")).font(.headline)
                        CompanionPublicValue(value: device.peerDeviceID, copyLabel: t("Copy fingerprint", "复制指纹"))
                    }
                    Text(device.allowWindows10TLS12 ? t("Explicit Windows 10 ESU TLS 1.2 compatibility", "已明确启用 Windows 10 ESU TLS 1.2 兼容") : "TLS 1.3")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(t("Existing AI desktop control includes delegated pairing. Import the Windows installer’s public enrollment bundle through jts_device_status to verify its grant and bind the target without another approval. Relay HTTPS/WSS stays encrypted with server certificate validation skipped by default; inner TLS verifies the pinned peer.",
                           "已有的 AI 桌面控制授权包含配对委托。通过 jts_device_status 导入 Windows 安装器的公开配对包，即可校验授权并绑定目标，无需再次确认。中继 HTTPS/WSS 默认跳过证书校验但保持加密，内层 TLS 仍校验固定设备身份。"))
                        .foregroundStyle(.secondary)
                    if device.revokedAt != nil {
                        Label(t("Local trust revoked. Windows permissions are unchanged.", "本机信任已撤销，Windows 端权限未改变。"), systemImage: "lock.slash")
                    } else {
                        HStack {
                            Button(t("Connect control channel", "连接控制通道")) { Task { await model.connect(deviceID: device.id) } }
                                .buttonStyle(.borderedProminent).disabled(!model.canConnect || model.hasRoute)
                            Button(t("Disconnect", "断开")) { model.disconnect() }
                                .disabled(!model.hasRoute && !model.busy)
                            Spacer()
                            Button(t("Revoke local trust…", "撤销本机信任…"), role: .destructive) { revoking = true }
                                .disabled(model.busy)
                        }
                        if let opened = model.openedAt {
                            Text(t("Encrypted channel last established: ", "上次建立加密通道：") + opened.formatted())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text(t("Check an existing Windows grant", "检查已有的 Windows 授权")).font(.headline)
                        TextField(t("Control grant ID issued by Windows", "Windows 签发的控制授权 ID"), text: $grantID)
                            .textFieldStyle(.roundedBorder).disabled(model.busy)
                        Button(t("Verify grant", "验证授权")) { Task { await model.checkGrant(grantID, deviceID: device.id) } }
                            .disabled(!model.hasRoute || model.busy || UUID(uuidString: grantID) == nil)
                        if let verified = model.verifiedAt, let verifiedGrant = model.verifiedGrant {
                            Text(t("Last verified grant: ", "上次验证的授权：") + verifiedGrant.uuidString.lowercased())
                                .font(.caption).textSelection(.enabled)
                            Text(verified.formatted()).font(.caption).foregroundStyle(.secondary)
                            Text(model.capabilities.joined(separator: ", ")).font(.body.monospaced()).textSelection(.enabled)
                        }
                        Text(t("This is a timestamped permission check, not continuous online status or proof that a PowerShell job will succeed. Disconnecting does not confirm remote tasks stopped.",
                               "这里记录的是当时的授权检查结果，不代表持续在线，也不保证 PowerShell 任务可执行。断开连接不能确认远端任务已停止。"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let route = model.selectedRoute {
                            Divider()
                            CompanionJobsView(model: model, route: route, language: language).id(route.deviceID)
                        }
                    }
                }.padding(22)
            }
        } else {
            ContentUnavailableView(t("Select or add a Windows device", "选择或添加 Windows 设备"), systemImage: "desktopcomputer")
        }
    }
}

private struct CompanionPublicValue: View {
    let value: String
    let copyLabel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button(copyLabel) { Self.copy(value) }.controlSize(.small)
        }
    }
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
}
#endif
