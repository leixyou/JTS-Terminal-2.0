#if ENABLE_RDP_2 && JTS_UI_TEST_SUPPORT
import AppKit
import Foundation

nonisolated enum UITestRDPFixtureMode: String, CaseIterable, Sendable {
    case connectedViewing = "connected-viewing"
    case connectedControl = "connected-control"
    case connectedStopping = "connected-stopping"
    case pendingPersistentGrant = "pending-persistent-grant"
}

nonisolated struct UITestRDPFixture: Equatable, Sendable {
    let fixtureID: UUID
    let mode: UITestRDPFixtureMode
    let targetID: UUID
    let clientID: String
    let clientDisplayIdentity: String
}

/// Strict, compile-time-gated data for hosted RDP UI tests.
///
/// A fixture is accepted only when the process explicitly identifies itself
/// as a UI test and imports exactly one reserved, non-routable RDP profile
/// whose target UUID matches the launch environment. This prevents a stray
/// environment value from replacing presentation or authorization state for a
/// real saved server.
nonisolated enum UITestRDPFixtureEnvironment {
    static let fixtureIDKey = "JTS_TERMINAL_UI_RDP_FIXTURE_ID"
    static let fixtureTargetIDKey = "JTS_TERMINAL_UI_RDP_FIXTURE_TARGET_ID"
    static let fixtureModeKey = "JTS_TERMINAL_UI_RDP_FIXTURE_MODE"
    static let grantStoreNamespaceKey = "JTS_TERMINAL_UI_GRANT_STORE_NAMESPACE"
    static let narrowWindowKey = "JTS_TERMINAL_UI_RDP_NARROW_WINDOW"

    static let reservedHost = "rdp-ui.example.invalid"
    static let reservedUsername = "ui-test"
    static let reservedAlias = "rdp-ui-fixture"
    static let reservedPort = 3_389
    static let clientDisplayIdentity = "Codex UI Fixture"

    private static let fallbackGrantStoreNamespace = UUID()

    @MainActor
    static func fixture(
        for target: RemoteSession,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UITestRDPFixture? {
        guard environment[UITestSSHSessionEnvironment.isUITestingKey] == "1",
              let fixtureID = validatedUUID(environment[fixtureIDKey]),
              let targetID = validatedUUID(environment[fixtureTargetIDKey]),
              let rawMode = environment[fixtureModeKey],
              let mode = UITestRDPFixtureMode(rawValue: rawMode),
              let profiles = try? UITestSSHSessionEnvironment.importedProfiles(
                  environment: environment
              ),
              profiles.count == 1,
              let profile = profiles.first,
              isReservedProfile(profile, targetID: targetID),
              target.targetID == targetID,
              target.connectionType == .rdp,
              target.name == profile.name,
              target.host == reservedHost,
              target.username == reservedUsername,
              target.port == reservedPort,
              target.mcpEnabled,
              target.effectiveMCPAlias == reservedAlias,
              target.rdpProfile.persistentMCPControlEnabled,
              target.rdpProfile.permissionPolicy.controlLeaseCapabilities.isEmpty else {
            return nil
        }

        return UITestRDPFixture(
            fixtureID: fixtureID,
            mode: mode,
            targetID: targetID,
            clientID: "ui-test-rdp-client-\(fixtureID.uuidString.lowercased())",
            clientDisplayIdentity: clientDisplayIdentity
        )
    }

    @MainActor
    static func presentation(
        for target: RemoteSession,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RDPDesktopWorkspacePresentation? {
        guard let fixture = fixture(for: target, environment: environment) else {
            return nil
        }

        let isViewing = fixture.mode == .connectedViewing
        let isControlling = fixture.mode == .connectedControl
        let isStopping = fixture.mode == .connectedStopping
        let showsAIActivity = isViewing || isControlling || isStopping
        let identity = RDPActiveAIClientIdentity(
            authorizationID: fixture.clientID,
            displayIdentity: fixture.clientDisplayIdentity,
            isControlling: isControlling || isStopping
        )
        let state = RDPDesktopSessionState(
            sessionID: fixture.fixtureID,
            targetID: fixture.targetID,
            phase: .connected,
            runtimeAvailability: .available,
            companion: WindowsCompanionState(
                availability: .ready,
                protocolVersion: 1,
                companionVersion: "UI Fixture",
                reason: nil
            ),
            stateRevision: 1,
            latestFrameID: fixture.fixtureID,
            remotePixelWidth: target.rdpProfile.desktopWidth,
            remotePixelHeight: target.rdpProfile.desktopHeight,
            connectedAt: Date(timeIntervalSince1970: 1_752_710_400),
            reconnectAttempt: nil,
            reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil,
            lastErrorCode: nil,
            lastErrorMessage: nil
        )

        return RDPDesktopWorkspacePresentation(
            state: state,
            frameImage: NSImage(size: NSSize(
                width: target.rdpProfile.desktopWidth,
                height: target.rdpProfile.desktopHeight
            )),
            certificateChallenge: nil,
            companionPairing: nil,
            companionIdentity: nil,
            isAIViewing: isViewing,
            isAIControlActive: isControlling,
            isAIControlStopping: isStopping,
            activeAIClientIdentities: showsAIActivity ? [identity] : [],
            connect: nil,
            disconnect: {},
            takeManualControl: showsAIActivity ? {} : nil,
            emergencyStop: showsAIActivity ? {} : nil,
            trustCertificateOnce: nil,
            pinCertificate: nil,
            approveCompanionPairing: nil,
            unpairCompanion: nil,
            performManualAction: nil,
            resizeDesktop: { _, _ in },
            openLocalNetworkSettings: nil
        )
    }

    /// Creates the real persistent-approval request through the production
    /// authorization store. ContentView calls this only for the dedicated
    /// pending-grant fixture after importing the reserved target.
    @MainActor
    @discardableResult
    static func seedPendingGrantIfNeeded(
        for target: RemoteSession,
        grantStore suppliedGrantStore: RemoteClientGrantStore? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let fixture = fixture(for: target, environment: environment),
              fixture.mode == .pendingPersistentGrant else {
            return false
        }
        let grantStore = suppliedGrantStore ?? .shared

        if grantStore.pendingRequests(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding
        ).contains(where: { $0.clientID == fixture.clientID }) {
            return true
        }
        if grantStore.activeGrants(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding
        ).contains(where: { $0.clientID == fixture.clientID }) {
            return false
        }

        do {
            _ = try grantStore.authorize(
                clientID: fixture.clientID,
                clientDisplayIdentity: fixture.clientDisplayIdentity,
                targetID: target.targetID,
                targetBinding: target.mcpGrantTargetBinding,
                capabilities: target.mcpPermissionPolicy.maximumCapabilities,
                policy: target.mcpPermissionPolicy,
                externalDataTypes: RemoteExternalDataPolicy.completeTypes(
                    for: target.mcpPermissionPolicy.maximumCapabilities
                )
            )
            return false
        } catch let failure as RemoteGrantGateFailure {
            guard failure.pendingRequestID != nil else { return false }
            return grantStore.pendingRequests(
                targetID: target.targetID,
                targetBinding: target.mcpGrantTargetBinding
            ).contains(where: { $0.clientID == fixture.clientID })
        } catch {
            return false
        }
    }

    /// UI tests must never read or mutate the installed app's authorization
    /// file. The explicit namespace is supplied by XCUI; the per-process UUID
    /// is a safe fallback for older UI tests that set only the testing marker.
    static func isolatedGrantStorageURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fallbackNamespace: UUID = fallbackGrantStoreNamespace
    ) -> URL? {
        isolatedSecurityStorageURL(
            fileName: "rdp-client-grants-v1.json",
            environment: environment,
            temporaryDirectory: temporaryDirectory,
            fallbackNamespace: fallbackNamespace
        )
    }

    static func isolatedAuditStorageURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fallbackNamespace: UUID = fallbackGrantStoreNamespace
    ) -> URL? {
        isolatedSecurityStorageURL(
            fileName: "rdp-capability-audit-v1.json",
            environment: environment,
            temporaryDirectory: temporaryDirectory,
            fallbackNamespace: fallbackNamespace
        )
    }

    static func requestsNarrowWindow(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[UITestSSHSessionEnvironment.isUITestingKey] == "1"
            && environment[narrowWindowKey] == "1"
            && validatedUUID(environment[fixtureIDKey]) != nil
            && validatedUUID(environment[fixtureTargetIDKey]) != nil
            && environment[fixtureModeKey].flatMap(UITestRDPFixtureMode.init(rawValue:)) != nil
            && environment[UITestSSHSessionEnvironment.importedProfileFixtureKey] != nil
    }

    private static func isolatedSecurityStorageURL(
        fileName: String,
        environment: [String: String],
        temporaryDirectory: URL,
        fallbackNamespace: UUID
    ) -> URL? {
        guard environment[UITestSSHSessionEnvironment.isUITestingKey] == "1" else {
            return nil
        }
        let namespace = validatedUUID(environment[grantStoreNamespaceKey])
            ?? fallbackNamespace
        return temporaryDirectory
            .standardizedFileURL
            .appendingPathComponent("JTS-Terminal-UITests", isDirectory: true)
            .appendingPathComponent(namespace.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func isReservedProfile(
        _ profile: RemoteSessionProfile,
        targetID: UUID
    ) -> Bool {
        guard profile.id == targetID,
              profile.connectionType == .rdp,
              profile.host == reservedHost,
              profile.username == reservedUsername,
              profile.port == reservedPort,
              profile.identityFile.isEmpty,
              profile.jumpHost.isEmpty,
              profile.mcpEnabled,
              profile.mcpAlias == reservedAlias,
              let rdpProfile = profile.rdpProfile,
              rdpProfile.domain.isEmpty,
              rdpProfile.certificateTrustMode == .systemOrPinned,
              rdpProfile.pinnedCertificateSHA256 == nil,
              !rdpProfile.clipboardEnabled,
              rdpProfile.persistentMCPControlEnabled,
              rdpProfile.permissionPolicy.controlLeaseCapabilities.isEmpty else {
            return false
        }
        return rdpProfile.permissionPolicy.maximumCapabilities
            == RemoteTargetPermissionPolicy.rdp2ReleaseCapabilities
    }

    private static func validatedUUID(_ rawValue: String?) -> UUID? {
        guard let rawValue,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = UUID(uuidString: rawValue) else {
            return nil
        }
        return value
    }
}
#endif
