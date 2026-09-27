#if ENABLE_RDP_2
import AppKit
import SwiftUI

/// UI-only adapter for the native RDP workspace. The signed FreeRDP runtime can
/// inject live state, frames, and actions without coupling this view to its XPC
/// implementation. A nil state means the configured profile has not connected
/// yet; runtime failures are reported through an explicit session state.
nonisolated struct RDPActiveAIClientIdentity: Equatable, Sendable {
    var authorizationID: String
    var displayIdentity: String
    var isControlling = false
}

struct RDPDesktopWorkspacePresentation {
    var state: RDPDesktopSessionState?
    var frameImage: NSImage?
    var certificateChallenge: RDPCertificateChallenge?
    var companionPairing: WindowsCompanionPeerIdentity?
    var companionDelegation: CompanionPairingDelegationGrant?
    var companionDelegationExport: CompanionPairingDelegationExport?
    var companionIdentity: WindowsCompanionPeerIdentity?
    var companionInstallation: WindowsCompanionInstallationState = .idle
    var isCompanionInstallerClipboardReady = false
    var isAIViewing = false
    var isAIControlActive = false
    var isAIControlStopping = false
    var activeAIClientIdentities: [RDPActiveAIClientIdentity] = []
    var connect: (() -> Void)?
    var disconnect: (() -> Void)?
    var takeManualControl: (() -> Void)?
    var emergencyStop: (() -> Void)?
    var trustCertificateOnce: (@MainActor () async throws -> Void)?
    var pinCertificate: (@MainActor () async throws -> Void)?
    var approveCompanionPairing: (() -> Void)?
    var confirmDelegatedPairing: (@MainActor () async throws -> Void)?
    var revokeDelegatedPairing: (@MainActor () async throws -> Void)?
    var restoreDelegatedPairing: (@MainActor () async throws -> Void)?
    var unpairCompanion: WindowsCompanionUnpairAction?
    var installCompanion: (() -> Void)?
    var performManualAction: ((DesktopActionRequest) -> Void)?
    var resizeDesktop: ((Int, Int) -> Void)?
    var openLocalNetworkSettings: (() -> Bool)?
}

enum RDPDesktopWorkspaceIdleContent {
    static func statusTitle(language: AppLanguage) -> String {
        language.localized("Ready to connect", "准备连接")
    }

    static func surfaceTitle(language: AppLanguage) -> String {
        language.localized("Ready to Connect", "准备连接")
    }

    static func detail(language: AppLanguage) -> String {
        language.localized(
            "This RDP profile is configured and has not connected yet. Connect to open a visible native RDP workspace on this Mac.",
            "此 RDP 配置已就绪，尚未连接。点击“连接”可在这台 Mac 上打开可见的原生 RDP 工作区。"
        )
    }
}

enum RDPDesktopWorkspaceFailureContent {
    private static let maximumMachineCodeLength = 96
    private static let allowedPrefixes = ["ERRCONNECT_", "FREERDP_", "RDP_"]

    static func machineErrorCode(for state: RDPDesktopSessionState?) -> String? {
        guard state?.phase == .failed else { return nil }
        return sanitizedMachineErrorCode(state?.lastErrorCode)
    }

    static func sanitizedMachineErrorCode(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumMachineCodeLength,
              allowedPrefixes.contains(where: value.hasPrefix),
              let first = value.unicodeScalars.first,
              isASCIICapital(first),
              let last = value.unicodeScalars.last,
              isASCIICapital(last) || isASCIIDigit(last),
              value.unicodeScalars.allSatisfy(isMachineCodeCharacter) else {
            return nil
        }
        return value
    }

    static func errorCodeTitle(language: AppLanguage) -> String {
        language.localized("Technical error code", "技术错误码")
    }

    static func errorCodeAccessibilityLabel(language: AppLanguage) -> String {
        language.localized("RDP connection error code", "RDP 连接错误码")
    }

    nonisolated private static func isMachineCodeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isASCIICapital(scalar) || isASCIIDigit(scalar) || scalar.value == 95
    }

    nonisolated private static func isASCIICapital(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value)
    }

    nonisolated private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }
}

enum RDPDesktopLocalNetworkBlockedContent {
    static func title(language: AppLanguage) -> String {
        language.localized(
            "macOS Blocked This Local Network Connection",
            "此本地网络连接被 macOS 阻止"
        )
    }

    static func detail(host: String, language: AppLanguage) -> String {
        language.localized(
            "Network.framework reported that macOS blocked this running JTS Terminal copy from reaching \(host). This does not mean the Local Network switch is necessarily off. If it is already enabled, quit other JTS Terminal copies and reopen this app from one stable location before retrying. RDP and Windows Companion contact only the saved host; they do not scan the LAN or open an additional TCP/UDP listener.",
            "Network.framework 报告 macOS 阻止了当前这份 JTS Terminal 访问 \(host)。这不表示“本地网络”开关一定关闭。若开关已经开启，请退出其他 JTS Terminal 副本，并从一个固定位置重新打开当前版本后再试。RDP 与 Windows Companion 只访问已保存的主机，不会扫描局域网，也不会打开额外的 TCP/UDP 监听端口。"
        )
    }

    static func retryTitle(language: AppLanguage) -> String {
        language.localized("Check and Connect Again", "重新检测并连接")
    }
}

enum RDPDesktopLocalNetworkDecisionPendingContent {
    static func title(language: AppLanguage) -> String {
        language.localized(
            "Finish Local Network Access for This App Copy",
            "请完成当前副本的本地网络授权"
        )
    }

    static func detail(host: String, language: AppLanguage) -> String {
        language.localized(
            "macOS has not finished the Local Network decision for this exact JTS Terminal build. Look for the system prompt, choose Allow, then check again. An enabled entry for another JTS Terminal copy does not authorize this build. RDP and Windows Companion contact only the saved host \(host); they do not scan the LAN or open an additional TCP/UDP listener.",
            "macOS 尚未完成对当前这份 JTS Terminal 的本地网络授权决定。请在系统提示中选择“允许”，然后重新检测。其他 JTS Terminal 副本显示为已开启，并不代表当前构建已获授权。RDP 与 Windows Companion 只访问已保存的主机 \(host)，不会扫描局域网，也不会打开额外的 TCP/UDP 监听端口。"
        )
    }

    static func retryTitle(language: AppLanguage) -> String {
        language.localized(
            "I Finished the Decision — Check Again",
            "已完成授权，重新检测"
        )
    }
}

nonisolated struct RDPDesktopWorkspaceInputFailure: Equatable, Sendable {
    var code: String
    var message: String
    var disablesAdaptiveResolution: Bool
}

nonisolated enum RDPDesktopWorkspaceInputFailurePolicy {
    static func visibleFailure(
        phase: RDPConnectionPhase?,
        code: String?,
        message: String?
    ) -> RDPDesktopWorkspaceInputFailure? {
        guard phase == .connected,
              RDPDesktopInputFailurePolicy.isTransientInputFailureCode(code),
              let code,
              let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }
        return RDPDesktopWorkspaceInputFailure(
            code: code,
            message: message,
            disablesAdaptiveResolution: disablesAdaptiveResolution(for: code)
        )
    }

    static func disablesAdaptiveResolution(for code: String?) -> Bool {
        code == RDPDesktopInputFailurePolicy.displayControlUnavailableCode
    }
}

nonisolated enum RDPDesktopWorkspaceControlPolicy {
    static func showsAIInterruptionControls(
        isAIViewing: Bool,
        isAIControlActive: Bool,
        isAIControlStopping: Bool = false
    ) -> Bool {
        isAIViewing || isAIControlActive || isAIControlStopping
    }
}

nonisolated enum RDPDesktopAIActivityState: Equatable, Sendable {
    case inactive
    case viewing
    case controlling
    case stopping

    static func resolved(
        isViewing: Bool,
        isControlActive: Bool,
        isControlStopping: Bool
    ) -> RDPDesktopAIActivityState {
        if isControlStopping {
            return .stopping
        }
        if isControlActive {
            return .controlling
        }
        return isViewing ? .viewing : .inactive
    }
}

struct RDPDesktopAIActivityAnnouncementPolicy {
    static func announcement(
        previous: RDPDesktopAIActivityState?,
        current: RDPDesktopAIActivityState,
        language: AppLanguage
    ) -> String? {
        guard previous != current else { return nil }
        switch current {
        case .inactive:
            guard previous != nil, previous != .inactive else { return nil }
            return language.localized(
                "AI activity stopped. Remote input is under your control.",
                "AI 活动已停止，远程输入现由你控制。"
            )
        case .viewing:
            return language.localized(
                "AI started viewing the remote desktop.",
                "AI 已开始查看远程桌面。"
            )
        case .controlling:
            return language.localized(
                "AI started controlling the remote desktop.",
                "AI 已开始控制远程桌面。"
            )
        case .stopping:
            return language.localized(
                "AI control is stopping.",
                "AI 控制正在停止。"
            )
        }
    }
}

@MainActor
private enum RDPDesktopVoiceOverAnnouncer {
    static func announce(_ message: String) {
        guard let element = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
            return
        }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

struct RDPDesktopAIClientIdentityContent: Equatable, Sendable {
    let visibleSummary: String
    let accessibilityValue: String
    let help: String
    let lineLimit: Int
}

enum RDPDesktopAIClientIdentityContentPolicy {
    static let maximumVisibleCharacterCount = 128

    static func content(
        identities: [RDPActiveAIClientIdentity],
        layout: RDPDesktopControlBarLayout,
        language: AppLanguage
    ) -> RDPDesktopAIClientIdentityContent {
        guard !identities.isEmpty else {
            let unknown = language.localized("Unknown client", "未知客户端")
            return RDPDesktopAIClientIdentityContent(
                visibleSummary: unknown,
                accessibilityValue: unknown,
                help: unknown,
                lineLimit: layout == .wide ? 1 : 2
            )
        }

        let primary = identities.first(where: \.isControlling) ?? identities[0]
        let visibleIdentities = [primary] + identities.filter {
            $0.authorizationID != primary.authorizationID
        }
        let fullEntries = identities.map { identity in
            fullEntry(identity, language: language)
        }
        let helpEntries = identities.map { identity in
            helpEntry(identity, language: language)
        }

        let visibleSummary: String
        if layout == .narrow, identities.count > 1 {
            let remainingCount = identities.count - 1
            let suffix = language.localized(
                " · +\(remainingCount) more",
                " · 另有 \(remainingCount) 个"
            )
            visibleSummary = summarized(
                roleLabeledName(primary, language: language),
                preserving: suffix
            )
        } else {
            visibleSummary = summarized(
                visibleIdentities
                    .map { roleLabeledName($0, language: language) }
                    .joined(separator: " · ")
            )
        }

        return RDPDesktopAIClientIdentityContent(
            visibleSummary: visibleSummary,
            accessibilityValue: fullEntries.joined(separator: " "),
            help: helpEntries.joined(separator: "\n\n"),
            lineLimit: layout == .wide ? 1 : 2
        )
    }

    private static func roleLabeledName(
        _ identity: RDPActiveAIClientIdentity,
        language: AppLanguage
    ) -> String {
        guard identity.isControlling else {
            return identity.displayIdentity
        }
        return language.localized(
            "Control: \(identity.displayIdentity)",
            "控制：\(identity.displayIdentity)"
        )
    }

    private static func fullEntry(
        _ identity: RDPActiveAIClientIdentity,
        language: AppLanguage
    ) -> String {
        let role = identity.isControlling
            ? language.localized("Control", "控制")
            : language.localized("Viewing", "查看")
        return language.localized(
            "\(role): \(identity.displayIdentity). Authorization ID: \(identity.authorizationID).",
            "\(role)：\(identity.displayIdentity)。授权 ID：\(identity.authorizationID)。"
        )
    }

    private static func helpEntry(
        _ identity: RDPActiveAIClientIdentity,
        language: AppLanguage
    ) -> String {
        let role = identity.isControlling
            ? language.localized("Control", "控制")
            : language.localized("Viewing", "查看")
        return "\(role): \(identity.displayIdentity)\n\(identity.authorizationID)"
    }

