#if ENABLE_RDP_2
import Combine
import Darwin
import Foundation

extension Notification.Name {
    static let jtsRDPGrantApprovalRequested = Notification.Name("com.lljts.JTSTerminal.rdp.grant-approval-requested")
}

nonisolated enum RemoteGrantRequestReason: String, Codable, Equatable, Sendable {
    case newGrant
    case capabilityExpansion
    case externalDataConsent
    case controlLeaseRenewal
}

nonisolated struct RemoteGrantRequest: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var clientID: String
    var clientDisplayIdentity: String
    var targetID: UUID
    var targetBinding: String?
    var requestedCapabilities: Set<RemoteCapability>
    var externalDataTypes: Set<RemoteExternalDataType>
    var reason: RemoteGrantRequestReason
    var firstRequestedAt: Date
    var lastRequestedAt: Date

    var requiresExternalDataConsent: Bool {
        !externalDataTypes.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case clientID
        case clientDisplayIdentity
        case targetID
        case targetBinding
        case requestedCapabilities
        case externalDataTypes
        case reason
        case firstRequestedAt
        case lastRequestedAt
    }

    init(
        id: UUID,
        clientID: String,
        clientDisplayIdentity: String? = nil,
        targetID: UUID,
        targetBinding: String? = nil,
        requestedCapabilities: Set<RemoteCapability>,
        externalDataTypes: Set<RemoteExternalDataType> = [],
        reason: RemoteGrantRequestReason,
        firstRequestedAt: Date,
        lastRequestedAt: Date
    ) {
        self.id = id
        self.clientID = clientID
        self.clientDisplayIdentity = MCPClientDisplayIdentity.resolved(
            clientDisplayIdentity,
            authorizationID: clientID
        )
        self.targetID = targetID
        self.targetBinding = targetBinding
        self.requestedCapabilities = requestedCapabilities
        self.externalDataTypes = externalDataTypes
        self.reason = reason
        self.firstRequestedAt = firstRequestedAt
        self.lastRequestedAt = lastRequestedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capabilities = try container.decode(Set<RemoteCapability>.self, forKey: .requestedCapabilities)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            clientID: try container.decode(String.self, forKey: .clientID),
            clientDisplayIdentity: try container.decodeIfPresent(
                String.self,
                forKey: .clientDisplayIdentity
            ),
            targetID: try container.decode(UUID.self, forKey: .targetID),
            targetBinding: try container.decodeIfPresent(String.self, forKey: .targetBinding),
            requestedCapabilities: capabilities,
            externalDataTypes: try container.decodeIfPresent(Set<RemoteExternalDataType>.self, forKey: .externalDataTypes)
                ?? Self.inferredExternalDataTypes(for: capabilities),
            reason: try container.decode(RemoteGrantRequestReason.self, forKey: .reason),
            firstRequestedAt: try container.decode(Date.self, forKey: .firstRequestedAt),
            lastRequestedAt: try container.decode(Date.self, forKey: .lastRequestedAt)
        )
    }

    private static func inferredExternalDataTypes(
        for capabilities: Set<RemoteCapability>
    ) -> Set<RemoteExternalDataType> {
        var types: Set<RemoteExternalDataType> = []
        if capabilities.contains(.desktopObserve) { types.insert(.desktopImage) }
        if capabilities.contains(.commandExecution) { types.insert(.commandOutput) }
        if capabilities.contains(.fileAccess) { types.formUnion([.fileMetadata, .fileContent]) }
        if capabilities.contains(.clipboard) { types.insert(.clipboardContent) }
        return types
    }
}

nonisolated struct RemoteGrantAuthorization: Equatable, Sendable {
    var grantID: UUID
    var clientID: String
    var clientDisplayIdentity: String
    var targetID: UUID
    var targetBinding: String?
    var capabilities: Set<RemoteCapability>
    var controlLeaseExpiresAt: Date?
    var controlRevocationToken: String?
}

nonisolated struct RemoteGrantGateFailure: LocalizedError, Equatable, Sendable {
    var denialCode: String
    var message: String
    var pendingRequestID: UUID?

    var errorDescription: String? { "\(denialCode): \(message)" }
}

@MainActor
final class RemoteClientGrantStore: ObservableObject {
    static let shared = RemoteClientGrantStore()
    private static let maximumPersistedStateBytes = 16 * 1_024 * 1_024
    private static let exclusiveLockTimeout: TimeInterval = 0.1
    private static let exclusiveLockRetryMicroseconds: useconds_t = 5_000

    @Published private(set) var grants: [RemoteClientGrant]
    @Published private(set) var pendingRequests: [RemoteGrantRequest]
    @Published private(set) var persistenceError: String?

    private struct PersistedState: Codable {
        var formatVersion = 1
        var grants: [RemoteClientGrant]
        var pendingRequests: [RemoteGrantRequest]

        static var empty: PersistedState {
            PersistedState(grants: [], pendingRequests: [])
        }
    }

    private struct PersistedSnapshot {
        var state: PersistedState
        var storageStamp: String?
    }

    private struct GrantStorePersistenceFailure: LocalizedError {
        var message: String
        var underlyingError: Error?

        var errorDescription: String? {
            guard let underlyingError else { return message }
            return "\(message) \(underlyingError.localizedDescription)"
        }
    }

    private enum AuthorizationOutcome {
        case authorized(RemoteGrantAuthorization)
        case denied(RemoteGrantGateFailure, pendingRequest: RemoteGrantRequest?)
    }

    private struct AuthorizationTransaction {
        var outcome: AuthorizationOutcome
        var didChangeState: Bool
    }

    private struct PendingRequestUpsert {
        var request: RemoteGrantRequest
        var didChangeState: Bool
    }

    private enum ApprovalOutcome {
        case approved(RemoteClientGrant)
        case denied(RemoteGrantGateFailure)
    }

    private let storageURL: URL
    private let lockURL: URL
    private let controlRevocationDirectoryURL: URL
    private let controlRevocationFailureForTesting: (() -> Error?)?
    private var lastLoadedStorageStamp: String?
    private var requiresReload: Bool
    private var pendingLocalControlRevocationTokensByTargetID: [UUID: String]

    init(
        storageURL: URL? = nil,
        controlRevocationFailureForTesting: (() -> Error?)? = nil
    ) {
        let resolvedStorageURL = storageURL ?? Self.defaultStorageURL()
        self.storageURL = resolvedStorageURL
        self.lockURL = resolvedStorageURL.appendingPathExtension("lock")
        self.controlRevocationDirectoryURL = resolvedStorageURL
            .deletingLastPathComponent()
            .appendingPathComponent("ControlRevocations", isDirectory: true)
        self.controlRevocationFailureForTesting = controlRevocationFailureForTesting
        self.grants = []
        self.pendingRequests = []
        self.persistenceError = nil
        self.lastLoadedStorageStamp = nil
        self.requiresReload = true
        self.pendingLocalControlRevocationTokensByTargetID = [:]

        do {
            applyPersistedState(try loadLatestSnapshot())
        } catch {
            invalidateSnapshot(for: error)
        }
    }

    var activeGrants: [RemoteClientGrant] {
        grants
            .filter { $0.revokedAt == nil && ($0.absoluteExpiration == nil || $0.absoluteExpiration! > Date()) }
            .sorted { lhs, rhs in
                if lhs.clientID == rhs.clientID { return lhs.issuedAt > rhs.issuedAt }
                return lhs.clientID.localizedStandardCompare(rhs.clientID) == .orderedAscending
            }
    }

