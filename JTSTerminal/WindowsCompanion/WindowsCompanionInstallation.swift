#if ENABLE_RDP_2
import Foundation

/// User-visible phases for installing the verified bundled Windows Companion through the
/// already connected RDP session. Runtime and transport details stay outside
/// SwiftUI so the presentation can be driven by the XPC-backed coordinator.
nonisolated enum WindowsCompanionInstallationPhase: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case transferring
    case launching
    case waitingForCompanion
    case pairingRequired
    case ready
    case failed
}

nonisolated struct WindowsCompanionInstallationState: Equatable, Sendable {
    var phase: WindowsCompanionInstallationPhase
    var transferredBytes: Int64
    var totalBytes: Int64?
    var failureMessage: String?

    init(
        phase: WindowsCompanionInstallationPhase,
        transferredBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        failureMessage: String? = nil
    ) {
        self.phase = phase
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.failureMessage = failureMessage
    }

    static let idle = WindowsCompanionInstallationState(phase: .idle)

    var isActive: Bool {
        switch phase {
        case .preparing, .transferring, .launching, .waitingForCompanion:
            return true
        case .idle, .pairingRequired, .ready, .failed:
            return false
        }
    }

    var canOfferInstallation: Bool {
        phase == .idle || phase == .failed
    }

    var isCompleted: Bool {
        phase == .pairingRequired || phase == .ready
    }

    var progressFraction: Double? {
        guard phase == .transferring,
              let totalBytes,
              totalBytes > 0 else {
            return nil
        }

        return min(
            max(Double(transferredBytes) / Double(totalBytes), 0),
            1
        )
    }
}

nonisolated enum WindowsCompanionStatusTapAction: Equatable, Sendable {
    case confirmInstallation
    case showInstallationProgress
    case showSetup
}

nonisolated enum WindowsCompanionStatusTapPolicy {
    static func action(
        availability: WindowsCompanionAvailability?,
        installation: WindowsCompanionInstallationState
    ) -> WindowsCompanionStatusTapAction {
        if installation.isActive || installation.phase == .failed {
            return .showInstallationProgress
        }
        if availability == .missing, installation.canOfferInstallation {
            return .confirmInstallation
        }
        return .showSetup
    }
}

nonisolated enum WindowsCompanionInstallationReconciliationPolicy {
    static func reconcile(
        proposed: WindowsCompanionInstallationState,
        currentAvailability: WindowsCompanionAvailability,
        incompatibleFailureMessage: String
    ) -> WindowsCompanionInstallationState {
        switch currentAvailability {
        case .pairingRequired:
            return WindowsCompanionInstallationState(phase: .pairingRequired)
        case .ready:
            return WindowsCompanionInstallationState(phase: .ready)
        case .incompatible:
            return WindowsCompanionInstallationState(
                phase: .failed,
                failureMessage: incompatibleFailureMessage
            )
        case .unknown, .missing:
            return proposed.isCompleted ? .idle : proposed
        }
    }
}

struct WindowsCompanionInstallationContent: Equatable {
    var title: String
    var detail: String
}

enum WindowsCompanionInstallationContentPolicy {
    static func confirmationTitle(language: AppLanguage) -> String {
        language.localized(
            "Install Windows Companion?",
            "安装 Windows Companion？"
        )
    }

    static func confirmationMessage(
        profileName: String,
        connectionKey: String,
        language: AppLanguage
    ) -> String {
        let normalizedName = normalizedProfileName(profileName, language: language)
        return language.localized(
            "JTS Terminal will send and start its bundled, hash-verified Companion installer through the current RDP session “\(normalizedName)” (\(connectionKey)) for the signed-in Windows user. Companion uses the existing RDP dynamic virtual channel and opens no additional TCP or UDP listener. Installation does not request administrator access; elevated tasks still require Windows UAC confirmation.",
            "JTS Terminal 将通过当前 RDP 会话“\(normalizedName)”（\(connectionKey)）向当前登录的 Windows 用户发送并启动内置且已核验哈希的 Companion 安装器。Companion 使用现有 RDP 动态虚拟通道，不会额外打开 TCP/UDP 监听端口。安装不申请管理员权限；提权任务仍需 Windows UAC 确认。"
        )
    }

    static func installTitle(language: AppLanguage) -> String {
        language.localized("Install", "安装")
    }

    static func cancelTitle(language: AppLanguage) -> String {
        language.localized("Cancel", "取消")
    }

