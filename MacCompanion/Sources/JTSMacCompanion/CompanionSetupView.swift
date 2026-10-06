import SwiftUI

/// Setup stays in the visible host window. Background starts only inspect
/// existing authorization; they never present macOS privacy permission prompts.
struct CompanionSetupView: View {
    @ObservedObject var server: CompanionServer
    let enableAutomaticSharing: () -> Void

    var body: some View {
        if !server.automaticSharing || server.clients.isEmpty || !server.screenPermission {
            Section("首次设置") {
                step(1, title: "允许屏幕录制", complete: server.screenPermission,
                     detail: "在下方授权屏幕录制。需要远程键鼠时再授权辅助功能；也可以只查看。")
                step(2, title: "确认第一台连接电脑", complete: !server.clients.isEmpty,
                     detail: "开始共享，复制配对邀请到另一台电脑的 JTS Terminal，再在此 Mac 允许连接。")
                HStack {
                    step(3, title: "启用自动启动与共享", complete: server.automaticSharing,
                         detail: "配对完成后启用，后续登录、唤醒和权限恢复时自动接受已授权电脑。")
                    Spacer()
                    if !server.automaticSharing {
                        Button("启用", action: enableAutomaticSharing)
                            .disabled(!server.canEnableAutomaticSharing)
                    }
                }
            }
        }
    }

    private func step(_ number: Int, title: String, complete: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(complete ? .green : .secondary)
                .font(.title3)
                .accessibilityLabel(complete ? "已完成" : "第 \(number) 步")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