    func activeGrants(
        targetID: UUID,
        targetBinding: String? = nil,
        at date: Date = Date()
    ) -> [RemoteClientGrant] {
        grants
            .filter {
                $0.targetID == targetID &&
                    (targetBinding == nil || $0.targetBinding == targetBinding) &&
                    $0.revokedAt == nil &&
                    ($0.absoluteExpiration == nil || $0.absoluteExpiration! > date)
            }
            .sorted { $0.clientID.localizedStandardCompare($1.clientID) == .orderedAscending }
    }

    func pendingRequests(
        targetID: UUID,
        targetBinding: String? = nil
    ) -> [RemoteGrantRequest] {
        pendingRequests
            .filter {
                $0.targetID == targetID &&
                    (targetBinding == nil || $0.targetBinding == targetBinding)
            }
            .sorted { $0.firstRequestedAt < $1.firstRequestedAt }
    }

    /// True when this client previously had access to the exact target and the
    /// user later revoked it, so implicit MCP-enabled access must not revive.
    func hasBlockingRevocation(
        clientID rawClientID: String,
        targetID: UUID,
        targetBinding rawTargetBinding: String? = nil,
        at date: Date = Date()
    ) -> Bool {
        let clientID: String
        let targetBinding: String?
        do {
            clientID = try normalizedClientID(rawClientID)
            targetBinding = try normalizedTargetBinding(rawTargetBinding)
        } catch {
            return true
        }
        return hasBlockingRevocationLocked(
            grants: grants,
            clientID: clientID,
            targetID: targetID,
            targetBinding: targetBinding,
            at: date
        )
    }

    /// Removes durable requests that are either no longer allowed by the
    /// target policy or already completely covered by a current non-leased
    /// grant. Legacy lease renewals are normalized when a target moves to
    /// persistent authorization.
    @discardableResult
    func reconcileResolvedPendingRequests(
        targetID: UUID,
        policy: RemoteTargetPermissionPolicy,
        targetBinding rawTargetBinding: String? = nil,
        at date: Date = Date()
    ) throws -> Bool {
        let targetBinding = try normalizedTargetBinding(rawTargetBinding)
        let transaction: (PersistedSnapshot, Bool)
        do {
            transaction = try withExclusiveLock {
                var state = try readLatestLocked()
                var didChangeState = removePolicyObsoletePendingRequests(
                    state: &state,
                    targetID: targetID,
                    policy: policy
                )
                didChangeState = normalizeLegacyLeaseState(
                    state: &state,
                    targetID: targetID,
                    policy: policy,
                    targetBinding: targetBinding,
                    at: date
                ) || didChangeState
                for grant in state.grants where
                    grant.targetID == targetID &&
                        (targetBinding == nil || grant.targetBinding == targetBinding) &&
                        grant.revokedAt == nil &&
                        (grant.absoluteExpiration == nil || grant.absoluteExpiration! > date) {
                    didChangeState = removeResolvedPendingRequests(
                        state: &state,
                        grant: grant,
                        policy: policy
                    ) || didChangeState
                }
                if didChangeState {
                    try persistLocked(state)
                }
                return (snapshotLocked(state), didChangeState)
            }
        } catch {
            invalidateSnapshot(for: error)
            throw error
        }

        applyPersistedState(transaction.0)
        return transaction.1
    }

    /// Fail-closed authorization entry point used by the RDP MCP adapter.
    ///
    /// Enabling MCP on a profile is the user's access decision. When
    /// `implicitProfileAccess` is true and the client has never been revoked
    /// for this exact target, the first real use silently records a persistent
    /// grant instead of creating a pending Always Allow request. Discovery
    /// callers must not use this path. A later explicit revocation still
    /// blocks the same client until the user approves it again.
    func authorize(
        clientID rawClientID: String,
        clientDisplayIdentity rawClientDisplayIdentity: String? = nil,
        targetID: UUID,
        targetBinding rawTargetBinding: String? = nil,
        capabilities requestedCapabilities: Set<RemoteCapability>,
        policy permissionPolicy: RemoteTargetPermissionPolicy,
        externalDataTypes requestedExternalDataTypes: Set<RemoteExternalDataType>? = nil,
        implicitProfileAccess: Bool = false,
        at date: Date = Date()
    ) throws -> RemoteGrantAuthorization {
        let clientID = try normalizedClientID(rawClientID)
        let targetBinding = try normalizedTargetBinding(rawTargetBinding)
        let providedDisplayIdentity = MCPClientDisplayIdentity.sanitized(rawClientDisplayIdentity)
        let externalDataTypes = requestedExternalDataTypes
            ?? inferredExternalDataTypes(for: requestedCapabilities)
        guard !requestedCapabilities.isEmpty else {
            throw RemoteGrantGateFailure(
                denialCode: "EMPTY_CAPABILITY_REQUEST",
                message: "The MCP operation did not declare a required capability."
            )
        }

        if let disallowed = requestedCapabilities.first(where: { !permissionPolicy.maximumCapabilities.contains($0) }) {
            throw RemoteGrantGateFailure(
                denialCode: RemoteAuthorizationDenialCode.capabilityNotAllowed.rawValue,
                message: "The target policy does not allow \(disallowed.rawValue)."
            )
        }

        let transaction: (PersistedSnapshot, AuthorizationTransaction)
        do {
            transaction = try withExclusiveLock {
                var state = try readLatestLocked()
                let currentControlRevocationToken: String?
                if permissionPolicy.containsControlLeaseCapability(in: requestedCapabilities) {
                    currentControlRevocationToken = try effectiveControlRevocationToken(
                        targetID: targetID
                    )
                } else {
                    currentControlRevocationToken = nil
                }
                let didNormalizeLegacyLeaseState = normalizeLegacyLeaseState(
                    state: &state,
                    targetID: targetID,
                    policy: permissionPolicy,
                    targetBinding: targetBinding,
                    at: date
                )
                let authorization = authorizeLocked(
                    state: &state,
                    clientID: clientID,
                    clientDisplayIdentity: providedDisplayIdentity,
                    targetID: targetID,
                    targetBinding: targetBinding,
                    requestedCapabilities: requestedCapabilities,
                    externalDataTypes: externalDataTypes,
                    permissionPolicy: permissionPolicy,
                    currentControlRevocationToken: currentControlRevocationToken,
                    implicitProfileAccess: implicitProfileAccess,
                    at: date
                )
                let result = AuthorizationTransaction(
                    outcome: authorization.outcome,
                    didChangeState: authorization.didChangeState ||
                        didNormalizeLegacyLeaseState
                )
                if result.didChangeState {
                    try persistLocked(state)
                }
                return (snapshotLocked(state), result)
            }
        } catch {
            invalidateSnapshot(for: error)
            throw RemoteGrantGateFailure(
                denialCode: "GRANT_STORE_UNAVAILABLE",
                message: "The AI authorization store could not be verified. Access remains fail-closed."
            )
        }

        applyPersistedState(transaction.0)
        switch transaction.1.outcome {
        case let .authorized(authorization):
            return authorization
        case let .denied(failure, pendingRequest):
            if let pendingRequest {
                postApprovalRequestNotification(pendingRequest)
            }
            throw failure
        }
    }

