#if ENABLE_RDP_2
import AppKit
import SwiftUI
import SwiftData
import JTSCompanionDevices
import JTSRelayEnrollment

struct CompanionEnrollmentView: View {
    let language: AppLanguage
    @State var model: CompanionEnrollmentModel = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var relay = ""
    @State private var compatibility = false
    @State private var selected: String?
    @State private var targetID: UUID?
    @Query private var targets: [RemoteSession]
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }
    private var record: CompanionEnrollmentRecord? { model.records.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Connect with an access code", "通过接入码连接")).font(.title2)
            Text(t("Paste the code into Companion on Windows. Binding lasts until you revoke it; RDP login is separate.",
                   "将接入码粘贴到 Windows 上的 Companion。绑定会保留到主动撤销，与 RDP 登录无关。"))
                .foregroundStyle(.secondary)
            Form {
                TextField(t("HTTPS relay address", "HTTPS 中转地址"), text: $relay).textFieldStyle(.roundedBorder)
                Toggle(t("Windows 10 / Server 2019 compatibility", "Windows 10 / Server 2019 兼容模式"), isOn: $compatibility)
                Picker(t("Windows profile", "Windows 连接配置"), selection: $targetID) {
                    Text(t("Device only", "仅添加设备")).tag(UUID?.none)
                    ForEach(targets.filter { $0.connectionType == .rdp }.sorted { $0.name < $1.name }, id: \.targetID) { target in
                        Text(target.name).tag(Optional(target.targetID))
                    }
                }
            }
            Button(t("Create access code", "生成接入码")) {
                Task {
                    do {
                        let target = targets.first { $0.targetID == targetID }
                        selected = try await model.create(relayURL: relay, compatibility: compatibility,
                            targetID: target?.targetID, targetBinding: target?.mcpGrantTargetBinding,
                            authorize: ownerCheck(targetID: target?.targetID, binding: target?.mcpGrantTargetBinding)).id
                    }
                    catch { model.present(error); selected = model.records.last?.id }
                }
            }.buttonStyle(.borderedProminent).disabled(model.busy || relay.isEmpty)
            if !model.records.isEmpty {
                Picker(t("Saved connection attempts", "已保存的接入记录"), selection: $selected) {
                    Text(t("Select", "选择")).tag(String?.none)
                    ForEach(model.records, id: \.id) { item in
                        Text(item.id.prefix(8) + " · " + status(item.state)).tag(Optional(item.id))
                    }
                }
            }
            if let record {
                Divider()
                Label(status(record.state), systemImage: ["bound", "complete"].contains(record.state) ? "checkmark.circle" : "link")
                    .font(.headline)
                if ["creating", "pending", "claimed"].contains(record.state) {
                    Text(t("Expires: ", "有效期至：") + Date(timeIntervalSince1970: Double(record.attempt.expiresAtUnixSeconds)).formatted())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(record.attempt.code).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button(t("Copy access code", "复制接入码")) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.attempt.code, forType: .string)
                        }
                        Button(t("Cancel this code", "取消此接入码"), role: .destructive) {
                            Task { do { _ = try await model.cancel(id: record.id) } catch { model.present(error) } }
                        }.disabled(model.busy)
                    }
                }
                Text(t("An RDP password or login error does not invalidate device binding. Interrupted enrollment resumes from this saved attempt.",
                       "RDP 密码错误或登录失败不会使设备绑定失效。接入时断网会从本记录继续。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorCode {
                Text(error == "BOUND_CONTROL_NOT_READY"
                     ? t("Device bound. Waiting for the Windows control service…", "设备已绑定，正在等待 Windows 控制服务…")
                     : t("Connection interrupted. Retrying the saved request: ", "连接中断，正在重试已保存的请求：") + error)
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button(t("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 620)
        .task {
            do { try await model.refresh(); selected = model.records.last?.id }
            catch { model.present(error) }
            while !Task.isCancelled {
                if let selected, let record, !["complete", "cancelled", "expired"].contains(record.state), !model.busy {
                    do {
                        _ = try await model.advance(id: selected,
                            authorize: ownerCheck(targetID: record.targetID, binding: record.targetBinding))
                    } catch { if !Task.isCancelled { model.present(error) } }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func ownerCheck(targetID: UUID?, binding: String?) -> CompanionDevicesModel.MCPAuthorityCheck {
        guard let targetID else { return {} }
        return {
            guard let target = targets.first(where: { $0.targetID == targetID }), target.connectionType == .rdp,
                  target.mcpGrantTargetBinding == binding else { throw EnrollmentError.changed }
        }
    }
    private func status(_ state: String) -> String {
        switch state {
        case "creating": return t("Creating invitation", "正在创建接入码")
        case "pending": return t("Waiting for Windows", "等待 Windows 输入接入码")
        case "claimed": return t("Completing device binding", "正在完成设备绑定")
        case "bound": return t("Device bound", "设备已绑定")
        case "complete": return t("Device bound · control verified", "设备已绑定 · 控制通道已验证")
        case "confirmationRequired": return t("Update Windows and create a new code", "请更新 Windows 端后重新生成接入码")
        case "cancelled": return t("Code cancelled", "接入码已取消")
        default: return t("Code expired", "接入码已过期")
        }
    }
}
#endif
