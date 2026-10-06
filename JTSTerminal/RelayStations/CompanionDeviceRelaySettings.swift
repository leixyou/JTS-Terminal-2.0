#if ENABLE_RDP_2
import SwiftUI
import JTSCompanionDevices

struct CompanionDeviceRelaySettings: View {
    let device: CompanionSavedDevice
    let model: CompanionDevicesModel
    let language: AppLanguage
    @State private var origin = ""
    @State private var stations = RelayStationsModel.shared
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.routes[device.id]?.hasRoute == true ? t("Control connected", "控制已连接")
                  : t("Control disconnected", "控制未连接"),
                  systemImage: model.routes[device.id]?.hasRoute == true ? "checkmark.circle" : "circle")
                .font(.callout).foregroundStyle(.secondary)
            RelayStationPicker(origin: $origin, language: language)
            if origin != device.relayURL && !origin.isEmpty {
                Text(t("Verify this Windows identity on the selected station before applying. Reconnect after saving.",
                       "应用前会验证所选中转站上的 Windows 身份，保存后请重新连接。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(t("Verify and apply", "验证并应用")) {
                    Task { _ = await stations.moveDevice(id: device.id, to: origin) }
                }.disabled(stations.busy || model.busy || !stations.stations.contains { $0.relayURL == origin })
            }
        }
        .onAppear { origin = device.relayURL }
        .onChange(of: device.relayURL) { _, value in origin = value }
    }
}
#endif