    /// Approval is also the explicit first-share consent gesture. The caller
    /// must pass `consentToExternalData=true` for a request that can expose
    /// screenshots, command output, or files.
    @discardableResult
    func approve(
        requestID: UUID,
        policy: RemoteTargetPermissionPolicy,
        consentToExternalData: Bool,
        grantPersistentTargetAccess: Bool = false,
        currentTargetBinding rawCurrentTargetBinding: String? = nil,
        at date: Date = Date()
    ) throws -> RemoteClientGrant {
        let currentTargetBinding = try normalizedTargetBinding(rawCurrentTargetBinding)
        let transaction: (PersistedSnapshot, ApprovalOutcome)
        do {
            transaction = try withExclusiveLock {
                var state = try readLatestLocked()
                guard let requestIndex = state.pendingRequests.firstIndex(where: { $0.id == requestID }) else {
                    return (
                        snapshotLocked(state),
                        .denied(RemoteGrantGateFailure(
                            denialCode: "GRANT_REQUEST_NOT_FOUND",
                            message: "The AI access request no longer exists."
                        ))
                    )
                }
                let request = state.pendingRequests[requestIndex]
                guard request.targetBinding == currentTargetBinding else {
                    state.pendingRequests.remove(at: requestIndex)
                    try persistLocked(state)
                    return (
                        snapshotLocked(state),
                        .denied(RemoteGrantGateFailure(
                            denialCode: "TARGET_BINDING_CHANGED",
                            message: "The saved target changed after this request was created. Retry the MCP action and review a new approval for the current endpoint."
                        ))
                    )
                }
                if grantPersistentTargetAccess,
                   policy.containsControlLeaseCapability(in: policy.maximumCapabilities) {
                    return (
                        snapshotLocked(state),
                        .denied(RemoteGrantGateFailure(
                            denialCode: RemoteAuthorizationDenialCode.capabilityNotAllowed.rawValue,
                            message: "Persistent target access cannot include temporary control or privileged capabilities."
                        ))
                    )
                }
                let approvedCapabilities = grantPersistentTargetAccess
                    ? policy.maximumCapabilities
                    : request.requestedCapabilities
                let approvedExternalDataTypes = grantPersistentTargetAccess
                    ? RemoteExternalDataPolicy.completeTypes(for: approvedCapabilities)
                    : request.externalDataTypes
                guard request.requestedCapabilities.isSubset(of: policy.maximumCapabilities) else {
                    return (
                        snapshotLocked(state),
                        .denied(RemoteGrantGateFailure(
                            denialCode: RemoteAuthorizationDenialCode.capabilityNotAllowed.rawValue,
                            message: "One or more requested capabilities are disabled by the target policy."
                        ))
                    )
                }
                if policy.requireExternalDataConsent,
                   !approvedExternalDataTypes.isEmpty,
                   !consentToExternalData {
                    return (
                        snapshotLocked(state),
                        .denied(RemoteGrantGateFailure(
                            denialCode: RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue,
                            message: "Explicit external-data consent is required for this request."
                        ))
                    )
                }

                var grant: RemoteClientGrant
                if let grantIndex = state.grants.lastIndex(where: {
                    $0.clientID == request.clientID &&
                        $0.targetID == request.targetID &&
                        $0.targetBinding == request.targetBinding &&
                        $0.revokedAt == nil &&
                        ($0.absoluteExpiration == nil || $0.absoluteExpiration! > date)
                }) {
                    var updated = state.grants[grantIndex]
                    updated.clientDisplayIdentity = request.clientDisplayIdentity
                    updated.capabilities.formUnion(approvedCapabilities)
                    if policy.containsControlLeaseCapability(in: approvedCapabilities) {
                        updated.lastUsedAt = date
                    }
                    if consentToExternalData, !approvedExternalDataTypes.isEmpty {
                        updated.externalDataConsentAt = date
                        updated.consentedExternalDataTypes.formUnion(approvedExternalDataTypes)
                    }
                    if policy.controlLeaseCapabilities.isEmpty {
                        updated.controlRevocationToken = nil
                    }
                    state.grants[grantIndex] = updated
                    grant = updated
                } else {
                    let created = RemoteClientGrant(
                        clientID: request.clientID,
                        clientDisplayIdentity: request.clientDisplayIdentity,
                        targetID: request.targetID,
                        targetBinding: request.targetBinding,
                        capabilities: approvedCapabilities,
                        issuedAt: date,
                        externalDataConsentAt: consentToExternalData && !approvedExternalDataTypes.isEmpty
                            ? date
                            : nil,
                        consentedExternalDataTypes: consentToExternalData
                            ? approvedExternalDataTypes
                            : []
                    )
                    state.grants.append(created)
                    grant = created
                }
                state.pendingRequests.remove(at: requestIndex)
                if policy.containsControlLeaseCapability(in: approvedCapabilities) {
                    let token = try effectiveControlRevocationToken(
                        targetID: request.targetID
                    )
                    if let grantIndex = state.grants.lastIndex(where: {
                        $0.grantID == grant.grantID
                    }) {
                        state.grants[grantIndex].controlRevocationToken = token
                        grant = state.grants[grantIndex]
                    }
                }
                try persistLocked(state)
                return (snapshotLocked(state), .approved(grant))
            }
        } catch {
            invalidateSnapshot(for: error)
            throw error
        }

        applyPersistedState(transaction.0)
        switch transaction.1 {
        case let .approved(grant):
            return grant
        case let .denied(failure):
            throw failure
        }
    }

    func deny(requestID: UUID) throws {
        do {
            let state = try withExclusiveLock {
                var state = try readLatestLocked()
                let previousCount = state.pendingRequests.count
                state.pendingRequests.removeAll { $0.id == requestID }
                if state.pendingRequests.count != previousCount {
                    try persistLocked(state)
                }
                return snapshotLocked(state)
            }
            applyPersistedState(state)
        } catch {
            invalidateSnapshot(for: error)
            throw error
        }
    }

    func revoke(grantID: UUID, at date: Date = Date()) throws {
        do {
            let state = try withExclusiveLock {
                var state = try readLatestLocked()
                guard let index = state.grants.firstIndex(where: { $0.grantID == grantID }) else {
                    return snapshotLocked(state)
                }
                state.grants[index].revoke(at: date)
                let revokedGrant = state.grants[index]
                state.pendingRequests.removeAll {
                    $0.clientID == revokedGrant.clientID &&
                        $0.targetID == revokedGrant.targetID
                }
                try persistLocked(state)
                return snapshotLocked(state)
            }
            applyPersistedState(state)
        } catch {
            invalidateSnapshot(for: error)
            throw error
        }
    }

    /// Legacy compatibility hook for persisted policies that still contain a
    /// control lease. Shipping SSH, Local Shell, and RDP policies are
    /// persistent and do not call this path.
    func invalidateControlAuthority(targetID: UUID, clientID: String? = nil) throws {
        let revocationToken = UUID().uuidString.lowercased()
        var markerFailure: Error?
        // The marker is an independent cross-process fail-closed latch. It is
        // created before touching the grant file so a broken or contended
        // primary lock cannot let an old control lease revive after repair.
        do {
            try markControlAuthorityRevoked(
                targetID: targetID,
                token: revocationToken
            )
            pendingLocalControlRevocationTokensByTargetID.removeValue(forKey: targetID)
        } catch {
            pendingLocalControlRevocationTokensByTargetID[targetID] = revocationToken
            markerFailure = error
        }

        var grantFailure: Error?
        do {
            let state = try withExclusiveLock {
                var state = try readLatestLocked()
                var changed = false
                for index in state.grants.indices {
                    guard state.grants[index].targetID == targetID,
                          state.grants[index].revokedAt == nil,
                          clientID.map({ state.grants[index].clientID == $0 }) ?? true,
                          !state.grants[index].capabilities.isDisjoint(
                              with: RemoteTargetPermissionPolicy.defaultControlLeaseCapabilities
                          ),
                          state.grants[index].lastUsedAt != .distantPast else {
                        continue
                    }
                    state.grants[index].lastUsedAt = .distantPast
                    changed = true
                }
                if changed {
                    try persistLocked(state)
                }
                return snapshotLocked(state)
            }
            applyPersistedState(state)
        } catch {
            grantFailure = error
        }

        if let failure = markerFailure ?? grantFailure {
            invalidateSnapshot(for: failure)
            throw failure
        }
    }

