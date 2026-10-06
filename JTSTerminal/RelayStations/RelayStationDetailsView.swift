#if ENABLE_RDP_2
import SwiftUI
import JTSCompanionDevices

struct RelayStationDetailsView: View {
    let model: RelayStationsModel
    let station: RelayStation
    let language: AppLanguage
    let edit: () -> Void
    let remove: () -> Void

    private var devices: [CompanionSavedDevice] { model.affectedDevices(origin: station.relayURL) }
    private var isDefault: Bool { model.defaultStationID == station.id }
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(station.name).font(.title2).textSelection(.enabled)
                    Spacer()
                    Button(t("Edit…", "编辑…"), action: edit)
                        .disabled(model.busy).accessibilityIdentifier("relay-station-edit")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(t("HTTPS address", "HTTPS 地址")).font(.headline)
                    Text(station.relayURL).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("relay-station-address")
                }
                defaultSection
                Divider()
                connectivitySection
                Divider()
                devicesSection
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Button(t("Delete relay…", "删除中转站…"), role: .destructive, action: remove)
                        .disabled(model.busy || !devices.isEmpty)
                        .accessibilityIdentifier("relay-station-delete")
                    if !devices.isEmpty {
                        Text(t("This relay is used by saved devices. Move those devices to another relay before deleting it.",
                               "此中转站仍被设备使用。请先将关联设备迁移到其他中转站，再删除。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var defaultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDefault {
                Label(t("Default for new devices", "新设备默认中转站"), systemImage: "checkmark.circle")
                    .font(.headline)
            }
            Button(isDefault ? t("Clear default", "取消默认") : t("Use for new devices", "设为新设备默认")) {
                Task { await model.setDefault(id: isDefault ? nil : station.id) }
            }
            .disabled(model.busy).accessibilityIdentifier("relay-station-default")
            Text(t("The default only preselects a relay when adding a device. Existing device connections keep their current relay.",
                   "默认设置仅用于添加新设备时预选中转站，已有设备继续使用各自的中转站。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("Connectivity", "连通性")).font(.headline)
                Spacer()
                Button(t("Test connection", "测试连通性")) {
                    Task { _ = await model.check(origin: station.relayURL) }
                }
                .disabled(model.busy).accessibilityIdentifier("relay-station-test")
            }
            RelayStationProbeStatusView(
                result: model.probes[station.relayURL],
                errorCode: model.probeErrors[station.relayURL], language: language
            )
            Text(t("This checks the relay service at that moment. It does not show continuous availability or confirm device pairing or access permissions.",
                   "测试仅记录当时的中转服务响应，不代表持续在线，也不确认设备已配对或已获授权。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Associated devices (\(devices.count))", "关联设备（\(devices.count)）")).font(.headline)
            if devices.isEmpty {
                Text(t("No saved devices use this relay.", "暂无设备使用此中转站。"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    Label(device.name, systemImage: "desktopcomputer")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(t("Changing the address verifies these device identities on the new relay before applying the change. Reconnect afterwards.",
                       "修改地址时，会先验证这些设备在新中转站上的身份，再应用更改。完成后需重新连接。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("relay-station-devices")
    }
}

struct RelayStationProbeStatusView: View {
    let result: RelayStationProbeResult?
    let errorCode: String?
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorCode {
                Label(RelayStationMessage.text(errorCode, language: language), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let result {
                Text(language.localized("Last successful check: ", "上次测试成功：") + result.checkedAt.formatted(date: .abbreviated, time: .standard))
                Text(language.localized("Response time: \(result.latencyMilliseconds) ms", "响应时间：\(result.latencyMilliseconds) 毫秒"))
                    .foregroundStyle(.secondary)
            } else if errorCode == nil {
                Text(language.localized("Not tested yet", "尚未测试")).foregroundStyle(.secondary)
            }
        }
        .font(.caption).accessibilityIdentifier("relay-station-probe-result")
    }
}
#endif
