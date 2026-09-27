#if ENABLE_RDP_2
import SwiftUI

struct WindowsCompanionInstallationProgressView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss

    let session: RemoteSession
    let state: WindowsCompanionInstallationState
    let install: (() -> Void)?

    private var content: WindowsCompanionInstallationContent {
        WindowsCompanionInstallationContentPolicy.content(
            for: state,
            language: language
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 18) {
                statusContent
                actionBar
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(WindowsCompanionInstallationContentPolicy.sheetTitle(language: language))
                    .font(.title3.weight(.semibold))
                Text(normalizedProfileName)
                    .font(.subheadline.weight(.medium))
                Label(session.connectionKey, systemImage: "server.rack")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.connectionKey)
            }

            Spacer(minLength: 12)
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(content.title)
                .font(.headline)
            Text(content.detail)
                .font(.subheadline)
                .foregroundStyle(state.phase == .failed ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.isActive {
                progressIndicator
                Text(language.localized(
                    "You can close this window. Installation and Companion detection will continue in the current RDP session.",
                    "你可以关闭此窗口；安装与 Companion 检测会在当前 RDP 会话中继续。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(statusAccessibilityIdentifier)
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if let fraction = state.progressFraction {
            ProgressView(value: fraction)
                .accessibilityValue(
                    Text("\(Int((fraction * 100).rounded()))%")
                )
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()

            switch state.phase {
            case .preparing, .transferring, .launching, .waitingForCompanion:
                Button(WindowsCompanionInstallationContentPolicy.closeTitle(language: language), role: .cancel) {
                    dismiss()
                }
                .accessibilityIdentifier("rdp-companion-install-close-button")
            case .failed:
                Button(WindowsCompanionInstallationContentPolicy.closeTitle(language: language), role: .cancel) {
                    dismiss()
                }

                Button(WindowsCompanionInstallationContentPolicy.retryTitle(language: language)) {
                    install?()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(install == nil)
                .accessibilityIdentifier("rdp-companion-install-retry")
            case .idle:
                Button(WindowsCompanionInstallationContentPolicy.closeTitle(language: language), role: .cancel) {
                    dismiss()
                }

                Button(WindowsCompanionInstallationContentPolicy.installTitle(language: language)) {
                    install?()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(install == nil)
                .accessibilityIdentifier("rdp-companion-install-start")
            case .pairingRequired, .ready:
                Button(WindowsCompanionInstallationContentPolicy.closeTitle(language: language)) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var normalizedProfileName: String {
        let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? language.localized("Unnamed RDP Profile", "未命名 RDP 配置")
            : trimmed
    }

    private var statusSymbol: String {
        switch state.phase {
        case .idle:
            return "shippingbox"
        case .preparing, .transferring, .launching, .waitingForCompanion:
            return "arrow.triangle.2.circlepath"
        case .pairingRequired:
            return "person.badge.key.fill"
        case .ready:
            return "checkmark.shield.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .pairingRequired:
            return .orange
        case .ready:
            return .green
        case .failed:
            return .red
        case .idle, .preparing, .transferring, .launching, .waitingForCompanion:
            return .accentColor
        }
    }

    private var statusAccessibilityIdentifier: String {
        switch state.phase {
        case .failed:
            return "rdp-companion-install-error"
        case .pairingRequired, .ready:
            return "rdp-companion-install-success"
        case .idle, .preparing, .transferring, .launching, .waitingForCompanion:
            return "rdp-companion-install-progress"
        }
    }
}
#endif