    func controlLeaseExpiry(
        clientID rawClientID: String,
        targetID: UUID,
        policy: RemoteTargetPermissionPolicy,
        at date: Date = Date()
    ) -> Date? {
        reloadFromDiskIfChanged()
        guard let clientID = try? normalizedClientID(rawClientID),
              let grant = grants.last(where: {
                  $0.clientID == clientID && $0.targetID == targetID && $0.revokedAt == nil
              }),
              policy.containsControlLeaseCapability(in: grant.capabilities) else {
            return nil
        }
        do {
            guard try effectiveControlRevocationToken(targetID: targetID)
                    == grant.controlRevocationToken else {
                return nil
            }
        } catch {
            invalidateSnapshot(for: error)
            return nil
        }
        let expiry = grant.lastUsedAt.addingTimeInterval(TimeInterval(policy.controlIdleTimeoutSeconds))
        return expiry > date ? expiry : nil
    }

    /// The MCP stdio server and visible GUI are separate app processes. Reload
    /// before authorization and on a lightweight UI timer so approvals and
    /// pending requests cross that process boundary without another port or
    /// background agent.
    func reloadFromDiskIfChanged(
        postApprovalRequestNotifications: Bool = true,
        force: Bool = false
    ) {
        let currentStamp = Self.storageStamp(for: storageURL)
        guard force
                || requiresReload
                || currentStamp != lastLoadedStorageStamp else {
            return
        }
        let existingRequestIDs = Set(pendingRequests.map(\.id))
        let wasRemoved = !requiresReload &&
            lastLoadedStorageStamp != nil &&
            currentStamp == nil
        do {
            let snapshot = try loadLatestSnapshot()
            applyPersistedState(snapshot)
            if wasRemoved {
                persistenceError = "The persisted AI grant file was removed. All AI authority was invalidated."
            }
            if postApprovalRequestNotifications {
                for request in snapshot.state.pendingRequests where !existingRequestIDs.contains(request.id) {
                    postApprovalRequestNotification(request)
                }
            }
        } catch {
            invalidateSnapshot(for: error)
        }
    }

    private func authorizeLocked(
        state: inout PersistedState,
        clientID: String,
        clientDisplayIdentity: String?,
        targetID: UUID,
        targetBinding: String?,
        requestedCapabilities: Set<RemoteCapability>,
        externalDataTypes: Set<RemoteExternalDataType>,
        permissionPolicy: RemoteTargetPermissionPolicy,
        currentControlRevocationToken: String?,
        implicitProfileAccess: Bool,
        at date: Date
    ) -> AuthorizationTransaction {
        let didIssueImplicitProfileGrant = issueImplicitProfileGrantIfEligible(
            state: &state,
            clientID: clientID,
            clientDisplayIdentity: clientDisplayIdentity,
            targetID: targetID,
            targetBinding: targetBinding,
            permissionPolicy: permissionPolicy,
            currentControlRevocationToken: currentControlRevocationToken,
            implicitProfileAccess: implicitProfileAccess,
            at: date
        )
        let didMigrateLegacyPersistentGrant = migrateLegacyPersistentGrantBindingIfEligible(
            state: &state,
            clientID: clientID,
            targetID: targetID,
            targetBinding: targetBinding,
            requestedCapabilities: requestedCapabilities,
            externalDataTypes: externalDataTypes,
            permissionPolicy: permissionPolicy
        )
        guard let grantIndex = state.grants.lastIndex(where: {
            $0.clientID == clientID &&
                $0.targetID == targetID &&
                $0.targetBinding == targetBinding &&
                $0.revokedAt == nil &&
                ($0.absoluteExpiration == nil || $0.absoluteExpiration! > date)
        }) else {
            let upsert = upsertPendingRequest(
                state: &state,
                clientID: clientID,
                clientDisplayIdentity: clientDisplayIdentity,
                targetID: targetID,
                targetBinding: targetBinding,
                capabilities: requestedCapabilities,
                externalDataTypes: externalDataTypes,
                reason: .newGrant,
                at: date
            )
            let request = upsert.request
            return AuthorizationTransaction(
                outcome: .denied(
                    approvalRequired(request),
                    pendingRequest: upsert.didChangeState ? request : nil
                ),
                didChangeState: upsert.didChangeState
            )
        }

        var grant = state.grants[grantIndex]
        let didNormalizeLegacyControlState =
            permissionPolicy.controlLeaseCapabilities.isEmpty &&
            grant.controlRevocationToken != nil
        if didNormalizeLegacyControlState {
            grant.controlRevocationToken = nil
        }
        let unconsentedExternalDataTypes = externalDataTypes.subtracting(
            grant.consentedExternalDataTypes
        )
        let missing = requestedCapabilities.subtracting(grant.capabilities)
        if !missing.isEmpty {
            let upsert = upsertPendingRequest(
                state: &state,
                clientID: clientID,
                clientDisplayIdentity: clientDisplayIdentity,
                targetID: targetID,
                targetBinding: targetBinding,
                capabilities: missing,
                externalDataTypes: unconsentedExternalDataTypes,
                reason: .capabilityExpansion,
                at: date
            )
            let request = upsert.request
            return AuthorizationTransaction(
                outcome: .denied(
                    approvalRequired(request),
                    pendingRequest: upsert.didChangeState ? request : nil
                ),
                didChangeState: upsert.didChangeState
            )
        }

        if grant.controlRevocationToken != currentControlRevocationToken,
           permissionPolicy.containsControlLeaseCapability(in: requestedCapabilities) {
            let upsert = upsertPendingRequest(
                state: &state,
                clientID: clientID,
                clientDisplayIdentity: clientDisplayIdentity,
                targetID: targetID,
                targetBinding: targetBinding,
                capabilities: requestedCapabilities,
                externalDataTypes: unconsentedExternalDataTypes,
                reason: .controlLeaseRenewal,
                at: date
            )
            let request = upsert.request
            return AuthorizationTransaction(
                outcome: .denied(
                    RemoteGrantGateFailure(
                        denialCode: RemoteAuthorizationDenialCode.leaseExpired.rawValue,
                        message: "Manual takeover or Emergency Stop ended this AI control lease. Visible approval is required before control can resume.",
                        pendingRequestID: request.id
                    ),
                    pendingRequest: upsert.didChangeState ? request : nil
                ),
                didChangeState: upsert.didChangeState
            )
        }

        if permissionPolicy.requireExternalDataConsent,
           !unconsentedExternalDataTypes.isEmpty {
            let upsert = upsertPendingRequest(
                state: &state,
                clientID: clientID,
                clientDisplayIdentity: clientDisplayIdentity,
                targetID: targetID,
                targetBinding: targetBinding,
                capabilities: requestedCapabilities,
                externalDataTypes: unconsentedExternalDataTypes,
                reason: .externalDataConsent,
                at: date
            )
            let request = upsert.request
            return AuthorizationTransaction(
                outcome: .denied(
                    RemoteGrantGateFailure(
                        denialCode: RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue,
                        message: "Explicit consent is required before sharing screenshots, terminal output, or files with this external AI client.",
                        pendingRequestID: request.id
                    ),
                    pendingRequest: upsert.didChangeState ? request : nil
                ),
                didChangeState: upsert.didChangeState
            )
        }

        let grantPolicy = RemoteCapabilityGrantPolicy(permissionPolicy: permissionPolicy)
        for capability in requestedCapabilities {
            if case let .denied(code, message) = grantPolicy.authorize(
                grant: grant,
                capability: capability,
                at: date
            ) {
                if code == .leaseExpired {
                    let upsert = upsertPendingRequest(
                        state: &state,
                        clientID: clientID,
                        clientDisplayIdentity: clientDisplayIdentity,
                        targetID: targetID,
                        targetBinding: targetBinding,
                        capabilities: requestedCapabilities.filter {
                            permissionPolicy.requiresControlLease($0)
                        },
                        externalDataTypes: unconsentedExternalDataTypes,
                        reason: .controlLeaseRenewal,
                        at: date
                    )
                    let request = upsert.request
                    return AuthorizationTransaction(
                        outcome: .denied(
                            RemoteGrantGateFailure(
                                denialCode: code.rawValue,
                                message: message,
                                pendingRequestID: request.id
                            ),
                            pendingRequest: upsert.didChangeState ? request : nil
                        ),
                        didChangeState: upsert.didChangeState
                    )
                }
                return AuthorizationTransaction(
                    outcome: .denied(
                        RemoteGrantGateFailure(
                            denialCode: code.rawValue,
                            message: message
                        ),
                        pendingRequest: nil
                    ),
                    didChangeState: false
                )
            }
        }

        let didRemovePolicyObsoleteRequests = removePolicyObsoletePendingRequests(
            state: &state,
            targetID: targetID,
            policy: permissionPolicy
        )
        let didResolvePendingRequests = removeResolvedPendingRequests(
            state: &state,
            grant: grant,
            policy: permissionPolicy
        )
        let resolvedDisplayIdentity = clientDisplayIdentity ?? grant.clientDisplayIdentity
        let consumesControlLease = permissionPolicy.containsControlLeaseCapability(
            in: requestedCapabilities
        )
        let didChangeState = didRemovePolicyObsoleteRequests ||
            didResolvePendingRequests ||
            didIssueImplicitProfileGrant ||
            didMigrateLegacyPersistentGrant ||
            didNormalizeLegacyControlState ||
            consumesControlLease ||
            grant.clientDisplayIdentity != resolvedDisplayIdentity
        if didChangeState {
            if consumesControlLease {
                grant.lastUsedAt = date
            }
            grant.clientDisplayIdentity = resolvedDisplayIdentity
            state.grants[grantIndex] = grant
        }

        let leaseExpiresAt = consumesControlLease
            ? date.addingTimeInterval(TimeInterval(permissionPolicy.controlIdleTimeoutSeconds))
            : nil
        return AuthorizationTransaction(
            outcome: .authorized(RemoteGrantAuthorization(
                grantID: grant.grantID,
                clientID: clientID,
                clientDisplayIdentity: resolvedDisplayIdentity,
                targetID: targetID,
                targetBinding: targetBinding,
                capabilities: requestedCapabilities,
                controlLeaseExpiresAt: leaseExpiresAt,
                controlRevocationToken: grant.controlRevocationToken
            )),
            didChangeState: didChangeState
        )
    }

