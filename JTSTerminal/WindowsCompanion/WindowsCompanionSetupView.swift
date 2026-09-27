#if ENABLE_RDP_2
import AppKit
import SwiftUI

nonisolated struct WindowsCompanionSetupTargetContent: Equatable, Sendable {
    var profileName: String
    var connectionKey: String
    var targetID: UUID
    var shortTargetID: String
    var targetIDLabel: String
    var targetIDAccessibilityLabel: String
    var accessibilityLabel: String
}

nonisolated struct WindowsCompanionSetupLocalizedCopy: Equatable, Sendable {
    var hostRequirementTitle: String
    var directRDPDetail: String
    var currentUserInstallationDetail: String
    var connectAndPairDetail: String
    var authorizedPeerDetail: String
    var unauthorizedPeerTitle: String
    var unauthorizedPeerDetail: String
    var pairingRequiredDetail: String
    var authorizedIdentityUnavailableDetail: String
}

enum WindowsCompanionSetupContentPolicy {
    static func targetContent(
        profileName: String,
        connectionKey: String,
        targetID: UUID,
        language: AppLanguage
    ) -> WindowsCompanionSetupTargetContent {
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetID = targetID.uuidString.lowercased()
        return WindowsCompanionSetupTargetContent(
            profileName: trimmedName.isEmpty
                ? language.localized("Unnamed RDP Profile", "未命名 RDP 配置")
                : trimmedName,
            connectionKey: connectionKey,
            targetID: targetID,
            shortTargetID: String(normalizedTargetID.prefix(8)),
            targetIDLabel: language.localized("Profile ID", "配置 ID"),
            targetIDAccessibilityLabel: language.localized(
                "Stable RDP profile identifier",
                "稳定的 RDP 配置标识"
            ),
            accessibilityLabel: language.localized(
                "Windows Companion pairing target",
                "Windows Companion 配对目标"
            )
        )
    }

    static func localizedCopy(
        language: AppLanguage
    ) -> WindowsCompanionSetupLocalizedCopy {
        WindowsCompanionSetupLocalizedCopy(
            hostRequirementTitle: language.localized(
                "Windows 10/11 Pro, Enterprise, or Education x64",
                "Windows 10/11 专业版、企业版或教育版（x64）"
            ),
            directRDPDetail: language.localized(
                "Companion uses the RDP dynamic virtual channel JTS.Companion.v1. It opens no TCP or UDP listener and needs no Tailscale, SSH alias, gateway, or relay.",
                "Companion 使用 RDP 动态虚拟通道 JTS.Companion.v1，不监听任何 TCP/UDP 端口，也不需要 Tailscale、SSH 别名、网关或中继。"
            ),
            currentUserInstallationDetail: language.localized(
                "Install for the current Windows user for visual UI Automation, PowerShell, files, and structured tasks. Elevated tasks still require Windows UAC confirmation. The optional Managed component is installed separately with administrator approval and still never controls the desktop from Session 0.",
                "为当前 Windows 用户安装后，可使用可视化 UI 自动化、PowerShell、文件和结构化任务。提权任务仍需 Windows UAC 确认。可选的托管组件需另行获得管理员批准后安装，并且不会从会话 0 操作桌面。"
            ),
            connectAndPairDetail: language.localized(
                "Connect the visible RDP desktop. When a verified Companion identity appears, compare the fingerprint shown on both Windows and this Mac, then approve it in the Desktop workspace.",
                "连接可见的 RDP 桌面。出现已验证的 Companion 身份后，请比对 Windows 与这台 Mac 上显示的指纹，再在桌面工作区批准配对。"
            ),
            authorizedPeerDetail: language.localized(
                "This profile is the currently authorized peer and may revoke its Windows-side grant. Use this before pairing the same Windows Companion from another saved RDP profile.",
                "此配置是当前已授权的对端，可以撤销 Windows 端授权。在另一个已保存的 RDP 配置中配对同一 Windows Companion 前，请先在这里取消配对。"
            ),
            unauthorizedPeerTitle: language.localized(
                "This profile is not the authorized peer",
                "此配置不是已授权对端"
            ),
            unauthorizedPeerDetail: language.localized(
                "Fail-closed: this profile cannot revoke another profile's grant. Connect the RDP profile that is currently paired, choose Unpair This Mac Client there, then return here and confirm the new fingerprints.",
                "为安全起见，此配置不能撤销另一个配置的授权。请连接当前已配对的 RDP 配置，在其中选择“取消配对此 Mac 客户端”，再返回这里确认新指纹。"
            ),
            pairingRequiredDetail: language.localized(
                "Compare the Windows and Mac fingerprints in the Desktop workspace. Companion features remain blocked until Windows and this Mac both approve.",
                "请在桌面工作区比对 Windows 与 Mac 指纹。Windows 与这台 Mac 双方都批准前，Companion 功能将保持阻止。"
            ),
            authorizedIdentityUnavailableDetail: language.localized(
                "Unpair is blocked because the current authenticated peer identity could not be verified. Disconnect and reconnect this RDP session.",
                "由于无法核验当前已认证的对端身份，取消配对已被阻止。请断开并重新连接此 RDP 会话。"
            )
        )
    }
}

