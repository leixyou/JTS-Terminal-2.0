#if ENABLE_RDP_2
import SwiftUI
import JTSCompanionDevices

struct RelayStationEditorView: View {
    let model: RelayStationsModel
    let station: RelayStation?
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var relayURL: String
    @State private var submitted = false
    @State private var testing = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, address }
    private var normalizedName: String? { try? RelayStationRegistry.normalizedName(name) }
    private var normalizedOrigin: String? { try? RelayStationRegistry.normalizedOrigin(relayURL) }
    private var changesOrigin: Bool { normalizedOrigin != nil && normalizedOrigin != station?.relayURL }
    private var affectedDevices: [CompanionSavedDevice] {
        guard let station, changesOrigin else { return [] }
        return model.affectedDevices(origin: station.relayURL)
    }
    private var duplicateOrigin: Bool {
        guard station == nil, let normalizedOrigin else { return false }
        return model.stations.contains { $0.id != station?.id && $0.relayURL == normalizedOrigin }
    }
    private var canSave: Bool {
        normalizedName != nil && normalizedOrigin != nil && !duplicateOrigin && !model.busy
    }
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }

    init(model: RelayStationsModel, station: RelayStation? = nil, language: AppLanguage) {
        self.model = model; self.station = station; self.language = language
        _name = State(initialValue: station?.name ?? "")
        _relayURL = State(initialValue: station?.relayURL ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(station == nil ? t("Add relay station", "添加中转站") : t("Edit relay station", "编辑中转站"))
                .font(.title2)
            fields
            if !affectedDevices.isEmpty { migrationSection }
            if let origin = normalizedOrigin {
                VStack(alignment: .leading, spacing: 8) {
                    Button(t("Test connection", "测试连通性")) {
                        testing = true
                        Task {
                            _ = await model.check(origin: origin)
                            testing = false
                        }
                    }
                    .disabled(model.busy).accessibilityIdentifier("relay-editor-test")
                    RelayStationProbeStatusView(
                        result: model.probes[origin], errorCode: model.probeErrors[origin], language: language
                    )
                }
            }
            Text(t("A connection test checks the relay service only. Device identity and access are verified separately.",
                   "连通性测试仅检查中转服务。设备身份与访问权限需单独验证。"))
                .font(.caption).foregroundStyle(.secondary)
            if submitted, let code = model.errorCode {
                Text(RelayStationMessage.text(code, language: language))
                    .font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("relay-editor-error")
            }
            footer
        }
        .padding(22).frame(width: 580)
        .accessibilityIdentifier("relay-station-editor")
        .interactiveDismissDisabled(model.busy)
        .onAppear { focusedField = station == nil ? .name : .address }
    }

    private var fields: some View {
        Form {
            VStack(alignment: .leading, spacing: 6) {
                TextField(t("Name", "名称"), text: $name, prompt: Text(t("My relay", "我的中转站")))
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("relay-editor-name")
                if !name.isEmpty && normalizedName == nil {
                    Text(t("The name is too long or contains unsupported characters. Use a shorter, plain-text name.",
                           "名称过长或包含不支持的字符，请使用较短的普通文本名称。"))
                        .font(.caption).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField(t("HTTPS address", "HTTPS 地址"), text: $relayURL,
                          prompt: Text("https://relay.example.com:8443"))
                    .focused($focusedField, equals: .address)
                    .accessibilityIdentifier("relay-editor-address")
                    .autocorrectionDisabled()
                Text(t("Use https:// followed by the host and optional port, without a path, username or query.",
                       "填写 https:// 开头的主机地址，可包含端口，不要添加路径、用户名或查询参数。"))
                    .font(.caption).foregroundStyle(.secondary)
                if !relayURL.isEmpty && normalizedOrigin == nil {
                    Text(t("Enter a valid HTTPS relay address.", "请输入有效的 HTTPS 中转站地址。"))
                        .font(.caption).foregroundStyle(.red)
                } else if duplicateOrigin {
                    Text(t("This address is already saved. Edit the existing relay station instead.",
                           "此地址已保存，请编辑已有中转站。"))
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped).fixedSize(horizontal: false, vertical: true).disabled(model.busy)
    }

    private var migrationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(t("Devices to update (\(affectedDevices.count))", "将更新的设备（\(affectedDevices.count)）"))
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(affectedDevices) { device in
                        Label(device.name, systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: min(CGFloat(affectedDevices.count) * 26, 104))
            Text(t("Each device identity will be verified through the new relay before its saved address changes. Reconnect these devices after saving.",
                   "会先通过新中转站验证每台设备的身份，再更改已保存的地址。保存后请重新连接这些设备。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("relay-editor-affected-devices")
    }

    private var footer: some View {
        HStack {
            if model.busy {
                ProgressView().controlSize(.small)
                Text(testing ? t("Testing connection…", "正在测试连通性…") :
                        changesOrigin ? t("Verifying relay…", "正在验证中转站…") : t("Saving…", "正在保存…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(t("Cancel", "取消")) { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(model.busy)
                .accessibilityIdentifier("relay-editor-cancel")
            Button(changesOrigin ? t("Verify and save", "验证并保存") : t("Save", "保存")) {
                submitted = true
                Task {
                    if await model.save(id: station?.id, name: name, relayURL: relayURL) { dismiss() }
                }
            }
            .keyboardShortcut(.defaultAction).disabled(!canSave)
            .accessibilityIdentifier("relay-editor-save")
        }
    }
}
#endif