    private func issueImplicitProfileGrantIfEligible(
        state: inout PersistedState,
        clientID: String,
        clientDisplayIdentity: String?,
        targetID: UUID,
        targetBinding: String?,
        permissionPolicy: RemoteTargetPermissionPolicy,
        currentControlRevocationToken: String?,
        implicitProfileAccess: Bool,
        at date: Date
    ) -> Bool {
        guard implicitProfileAccess else { return false }
        guard !hasBlockingRevocationLocked(
            grants: state.grants,
            clientID: clientID,
            targetID: targetID,
            targetBinding: targetBinding,
            at: date
        ) else {
            return false
        }

        let grantedCapabilities = permissionPolicy.maximumCapabilities
        guard !grantedCapabilities.isEmpty else { return false }
        let consentedTypes = RemoteExternalDataPolicy.completeTypes(
            for: grantedCapabilities
        )
        let usesControlLease = permissionPolicy.containsControlLeaseCapability(
            in: grantedCapabilities
        )

        if let grantIndex = state.grants.lastIndex(where: {
            $0.clientID == clientID &&
                $0.targetID == targetID &&
                $0.targetBinding == targetBinding &&
                $0.revokedAt == nil &&
                ($0.absoluteExpiration == nil || $0.absoluteExpiration! > date)
        }) {
            var grant = state.grants[grantIndex]
            let previous = grant
            grant.capabilities.formUnion(grantedCapabilities)
            if !consentedTypes.isEmpty {
                grant.consentedExternalDataTypes.formUnion(consentedTypes)
                if grant.externalDataConsentAt == nil {
                    grant.externalDataConsentAt = date
                }
            }
            if let clientDisplayIdentity {
                grant.clientDisplayIdentity = clientDisplayIdentity
            }
            if usesControlLease, grant.controlRevocationToken == nil {
                grant.controlRevocationToken = currentControlRevocationToken
            }
            guard grant != previous else { return false }
            state.grants[grantIndex] = grant
        } else {
            state.grants.append(
                RemoteClientGrant(
                    clientID: clientID,
                    clientDisplayIdentity: clientDisplayIdentity,
                    targetID: targetID,
                    targetBinding: targetBinding,
                    capabilities: grantedCapabilities,
                    issuedAt: date,
                    externalDataConsentAt: consentedTypes.isEmpty ? nil : date,
                    consentedExternalDataTypes: consentedTypes,
                    controlRevocationToken: usesControlLease
                        ? currentControlRevocationToken
                        : nil
                )
            )
        }
        state.pendingRequests.removeAll {
            $0.clientID == clientID &&
                $0.targetID == targetID &&
                (targetBinding == nil || $0.targetBinding == targetBinding)
        }
        return true
    }

    private func hasActiveGrantLocked(
        grants: [RemoteClientGrant],
        clientID: String,
        targetID: UUID,
        targetBinding: String?,
        at date: Date
    ) -> Bool {
        grants.contains {
            $0.clientID == clientID &&
                $0.targetID == targetID &&
                $0.targetBinding == targetBinding &&
                $0.revokedAt == nil &&
                ($0.absoluteExpiration == nil || $0.absoluteExpiration! > date)
        }
    }

    private func hasBlockingRevocationLocked(
        grants: [RemoteClientGrant],
        clientID: String,
        targetID: UUID,
        targetBinding: String?,
        at date: Date
    ) -> Bool {
        if hasActiveGrantLocked(
            grants: grants,
            clientID: clientID,
            targetID: targetID,
            targetBinding: targetBinding,
            at: date
        ) {
            return false
        }
        return grants.contains {
            $0.clientID == clientID &&
                $0.targetID == targetID &&
                $0.targetBinding == targetBinding &&
                $0.revokedAt != nil
        }
    }

