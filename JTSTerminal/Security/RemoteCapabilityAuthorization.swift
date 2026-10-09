#if ENABLE_RDP_2
import CryptoKit
import Foundation

nonisolated struct RemoteTargetPermissionPolicy: Codable, Equatable, Sendable {
    static let defaultControlIdleTimeoutSeconds = 15 * 60
    static let maximumControlIdleTimeoutSeconds = 15 * 60
    static let defaultControlLeaseCapabilities: Set<RemoteCapability> = [
        .desktopControl,
        .commandExecution,
        .clipboard,
        .destructiveOperations,
        .elevation,
        .structuredTasks,
    ]
    static let rdp2ReleaseCapabilities: Set<RemoteCapability> = [
        .discovery,
        .desktopObserve,
        .desktopControl,
        .commandExecution,
        .fileAccess,
        .destructiveOperations,
        .elevation,
        .structuredTasks,
    ]
    static let rdp2PersistentControlCapabilities: Set<RemoteCapability> = [
        .desktopControl,
        .commandExecution,
        .destructiveOperations,
        .elevation,
        .structuredTasks,
    ]

    var maximumCapabilities: Set<RemoteCapability>
    var controlLeaseCapabilities: Set<RemoteCapability>
    var controlIdleTimeoutSeconds: Int
    var requireExternalDataConsent: Bool

    private enum CodingKeys: String, CodingKey {
        case maximumCapabilities
        case controlLeaseCapabilities
        case controlIdleTimeoutSeconds
        case requireExternalDataConsent
    }

    init(
        maximumCapabilities: Set<RemoteCapability>,
        controlLeaseCapabilities: Set<RemoteCapability>? = nil,
        controlIdleTimeoutSeconds: Int = defaultControlIdleTimeoutSeconds,
        requireExternalDataConsent: Bool = true
    ) {
        self.maximumCapabilities = maximumCapabilities
        self.controlLeaseCapabilities = (controlLeaseCapabilities
            ?? Self.defaultControlLeaseCapabilities)
            .intersection(maximumCapabilities)
        self.controlIdleTimeoutSeconds = min(
            max(controlIdleTimeoutSeconds, 60),
            Self.maximumControlIdleTimeoutSeconds
        )
        self.requireExternalDataConsent = requireExternalDataConsent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maximumCapabilities: try container.decodeIfPresent(
                Set<RemoteCapability>.self,
                forKey: .maximumCapabilities
            ) ?? Self.rdpDefault.maximumCapabilities,
            controlLeaseCapabilities: try container.decodeIfPresent(
                Set<RemoteCapability>.self,
                forKey: .controlLeaseCapabilities
            ),
            controlIdleTimeoutSeconds: try container.decodeIfPresent(
                Int.self,
                forKey: .controlIdleTimeoutSeconds
            ) ?? Self.defaultControlIdleTimeoutSeconds,
            requireExternalDataConsent: try container.decodeIfPresent(
                Bool.self,
                forKey: .requireExternalDataConsent
            ) ?? true
        )
    }

    static let rdpDefault = RemoteTargetPermissionPolicy(
        maximumCapabilities: rdp2ReleaseCapabilities,
        controlLeaseCapabilities: []
    )

    static let sshDefault = RemoteTargetPermissionPolicy(
        maximumCapabilities: [
            .discovery,
            .commandExecution,
            .fileAccess,
            .destructiveOperations,
        ],
        controlLeaseCapabilities: []
    )

    static let localShellDefault = RemoteTargetPermissionPolicy(
        maximumCapabilities: [
            .discovery,
            .commandExecution,
        ],
        controlLeaseCapabilities: []
    )

    func requiresControlLease(_ capability: RemoteCapability) -> Bool {
        controlLeaseCapabilities.contains(capability)
    }

    func containsControlLeaseCapability(
        in capabilities: Set<RemoteCapability>
    ) -> Bool {
        !controlLeaseCapabilities.isDisjoint(with: capabilities)
    }
}

