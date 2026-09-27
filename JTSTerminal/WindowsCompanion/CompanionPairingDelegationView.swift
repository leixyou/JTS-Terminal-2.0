#if ENABLE_RDP_2
import AppKit
import SwiftUI

/// A compact status surface. Enabling device AI control already includes
/// pairing delegation; only restoring an explicitly revoked grant is an action.
struct CompanionPairingDelegationView: View {
    @Environment(\.appLanguage) private var language
    let grant: CompanionPairingDelegationGrant
    let enrollmentExport: CompanionPairingDelegationExport?
    let availability: WindowsCompanionAvailability
    var confirm: (@MainActor () async throws -> Void)?
    var revoke: (@MainActor () async throws -> Void)?
    var restore: (@MainActor () async throws -> Void)?

    @State private var isPerformingAction = false
    @State private var errorMessage: String?
    @State private var didCopyRequest = false
    @State private var showsIdentityDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    summary.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    actions
                }
                VStack(alignment: .leading, spacing: 6) {
                    summary
                    actions
                }
            }

            DisclosureGroup(
                language.localized("Device fingerprints", "设备指纹"),
                isExpanded: $showsIdentityDetails
            ) {
                identityDetails
                    .padding(.top, 4)
            }
            .font(.caption2)
            .accessibilityIdentifier("rdp-companion-delegation-details")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .help(errorMessage)
                    .accessibilityLabel(errorMessage)
                    .accessibilityIdentifier("rdp-companion-delegation-error")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rdp-companion-delegation")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(
                grant.isRevoked
                    ? language.localized("Device AI pairing delegation revoked", "设备 AI 配对委托已撤销")
                    : language.localized("AI control includes pairing delegation", "AI 控制已包含配对委托"),
                systemImage: grant.isRevoked ? "hand.raised" : "person.badge.key"
            )
            .font(.caption.weight(.semibold))

            Text(statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rdp-companion-delegation-status")
        }
    }

    private var statusDetail: String {
        if grant.isRevoked {
            return grant.pendingRemoteRevocation
                ? language.localized("Revoked on this Mac · Windows confirmation pending", "本机已撤销 · 等待 Windows 确认")
                : language.localized("Revocation confirmed by Windows", "Windows 已确认撤销")
        }
        let status: String
        switch availability {
        case .ready:
            status = language.localized("Ready", "已就绪")
        case .pairingRequired:
            status = language.localized("Windows enrollment pending", "等待 Windows 完成登记")
        case .incompatible:
            status = language.localized("Pairing needs attention", "配对尚未完成")
        default:
            status = language.localized("Waiting for Companion connection", "等待 Companion 连接")
        }
        return language.localized("Source: device AI control · \(status)", "来源：设备 AI 控制 · \(status)")
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if isPerformingAction {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel(language.localized("Updating device pairing", "正在更新设备配对"))
            }
            if grant.isRevoked {
                Button(language.localized("Re-enable AI control", "重新启用 AI 控制")) {
                    perform(restore)
                }
                .disabled(restore == nil || isPerformingAction)
                .accessibilityIdentifier("rdp-companion-delegation-restore")
            } else {
                Button(language.localized(
                    didCopyRequest ? "Request copied" : "Copy enrollment request",
                    didCopyRequest ? "已复制登记请求" : "复制登记请求"
                )) {
                    copyEnrollmentRequest()
                }
                .disabled(validExport == nil || isPerformingAction)
                .help(language.localized(
                    "Copy the public device enrollment JSON for Windows Companion.",
                    "复制用于 Windows Companion 的设备登记 JSON，仅包含公开身份信息。"
                ))
                .accessibilityIdentifier("rdp-companion-delegation-copy-request")

                if availability != .ready {
                    Button(language.localized("Complete pairing", "完成配对")) {
                        perform(confirm)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(confirm == nil || isPerformingAction)
                    .accessibilityIdentifier("rdp-companion-delegation-confirm")
                }

                Button(language.localized("Revoke", "撤销"), role: .destructive) {
                    perform(revoke)
                }
                .disabled(revoke == nil || isPerformingAction)
                .accessibilityIdentifier("rdp-companion-delegation-revoke")
            }
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var identityDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            identityRow(language.localized("Grant", "委托 ID"), value: grant.grantID.uuidString.lowercased())
            identityRow(language.localized("Windows fingerprint", "Windows 指纹"), value: grant.windowsFingerprintSHA256)
            identityRow(language.localized("Mac fingerprint", "Mac 指纹"), value: grant.macFingerprintSHA256)
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identityRow(_ label: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var validExport: CompanionPairingDelegationExport? {
        guard !grant.isRevoked,
              let enrollmentExport,
              enrollmentExport.grant.grantID == grant.grantID else { return nil }
        return enrollmentExport
    }

    private func copyEnrollmentRequest() {
        guard let exported = validExport,
              let text = String(data: exported.requestJSON, encoding: .utf8) else { return }
        errorMessage = nil
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            didCopyRequest = true
        } else {
            errorMessage = language.localized("The enrollment request could not be copied.", "无法复制登记请求。")
        }
    }

    private func perform(_ action: (@MainActor () async throws -> Void)?) {
        guard let action, !isPerformingAction else { return }
        isPerformingAction = true
        errorMessage = nil
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