    /// Upgrades the pre-target-binding form of a durable grant once, without
    /// making endpoint changes invisible after the upgrade. The migration is
    /// deliberately narrow: it applies only to a JTS-registered client, only
    /// when no exact-bound grant has ever become active for that client and
    /// profile, and only when the old grant already covers the requested
    /// capabilities and external-data consent.
    private func migrateLegacyPersistentGrantBindingIfEligible(
        state: inout PersistedState,
        clientID: String,
        targetID: UUID,
        targetBinding: String?,
        requestedCapabilities: Set<RemoteCapability>,
        externalDataTypes: Set<RemoteExternalDataType>,
        permissionPolicy: RemoteTargetPermissionPolicy
    ) -> Bool {
        guard let targetBinding,
              clientID.hasPrefix("mcp-registration:"),
              permissionPolicy.controlLeaseCapabilities.isEmpty,
              !state.grants.contains(where: {
                  $0.clientID == clientID &&
                      $0.targetID == targetID &&
                      $0.targetBinding != nil
              }),
              let legacyGrantIndex = state.grants.lastIndex(where: {
                  $0.clientID == clientID &&
                      $0.targetID == targetID &&
                      $0.targetBinding == nil &&
                      $0.revokedAt == nil &&
                      $0.absoluteExpiration == nil &&
                      $0.controlRevocationToken == nil &&
                      requestedCapabilities.isSubset(of: $0.capabilities) &&
                      (!permissionPolicy.requireExternalDataConsent ||
                          externalDataTypes.isSubset(of: $0.consentedExternalDataTypes))
              }) else {
            return false
        }

        state.grants[legacyGrantIndex].targetBinding = targetBinding
        return true
    }

    private func removePolicyObsoletePendingRequests(
        state: inout PersistedState,
        targetID: UUID,
        policy: RemoteTargetPermissionPolicy
    ) -> Bool {
        let previousCount = state.pendingRequests.count
        state.pendingRequests.removeAll { request in
            request.targetID == targetID &&
                !request.requestedCapabilities.isSubset(of: policy.maximumCapabilities)
        }
        return state.pendingRequests.count != previousCount
    }

    private func removeResolvedPendingRequests(
        state: inout PersistedState,
        grant: RemoteClientGrant,
        policy: RemoteTargetPermissionPolicy
    ) -> Bool {
        let previousCount = state.pendingRequests.count
        state.pendingRequests.removeAll { request in
            guard request.clientID == grant.clientID,
                  request.targetID == grant.targetID,
                  request.targetBinding == grant.targetBinding,
                  request.requestedCapabilities.isSubset(of: policy.maximumCapabilities),
                  !policy.containsControlLeaseCapability(in: request.requestedCapabilities),
                  request.requestedCapabilities.isSubset(of: grant.capabilities) else {
                return false
            }
            return !policy.requireExternalDataConsent ||
                request.externalDataTypes.isSubset(of: grant.consentedExternalDataTypes)
        }
        return state.pendingRequests.count != previousCount
    }

    private func normalizeLegacyLeaseState(
        state: inout PersistedState,
        targetID: UUID,
        policy: RemoteTargetPermissionPolicy,
        targetBinding: String?,
        at date: Date
    ) -> Bool {
        guard policy.controlLeaseCapabilities.isEmpty else { return false }
        var didChangeState = false

        if let targetBinding {
            let previousRequestCount = state.pendingRequests.count
            state.pendingRequests.removeAll {
                $0.targetID == targetID &&
                    $0.targetBinding != targetBinding
            }
            didChangeState = state.pendingRequests.count != previousRequestCount
        }

        for index in state.grants.indices where
            state.grants[index].targetID == targetID &&
                (targetBinding == nil ||
                    state.grants[index].targetBinding == targetBinding) &&
                state.grants[index].revokedAt == nil &&
                (state.grants[index].absoluteExpiration == nil ||
                    state.grants[index].absoluteExpiration! > date) &&
                state.grants[index].controlRevocationToken != nil {
            state.grants[index].controlRevocationToken = nil
            didChangeState = true
        }

        for index in state.pendingRequests.indices where
            state.pendingRequests[index].targetID == targetID &&
                (targetBinding == nil ||
                    state.pendingRequests[index].targetBinding == targetBinding) &&
                state.pendingRequests[index].reason == .controlLeaseRenewal {
            let request = state.pendingRequests[index]
            let hasActiveGrant = state.grants.contains {
                $0.clientID == request.clientID &&
                    $0.targetID == targetID &&
                    $0.targetBinding == request.targetBinding &&
                    $0.revokedAt == nil &&
                    ($0.absoluteExpiration == nil || $0.absoluteExpiration! > date)
            }
            state.pendingRequests[index].reason = hasActiveGrant
                ? .capabilityExpansion
                : .newGrant
            didChangeState = true
        }

        return didChangeState
    }

    private func upsertPendingRequest(
        state: inout PersistedState,
        clientID: String,
        clientDisplayIdentity: String?,
        targetID: UUID,
        targetBinding: String?,
        capabilities: Set<RemoteCapability>,
        externalDataTypes: Set<RemoteExternalDataType>,
        reason: RemoteGrantRequestReason,
        at date: Date
    ) -> PendingRequestUpsert {
        if let index = state.pendingRequests.firstIndex(where: {
            $0.clientID == clientID &&
                $0.targetID == targetID &&
                $0.targetBinding == targetBinding
        }) {
            var updated = state.pendingRequests[index]
            var didChangeState = false
            if let clientDisplayIdentity,
               updated.clientDisplayIdentity != clientDisplayIdentity {
                updated.clientDisplayIdentity = clientDisplayIdentity
                didChangeState = true
            }
            if !capabilities.isSubset(of: updated.requestedCapabilities) {
                updated.requestedCapabilities.formUnion(capabilities)
                didChangeState = true
            }
            if !externalDataTypes.isSubset(of: updated.externalDataTypes) {
                updated.externalDataTypes.formUnion(externalDataTypes)
                didChangeState = true
            }
            let resolvedReason = Self.higherPriorityReason(
                updated.reason,
                reason
            )
            if updated.reason != resolvedReason {
                updated.reason = resolvedReason
                didChangeState = true
            }
            if didChangeState {
                updated.lastRequestedAt = date
                state.pendingRequests[index] = updated
            }
            return PendingRequestUpsert(
                request: updated,
                didChangeState: didChangeState
            )
        }

        let request = RemoteGrantRequest(
            id: UUID(),
            clientID: clientID,
            clientDisplayIdentity: clientDisplayIdentity,
            targetID: targetID,
            targetBinding: targetBinding,
            requestedCapabilities: capabilities,
            externalDataTypes: externalDataTypes,
            reason: reason,
            firstRequestedAt: date,
            lastRequestedAt: date
        )
        state.pendingRequests.append(request)
        return PendingRequestUpsert(request: request, didChangeState: true)
    }

    private func approvalRequired(_ request: RemoteGrantRequest) -> RemoteGrantGateFailure {
        RemoteGrantGateFailure(
            denialCode: "GRANT_APPROVAL_REQUIRED",
            message: "JTS Terminal is waiting for visible approval of this AI client's \(request.requestedCapabilities.map(\.rawValue).sorted().joined(separator: ", ")) access.",
            pendingRequestID: request.id
        )
    }

    private func postApprovalRequestNotification(_ request: RemoteGrantRequest) {
        NotificationCenter.default.post(
            name: .jtsRDPGrantApprovalRequested,
            object: nil,
            userInfo: [
                "targetId": request.targetID.uuidString.lowercased(),
                "requestId": request.id.uuidString.lowercased(),
                "clientId": request.clientID,
                "clientDisplayIdentity": request.clientDisplayIdentity,
            ]
        )
    }

