#if !ENABLE_RDP_2
import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    static let jtsRDPDesktopRequested = Notification.Name("com.lljts.JTSTerminal.disabled.desktop-requested")
    static let jtsRDPGrantApprovalRequested = Notification.Name("com.lljts.JTSTerminal.disabled.grant-approval-requested")
}

nonisolated enum RDPCompanionPolicy: String, CaseIterable, Codable, Sendable {
    case optional
    case required
}

nonisolated enum RDPCertificateTrustMode: String, CaseIterable, Codable, Sendable {
    case systemOrPinned
    case pinnedOnly
}

nonisolated struct RemoteTargetPermissionPolicy: Codable, Equatable, Sendable {
    static let rdpDefault = RemoteTargetPermissionPolicy()
}

nonisolated struct RDPConnectionProfile: Codable, Equatable, Sendable {
    static let defaultWidth = 1_920
    static let defaultHeight = 1_080

    var domain: String
    var desktopWidth: Int
    var desktopHeight: Int
    var certificateTrustMode: RDPCertificateTrustMode
    var pinnedCertificateSHA256: String?
    var clipboardEnabled: Bool
    var companionPolicy: RDPCompanionPolicy
    var persistentMCPControlEnabled: Bool
    var permissionPolicy: RemoteTargetPermissionPolicy

    private enum CodingKeys: String, CodingKey {
        case domain
        case desktopWidth
        case desktopHeight
        case certificateTrustMode
        case pinnedCertificateSHA256
        case clipboardEnabled
        case companionPolicy
        case persistentMCPControlEnabled
        case permissionPolicy
    }

    init(
        domain: String = "",
        desktopWidth: Int = defaultWidth,
        desktopHeight: Int = defaultHeight,
        certificateTrustMode: RDPCertificateTrustMode = .systemOrPinned,
        pinnedCertificateSHA256: String? = nil,
        clipboardEnabled: Bool = false,
        companionPolicy: RDPCompanionPolicy = .optional,
        persistentMCPControlEnabled: Bool = true,
        permissionPolicy: RemoteTargetPermissionPolicy = .rdpDefault
    ) {
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.desktopWidth = min(max(desktopWidth, 640), 7_680)
        self.desktopHeight = min(max(desktopHeight, 480), 4_320)
        self.certificateTrustMode = certificateTrustMode
        self.pinnedCertificateSHA256 = Self.normalizedFingerprint(pinnedCertificateSHA256)
        self.clipboardEnabled = false
        self.companionPolicy = companionPolicy
        self.persistentMCPControlEnabled = persistentMCPControlEnabled
        self.permissionPolicy = permissionPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            domain: try container.decodeIfPresent(String.self, forKey: .domain) ?? "",
            desktopWidth: try container.decodeIfPresent(Int.self, forKey: .desktopWidth) ?? Self.defaultWidth,
            desktopHeight: try container.decodeIfPresent(Int.self, forKey: .desktopHeight) ?? Self.defaultHeight,
            certificateTrustMode: try container.decodeIfPresent(
                RDPCertificateTrustMode.self,
                forKey: .certificateTrustMode
            ) ?? .systemOrPinned,
            pinnedCertificateSHA256: try container.decodeIfPresent(
                String.self,
                forKey: .pinnedCertificateSHA256
            ),
            clipboardEnabled: try container.decodeIfPresent(Bool.self, forKey: .clipboardEnabled) ?? false,
            companionPolicy: try container.decodeIfPresent(
                RDPCompanionPolicy.self,
                forKey: .companionPolicy
            ) ?? .optional,
            persistentMCPControlEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .persistentMCPControlEnabled
            ) ?? true,
            permissionPolicy: try container.decodeIfPresent(
                RemoteTargetPermissionPolicy.self,
                forKey: .permissionPolicy
            ) ?? .rdpDefault
        )
    }

    static func normalizedFingerprint(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .uppercased()
            .filter { $0.isHexDigit }
        return normalized.count == 64 ? normalized : nil
    }

    func validateForConnection() throws {}
}

nonisolated enum RDPConnectionProfileCodec {
    static func encode(_ profile: RDPConnectionProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(profile)
    }

    static func decode(_ data: Data?) -> RDPConnectionProfile {
        guard let data,
              let profile = try? JSONDecoder().decode(RDPConnectionProfile.self, from: data) else {
            return RDPConnectionProfile()
        }
        return profile
    }
}

struct RDPDesktopWorkspacePresentation {
    static let runtimeUnavailable = RDPDesktopWorkspacePresentation()
}

struct RDPDesktopWorkspace: View {
    let session: RemoteSession
    let presentation: RDPDesktopWorkspacePresentation
    let openServerProperties: () -> Void

    var body: some View {
        EmptyView()
    }
}

@MainActor
final class RDPDesktopRuntimeStore: ObservableObject {
    static let shared = RDPDesktopRuntimeStore()

    var runningDesktopSummaries: [String] { [] }

    func presentation(for target: RemoteSession) -> RDPDesktopWorkspacePresentation {
        .runtimeUnavailable
    }

    func stopAllImmediately() {}
}

nonisolated struct RemoteClientGrantRequest: Identifiable, Equatable, Sendable {
    var id: UUID
    var targetID: UUID

    init(id: UUID = UUID(), targetID: UUID = UUID()) {
        self.id = id
        self.targetID = targetID
    }
}

@MainActor
final class RemoteClientGrantStore: ObservableObject {
    static let shared = RemoteClientGrantStore()
    @Published private(set) var pendingRequests: [RemoteClientGrantRequest] = []

    func reloadFromDiskIfChanged() {}
}

@MainActor
final class RemoteCapabilityAuditStore: ObservableObject {
    static let shared = RemoteCapabilityAuditStore()

    func reloadFromDiskIfChanged() {}
}

nonisolated enum RDPKeychainStore {
    static func savePassword(_ secret: String, targetID: UUID) throws {}
    static func readPassword(targetID: UUID) throws -> String? { nil }
    static func deletePassword(targetID: UUID) throws {}
}

struct WindowsMCPToolDispatcher {
    static func guiBridge(client: TerminalMCPBridgeClient) -> WindowsMCPToolDispatcher {
        WindowsMCPToolDispatcher()
    }
}
#endif