    private static func summarized(
        _ value: String,
        preserving suffix: String = ""
    ) -> String {
        let maximumPrefixCount = maximumVisibleCharacterCount - suffix.count
        guard maximumPrefixCount > 0 else {
            return String(suffix.suffix(maximumVisibleCharacterCount))
        }
        guard value.count + suffix.count > maximumVisibleCharacterCount else {
            return value + suffix
        }
        let ellipsis = "…"
        let prefixCount = max(maximumPrefixCount - ellipsis.count, 0)
        return String(value.prefix(prefixCount)) + ellipsis + suffix
    }
}

nonisolated enum RDPDesktopControlBarLayout: Equatable, Sendable {
    case wide
    case narrow
}

nonisolated enum RDPDesktopControlBarSecondaryPlacement: Equatable, Sendable {
    case inline
    case overflowMenu
}

nonisolated enum RDPDesktopControlBarSecondaryAction: Hashable, Sendable {
    case companion
    case desktopScale
    case fullScreen
}

nonisolated enum RDPDesktopControlBarCriticalAction: Hashable, Sendable {
    case aiAccess
    case takeControl
    case emergencyStop
    case connect
    case disconnect
}

nonisolated struct RDPDesktopControlBarPlan: Equatable, Sendable {
    var secondaryPlacement: RDPDesktopControlBarSecondaryPlacement
    var secondaryActions: [RDPDesktopControlBarSecondaryAction]
    var criticalActions: [RDPDesktopControlBarCriticalAction]
    var usesIconOnlyCriticalLabels: Bool
}

nonisolated enum RDPDesktopControlBarPolicy {
    static func plan(
        layout: RDPDesktopControlBarLayout,
        isConnected: Bool,
        shouldOfferConnect: Bool,
        showsAIInterruptionControls: Bool,
        showsPendingAIAccessRequest: Bool
    ) -> RDPDesktopControlBarPlan {
        var secondaryActions: [RDPDesktopControlBarSecondaryAction] = [.companion]
        if isConnected {
            secondaryActions.append(contentsOf: [.desktopScale, .fullScreen])
        }

        var criticalActions: [RDPDesktopControlBarCriticalAction] = []
        if showsPendingAIAccessRequest {
            criticalActions.append(.aiAccess)
        }
        if showsAIInterruptionControls {
            criticalActions.append(contentsOf: [.takeControl, .emergencyStop])
        }
        if isConnected {
            criticalActions.append(.disconnect)
        } else if shouldOfferConnect {
            criticalActions.append(.connect)
        }

        return RDPDesktopControlBarPlan(
            secondaryPlacement: layout == .wide ? .inline : .overflowMenu,
            secondaryActions: secondaryActions,
            criticalActions: criticalActions,
            usesIconOnlyCriticalLabels: false
        )
    }

    static func narrowCriticalActionRows(
        _ actions: [RDPDesktopControlBarCriticalAction]
    ) -> [[RDPDesktopControlBarCriticalAction]] {
        stride(from: 0, to: actions.count, by: 2).map { start in
            Array(actions[start..<min(start + 2, actions.count)])
        }
    }
}

nonisolated enum RDPDesktopWorkspaceConnectionAction: Equatable, Sendable {
    case connect
    case reloadCertificateDetails
    case none
}

nonisolated enum RDPDesktopWorkspaceConnectionPolicy {
    static func action(
        phase: RDPConnectionPhase?,
        hasCertificateChallenge: Bool
    ) -> RDPDesktopWorkspaceConnectionAction {
        if hasCertificateChallenge {
            return .none
        }
        switch phase {
        case .none, .closed, .failed:
            return .connect
        case .awaitingCertificateTrust:
            return .reloadCertificateDetails
        case .connecting, .authenticating, .reconnecting, .connected:
            return .none
        }
    }
}

enum RDPDesktopCertificateWarningContent {
    static func hostMismatchDetail(
        host: String,
        language: AppLanguage
    ) -> String {
        language.localized(
            "The certificate identity does not match \(host). Verify the server address and certificate identity before trusting it.",
            "证书身份与 \(host) 不匹配。信任前请核对服务器地址和证书身份。"
        )
    }

    static func previousFingerprintDetail(
        fingerprint: String,
        isPinned: Bool,
        language: AppLanguage
    ) -> String {
        if isPinned {
            return language.localized(
                "Pinned fingerprint: \(fingerprint)",
                "原固定指纹：\(fingerprint)"
            )
        }
        return language.localized(
            "Previously trusted fingerprint: \(fingerprint)",
            "本次连接先前信任的指纹：\(fingerprint)"
        )
    }

    static func changedCertificateBlockingDetail(language: AppLanguage) -> String {
        language.localized(
            "Trust Once and Verify and Pin are disabled because the server reported a changed certificate. Verify the new fingerprint through an independent channel, then update the saved pin in Server Properties only if the change is expected.",
            "服务器报告证书已变化，因此“仅信任本次”和“核验并固定指纹”均已禁用。请通过独立渠道核验新指纹；仅在确认变更符合预期后，才可在“服务器属性”中更新已保存的指纹。"
        )
    }

    static func decisionFailureDetail(
        errorDescription: String,
        language: AppLanguage
    ) -> String {
        let detail = errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return language.localized(
                "The certificate decision could not be applied. The connection remains blocked.",
                "无法应用证书决定，连接仍保持阻断。"
            )
        }
        return detail
    }
}

nonisolated enum RDPDesktopCertificateDecisionDisposition: Equatable, Sendable {
    case actionsAvailable
    case blockedChangedCertificate(previousSHA256: String?)
}

nonisolated enum RDPDesktopCertificateDecisionPolicy {
    static func disposition(
        changed: Bool,
        pinnedMismatch: Bool = false,
        oldSHA256: String?
    ) -> RDPDesktopCertificateDecisionDisposition {
        changed || pinnedMismatch
            ? .blockedChangedCertificate(previousSHA256: oldSHA256)
            : .actionsAvailable
    }
}

nonisolated enum RDPDesktopInputFocusDestination: Equatable, Sendable {
    case local
    case remote
}

nonisolated struct RDPDesktopInputFocusCommand: Equatable, Sendable {
    let generation: UInt64
    let destination: RDPDesktopInputFocusDestination

    static let initial = RDPDesktopInputFocusCommand(
        generation: 0,
        destination: .local
    )

    func advanced(
        to destination: RDPDesktopInputFocusDestination
    ) -> RDPDesktopInputFocusCommand {
        RDPDesktopInputFocusCommand(
            generation: generation == .max ? 1 : generation + 1,
            destination: destination
        )
    }
}

nonisolated enum RDPDesktopInputFocusHandshakeDisposition: Equatable, Sendable {
    case ignored
    case releaseLocal
    case requestRemote(command: RDPDesktopInputFocusCommand, token: UInt64)
}

/// Keeps AppKit focus retries bound to the latest SwiftUI command. A remote
/// request remains pending until the framebuffer has stayed first responder
/// across two main-runloop checks; a newer local command or lifecycle
/// cancellation invalidates every queued retry.
nonisolated struct RDPDesktopInputFocusHandshake: Equatable, Sendable {
    private(set) var latestCommand = RDPDesktopInputFocusCommand.initial
    private(set) var pendingRemoteCommand: RDPDesktopInputFocusCommand?
    private(set) var attemptToken: UInt64 = 0
    private var didAcknowledgeLocalForLatestCommand = true

    var hasPendingRemoteCommand: Bool {
        pendingRemoteCommand != nil
    }

    mutating func receive(
        _ command: RDPDesktopInputFocusCommand
    ) -> RDPDesktopInputFocusHandshakeDisposition {
        guard command.generation != 0, command != latestCommand else {
            return .ignored
        }

        latestCommand = command
        attemptToken = nextToken(after: attemptToken)
        switch command.destination {
        case .local:
            didAcknowledgeLocalForLatestCommand = true
            pendingRemoteCommand = nil
            return .releaseLocal
        case .remote:
            didAcknowledgeLocalForLatestCommand = false
            pendingRemoteCommand = command
            return .requestRemote(command: command, token: attemptToken)
        }
    }

    mutating func restartPendingRemoteRequest()
        -> (command: RDPDesktopInputFocusCommand, token: UInt64)? {
        guard let pendingRemoteCommand else { return nil }
        attemptToken = nextToken(after: attemptToken)
        return (pendingRemoteCommand, attemptToken)
    }

    func acceptsRemoteAttempt(
        command: RDPDesktopInputFocusCommand,
        token: UInt64
    ) -> Bool {
        pendingRemoteCommand == command
            && latestCommand == command
            && command.destination == .remote
            && attemptToken == token
    }

    mutating func acknowledgeRemoteAttempt(
        command: RDPDesktopInputFocusCommand,
        token: UInt64
    ) -> Bool {
        guard acceptsRemoteAttempt(command: command, token: token) else {
            return false
        }
        pendingRemoteCommand = nil
        return true
    }

    /// Invalidates the old window's queued work while preserving the latest
    /// remote intent for the same representable if AppKit reattaches it.
    mutating func suspendForViewReattachment() {
        attemptToken = nextToken(after: attemptToken)
        pendingRemoteCommand =
            latestCommand.destination == .remote
                && !didAcknowledgeLocalForLatestCommand
            ? latestCommand
            : nil
    }

    /// Returns true when SwiftUI still needs an explicit local-focus
    /// acknowledgement for the cancelled remote command.
    mutating func cancelRemoteRequest(
        preservingRemoteIntent: Bool = false
    ) -> Bool {
        if preservingRemoteIntent {
            return false
        }
        let cancelledRemoteCommand = latestCommand.destination == .remote
            && !didAcknowledgeLocalForLatestCommand
        attemptToken = nextToken(after: attemptToken)
        pendingRemoteCommand = nil
        didAcknowledgeLocalForLatestCommand = true
        return cancelledRemoteCommand
    }

    private func nextToken(after token: UInt64) -> UInt64 {
        token == .max ? 1 : token + 1
    }
}

