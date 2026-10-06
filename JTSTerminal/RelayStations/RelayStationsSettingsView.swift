#if ENABLE_RDP_2
import SwiftUI
import JTSCompanionDevices

struct RelayStationsSettingsView: View {
    @State var model: RelayStationsModel = .shared
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.defaultLanguage.rawValue
    @State private var selectedID: UUID?
    @State private var editor: RelayStationEditorRequest?
    @State private var deleting: RelayStation?

    private var language: AppLanguage { .resolved(from: languageRawValue) }
    private var selected: RelayStation? { model.stations.first { $0.id == selectedID } }
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let code = model.errorCode {
                Text(RelayStationMessage.text(code, language: language))
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .accessibilityIdentifier("relay-stations-error")
                Divider()
            }
            if !model.loaded {
                if model.busy {
                    ProgressView(t("Loading relay stations…", "正在读取中转站…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(t("Relay stations unavailable", "暂时无法读取中转站"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(t("Reload to try reading the saved stations again.", "请重新读取已保存的中转站。"))
                    } actions: {
                        Button(t("Reload", "重新读取")) { Task { await model.refresh() } }
                            .accessibilityIdentifier("relay-stations-retry")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.stations.isEmpty {
                emptyState
            } else {
                HSplitView {
                    stationList.frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                    if let selected {
                        RelayStationDetailsView(
                            model: model, station: selected, language: language,
                            edit: { editor = RelayStationEditorRequest(station: selected) },
                            remove: { deleting = selected }
                        )
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(t("Select a relay station", "选择中转站"), systemImage: "network")
                            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Divider()
            Text(t("Relay stations can be reused when adding Windows devices. Device pairing and permissions are managed separately.",
                   "添加 Windows 设备时可复用已保存的中转站。设备配对与权限需单独管理。"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(minWidth: 740, minHeight: 520)
        .accessibilityIdentifier("relay-stations-settings")
        .task { await model.refresh() }
        .onChange(of: model.stations.map(\.id), initial: true) { _, ids in
            guard !ids.contains(where: { $0 == selectedID }) else { return }
            selectedID = model.defaultStationID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        }
        .sheet(item: $editor) { request in
            RelayStationEditorView(model: model, station: request.station, language: language)
        }
        .alert(t("Delete this relay station?", "删除这个中转站？"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { station in
            Button(t("Cancel", "取消"), role: .cancel) { deleting = nil }
            Button(t("Delete", "删除"), role: .destructive) {
                deleting = nil
                Task { await model.remove(id: station.id) }
            }
        } message: { station in
            Text(t("Remove “\(station.name)” from saved relay stations? If it is the default, new devices will need a relay selection.",
                   "从已保存的中转站中移除“\(station.name)”？如果它是默认中转站，添加新设备时需要另选中转站。"))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(t("Relay stations", "中转站"), systemImage: "network").font(.headline)
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small).accessibilityLabel(t("Working", "处理中"))
            }
            Button(t("Reload", "重新读取"), systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .disabled(model.busy).accessibilityIdentifier("relay-stations-reload")
            Button(t("Add relay…", "添加中转站…"), systemImage: "plus") {
                editor = RelayStationEditorRequest(station: nil)
            }
            .disabled(!model.loaded || model.busy)
            .accessibilityIdentifier("relay-stations-add")
        }.padding(16)
    }

    private var stationList: some View {
        List(selection: $selectedID) {
            ForEach(model.stations) { station in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(station.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if station.id == model.defaultStationID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(t("Default for new devices", "新设备默认中转站"))
                        }
                    }
                    Text(station.relayURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 4).tag(station.id)
                .accessibilityIdentifier("relay-station-row-\(station.id.uuidString)")
            }
        }
        .listStyle(.sidebar).accessibilityIdentifier("relay-stations-list")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(t("No relay stations yet", "尚未添加中转站"), systemImage: "network")
        } description: {
            Text(t("Save a relay HTTPS address to reuse it for Windows connections.",
                   "保存中转站 HTTPS 地址，供 Windows 连接使用。"))
        } actions: {
            Button(t("Add relay…", "添加中转站…")) { editor = RelayStationEditorRequest(station: nil) }
                .buttonStyle(.borderedProminent).disabled(model.busy)
                .accessibilityIdentifier("relay-stations-empty-add")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RelayStationEditorRequest: Identifiable {
    let id = UUID()
    let station: RelayStation?
}
#endif