    static func closeTitle(language: AppLanguage) -> String {
        language.localized("Close", "关闭")
    }

    static func retryTitle(language: AppLanguage) -> String {
        language.localized("Retry Installation", "重试安装")
    }

    static func sheetTitle(language: AppLanguage) -> String {
        language.localized(
            "Windows Companion Installation",
            "Windows Companion 安装"
        )
    }

    static func content(
        for state: WindowsCompanionInstallationState,
        language: AppLanguage
    ) -> WindowsCompanionInstallationContent {
        switch state.phase {
        case .idle:
            return WindowsCompanionInstallationContent(
                title: language.localized("Ready to install", "准备安装"),
                detail: language.localized(
                    "The bundled installer is ready to be verified and sent through this RDP session.",
                    "内置安装器已准备好核验并通过此 RDP 会话发送。"
                )
            )
        case .preparing:
            return WindowsCompanionInstallationContent(
                title: language.localized("Preparing installer", "正在准备安装器"),
                detail: language.localized(
                    "Verifying the bundled release installer's size and SHA-256 before transfer.",
                    "正在传输前核验内置发布安装器的大小和 SHA-256。"
                )
            )
        case .transferring:
            return WindowsCompanionInstallationContent(
                title: language.localized("Sending to Windows", "正在发送到 Windows"),
                detail: transferDetail(for: state, language: language)
            )
        case .launching:
            return WindowsCompanionInstallationContent(
                title: language.localized("Starting installer", "正在启动安装器"),
                detail: language.localized(
                    "Windows is starting the verified installer for the signed-in user.",
                    "Windows 正在为当前登录用户启动已核验的安装器。"
                )
            )
        case .waitingForCompanion:
            return WindowsCompanionInstallationContent(
                title: language.localized("Waiting for Companion", "正在等待 Companion"),
                detail: language.localized(
                    "Installation started. Waiting for Companion to join this RDP session.",
                    "安装已启动，正在等待 Companion 加入当前 RDP 会话。"
                )
            )
        case .pairingRequired:
            return WindowsCompanionInstallationContent(
                title: language.localized("Installed — pairing required", "安装完成——需要配对"),
                detail: language.localized(
                    "Companion is running. Compare the Windows and Mac fingerprints in the RDP workspace, then approve the pairing.",
                    "Companion 已运行。请在 RDP 工作区比对 Windows 与 Mac 指纹，然后批准配对。"
                )
            )
        case .ready:
            return WindowsCompanionInstallationContent(
                title: language.localized("Companion is ready", "Companion 已就绪"),
                detail: language.localized(
                    "The signed-in Windows user is connected through this RDP session.",
                    "当前登录的 Windows 用户已通过此 RDP 会话连接。"
                )
            )
        case .failed:
            return WindowsCompanionInstallationContent(
                title: language.localized("Installation failed", "安装失败"),
                detail: normalizedFailureMessage(state.failureMessage, language: language)
            )
        }
    }

    private static func transferDetail(
        for state: WindowsCompanionInstallationState,
        language: AppLanguage
    ) -> String {
        guard let totalBytes = state.totalBytes,
              totalBytes > 0 else {
            return language.localized(
                "Transferring the verified bundled installer over the current RDP session.",
                "正在通过当前 RDP 会话传输已核验的内置安装器。"
            )
        }

        let transferred = ByteCountFormatter.string(
            fromByteCount: max(state.transferredBytes, 0),
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: totalBytes,
            countStyle: .file
        )
        return language.localized(
            "\(transferred) of \(total)",
            "\(transferred) / \(total)"
        )
    }

    private static func normalizedProfileName(
        _ profileName: String,
        language: AppLanguage
    ) -> String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? language.localized("Unnamed RDP Profile", "未命名 RDP 配置")
            : trimmed
    }

    private static func normalizedFailureMessage(
        _ failureMessage: String?,
        language: AppLanguage
    ) -> String {
        guard let failureMessage else {
            return language.localized(
                "The installer could not be completed through this RDP session. Retry after confirming the desktop is still connected.",
                "无法通过当前 RDP 会话完成安装。请确认桌面仍已连接后重试。"
            )
        }

        let trimmed = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? language.localized(
                "The installer could not be completed through this RDP session. Retry after confirming the desktop is still connected.",
                "无法通过当前 RDP 会话完成安装。请确认桌面仍已连接后重试。"
            )
            : trimmed
    }
}
#endif
