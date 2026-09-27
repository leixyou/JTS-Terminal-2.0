#if ENABLE_RDP_2
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct RemoteGrantApprovalScope: Equatable, Sendable {
    var capabilities: Set<RemoteCapability>
    var externalDataTypes: Set<RemoteExternalDataType>
    var grantsPersistentTargetAccess: Bool

    var requiresExternalDataConsent: Bool {
        !externalDataTypes.isEmpty
    }

    static func resolved(
        request: RemoteGrantRequest,
        connectionType: RemoteConnectionType,
        policy: RemoteTargetPermissionPolicy
    ) -> RemoteGrantApprovalScope {
        // Every shipping target now exposes persistent, revocable scopes. Show
        // the complete configured scope once so a single explicit approval is
        // enough for this registered client and bound server account.
        guard !policy.containsControlLeaseCapability(in: policy.maximumCapabilities) else {
            return RemoteGrantApprovalScope(
                capabilities: request.requestedCapabilities,
                externalDataTypes: request.externalDataTypes,
                grantsPersistentTargetAccess: false
            )
        }
        return RemoteGrantApprovalScope(
            capabilities: policy.maximumCapabilities,
            externalDataTypes: RemoteExternalDataPolicy.completeTypes(
                for: policy.maximumCapabilities
            ),
            grantsPersistentTargetAccess: true
        )
    }
}

nonisolated struct RemoteGrantManagementButtonContent: Equatable, Sendable {
    var title: String
    var accessibilityValue: String
    var systemImage: String
}

nonisolated struct RemoteGrantRequestContent: Equatable, Sendable {
    var reasonSummary: String
    var persistentAccessSummary: String?
    var elevationSummary: String?
}

nonisolated enum RemoteGrantAccessStatus: Equatable, Sendable {
    case persistentExactTarget
    case persistentPaused
    case temporaryControl(expiresAt: Date)
    case temporaryPaused(expiresAt: Date)
    case expiredTemporaryControl
}

nonisolated struct RemoteGrantAccessStatusContent: Equatable, Sendable {
    var status: RemoteGrantAccessStatus
    var summary: String
    var elevationSummary: String?

    var systemImage: String {
        switch status {
        case .persistentExactTarget:
            return "infinity"
        case .persistentPaused, .temporaryPaused:
            return "pause.circle"
        case .temporaryControl, .expiredTemporaryControl:
            return "timer"
        }
    }

    var isExpired: Bool {
        status == .expiredTemporaryControl
    }
}

enum RemoteGrantManagementPane: String, CaseIterable, Identifiable, Sendable {
    case access
    case audit

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .access:
            return language.localized("Access", "访问")
        case .audit:
            return language.localized("Audit", "审计")
        }
    }

    var systemImage: String {
        switch self {
        case .access:
            return "person.badge.key"
        case .audit:
            return "list.bullet.clipboard"
        }
    }
}

nonisolated enum RemoteGrantManagementLayoutPolicy {
    static func centersEmptyAccess(
        pane: RemoteGrantManagementPane,
        hasPersistenceError: Bool,
        pendingRequestCount: Int,
        activeGrantCount: Int
    ) -> Bool {
        pane == .access
            && !hasPersistenceError
            && pendingRequestCount <= 0
            && activeGrantCount <= 0
    }
}