/// Guided, port-free setup for the optional Windows enhancement process. The
/// bundled installer is a hash-bound release artifact; source builds without
/// it show a missing-artifact state instead of selecting an arbitrary executable.
struct WindowsCompanionSetupView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss

    let session: RemoteSession
    let companionState: WindowsCompanionState?
    let companionIdentity: WindowsCompanionPeerIdentity?
    let unpairCompanion: WindowsCompanionUnpairAction?

    @State private var isShowingUnpairConfirmation = false
    @State private var isUnpairing = false
    @State private var didUnpair = false
    @State private var unpairErrorMessage: String?

    private var targetContent: WindowsCompanionSetupTargetContent {
        WindowsCompanionSetupContentPolicy.targetContent(
            profileName: session.name,
            connectionKey: session.connectionKey,
            targetID: session.targetID,
            language: language
        )
    }

    private var localizedCopy: WindowsCompanionSetupLocalizedCopy {
        WindowsCompanionSetupContentPolicy.localizedCopy(language: language)
    }

    private var bundledInstallerURL: URL? {
        ["msix", "exe"].lazy.compactMap {
            Bundle.main.url(forResource: "JTS-Windows-Companion-Setup", withExtension: $0)
        }.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.localized("Windows Companion Setup", "Windows Companion 设置"))
                        .font(.title3.weight(.semibold))
                    Text(targetContent.profileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(targetContent.connectionKey, systemImage: "server.rack")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(targetContent.connectionKey)
                        .accessibilityLabel(targetContent.accessibilityLabel)
                        .accessibilityValue(targetContent.connectionKey)
                        .accessibilityIdentifier("rdp-companion-setup-target")
                    Label(
                        "\(targetContent.targetIDLabel): \(targetContent.shortTargetID)",
                        systemImage: "number"
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help(targetContent.targetID.uuidString.lowercased())
                    .accessibilityLabel(targetContent.targetIDAccessibilityLabel)
                    .accessibilityValue(targetContent.targetID.uuidString.lowercased())
                    .accessibilityIdentifier("rdp-companion-setup-target-id")
                }
                Spacer()
                Button(language.localized("Done", "完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            List {
                Section(language.localized("1. Verify the Windows host", "1. 核验 Windows 主机")) {
                    SetupRow(
                        symbol: "desktopcomputer",
                        title: localizedCopy.hostRequirementTitle,
                        detail: language.localized(
                            "Remote Desktop must be enabled and the account must be allowed to sign in. Windows Home cannot act as the RDP host.",
                            "必须启用远程桌面，并允许该账号登录。Windows Home 不能作为 RDP 主机。"
                        )
                    )
                    SetupRow(
                        symbol: "network",
                        title: language.localized("Same-LAN direct RDP", "同一局域网直连 RDP"),
                        detail: localizedCopy.directRDPDetail
                    )
                }

                Section(language.localized("2. Install the bundled Companion", "2. 安装内置 Companion")) {
                    SetupRow(
                        symbol: "arrow.right.circle.fill",
                        title: language.localized(
                            "Install through this RDP session",
                            "通过当前 RDP 会话安装"
                        ),
                        detail: language.localized(
                            "Close this panel and click the Companion status in the RDP toolbar. When Companion is missing, JTS Terminal offers one-click installation for the signed-in Windows user; you never need to choose an installer file or folder.",
                            "关闭此面板并点击 RDP 工具栏中的 Companion 状态。未检测到 Companion 时，JTS Terminal 会为当前登录的 Windows 用户提供一键安装，无需自行选择安装器文件或路径。"
                        )
                    )

                    if let bundledInstallerURL {
                        SetupRow(
                            symbol: "checkmark.seal.fill",
                            title: language.localized("Bundled installer is included", "已包含内置安装器"),
                            detail: bundledInstallerURL.lastPathComponent
                        )
                    } else {
                        SetupRow(
                            symbol: "exclamationmark.triangle.fill",
                            title: language.localized("Release installer is not bundled", "当前未内置发布版安装器"),
                            detail: language.localized(
                                "This build does not include the required x64 installer and SHA-256 manifest. JTS Terminal only transfers its bundled release installer after verifying its size and hash; it does not select an arbitrary Windows executable.",
                                "此构建未包含所需的 x64 安装器及 SHA-256 清单。JTS Terminal 只会在核验大小和哈希后传输内置发布安装器，不会选择任意 Windows 可执行文件。"
                            )
                        )
                    }
                    Text(localizedCopy.currentUserInstallationDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section(language.localized("3. Connect and pair", "3. 连接并配对")) {
                    SetupRow(
                        symbol: companionSymbol,
                        title: companionTitle,
                        detail: localizedCopy.connectAndPairDetail
                    )
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(WindowsCompanionDVC.channelName, forType: .string)
                    } label: {
                        Label(language.localized("Copy DVC Name", "复制 DVC 名称"), systemImage: "doc.on.doc")
                    }
                }

                Section(language.localized("4. Pairing identity", "4. 配对身份")) {
                    pairingIdentityContent
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 620)
        .confirmationDialog(
            language.localized("Unpair Windows Companion?", "要取消配对 Windows Companion 吗？"),
            isPresented: $isShowingUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.localized("Unpair This Mac Client", "取消配对此 Mac 客户端"), role: .destructive) {
                performUnpair()
            }
            Button(language.localized("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(language.localized(
                "This interrupts Companion UI Automation, PowerShell, file, and structured-task access. It does not delete the saved RDP profile or disconnect the visible desktop. Pairing again always requires a new explicit fingerprint confirmation.",
                "此操作会中断 Companion 的 UI 自动化、PowerShell、文件和结构化任务访问，但不会删除已保存的 RDP 配置，也不会断开可见桌面。再次配对始终需要重新明确确认指纹。"
            ))
        }
        .alert(
            language.localized("Companion Was Not Unpaired", "未能取消 Companion 配对"),
            isPresented: Binding(
                get: { unpairErrorMessage != nil },
                set: { if !$0 { unpairErrorMessage = nil } }
            )
        ) {
            Button(language.localized("OK", "好"), role: .cancel) {}
        } message: {
            Text(unpairErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var pairingIdentityContent: some View {
        Text(language.localized(
            "Each saved RDP profile has its own Mac client identity. A Windows Companion approves exactly one Mac client identity at a time.",
            "每个已保存的 RDP 配置都有独立的 Mac 客户端身份；一个 Windows Companion 同一时间只批准一个 Mac 客户端身份。"
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if let reason = companionState?.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            SetupRow(
                symbol: "info.circle",
                title: language.localized("Current Companion status", "当前 Companion 状态"),
                detail: reason
            )
            .accessibilityIdentifier("rdp-companion-status-detail")
        }

        if let companionIdentity {
            SetupRow(
                symbol: "pc",
                title: language.localized("Windows Companion fingerprint", "Windows Companion 指纹"),
                detail: companionIdentity.fingerprintSHA256
            )
            SetupRow(
                symbol: "person.badge.key.fill",
                title: language.localized("This RDP profile's Mac client fingerprint", "此 RDP 配置的 Mac 客户端指纹"),
                detail: companionIdentity.clientFingerprintSHA256
            )
            SetupRow(
                symbol: "number",
                title: language.localized("Mac client device ID", "Mac 客户端设备 ID"),
                detail: companionIdentity.clientDeviceID.uuidString.lowercased()
            )
        }

        switch companionState?.availability {
        case .ready where companionIdentity != nil:
            Text(localizedCopy.authorizedPeerDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if didUnpair {
                Label(
                    language.localized(
                        "Unpaired. Companion features stay blocked until explicit fingerprint confirmation.",
                        "已取消配对。明确确认指纹前，Companion 功能将保持阻止。"
                    ),
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("rdp-companion-unpaired-status")
            } else if isUnpairing {
                ProgressView(language.localized("Unpairing and blocking Companion access…", "正在取消配对并阻止 Companion 访问…"))
                    .controlSize(.small)
                    .accessibilityIdentifier("rdp-companion-unpair-progress")
            } else {
                Button(role: .destructive) {
                    isShowingUnpairConfirmation = true
                } label: {
                    Label(language.localized("Unpair This Mac Client…", "取消配对此 Mac 客户端…"), systemImage: "person.crop.circle.badge.minus")
                }
                .disabled(unpairCompanion == nil)
                .accessibilityIdentifier("rdp-companion-unpair-button")
            }

        case .incompatible:
            SetupRow(
                symbol: "exclamationmark.shield.fill",
                title: localizedCopy.unauthorizedPeerTitle,
                detail: localizedCopy.unauthorizedPeerDetail
            )

        case .pairingRequired:
            SetupRow(
                symbol: "person.badge.key",
                title: language.localized("Explicit pairing is required", "需要明确配对"),
                detail: localizedCopy.pairingRequiredDetail
            )

        case .ready:
            SetupRow(
                symbol: "exclamationmark.shield.fill",
                title: language.localized("Authorized identity unavailable", "无法读取已授权身份"),
                detail: localizedCopy.authorizedIdentityUnavailableDetail
            )

        case .missing, .unknown, .none:
            Text(language.localized(
                "Connect this RDP profile to inspect or change its Companion pairing.",
                "请连接此 RDP 配置以查看或更改其 Companion 配对。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func performUnpair() {
        guard !isUnpairing, let unpairCompanion else { return }
        isUnpairing = true
        unpairErrorMessage = nil
        Task { @MainActor in
            defer { isUnpairing = false }
            do {
                try await unpairCompanion()
                didUnpair = true
            } catch {
                unpairErrorMessage = error.localizedDescription
            }
        }
    }

    private var companionTitle: String {
        switch companionState?.availability {
        case .ready: return language.localized("Companion paired and ready", "Companion 已配对并就绪")
        case .pairingRequired: return language.localized("Fingerprint confirmation required", "需要确认指纹")
        case .incompatible: return language.localized("Companion incompatible or identity changed", "Companion 不兼容或身份已变化")
        case .missing: return language.localized("Companion not detected", "未检测到 Companion")
        case .unknown, .none: return language.localized("Companion status not checked", "尚未检查 Companion 状态")
        }
    }

    private var companionSymbol: String {
        companionState?.availability == .ready ? "checkmark.shield.fill" : "shield.lefthalf.filled.badge.checkmark"
    }
}

private struct SetupRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

#endif