nonisolated enum RemoteExternalDataType: String, CaseIterable, Codable, Hashable, Sendable {
    case targetMetadata
    case commandOutput
    case terminalOutput
    case fileMetadata
    case fileContent
    case desktopImage
    case desktopStructure
    case clipboardContent
}

nonisolated enum RemoteExternalDataPolicy {
    /// The complete set of data categories that can be returned by the
    /// configured capabilities. This is used only by the explicit persistent
    /// target-access approval UI, where every category is shown up front.
    static func completeTypes(
        for capabilities: Set<RemoteCapability>
    ) -> Set<RemoteExternalDataType> {
        var types: Set<RemoteExternalDataType> = []
        if capabilities.contains(.discovery) {
            types.insert(.targetMetadata)
        }
        if capabilities.contains(.desktopObserve) {
            types.insert(.desktopImage)
            types.insert(.desktopStructure)
        }
        if capabilities.contains(.commandExecution) {
            types.formUnion([.commandOutput, .terminalOutput])
        }
        if capabilities.contains(.fileAccess) {
            types.formUnion([.fileMetadata, .fileContent])
        }
        if capabilities.contains(.clipboard) {
            types.insert(.clipboardContent)
        }
        return types
    }
}

extension RemoteSession {
    /// Binds a durable grant to one immutable interpretation of a saved
    /// target. The profile UUID alone is not enough because imports and edits
    /// may retain it while changing the actual endpoint.
    var mcpGrantTargetBinding: String {
        let commonFields = [
            "jts-mcp-target-binding-v1",
            targetID.uuidString.lowercased(),
            String(createdAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            connectionType.rawValue,
        ]
        let targetFields: [String]
        switch connectionType {
        case .ssh:
            targetFields = [
                host.trimmingCharacters(in: .whitespacesAndNewlines),
                String(port),
                username.trimmingCharacters(in: .whitespacesAndNewlines),
                jumpHost.trimmingCharacters(in: .whitespacesAndNewlines),
                identityFile.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        case .localShell:
            targetFields = [
                username.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        case .macDesktop:
            targetFields = [host.trimmingCharacters(in: .whitespacesAndNewlines), String(port)]
        case .rdp:
            let profile = rdpProfile
            targetFields = [
                host.trimmingCharacters(in: .whitespacesAndNewlines),
                String(port),
                username.trimmingCharacters(in: .whitespacesAndNewlines),
                profile.domain.trimmingCharacters(in: .whitespacesAndNewlines),
                profile.certificateTrustMode.rawValue,
                profile.pinnedCertificateSHA256 ?? "",
            ]
        }
        return RemoteGrantTargetBinding.digest(fields: commonFields + targetFields)
    }

    var mcpPermissionPolicy: RemoteTargetPermissionPolicy {
        switch connectionType {
        case .ssh: return .sshDefault
        case .localShell: return .localShellDefault
        case .macDesktop: return RemoteTargetPermissionPolicy(maximumCapabilities: [], controlLeaseCapabilities: [])
        case .rdp:
            let profile = rdpProfile
            guard !profile.persistentMCPControlEnabled else {
                return profile.permissionPolicy
            }
            return RemoteTargetPermissionPolicy(
                maximumCapabilities: profile.permissionPolicy.maximumCapabilities
                    .subtracting(RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities),
                controlLeaseCapabilities: [],
                controlIdleTimeoutSeconds: profile.permissionPolicy.controlIdleTimeoutSeconds,
                requireExternalDataConsent: profile.permissionPolicy.requireExternalDataConsent
            )
        }
    }

    /// Windows control is blocked by a saved target setting, not by a request
    /// waiting for approval. Name that one-time switch so the AI client can
    /// tell the user exactly what to change instead of asking again.
    func requirePersistentMCPControl(for capabilities: Set<RemoteCapability>) throws {
        guard connectionType == .rdp, mcpEnabled else { return }
        let profile = rdpProfile
        guard !profile.persistentMCPControlEnabled else { return }
        let blocked = capabilities
            .intersection(RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities)
            .intersection(profile.permissionPolicy.maximumCapabilities)
        guard !blocked.isEmpty else { return }
        let names = blocked.map(\.rawValue).sorted().joined(separator: ", ")
        throw RemoteGrantGateFailure(
            denialCode: RemoteAuthorizationDenialCode.capabilityNotAllowed.rawValue,
            message: "Persistent AI control is turned off for Windows target '\(effectiveMCPAlias)', so \(names) is not allowed. This is a saved setting, not a pending approval. Ask the user to turn on \"Allow registered AI clients persistent control of this target\" in JTS Terminal > Server Properties > AI / MCP Access (服务器属性 > AI / MCP 访问 > 允许已注册 AI 客户端长期控制此目标). No further approval is needed after that until the user revokes this client in AI Access Management."
        )
    }
}

nonisolated private enum RemoteGrantTargetBinding {
    static func digest(fields: [String]) -> String {
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) {
                canonical.append(contentsOf: $0)
            }
            canonical.append(bytes)
        }
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

nonisolated struct RemoteClientGrant: Codable, Equatable, Sendable {
    var grantID: UUID
    var clientID: String
    var clientDisplayIdentity: String
    var targetID: UUID
    var targetBinding: String?
    var capabilities: Set<RemoteCapability>
    var issuedAt: Date
    var lastUsedAt: Date
    var absoluteExpiration: Date?
    var revokedAt: Date?
    /// Most recent explicit external-data consent gesture. Presence alone never
    /// authorizes a data type; `consentedExternalDataTypes` is authoritative.
    var externalDataConsentAt: Date?
    var consentedExternalDataTypes: Set<RemoteExternalDataType>
    var controlRevocationToken: String?

    init(
        grantID: UUID = UUID(),
        clientID: String,
        clientDisplayIdentity: String? = nil,
        targetID: UUID,
        targetBinding: String? = nil,
        capabilities: Set<RemoteCapability>,
        issuedAt: Date = Date(),
        absoluteExpiration: Date? = nil,
        externalDataConsentAt: Date? = nil,
        consentedExternalDataTypes: Set<RemoteExternalDataType> = [],
        controlRevocationToken: String? = nil
    ) {
        self.grantID = grantID
        self.clientID = clientID
        self.clientDisplayIdentity = MCPClientDisplayIdentity.resolved(
            clientDisplayIdentity,
            authorizationID: clientID
        )
        self.targetID = targetID
        self.targetBinding = targetBinding
        self.capabilities = capabilities
        self.issuedAt = issuedAt
        self.lastUsedAt = issuedAt
        self.absoluteExpiration = absoluteExpiration
        self.revokedAt = nil
        self.externalDataConsentAt = externalDataConsentAt
        self.consentedExternalDataTypes = consentedExternalDataTypes
        self.controlRevocationToken = controlRevocationToken
    }

    private enum CodingKeys: String, CodingKey {
        case grantID
        case clientID
        case clientDisplayIdentity
        case targetID
        case targetBinding
        case capabilities
        case issuedAt
        case lastUsedAt
        case absoluteExpiration
        case revokedAt
        case externalDataConsentAt
        case consentedExternalDataTypes
        case controlRevocationToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let clientID = try container.decode(String.self, forKey: .clientID)
        grantID = try container.decode(UUID.self, forKey: .grantID)
        self.clientID = clientID
        clientDisplayIdentity = MCPClientDisplayIdentity.resolved(
            try container.decodeIfPresent(String.self, forKey: .clientDisplayIdentity),
            authorizationID: clientID
        )
        targetID = try container.decode(UUID.self, forKey: .targetID)
        targetBinding = try container.decodeIfPresent(String.self, forKey: .targetBinding)
        capabilities = try container.decode(Set<RemoteCapability>.self, forKey: .capabilities)
        issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        absoluteExpiration = try container.decodeIfPresent(Date.self, forKey: .absoluteExpiration)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
        // Legacy records only carried a timestamp, which did not identify the
        // data types the user actually reviewed. Treat them as unconsented so
        // the next external handoff requires a new, explicit scoped approval.
        let decodedConsentTypes = try container.decodeIfPresent(
            Set<RemoteExternalDataType>.self,
            forKey: .consentedExternalDataTypes
        )
        consentedExternalDataTypes = decodedConsentTypes ?? []
        if decodedConsentTypes == nil {
            externalDataConsentAt = nil
        } else {
            externalDataConsentAt = try container.decodeIfPresent(
                Date.self,
                forKey: .externalDataConsentAt
            )
        }
        controlRevocationToken = try container.decodeIfPresent(
            String.self,
            forKey: .controlRevocationToken
        )
    }

    mutating func revoke(at date: Date = Date()) {
        revokedAt = date
    }
}

nonisolated enum RemoteAuthorizationDenialCode: String, Codable, Equatable, Sendable {
    case grantRevoked = "GRANT_REVOKED"
    case grantExpired = "GRANT_EXPIRED"
    case leaseExpired = "CONTROL_LEASE_EXPIRED"
    case capabilityNotGranted = "CAPABILITY_NOT_GRANTED"
    case capabilityNotAllowed = "CAPABILITY_NOT_ALLOWED"
    case externalDataConsentRequired = "EXTERNAL_DATA_CONSENT_REQUIRED"
}

nonisolated enum RemoteAuthorizationDecision: Equatable, Sendable {
    case allowed
    case denied(code: RemoteAuthorizationDenialCode, message: String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

nonisolated struct RemoteCapabilityGrantPolicy: Sendable {
    static let externalDataCapabilities: Set<RemoteCapability> = [
        .desktopObserve,
        .commandExecution,
        .fileAccess,
        .clipboard,
    ]

    var permissionPolicy: RemoteTargetPermissionPolicy

    func authorize(
        grant: RemoteClientGrant,
        capability: RemoteCapability,
        at date: Date = Date()
    ) -> RemoteAuthorizationDecision {
        if grant.revokedAt != nil {
            return .denied(code: .grantRevoked, message: "The AI client grant was revoked.")
        }
        if let expiration = grant.absoluteExpiration, date >= expiration {
            return .denied(code: .grantExpired, message: "The AI client grant expired.")
        }
        guard permissionPolicy.maximumCapabilities.contains(capability) else {
            return .denied(
                code: .capabilityNotAllowed,
                message: "The target policy does not allow \(capability.rawValue)."
            )
        }
        guard grant.capabilities.contains(capability) else {
            return .denied(
                code: .capabilityNotGranted,
                message: "The AI client grant does not include \(capability.rawValue)."
            )
        }
        if permissionPolicy.requiresControlLease(capability),
           date.timeIntervalSince(grant.lastUsedAt) >= TimeInterval(permissionPolicy.controlIdleTimeoutSeconds) {
            return .denied(
                code: .leaseExpired,
                message: "The AI control lease expired after \(permissionPolicy.controlIdleTimeoutSeconds) seconds of inactivity."
            )
        }
        return .allowed
    }

    func authorizeAndTouch(
        grant: inout RemoteClientGrant,
        capability: RemoteCapability,
        at date: Date = Date()
    ) -> RemoteAuthorizationDecision {
        let decision = authorize(grant: grant, capability: capability, at: date)
        // Observation/discovery must not silently keep a Control lease alive.
        // Only an operation that consumes lease-bound authority renews it.
        if decision.isAllowed, permissionPolicy.requiresControlLease(capability) {
            grant.lastUsedAt = date
        }
        return decision
    }
}

extension RemoteCapability {
    nonisolated var sharesExternalData: Bool {
        RemoteCapabilityGrantPolicy.externalDataCapabilities.contains(self)
    }
}

#endif