enum RemoteGrantTimestampTextPolicy {
    static func relative(
        _ date: Date,
        to referenceDate: Date = Date(),
        language: AppLanguage
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    static func dateAndTime(
        _ date: Date,
        language: AppLanguage
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func time(
        _ date: Date,
        language: AppLanguage
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

nonisolated enum RemoteGrantAuditTimelinePolicy {
    static let refreshInterval: TimeInterval = 30
}

enum RemoteGrantManagementContentPolicy {
    static func emptyAccessSummary(
        isMCPEnabled: Bool,
        language: AppLanguage
    ) -> String {
        if isMCPEnabled {
            return language.localized(
                "After you enable MCP, registered AI clients can use this server account directly. Usage is recorded in Audit, and you can revoke a client here.",
                "启用 MCP 后，已注册的 AI 客户端可以直接使用此服务器账号。使用情况会记入审计，需要时再从这里撤销。"
            )
        }
        return language.localized(
            "MCP is disabled for this server. Enable it in Server Properties before a registered AI client can request access.",
            "此服务器尚未启用 MCP。请先在“服务器属性”中启用，已注册的 AI 客户端才能请求访问。"
        )
    }

    static func pendingSectionFooter(
        connectionType: RemoteConnectionType,
        capabilities: Set<RemoteCapability>,
        policy: RemoteTargetPermissionPolicy,
        language: AppLanguage
    ) -> String {
        let effectiveCapabilities = capabilities.intersection(
            policy.maximumCapabilities
        )
        if policy.containsControlLeaseCapability(in: effectiveCapabilities) {
            return language.localized(
                "Approval applies only to this registered AI client and the server account shown above. Temporary control expires after inactivity.",
                "审批仅适用于此已注册 AI 客户端和上方显示的服务器账号。临时控制会在空闲后到期。"
            )
        }
        guard connectionType == .rdp else {
            return language.localized(
                "Approval applies only to this registered AI client and the server account shown above. Access remains until you revoke it from AI Access Management.",
                "审批仅适用于此已注册 AI 客户端和上方显示的服务器账号。授权会持续有效，直到你在“AI 访问管理”中主动撤销。"
            )
        }
        return language.localized(
            "Access for this registered AI client to the Windows account shown above remains until you revoke it.",
            "此已注册 AI 客户端对上方 Windows 账号的访问会持续有效，直到你主动撤销。"
        )
    }

    static func requestContent(
        reason: RemoteGrantRequestReason,
        scope: RemoteGrantApprovalScope,
        language: AppLanguage
    ) -> RemoteGrantRequestContent {
        let reasonSummary: String
        switch reason {
        case .newGrant:
            reasonSummary = language.localized(
                "New AI client access request",
                "新的 AI 客户端访问请求"
            )
        case .capabilityExpansion:
            reasonSummary = language.localized(
                "Additional access requested",
                "请求增加访问权限"
            )
        case .externalDataConsent:
            reasonSummary = language.localized(
                "External data consent required",
                "需要同意外部数据处理"
            )
        case .controlLeaseRenewal:
            reasonSummary = scope.grantsPersistentTargetAccess
                ? language.localized(
                    "Persistent server access approval required",
                    "需要批准长期服务器访问"
                )
                : language.localized(
                    "Temporary control renewal required",
                    "需要续期临时控制权限"
                )
        }

        guard scope.grantsPersistentTargetAccess else {
            return RemoteGrantRequestContent(
                reasonSummary: reasonSummary,
                persistentAccessSummary: nil,
                elevationSummary: nil
            )
        }
        return RemoteGrantRequestContent(
            reasonSummary: reasonSummary,
            persistentAccessSummary: language.localized(
                "Access to the server account shown above remains until you revoke it.",
                "对上方服务器账号的访问会持续有效，直到你主动撤销。"
            ),
            elevationSummary: elevationSummary(
                capabilities: scope.capabilities,
                language: language
            )
        )
    }

    static func activeGrantContent(
        capabilities: Set<RemoteCapability>,
        lastUsedAt: Date,
        policy: RemoteTargetPermissionPolicy,
        isMCPEnabled: Bool = true,
        now: Date = Date(),
        language: AppLanguage
    ) -> RemoteGrantAccessStatusContent {
        let effectiveCapabilities = capabilities.intersection(
            policy.maximumCapabilities
        )
        let hasControlLease = policy.containsControlLeaseCapability(
            in: effectiveCapabilities
        )
        guard hasControlLease else {
            guard isMCPEnabled else {
                return RemoteGrantAccessStatusContent(
                    status: .persistentPaused,
                    summary: language.localized(
                        "Authorization saved; access is paused while MCP is off",
                        "授权已保存；MCP 关闭期间访问已暂停"
                    ),
                    elevationSummary: nil
                )
            }
            return RemoteGrantAccessStatusContent(
                status: .persistentExactTarget,
                summary: language.localized(
                    "Access remains until revoked",
                    "访问会持续有效，直到主动撤销"
                ),
                elevationSummary: elevationSummary(
                    capabilities: effectiveCapabilities,
                    language: language
                )
            )
        }

        let expiry = lastUsedAt.addingTimeInterval(
            TimeInterval(policy.controlIdleTimeoutSeconds)
        )
        guard expiry > now else {
            return RemoteGrantAccessStatusContent(
                status: .expiredTemporaryControl,
                summary: language.localized(
                    "Temporary control expired",
                    "临时控制已到期"
                ),
                elevationSummary: nil
            )
        }
        guard isMCPEnabled else {
            return RemoteGrantAccessStatusContent(
                status: .temporaryPaused(expiresAt: expiry),
                summary: language.localized(
                    "Temporary control paused; expires at \(RemoteGrantTimestampTextPolicy.time(expiry, language: language))",
                    "临时控制已暂停；将于 \(RemoteGrantTimestampTextPolicy.time(expiry, language: language)) 到期"
                ),
                elevationSummary: nil
            )
        }
        return RemoteGrantAccessStatusContent(
            status: .temporaryControl(expiresAt: expiry),
            summary: language.localized(
                "Temporary control until \(RemoteGrantTimestampTextPolicy.time(expiry, language: language))",
                "临时控制至 \(RemoteGrantTimestampTextPolicy.time(expiry, language: language))"
            ),
            elevationSummary: nil
        )
    }

    static func approvalButtonTitle(
        scope: RemoteGrantApprovalScope,
        language: AppLanguage
    ) -> String {
        if scope.grantsPersistentTargetAccess {
            return scope.requiresExternalDataConsent
                ? language.localized(
                    "Always Allow & Consent",
                    "始终允许并同意共享"
                )
                : language.localized("Always Allow", "始终允许")
        }
        return scope.requiresExternalDataConsent
            ? language.localized("Allow & Consent", "允许并同意共享")
            : language.localized("Allow", "允许")
    }

    private static func elevationSummary(
        capabilities: Set<RemoteCapability>,
        language: AppLanguage
    ) -> String? {
        guard capabilities.contains(.elevation) else { return nil }
        return language.localized(
            "Each elevated action still requires separate confirmation on Windows.",
            "每次提权仍需在 Windows 上单独确认。"
        )
    }
}

enum RemoteGrantManagementButtonContentPolicy {
    static func content(
        isMCPEnabled: Bool,
        activeGrantCount: Int,
        pendingRequestCount: Int,
        language: AppLanguage
    ) -> RemoteGrantManagementButtonContent {
        let activeCount = max(0, activeGrantCount)
        let pendingCount = max(0, pendingRequestCount)
        let title: String
        if pendingCount > 0 {
            title = language.localized(
                "AI Access · \(pendingCount) pending",
                "AI 访问 · 待确认 \(pendingCount)"
            )
        } else if !isMCPEnabled, activeCount > 0 {
            title = language.localized(
                "AI Access · Paused",
                "AI 访问 · 已暂停"
            )
        } else if activeCount > 0 {
            title = language.localized(
                "AI Access · \(activeCount) active",
                "AI 访问 · 已授权 \(activeCount)"
            )
        } else if !isMCPEnabled {
            title = language.localized("AI Access · Off", "AI 访问 · 关闭")
        } else {
            title = language.localized("AI Access", "AI 访问")
        }
        let accessibilityValue = language.localized(
            "MCP \(isMCPEnabled ? "on" : "off"). "
                + countDescription(activeCount, singular: "authorized client", plural: "authorized clients")
                + ". "
                + countDescription(pendingCount, singular: "request needing review", plural: "requests needing review")
                + ".",
            "MCP 已\(isMCPEnabled ? "开启" : "关闭")。已授权客户端 \(activeCount) 个。待确认请求 \(pendingCount) 个。"
        )
        let systemImage = pendingCount > 0
            ? "person.crop.circle.badge.exclamationmark"
            : "person.badge.key"
        return RemoteGrantManagementButtonContent(
            title: title,
            accessibilityValue: accessibilityValue,
            systemImage: systemImage
        )
    }

    private static func countDescription(
        _ count: Int,
        singular: String,
        plural: String
    ) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

nonisolated enum RemoteGrantManagementAccessibilityIdentifier {
    static let managementButton = "rdp-ai-access-button"
    static let pendingEntryButton = "rdp-ai-pending-access-button"
    static let panePicker = "rdp-ai-management-pane-picker"
    static let pendingRequestRow = "rdp-ai-pending-request-row"
    static let alwaysAllowButton = "rdp-ai-always-allow-button"
    static let allowButton = "rdp-ai-allow-button"
    static let denyButton = "rdp-ai-deny-button"
    static let activeGrantRow = "rdp-ai-active-grant-row"
    static let emptyAccessState = "rdp-ai-empty-access-state"
    static let grantStoreError = "rdp-ai-grant-store-error"
    static let auditStoreError = "rdp-ai-audit-store-error"
    static let revokeButton = "rdp-ai-revoke-button"
}

/// Compact entry point intended for the native Desktop toolbar. The detail UI
/// is a stable List with explicit approval and revoke actions, not a dashboard.
struct RemoteGrantManagementButton: View {
    @ObservedObject private var grantStore = RemoteClientGrantStore.shared
    let session: RemoteSession
    let language: AppLanguage
    var accessibilityIdentifier =
        RemoteGrantManagementAccessibilityIdentifier.managementButton
    var authorityWasRevoked: (() -> Void)?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(content.title, systemImage: content.systemImage)
        }
        .help(content.accessibilityValue)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(content.accessibilityValue)
        .accessibilityIdentifier(accessibilityIdentifier)
        .sheet(isPresented: $isPresented) {
            RemoteGrantManagementView(
                session: session,
                authorityWasRevoked: authorityWasRevoked
            )
            .environment(\.appLanguage, language)
            .environment(
                \.locale,
                Locale(identifier: language.localeIdentifier)
            )
        }
        .onAppear {
            _ = try? grantStore.reconcileResolvedPendingRequests(
                targetID: session.targetID,
                policy: session.mcpPermissionPolicy,
                targetBinding: session.mcpGrantTargetBinding
            )
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            grantStore.reloadFromDiskIfChanged()
            RemoteCapabilityAuditStore.shared.reloadFromDiskIfChanged()
        }
    }

    private var pending: [RemoteGrantRequest] {
        grantStore.pendingRequests(
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding
        )
    }

    private var active: [RemoteClientGrant] {
        grantStore.activeGrants(
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding
        )
    }

    private var content: RemoteGrantManagementButtonContent {
        RemoteGrantManagementButtonContentPolicy.content(
            isMCPEnabled: session.mcpEnabled,
            activeGrantCount: active.count,
            pendingRequestCount: pending.count,
            language: language
        )
    }

    private var accessibilityLabel: String {
        if accessibilityIdentifier
            == RemoteGrantManagementAccessibilityIdentifier.pendingEntryButton {
            return language.localized(
                "Review AI Access Request",
                "确认 AI 访问请求"
            )
        }
        return language.localized("AI Access Management", "AI 访问管理")
    }
}

struct RemoteGrantManagementView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var grantStore = RemoteClientGrantStore.shared
    @ObservedObject private var auditStore = RemoteCapabilityAuditStore.shared

    let session: RemoteSession
    var authorityWasRevoked: (() -> Void)?

    @State private var errorMessage = ""
    @State private var isConfirmingAuditClear = false
    @State private var selectedPane: RemoteGrantManagementPane = .access

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("", selection: $selectedPane) {
                ForEach(RemoteGrantManagementPane.allCases) { pane in
                    Label(
                        pane.title(language: language),
                        systemImage: pane.systemImage
                    )
                    .tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .accessibilityIdentifier(
                RemoteGrantManagementAccessibilityIdentifier.panePicker
            )

            if centersEmptyAccess {
                emptyAccessView
            } else {
                List {
                    if selectedPane == .access {
                        if let persistenceError = grantStore.persistenceError {
                            persistenceFailureSection(
                                title: language.localized(
                                    "AI access state could not be verified",
                                    "无法核验 AI 访问状态"
                                ),
                                detail: persistenceError,
                                accessibilityIdentifier:
                                    RemoteGrantManagementAccessibilityIdentifier
                                        .grantStoreError,
                                retry: reloadGrantState
                            )
                        } else {
                            if !pendingRequests.isEmpty {
                                pendingSection
                            }
                            if !activeGrants.isEmpty {
                                activeGrantSection
                            }
                        }
                    } else {
                        if let persistenceError = auditStore.persistenceError {
                            persistenceFailureSection(
                                title: language.localized(
                                    "Audit history could not be verified",
                                    "无法核验审计记录"
                                ),
                                detail: persistenceError,
                                accessibilityIdentifier:
                                    RemoteGrantManagementAccessibilityIdentifier
                                        .auditStoreError,
                                retry: reloadAuditState
                            )
                        } else {
                            auditSection
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 300, idealHeight: 340)
        .alert(
            language.localized("AI Access Error", "AI 访问错误"),
            isPresented: Binding(
                get: { !errorMessage.isEmpty },
                set: { if !$0 { errorMessage = "" } }
            )
        ) {
            Button(language.localized("OK", "好"), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(
            language.localized("Clear this target's MCP audit history?", "清除此目标的 MCP 审计记录？"),
            isPresented: $isConfirmingAuditClear,
            titleVisibility: .visible
        ) {
            Button(language.localized("Clear Audit History", "清除审计记录"), role: .destructive) {
                do {
                    try auditStore.clear(targetID: session.targetID)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button(language.localized("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(language.localized(
                "This permanently removes the local metadata records for this target.",
                "这会永久删除此目标的本地元数据记录。"
            ))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.localized("AI Access Management", "AI 访问管理"))
                    .font(.headline)
                Text(session.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(session.connectionKey, systemImage: "server.rack")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.connectionKey)
                    .accessibilityLabel(
                        language.localized(
                            "Access target",
                            "访问目标"
                        )
                    )
                    .accessibilityValue(session.connectionKey)
                    .accessibilityIdentifier(
                        "rdp-ai-authorization-target"
                    )
            }
            Spacer()
            Button(language.localized("Done", "完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func persistenceFailureSection(
        title: String,
        detail: String,
        accessibilityIdentifier: String,
        retry: @escaping () -> Void
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "exclamationmark.shield.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)

                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Button(
                    language.localized("Retry", "重试"),
                    action: retry
                )
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private func reloadGrantState() {
        grantStore.reloadFromDiskIfChanged(force: true)
        guard grantStore.persistenceError == nil else { return }
        do {
            _ = try grantStore.reconcileResolvedPendingRequests(
                targetID: session.targetID,
                policy: session.mcpPermissionPolicy,
                targetBinding: session.mcpGrantTargetBinding
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadAuditState() {
        auditStore.reloadFromDiskIfChanged()
    }

    @ViewBuilder
    private var pendingSection: some View {
        Section {
            ForEach(pendingRequests) { request in
                let scope = RemoteGrantApprovalScope.resolved(
                    request: request,
                    connectionType: session.connectionType,
                    policy: session.mcpPermissionPolicy
                )
                PendingGrantRequestRow(
                    request: request,
                    scope: scope,
                    language: language,
                    approve: { approve(request, scope: scope) },
                    deny: { deny(request) }
                )
            }
        } header: {
            Text(language.localized("Needs Your Review", "需要你确认"))
        } footer: {
            Text(RemoteGrantManagementContentPolicy.pendingSectionFooter(
                connectionType: session.connectionType,
                capabilities: session.mcpPermissionPolicy.maximumCapabilities,
                policy: session.mcpPermissionPolicy,
                language: language
            ))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyAccessView: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text(language.localized(
                        "No AI access granted",
                        "尚未授予 AI 访问权限"
                    ))
                    .font(.headline)

                    Text(RemoteGrantManagementContentPolicy.emptyAccessSummary(
                        isMCPEnabled: session.mcpEnabled,
                        language: language
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    RemoteGrantManagementAccessibilityIdentifier
                        .emptyAccessState
                )
                .frame(maxWidth: .infinity)
                .frame(
                    minHeight: geometry.size.height,
                    alignment: .center
                )
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var activeGrantSection: some View {
        Section {
            ForEach(activeGrants, id: \.grantID) { grant in
                ActiveRemoteGrantRow(
                    grant: grant,
                    policy: session.mcpPermissionPolicy,
                    isMCPEnabled: session.mcpEnabled,
                    language: language,
                    revoke: { revoke(grant) }
                )
            }
        } header: {
            Text(language.localized("Authorized Clients", "已授权客户端"))
        } footer: {
            Text(
                session.mcpEnabled
                    ? language.localized(
                        "Each client's access is limited to this server account and remains active until you revoke it.",
                        "每个客户端的访问仅限此服务器账号，并会持续有效，直到你主动撤销。"
                    )
                    : language.localized(
                        "Saved authorizations are paused while MCP is off. They resume for this exact server account if you enable MCP again, or you can revoke them now.",
                        "MCP 关闭期间，已保存的授权会暂停；重新启用后只会对这个精确服务器账号恢复，也可以现在主动撤销。"
                    )
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var auditSection: some View {
        Section {
            if auditRecords.isEmpty {
                Text(language.localized("No MCP audit records in the retention window.", "保留期内没有 MCP 审计记录。"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(auditRecords) { record in
                    RemoteCapabilityAuditRow(record: record, language: language)
                }
            }
        } header: {
            HStack {
                Text(language.localized("Recent Audit (30 days)", "近期审计（30 天）"))
                Spacer()
                Button(language.localized("Export…", "导出…"), action: exportAudit)
                    .buttonStyle(.borderless)
                    .disabled(auditRecords.isEmpty)
                Button(language.localized("Clear…", "清除…"), role: .destructive) {
                    isConfirmingAuditClear = true
                }
                .buttonStyle(.borderless)
                .disabled(auditRecords.isEmpty)
            }
        } footer: {
            Text(language.localized(
                "Audit records contain only client, target, allowlisted action and capability categories, result, duration, and timestamps. Screenshots, typed text, passwords, complete commands, clipboard values, paths, and file contents are never stored.",
                "审计仅包含客户端、目标、白名单动作及能力类别、结果、持续时间和时间戳；绝不保存截图、输入文本、密码、完整命令、剪贴板内容、路径或文件内容。"
            ))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func approve(
        _ request: RemoteGrantRequest,
        scope: RemoteGrantApprovalScope
    ) {
        do {
            _ = try grantStore.approve(
                requestID: request.id,
                policy: session.mcpPermissionPolicy,
                consentToExternalData: scope.requiresExternalDataConsent,
                grantPersistentTargetAccess: scope.grantsPersistentTargetAccess,
                currentTargetBinding: session.mcpGrantTargetBinding
            )
            auditStore.record(
                clientID: request.clientID,
                clientDisplayIdentity: request.clientDisplayIdentity,
                targetID: request.targetID,
                targetAlias: session.effectiveMCPAlias,
                actionType: "grant.approve",
                capabilities: scope.capabilities,
                result: .approved,
                resultCode: scope.requiresExternalDataConsent ? "APPROVED_WITH_EXTERNAL_DATA_CONSENT" : "APPROVED",
                controlLeaseExpiresAt: session.mcpPermissionPolicy.containsControlLeaseCapability(
                    in: scope.capabilities
                )
                    ? Date().addingTimeInterval(TimeInterval(session.mcpPermissionPolicy.controlIdleTimeoutSeconds))
                    : nil,
                startedAt: Date()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deny(_ request: RemoteGrantRequest) {
        do {
            try grantStore.deny(requestID: request.id)
            auditStore.record(
                clientID: request.clientID,
                clientDisplayIdentity: request.clientDisplayIdentity,
                targetID: request.targetID,
                targetAlias: session.effectiveMCPAlias,
                actionType: "grant.deny",
                capabilities: request.requestedCapabilities,
                result: .denied,
                resultCode: "USER_DENIED",
                controlLeaseExpiresAt: nil,
                startedAt: Date()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ grant: RemoteClientGrant) {
        do {
            try grantStore.revoke(grantID: grant.grantID)
            auditStore.record(
                clientID: grant.clientID,
                clientDisplayIdentity: grant.clientDisplayIdentity,
                targetID: grant.targetID,
                targetAlias: session.effectiveMCPAlias,
                actionType: "grant.revoke",
                capabilities: grant.capabilities,
                result: .revoked,
                resultCode: "USER_REVOKED",
                controlLeaseExpiresAt: nil,
                startedAt: Date()
            )
            authorityWasRevoked?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportAudit() {
        let panel = NSSavePanel()
        panel.title = language.localized("Export MCP Audit", "导出 MCP 审计")
        panel.nameFieldStringValue = "jts-mcp-audit-\(session.effectiveMCPAlias).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try auditStore.export(to: url, targetID: session.targetID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var pendingRequests: [RemoteGrantRequest] {
        grantStore.pendingRequests(
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding
        )
    }

    private var activeGrants: [RemoteClientGrant] {
        grantStore.activeGrants(
            targetID: session.targetID,
            targetBinding: session.mcpGrantTargetBinding
        )
    }

    private var auditRecords: [RemoteCapabilityAuditRecord] {
        Array(auditStore.records(targetID: session.targetID).prefix(100))
    }

    private var centersEmptyAccess: Bool {
        RemoteGrantManagementLayoutPolicy.centersEmptyAccess(
            pane: selectedPane,
            hasPersistenceError: grantStore.persistenceError != nil,
            pendingRequestCount: pendingRequests.count,
            activeGrantCount: activeGrants.count
        )
    }
}

private struct PendingGrantRequestRow: View {
    let request: RemoteGrantRequest
    let scope: RemoteGrantApprovalScope
    let language: AppLanguage
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            requestSummary
            HStack(spacing: 8) {
                Spacer()
                Button(
                    language.localized("Deny", "拒绝"),
                    role: .destructive,
                    action: deny
                )
                .accessibilityIdentifier(
                    RemoteGrantManagementAccessibilityIdentifier.denyButton
                )
                Button(
                    RemoteGrantManagementContentPolicy.approvalButtonTitle(
                        scope: scope,
                        language: language
                    ),
                    action: approve
                )
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    scope.grantsPersistentTargetAccess
                        ? RemoteGrantManagementAccessibilityIdentifier.alwaysAllowButton
                        : RemoteGrantManagementAccessibilityIdentifier.allowButton
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            RemoteGrantManagementAccessibilityIdentifier.pendingRequestRow
        )
    }

    private var requestSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(request.clientDisplayIdentity)
                    .font(.body.weight(.semibold))
                    .help(request.clientID)
                    .accessibilityValue(request.clientID)
                Text(content.reasonSummary)
                    .font(.caption.weight(.medium))
                Text(capabilitySummary(scope.capabilities, language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let persistentAccessSummary = content.persistentAccessSummary {
                    Label(
                        persistentAccessSummary,
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let elevationSummary = content.elevationSummary {
                    Label(elevationSummary, systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if scope.requiresExternalDataConsent {
                    Label(
                        language.localized(
                            "This approval explicitly consents to sending the listed target data to this external AI client for processing.",
                            "此次批准明确同意将列出的目标数据发送给此第三方 AI 客户端处理。"
                        ),
                        systemImage: "externaldrive.badge.person.crop"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Text(externalDataSummary(scope.externalDataTypes, language: language))
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var content: RemoteGrantRequestContent {
        RemoteGrantManagementContentPolicy.requestContent(
            reason: request.reason,
            scope: scope,
            language: language
        )
    }
}

private struct ActiveRemoteGrantRow: View {
    let grant: RemoteClientGrant
    let policy: RemoteTargetPermissionPolicy
    let isMCPEnabled: Bool
    let language: AppLanguage
    let revoke: () -> Void

    var body: some View {
        let accessContent = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: effectiveCapabilities,
            lastUsedAt: grant.lastUsedAt,
            policy: policy,
            isMCPEnabled: isMCPEnabled,
            language: language
        )
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(grant.clientDisplayIdentity)
                    .font(.body.weight(.semibold))
                    .help(grant.clientID)
                    .accessibilityValue(grant.clientID)
                Text(capabilitySummary(effectiveCapabilities, language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !disabledCapabilities.isEmpty {
                    Label(
                        language.localized(
                            "Disabled by the current server setting: \(capabilitySummary(disabledCapabilities, language: language))",
                            "当前服务器设置已停用：\(capabilitySummary(disabledCapabilities, language: language))"
                        ),
                        systemImage: "pause.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if grant.externalDataConsentAt != nil {
                        Label(language.localized("External sharing consented", "已同意外部共享"), systemImage: "checkmark.shield")
                    }
                    Label(
                        accessContent.summary,
                        systemImage: accessContent.systemImage
                    )
                    .foregroundStyle(
                        accessContent.isExpired ? Color.orange : Color.secondary
                    )
                    if let elevationSummary = accessContent.elevationSummary {
                        Label(elevationSummary, systemImage: "lock.shield")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(language.localized("Revoke", "撤销"), role: .destructive, action: revoke)
                .accessibilityIdentifier(
                    RemoteGrantManagementAccessibilityIdentifier.revokeButton
                )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            RemoteGrantManagementAccessibilityIdentifier.activeGrantRow
        )
    }

    private var effectiveCapabilities: Set<RemoteCapability> {
        grant.capabilities.intersection(policy.maximumCapabilities)
    }

    private var disabledCapabilities: Set<RemoteCapability> {
        grant.capabilities.subtracting(policy.maximumCapabilities)
    }
}

private struct RemoteCapabilityAuditRow: View {
    let record: RemoteCapabilityAuditRecord
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: resultSymbol)
                .foregroundStyle(resultColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.actionType)
                    .font(.system(.body, design: .monospaced))
                Text(record.capabilityNames.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(
                    "\(record.clientDisplayIdentity) · \(record.resultCode) · \(record.durationMilliseconds) ms"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(record.clientID)
                if let leaseExpiry = record.controlLeaseExpiresAt {
                    Text(
                        language.localized("Lease expires ", "租约到期：")
                            + RemoteGrantTimestampTextPolicy.dateAndTime(
                                leaseExpiry,
                                language: language
                            )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            TimelineView(
                .periodic(
                    from: .now,
                    by: RemoteGrantAuditTimelinePolicy.refreshInterval
                )
            ) { context in
                Text(
                    RemoteGrantTimestampTextPolicy.relative(
                        record.finishedAt,
                        to: context.date,
                        language: language
                    )
                )
            }
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resultSymbol: String {
        switch record.result {
        case .succeeded, .approved: return "checkmark.circle.fill"
        case .denied, .revoked: return "nosign"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var resultColor: Color {
        switch record.result {
        case .succeeded, .approved: return Color.accentColor
        case .denied, .revoked, .failed: return .orange
        }
    }
}

private func capabilitySummary(_ capabilities: Set<RemoteCapability>, language: AppLanguage) -> String {
    capabilities
        .sorted { $0.rawValue < $1.rawValue }
        .map { capability in
            switch capability {
            case .discovery: return language.localized("Discovery", "发现")
            case .desktopObserve: return language.localized("Observe", "查看")
            case .desktopControl: return language.localized("Control", "控制")
            case .commandExecution: return language.localized("Commands", "命令")
            case .fileAccess: return language.localized("Files", "文件")
            case .clipboard: return language.localized("Clipboard (unavailable in 2.0)", "剪贴板（2.0 不可用）")
            case .destructiveOperations: return language.localized("Destructive", "破坏性操作")
            case .elevation: return language.localized("Elevation", "提权")
            case .structuredTasks: return language.localized("Structured Tasks", "结构化任务")
            }
        }
        .joined(separator: " · ")
}

private func externalDataSummary(
    _ dataTypes: Set<RemoteExternalDataType>,
    language: AppLanguage
) -> String {
    let labels = dataTypes.sorted { $0.rawValue < $1.rawValue }.map { dataType in
        switch dataType {
        case .targetMetadata: return language.localized("target metadata", "目标元数据")
        case .commandOutput: return language.localized("command output", "命令输出")
        case .terminalOutput: return language.localized("terminal output", "终端输出")
        case .fileMetadata: return language.localized("file metadata", "文件元数据")
        case .fileContent: return language.localized("file content / downloads", "文件内容 / 下载")
        case .desktopImage: return language.localized("desktop images", "桌面图像")
        case .desktopStructure: return language.localized("desktop controls and text", "桌面控件和文字")
        case .clipboardContent: return language.localized("clipboard content (unavailable in 2.0)", "剪贴板内容（2.0 不可用）")
        }
    }
    return language.localized("External processing: ", "外部处理：") + labels.joined(separator: ", ")
}

#endif
