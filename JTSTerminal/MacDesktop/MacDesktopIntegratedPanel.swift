#if ENABLE_RDP_2
import AppKit
import SwiftUI
import SwiftData
import JTSCompanionDevices
import JTSRelayEnrollment

struct MacDesktopIntegratedPanel: View {
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    @State private var mode = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker(language.localized("Desktop connection", "桌面连接方式"), selection: $mode) {
                Text(language.localized("Embedded desktop · LAN / VPN", "嵌入式桌面 · 局域网 / VPN")).tag(0)
                Text(language.localized("System Screen Sharing · Relay", "系统屏幕共享 · 公网中继")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if mode == 0 {
                MacDesktopPanel(session: session, workspace: ApplicationWorkspaceRuntime.shared.macDesktops.workspace(for: session.persistentModelID))
                    .id(session.mcpGrantTargetBinding)
            }
            else { MacNativeScreenSharingPanel(session: session).id(session.mcpGrantTargetBinding) }
        }
        .onChange(of: session.mcpGrantTargetBinding) { _, _ in
            MacSystemScreenSharingStore.shared.state(for: session.targetID).stop()
        }
    }
}

private struct MacNativeScreenSharingPanel: View {
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    @StateObject private var state: MacSystemScreenSharingState
    @ObservedObject private var enrollment = NativeScreenSharingEnrollmentModel.shared
    @State private var relayURL = ""
    @State private var selected: String?
    @State private var paired = false
    init(session: RemoteSession) {
        self.session = session
        _state = StateObject(wrappedValue: MacSystemScreenSharingStore.shared.state(for: session.targetID))
    }
    private var record: CompanionEnrollmentRecord? { enrollment.records.first { $0.id == selected && $0.targetID == session.targetID && $0.targetBinding == session.mcpGrantTargetBinding } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(language.localized("System Screen Sharing", "系统屏幕共享"), systemImage: "display.2").font(.title2)
                Text(language.localized(
                    "On the remote Mac, first turn on System Settings → General → Sharing → Screen Sharing, then enter the access code in JTS Mac Companion and confirm the pairing. The connection opens in the Screen Sharing window, which handles the macOS login.",
                    "首次在被控 Mac 开启系统设置 → 通用 → 共享 → 屏幕共享，再用 JTS Mac Companion 接收接入码并确认配对。连接将在系统屏幕共享窗口中打开，macOS 登录由该窗口处理。"
                ))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(language.localized(
                    "The relay supports the standard Screen Sharing mode. The UDP channel required for High Performance mode is not available yet.",
                    "公网中继支持标准屏幕共享模式。高性能模式所需的 UDP 通道尚未提供。"
                ))
                    .font(.caption).foregroundStyle(.secondary)
                RelayStationPicker(origin: $relayURL, language: language)
                    .disabled(enrollment.busy || state.active)
                Button(language.localized("Create Access Code", "生成接入码")) {
                    Task {
                        do {
                            selected = try await enrollment.create(relayURL: relayURL, targetID: session.targetID,
                                targetBinding: session.mcpGrantTargetBinding, authorize: ownerCheck).id
                        } catch { enrollment.present(error) }
                    }
                }.disabled(enrollment.busy || relayURL.isEmpty || state.active)
                if let record {
                    Text(record.state == "complete"
                         ? language.localized("Mac paired", "Mac 已配对")
                         : language.localized("Pairing status: \(record.state)", "配对状态：\(record.state)"))
                    if !["complete", "cancelled", "expired"].contains(record.state) {
                        Text(record.attempt.code).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button(language.localized("Copy Access Code", "复制接入码")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(record.attempt.code, forType: .string)
                            }
                            Button(language.localized("Cancel Access Code", "取消接入码")) { Task { do { _ = try await enrollment.cancel(id: record.id, authorize: ownerCheck) } catch { enrollment.present(error) } } }
                        }.disabled(enrollment.busy)
                    }
                }
                if let error = enrollment.errorCode { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                Divider()
                Text(state.status).accessibilityIdentifier("mac-native-sharing-status")
                Toggle(language.localized("Reconnect automatically after interruptions", "连接中断后自动重连"), isOn: $state.autoReconnect)
                    .help(language.localized(
                        "Reopens the Screen Sharing window with the approved pairing and grant. Disconnecting stops reconnection.",
                        "使用已批准的配对和授权重新打开系统屏幕共享窗口。断开会停止重连。"
                    ))
                HStack {
                    Button(language.localized("Open Screen Sharing", "打开系统屏幕共享")) {
                        let authorize = ownerCheck
                        state.connect(targetBinding: session.mcpGrantTargetBinding) { try authorize() }
                    }
                        .buttonStyle(.borderedProminent).disabled(!paired || state.active)
                    Button(language.localized("Disconnect", "断开")) { state.stop() }.disabled(!state.active)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: session.mcpGrantTargetBinding) { _, _ in state.stop() }
        .task(id: session.mcpGrantTargetBinding) {
            paired = false; selected = nil
            do {
                try await enrollment.refresh()
                selected = enrollment.records.last(where: { $0.targetID == session.targetID && $0.targetBinding == session.mcpGrantTargetBinding })?.id
            } catch { enrollment.present(error) }
            while !Task.isCancelled {
                if let record, !["complete", "cancelled", "expired"].contains(record.state), !enrollment.busy {
                    do { _ = try await enrollment.advance(id: record.id, targetID: session.targetID,
                        targetBinding: session.mcpGrantTargetBinding, authorize: ownerCheck) }
                    catch { if !Task.isCancelled { enrollment.present(error) } }
                }
                paired = false
                if let route = try? await CompanionTargetRouteStore.shared.binding(targetID: session.targetID,
                    targetBinding: session.mcpGrantTargetBinding), let grant = route.rdpGrantID {
                    paired = (try? await CompanionDevicesModel.shared.relayConfiguration(deviceID: route.deviceID, grantID: grant)) != nil
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private var ownerCheck: @MainActor @Sendable () throws -> Void {
        let expected = session.mcpGrantTargetBinding
        return { guard session.connectionType == .macDesktop, session.mcpGrantTargetBinding == expected else { throw CompanionTargetRouteError.changed } }
    }
}
#endif