    private func normalizedClientID(_ value: String) throws -> String {
        let sanitized = value
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(160)
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized != "unidentified-mcp-client" else {
            throw RemoteGrantGateFailure(
                denialCode: "CLIENT_IDENTITY_REQUIRED",
                message: "The MCP client must identify itself during initialize before requesting Windows access."
            )
        }
        return sanitized
    }

    private func normalizedTargetBinding(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw RemoteGrantGateFailure(
                denialCode: "INVALID_TARGET_BINDING",
                message: "The MCP target identity binding is invalid."
            )
        }
        return normalized
    }

    private func inferredExternalDataTypes(
        for capabilities: Set<RemoteCapability>
    ) -> Set<RemoteExternalDataType> {
        var types: Set<RemoteExternalDataType> = []
        if capabilities.contains(.desktopObserve) { types.insert(.desktopImage) }
        if capabilities.contains(.commandExecution) { types.insert(.commandOutput) }
        if capabilities.contains(.fileAccess) { types.formUnion([.fileMetadata, .fileContent]) }
        if capabilities.contains(.clipboard) { types.insert(.clipboardContent) }
        return types
    }

    private func applyPersistedState(_ snapshot: PersistedSnapshot) {
        grants = snapshot.state.grants
        pendingRequests = snapshot.state.pendingRequests
        lastLoadedStorageStamp = snapshot.storageStamp
        requiresReload = false
        persistenceError = nil
    }

    private func invalidateSnapshot(for error: Error) {
        grants = []
        pendingRequests = []
        // Keep the last known stamp for removal diagnostics, while an explicit
        // unknown-state bit forces retry even when both old and current stamps
        // are nil (for example, a repaired lock before grants.json exists).
        requiresReload = true
        persistenceError = error.localizedDescription
    }

    private func loadLatestSnapshot() throws -> PersistedSnapshot {
        try withExclusiveLock {
            snapshotLocked(try readLatestLocked())
        }
    }

    private func snapshotLocked(_ state: PersistedState) -> PersistedSnapshot {
        PersistedSnapshot(
            state: state,
            storageStamp: Self.storageStamp(for: storageURL)
        )
    }

    private func readLatestLocked() throws -> PersistedState {
        let descriptor = storageURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            let openError = errno
            if openError == ENOENT {
                return .empty
            }
            throw Self.posixFailure(
                message: "The AI authorization file could not be opened.",
                errorNumber: openError
            )
        }
        defer { _ = Darwin.close(descriptor) }

        try validatePrivateRegularFile(
            descriptor,
            context: "AI authorization file"
        )
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw Self.posixFailure(
                message: "The AI authorization file could not be inspected.",
                errorNumber: errno
            )
        }
        guard fileStatus.st_size >= 0,
              fileStatus.st_size <= off_t(Self.maximumPersistedStateBytes) else {
            throw GrantStorePersistenceFailure(
                message: "The AI authorization file exceeds the safe size limit.",
                underlyingError: nil
            )
        }

        let data: Data
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            data = try handle.read(upToCount: Self.maximumPersistedStateBytes + 1) ?? Data()
        } catch {
            throw GrantStorePersistenceFailure(
                message: "The AI authorization file could not be read.",
                underlyingError: error
            )
        }
        guard data.count <= Self.maximumPersistedStateBytes else {
            throw GrantStorePersistenceFailure(
                message: "The AI authorization file exceeds the safe size limit.",
                underlyingError: nil
            )
        }

        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            guard state.formatVersion == 1 else {
                throw GrantStorePersistenceFailure(
                    message: "The AI authorization file uses an unsupported format.",
                    underlyingError: nil
                )
            }
            return state
        } catch let failure as GrantStorePersistenceFailure {
            throw failure
        } catch {
            throw GrantStorePersistenceFailure(
                message: "The AI authorization file could not be decoded.",
                underlyingError: error
            )
        }
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        let directory = storageURL.deletingLastPathComponent()
        let directoryDescriptor = try openPrivateDirectory(
            directory,
            errorContext: "AI authorization"
        )
        defer { _ = Darwin.close(directoryDescriptor) }

        let descriptor = lockURL.lastPathComponent.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw Self.posixFailure(
                message: "The AI authorization lock file could not be opened.",
                errorNumber: errno
            )
        }
        defer { _ = Darwin.close(descriptor) }

        do {
            try PrivateFileSecurity.securePrivateFileDescriptor(
                descriptor,
                path: lockURL.path
            )
        } catch {
            throw GrantStorePersistenceFailure(
                message: "The AI authorization lock file could not be secured.",
                underlyingError: error
            )
        }

        let deadline = ProcessInfo.processInfo.systemUptime + Self.exclusiveLockTimeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            if lockError == EINTR { continue }
            if (lockError == EWOULDBLOCK || lockError == EAGAIN),
               ProcessInfo.processInfo.systemUptime < deadline {
                usleep(Self.exclusiveLockRetryMicroseconds)
                continue
            }
            throw Self.posixFailure(
                message: lockError == EWOULDBLOCK || lockError == EAGAIN
                    ? "The AI authorization lock timed out."
                    : "The AI authorization lock could not be acquired.",
                errorNumber: lockError
            )
        }

        let operationResult: Result<T, Error> = Result {
            try operation()
        }
        // Closing the descriptor below releases the flock even if an explicit
        // unlock reports an interruption. Never overwrite an already committed
        // authorization transaction with an ambiguous post-commit error.
        _ = flock(descriptor, LOCK_UN)
        return try operationResult.get()
    }

    private func persistLocked(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(state)
            guard data.count <= Self.maximumPersistedStateBytes else {
                throw GrantStorePersistenceFailure(
                    message: "The AI authorization state exceeds the safe size limit.",
                    underlyingError: nil
                )
            }
            let directoryDescriptor = try openPrivateDirectory(
                storageURL.deletingLastPathComponent(),
                errorContext: "AI authorization"
            )
            defer { _ = Darwin.close(directoryDescriptor) }
            try persistDataAtomically(
                data,
                destinationName: storageURL.lastPathComponent,
                directoryDescriptor: directoryDescriptor,
                context: "AI authorization"
            )
        } catch let failure as GrantStorePersistenceFailure {
            throw failure
        } catch {
            throw GrantStorePersistenceFailure(
                message: "The AI authorization state could not be persisted.",
                underlyingError: error
            )
        }
    }

    func requireControlAuthorityAvailable(
        targetID: UUID,
        approvedRevocationToken: String?
    ) throws {
        do {
            guard try effectiveControlRevocationToken(targetID: targetID)
                    == approvedRevocationToken else {
                throw RemoteGrantGateFailure(
                    denialCode: RemoteAuthorizationDenialCode.leaseExpired.rawValue,
                    message: "Manual takeover or Emergency Stop ended this AI control lease."
                )
            }
        } catch let failure as RemoteGrantGateFailure {
            throw failure
        } catch {
            invalidateSnapshot(for: error)
            throw RemoteGrantGateFailure(
                denialCode: "GRANT_STORE_UNAVAILABLE",
                message: "The AI authorization store could not verify control authority. Access remains fail-closed."
            )
        }
    }

    private func markControlAuthorityRevoked(
        targetID: UUID,
        token: String
    ) throws {
        if let failure = controlRevocationFailureForTesting?() {
            throw failure
        }
        let directoryDescriptor = try openPrivateDirectory(
            controlRevocationDirectoryURL,
            errorContext: "AI control revocation"
        )
        defer { _ = Darwin.close(directoryDescriptor) }
        try persistDataAtomically(
            Data(token.utf8),
            destinationName: controlRevocationFileName(targetID: targetID),
            directoryDescriptor: directoryDescriptor,
            context: "AI control revocation marker"
        )
    }

    private func effectiveControlRevocationToken(targetID: UUID) throws -> String? {
        if let pendingToken = pendingLocalControlRevocationTokensByTargetID[targetID] {
            // A failed marker commit must never let an older durable epoch win.
            // Retry the exact pending epoch and remain fail-closed until it is
            // durably visible to every process.
            try markControlAuthorityRevoked(
                targetID: targetID,
                token: pendingToken
            )
            pendingLocalControlRevocationTokensByTargetID.removeValue(forKey: targetID)
        }
        return try controlRevocationToken(targetID: targetID)
    }

    private func controlRevocationToken(targetID: UUID) throws -> String? {
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try openPrivateDirectory(
                controlRevocationDirectoryURL,
                errorContext: "AI control revocation"
            )
        } catch let failure as GrantStorePersistenceFailure {
            throw failure
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        let name = controlRevocationFileName(targetID: targetID)
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0 {
            let openError = errno
            if openError == ENOENT { return nil }
            throw Self.posixFailure(
                message: "The AI control revocation marker could not be opened.",
                errorNumber: openError
            )
        }
        defer { _ = Darwin.close(descriptor) }
        try validatePrivateRegularFile(
            descriptor,
            context: "AI control revocation marker"
        )
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_size > 0,
              fileStatus.st_size <= 64 else {
            throw GrantStorePersistenceFailure(
                message: "The AI control revocation marker has an invalid size.",
                underlyingError: nil
            )
        }
        let data: Data
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            data = try handle.read(upToCount: 65) ?? Data()
        } catch {
            throw GrantStorePersistenceFailure(
                message: "The AI control revocation marker could not be read.",
                underlyingError: error
            )
        }
        guard data.count <= 64,
              let token = String(data: data, encoding: .utf8),
              UUID(uuidString: token) != nil else {
            throw GrantStorePersistenceFailure(
                message: "The AI control revocation marker is invalid.",
                underlyingError: nil
            )
        }
        return token.lowercased()
    }

    private func controlRevocationFileName(targetID: UUID) -> String {
        "\(targetID.uuidString.lowercased()).revoked"
    }

    private func openPrivateDirectory(
        _ directory: URL,
        errorContext: String
    ) throws -> Int32 {
        do {
            try PrivateFileSecurity.secureDirectory(at: directory)
        } catch {
            throw GrantStorePersistenceFailure(
                message: "The \(errorContext) directory could not be secured.",
                underlyingError: error
            )
        }

        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw Self.posixFailure(
                message: "The \(errorContext) directory could not be opened.",
                errorNumber: errno
            )
        }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFDIR,
              fileStatus.st_uid == geteuid() else {
            _ = Darwin.close(descriptor)
            throw GrantStorePersistenceFailure(
                message: "The \(errorContext) directory ownership or type is unsafe.",
                underlyingError: nil
            )
        }
        do {
            try PrivateFileSecurity.verifyPrivateDirectoryDescriptor(
                descriptor,
                path: directory.path
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw GrantStorePersistenceFailure(
                message: "The \(errorContext) directory is not private.",
                underlyingError: error
            )
        }
        return descriptor
    }

    private func validatePrivateRegularFile(
        _ descriptor: Int32,
        context: String
    ) throws {
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw Self.posixFailure(
                message: "The \(context) could not be inspected.",
                errorNumber: errno
            )
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            throw GrantStorePersistenceFailure(
                message: "The \(context) path is not a regular file.",
                underlyingError: nil
            )
        }
        guard fileStatus.st_uid == geteuid(), fileStatus.st_nlink == 1 else {
            throw GrantStorePersistenceFailure(
                message: "The \(context) ownership or link count is unsafe.",
                underlyingError: nil
            )
        }
        do {
            try PrivateFileSecurity.verifyPrivateFileDescriptor(
                descriptor,
                path: context
            )
        } catch {
            throw GrantStorePersistenceFailure(
                message: "The \(context) permissions or ACL are unsafe.",
                underlyingError: error
            )
        }
    }

    private func persistDataAtomically(
        _ data: Data,
        destinationName: String,
        directoryDescriptor: Int32,
        context: String
    ) throws {
        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw Self.posixFailure(
                message: "The \(context) temporary file could not be created.",
                errorNumber: errno
            )
        }

        var descriptorNeedsClose = true
        var temporaryNeedsRemoval = true
        defer {
            if descriptorNeedsClose {
                _ = Darwin.close(descriptor)
            }
            if temporaryNeedsRemoval {
                temporaryName.withCString {
                    _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }

        do {
            try PrivateFileSecurity.securePrivateFileDescriptor(
                descriptor,
                path: "\(context) temporary file"
            )
        } catch {
            throw GrantStorePersistenceFailure(
                message: "The \(context) temporary file could not be secured.",
                underlyingError: error
            )
        }
        try writeAll(data, to: descriptor, context: context)
        guard Darwin.fsync(descriptor) == 0 else {
            throw Self.posixFailure(
                message: "The \(context) temporary file could not be synchronized.",
                errorNumber: errno
            )
        }

        let closeResult = Darwin.close(descriptor)
        descriptorNeedsClose = false
        guard closeResult == 0 else {
            throw Self.posixFailure(
                message: "The \(context) temporary file could not be closed.",
                errorNumber: errno
            )
        }

        let renameResult = temporaryName.withCString { temporaryPath in
            destinationName.withCString { destinationPath in
                Darwin.renameat(
                    directoryDescriptor,
                    temporaryPath,
                    directoryDescriptor,
                    destinationPath
                )
            }
        }
        guard renameResult == 0 else {
            throw Self.posixFailure(
                message: "The \(context) could not be committed.",
                errorNumber: errno
            )
        }
        temporaryNeedsRemoval = false

        // The namespace commit above is authoritative for this running system.
        // Directory synchronization is best-effort so a post-rename failure
        // cannot masquerade as a rolled-back authorization transaction.
        _ = Darwin.fsync(directoryDescriptor)
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        context: String
    ) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            throw Self.posixFailure(
                message: "The \(context) temporary file could not be written.",
                errorNumber: written < 0 ? errno : EIO
            )
        }
    }

    private static func posixFailure(
        message: String,
        errorNumber: Int32
    ) -> GrantStorePersistenceFailure {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorNumber),
            userInfo: nil
        )
        return GrantStorePersistenceFailure(
            message: message,
            underlyingError: underlying
        )
    }

    private static func higherPriorityReason(
        _ lhs: RemoteGrantRequestReason,
        _ rhs: RemoteGrantRequestReason
    ) -> RemoteGrantRequestReason {
        let priority: [RemoteGrantRequestReason: Int] = [
            .newGrant: 0,
            .capabilityExpansion: 1,
            .controlLeaseRenewal: 2,
            .externalDataConsent: 3,
        ]
        return (priority[rhs] ?? 0) > (priority[lhs] ?? 0) ? rhs : lhs
    }

    private static func defaultStorageURL() -> URL {
        #if JTS_UI_TEST_SUPPORT
        if let isolatedURL = UITestRDPFixtureEnvironment.isolatedGrantStorageURL() {
            return isolatedURL
        }
        #endif

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("JTS Terminal", isDirectory: true)
            .appendingPathComponent("Security", isDirectory: true)
            .appendingPathComponent("rdp-client-grants-v1.json")
    }

    private static func storageStamp(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(fileNumber)-\(modified.timeIntervalSinceReferenceDate)-\(size.uint64Value)"
    }
}

#endif