struct RDPDesktopWorkspace: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject private var grantStore = RemoteClientGrantStore.shared
    let session: RemoteSession
    let presentation: RDPDesktopWorkspacePresentation
    let openServerProperties: () -> Void
    var toggleFullScreen: (() -> Void)? = nil
    @State private var scaleMode: RDPDesktopScaleMode = .fit
    @State private var isShowingCompanionSetup = false
    @State private var isShowingCompanionInstallConfirmation = false
    @State private var isShowingCompanionInstallationProgress = false
    @State private var isShowingCompanionInstallUnavailable = false
    @State private var companionInstallUnavailableMessage = ""
    @State private var isAdaptiveResolutionEnabled = true
    @State private var adaptiveResize = RDPDesktopResizeCoordinator()
    @State private var lastViewportSize = CGSize.zero
    @State private var isShowingSystemSettingsFailure = false
    @State private var isApplyingCertificateDecision = false
    @State private var isShowingCertificateDecisionFailure = false
    @State private var certificateDecisionFailureMessage = ""
    @State private var lastAnnouncedAIActivityState: RDPDesktopAIActivityState?
    @State private var isRemoteInputFocused = false
    @State private var remoteInputFocusCommand = RDPDesktopInputFocusCommand.initial

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()

            if let failure = connectedInputFailure {
                inputFailureBanner(failure)
                Divider()
            }

            if shouldShowVisualOnlyBanner {
                visualOnlyBanner
                Divider()
            }

            if let challenge = presentation.certificateChallenge {
                certificateBanner(challenge)
                Divider()
            }

            if let grant = presentation.companionDelegation {
                CompanionPairingDelegationView(
                    grant: grant,
                    enrollmentExport: presentation.companionDelegationExport,
                    availability: presentation.state?.companion.availability ?? .unknown,
                    confirm: presentation.confirmDelegatedPairing,
                    revoke: presentation.revokeDelegatedPairing,
                    restore: presentation.restoreDelegatedPairing
                )
                .id(grant.grantID)
                Divider()
            } else if let peer = presentation.companionPairing {
                companionPairingBanner(peer)
                Divider()
            }

            desktopSurface
                .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    minHeight: 0,
                    maxHeight: .infinity
                )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("rdp-desktop-workspace")
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isShowingCompanionSetup) {
            WindowsCompanionSetupView(
                session: session,
                companionState: presentation.state?.companion,
                companionIdentity: presentation.companionIdentity ?? presentation.companionPairing,
                unpairCompanion: presentation.unpairCompanion
            )
        }
        .sheet(isPresented: $isShowingCompanionInstallationProgress) {
            WindowsCompanionInstallationProgressView(
                session: session,
                state: presentation.companionInstallation,
                install: presentation.installCompanion
            )
        }
        .alert(
            WindowsCompanionInstallationContentPolicy.confirmationTitle(language: language),
            isPresented: $isShowingCompanionInstallConfirmation
        ) {
            Button(
                WindowsCompanionInstallationContentPolicy.installTitle(language: language)
            ) {
                presentation.installCompanion?()
                isShowingCompanionInstallationProgress = true
            }
            .keyboardShortcut(.defaultAction)
            .disabled(presentation.installCompanion == nil)
            .accessibilityIdentifier("rdp-companion-install-confirm-button")

            Button(
                WindowsCompanionInstallationContentPolicy.cancelTitle(language: language),
                role: .cancel
            ) {}
        } message: {
            Text(
                WindowsCompanionInstallationContentPolicy.confirmationMessage(
                    profileName: session.name,
                    connectionKey: session.connectionKey,
                    language: language
                )
            )
        }
        .alert(
            language.localized(
                "Companion Installation Unavailable",
                "暂时无法安装 Companion"
            ),
            isPresented: $isShowingCompanionInstallUnavailable
        ) {
            Button(language.localized("OK", "好"), role: .cancel) {}
        } message: {
            Text(companionInstallUnavailableMessage)
        }
        .alert(
            language.localized("Open System Settings", "打开系统设置"),
            isPresented: $isShowingSystemSettingsFailure
        ) {
            Button(language.localized("OK", "好"), role: .cancel) {}
        } message: {
            Text(language.localized(
                "System Settings could not be opened automatically. Open Privacy & Security > Local Network manually and verify the entry for the JTS Terminal copy you are running. If it is already enabled, do not keep toggling it.",
                "无法自动打开系统设置。请手动打开“隐私与安全性”>“本地网络”，核对当前正在运行的 JTS Terminal 副本对应条目。若已经开启，请不要反复切换。"
            ))
        }
        .alert(
            language.localized("Certificate Decision Failed", "证书决定失败"),
            isPresented: $isShowingCertificateDecisionFailure
        ) {
            Button(language.localized("OK", "好"), role: .cancel) {}
        } message: {
            Text(certificateDecisionFailureMessage)
        }
        .onAppear {
            disableAdaptiveResolutionIfNeeded(
                for: presentation.state?.lastErrorCode
            )
            announceAIActivityChange(to: aiActivityState)
        }
        .onChange(of: presentation.state?.lastErrorCode) { _, newCode in
            disableAdaptiveResolutionIfNeeded(for: newCode)
        }
        .onChange(of: aiActivityState) { _, newState in
            announceAIActivityChange(to: newState)
        }
        .onChange(of: isConnected) { _, connected in
            scheduleAdaptiveResize(lastViewportSize)
            guard !connected else { return }
            moveInputFocus(to: .local)
        }
        .onChange(of: scaleMode) { _, _ in scheduleAdaptiveResize(lastViewportSize) }
        .onChange(of: isAdaptiveResolutionEnabled) { _, _ in scheduleAdaptiveResize(lastViewportSize) }
        .onChange(of: presentation.state?.sessionID) { _, _ in adaptiveResize.cancel() }
        .onDisappear { adaptiveResize.cancel() }
    }

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            wideControlBar
            narrowControlBar
        }
        .fixedSize(horizontal: false, vertical: true)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .background {
            RDPDesktopLayoutMarker(identifier: "rdp-desktop-control-bar-layout")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rdp-desktop-control-bar")
    }

    private var wideControlBar: some View {
        let plan = controlBarPlan(layout: .wide)
        return HStack(spacing: 12) {
            wideControlBarStatus
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                if showsRemoteInputFocusControl {
                    remoteInputFocusControl
                }

                ForEach(plan.secondaryActions, id: \.self) { action in
                    inlineSecondaryControl(action)
                }

                if (showsRemoteInputFocusControl || !plan.secondaryActions.isEmpty),
                   !plan.criticalActions.isEmpty {
                    Divider()
                        .frame(height: 18)
                }

                ForEach(plan.criticalActions, id: \.self) { action in
                    criticalControl(
                        action,
                        usesIconOnlyLabels: plan.usesIconOnlyCriticalLabels
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var narrowControlBar: some View {
        let plan = controlBarPlan(layout: .narrow)
        let criticalRows = RDPDesktopControlBarPolicy.narrowCriticalActionRows(
            plan.criticalActions
        )
        return VStack(alignment: .leading, spacing: 7) {
            narrowControlBarStatus
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(spacing: 8) {
                if showsRemoteInputFocusControl {
                    remoteInputFocusControl
                        .fixedSize(horizontal: true, vertical: false)
                }

                secondaryOverflowMenu(actions: plan.secondaryActions)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }

            VStack(spacing: 6) {
                ForEach(Array(criticalRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { action in
                            criticalControl(
                                action,
                                usesIconOnlyLabels: plan.usesIconOnlyCriticalLabels
                            )
                            .frame(maxWidth: .infinity)
                        }

                        if row.count == 1 {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 0)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
        }
    }

    private var wideControlBarStatus: some View {
        let identityContent = aiClientIdentityContent(layout: .wide)
        return HStack(spacing: 10) {
            connectionStatusIndicator
                .fixedSize(horizontal: true, vertical: false)

            if showsAIActivityStatus {
                Divider()
                    .frame(height: 18)

                aiActivityStatusIndicator
                    .fixedSize(horizontal: true, vertical: false)

                Text(identityContent.visibleSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(identityContent.lineLimit)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240)
                    .help(identityContent.help)
                    .accessibilityLabel(language.localized("Active AI client", "当前 AI 客户端"))
                    .accessibilityValue(identityContent.accessibilityValue)
                    .accessibilityIdentifier("rdp-ai-client-identity")
            }
        }
    }

    private var narrowControlBarStatus: some View {
        let identityContent = aiClientIdentityContent(layout: .narrow)
        return VStack(alignment: .leading, spacing: 4) {
            connectionStatusIndicator
                .fixedSize(horizontal: false, vertical: true)

            if showsAIActivityStatus {
                aiActivityStatusIndicator
                    .fixedSize(horizontal: false, vertical: true)

                Text(identityContent.visibleSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(identityContent.lineLimit)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(identityContent.help)
                    .accessibilityLabel(language.localized("Active AI client", "当前 AI 客户端"))
                    .accessibilityValue(identityContent.accessibilityValue)
                    .accessibilityIdentifier("rdp-ai-client-identity")
            }
        }
    }

    private var connectionStatusIndicator: some View {
        Label(connectionStatusTitle, systemImage: connectionStatusSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(connectionStatusColor)
            .accessibilityIdentifier("rdp-desktop-connection-status")
    }

    private var aiActivityStatusIndicator: some View {
        Label(
            aiActivityStatusTitle,
            systemImage: aiActivityStatusSymbol
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
        .accessibilityLabel(aiActivityStatusTitle)
        .accessibilityIdentifier("rdp-ai-control-status")
    }

    private var showsAIActivityStatus: Bool {
        presentation.isAIViewing ||
            presentation.isAIControlActive ||
            presentation.isAIControlStopping
    }

    private func controlBarPlan(
        layout: RDPDesktopControlBarLayout
    ) -> RDPDesktopControlBarPlan {
        RDPDesktopControlBarPolicy.plan(
            layout: layout,
            isConnected: isConnected,
            shouldOfferConnect: shouldOfferConnect,
            showsAIInterruptionControls: shouldShowAIInterruptionControls,
            showsPendingAIAccessRequest: hasPendingAIAccessRequest
        )
    }

    private var hasPendingAIAccessRequest: Bool {
        !grantStore.pendingRequests(
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding
        ).isEmpty
    }

    @ViewBuilder
    private func inlineSecondaryControl(
        _ action: RDPDesktopControlBarSecondaryAction
    ) -> some View {
        switch action {
        case .companion:
            companionSetupButton
        case .desktopScale:
            desktopScaleMenu
        case .fullScreen:
            fullScreenButton
        }
    }

    private var companionSetupButton: some View {
        Button {
            handleCompanionStatusTap()
        } label: {
            Label(companionStatusTitle, systemImage: companionStatusSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(companionStatusHelp)
        .accessibilityIdentifier("rdp-companion-status")
    }

    private var companionStatusHelp: String {
        switch WindowsCompanionStatusTapPolicy.action(
            availability: presentation.state?.companion.availability,
            installation: presentation.companionInstallation
        ) {
        case .confirmInstallation:
            if presentation.installCompanion == nil {
                return language.localized(
                    "Show why Companion installation is unavailable",
                    "查看暂时无法安装 Companion 的原因"
                )
            }
            return language.localized(
                "Install Windows Companion through this RDP session",
                "通过当前 RDP 会话安装 Windows Companion"
            )
        case .showInstallationProgress:
            return language.localized(
                "Show Companion installation progress",
                "显示 Companion 安装进度"
            )
        case .showSetup:
            return language.localized("Open Companion setup", "打开 Companion 设置")
        }
    }

    private func handleCompanionStatusTap() {
        switch WindowsCompanionStatusTapPolicy.action(
            availability: presentation.state?.companion.availability,
            installation: presentation.companionInstallation
        ) {
        case .confirmInstallation:
            isShowingCompanionInstallationProgress = false
            isShowingCompanionSetup = false
            guard presentation.installCompanion != nil else {
                companionInstallUnavailableMessage = companionInstallUnavailableDetail
                isShowingCompanionInstallUnavailable = true
                return
            }
            isShowingCompanionInstallConfirmation = true
        case .showInstallationProgress:
            isShowingCompanionInstallConfirmation = false
            isShowingCompanionSetup = false
            isShowingCompanionInstallationProgress = true
        case .showSetup:
            isShowingCompanionInstallConfirmation = false
            isShowingCompanionInstallationProgress = false
            isShowingCompanionSetup = true
        }
    }

    private var companionInstallUnavailableDetail: String {
        if !session.rdpProfile.clipboardEnabled {
            return language.localized(
                "Enable Clipboard in Server Properties, reconnect this RDP session, and try again. The one-click installer uses a temporary, read-only RDP clipboard file offer.",
                "请在“服务器属性”中启用剪贴板，重新连接此 RDP 会话后再试。一键安装会临时使用只读的 RDP 剪贴板文件传输。"
            )
        }
        if presentation.state?.phase != .connected {
            return language.localized(
                "Connect this RDP desktop and wait for Companion detection to finish before installing.",
                "请先连接此 RDP 桌面，并等待 Companion 检测完成后再安装。"
            )
        }
        if !presentation.isCompanionInstallerClipboardReady {
            return language.localized(
                "This Windows RDP session did not negotiate streamed, path-free clipboard file transfer. Check the Windows clipboard/group-policy settings, reconnect, and try again.",
                "当前 Windows RDP 会话未协商流式、无路径的剪贴板文件传输。请检查 Windows 剪贴板或组策略设置，重新连接后再试。"
            )
        }
        return language.localized(
            "Companion installation is already changing state. Wait for the current operation or detection pass to finish, then try again.",
            "Companion 安装状态正在变化。请等待当前操作或检测完成后再试。"
        )
    }

    private var desktopScaleMenu: some View {
        Menu {
            desktopScaleControls
        } label: {
            Label(
                scaleMode.title(language: language),
                systemImage: "arrow.up.left.and.arrow.down.right"
            )
        }
        .accessibilityIdentifier("rdp-scale-menu")
    }

    @ViewBuilder
    private var desktopScaleControls: some View {
        Picker(language.localized("Desktop scale", "桌面缩放"), selection: $scaleMode) {
            ForEach(RDPDesktopScaleMode.allCases) { mode in
                Text(mode.title(language: language)).tag(mode)
            }
        }
        .accessibilityIdentifier("rdp-scale-picker")

        Toggle(
            language.localized("Adaptive resolution", "自适应分辨率"),
            isOn: $isAdaptiveResolutionEnabled
        )
        .disabled(isAdaptiveResolutionUnavailable)
        .accessibilityIdentifier("rdp-adaptive-resolution-toggle")
    }

    private var fullScreenButton: some View {
        Button {
            if let toggleFullScreen { toggleFullScreen() }
            else { MainWindowLifecycle.toggleFullScreen() }
        } label: {
            Label(
                language.localized("Full Screen", "全屏"),
                systemImage: "arrow.up.left.and.arrow.down.right"
            )
        }
        .help(language.localized("Enter or exit full screen", "进入或退出全屏"))
        .accessibilityIdentifier("rdp-full-screen-button")
    }

    private func secondaryOverflowMenu(
        actions: [RDPDesktopControlBarSecondaryAction]
    ) -> some View {
        Menu {
            if actions.contains(.companion) {
                companionSetupButton
            }
            if actions.contains(.desktopScale) {
                Divider()
                desktopScaleControls
            }
            if actions.contains(.fullScreen) {
                Divider()
                fullScreenButton
            }
        } label: {
            Label(language.localized("More", "更多"), systemImage: "ellipsis.circle")
        }
        .help(language.localized("Companion and display options", "Companion 与显示选项"))
        .accessibilityIdentifier("rdp-secondary-actions-menu")
    }

    @ViewBuilder
    private func criticalControl(
        _ action: RDPDesktopControlBarCriticalAction,
        usesIconOnlyLabels: Bool
    ) -> some View {
        if usesIconOnlyLabels {
            criticalControlContent(action)
                .labelStyle(.iconOnly)
        } else {
            criticalControlContent(action)
        }
    }

    @ViewBuilder
    private func criticalControlContent(
        _ action: RDPDesktopControlBarCriticalAction
    ) -> some View {
        switch action {
        case .aiAccess:
            RemoteGrantManagementButton(
                session: session,
                language: language,
                accessibilityIdentifier:
                    RemoteGrantManagementAccessibilityIdentifier
                        .pendingEntryButton
            ) {
                presentation.takeManualControl?()
            }
        case .takeControl:
            Button {
                presentation.takeManualControl?()
            } label: {
                Label(language.localized("Take Control", "接管"), systemImage: "hand.raised.fill")
            }
            .help(language.localized(
                "Stop current AI work on this desktop and return input to you",
                "停止此桌面当前的 AI 操作并由你接管"
            ))
            .disabled(presentation.takeManualControl == nil)
            .accessibilityIdentifier("rdp-take-control-button")
        case .emergencyStop:
            Button(role: .destructive) {
                presentation.emergencyStop?()
            } label: {
                Label(language.localized("Emergency Stop", "急停"), systemImage: "stop.circle.fill")
            }
            .help(language.localized(
                "Revoke AI authority and disconnect this remote desktop immediately",
                "立即撤销 AI 权限并断开此远程桌面"
            ))
            .disabled(presentation.emergencyStop == nil)
            .accessibilityIdentifier("rdp-emergency-stop-button")
        case .connect:
            Button {
                presentation.connect?()
            } label: {
                Label(connectionActionTitle, systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help(connectionActionTitle)
            .disabled(!session.isConnectable || presentation.connect == nil)
            .accessibilityIdentifier("rdp-connect-button")
        case .disconnect:
            Button {
                presentation.disconnect?()
            } label: {
                Label(language.localized("Disconnect", "断开"), systemImage: "xmark.circle")
            }
            .help(language.localized("Disconnect", "断开"))
            .disabled(presentation.disconnect == nil)
            .accessibilityIdentifier("rdp-disconnect-button")
        }
    }

    @ViewBuilder
    private var desktopSurface: some View {
        if !session.isConnectable {
            RDPDesktopCenteredStateSurface {
                ConfigureServerPrompt(openServerProperties: openServerProperties)
            }
        } else if let frameImage = presentation.frameImage, isConnected {
            RDPInteractiveDesktopSurface(
                image: frameImage,
                pixelWidth: presentation.state?.remotePixelWidth ?? Int(frameImage.size.width),
                pixelHeight: presentation.state?.remotePixelHeight ?? Int(frameImage.size.height),
                scaleMode: scaleMode,
                focusCommand: remoteInputFocusCommand,
                onInput: sendManualInput,
                onViewportSize: scheduleAdaptiveResize,
                onInputFocusChange: handleRemoteInputFocusChange,
                onReleaseToLocalFocus: releaseRemoteInputToLocalControl
            )
            .overlay {
                Rectangle()
                    .stroke(
                        isRemoteInputFocused ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(language.localized("Remote Windows desktop", "远程 Windows 桌面"))
        } else if presentation.state == nil {
            RDPDesktopCenteredStateSurface {
                ContentUnavailableView {
                    Label(
                        RDPDesktopWorkspaceIdleContent.surfaceTitle(language: language),
                        systemImage: "desktopcomputer"
                    )
                } description: {
                    Text(RDPDesktopWorkspaceIdleContent.detail(language: language))
                } actions: {
                    Button(language.localized("Open Server Properties", "打开服务器属性"), action: openServerProperties)
                }
                .accessibilityIdentifier("rdp-ready-to-connect")
            }
        } else if presentation.state?.isLocalNetworkDecisionPending == true {
            RDPDesktopCenteredStateSurface {
                localNetworkDecisionPendingSurface
            }
        } else if presentation.state?.isLocalNetworkPathBlocked == true {
            RDPDesktopCenteredStateSurface {
                localNetworkPathBlockedSurface
            }
        } else if isConnected {
            RDPDesktopCenteredStateSurface {
                ProgressView(language.localized("Waiting for the first desktop frame…", "正在等待第一帧桌面画面…"))
                    .controlSize(.small)
            }
        } else {
            RDPDesktopCenteredStateSurface {
                ContentUnavailableView {
                    Label(connectionStatusTitle, systemImage: connectionStatusSymbol)
                } description: {
                    VStack(spacing: 8) {
                        Text(connectionStatusDetail)
                        connectionFailureCodeDetail
                    }
                } actions: {
                    Button(language.localized("Open Server Properties", "打开服务器属性"), action: openServerProperties)
                }
            }
        }
    }

    @ViewBuilder
    private var remoteInputFocusControl: some View {
        if isRemoteInputFocused {
            remoteInputFocusButton(
                destination: .local,
                action: releaseRemoteInputToLocalControl
            )
                .keyboardShortcut(.escape, modifiers: [.control, .command])
        } else {
            remoteInputFocusButton(
                destination: .remote,
                action: focusRemoteInput
            )
        }
    }

    private var showsRemoteInputFocusControl: Bool {
        isConnected && presentation.frameImage != nil
    }

    private func remoteInputFocusButton(
        destination: RDPDesktopInputFocusDestination,
        action: @escaping () -> Void
    ) -> some View {
        let releasesInput = destination == .local
        return Button(action: action) {
            Label(
                releasesInput
                    ? language.localized("Release Input", "释放输入")
                    : language.localized("Focus Remote Input", "聚焦远程输入"),
                systemImage: releasesInput
                    ? "keyboard.badge.ellipsis"
                    : "keyboard"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(remoteInputFocusHelp)
        .accessibilityLabel(
            releasesInput
                ? language.localized("Release remote input", "释放远程输入")
                : language.localized("Focus remote input", "聚焦远程输入")
        )
        .accessibilityValue(
            releasesInput
                ? language.localized(
                    "Remote input is active. Press Control-Command-Escape to return keyboard focus to JTS Terminal.",
                    "远程输入已激活。按 Control-Command-Escape 可将键盘焦点返回 JTS Terminal。"
                )
                : language.localized(
                    "Keyboard focus is in JTS Terminal.",
                    "键盘焦点位于 JTS Terminal。"
                )
        )
        .accessibilityIdentifier("rdp-remote-input-focus-button")
    }

    @ViewBuilder
    private var connectionFailureCodeDetail: some View {
        if let code = RDPDesktopWorkspaceFailureContent.machineErrorCode(for: presentation.state) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(RDPDesktopWorkspaceFailureContent.errorCodeTitle(language: language))
                    .font(.caption)
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(
                RDPDesktopWorkspaceFailureContent.errorCodeAccessibilityLabel(language: language)
            ))
            .accessibilityValue(Text(code))
            .accessibilityIdentifier("rdp-connection-error-code")
        }
    }

    private var localNetworkPathBlockedSurface: some View {
        ContentUnavailableView {
            Label(
                RDPDesktopLocalNetworkBlockedContent.title(language: language),
                systemImage: "network.slash"
            )
        } description: {
            VStack(spacing: 8) {
                Text(RDPDesktopLocalNetworkBlockedContent.detail(
                    host: session.host,
                    language: language
                ))
                connectionFailureCodeDetail
            }
        } actions: {
            if let connect = presentation.connect {
                Button(
                    RDPDesktopLocalNetworkBlockedContent.retryTitle(language: language),
                    action: connect
                )
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("rdp-local-network-retry")
            }

            Button(language.localized("Open Local Network Settings", "打开本地网络设置")) {
                guard presentation.openLocalNetworkSettings?() == true else {
                    isShowingSystemSettingsFailure = true
                    return
                }
            }
            .accessibilityIdentifier("rdp-open-local-network-settings")
            .buttonStyle(.bordered)

            localNetworkRecoveryMenu
        }
        .accessibilityIdentifier("rdp-local-network-path-blocked")
    }

    private var localNetworkDecisionPendingSurface: some View {
        ContentUnavailableView {
            Label(
                RDPDesktopLocalNetworkDecisionPendingContent.title(
                    language: language
                ),
                systemImage: "network.badge.shield.half.filled"
            )
        } description: {
            VStack(spacing: 8) {
                Text(RDPDesktopLocalNetworkDecisionPendingContent.detail(
                    host: session.host,
                    language: language
                ))
                connectionFailureCodeDetail
            }
        } actions: {
            if let connect = presentation.connect {
                Button(
                    RDPDesktopLocalNetworkDecisionPendingContent.retryTitle(
                        language: language
                    ),
                    action: connect
                )
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("rdp-local-network-decision-retry")
            }

            Button(language.localized("Open Local Network Settings", "打开本地网络设置")) {
                guard presentation.openLocalNetworkSettings?() == true else {
                    isShowingSystemSettingsFailure = true
                    return
                }
            }
            .accessibilityIdentifier("rdp-open-local-network-settings")
            .buttonStyle(.bordered)

            localNetworkRecoveryMenu
        }
        .accessibilityIdentifier("rdp-local-network-decision-pending")
    }

    private var localNetworkRecoveryMenu: some View {
        Menu {
            Button(
                language.localized(
                    "Show This App in Finder",
                    "在 Finder 中显示当前副本"
                )
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([
                    Bundle.main.bundleURL
                ])
            }
            .accessibilityIdentifier("rdp-show-current-app-in-finder")

            Button(
                language.localized(
                    "Open Server Properties",
                    "打开服务器属性"
                ),
                action: openServerProperties
            )
        } label: {
            Label(
                language.localized("More Options", "更多选项"),
                systemImage: "ellipsis.circle"
            )
        }
        .accessibilityIdentifier("rdp-local-network-more-actions")
    }

    private var visualOnlyBanner: some View {
        Label {
            Text(language.localized(
                "Visual-only mode: desktop display, screenshots, keyboard, and pointer remain available. UI Automation, PowerShell, files, and structured tasks require a compatible paired Windows Companion.",
                "纯视觉模式：桌面显示、截图、键盘和鼠标仍可使用；UI Automation、PowerShell、文件和结构化任务需要兼容且已配对的 Windows Companion。"
            ))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "eye.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09))
        .accessibilityIdentifier("rdp-visual-only-banner")
    }

    private func inputFailureBanner(_ failure: RDPDesktopWorkspaceInputFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                failure.disablesAdaptiveResolution
                    ? language.localized(
                        "Adaptive resolution is unavailable",
                        "自适应分辨率不可用"
                    )
                    : language.localized("Desktop input failed", "桌面输入失败"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.semibold))

            Text(failure.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Text(failure.code)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09))
        .accessibilityIdentifier("rdp-input-failure-banner")
    }

    private func certificateBanner(_ challenge: RDPCertificateChallenge) -> some View {
        let blocksTrust = challenge.changed || challenge.pinnedMismatch
        return VStack(alignment: .leading, spacing: 7) {
            Label(
                blocksTrust
                    ? language.localized("RDP certificate changed — connection blocked", "RDP 证书已变化——连接已阻断")
                    : language.localized("Verify this RDP certificate", "请核验此 RDP 证书"),
                systemImage: blocksTrust ? "exclamationmark.shield.fill" : "checkmark.shield"
            )
            .font(.caption.weight(.semibold))

            Text("\(challenge.host):\(challenge.port)  •  \(challenge.issuer)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(challenge.sha256)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)

            if challenge.hostMismatch {
                Label {
                    Text(RDPDesktopCertificateWarningContent.hostMismatchDetail(
                        host: challenge.host,
                        language: language
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityIdentifier("rdp-certificate-host-mismatch-warning")
            }

            switch RDPDesktopCertificateDecisionPolicy.disposition(
                changed: challenge.changed,
                pinnedMismatch: challenge.pinnedMismatch,
                oldSHA256: challenge.oldSHA256
            ) {
            case let .blockedChangedCertificate(previousSHA256):
                Label {
                    Text(RDPDesktopCertificateWarningContent.changedCertificateBlockingDetail(
                        language: language
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.slash.fill")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityIdentifier("rdp-certificate-changed-blocked")

                if let previousSHA256 {
                    Text(RDPDesktopCertificateWarningContent.previousFingerprintDetail(
                        fingerprint: previousSHA256,
                        isPinned: challenge.pinnedMismatch,
                        language: language
                    ))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .actionsAvailable:
                HStack {
                    Button(language.localized("Trust Once", "仅信任本次")) {
                        performCertificateDecision(presentation.trustCertificateOnce)
                    }
                    .disabled(
                        presentation.trustCertificateOnce == nil ||
                            isApplyingCertificateDecision
                    )

                    Button(language.localized("Verify and Pin", "核验并固定指纹")) {
                        performCertificateDecision(presentation.pinCertificate)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        presentation.pinCertificate == nil ||
                            isApplyingCertificateDecision
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .accessibilityIdentifier("rdp-certificate-challenge")
    }

    private func performCertificateDecision(
        _ action: (@MainActor () async throws -> Void)?
    ) {
        guard let action, !isApplyingCertificateDecision else { return }
        isApplyingCertificateDecision = true
        Task { @MainActor in
            defer { isApplyingCertificateDecision = false }
            do {
                try await action()
            } catch {
                certificateDecisionFailureMessage =
                    RDPDesktopCertificateWarningContent.decisionFailureDetail(
                        errorDescription: error.localizedDescription,
                        language: language
                    )
                isShowingCertificateDecisionFailure = true
            }
        }
    }

    private func companionPairingBanner(_ peer: WindowsCompanionPeerIdentity) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(language.localized("Confirm Windows Companion pairing", "确认 Windows Companion 配对"), systemImage: "person.badge.key.fill")
                .font(.caption.weight(.semibold))
            Text(language.localized(
                "Verify the Windows Companion identity below, then confirm this Mac client fingerprint in the visible Windows prompt. Structured access stays blocked until both sides agree.",
                "请先核对下方 Windows Companion 身份，再在可见的 Windows 提示中确认这台 Mac 的客户端指纹。双方确认前，结构化访问始终保持阻止。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(language.localized("Windows Companion fingerprint", "Windows Companion 指纹"))
                .font(.caption2.weight(.semibold))
            Text(peer.fingerprintSHA256)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
            Text(language.localized("This Mac client fingerprint (confirm on Windows)", "这台 Mac 的客户端指纹（请在 Windows 上确认）"))
                .font(.caption2.weight(.semibold))
            Text(peer.clientFingerprintSHA256)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
            Button(language.localized("Continue to Windows Confirmation", "继续在 Windows 上确认")) {
                presentation.approveCompanionPairing?()
            }
            .buttonStyle(.borderedProminent)
            .disabled(presentation.approveCompanionPairing == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.09))
        .accessibilityIdentifier("rdp-companion-pairing")
    }

    private func sendManualInput(_ input: RDPManualDesktopInput) {
        guard let state = presentation.state,
              let frameID = state.latestFrameID,
              presentation.performManualAction != nil else { return }

        let request: DesktopActionRequest
        switch input {
        case let .pointer(action, point, button, deltaX, deltaY):
            request = DesktopActionRequest(
                action: action,
                expectedStateRevision: state.stateRevision,
                expectedFrameID: frameID,
                selector: nil,
                point: point,
                mouseButton: button,
                scrollDeltaX: deltaX,
                scrollDeltaY: deltaY,
                key: nil,
                keyChord: nil,
                text: nil,
                deadlineMilliseconds: 5_000,
                idempotencyKey: nil
            )
        case let .key(name, isDown, modifiers):
            if isDown, !modifiers.isEmpty {
                request = DesktopActionRequest(
                    action: .keyChord,
                    expectedStateRevision: state.stateRevision,
                    expectedFrameID: frameID,
                    selector: nil,
                    point: nil,
                    mouseButton: nil,
                    scrollDeltaX: nil,
                    scrollDeltaY: nil,
                    key: nil,
                    keyChord: modifiers + [name],
                    text: nil,
                    deadlineMilliseconds: 5_000,
                    idempotencyKey: nil
                )
            } else {
                request = DesktopActionRequest(
                    action: isDown ? .keyDown : .keyUp,
                    expectedStateRevision: state.stateRevision,
                    expectedFrameID: frameID,
                    selector: nil,
                    point: nil,
                    mouseButton: nil,
                    scrollDeltaX: nil,
                    scrollDeltaY: nil,
                    key: name,
                    keyChord: nil,
                    text: nil,
                    deadlineMilliseconds: 5_000,
                    idempotencyKey: nil
                )
            }
        case let .text(value):
            request = DesktopActionRequest(
                action: .typeText,
                expectedStateRevision: state.stateRevision,
                expectedFrameID: frameID,
                selector: nil,
                point: nil,
                mouseButton: nil,
                scrollDeltaX: nil,
                scrollDeltaY: nil,
                key: nil,
                keyChord: nil,
                text: value,
                deadlineMilliseconds: 5_000,
                idempotencyKey: nil
            )
        }
        presentation.performManualAction?(request)
    }

    private func scheduleAdaptiveResize(_ size: CGSize) {
        lastViewportSize = size
        adaptiveResize.schedule(viewport: size,
            remote: CGSize(width: presentation.state?.remotePixelWidth ?? 0,
                           height: presentation.state?.remotePixelHeight ?? 0),
            enabled: canAdaptResolution, sessionID: presentation.state?.sessionID,
            isStillAllowed: { canAdaptResolution },
            send: { width, height in presentation.resizeDesktop?(width, height) })
    }

    private var canAdaptResolution: Bool {
        isConnected && isAdaptiveResolutionEnabled && !isAdaptiveResolutionUnavailable
            && scaleMode == .fit && presentation.resizeDesktop != nil
    }

    private func disableAdaptiveResolutionIfNeeded(for errorCode: String?) {
        guard RDPDesktopWorkspaceInputFailurePolicy
            .disablesAdaptiveResolution(for: errorCode) else { return }
        isAdaptiveResolutionEnabled = false
        adaptiveResize.cancel()
    }

    private var isConnected: Bool {
        presentation.state?.phase == .connected
    }

    private var connectedInputFailure: RDPDesktopWorkspaceInputFailure? {
        RDPDesktopWorkspaceInputFailurePolicy.visibleFailure(
            phase: presentation.state?.phase,
            code: presentation.state?.lastErrorCode,
            message: presentation.state?.lastErrorMessage
        )
    }

    private var isAdaptiveResolutionUnavailable: Bool {
        connectedInputFailure?.disablesAdaptiveResolution == true
    }

    private var shouldShowVisualOnlyBanner: Bool {
        guard isConnected, let companion = presentation.state?.companion.availability else { return false }
        switch companion {
        case .missing, .incompatible, .pairingRequired:
            return true
        case .unknown, .ready:
            return false
        }
    }

    private var shouldShowAIInterruptionControls: Bool {
        RDPDesktopWorkspaceControlPolicy.showsAIInterruptionControls(
            isAIViewing: presentation.isAIViewing,
            isAIControlActive: presentation.isAIControlActive,
            isAIControlStopping: presentation.isAIControlStopping
        )
    }

    private var aiActivityState: RDPDesktopAIActivityState {
        RDPDesktopAIActivityState.resolved(
            isViewing: presentation.isAIViewing,
            isControlActive: presentation.isAIControlActive,
            isControlStopping: presentation.isAIControlStopping
        )
    }

    private var aiActivityStatusTitle: String {
        switch aiActivityState {
        case .controlling:
            return language.localized("AI Control", "AI 控制中")
        case .stopping:
            return language.localized("AI Control stopping", "AI 控制停止中")
        case .viewing:
            return language.localized("AI Viewing", "AI 查看中")
        case .inactive:
            return language.localized("AI inactive", "AI 未活动")
        }
    }

    private var aiActivityStatusSymbol: String {
        switch aiActivityState {
        case .controlling:
            return "cursorarrow.motionlines"
        case .stopping:
            return "stop.circle"
        case .viewing:
            return "eye.fill"
        case .inactive:
            return "eye.slash"
        }
    }

    private func announceAIActivityChange(
        to newState: RDPDesktopAIActivityState
    ) {
        let announcement = RDPDesktopAIActivityAnnouncementPolicy.announcement(
            previous: lastAnnouncedAIActivityState,
            current: newState,
            language: language
        )
        lastAnnouncedAIActivityState = newState
        guard let announcement else { return }
        RDPDesktopVoiceOverAnnouncer.announce(announcement)
    }

    private var connectionStatusTitle: String {
        guard let state = presentation.state else {
            return RDPDesktopWorkspaceIdleContent.statusTitle(language: language)
        }

        if state.isLocalNetworkPathBlocked {
            return language.localized(
                "macOS blocked the local network path",
                "本地网络路径被 macOS 阻止"
            )
        }
        if state.isLocalNetworkDecisionPending {
            return language.localized(
                "Waiting for a macOS Local Network decision",
                "正在等待 macOS 本地网络授权决定"
            )
        }

        switch state.phase {
        case .closed:
            return language.localized("Disconnected", "已断开")
        case .connecting:
            return language.localized("Connecting", "正在连接")
        case .awaitingCertificateTrust:
            return language.localized("Certificate approval required", "需要确认服务器证书")
        case .authenticating:
            return language.localized("Authenticating", "正在认证")
        case .connected:
            return language.localized("Connected", "已连接")
        case .reconnecting:
            if let attempt = state.reconnectAttempt,
               let maximumAttempts = state.reconnectMaximumAttempts {
                return language.localized(
                    "Reconnecting (\(attempt)/\(maximumAttempts))",
                    "正在重连（\(attempt)/\(maximumAttempts)）"
                )
            }
            return language.localized("Reconnecting", "正在重连")
        case .failed:
            return language.localized("Connection failed", "连接失败")
        }
    }

    private var connectionStatusDetail: String {
        if presentation.state?.phase == .awaitingCertificateTrust,
           presentation.certificateChallenge == nil {
            return language.localized(
                "Certificate details did not arrive. Reload them before deciding whether to trust this server.",
                "证书详情尚未到达。请先重新获取详情，再决定是否信任此服务器。"
            )
        }
        if let message = presentation.state?.lastErrorMessage?.nilIfBlank {
            return message
        }
        return language.localized(
            "Connect to open a visible native RDP workspace on this Mac.",
            "连接后可在这台 Mac 上打开可见的原生 RDP 工作区。"
        )
    }

    private var connectionStatusSymbol: String {
        if presentation.state?.isLocalNetworkDecisionPending == true {
            return "network.badge.shield.half.filled"
        }
        if presentation.state?.isLocalNetworkPathBlocked == true {
            return "network.slash"
        }
        switch presentation.state?.phase {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting, .authenticating, .reconnecting:
            return "arrow.triangle.2.circlepath"
        case .awaitingCertificateTrust:
            return "checkmark.shield"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .closed, .none:
            return "circle.dashed"
        }
    }

    private var shouldOfferConnect: Bool {
        if presentation.state?.isLocalNetworkDecisionPending == true ||
            presentation.state?.isLocalNetworkPathBlocked == true {
            return false
        }
        return connectionAction != .none
    }

    private var connectionAction: RDPDesktopWorkspaceConnectionAction {
        RDPDesktopWorkspaceConnectionPolicy.action(
            phase: presentation.state?.phase,
            hasCertificateChallenge: presentation.certificateChallenge != nil
        )
    }

    private var connectionActionTitle: String {
        if connectionAction == .reloadCertificateDetails {
            return language.localized(
                "Reload Certificate Details",
                "重新获取证书详情"
            )
        }
        return language.localized("Connect", "连接")
    }

    private var connectionStatusColor: Color {
        switch presentation.state?.phase {
        case .connected:
            return Color.accentColor
        case .failed, .awaitingCertificateTrust:
            return .orange
        default:
            return .secondary
        }
    }

    private var companionStatusTitle: String {
        if presentation.companionInstallation.isActive ||
            presentation.companionInstallation.phase == .failed {
            return WindowsCompanionInstallationContentPolicy.content(
                for: presentation.companionInstallation,
                language: language
            ).title
        }

        guard let companion = presentation.state?.companion else {
            return language.localized("Companion unknown", "Companion 状态未知")
        }

        switch companion.availability {
        case .unknown:
            return language.localized("Checking Companion", "正在检查 Companion")
        case .missing:
            return language.localized("Companion missing", "未检测到 Companion")
        case .incompatible:
            return language.localized("Companion incompatible", "Companion 不兼容")
        case .pairingRequired:
            return language.localized("Companion pairing required", "Companion 需要配对")
        case .ready:
            return language.localized("Companion ready", "Companion 已就绪")
        }
    }

    private var companionStatusSymbol: String {
        if presentation.companionInstallation.isActive {
            return "arrow.triangle.2.circlepath"
        }
        if presentation.companionInstallation.phase == .failed {
            return "exclamationmark.triangle.fill"
        }

        switch presentation.state?.companion.availability {
        case .ready:
            return "checkmark.shield.fill"
        case .missing, .incompatible, .pairingRequired:
            return "exclamationmark.shield"
        case .unknown, .none:
            return "shield"
        }
    }

    private func aiClientIdentityContent(
        layout: RDPDesktopControlBarLayout
    ) -> RDPDesktopAIClientIdentityContent {
        RDPDesktopAIClientIdentityContentPolicy.content(
            identities: presentation.activeAIClientIdentities,
            layout: layout,
            language: language
        )
    }

    private var remoteInputFocusHelp: String {
        if isRemoteInputFocused {
            return language.localized(
                "Release remote keyboard input and return focus to JTS Terminal (Control-Command-Escape)",
                "释放远程键盘输入并将焦点返回 JTS Terminal（Control-Command-Escape）"
            )
        }
        return language.localized(
            "Focus the remote desktop for keyboard input. Control-Command-Escape always returns focus to JTS Terminal.",
            "聚焦远程桌面以输入键盘操作。Control-Command-Escape 始终可将焦点返回 JTS Terminal。"
        )
    }

    private func focusRemoteInput() {
        moveInputFocus(to: .remote)
    }

    private func handleRemoteInputFocusChange(_ focused: Bool) {
        isRemoteInputFocused = focused
        let destination: RDPDesktopInputFocusDestination = focused ? .remote : .local
        guard remoteInputFocusCommand.destination != destination else { return }
        remoteInputFocusCommand = remoteInputFocusCommand.advanced(to: destination)
    }

    private func releaseRemoteInputToLocalControl() {
        moveInputFocus(to: .local)
    }

    private func moveInputFocus(
        to destination: RDPDesktopInputFocusDestination
    ) {
        remoteInputFocusCommand = remoteInputFocusCommand.advanced(
            to: destination
        )
        if destination == .local {
            isRemoteInputFocused = false
        }
    }
}

/// Centers non-interactive workspace states inside the visible desktop area.
/// When localized copy or accessibility text needs more height than a compact
/// window provides, the same surface becomes vertically scrollable instead of
/// pushing its actions above or below the clipped viewport.
private struct RDPDesktopCenteredStateSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = RDPDesktopViewportSizing.viewportSize(proxy.size)

            ScrollView(.vertical) {
                content
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                    .frame(
                        minHeight: viewport.height,
                        alignment: .center
                    )
            }
            .frame(
                width: viewport.width,
                height: viewport.height
            )
        }
        .accessibilityIdentifier("rdp-centered-state-surface")
    }
}

private enum RDPDesktopScaleMode: String, CaseIterable, Identifiable {
    case fit
    case actualSize

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .fit:
            return language.localized("Fit", "适应窗口")
        case .actualSize:
            return language.localized("100%", "100% 原始大小")
        }
    }
}

enum RDPManualDesktopInput {
    case pointer(
        action: DesktopActionKind,
        point: DesktopPoint,
        button: DesktopMouseButton,
        deltaX: Int?,
        deltaY: Int?
    )
    case key(name: String, isDown: Bool, modifiers: [String])
    case text(String)
}

/// Keeps the AppKit framebuffer host subordinate to the viewport proposed by
/// SwiftUI. A remote desktop's native pixel dimensions are drawing metadata;
/// they must never become the window's intrinsic content size.
nonisolated enum RDPDesktopViewportSizing {
    static func representableSize(width: CGFloat?, height: CGFloat?) -> CGSize {
        CGSize(
            width: finiteNonnegative(width),
            height: finiteNonnegative(height)
        )
    }

    static func viewportSize(_ proposed: CGSize) -> CGSize {
        representableSize(width: proposed.width, height: proposed.height)
    }

    static func fittedContentSize(
        pixelWidth: Int,
        pixelHeight: Int,
        available: CGSize
    ) -> CGSize {
        guard pixelWidth > 0,
              pixelHeight > 0,
              available.width.isFinite,
              available.height.isFinite,
              available.width > 0,
              available.height > 0 else {
            return .zero
        }
        let ratio = min(
            available.width / CGFloat(pixelWidth),
            available.height / CGFloat(pixelHeight)
        )
        guard ratio.isFinite, ratio > 0 else { return .zero }
        return CGSize(
            width: CGFloat(pixelWidth) * ratio,
            height: CGFloat(pixelHeight) * ratio
        )
    }

    static func fittedContentRect(
        pixelWidth: Int,
        pixelHeight: Int,
        available: CGSize
    ) -> CGRect {
        let size = fittedContentSize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            available: available
        )
        guard size != .zero else { return .zero }
        return centeredContentRect(contentSize: size, available: available)
    }

    /// Returns a top-leading content rect that is centered on every axis where
    /// it is smaller than the visible viewport. Oversized content stays at
    /// origin zero so a scroll view opens at its conventional top-left edge.
    static func centeredContentRect(
        contentSize: CGSize,
        available: CGSize
    ) -> CGRect {
        let content = viewportSize(contentSize)
        let viewport = viewportSize(available)
        guard content.width > 0,
              content.height > 0,
              viewport.width > 0,
              viewport.height > 0 else {
            return .zero
        }
        return CGRect(
            x: max((viewport.width - content.width) / 2, 0),
            y: max((viewport.height - content.height) / 2, 0),
            width: content.width,
            height: content.height
        )
    }

    private static func finiteNonnegative(_ value: CGFloat?) -> CGFloat {
        guard let value, value.isFinite else { return 0 }
        return max(value, 0)
    }
}

nonisolated enum RDPDesktopLayoutIdentifiers {
    static let featureContainer = "rdp-desktop-feature-container"
    static let viewportHost = "rdp-desktop-viewport-host"
    static let framebuffer = "rdp-desktop-framebuffer"
}

nonisolated enum RDPDesktopKeyboardKeyDownRoute: Equatable {
    case releaseLocalFocus
    case textInput
    case remoteChord(modifiers: [String])
    case physicalKey
    case ignored
}

/// Routes text-producing events through AppKit's text input system so an IME
/// can distinguish marked composition from committed text. Physical chords and
/// non-printable keys bypass text interpretation when no composition is active.
nonisolated struct RDPDesktopKeyboardInputRouting {
    static let localReleaseKeyCode: UInt16 = 53
    static let localReleaseModifiers: NSEvent.ModifierFlags = [.control, .command]

    private var textInputKeyCodes: Set<UInt16> = []
    private var locallyHandledKeyCodes: Set<UInt16> = []

    mutating func keyDownRoute(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String? = nil,
        modifierFlags: NSEvent.ModifierFlags,
        hasPhysicalKey: Bool,
        hasMarkedText: Bool
    ) -> RDPDesktopKeyboardKeyDownRoute {
        // A focus-release shortcut can legitimately resign first responder
        // before AppKit delivers its key-up. Clear any such stale marker when
        // the same physical key begins a later down/up sequence.
        locallyHandledKeyCodes.remove(keyCode)

        if Self.shouldReleaseLocalFocus(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        ) {
            textInputKeyCodes.remove(keyCode)
            locallyHandledKeyCodes.insert(keyCode)
            return .releaseLocalFocus
        }

        if Self.shouldMapMacClipboardShortcut(
            characters: charactersIgnoringModifiers ?? characters,
            modifierFlags: modifierFlags
        ) {
            textInputKeyCodes.remove(keyCode)
            locallyHandledKeyCodes.insert(keyCode)
            return .remoteChord(modifiers: ["control"])
        }

        if Self.shouldInterpretTextInput(
            characters: characters,
            modifierFlags: modifierFlags,
            hasMarkedText: hasMarkedText
        ) {
            textInputKeyCodes.insert(keyCode)
            return .textInput
        }

        // Avoid retaining a stale text-down marker if AppKit omitted a key-up
        // while this view was not the first responder.
        textInputKeyCodes.remove(keyCode)
        return hasPhysicalKey ? .physicalKey : .ignored
    }

    mutating func shouldSendPhysicalKeyUp(
        keyCode: UInt16,
        hasPhysicalKey: Bool
    ) -> Bool {
        if locallyHandledKeyCodes.remove(keyCode) != nil {
            return false
        }
        if textInputKeyCodes.remove(keyCode) != nil {
            return false
        }
        return hasPhysicalKey
    }

    static func shouldReleaseLocalFocus(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let routingFlags = modifierFlags.intersection([
            .control,
            .option,
            .shift,
            .command,
        ])
        return keyCode == localReleaseKeyCode
            && routingFlags == localReleaseModifiers
    }

    static func shouldMapMacClipboardShortcut(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let routingFlags = modifierFlags.intersection([
            .control,
            .option,
            .shift,
            .command,
        ])
        guard routingFlags == [.command],
              let key = characters?.lowercased(),
              key.count == 1 else {
            return false
        }
        return key == "c" || key == "v" || key == "x"
    }

    static func shouldInterpretTextInput(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.command) else {
            return false
        }

        // Once an IME owns a composition, navigation, deletion, and commit
        // keys must return to the input context even when their event text is
        // a control/private-use scalar. The input context decides whether they
        // update, cancel, or commit the marked text.
        if hasMarkedText {
            return true
        }

        guard let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy(isPrintableTextScalar)
    }

    private static func isPrintableTextScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.properties.generalCategory != .control
            && !(0xF700...0xF8FF).contains(scalar.value)
    }
}

nonisolated struct RDPDesktopPhysicalKeyState {
    private var activeKeys: [UInt16: String] = [:]

    var isEmpty: Bool {
        activeKeys.isEmpty
    }

    mutating func recordKeyDown(keyCode: UInt16, name: String) {
        activeKeys[keyCode] = name
    }

    mutating func keyUpName(
        keyCode: UInt16,
        fallbackName: String?
    ) -> String? {
        activeKeys.removeValue(forKey: keyCode) ?? fallbackName
    }

    mutating func releaseAllKeyNames() -> [String] {
        let names = activeKeys
            .sorted { $0.key < $1.key }
            .map(\.value)
        activeKeys.removeAll(keepingCapacity: true)
        return names
    }
}

nonisolated struct RDPDesktopPointerRelease: Equatable, Sendable {
    let button: DesktopMouseButton
    let point: DesktopPoint

    func clamped(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> RDPDesktopPointerRelease? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return RDPDesktopPointerRelease(
            button: button,
            point: DesktopPoint(
                x: min(max(point.x, 0), pixelWidth - 1),
                y: min(max(point.y, 0), pixelHeight - 1)
            )
        )
    }
}

nonisolated struct RDPDesktopPressedPointerState: Sendable {
    private var pointsByButton: [DesktopMouseButton: DesktopPoint] = [:]
    private var buttonsAwaitingLateMouseUp: Set<DesktopMouseButton> = []

    var isEmpty: Bool {
        pointsByButton.isEmpty
    }

    mutating func recordMouseDown(
        button: DesktopMouseButton,
        point: DesktopPoint
    ) {
        buttonsAwaitingLateMouseUp.remove(button)
        pointsByButton[button] = point
    }

    mutating func recordPointerMove(
        button: DesktopMouseButton,
        point: DesktopPoint
    ) {
        guard pointsByButton[button] != nil else { return }
        pointsByButton[button] = point
    }

    func lastPoint(for button: DesktopMouseButton) -> DesktopPoint? {
        pointsByButton[button]
    }

    mutating func recordMouseUp(button: DesktopMouseButton) -> Bool {
        if pointsByButton.removeValue(forKey: button) != nil {
            return true
        }
        buttonsAwaitingLateMouseUp.remove(button)
        return false
    }

    mutating func releaseAll() -> [RDPDesktopPointerRelease] {
        let releases = DesktopMouseButton.allCases.compactMap { button in
            pointsByButton[button].map {
                RDPDesktopPointerRelease(button: button, point: $0)
            }
        }
        buttonsAwaitingLateMouseUp.formUnion(releases.map(\.button))
        pointsByButton.removeAll(keepingCapacity: true)
        return releases
    }
}

nonisolated struct RDPDesktopInputReleasePlan: Equatable, Sendable {
    let pointerReleases: [RDPDesktopPointerRelease]
    let physicalKeyNames: [String]
    let discardedMarkedText: Bool

    static func drain(
        pointerState: inout RDPDesktopPressedPointerState,
        physicalKeyState: inout RDPDesktopPhysicalKeyState,
        textInputState: inout RDPDesktopTextInputState
    ) -> RDPDesktopInputReleasePlan {
        let discardedMarkedText = textInputState.hasMarkedText
        textInputState.cancelMarkedText()
        return RDPDesktopInputReleasePlan(
            pointerReleases: pointerState.releaseAll(),
            physicalKeyNames: physicalKeyState.releaseAllKeyNames(),
            discardedMarkedText: discardedMarkedText
        )
    }
}

nonisolated enum RDPDesktopTextInputEffect: Equatable {
    case none
    case commit(String)
}

/// Minimal document state required by `NSTextInputClient`. Marked text is kept
/// local to AppKit and never emitted to the remote desktop until AppKit either
/// inserts it or removes its marked status, which both finalize the text.
nonisolated struct RDPDesktopTextInputState {
    private(set) var markedText = ""
    private(set) var selectionInMarkedText = NSRange(location: 0, length: 0)

    var hasMarkedText: Bool {
        !markedText.isEmpty
    }

    var markedRange: NSRange {
        guard hasMarkedText else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    var selectedRange: NSRange {
        guard hasMarkedText else {
            return NSRange(location: 0, length: 0)
        }
        let markedLength = markedText.utf16.count
        let location = min(selectionInMarkedText.location, markedLength)
        let length = min(selectionInMarkedText.length, markedLength - location)
        return NSRange(location: location, length: length)
    }

    mutating func setMarkedText(
        _ text: String,
        selectedRange: NSRange
    ) -> RDPDesktopTextInputEffect {
        markedText = text
        selectionInMarkedText = selectedRange
        if text.isEmpty {
            clearMarkedText()
        }
        return .none
    }

    mutating func insertText(_ text: String) -> RDPDesktopTextInputEffect {
        clearMarkedText()
        guard !text.isEmpty else { return .none }
        return .commit(text)
    }

    mutating func unmarkText() -> RDPDesktopTextInputEffect {
        let committedText = markedText
        clearMarkedText()
        guard !committedText.isEmpty else { return .none }
        return .commit(committedText)
    }

    mutating func cancelMarkedText() {
        clearMarkedText()
    }

    private mutating func clearMarkedText() {
        markedText = ""
        selectionInMarkedText = NSRange(location: 0, length: 0)
    }
}

private struct RDPInteractiveDesktopSurface: View {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let scaleMode: RDPDesktopScaleMode
    let focusCommand: RDPDesktopInputFocusCommand
    let onInput: (RDPManualDesktopInput) -> Void
    let onViewportSize: (CGSize) -> Void
    let onInputFocusChange: (Bool) -> Void
    let onReleaseToLocalFocus: () -> Void

    var body: some View {
        Group {
            switch scaleMode {
            case .fit:
                GeometryReader { proxy in
                    let viewport = RDPDesktopViewportSizing.viewportSize(proxy.size)
                    RDPDesktopInputView(
                        image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                        fitsViewport: true, focusCommand: focusCommand,
                        onInput: onInput, onInputFocusChange: onInputFocusChange,
                        onReleaseToLocalFocus: onReleaseToLocalFocus
                    )
                    .frame(width: viewport.width, height: viewport.height)
                    .clipped()
                    .onAppear { onViewportSize(viewport) }
                    .onChange(of: proxy.size) { _, newSize in
                        onViewportSize(RDPDesktopViewportSizing.viewportSize(newSize))
                    }
                }
            case .actualSize:
                GeometryReader { proxy in
                    let viewport = RDPDesktopViewportSizing.viewportSize(proxy.size)
                    let contentSize = CGSize(
                        width: max(CGFloat(pixelWidth), 0),
                        height: max(CGFloat(pixelHeight), 0)
                    )
                    ScrollView([.horizontal, .vertical]) {
                        RDPDesktopInputView(
                            image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                            fitsViewport: false, focusCommand: focusCommand,
                            onInput: onInput, onInputFocusChange: onInputFocusChange,
                            onReleaseToLocalFocus: onReleaseToLocalFocus
                        )
                        .frame(width: max(viewport.width, contentSize.width),
                               height: max(viewport.height, contentSize.height))
                    }
                    .frame(width: viewport.width, height: viewport.height)
                    .background {
                        RDPDesktopLayoutMarker(
                            identifier: RDPDesktopLayoutIdentifiers.viewportHost
                        )
                    }
                    .clipped()
                }
                .background(Color.black)
            }
        }
        .frame(
            minWidth: 0,
            idealWidth: 0,
            maxWidth: .infinity,
            minHeight: 0,
            idealHeight: 0,
            maxHeight: .infinity
        )
        .background(Color.black)
    }


}

struct RDPDesktopLayoutMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(identifier)
    }
}

private struct RDPDesktopInputView: NSViewRepresentable {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let fitsViewport: Bool
    let focusCommand: RDPDesktopInputFocusCommand
    let onInput: (RDPManualDesktopInput) -> Void
    let onInputFocusChange: (Bool) -> Void
    let onReleaseToLocalFocus: () -> Void

    func makeNSView(context: Context) -> RDPDesktopViewportNSView {
        let view = RDPDesktopViewportNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: RDPDesktopViewportNSView, context: Context) { update(nsView) }

    private func update(_ viewport: RDPDesktopViewportNSView) {
        let view = viewport.desktop
        view.image = image
        view.pixelWidth = pixelWidth
        view.pixelHeight = pixelHeight
        view.onInput = onInput
        view.onInputFocusChange = onInputFocusChange
        view.onReleaseToLocalFocus = onReleaseToLocalFocus
        view.applyFocusCommand(focusCommand)
        viewport.fitsViewport = fitsViewport
        viewport.needsLayout = true
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RDPDesktopViewportNSView, context: Context) -> CGSize? {
        RDPDesktopViewportSizing.representableSize(width: proposal.width, height: proposal.height)
    }
}

/// Keep letterboxing and pointer coordinates in a single AppKit coordinate
/// space. Positioning an NSViewRepresentable through a SwiftUI transform can
/// leave its native clipping ancestor at the pre-transform frame on resize.
private final class RDPDesktopViewportNSView: NSView {
    let desktop = RDPDesktopNSView()
    var fitsViewport = true
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { .zero }
    override var fittingSize: NSSize { .zero }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier(RDPDesktopLayoutIdentifiers.viewportHost)
        desktop.identifier = NSUserInterfaceItemIdentifier(RDPDesktopLayoutIdentifiers.framebuffer)
        addSubview(desktop)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let frame = fitsViewport
            ? RDPDesktopViewportSizing.fittedContentRect(pixelWidth: desktop.pixelWidth,
                pixelHeight: desktop.pixelHeight, available: bounds.size)
            : RDPDesktopViewportSizing.centeredContentRect(
                contentSize: CGSize(width: max(desktop.pixelWidth, 0), height: max(desktop.pixelHeight, 0)),
                available: bounds.size)
        desktop.frame = frame.offsetBy(dx: bounds.minX, dy: bounds.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }
}

final class RDPDesktopNSView: NSView, NSTextInputClient {
    var image: NSImage?
    var pixelWidth = 0
    var pixelHeight = 0
    var onInput: ((RDPManualDesktopInput) -> Void)?
    var onInputFocusChange: ((Bool) -> Void)?
    var onReleaseToLocalFocus: (() -> Void)?

    private var trackingAreaReference: NSTrackingArea?
    private var lastPointerMove = ContinuousClock.now
    private var keyboardInputRouting = RDPDesktopKeyboardInputRouting()
    private var physicalKeyState = RDPDesktopPhysicalKeyState()
    private var pressedPointerState = RDPDesktopPressedPointerState()
    private var textInputState = RDPDesktopTextInputState()
    private var focusHandshake = RDPDesktopInputFocusHandshake()
    private var manualFocusVerificationToken: UInt64 = 0
    private var localFocusVerificationToken: UInt64 = 0
    private var lastReportedInputFocus = false
    private var isSuppressingFocusReports = false
    private var isReleasingForViewReattachment = false

    private static let remoteFocusAttemptLimit = 3
    private static let remoteFocusRetryDelay = DispatchTimeInterval.milliseconds(50)

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { .zero }
    override var fittingSize: NSSize { .zero }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        // Scaling changes every destination pixel, including the previously
        // visible area. An exposed-strip redraw is insufficient after resize.
        if changed { needsDisplay = true }
    }

    override func setBoundsSize(_ newSize: NSSize) {
        let changed = bounds.size != newSize
        super.setBoundsSize(newSize)
        if changed { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
        if let request = focusHandshake.restartPendingRemoteRequest() {
            scheduleRemoteFocusCheck(
                command: request.command,
                token: request.token,
                acquisitionAttemptsRemaining: Self.remoteFocusAttemptLimit,
                wasFocusedOnPreviousCheck: false,
                afterEventCycle: true
            )
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
        if window != nil, newWindow !== window {
            releaseForViewReattachment()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            if !focusHandshake.hasPendingRemoteCommand {
                scheduleManualFocusVerification()
            }
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            let needsLocalAcknowledgement =
                focusHandshake.cancelRemoteRequest(
                    preservingRemoteIntent: isReleasingForViewReattachment
                )
            invalidateManualFocusVerification()
            releaseRemoteInputState()
            scheduleLocalFocusVerification(
                forceLocalAcknowledgement: needsLocalAcknowledgement
            )
        }
        return resigned
    }

    func applyFocusCommand(_ command: RDPDesktopInputFocusCommand) {
        switch focusHandshake.receive(command) {
        case .ignored:
            return
        case .releaseLocal:
            invalidateManualFocusVerification()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.focusHandshake.latestCommand == command else {
                    return
                }
                self.releaseInputToLocalUI(notifyShortcut: false)
            }
        case let .requestRemote(command, token):
            invalidateManualFocusVerification()
            invalidateLocalFocusVerification()
            scheduleRemoteFocusCheck(
                command: command,
                token: token,
                acquisitionAttemptsRemaining: Self.remoteFocusAttemptLimit,
                wasFocusedOnPreviousCheck: false,
                afterEventCycle: true
            )
        }
    }

    private func scheduleRemoteFocusCheck(
        command: RDPDesktopInputFocusCommand,
        token: UInt64,
        acquisitionAttemptsRemaining: Int,
        wasFocusedOnPreviousCheck: Bool,
        afterEventCycle: Bool = false
    ) {
        if afterEventCycle {
            DispatchQueue.main.async { [weak self] in
                self?.performRemoteFocusCheck(
                    command: command,
                    token: token,
                    acquisitionAttemptsRemaining: acquisitionAttemptsRemaining,
                    wasFocusedOnPreviousCheck: wasFocusedOnPreviousCheck
                )
            }
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.remoteFocusRetryDelay
            ) { [weak self] in
                self?.performRemoteFocusCheck(
                    command: command,
                    token: token,
                    acquisitionAttemptsRemaining: acquisitionAttemptsRemaining,
                    wasFocusedOnPreviousCheck: wasFocusedOnPreviousCheck
                )
            }
        }
    }

    private func performRemoteFocusCheck(
        command: RDPDesktopInputFocusCommand,
        token: UInt64,
        acquisitionAttemptsRemaining: Int,
        wasFocusedOnPreviousCheck: Bool
    ) {
        guard focusHandshake.acceptsRemoteAttempt(
            command: command,
            token: token
        ) else {
            return
        }
        guard let window else {
            return
        }
        guard window.isKeyWindow else {
            cancelRemoteFocusAndReleaseInput()
            return
        }

        let wasFocusedBeforeAttempt = window.firstResponder === self
        var isFocusedAfterAttempt = wasFocusedBeforeAttempt
        var remainingAttempts = acquisitionAttemptsRemaining
        if !wasFocusedBeforeAttempt, remainingAttempts > 0 {
            let accepted = window.makeFirstResponder(self)
            isFocusedAfterAttempt = accepted && window.firstResponder === self
            remainingAttempts -= 1
        }

        if wasFocusedOnPreviousCheck,
           wasFocusedBeforeAttempt,
           isFocusedAfterAttempt,
           focusHandshake.acknowledgeRemoteAttempt(
               command: command,
               token: token
           ) {
            reportInputFocus(true)
            return
        }

        guard isFocusedAfterAttempt || remainingAttempts > 0 else {
            cancelRemoteFocusAndReleaseInput()
            return
        }
        scheduleRemoteFocusCheck(
            command: command,
            token: token,
            acquisitionAttemptsRemaining: remainingAttempts,
            wasFocusedOnPreviousCheck: isFocusedAfterAttempt
        )
    }

    private func scheduleManualFocusVerification() {
        guard focusHandshake.latestCommand.destination == .local,
              !focusHandshake.hasPendingRemoteCommand else {
            return
        }
        manualFocusVerificationToken = nextManualFocusVerificationToken()
        let token = manualFocusVerificationToken
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.remoteFocusRetryDelay
        ) { [weak self] in
            guard let self,
                  self.manualFocusVerificationToken == token,
                  self.focusHandshake.latestCommand.destination == .local,
                  !self.focusHandshake.hasPendingRemoteCommand,
                  let window = self.window,
                  window.isKeyWindow,
                  window.firstResponder === self else {
                return
            }
            self.reportInputFocus(true)
        }
    }

    private func invalidateManualFocusVerification() {
        manualFocusVerificationToken = nextManualFocusVerificationToken()
    }

    private func nextManualFocusVerificationToken() -> UInt64 {
        manualFocusVerificationToken == .max
            ? 1
            : manualFocusVerificationToken + 1
    }

    private func scheduleLocalFocusVerification(
        forceLocalAcknowledgement: Bool
    ) {
        localFocusVerificationToken = nextLocalFocusVerificationToken()
        let token = localFocusVerificationToken
        DispatchQueue.main.async { [weak self] in
            guard let self, self.localFocusVerificationToken == token else {
                return
            }
            let remainsRemoteFirstResponder =
                self.window?.isKeyWindow == true
                && self.window?.firstResponder === self
            if remainsRemoteFirstResponder {
                self.reportInputFocus(true)
            } else {
                self.reportInputFocus(
                    false,
                    force: forceLocalAcknowledgement
                        && !self.lastReportedInputFocus
                )
            }
        }
    }

    private func invalidateLocalFocusVerification() {
        localFocusVerificationToken = nextLocalFocusVerificationToken()
    }

    private func nextLocalFocusVerificationToken() -> UInt64 {
        localFocusVerificationToken == .max
            ? 1
            : localFocusVerificationToken + 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, action: .mouseDown, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(
            event,
            action: .mouseUp,
            button: .left,
            clampsOutsideBounds: true
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, action: .mouseDown, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(
            event,
            action: .mouseUp,
            button: .right,
            clampsOutsideBounds: true
        )
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, action: .mouseDown, button: .middle)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendPointer(
            event,
            action: .mouseUp,
            button: .middle,
            clampsOutsideBounds: true
        )
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(
            event,
            action: .movePointer,
            button: .left,
            clampsOutsideBounds: true
        )
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(
            event,
            action: .movePointer,
            button: .right,
            clampsOutsideBounds: true
        )
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(
            event,
            action: .movePointer,
            button: .middle,
            clampsOutsideBounds: true
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let now = ContinuousClock.now
        guard lastPointerMove.duration(to: now) >= .milliseconds(16) else { return }
        lastPointerMove = now
        sendPointer(event, action: .movePointer, button: .left)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = remotePoint(for: event) else { return }
        let deltaX = Int((event.scrollingDeltaX * 120).rounded())
        let deltaY = Int((event.scrollingDeltaY * 120).rounded())
        onInput?(.pointer(
            action: .scroll,
            point: point,
            button: .middle,
            deltaX: deltaX,
            deltaY: deltaY == 0 ? (event.scrollingDeltaY < 0 ? -1 : 1) : deltaY
        ))
    }

    override func keyDown(with event: NSEvent) {
        let name = Self.remoteKeyName(for: event)
        switch keyboardInputRouting.keyDownRoute(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            hasPhysicalKey: name != nil,
            hasMarkedText: textInputState.hasMarkedText
        ) {
        case .releaseLocalFocus:
            _ = focusHandshake.cancelRemoteRequest()
            invalidateManualFocusVerification()
            releaseInputToLocalUI(notifyShortcut: true)
        case .textInput:
            interpretKeyEvents([event])
        case let .remoteChord(modifiers):
            guard let name else { return }
            onInput?(.key(
                name: name,
                isDown: true,
                modifiers: modifiers
            ))
        case .physicalKey:
            guard let name else { return }
            physicalKeyState.recordKeyDown(
                keyCode: event.keyCode,
                name: name
            )
            onInput?(.key(
                name: name,
                isDown: true,
                modifiers: Self.modifierNames(for: event)
            ))
        case .ignored:
            break
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.type == .keyDown,
              RDPDesktopKeyboardInputRouting.shouldMapMacClipboardShortcut(
                  characters: event.charactersIgnoringModifiers ?? event.characters,
                  modifierFlags: event.modifierFlags
              ),
              let name = Self.remoteKeyName(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        guard case let .remoteChord(modifiers) =
            keyboardInputRouting.keyDownRoute(
                keyCode: event.keyCode,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags,
                hasPhysicalKey: true,
                hasMarkedText: textInputState.hasMarkedText
            ) else {
            return super.performKeyEquivalent(with: event)
        }
        onInput?(.key(
            name: name,
            isDown: true,
            modifiers: modifiers
        ))
        return true
    }

    override func keyUp(with event: NSEvent) {
        let fallbackName = Self.remoteKeyName(for: event)
        guard keyboardInputRouting.shouldSendPhysicalKeyUp(
            keyCode: event.keyCode,
            hasPhysicalKey: fallbackName != nil
        ), let name = physicalKeyState.keyUpName(
            keyCode: event.keyCode,
            fallbackName: fallbackName
        ) else { return }
        onInput?(.key(name: name, isDown: false, modifiers: []))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = Self.plainText(from: string) else { return }
        handleTextInputEffect(textInputState.insertText(text))
    }

    override func doCommand(by selector: Selector) {
        // Non-printable keys are sent through the physical path before text
        // interpretation when no composition exists. During composition the
        // input method owns command selectors and will call insertText if it
        // commits text; forwarding a selector here could send it twice.
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        guard let text = Self.plainText(from: string) else { return }
        handleTextInputEffect(textInputState.setMarkedText(
            text,
            selectedRange: selectedRange
        ))
    }

    func unmarkText() {
        handleTextInputEffect(textInputState.unmarkText())
    }

    func selectedRange() -> NSRange {
        textInputState.selectedRange
    }

    func markedRange() -> NSRange {
        textInputState.markedRange
    }

    func hasMarkedText() -> Bool {
        textInputState.hasMarkedText
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = NSRange(location: 0, length: 0)
        guard let window else { return .zero }
        let localRect = NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1)
        return window.convertToScreen(convert(localRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    private func handleTextInputEffect(_ effect: RDPDesktopTextInputEffect) {
        guard case let .commit(text) = effect else { return }
        onInput?(.text(text))
    }

    private func releaseInputToLocalUI(
        notifyShortcut: Bool,
        forceLocalAcknowledgement: Bool = false
    ) {
        releaseRemoteInputState()
        if window?.firstResponder === self {
            _ = window?.makeFirstResponder(nil)
        }
        scheduleLocalFocusVerification(
            forceLocalAcknowledgement: forceLocalAcknowledgement
        )
        if notifyShortcut {
            onReleaseToLocalFocus?()
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        cancelRemoteFocusAndReleaseInput()
    }

    private func cancelRemoteFocusAndReleaseInput() {
        let needsLocalAcknowledgement = focusHandshake.cancelRemoteRequest()
        invalidateManualFocusVerification()
        releaseInputToLocalUI(
            notifyShortcut: false,
            forceLocalAcknowledgement: needsLocalAcknowledgement
        )
    }

    private func releaseForViewReattachment() {
        let wasSuppressingFocusReports = isSuppressingFocusReports
        isSuppressingFocusReports = true
        isReleasingForViewReattachment = true
        defer {
            isReleasingForViewReattachment = false
            isSuppressingFocusReports = wasSuppressingFocusReports
        }
        focusHandshake.suspendForViewReattachment()
        invalidateManualFocusVerification()
        releaseInputToLocalUI(notifyShortcut: false)
        invalidateLocalFocusVerification()
        lastReportedInputFocus = false
    }

    private func releaseRemoteInputState() {
        let plan = RDPDesktopInputReleasePlan.drain(
            pointerState: &pressedPointerState,
            physicalKeyState: &physicalKeyState,
            textInputState: &textInputState
        )
        if plan.discardedMarkedText {
            inputContext?.discardMarkedText()
        }
        for pendingRelease in plan.pointerReleases {
            guard let release = pendingRelease.clamped(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ) else {
                continue
            }
            onInput?(.pointer(
                action: .mouseUp,
                point: release.point,
                button: release.button,
                deltaX: nil,
                deltaY: nil
            ))
        }
        for name in plan.physicalKeyNames {
            onInput?(.key(name: name, isDown: false, modifiers: []))
        }
    }

    private func reportInputFocus(_ focused: Bool, force: Bool = false) {
        guard !isSuppressingFocusReports else { return }
        guard force || focused != lastReportedInputFocus else { return }
        lastReportedInputFocus = focused
        onInputFocusChange?(focused)
    }

    private static func plainText(from value: Any) -> String? {
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return value as? String
    }

    private func sendPointer(
        _ event: NSEvent,
        action: DesktopActionKind,
        button: DesktopMouseButton,
        clampsOutsideBounds: Bool = false
    ) {
        let point = remotePoint(
            for: event,
            clampsOutsideBounds: clampsOutsideBounds
        ) ?? (action == .mouseUp ? pressedPointerState.lastPoint(for: button) : nil)
        guard let point else { return }
        switch action {
        case .mouseDown:
            pressedPointerState.recordMouseDown(button: button, point: point)
        case .movePointer:
            pressedPointerState.recordPointerMove(button: button, point: point)
        case .mouseUp:
            guard pressedPointerState.recordMouseUp(button: button) else {
                return
            }
        default:
            break
        }
        onInput?(.pointer(action: action, point: point, button: button, deltaX: nil, deltaY: nil))
    }

    private func remotePoint(
        for event: NSEvent,
        clampsOutsideBounds: Bool = false
    ) -> DesktopPoint? {
        guard pixelWidth > 0, pixelHeight > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        guard clampsOutsideBounds || bounds.contains(local) else { return nil }
        let clampedX = min(max(local.x, bounds.minX), bounds.maxX)
        let clampedY = min(max(local.y, bounds.minY), bounds.maxY)
        let x = min(
            max(
                Int(
                    ((clampedX - bounds.minX) / bounds.width)
                        * CGFloat(pixelWidth)
                ),
                0
            ),
            pixelWidth - 1
        )
        let y = min(
            max(
                Int(
                    ((clampedY - bounds.minY) / bounds.height)
                        * CGFloat(pixelHeight)
                ),
                0
            ),
            pixelHeight - 1
        )
        return DesktopPoint(x: x, y: y)
    }

    private static func modifierNames(for event: NSEvent) -> [String] {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var names: [String] = []
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("alt") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.command) { names.append("meta") }
        return names
    }

    private static func remoteKeyName(for event: NSEvent) -> String? {
        let fixed: [UInt16: String] = [
            36: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape",
            115: "home", 116: "pageup", 117: "delete", 119: "end", 121: "pagedown",
            123: "left", 124: "right", 125: "down", 126: "up",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
            98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        ]
        if let value = fixed[event.keyCode] { return value }
        guard let value = event.charactersIgnoringModifiers?.lowercased(), value.count == 1 else { return nil }
        return value
    }
}


private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

#endif
