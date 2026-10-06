#if ENABLE_RDP_2
import SwiftUI
import JTSCompanionDevices

struct RelayStationPicker: View {
    @Binding var origin: String
    let language: AppLanguage
    @State private var stations = RelayStationsModel.shared
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(t("Relay station", "中转站"), selection: $origin) {
                    Text(t("Select a relay station", "选择中转站")).tag("")
                    ForEach(stations.stations) { station in
                        Text(station.name + (station.id == stations.defaultStationID ? t(" (Default)", "（默认）") : ""))
                            .tag(station.relayURL)
                    }
                    if !origin.isEmpty && !stations.stations.contains(where: { $0.relayURL == origin }) {
                        Text(origin).tag(origin)
                    }
                }.accessibilityIdentifier("relay-station-picker")
                SettingsLink { Text(t("Manage…", "管理…")) }
            }
            if !origin.isEmpty { Text(origin).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if stations.loaded && stations.stations.isEmpty {
                Text(t("Add a relay station in Settings to continue.", "请先在设置中添加中转站。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let code = stations.errorCode {
                Text(RelayStationMessage.text(code, language: language)).font(.caption).foregroundStyle(.red)
            }
        }
        .task {
            await stations.refresh()
            if origin.isEmpty { origin = stations.defaultOrigin ?? "" }
        }
    }
}
#endif
