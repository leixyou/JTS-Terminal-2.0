#if ENABLE_RDP_2
import AppKit
import Combine
import CoreGraphics
import Foundation
import IOSurface

extension Notification.Name {
    static let jtsRDPDesktopRequested = Notification.Name("com.lljts.JTSTerminal.rdp.desktop-requested")
}

nonisolated struct RDPCertificateChallenge: Equatable, Sendable {
    var host: String
    var port: Int
    var commonName: String
    var subject: String
    var issuer: String
    var sha256: String
    var oldSHA256: String?
    var changed: Bool
    var hostMismatch: Bool
    var pinnedMismatch: Bool
}

nonisolated enum RDPDesktopInputFailurePolicy {
    static let genericCode = "RDP_INPUT_FAILED"
    static let displayControlUnavailableCode = "RDP_DISPLAY_CONTROL_UNAVAILABLE"

    static func machineCode(for error: Error) -> String {
        if let failure = error as? WindowsMCPToolError {
            return failure.code.rawValue
        }
        guard let failure = error as? FreeRDPXPCFailure else {
            return genericCode
        }
        let rawCode = failure.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCode = rawCode.hasPrefix("RDP_DISPLAY_")
            ? rawCode
            : "RDP_\(rawCode)"
        guard displayCode.hasPrefix("RDP_DISPLAY_"),
              displayCode.utf8.count <= 96,
              displayCode.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value) ||
                      (48...57).contains(scalar.value) ||
                      scalar.value == 95
              }) else {
            return genericCode
        }
        return displayCode
    }

    static func isTransientInputFailureCode(_ code: String?) -> Bool {
        guard let code else { return false }
        return code == genericCode ||
            code == WindowsMCPToolError.Code.stateConflict.rawValue ||
            code.hasPrefix("RDP_DISPLAY_")
    }
}

/// Validates the IOSurface allocation independently of XPC-provided frame
/// metadata before the main app copies any helper-owned pixels.
nonisolated struct RDPFrameSurfaceLayout: Equatable, Sendable {
    static let maximumFramebufferBytes = 256 * 1_024 * 1_024

    var width: Int
    var height: Int
    var bytesPerRow: Int
    var requiredBytes: Int

    static func validated(
        metadataWidth: Int,
        metadataHeight: Int,
        metadataBytesPerRow: Int,
        surfaceWidth: Int,
        surfaceHeight: Int,
        surfaceBytesPerRow: Int,
        surfaceAllocationBytes: Int
    ) -> Self? {
        guard metadataWidth == surfaceWidth,
              metadataHeight == surfaceHeight,
              metadataBytesPerRow == surfaceBytesPerRow,
              (640...7_680).contains(surfaceWidth),
              (480...4_320).contains(surfaceHeight),
              surfaceWidth <= Int.max / 4 else {
            return nil
        }
        let minimumBytesPerRow = surfaceWidth * 4
        guard surfaceBytesPerRow >= minimumBytesPerRow,
              surfaceBytesPerRow <= maximumFramebufferBytes,
              surfaceHeight <= Int.max / surfaceBytesPerRow else {
            return nil
        }
        let requiredBytes = surfaceHeight * surfaceBytesPerRow
        guard requiredBytes > 0,
              requiredBytes <= maximumFramebufferBytes,
              surfaceAllocationBytes >= requiredBytes,
              surfaceAllocationBytes <= maximumFramebufferBytes else {
            return nil
        }
        return Self(
            width: surfaceWidth,
            height: surfaceHeight,
            bytesPerRow: surfaceBytesPerRow,
            requiredBytes: requiredBytes
        )
    }
}

nonisolated enum RDPCompanionSensitiveInteractionPolicy {
    static func aiInputDenialReason(
        companionAvailability: WindowsCompanionAvailability,
        pairingAuthorizationInProgress: Bool,
        elevationPromptInProgress: Bool
    ) -> String? {
        if pairingAuthorizationInProgress || companionAvailability == .pairingRequired {
            return "AI desktop input is blocked while Windows Companion pairing requires human confirmation."
        }
        if elevationPromptInProgress {
            return "AI desktop input is blocked while the Windows user reviews an elevation request."
        }
        return nil
    }
}

nonisolated struct RDPAuthorizedOperationToken: Equatable, Sendable {
    var operationID: UUID
    var targetID: UUID
    var targetBinding: String
    var clientID: String
    var generation: UInt64
    var connectionGeneration: UInt64
    var showsControlActivity: Bool
    var showsViewingActivity: Bool
    var survivesConnectionTransition: Bool
}

/// Binds every Companion write to one exact DVC lifecycle. The RDP connection
/// itself can stay alive while Windows closes and reopens the dynamic virtual
/// channel, so the connection-attempt token alone is not sufficient.
@MainActor
enum RDPCompanionChannelTransport {
    typealias ChannelIDProvider = @MainActor () -> UUID?
    typealias Transport = @MainActor (Data) async throws -> Void

    static func send(
        _ data: Data,
        expectedChannelID: UUID,
        currentChannelID: @escaping ChannelIDProvider,
        transport: @escaping Transport
    ) async throws {
        try requireCurrent(
            expectedChannelID: expectedChannelID,
            currentChannelID: currentChannelID()
        )
        try Task.checkCancellation()
        try await transport(data)
        try requireCurrent(
            expectedChannelID: expectedChannelID,
            currentChannelID: currentChannelID()
        )
        try Task.checkCancellation()
    }

    private static func requireCurrent(
        expectedChannelID: UUID,
        currentChannelID: UUID?
    ) throws {
        guard currentChannelID == expectedChannelID else {
            throw WindowsCompanionRequestFailure(
                code: "COMPANION_CONNECTION_CHANGED",
                message: "The Windows Companion dynamic virtual channel changed while a message was in flight.",
                retryable: true
            )
        }
    }
}

@MainActor
final class RDPDesktopRuntimeStore: ObservableObject, DesktopProvider {
    typealias OpenOperationExecutor = @MainActor (
        _ target: RemoteSession,
        _ plan: DesktopOpenRequestPlan,
        _ operationID: UUID
    ) async throws -> RDPDesktopSessionState

    typealias InputExecutor = @MainActor (
        _ input: [String: Any],
        _ deadlineMilliseconds: Int?
    ) async throws -> Void

    typealias ConnectionPasswordProvider = @MainActor (
        _ target: RemoteSession,
        _ migrateLegacyCredential: Bool
    ) async throws -> String

    typealias TrustedReopenConnector = @MainActor (
        _ configuration: [String: Any]
    ) async throws -> Void

    typealias LocalNetworkDiagnoser = @MainActor (
        _ endpoint: RDPLocalNetworkDiagnosticEndpoint,
        _ mode: RDPLocalNetworkDiagnosticMode
    ) async -> RDPLocalNetworkDiagnosticResult

    typealias ClipboardIsolationBarrier = @MainActor (
        _ session: FreeRDPXPCSession,
        _ isolated: Bool,
        _ text: Data?
    ) async throws -> Void

    static let shared = RDPDesktopRuntimeStore(
        openOperationExecutor: nil,
        grantStore: .shared,
        auditStore: .shared
    )

    let providerIdentifier = "jts.native-freerdp-xpc"
    var uiaObservations = RDPUIAObservationLedger()

    private struct AIViewingActivity {
        var displayIdentity: String
        var lastObservedAt: Date
        var activityWindow: TimeInterval

        var expiresAt: Date {
            lastObservedAt.addingTimeInterval(activityWindow)
        }
    }

    private struct AuthorizedOperationActivity {
        var token: RDPAuthorizedOperationToken
        var displayIdentity: String
        var startedAt: Date
        var cancel: (() -> Void)?
    }

    private struct LocalNetworkDiagnosticModeRequest {
        let requestID: UUID
        let mode: RDPLocalNetworkDiagnosticMode
    }

    /// Keeps the public `stateRevision` stable as an opaque caller token while
    /// translating it back to the helper's per-connection revision. FreeRDP
    /// restarts its revision counter for every connection, so exposing that raw
    /// value would let a delayed action from the previous connection collide
    /// with a new frame that happens to use the same number.
    struct AttemptScopedRevisionLedger {
        private static let retainedFrameMappingCount = 1_024
        private static let frameMappingTrimThreshold = 1_536

        private(set) var attemptID: UUID
        private(set) var lastRuntimeRevision: UInt64 = 0
        private var lastStateRuntimeRevision: UInt64?
        private var lastFrameRuntimeRevision: UInt64?
        private var highestPublishedRevision: UInt64 = 0
        private var usesIdentityMapping = true
        private var publishedFrameByRuntimeRevision: [UInt64: UInt64] = [:]
        private var runtimeByPublishedFrameRevision: [UInt64: UInt64] = [:]
        private var frameRuntimeRevisionOrder: [UInt64] = []

        var retainedFrameMappingCount: Int {
            publishedFrameByRuntimeRevision.count
        }

        init(initialAttemptID: UUID) {
            attemptID = initialAttemptID
        }

        mutating func beginAttempt(_ newAttemptID: UUID) {
            attemptID = newAttemptID
            lastRuntimeRevision = 0
            lastStateRuntimeRevision = nil
            lastFrameRuntimeRevision = nil
            usesIdentityMapping = false
            publishedFrameByRuntimeRevision.removeAll(keepingCapacity: false)
            runtimeByPublishedFrameRevision.removeAll(keepingCapacity: false)
            frameRuntimeRevisionOrder.removeAll(keepingCapacity: false)
        }

        mutating func publishStateRevision(
            runtimeRevision: UInt64,
            attemptID expectedAttemptID: UUID
        ) -> UInt64? {
            guard attemptID == expectedAttemptID,
                  lastStateRuntimeRevision.map({ runtimeRevision > $0 }) ?? true,
                  let publishedRevision = allocatePublishedRevision(
                      preferredIdentity: runtimeRevision
                  ) else {
                return nil
            }
            lastStateRuntimeRevision = runtimeRevision
            lastRuntimeRevision = max(lastRuntimeRevision, runtimeRevision)
            return publishedRevision
        }

        mutating func publishFrameRevision(
            runtimeRevision: UInt64,
            attemptID expectedAttemptID: UUID
        ) -> UInt64? {
            guard attemptID == expectedAttemptID,
                  lastFrameRuntimeRevision.map({ runtimeRevision >= $0 }) ?? true else {
                return nil
            }
            let publishedRevision: UInt64
            if let existing = publishedFrameByRuntimeRevision[runtimeRevision] {
                publishedRevision = existing
            } else {
                guard let allocated = allocatePublishedRevision(
                    preferredIdentity: runtimeRevision
                ) else { return nil }
                publishedRevision = allocated
                publishedFrameByRuntimeRevision[runtimeRevision] = publishedRevision
                runtimeByPublishedFrameRevision[publishedRevision] = runtimeRevision
                frameRuntimeRevisionOrder.append(runtimeRevision)
                trimFrameMappingsIfNeeded()
            }
            // A non-frame state callback (for example, Companion DVC open or
            // close) can advance the helper revision while the last valid
            // framebuffer remains unchanged. That cached frame is still the
            // helper's authoritative input coordinate space. A frame may trail
            // general state, but it may never trail a frame already displayed.
            lastFrameRuntimeRevision = runtimeRevision
            lastRuntimeRevision = max(lastRuntimeRevision, runtimeRevision)
            return publishedRevision
        }

        func runtimeRevision(
            for publishedRevision: UInt64,
            attemptID expectedAttemptID: UUID
        ) -> UInt64? {
            guard attemptID == expectedAttemptID else { return nil }
            return runtimeByPublishedFrameRevision[publishedRevision]
        }

        private mutating func allocatePublishedRevision(
            preferredIdentity runtimeRevision: UInt64
        ) -> UInt64? {
            let publishedRevision: UInt64
            if usesIdentityMapping,
               runtimeRevision > highestPublishedRevision {
                publishedRevision = runtimeRevision
                highestPublishedRevision = publishedRevision
            } else {
                guard highestPublishedRevision < .max else { return nil }
                highestPublishedRevision += 1
                publishedRevision = highestPublishedRevision
            }
            return publishedRevision
        }

        private mutating func trimFrameMappingsIfNeeded() {
            guard frameRuntimeRevisionOrder.count > Self.frameMappingTrimThreshold else {
                return
            }
            let overflow = frameRuntimeRevisionOrder.count - Self.retainedFrameMappingCount
            let evicted = frameRuntimeRevisionOrder.prefix(overflow)
            frameRuntimeRevisionOrder.removeFirst(overflow)
            for runtimeRevision in evicted {
                guard let publishedRevision = publishedFrameByRuntimeRevision.removeValue(
                    forKey: runtimeRevision
                ) else { continue }
                runtimeByPublishedFrameRevision.removeValue(forKey: publishedRevision)
            }
        }
    }

    private static let aiViewingActivityWindow: TimeInterval = 10
    private static let defaultCompanionMissingGracePeriod: Duration = .seconds(2)

    @Published private(set) var statesByTargetID: [UUID: RDPDesktopSessionState] = [:]
    @Published private(set) var imagesByTargetID: [UUID: NSImage] = [:]
    @Published private(set) var certificateChallengesByTargetID: [UUID: RDPCertificateChallenge] = [:]
    @Published var companionPairingByTargetID: [UUID: WindowsCompanionPeerIdentity] = [:]
    @Published var companionDelegationExportsByTargetID: [UUID: CompanionPairingDelegationExport] = [:]
    @Published private(set) var companionInstallationStatesByTargetID:
        [UUID: WindowsCompanionInstallationState] = [:]
    @Published private var aiViewingActivityByTargetID: [UUID: [String: AIViewingActivity]] = [:]

    final class ActiveDesktop {
        let target: RemoteSession
        let targetBinding: String
        let sessionID: UUID
        let xpc: FreeRDPXPCSession
        var relayBridge: RDPRelaySocketBridge?
        var transportRoute: RDPDesktopTransportRoute = .unknown
        var state: RDPDesktopSessionState
        var latestFrame: DesktopFrame?
        var recentFrameMetadataByID: [UUID: DesktopFrameMetadata] = [:]
        var recentFrameIDs: [UUID] = []
        var latestSurface: IOSurface?
        var clipboardSynchronizer: RDPTextClipboardSynchronizer?
        var clipboardSyncAttemptID: UUID?
        var clipboardSuspendedForAI = false
        var clipboardAIIsolationTask: Task<Void, Error>?
        var clipboardAIIsolationTaskID: UUID?
        var clipboardAIIsolationAttemptID: UUID?
        var clipboardAIIsolationReadyAttemptID: UUID?
        var clipboardAIResumeTask: Task<Void, Never>?
        var clipboardAIResumeTaskID: UUID?
        var clipboardAIResumeAttemptID: UUID?
        var companion: WindowsCompanionClient?
        var companionChannelID: UUID?
        var companionDVCConnected: Bool?
        var companionDVCGeneration: UInt64?
        var companionInstallerClipboardReady = false
        var companionMissingTask: Task<Void, Never>?
        var companionMissingTaskID: UUID?
        var companionHandshakeTask: Task<Void, Never>?
        var companionHandshakeTaskID: UUID?
        var companionAuthorizationTask: Task<Void, Never>?
        var companionAuthorizationTaskID: UUID?
        var companionInstallationTask: Task<Void, Never>?
        var companionInstallationTaskID: UUID?
        var companionInstallationCancellationState: WindowsCompanionInstallationState?
        var elevationPromptInProgress = false
        var elevationPromptOperationID: UUID?
        var reconnectTask: Task<Void, Never>?
        var reconnectTaskID: UUID?
        var localNetworkDiagnosticTask: Task<Void, Never>?
        var localNetworkDiagnosticTaskID: UUID?
        var localNetworkDiagnosticMode: RDPLocalNetworkDiagnosticMode = .initial
        var reconnectSupervisor = RDPReconnectSupervisor()
        var trustOnceFingerprint: String?
        var intentionallyClosing = false
        var hasConnectedOnce = false
        var inputFailureGeneration: UInt64 = 0
        var connectionAttemptID: UUID
        var revisionLedger: AttemptScopedRevisionLedger
        var invalidatedControlAttemptID: UUID?
        let openOperationID: UUID?
        let requestedPixelWidth: Int
        let requestedPixelHeight: Int

        init(
            target: RemoteSession,
            targetBinding: String? = nil,
            sessionID: UUID,
            xpc: FreeRDPXPCSession,
            openOperationID: UUID? = nil,
            requestedPixelWidth: Int,
            requestedPixelHeight: Int
        ) {
            let initialConnectionAttemptID = UUID()
            self.target = target
            self.targetBinding = targetBinding ?? target.mcpGrantTargetBinding
            self.sessionID = sessionID
            self.xpc = xpc
            self.connectionAttemptID = initialConnectionAttemptID
            self.revisionLedger = AttemptScopedRevisionLedger(
                initialAttemptID: initialConnectionAttemptID
            )
            self.openOperationID = openOperationID
            self.requestedPixelWidth = requestedPixelWidth
            self.requestedPixelHeight = requestedPixelHeight
            self.state = RDPDesktopSessionState(
                sessionID: sessionID,
                targetID: target.targetID,
                phase: .connecting,
                runtimeAvailability: .starting,
                companion: .unknown,
                stateRevision: 0,
                latestFrameID: nil,
                remotePixelWidth: nil,
                remotePixelHeight: nil,
                connectedAt: nil,
                reconnectAttempt: nil,
                reconnectMaximumAttempts: nil,
                reconnectScheduledAt: nil,
                lastErrorCode: nil,
                lastErrorMessage: nil
            )
        }
    }

    private enum AttemptScopedFrameError: Error {
        case stale
    }

    private enum CompanionInstallationError: LocalizedError {
        case sessionUnavailable
        case companionNotMissing
        case clipboardDisabled
        case aiControlDidNotDrain
        case clipboardNotReady
        case desktopInputUnavailable
        case companionStatusChanged
        case companionIncompatible
        case companionJoinTimedOut

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable:
                return "The RDP session disconnected before Companion installation completed."
            case .companionNotMissing:
                return "Companion installation is available only while the connected session reports Companion as missing."
            case .clipboardDisabled:
                return "Enable clipboard synchronization for this RDP profile, reconnect, and retry Companion installation."
            case .aiControlDidNotDrain:
                return "The previous AI control operation did not stop in time. Take control and retry."
            case .clipboardNotReady:
                return "The RDP clipboard could not be reserved for the Companion installer."
            case .desktopInputUnavailable:
                return "The connected Windows desktop is not ready to receive the installer launch command."
            case .companionStatusChanged:
                return "Companion status changed while installation was being prepared. Wait for detection to finish before retrying."
            case .companionIncompatible:
                return "Windows started a Companion that is incompatible with this JTS Terminal build."
            case .companionJoinTimedOut:
                return "Windows Companion did not join this RDP session before the installation timeout."
            }
        }
    }

    private enum CompanionInstallationResolution: Error {
        case available(WindowsCompanionAvailability)
    }

    private struct SavedCompanionInstallationClipboard {
        let payload: Data?
    }

    private final class ActiveOpenOperation {
        static let maximumJoinedWaiters = 128

        let operationID: UUID
        let target: RemoteSession
        let plan: DesktopOpenRequestPlan
        let localNetworkDiagnosticMode: RDPLocalNetworkDiagnosticMode
        let deadlineCoordinator = XPCRequestCoordinator()
        var executionTask: Task<RDPDesktopSessionState, Error>?
        var resultTask: Task<RDPDesktopSessionState, Error>?
        var activeWaiterIDs: Set<UUID> = []

        init(
            operationID: UUID,
            target: RemoteSession,
            plan: DesktopOpenRequestPlan,
            localNetworkDiagnosticMode: RDPLocalNetworkDiagnosticMode
        ) {
            self.operationID = operationID
            self.target = target
            self.plan = plan
            self.localNetworkDiagnosticMode = localNetworkDiagnosticMode
        }
    }

    var desktopsBySessionID: [UUID: ActiveDesktop] = [:]
    var sessionIDByTargetID: [UUID: UUID] = [:]
    private var targetsByID: [UUID: RemoteSession] = [:]
    private var openOperationsByID: [UUID: ActiveOpenOperation] = [:]
    private var openOperationIDByTargetID: [UUID: UUID] = [:]
    private var nextLocalNetworkDiagnosticModesByTargetID:
        [UUID: LocalNetworkDiagnosticModeRequest] = [:]
    private var openIdempotencyLedger = DesktopOpenIdempotencyLedger()
    private let openOperationExecutor: OpenOperationExecutor?
    private let inputExecutor: InputExecutor?
    private let connectionPasswordProvider: ConnectionPasswordProvider?
    private let trustedReopenConnector: TrustedReopenConnector?
    private let localNetworkDiagnoser: LocalNetworkDiagnoser
    private let clipboardIsolationBarrier: ClipboardIsolationBarrier?
    private let companionMissingGracePeriod: Duration
    let grantStore: RemoteClientGrantStore
    let auditStore: RemoteCapabilityAuditStore
    private static let retainedManualFrameMetadataCount = 512
    private var aiViewingExpiryTasksByTargetID: [UUID: Task<Void, Never>] = [:]
    private var aiViewingExpiryGenerationByTargetID: [UUID: UInt64] = [:]
    private var authorityGenerationByTargetID: [UUID: UInt64] = [:]
    private var connectionAuthorityGenerationByTargetID: [UUID: UInt64] = [:]
    private var authorizedOperationsByTargetID: [UUID: [UUID: AuthorizedOperationActivity]] = [:]

    private init(
        openOperationExecutor: OpenOperationExecutor?,
        grantStore: RemoteClientGrantStore,
        auditStore: RemoteCapabilityAuditStore,
        inputExecutor: InputExecutor? = nil,
        connectionPasswordProvider: ConnectionPasswordProvider? = nil,
        trustedReopenConnector: TrustedReopenConnector? = nil,
        clipboardIsolationBarrier: ClipboardIsolationBarrier? = nil,
        companionMissingGracePeriod: Duration? = nil,
        localNetworkDiagnoser: @escaping LocalNetworkDiagnoser = { endpoint, mode in
            await RDPLocalNetworkPathDiagnostic.diagnose(
                endpoint: endpoint,
                mode: mode
            )
        }
    ) {
        self.openOperationExecutor = openOperationExecutor
        self.inputExecutor = inputExecutor
        self.connectionPasswordProvider = connectionPasswordProvider
        self.trustedReopenConnector = trustedReopenConnector
        self.clipboardIsolationBarrier = clipboardIsolationBarrier
        self.companionMissingGracePeriod =
            companionMissingGracePeriod ?? Self.defaultCompanionMissingGracePeriod
        self.localNetworkDiagnoser = localNetworkDiagnoser
        self.grantStore = grantStore
        self.auditStore = auditStore
    }

#if DEBUG
    convenience init(
        openOperationExecutorForTesting: @escaping OpenOperationExecutor,
        inputExecutorForTesting: InputExecutor? = nil,
        connectionPasswordProviderForTesting: ConnectionPasswordProvider? = nil,
        trustedReopenConnectorForTesting: TrustedReopenConnector? = nil,
        clipboardIsolationBarrierForTesting: ClipboardIsolationBarrier? = nil,
        companionMissingGracePeriodForTesting: Duration? = nil,
        localNetworkDiagnoserForTesting: LocalNetworkDiagnoser? = nil
    ) {
        self.init(
            openOperationExecutor: openOperationExecutorForTesting,
            grantStore: .shared,
            auditStore: .shared,
            inputExecutor: inputExecutorForTesting,
            connectionPasswordProvider: connectionPasswordProviderForTesting,
            trustedReopenConnector: trustedReopenConnectorForTesting,
            clipboardIsolationBarrier: clipboardIsolationBarrierForTesting,
            companionMissingGracePeriod: companionMissingGracePeriodForTesting,
            localNetworkDiagnoser: localNetworkDiagnoserForTesting ?? { endpoint, mode in
                await RDPLocalNetworkPathDiagnostic.diagnose(
                    endpoint: endpoint,
                    mode: mode
                )
            }
        )
    }

    convenience init(
        openOperationExecutorForTesting: @escaping OpenOperationExecutor,
        grantStoreForTesting: RemoteClientGrantStore
    ) {
        self.init(
            openOperationExecutor: openOperationExecutorForTesting,
            grantStore: grantStoreForTesting,
            auditStore: .shared
        )
    }

    convenience init(
        openOperationExecutorForTesting: @escaping OpenOperationExecutor,
        grantStoreForTesting: RemoteClientGrantStore,
        clipboardIsolationBarrierForTesting: @escaping ClipboardIsolationBarrier
    ) {
        self.init(
            openOperationExecutor: openOperationExecutorForTesting,
            grantStore: grantStoreForTesting,
            auditStore: .shared,
            clipboardIsolationBarrier: clipboardIsolationBarrierForTesting
        )
    }

    convenience init(
        openOperationExecutorForTesting: @escaping OpenOperationExecutor,
        grantStoreForTesting: RemoteClientGrantStore,
        auditStoreForTesting: RemoteCapabilityAuditStore
    ) {
        self.init(
            openOperationExecutor: openOperationExecutorForTesting,
            grantStore: grantStoreForTesting,
            auditStore: auditStoreForTesting
        )
    }

    var activeOpenOperationCountForTesting: Int {
        openOperationsByID.count
    }

    var activeOpenWaiterCountForTesting: Int {
        openOperationsByID.values.reduce(0) {
            $0 + $1.activeWaiterIDs.count
        }
    }

    @discardableResult
    func installActiveDesktopForTesting(
        target: RemoteSession,
        phase: RDPConnectionPhase = .connected,
        hasConnectedOnce: Bool = true,
        reconnectPolicyForTesting: RDPReconnectPolicy = .standard,
        transportRouteForTesting: RDPDesktopTransportRoute = .direct
    ) -> UUID {
        register(target: target)
        let sessionID = UUID()
        let profile = target.rdpProfile
        let active = ActiveDesktop(
            target: target,
            sessionID: sessionID,
            xpc: FreeRDPXPCSession(),
            requestedPixelWidth: profile.desktopWidth,
            requestedPixelHeight: profile.desktopHeight
        )
        active.reconnectSupervisor = RDPReconnectSupervisor(
            policy: reconnectPolicyForTesting
        )
        active.transportRoute = transportRouteForTesting
        active.state.phase = phase
        active.state.runtimeAvailability = phase == .connected ? .available : .starting
        active.state.connectedAt = phase == .connected ? Date() : nil
        active.hasConnectedOnce = hasConnectedOnce
        if phase == .connected {
            active.reconnectSupervisor.markConnected()
        }
        desktopsBySessionID[sessionID] = active
        sessionIDByTargetID[target.targetID] = sessionID
        publish(active)
        return sessionID
    }

    func setPublishedDesktopErrorForTesting(
        sessionID: UUID,
        code: String,
        message: String
    ) {
        guard let active = desktopsBySessionID[sessionID],
              isCurrent(active), !active.intentionallyClosing else { return }
        active.state.lastErrorCode = code
        active.state.lastErrorMessage = message
        publish(active)
    }

    func processConnectionFailureForTesting(
        sessionID: UUID,
        failure: RDPReconnectFailure,
        allowPathDiagnosis: Bool = true
    ) {
        guard let active = desktopsBySessionID[sessionID],
              isCurrent(active), !active.intentionallyClosing else { return }
        processConnectionFailure(
            failure,
            active: active,
            allowPathDiagnosis: allowPathDiagnosis
        )
    }

    func hasLocalNetworkDiagnosticForTesting(sessionID: UUID) -> Bool {
        guard let active = desktopsBySessionID[sessionID] else { return false }
        return active.localNetworkDiagnosticTask != nil
            && active.localNetworkDiagnosticTaskID != nil
    }

    func transportRouteForTesting(sessionID: UUID) -> RDPDesktopTransportRoute? {
        desktopsBySessionID[sessionID]?.transportRoute
    }

    func localNetworkDiagnosticTaskForTesting(
        sessionID: UUID
    ) -> Task<Void, Never>? {
        desktopsBySessionID[sessionID]?.localNetworkDiagnosticTask
    }

    func pendingLocalNetworkDiagnosticModeForTesting(
        targetID: UUID
    ) -> RDPLocalNetworkDiagnosticMode? {
        if let operationID = openOperationIDByTargetID[targetID],
           let operation = openOperationsByID[operationID] {
            return operation.localNetworkDiagnosticMode
        }
        return nextLocalNetworkDiagnosticModesByTargetID[targetID]?.mode
    }

    func receiveDesktopInvalidationForTesting(
        sessionID: UUID,
        message: String
    ) {
        guard let active = desktopsBySessionID[sessionID] else { return }
        handleInvalidation(
            connectionAttemptID: active.connectionAttemptID,
            message: message,
            active: active
        )
    }

    func receiveDesktopStateForTesting(
        sessionID: UUID,
        phase: RDPConnectionPhase,
        code: String? = nil,
        message: String? = nil,
        certificate: [String: Any]? = nil,
        companionDVCConnected: Bool? = nil,
        companionDVCGeneration: UInt64? = nil,
        companionInstallerClipboardReady: Bool? = nil,
        stateRevision: UInt64? = nil,
        connectionAttemptID: UUID? = nil
    ) {
        guard let active = desktopsBySessionID[sessionID],
              isCurrent(active), !active.intentionallyClosing else { return }
        let runtimeRevision = active.revisionLedger.lastRuntimeRevision
        let nextRevision = runtimeRevision == .max
            ? 0
            : runtimeRevision + 1
        var state: [String: Any] = [
            "connectionAttemptId": (connectionAttemptID ?? active.connectionAttemptID)
                .uuidString.lowercased(),
            "phase": phase.rawValue,
            "stateRevision": stateRevision ?? nextRevision,
            "companionDVCGeneration": companionDVCGeneration
                ?? active.companionDVCGeneration
                ?? 0,
        ]
        if let code {
            state["code"] = code
        }
        if let message {
            state["message"] = message
        }
        if let certificate {
            state["certificate"] = certificate
        }
        if let companionDVCConnected {
            state["companionDVCConnected"] = companionDVCConnected
        }
        state["companionInstallerClipboardReady"] =
            companionInstallerClipboardReady
                ?? active.companionInstallerClipboardReady
        handleState(state, active: active)
    }

    func receiveDesktopCertificateForTesting(
        sessionID: UUID,
        certificate: [String: Any],
        connectionAttemptID: UUID? = nil
    ) {
        guard let active = desktopsBySessionID[sessionID],
              isCurrent(active), !active.intentionallyClosing else { return }
        var boundCertificate = certificate
        boundCertificate["connectionAttemptId"] = (connectionAttemptID ?? active.connectionAttemptID)
            .uuidString.lowercased()
        handleCertificate(boundCertificate, active: active)
    }

    @discardableResult
    func installDesktopFrameForTesting(
        sessionID: UUID,
        runtimeStateRevision: UInt64 = 1
    ) -> DesktopFrameMetadata? {
        guard let active = desktopsBySessionID[sessionID],
              isCurrent(active), !active.intentionallyClosing,
              let publishedStateRevision = active.revisionLedger.publishFrameRevision(
                  runtimeRevision: runtimeStateRevision,
                  attemptID: active.connectionAttemptID
              ) else { return nil }
        let metadata = DesktopFrameMetadata(
            sessionID: sessionID,
            stateRevision: publishedStateRevision,
            pixelWidth: active.requestedPixelWidth,
            pixelHeight: active.requestedPixelHeight
        )
        active.latestFrame = DesktopFrame(metadata: metadata, pngData: Data())
        rememberFrameMetadata(metadata, active: active)
        active.state.latestFrameID = metadata.frameID
        active.state.stateRevision = publishedStateRevision
        active.state.remotePixelWidth = metadata.pixelWidth
        active.state.remotePixelHeight = metadata.pixelHeight
        publish(active)
        return metadata
    }

    func receiveDesktopFramePixelsForTesting(
        sessionID: UUID,
        runtimeStateRevision: UInt64,
        frameID: UUID = UUID(),
        connectionAttemptID: UUID? = nil
    ) {
        guard let active = desktopsBySessionID[sessionID],
              isCurrent(active), !active.intentionallyClosing else { return }
        let width = 640
        let height = 480
        let bytesPerRow = width * 4
        handleFramePixels(
            Data(repeating: 0, count: height * bytesPerRow),
            metadata: [
                "connectionAttemptId": (connectionAttemptID ?? active.connectionAttemptID)
                    .uuidString.lowercased(),
                "frameId": frameID.uuidString,
                "stateRevision": runtimeStateRevision,
                "width": width,
                "height": height,
                "bytesPerRow": bytesPerRow,
                "capturedAt": Date().timeIntervalSince1970,
            ],
            surface: nil,
            active: active
        )
    }

    func performManualDesktopActionForTesting(
        sessionID: UUID,
        request: DesktopActionRequest
    ) async throws -> RDPDesktopSessionState {
        try await performDesktopAction(
            sessionID: sessionID,
            request: request,
            isManualInput: true
        )
    }

    func retainedFrameRevisionMappingCountForTesting(sessionID: UUID) -> Int? {
        desktopsBySessionID[sessionID]?.revisionLedger.retainedFrameMappingCount
    }

    func connectionAttemptIDForTesting(sessionID: UUID) -> UUID? {
        desktopsBySessionID[sessionID]?.connectionAttemptID
    }

    func isClipboardSuspendedForAIForTesting(targetID: UUID) -> Bool {
        guard let sessionID = sessionIDByTargetID[targetID] else { return false }
        return desktopsBySessionID[sessionID]?.clipboardSuspendedForAI ?? false
    }

    func setCompanionAvailabilityForTesting(
        sessionID: UUID,
        availability: WindowsCompanionAvailability
    ) {
        guard let active = desktopsBySessionID[sessionID] else { return }
        active.state.companion = WindowsCompanionState(availability: availability)
        publish(active)
    }

    func hasCompanionHandshakeTaskForTesting(sessionID: UUID) -> Bool {
        desktopsBySessionID[sessionID]?.companionHandshakeTask != nil
    }

    func hasCompanionMissingTaskForTesting(sessionID: UUID) -> Bool {
        desktopsBySessionID[sessionID]?.companionMissingTask != nil
    }

    func companionMissingTaskForTesting(sessionID: UUID) -> Task<Void, Never>? {
        desktopsBySessionID[sessionID]?.companionMissingTask
    }

    func companionChannelIDForTesting(sessionID: UUID) -> UUID? {
        desktopsBySessionID[sessionID]?.companionChannelID
    }

    func companionDVCGenerationForTesting(sessionID: UUID) -> UInt64? {
        desktopsBySessionID[sessionID]?.companionDVCGeneration
    }

    func invalidateDesktopConnectionForTesting(
        sessionID: UUID,
        connectionAttemptID: UUID? = nil,
        code: String = "RDP_XPC_INVALIDATED"
    ) {
        guard let active = desktopsBySessionID[sessionID],
              isCurrent(active), !active.intentionallyClosing,
              active.connectionAttemptID == (connectionAttemptID ?? active.connectionAttemptID) else { return }
        scheduleReconnect(
            active: active,
            failure: RDPReconnectFailure(
                phase: active.state.phase,
                code: code,
                message: "The test XPC connection was invalidated."
            ),
            runtimeUnavailable: true
        )
    }

    func invalidateOpenDesktopForTesting(sessionID: UUID) {
        guard let active = desktopsBySessionID[sessionID],
              isCurrent(active), !active.intentionallyClosing else { return }
        invalidateOpenDesktop(
            active,
            code: "RDP_OPEN_CANCELLED",
            message: "The desktop open operation was cancelled."
        )
    }
#endif

    func supports(target: RemoteTargetDescriptor) -> Bool {
        target.connectionType == .rdp
    }

    func capabilities(for target: RemoteTargetDescriptor) -> Set<RemoteCapability> {
        guard supports(target: target) else { return [] }
        return target.configuredCapabilities
    }

    func register(target: RemoteSession) {
        guard target.connectionType == .rdp else { return }
        targetsByID[target.targetID] = target
    }

    func state(for targetID: UUID) -> RDPDesktopSessionState? {
        statesByTargetID[targetID]
    }

    func image(for targetID: UUID) -> NSImage? {
        imagesByTargetID[targetID]
    }

    func sessionID(for targetID: UUID) -> UUID? {
        sessionIDByTargetID[targetID]
    }

    func sessionID(for target: RemoteSession) -> UUID? {
        guard let sessionID = sessionIDByTargetID[target.targetID],
              desktopsBySessionID[sessionID]?.targetBinding
                == target.mcpGrantTargetBinding else {
            return nil
        }
        return sessionID
    }

    func sessionMatchesTarget(sessionID: UUID, target: RemoteSession) -> Bool {
        desktopsBySessionID[sessionID]?.targetBinding == target.mcpGrantTargetBinding
    }

    var runningDesktopSummaries: [String] {
        desktopsBySessionID.values
            .filter { $0.state.phase != .closed && $0.state.phase != .failed }
            .map { "\($0.target.name) — \($0.target.host):\($0.target.port)" }
            .sorted()
    }

    func stopAllImmediately() {
        uiaObservations.removeAll()
        let openOperations = Array(openOperationsByID.values)
        let activeDesktops = Array(desktopsBySessionID.values)
        let affectedTargetIDs = Set(
            openOperations.map { $0.target.targetID } +
                activeDesktops.map { $0.target.targetID }
        )
        for targetID in affectedTargetIDs {
            invalidateAllAIAuthority(targetID: targetID)
        }
        for operation in openOperations {
            operation.executionTask?.cancel()
            operation.resultTask?.cancel()
        }
        openOperationsByID.removeAll()
        openOperationIDByTargetID.removeAll()
        openIdempotencyLedger.removeAll()
        nextLocalNetworkDiagnosticModesByTargetID.removeAll()

        for active in activeDesktops {
            active.intentionallyClosing = true
            active.relayBridge?.stop(); active.relayBridge = nil
            stopClipboardSync(active, discardSynchronizer: true)
            active.reconnectSupervisor.stop()
            active.reconnectTask?.cancel()
            active.reconnectTask = nil
            active.reconnectTaskID = nil
            cancelLocalNetworkDiagnostic(active)
            cancelCompanionMissingTask(active)
            active.companionHandshakeTask?.cancel()
            active.companionAuthorizationTask?.cancel()
            active.companionInstallationCancellationState = .idle
            active.companionInstallationTask?.cancel()
            active.companionInstallationTask = nil
            active.companionInstallationTaskID = nil
            active.companionChannelID = nil
            active.companion?.cancelAll()
            active.xpc.invalidateImmediately()
            var closed = active.state
            closed.phase = .closed
            closed.companion = .unknown
            closed.reconnectAttempt = nil
            closed.reconnectMaximumAttempts = nil
            closed.reconnectScheduledAt = nil
            statesByTargetID[active.target.targetID] = closed
        }
        desktopsBySessionID.removeAll()
        sessionIDByTargetID.removeAll()
        certificateChallengesByTargetID.removeAll()
        companionPairingByTargetID.removeAll()
        companionDelegationExportsByTargetID.removeAll()
        companionInstallationStatesByTargetID.removeAll()
        imagesByTargetID.removeAll()
        clearAllAIActivityState()
    }

    func presentation(for target: RemoteSession) -> RDPDesktopWorkspacePresentation {
        #if JTS_UI_TEST_SUPPORT
        if let fixturePresentation = UITestRDPFixtureEnvironment.presentation(
            for: target
        ) {
            return fixturePresentation
        }
        #endif

        register(target: target)
        let targetID = target.targetID
        let companionInstallation =
            companionInstallationStatesByTargetID[targetID] ?? .idle
        let activeDesktop = sessionIDByTargetID[targetID].flatMap {
            desktopsBySessionID[$0]
        }
        let canInstallCompanion =
            activeDesktop.map {
                isCurrent($0) &&
                    !$0.intentionallyClosing &&
                    $0.state.phase == .connected &&
                    $0.state.companion.availability == .missing &&
                    $0.target.rdpProfile.clipboardEnabled &&
                    $0.companionInstallerClipboardReady &&
                    $0.companionInstallationTaskID == nil &&
                    companionInstallation.canOfferInstallation
            } ?? false
        let now = Date()
        let inFlightActivities = authorizedOperationsByTargetID[targetID].map {
            Array($0.values)
        } ?? []
        let inFlightControlActivities = inFlightActivities.filter {
            $0.token.showsControlActivity
        }
        let activeInFlightControlActivities = inFlightControlActivities.filter {
            isCurrentAuthorizedOperation($0.token)
        }
        let stoppingInFlightControlActivities = inFlightControlActivities.filter {
            !isCurrentAuthorizedOperation($0.token)
        }
        let inFlightViewingActivities = inFlightActivities.filter {
            $0.token.showsViewingActivity
        }
        let hasActiveControl = !activeInFlightControlActivities.isEmpty
        let isAIControlStopping = !stoppingInFlightControlActivities.isEmpty
        let viewingIdentities = aiViewingActivityByTargetID[targetID]
            .map { activities in
                activities
                    .filter { $0.value.expiresAt > now }
                    .map {
                        RDPActiveAIClientIdentity(
                            authorizationID: $0.key,
                            displayIdentity: $0.value.displayIdentity
                        )
                    }
                    .sorted(by: Self.sortAIClientIdentities)
            } ?? []
        var identitiesByAuthorizationID = Dictionary(
            uniqueKeysWithValues: viewingIdentities.map {
                ($0.authorizationID, $0)
            }
        )
        for activity in inFlightViewingActivities {
            identitiesByAuthorizationID[activity.token.clientID] = RDPActiveAIClientIdentity(
                authorizationID: activity.token.clientID,
                displayIdentity: activity.displayIdentity
            )
        }
        for activity in inFlightControlActivities {
            identitiesByAuthorizationID[activity.token.clientID] = RDPActiveAIClientIdentity(
                authorizationID: activity.token.clientID,
                displayIdentity: activity.displayIdentity,
                isControlling: true
            )
        }
        let activeAIClientIdentities = identitiesByAuthorizationID.values.sorted {
            if $0.isControlling != $1.isControlling {
                return $0.isControlling && !$1.isControlling
            }
            return Self.sortAIClientIdentities($0, $1)
        }
        return RDPDesktopWorkspacePresentation(
            state: statesByTargetID[targetID],
            frameImage: imagesByTargetID[targetID],
            certificateChallenge: certificateChallengesByTargetID[targetID],
            companionPairing: companionPairingByTargetID[targetID],
            companionDelegation: CompanionPairingDelegationStore.shared.grants.last { $0.targetID == targetID },
            companionDelegationExport: companionDelegationExportsByTargetID[targetID],
            companionIdentity: currentCompanionIdentity(targetID: targetID),
            companionInstallation: companionInstallation,
            isCompanionInstallerClipboardReady:
                activeDesktop?.companionInstallerClipboardReady ?? false,
            isAIViewing: !viewingIdentities.isEmpty || !inFlightViewingActivities.isEmpty,
            isAIControlActive: hasActiveControl,
            isAIControlStopping: isAIControlStopping,
            activeAIClientIdentities: activeAIClientIdentities,
            connect: { [weak self, weak target] in
                guard let self, let target else { return }
                Task { @MainActor in
                    let diagnosticModeRequestID: UUID?
                    if self.statesByTargetID[targetID]?.isLocalNetworkDecisionPending == true {
                        let requestID = UUID()
                        self.nextLocalNetworkDiagnosticModesByTargetID[targetID] =
                            LocalNetworkDiagnosticModeRequest(
                                requestID: requestID,
                                mode: .confirmedRecheck
                            )
                        diagnosticModeRequestID = requestID
                    } else {
                        self.nextLocalNetworkDiagnosticModesByTargetID.removeValue(
                            forKey: targetID
                        )
                        diagnosticModeRequestID = nil
                    }
                    defer {
                        if let diagnosticModeRequestID,
                           self.nextLocalNetworkDiagnosticModesByTargetID[targetID]?
                            .requestID == diagnosticModeRequestID {
                            self.nextLocalNetworkDiagnosticModesByTargetID.removeValue(
                                forKey: targetID
                            )
                        }
                    }
                    do {
                        if self.statesByTargetID[targetID]?.phase == .awaitingCertificateTrust,
                           self.certificateChallengesByTargetID[targetID] == nil {
                            await self.close(targetID: targetID)
                        }
                        _ = try await self.open(target: target)
                    } catch {
                        self.publishFailure(target: target, error: error)
                    }
                }
            },
            disconnect: { [weak self] in
                Task { @MainActor in
                    await self?.close(targetID: targetID)
                }
            },
            takeManualControl: { [weak self] in
                self?.takeManualControl(targetID: targetID)
            },
            emergencyStop: { [weak self] in
                Task { @MainActor in
                    await self?.emergencyStop(targetID: targetID)
                }
            },
            trustCertificateOnce: { [weak self] in
                guard let self else {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "The RDP session ended before the certificate decision could be applied."
                    )
                }
                try await self.trustCertificate(targetID: targetID, persistPin: false)
            },
            pinCertificate: { [weak self] in
                guard let self else {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "The RDP session ended before the certificate decision could be applied."
                    )
                }
                try await self.trustCertificate(targetID: targetID, persistPin: true)
            },
            approveCompanionPairing: { [weak self] in
                try? self?.approveCompanionPairing(targetID: targetID)
            },
            confirmDelegatedPairing: { [weak self] in
                guard let self, let sessionID = self.sessionID(for: targetID) else { return }
                _ = try await self.confirmDelegatedCompanionPairing(sessionID: sessionID)
            },
            revokeDelegatedPairing: { [weak self] in
                guard let self, let sessionID = self.sessionID(for: targetID) else { return }
                _ = try await self.revokeCompanionDelegation(sessionID: sessionID)
            },
            restoreDelegatedPairing: { [weak self] in
                try await self?.restoreCompanionDelegation(targetID: targetID)
            },
            unpairCompanion: WindowsCompanionUnpairAction { [weak self] in
                guard let self else {
                    throw WindowsCompanionRequestFailure(
                        code: "COMPANION_DISCONNECTED",
                        message: "The RDP desktop session closed.",
                        retryable: true
                    )
                }
                try await self.unpairCompanion(targetID: targetID)
            },
            installCompanion: canInstallCompanion ? { [weak self] in
                self?.startCompanionInstallation(targetID: targetID)
            } : nil,
            performManualAction: { [weak self] request in
                Task { @MainActor in
                    guard let self,
                          let sessionID = self.sessionID(for: targetID),
                          let active = self.desktopsBySessionID[sessionID],
                          self.isCurrent(active), !active.intentionallyClosing else { return }
                    let connectionAttemptID = active.connectionAttemptID
                    let inputFailureGeneration = active.inputFailureGeneration
                    self.takeManualControl(targetID: targetID)
                    do {
                        if Self.isClipboardPasteRequest(request) {
                            try await self.prepareManualClipboardPaste(active)
                        }
                        _ = try await self.performDesktopAction(
                            sessionID: sessionID,
                            request: request,
                            isManualInput: true
                        )
                        self.clearPublishedInputFailure(
                            active: active,
                            matchingGeneration: inputFailureGeneration
                        )
                    } catch {
                        self.publishInputFailure(
                            active: active,
                            expectedConnectionAttemptID: connectionAttemptID,
                            error: error
                        )
                    }
                }
            },
            resizeDesktop: { [weak self] width, height in
                Task { @MainActor in
                    await self?.resizeDesktop(targetID: targetID, width: width, height: height)
                }
            },
            openLocalNetworkSettings: {
                RDPLocalNetworkSystemSettings.open()
            }
        )
    }

    func resizeDesktop(targetID: UUID, width: Int, height: Int) async {
        guard let sessionID = sessionIDByTargetID[targetID],
              let active = desktopsBySessionID[sessionID] else { return }
        let connectionAttemptID = active.connectionAttemptID
        guard (try? requireCurrentConnectedActionAttempt(
            active,
            expectedConnectionAttemptID: connectionAttemptID
        )) != nil else { return }
        let inputFailureGeneration = active.inputFailureGeneration
        let input: [String: Any] = [
            "type": "resize",
            "width": min(max(width, 640), 7_680),
            "height": min(max(height, 480), 4_320),
        ]
        do {
            if let inputExecutor {
                try await inputExecutor(input, nil)
            } else {
                try await active.xpc.sendInput(input)
            }
            guard (try? requireCurrentConnectedActionAttempt(
                active,
                expectedConnectionAttemptID: connectionAttemptID
            )) != nil else { return }
            clearPublishedInputFailure(
                active: active,
                matchingGeneration: inputFailureGeneration
            )
        } catch {
            publishInputFailure(
                active: active,
                expectedConnectionAttemptID: connectionAttemptID,
                error: error
            )
        }
    }

    func open(target: RemoteSession, request: DesktopOpenRequest = DesktopOpenRequest()) async throws -> RDPDesktopSessionState {
        register(target: target)
        let state = try await openDesktop(target: target.remoteTargetDescriptor, request: request)
        // Presentation belongs to each caller, including callers reusing a live
        // session. It must not be inherited from the first single-flight opener.
        NotificationCenter.default.post(name: .jtsRDPDesktopRequested, object: nil,
            userInfo: ["targetId": target.targetID.uuidString.lowercased(),
                       "sessionId": state.sessionID.uuidString.lowercased(),
                       "activate": request.activateWindow ?? true])
        return state
    }

    func openDesktop(
        target descriptor: RemoteTargetDescriptor,
        request: DesktopOpenRequest
    ) async throws -> RDPDesktopSessionState {
        guard descriptor.connectionType == .rdp,
              let target = targetsByID[descriptor.targetID] else {
            throw WindowsMCPToolError(
                code: .targetNotFound,
                message: "The RDP target is not registered in the visible JTS Terminal workspace."
            )
        }

        let plan: DesktopOpenRequestPlan
        do {
            plan = try DesktopOpenRequestPolicy.plan(
                request: request,
                profile: target.rdpProfile,
                targetBinding: target.mcpGrantTargetBinding
            )
        } catch let failure as DesktopOpenRequestValidationFailure {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: failure.localizedDescription
            )
        }
        try ensureDeadlineRemaining(plan)

        let nowUptime = ProcessInfo.processInfo.systemUptime
        let idempotencyScope = plan.idempotencyKeyDigest.map {
            DesktopOpenIdempotencyScope(
                targetID: target.targetID,
                clientID: plan.idempotencyClientID,
                keyDigest: $0
            )
        }
        if let idempotencyScope {
            do {
                if let outcome = try openIdempotencyLedger.lookup(
                    scope: idempotencyScope,
                    signature: plan.signature,
                    nowUptime: nowUptime
                ) {
                    switch outcome {
                    case .pending(let operationID):
                        if let operation = openOperationsByID[operationID] {
                            return try await awaitOpenOperation(
                                operation,
                                waiterPlan: plan
                            )
                        }
                        openIdempotencyLedger.discardPending(
                            scope: idempotencyScope,
                            operationID: operationID
                        )
                    case .success(let state):
                        if let current = desktopsBySessionID[state.sessionID],
                           current.targetBinding == plan.signature.targetBinding {
                            return current.state
                        }
                        if let published = statesByTargetID[state.targetID],
                           published.sessionID == state.sessionID {
                            return published
                        }
                        return state
                    case .failure(let failure):
                        throw restoredOpenFailure(failure)
                    }
                }
            } catch is DesktopOpenIdempotencyConflict {
                throw WindowsMCPToolError(
                    code: .idempotencyConflict,
                    message: "The idempotencyKey was already used for different desktop parameters or target configuration.",
                    details: ["retryable": false]
                )
            }
        }

        if let operationID = openOperationIDByTargetID[target.targetID],
           let operation = openOperationsByID[operationID] {
            if operation.plan.signature != plan.signature {
                throw WindowsMCPToolError(
                    code: .stateConflict,
                    message: "Another desktop open for this target is already using different desktop parameters or target configuration.",
                    details: ["retryable": true]
                )
            }
            if let idempotencyScope {
                do {
                    _ = try openIdempotencyLedger.reserve(
                        scope: idempotencyScope,
                        signature: plan.signature,
                        operationID: operation.operationID,
                        nowUptime: nowUptime
                    )
                } catch is DesktopOpenIdempotencyConflict {
                    throw WindowsMCPToolError(
                        code: .idempotencyConflict,
                        message: "The idempotencyKey was already used for different desktop parameters or target configuration.",
                        details: ["retryable": false]
                    )
                } catch is DesktopOpenIdempotencyCapacityExceeded {
                    throw desktopOpenCapacityError()
                }
            }
            return try await awaitOpenOperation(
                operation,
                waiterPlan: plan
            )
        }

        if let existingID = sessionIDByTargetID[target.targetID],
           let existing = desktopsBySessionID[existingID],
           existing.targetBinding == plan.signature.targetBinding,
           !existing.intentionallyClosing,
           existing.state.phase != .failed,
           existing.state.phase != .closed {
            if let idempotencyScope {
                do {
                    try openIdempotencyLedger.storeImmediateSuccess(
                        scope: idempotencyScope,
                        signature: plan.signature,
                        state: existing.state,
                        nowUptime: nowUptime
                    )
                } catch is DesktopOpenIdempotencyConflict {
                    throw WindowsMCPToolError(
                        code: .idempotencyConflict,
                        message: "The idempotencyKey was already used for different desktop parameters or target configuration.",
                        details: ["retryable": false]
                    )
                } catch is DesktopOpenIdempotencyCapacityExceeded {
                    throw desktopOpenCapacityError()
                }
            }
            return existing.state
        }

        let localNetworkDiagnosticMode =
            nextLocalNetworkDiagnosticModesByTargetID.removeValue(
                forKey: target.targetID
            )?.mode ?? .initial
        let operation = ActiveOpenOperation(
            operationID: UUID(),
            target: target,
            plan: plan,
            localNetworkDiagnosticMode: localNetworkDiagnosticMode
        )
        if let idempotencyScope {
            do {
                _ = try openIdempotencyLedger.reserve(
                    scope: idempotencyScope,
                    signature: plan.signature,
                    operationID: operation.operationID,
                    nowUptime: nowUptime
                )
            } catch is DesktopOpenIdempotencyConflict {
                throw WindowsMCPToolError(
                    code: .idempotencyConflict,
                    message: "The idempotencyKey was already used for different desktop parameters or target configuration.",
                    details: ["retryable": false]
                )
            } catch is DesktopOpenIdempotencyCapacityExceeded {
                throw desktopOpenCapacityError()
            }
        }
        openOperationsByID[operation.operationID] = operation
        openOperationIDByTargetID[target.targetID] = operation.operationID
        operation.resultTask = Task { @MainActor [weak self, weak operation] in
            guard let self, let operation else { throw CancellationError() }
            return try await self.runOpenOperation(operation)
        }
        return try await awaitOpenOperation(
            operation,
            waiterPlan: plan
        )
    }

    private func awaitOpenOperation(
        _ operation: ActiveOpenOperation,
        waiterPlan: DesktopOpenRequestPlan
    ) async throws -> RDPDesktopSessionState {
        guard let resultTask = operation.resultTask else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: "The desktop open operation did not initialize."
            )
        }

        let remainingMilliseconds = waiterPlan.remainingMilliseconds(
            at: ProcessInfo.processInfo.systemUptime
        )
        guard remainingMilliseconds > 0 else {
            throw desktopOpenDeadlineError(plan: waiterPlan)
        }
        guard operation.activeWaiterIDs.count < ActiveOpenOperation.maximumJoinedWaiters else {
            throw desktopOpenCapacityError()
        }

        let waiterID = UUID()
        let coordinator = XPCRequestCoordinator()
        operation.activeWaiterIDs.insert(waiterID)
        do {
            let state: RDPDesktopSessionState = try await coordinator.perform(
                deadlineSeconds: TimeInterval(remainingMilliseconds) / 1_000
            ) { completion in
                Task { @MainActor in
                    completion(await resultTask.result)
                }
            }
            operation.activeWaiterIDs.remove(waiterID)
            return state
        } catch is XPCRequestTimeoutFailure {
            // The operation and its owner can reach the same absolute deadline
            // through separate coordinators. If the waiter is not earlier than
            // the operation, let the operation publish its canonical result
            // and idempotency tombstone before returning. Only an earlier
            // joiner deadline is independent.
            if waiterPlan.deadlineUptime >= operation.plan.deadlineUptime {
                do {
                    let state = try await resultTask.value
                    operation.activeWaiterIDs.remove(waiterID)
                    return state
                } catch {
                    operation.activeWaiterIDs.remove(waiterID)
                    throw error
                }
            }
            cancelOpenWaiter(
                operation,
                waiterID: waiterID
            )
            throw desktopOpenDeadlineError(plan: waiterPlan)
        } catch is CancellationError {
            cancelOpenWaiter(
                operation,
                waiterID: waiterID
            )
            throw CancellationError()
        } catch {
            operation.activeWaiterIDs.remove(waiterID)
            throw error
        }
    }

    private func cancelOpenWaiter(
        _ operation: ActiveOpenOperation,
        waiterID: UUID
    ) {
        guard operation.activeWaiterIDs.remove(waiterID) != nil,
              operation.activeWaiterIDs.isEmpty,
              openOperationsByID[operation.operationID] === operation else {
            return
        }
        operation.executionTask?.cancel()
        operation.resultTask?.cancel()
        operation.deadlineCoordinator.failAll(CancellationError())
    }

    private func runOpenOperation(
        _ operation: ActiveOpenOperation
    ) async throws -> RDPDesktopSessionState {
        defer { finalizeOpenOperation(operation) }
        do {
            let remainingMilliseconds = operation.plan.remainingMilliseconds(
                at: ProcessInfo.processInfo.systemUptime
            )
            guard remainingMilliseconds > 0 else {
                throw desktopOpenDeadlineError(plan: operation.plan)
            }

            let state: RDPDesktopSessionState = try await operation.deadlineCoordinator.perform(
                deadlineSeconds: TimeInterval(remainingMilliseconds) / 1_000
            ) { [weak self, weak operation] completion in
                guard let self, let operation else {
                    completion(.failure(CancellationError()))
                    return
                }
                let executionTask = Task { @MainActor in
                    try await self.performOpenOperation(operation)
                }
                operation.executionTask = executionTask
                Task { @MainActor in
                    completion(await executionTask.result)
                }
            }
            openIdempotencyLedger.complete(
                operationID: operation.operationID,
                outcome: .success(state)
            )
            return state
        } catch is XPCRequestTimeoutFailure {
            let failure = desktopOpenDeadlineError(plan: operation.plan)
            operation.executionTask?.cancel()
            abortOpenOperation(operation, failure: failure)
            openIdempotencyLedger.complete(
                operationID: operation.operationID,
                outcome: .failure(storedOpenFailure(failure))
            )
            throw failure
        } catch let failure as WindowsMCPToolError where failure.code == .deadlineExceeded {
            operation.executionTask?.cancel()
            abortOpenOperation(operation, failure: failure)
            openIdempotencyLedger.complete(
                operationID: operation.operationID,
                outcome: .failure(storedOpenFailure(failure))
            )
            throw failure
        } catch is CancellationError {
            operation.executionTask?.cancel()
            let failure = WindowsMCPToolError(
                code: .runtimeFailure,
                message: "The desktop open operation was cancelled.",
                details: [
                    "machineCode": "RDP_OPEN_CANCELLED",
                    "retryable": true,
                ]
            )
            abortOpenOperation(operation, failure: failure)
            openIdempotencyLedger.complete(
                operationID: operation.operationID,
                outcome: .failure(storedOpenFailure(failure))
            )
            throw failure
        } catch {
            let failure = normalizedOpenFailure(error)
            openIdempotencyLedger.complete(
                operationID: operation.operationID,
                outcome: .failure(storedOpenFailure(failure))
            )
            throw failure
        }
    }

    private func performOpenOperation(
        _ operation: ActiveOpenOperation
    ) async throws -> RDPDesktopSessionState {
        let target = operation.target
        try ensureOpenOperationCurrent(operation)

        // Every open path for a target joins the registered single flight. A
        // live session can still appear through a manual trust flow, so honor
        // it instead of replacing it after a suspension point.
        if let existingID = sessionIDByTargetID[target.targetID],
           let existing = desktopsBySessionID[existingID],
           existing.targetBinding == operation.plan.signature.targetBinding,
           !existing.intentionallyClosing,
           existing.state.phase != .failed,
           existing.state.phase != .closed {
            return existing.state
        }

        if let existingID = sessionIDByTargetID[target.targetID],
           let existing = desktopsBySessionID[existingID] {
            await close(active: existing)
            try ensureOpenOperationCurrent(operation)
        }

        if let openOperationExecutor {
            let state = try await openOperationExecutor(
                target,
                operation.plan,
                operation.operationID
            )
            try ensureOpenOperationCurrent(operation)
            return state
        }
        try target.rdpProfile.validateForConnection()
        let password = try await connectionPassword(for: target, migrateLegacyCredential: true)
        try ensureOpenOperationCurrent(operation)

        let sessionID = UUID()
        let xpc = FreeRDPXPCSession()
        let active = ActiveDesktop(
            target: target,
            targetBinding: operation.plan.signature.targetBinding,
            sessionID: sessionID,
            xpc: xpc,
            openOperationID: operation.operationID,
            requestedPixelWidth: operation.plan.signature.pixelWidth,
            requestedPixelHeight: operation.plan.signature.pixelHeight
        )
        active.localNetworkDiagnosticMode = operation.localNetworkDiagnosticMode
        desktopsBySessionID[sessionID] = active
        sessionIDByTargetID[target.targetID] = sessionID
        publish(active)
        wireCallbacks(for: active)
        let initialConnectionAttemptID = active.connectionAttemptID

        do {
            let remainingMilliseconds = operation.plan.remainingMilliseconds(
                at: ProcessInfo.processInfo.systemUptime
            )
            guard remainingMilliseconds > 0 else {
                throw desktopOpenDeadlineError(plan: operation.plan)
            }
            try await connectTransport(for: active,
                configuration: try connectionConfiguration(for: active, password: password),
                deadlineMilliseconds: remainingMilliseconds
            )
            try ensureOpenOperationCurrent(operation)
            if let supersedingState = stateForSupersededOpenAttempt(
                active,
                expectedConnectionAttemptID: initialConnectionAttemptID
            ) {
                return supersedingState
            }
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == initialConnectionAttemptID else {
                xpc.invalidateImmediately()
                throw CancellationError()
            }
            active.state.runtimeAvailability = .available
            publish(active)
            return active.state
        } catch is CancellationError {
            if let supersedingState = stateForSupersededOpenAttempt(
                active,
                expectedConnectionAttemptID: initialConnectionAttemptID
            ) {
                return supersedingState
            }
            if isCurrent(active), targetBindingIsCurrent(active),
               !active.intentionallyClosing,
               active.connectionAttemptID == initialConnectionAttemptID {
                invalidateOpenDesktop(active, code: "RDP_OPEN_CANCELLED", message: "The desktop open operation was cancelled.")
            } else {
                xpc.invalidateImmediately()
            }
            throw CancellationError()
        } catch let failure as WindowsMCPToolError where failure.code == .deadlineExceeded {
            if let supersedingState = stateForSupersededOpenAttempt(
                active,
                expectedConnectionAttemptID: initialConnectionAttemptID
            ) {
                return supersedingState
            }
            if isCurrent(active), targetBindingIsCurrent(active),
               !active.intentionallyClosing,
               active.connectionAttemptID == initialConnectionAttemptID {
                invalidateOpenDesktop(
                    active,
                    code: "RDP_OPEN_DEADLINE_EXCEEDED",
                    message: failure.message
                )
            } else {
                xpc.invalidateImmediately()
            }
            throw failure
        } catch {
            if let supersedingState = stateForSupersededOpenAttempt(
                active,
                expectedConnectionAttemptID: initialConnectionAttemptID
            ) {
                return supersedingState
            }
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == initialConnectionAttemptID else {
                xpc.invalidateImmediately()
                throw CancellationError()
            }
            if operation.plan.remainingMilliseconds(
                at: ProcessInfo.processInfo.systemUptime
            ) == 0 {
                let failure = desktopOpenDeadlineError(plan: operation.plan)
                invalidateOpenDesktop(
                    active,
                    code: "RDP_OPEN_DEADLINE_EXCEEDED",
                    message: failure.message
                )
                throw failure
            }
            if let xpcFailure = error as? FreeRDPXPCFailure,
               xpcFailure.code == XPCRequestTimeoutFailure.errorCode {
                let failure = normalizedOpenFailure(xpcFailure)
                invalidateOpenDesktop(
                    active,
                    code: xpcFailure.code,
                    message: failure.message
                )
                throw failure
            }
            let failure = reconnectFailure(from: error, phase: .failed)
            scheduleReconnect(active: active, failure: failure, runtimeUnavailable: true)
            if active.reconnectSupervisor.hasPendingAttempt {
                return active.state
            }
            active.state.phase = .failed
            active.state.runtimeAvailability = .unavailable
            active.state.lastErrorCode = failure.code
            active.state.lastErrorMessage = failure.message
            publish(active)
            throw normalizedOpenFailure(error)
        }
    }

    /// An open/reopen connect and its invalidation callback complete on
    /// separate asynchronous paths. If invalidation already retired attempt A
    /// and installed reconnect attempt B, A's late reply is observational only:
    /// it must neither publish success nor tear down or reschedule B.
    private func stateForSupersededOpenAttempt(
        _ active: ActiveDesktop,
        expectedConnectionAttemptID: UUID
    ) -> RDPDesktopSessionState? {
        guard isCurrent(active),
              targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.connectionAttemptID != expectedConnectionAttemptID else {
            return nil
        }
        return active.state
    }

#if DEBUG
    func stateForSupersededOpenAttemptForTesting(
        sessionID: UUID,
        expectedConnectionAttemptID: UUID
    ) -> RDPDesktopSessionState? {
        guard let active = desktopsBySessionID[sessionID] else { return nil }
        return stateForSupersededOpenAttempt(
            active,
            expectedConnectionAttemptID: expectedConnectionAttemptID
        )
    }
#endif

    private func ensureOpenOperationCurrent(_ operation: ActiveOpenOperation) throws {
        try Task.checkCancellation()
        guard openOperationIDByTargetID[operation.target.targetID] == operation.operationID,
              openOperationsByID[operation.operationID] === operation,
              targetsByID[operation.target.targetID]?.mcpGrantTargetBinding
                == operation.plan.signature.targetBinding else {
            throw CancellationError()
        }
        try ensureDeadlineRemaining(operation.plan)
    }

    private func ensureDeadlineRemaining(_ plan: DesktopOpenRequestPlan) throws {
        guard plan.remainingMilliseconds(at: ProcessInfo.processInfo.systemUptime) > 0 else {
            throw desktopOpenDeadlineError(plan: plan)
        }
    }

    private func desktopOpenDeadlineError(
        plan: DesktopOpenRequestPlan
    ) -> WindowsMCPToolError {
        WindowsMCPToolError(
            code: .deadlineExceeded,
            message: "The desktop open request exceeded its \(plan.deadlineMilliseconds) millisecond deadline.",
            details: [
                "machineCode": "RDP_OPEN_DEADLINE_EXCEEDED",
                "retryable": true,
            ]
        )
    }

    private func desktopOpenCapacityError() -> WindowsMCPToolError {
        WindowsMCPToolError(
            code: .stateConflict,
            message: "The in-flight desktop open has too many waiting requests. Retry after it finishes.",
            details: [
                "machineCode": "RDP_OPEN_CAPACITY_EXCEEDED",
                "retryable": true,
            ]
        )
    }

    private func finalizeOpenOperation(_ operation: ActiveOpenOperation) {
        if openOperationIDByTargetID[operation.target.targetID] == operation.operationID {
            openOperationIDByTargetID.removeValue(forKey: operation.target.targetID)
        }
        if openOperationsByID[operation.operationID] === operation {
            openOperationsByID.removeValue(forKey: operation.operationID)
        }
    }

    private func abortOpenOperation(
        _ operation: ActiveOpenOperation,
        failure: WindowsMCPToolError
    ) {
        guard let sessionID = sessionIDByTargetID[operation.target.targetID],
              let active = desktopsBySessionID[sessionID],
              active.openOperationID == operation.operationID else {
            return
        }
        invalidateOpenDesktop(
            active,
            code: failure.details["machineCode"] as? String ?? failure.code.rawValue,
            message: failure.message
        )
    }

    private func invalidateOpenDesktop(
        _ active: ActiveDesktop,
        code: String,
        message: String
    ) {
        invalidateConnectionBoundAuthority(
            for: active,
            connectionAttemptID: active.connectionAttemptID
        )
        discardDesktopFrameState(active)
        active.intentionallyClosing = true
        active.relayBridge?.stop(); active.relayBridge = nil
        stopClipboardSync(active, discardSynchronizer: true)
        active.reconnectSupervisor.stop()
        active.reconnectTask?.cancel()
        active.reconnectTask = nil
        active.reconnectTaskID = nil
        cancelLocalNetworkDiagnostic(active)
        cancelCompanionMissingTask(active)
        active.companionHandshakeTask?.cancel()
        active.companionAuthorizationTask?.cancel()
        active.companionChannelID = nil
        active.companion?.cancelAll()
        active.xpc.invalidateImmediately()
        if desktopsBySessionID[active.sessionID] === active {
            desktopsBySessionID.removeValue(forKey: active.sessionID)
        }
        if sessionIDByTargetID[active.target.targetID] == active.sessionID {
            sessionIDByTargetID.removeValue(forKey: active.target.targetID)
        }
        certificateChallengesByTargetID.removeValue(forKey: active.target.targetID)
        companionPairingByTargetID.removeValue(forKey: active.target.targetID)
        companionDelegationExportsByTargetID.removeValue(forKey: active.target.targetID)
        imagesByTargetID.removeValue(forKey: active.target.targetID)
        var failed = active.state
        failed.phase = .failed
        failed.runtimeAvailability = .unavailable
        failed.companion = .unknown
        failed.reconnectAttempt = nil
        failed.reconnectMaximumAttempts = nil
        failed.reconnectScheduledAt = nil
        failed.lastErrorCode = code
        failed.lastErrorMessage = message
        statesByTargetID[active.target.targetID] = failed
    }

    private func normalizedOpenFailure(_ error: Error) -> WindowsMCPToolError {
        if let failure = error as? WindowsMCPToolError {
            return failure
        }
        if error is RDPProfileValidationError {
            return WindowsMCPToolError(
                code: .invalidArgument,
                message: error.localizedDescription,
                details: [
                    "machineCode": "RDP_PROFILE_INVALID",
                    "retryable": false,
                ]
            )
        }
        if let failure = error as? FreeRDPXPCFailure {
            return WindowsMCPToolError(
                code: .runtimeFailure,
                message: failure.message,
                details: [
                    "machineCode": failure.code,
                    "retryable": RDPReconnectPolicy.standard.permitsReconnect(
                        phase: .failed,
                        failureCode: failure.code
                    ),
                ]
            )
        }
        return WindowsMCPToolError(
            code: .runtimeFailure,
            message: error.localizedDescription,
            details: ["retryable": false]
        )
    }

    private func storedOpenFailure(_ error: Error) -> DesktopOpenStoredFailure {
        if let failure = error as? WindowsMCPToolError {
            return DesktopOpenStoredFailure(
                code: failure.code.rawValue,
                message: failure.message,
                machineCode: failure.details["machineCode"] as? String,
                retryable: failure.details["retryable"] as? Bool ?? false
            )
        }
        if let failure = error as? FreeRDPXPCFailure {
            return DesktopOpenStoredFailure(
                code: WindowsMCPToolError.Code.runtimeFailure.rawValue,
                message: failure.message,
                machineCode: failure.code,
                retryable: RDPReconnectPolicy.standard.permitsReconnect(
                    phase: .failed,
                    failureCode: failure.code
                )
            )
        }
        return DesktopOpenStoredFailure(
            code: WindowsMCPToolError.Code.runtimeFailure.rawValue,
            message: error.localizedDescription,
            machineCode: nil,
            retryable: false
        )
    }

    private func restoredOpenFailure(
        _ failure: DesktopOpenStoredFailure
    ) -> WindowsMCPToolError {
        var details: [String: Any] = [
            "idempotentReplay": true,
            "retryable": failure.retryable,
        ]
        if let machineCode = failure.machineCode {
            details["machineCode"] = machineCode
        }
        return WindowsMCPToolError(
            code: WindowsMCPToolError.Code(rawValue: failure.code) ?? .runtimeFailure,
            message: failure.message,
            details: details
        )
    }

    func desktopState(sessionID: UUID) async throws -> RDPDesktopSessionState {
        guard let active = desktopsBySessionID[sessionID] else {
            throw WindowsMCPToolError(code: .targetNotFound, message: "The RDP desktop session is not open.")
        }
        return active.state
    }

    func observeDesktop(sessionID: UUID) async throws -> DesktopFrame {
        guard let active = desktopsBySessionID[sessionID] else {
            throw WindowsMCPToolError(code: .targetNotFound, message: "The RDP desktop session is not open.")
        }
        let connectionAttemptID = active.connectionAttemptID
        try requireCurrentConnectedActionAttempt(
            active,
            expectedConnectionAttemptID: connectionAttemptID
        )
        // MCP observations need an atomic pixels + metadata snapshot. The live
        // IOSurface is intentionally reusable, so a cached callback image must
        // never be presented as a newly observed frame.
        let copy = try await active.xpc.copyFrame()
        try requireCurrentConnectedActionAttempt(
            active,
            expectedConnectionAttemptID: connectionAttemptID
        )
        let frame: DesktopFrame
        do {
            frame = try makeAttemptScopedFrame(
                pixels: copy.pixels,
                metadata: copy.metadata,
                active: active,
                connectionAttemptID: connectionAttemptID
            )
        } catch AttemptScopedFrameError.stale {
            throw WindowsMCPToolError(
                code: .stateConflict,
                message: "The RDP frame belongs to a stale connection attempt. Observe the current desktop again."
            )
        }
        rememberFrameMetadata(frame.metadata, active: active)
        active.latestFrame = frame
        active.state.latestFrameID = frame.metadata.frameID
        active.state.stateRevision = frame.metadata.stateRevision
        active.state.remotePixelWidth = frame.metadata.pixelWidth
        active.state.remotePixelHeight = frame.metadata.pixelHeight
        imagesByTargetID[active.target.targetID] = NSImage(data: frame.pngData)
        publish(active)
        return frame
    }

    func performDesktopAction(
        sessionID: UUID,
        request: DesktopActionRequest
    ) async throws -> RDPDesktopSessionState {
        try await performDesktopAction(
            sessionID: sessionID,
            request: request,
            isManualInput: false
        )
    }

    func performObservedSemanticAction(
        sessionID: UUID,
        request: DesktopActionRequest,
        observationID: UUID,
        operationToken: RDPAuthorizedOperationToken
    ) async throws -> RDPDesktopSessionState {
        try await performDesktopAction(
            sessionID: sessionID, request: request, isManualInput: false,
            observedUIAContext: (observationID, operationToken)
        )
    }

    private func performDesktopAction(
        sessionID: UUID,
        request: DesktopActionRequest,
        isManualInput: Bool,
        observedUIAContext: (id: UUID, token: RDPAuthorizedOperationToken)? = nil
    ) async throws -> RDPDesktopSessionState {
        guard let active = desktopsBySessionID[sessionID] else {
            throw WindowsMCPToolError(code: .targetNotFound, message: "The RDP desktop session is not open.")
        }
        let connectionAttemptID = active.connectionAttemptID
        try requireCurrentConnectedActionAttempt(
            active,
            expectedConnectionAttemptID: connectionAttemptID
        )
        guard active.companionInstallationTaskID == nil else {
            throw WindowsMCPToolError(
                code: .sensitiveInteractionActive,
                message: "Desktop input is paused while the user-initiated Windows Companion installation is running."
            )
        }
        if !isManualInput {
            try requireAIClipboardIsolationReady(active)
        }
        if !isManualInput,
           let reason = RDPCompanionSensitiveInteractionPolicy.aiInputDenialReason(
            companionAvailability: active.state.companion.availability,
            pairingAuthorizationInProgress: active.companionAuthorizationTaskID != nil,
            elevationPromptInProgress: active.elevationPromptInProgress
           ) {
            throw WindowsMCPToolError(
                code: .sensitiveInteractionActive,
                message: reason
            )
        }
        guard let frame = active.latestFrame else {
            throw WindowsMCPToolError(code: .stateConflict, message: "Observe the current desktop frame before acting.")
        }
        if let context = observedUIAContext {
            try requireAuthorizedOperation(context.token)
            guard context.token.targetID == active.target.targetID,
                  context.token.showsControlActivity else {
                throw WindowsMCPToolError(code: .permissionDenied,
                    message: "The UI Automation action requires control authority for this desktop.")
            }
        }
        let resolvedRequest: DesktopActionRequest
        do {
            if isManualInput {
                let observedFrame = request.expectedFrameID.flatMap {
                    active.recentFrameMetadataByID[$0]
                }
                resolvedRequest = try RDPManualDesktopActionResolver.rebind(
                    request,
                    observedFrame: observedFrame,
                    latestFrame: frame.metadata
                )
            } else if let context = observedUIAContext {
                // Observation validation and frame selection run together on
                // MainActor, before any suspension or remote mutation.
                resolvedRequest = try uiaObservations.rebindSemanticAction(
                    request, observationID: context.id, token: context.token,
                    sessionID: sessionID, latestFrame: frame.metadata)
            } else {
                resolvedRequest = request
            }
            try resolvedRequest.validate(against: frame.metadata)
        } catch {
            throw WindowsMCPToolError(
                code: .stateConflict,
                message: error.localizedDescription,
                details: [
                    "currentFrameId": frame.metadata.frameID.uuidString.lowercased(),
                    "currentStateRevision": frame.metadata.stateRevision,
                ]
            )
        }

        guard let runtimeStateRevision = active.revisionLedger.runtimeRevision(
            for: resolvedRequest.expectedStateRevision,
            attemptID: connectionAttemptID
        ) else {
            throw WindowsMCPToolError(
                code: .stateConflict,
                message: "The desktop action belongs to a different RDP connection attempt. Observe the current desktop before acting.",
                details: [
                    "currentFrameId": frame.metadata.frameID.uuidString.lowercased(),
                    "currentStateRevision": frame.metadata.stateRevision,
                ]
            )
        }
        var executionRequest = resolvedRequest
        executionRequest.expectedStateRevision = runtimeStateRevision

        if executionRequest.action.requiresSelector {
            try await performSemanticAction(
                active: active,
                request: executionRequest,
                connectionAttemptID: connectionAttemptID
            )
        } else {
            try await performRawAction(
                active: active,
                request: executionRequest,
                localManualFrame: isManualInput ? frame.metadata : nil,
                connectionAttemptID: connectionAttemptID
            )
        }
        try requireCurrentConnectedActionAttempt(
            active,
            expectedConnectionAttemptID: connectionAttemptID
        )
        return active.state
    }

    func closeDesktop(sessionID: UUID) async throws {
        guard let active = desktopsBySessionID[sessionID] else { return }
        await close(active: active)
    }

    func close(targetID: UUID) async {
        nextLocalNetworkDiagnosticModesByTargetID.removeValue(forKey: targetID)
        // Capture the session that existed when Close was requested. MainActor
        // reentrancy while cleanup awaits must never let this call close a new
        // session installed by an immediate reopen.
        let activeToClose = sessionIDByTargetID[targetID].flatMap {
            desktopsBySessionID[$0]
        }
        var cancelledResultTask: Task<RDPDesktopSessionState, Error>?
        if let operationID = openOperationIDByTargetID[targetID],
           let operation = openOperationsByID[operationID] {
            // Detach the cancelled flight synchronously so an immediate reopen
            // cannot join it. The operation's conditional finalizer cannot
            // remove a newer flight installed while this close awaits cleanup.
            if openOperationIDByTargetID[targetID] == operationID {
                openOperationIDByTargetID.removeValue(forKey: targetID)
            }
            if openOperationsByID[operationID] === operation {
                openOperationsByID.removeValue(forKey: operationID)
            }
            operation.executionTask?.cancel()
            operation.resultTask?.cancel()
            cancelledResultTask = operation.resultTask
        }
        if let activeToClose {
            await close(active: activeToClose)
        } else {
            invalidateAllAIAuthority(targetID: targetID)
        }
        if let cancelledResultTask {
            _ = await cancelledResultTask.result
        }
    }

    func takeManualControl(targetID: UUID) {
        if let sessionID = sessionIDByTargetID[targetID],
           let active = desktopsBySessionID[sessionID],
           let companion = active.companion {
            Task { @MainActor [weak companion] in
                await companion?.cancelPendingOperations()
            }
        }
        // Cancel in-flight work synchronously so human input cannot race an AI
        // operation. The persistent client grant remains valid until the user
        // explicitly revokes it from AI Access.
        clearAIActivityState(targetID: targetID)
    }

    private func startCompanionInstallation(targetID: UUID) {
        guard let sessionID = sessionIDByTargetID[targetID],
              let active = desktopsBySessionID[sessionID],
              isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing else {
            publishCompanionInstallationFailure(
                targetID: targetID,
                message: CompanionInstallationError.sessionUnavailable.localizedDescription
            )
            return
        }
        guard active.companionInstallationTaskID == nil else { return }
        guard active.state.phase == .connected,
              active.state.companion.availability == .missing else {
            publishCompanionInstallationFailure(
                targetID: targetID,
                message: CompanionInstallationError.companionNotMissing.localizedDescription
            )
            return
        }
        guard active.target.rdpProfile.clipboardEnabled else {
            publishCompanionInstallationFailure(
                targetID: targetID,
                message: CompanionInstallationError.clipboardDisabled.localizedDescription
            )
            return
        }

        let taskID = UUID()
        let connectionAttemptID = active.connectionAttemptID
        active.companionInstallationTaskID = taskID
        active.companionInstallationCancellationState = nil
        companionInstallationStatesByTargetID[targetID] =
            WindowsCompanionInstallationState(phase: .preparing)
        active.companionInstallationTask = Task { @MainActor [weak self, weak active] in
            guard let self, let active else { return }
            await self.runCompanionInstallation(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: connectionAttemptID
            )
        }
    }

    private func cancelCompanionInstallation(
        active: ActiveDesktop,
        failureMessage: String
    ) {
        guard active.companionInstallationTaskID != nil else { return }
        let state = WindowsCompanionInstallationState(
            phase: .failed,
            failureMessage: failureMessage
        )
        active.companionInstallationCancellationState = state
        companionInstallationStatesByTargetID[active.target.targetID] = state
        active.companionInstallationTask?.cancel()
    }

    private func runCompanionInstallation(
        active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID
    ) async {
        var savedClipboard: SavedCompanionInstallationClipboard?
        var installerOfferMayBeActive = false
        var finalState = WindowsCompanionInstallationState.idle

        do {
            try requireCurrentCompanionInstallation(
                active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            try requireCompanionStillMissing(active)
            savedClipboard = try await reserveClipboardForCompanionInstallation(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            try requireCurrentCompanionInstallation(
                active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            try requireCompanionStillMissing(active)

            // A cancelled XPC waiter can race the helper's accepted format
            // announcement. From this point onward cleanup must attempt the
            // idempotent clear even when the offer call does not return.
            installerOfferMayBeActive = true
            let offer = try await active.xpc.offerCompanionInstaller(
                deadlineMilliseconds: 10_000
            )
            try requireCurrentCompanionInstallation(
                active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            let plan = try RDPCompanionBootstrapInstaller.makePlan(
                fileName: offer.fileName,
                fileSize: offer.fileSize,
                sha256: offer.sha256
            )
            try requireCompanionStillMissing(active)
            companionInstallationStatesByTargetID[active.target.targetID] =
                WindowsCompanionInstallationState(
                    phase: .transferring
                )

            try await pasteCompanionInstallerIntoTemporaryFolder(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID,
                temporaryFolderAddress: plan.temporaryFolderAddress
            )
            try await Task.sleep(for: .milliseconds(250))
            try requireCompanionStillMissing(active)
            companionInstallationStatesByTargetID[active.target.targetID] =
                WindowsCompanionInstallationState(
                    phase: .launching
                )
            let powerShellLaunchFrameID = try await sendCompanionInstallationRunCommand(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID,
                command: plan.powerShellLaunchCommand
            )
            try await waitForCompanionInstallationDesktopTransition(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID,
                previousFrameID: powerShellLaunchFrameID
            )
            try await sendCompanionInstallationPowerShellScript(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID,
                script: plan.powerShellScript
            )
            companionInstallationStatesByTargetID[active.target.targetID] =
                WindowsCompanionInstallationState(
                    phase: .waitingForCompanion
                )

            let availability = try await waitForInstalledCompanion(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            finalState = WindowsCompanionInstallationState(
                phase: availability == .ready ? .ready : .pairingRequired
            )
        } catch let resolution as CompanionInstallationResolution {
            switch resolution {
            case let .available(availability):
                finalState = companionInstallationCompletionState(
                    for: availability
                ) ?? .idle
            }
        } catch is CancellationError {
            finalState = active.companionInstallationCancellationState ?? .idle
        } catch {
            finalState = WindowsCompanionInstallationState(
                phase: .failed,
                failureMessage: companionInstallationFailureMessage(for: error)
            )
        }

        let clipboardRestored = await finishCompanionInstallationClipboard(
            active: active,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            installerOfferMayBeActive: installerOfferMayBeActive,
            savedClipboard: savedClipboard
        )
        guard active.companionInstallationTaskID == taskID else { return }
        if let cancellationState = active.companionInstallationCancellationState {
            finalState = cancellationState
        }
        finalState = reconciledCompanionInstallationState(
            finalState,
            active: active,
            expectedConnectionAttemptID: expectedConnectionAttemptID
        )
        active.companionInstallationTask = nil
        active.companionInstallationTaskID = nil
        active.companionInstallationCancellationState = nil
        companionInstallationStatesByTargetID[active.target.targetID] = finalState

        let sessionIsCurrent = isCurrent(active) &&
            targetBindingIsCurrent(active) &&
            !active.intentionallyClosing &&
            active.connectionAttemptID == expectedConnectionAttemptID &&
            active.state.phase == .connected
        if sessionIsCurrent {
            publish(active)
        }

        guard clipboardRestored else {
            guard sessionIsCurrent else { return }
            let message = "Windows did not acknowledge clipboard restoration. JTS Terminal will reconnect this RDP session before clipboard use resumes."
            scheduleReconnect(
                active: active,
                failure: RDPReconnectFailure(
                    phase: active.state.phase,
                    code: "RDP_CLIPBOARD_RESTORE_FAILED",
                    message: message
                ),
                runtimeUnavailable: false
            )
            // Publish reconnect state first: canonical Companion availability
            // must not overwrite this transport failure before the user sees it.
            companionInstallationStatesByTargetID[active.target.targetID] =
                WindowsCompanionInstallationState(
                    phase: .failed,
                    failureMessage: message
                )
            return
        }

        if sessionIsCurrent,
           !active.clipboardSuspendedForAI,
           !hasAnyAIControlActivity(targetID: active.target.targetID) {
            startClipboardSync(active)
        }
    }

    private func reserveClipboardForCompanionInstallation(
        active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID
    ) async throws -> SavedCompanionInstallationClipboard {
        takeManualControl(targetID: active.target.targetID)
        let drainDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while hasAnyAIControlActivity(targetID: active.target.targetID) {
            try requireCurrentCompanionInstallation(
                active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            guard ContinuousClock.now < drainDeadline else {
                throw CompanionInstallationError.aiControlDidNotDrain
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        if active.clipboardSuspendedForAI {
            resumeClipboardAfterAI(active)
            if let resumeTask = active.clipboardAIResumeTask {
                await resumeTask.value
            }
        }
        try requireCurrentCompanionInstallation(
            active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID
        )
        guard !active.clipboardSuspendedForAI else {
            throw CompanionInstallationError.clipboardNotReady
        }
        let synchronizer =
            active.clipboardSynchronizer ?? RDPTextClipboardSynchronizer()
        active.clipboardSynchronizer = synchronizer
        do {
            // Do not cancel a text clipboard XPC mutation after the helper has
            // accepted it. That would invalidate the shared XPC session and
            // race the following virtual-file format announcement.
            try await synchronizer.publishCurrent(force: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CompanionInstallationError.clipboardNotReady
        }
        try requireCurrentCompanionInstallation(
            active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID
        )
        let payload: Data?
        do {
            payload = try synchronizer.currentPayload()
        } catch {
            throw CompanionInstallationError.clipboardNotReady
        }
        stopClipboardSync(active)
        return SavedCompanionInstallationClipboard(payload: payload)
    }

    private func sendCompanionInstallationInput(
        active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID,
        type: String,
        values: [String: Any]
    ) async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            try requireCurrentCompanionInstallation(
                active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            guard let frame = active.latestFrame,
                  let runtimeRevision = active.revisionLedger.runtimeRevision(
                    for: frame.metadata.stateRevision,
                    attemptID: expectedConnectionAttemptID
                  ) else {
                throw CompanionInstallationError.desktopInputUnavailable
            }
            var input = values
            input["type"] = type
            input["inputOrigin"] = "localManual"
            input["expectedStateRevision"] = runtimeRevision
            do {
                try await sendDesktopInput(
                    active: active,
                    input,
                    deadlineMilliseconds: 5_000
                )
                try requireCurrentCompanionInstallation(
                    active,
                    taskID: taskID,
                    expectedConnectionAttemptID: expectedConnectionAttemptID
                )
                return
            } catch {
                lastError = error
                guard attempt < 2,
                      isTransientCompanionInstallationInputFailure(error) else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(75))
            }
        }
        throw lastError ?? CompanionInstallationError.desktopInputUnavailable
    }

    private func sendCompanionInstallationRunCommand(
        active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID,
        command: String
    ) async throws -> UUID {
        guard command.utf8.count <=
                RDPCompanionBootstrapInstaller.maximumRunCommandBytes,
              command.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
            throw RDPCompanionBootstrapInstaller.PlanError.invalidCommand
        }
        try requireCompanionStillMissing(active)
        try await sendCompanionInstallationInput(
            active: active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            type: "keyChord",
            values: [
                "scancodes": try ["meta", "r"].map(Self.scanCode(for:)),
            ]
        )
        try await Task.sleep(for: .milliseconds(350))
        try await sendCompanionInstallationInput(
            active: active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            type: "text",
            values: ["text": command]
        )
        do {
            try requireCompanionStillMissing(active)
        } catch {
            try? await sendCompanionInstallationInput(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID,
                type: "keyChord",
                values: [
                    "scancodes": try ["escape"].map(Self.scanCode(for:)),
                ]
            )
            throw error
        }
        guard let launchFrameID = active.latestFrame?.metadata.frameID else {
            throw CompanionInstallationError.desktopInputUnavailable
        }
        try await sendCompanionInstallationInput(
            active: active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            type: "keyChord",
            values: [
                "scancodes": try ["enter"].map(Self.scanCode(for:)),
            ]
        )
        return launchFrameID
    }

    private func pasteCompanionInstallerIntoTemporaryFolder(
        active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID,
        temporaryFolderAddress: String
    ) async throws {
        // The Run dialog expands this fixed environment path and opens Explorer
        // without localized menus, address-bar focus, or an asynchronous cleanup
        // process. Wait for a real framebuffer transition and the bounded
        // cold-start readiness window before pasting.
        let explorerLaunchFrameID = try await sendCompanionInstallationRunCommand(
            active: active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            command: temporaryFolderAddress
        )
        try await waitForCompanionInstallationDesktopTransition(
            active: active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            previousFrameID: explorerLaunchFrameID
        )
        try requireCompanionStillMissing(active)
        try await sendCompanionInstallationInput(
            active: active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            type: "keyChord",
            values: [
                "scancodes": try ["control", "v"].map(Self.scanCode(for:)),
            ]
        )
    }

    private func waitForCompanionInstallationDesktopTransition(
        active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID,
        previousFrameID: UUID
    ) async throws {
        let startedAt = ContinuousClock.now
        let earliestReady = startedAt.advanced(
            by: RDPCompanionBootstrapInstaller.desktopLaunchMinimumReadinessDelay
        )
        let deadline = startedAt.advanced(
            by: RDPCompanionBootstrapInstaller.desktopLaunchTransitionTimeout
        )
        var observedTransition = false
        while ContinuousClock.now < deadline {
            try requireCurrentCompanionInstallation(
                active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            try requireCompanionStillMissing(active)
            if let frameID = active.latestFrame?.metadata.frameID,
               frameID != previousFrameID {
                observedTransition = true
            }
            if observedTransition, ContinuousClock.now >= earliestReady {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CompanionInstallationError.desktopInputUnavailable
    }

    private func sendCompanionInstallationPowerShellScript(
        active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID,
        script: String
    ) async throws {
        try await sendCompanionInstallationInput(
            active: active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            type: "text",
            values: ["text": script]
        )
        do {
            try requireCompanionStillMissing(active)
        } catch {
            try? await sendCompanionInstallationInput(
                active: active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID,
                type: "keyChord",
                values: [
                    "scancodes": try ["escape"].map(Self.scanCode(for:)),
                ]
            )
            throw error
        }
        try await sendCompanionInstallationInput(
            active: active,
            taskID: taskID,
            expectedConnectionAttemptID: expectedConnectionAttemptID,
            type: "keyChord",
            values: [
                "scancodes": try ["enter"].map(Self.scanCode(for:)),
            ]
        )
    }

    private func requireCompanionStillMissing(
        _ active: ActiveDesktop
    ) throws {
        switch active.state.companion.availability {
        case .missing:
            return
        case .pairingRequired, .ready:
            throw CompanionInstallationResolution.available(
                active.state.companion.availability
            )
        case .incompatible:
            throw CompanionInstallationError.companionIncompatible
        case .unknown:
            throw CompanionInstallationError.companionStatusChanged
        }
    }

    private func companionInstallationCompletionState(
        for availability: WindowsCompanionAvailability
    ) -> WindowsCompanionInstallationState? {
        switch availability {
        case .pairingRequired:
            return WindowsCompanionInstallationState(phase: .pairingRequired)
        case .ready:
            return WindowsCompanionInstallationState(phase: .ready)
        case .unknown, .missing, .incompatible:
            return nil
        }
    }

    private func reconciledCompanionInstallationState(
        _ proposedState: WindowsCompanionInstallationState,
        active: ActiveDesktop,
        expectedConnectionAttemptID: UUID
    ) -> WindowsCompanionInstallationState {
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.connectionAttemptID == expectedConnectionAttemptID,
              active.state.phase == .connected else {
            return proposedState
        }
        return WindowsCompanionInstallationReconciliationPolicy.reconcile(
            proposed: proposedState,
            currentAvailability: active.state.companion.availability,
            incompatibleFailureMessage:
                CompanionInstallationError.companionIncompatible.localizedDescription
        )
    }

    private func waitForInstalledCompanion(
        active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID
    ) async throws -> WindowsCompanionAvailability {
        let deadline = ContinuousClock.now.advanced(
            by: RDPCompanionBootstrapInstaller.companionJoinTimeout
        )
        while ContinuousClock.now < deadline {
            try requireCurrentCompanionInstallation(
                active,
                taskID: taskID,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
            switch active.state.companion.availability {
            case .pairingRequired:
                return .pairingRequired
            case .ready:
                return .ready
            case .incompatible:
                throw CompanionInstallationError.companionIncompatible
            case .unknown, .missing:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CompanionInstallationError.companionJoinTimedOut
    }

    private func requireCurrentCompanionInstallation(
        _ active: ActiveDesktop,
        taskID: UUID,
        expectedConnectionAttemptID: UUID
    ) throws {
        try Task.checkCancellation()
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.companionInstallationTaskID == taskID,
              active.connectionAttemptID == expectedConnectionAttemptID,
              active.state.phase == .connected,
              certificateChallengesByTargetID[active.target.targetID] == nil else {
            throw CompanionInstallationError.sessionUnavailable
        }
    }

    private func finishCompanionInstallationClipboard(
        active: ActiveDesktop,
        expectedConnectionAttemptID: UUID,
        installerOfferMayBeActive: Bool,
        savedClipboard: SavedCompanionInstallationClipboard?
    ) async -> Bool {
        let cleanup = Task { @MainActor [weak self, weak active] () -> Bool in
            guard let self, let active else { return false }
            // Cleanup belongs to the captured live XPC attempt, not to the
            // mutable saved-profile binding. Server Properties can update the
            // RemoteSession in place while installation is running; that must
            // cancel further input without skipping revocation of an already
            // advertised virtual installer file.
            let attemptIsOwned = {
                self.isCurrent(active) &&
                    active.connectionAttemptID == expectedConnectionAttemptID
            }
            let targetBindingChanged = {
                !self.targetBindingIsCurrent(active)
            }
            guard attemptIsOwned() else { return true }
            var offerWasCleared = !installerOfferMayBeActive
            if installerOfferMayBeActive {
                for retry in 0..<2 {
                    guard attemptIsOwned() else { return true }
                    do {
                        try await active.xpc.clearCompanionInstallerOffer(
                            deadlineMilliseconds: 3_000
                        )
                        guard attemptIsOwned() else { return true }
                        offerWasCleared = true
                        break
                    } catch {
                        guard attemptIsOwned() else { return true }
                        guard retry == 0 else { break }
                        try? await Task.sleep(for: .milliseconds(100))
                        guard attemptIsOwned() else { return true }
                    }
                }
            }
            guard attemptIsOwned() else { return true }
            guard offerWasCleared else {
                active.xpc.invalidateImmediately()
                if targetBindingChanged() {
                    self.scheduleCompanionInstallationSessionRetirement(
                        active,
                        expectedConnectionAttemptID: expectedConnectionAttemptID
                    )
                }
                return false
            }
            // Clearing an active virtual-file offer re-advertises the bridge's
            // preserved local text (including an explicit empty list). If the
            // offer never became active, require an acknowledged restoration
            // before normal clipboard synchronization resumes.
            if !installerOfferMayBeActive, let savedClipboard,
               !active.intentionallyClosing,
               active.state.phase == .connected {
                guard attemptIsOwned() else { return true }
                do {
                    try await active.xpc.updateClipboardText(savedClipboard.payload)
                    guard attemptIsOwned() else { return true }
                } catch {
                    guard attemptIsOwned() else { return true }
                    active.xpc.invalidateImmediately()
                    if targetBindingChanged() {
                        self.scheduleCompanionInstallationSessionRetirement(
                            active,
                            expectedConnectionAttemptID: expectedConnectionAttemptID
                        )
                    }
                    return false
                }
            }
            guard attemptIsOwned() else { return true }
            if targetBindingChanged() {
                // The old XPC session is bound to the pre-edit endpoint. It
                // must not survive the cleanup and later accept clipboard or
                // desktop input for a differently bound saved target.
                active.xpc.invalidateImmediately()
                self.scheduleCompanionInstallationSessionRetirement(
                    active,
                    expectedConnectionAttemptID: expectedConnectionAttemptID
                )
                return false
            }
            return true
        }
        return await cleanup.value
    }

    private func scheduleCompanionInstallationSessionRetirement(
        _ active: ActiveDesktop,
        expectedConnectionAttemptID: UUID
    ) {
        Task { @MainActor [weak self, weak active] in
            guard let self, let active,
                  self.isCurrent(active),
                  active.connectionAttemptID == expectedConnectionAttemptID else {
                return
            }
            await self.close(active: active)
        }
    }

    private func isTransientCompanionInstallationInputFailure(
        _ error: Error
    ) -> Bool {
        guard let failure = error as? FreeRDPXPCFailure else { return false }
        return failure.code == "STATE_CONFLICT" ||
            failure.code == "RDP_STATE_CONFLICT"
    }

    private func companionInstallationFailureMessage(for error: Error) -> String {
        if let failure = error as? CompanionInstallationError {
            return failure.localizedDescription
        }
        if let failure = error as? RDPCompanionBootstrapInstaller.PlanError {
            return failure.localizedDescription
        }
        if let failure = error as? FreeRDPXPCFailure {
            switch failure.code {
            case "COMPANION_INSTALLER_UNAVAILABLE":
                return "This JTS Terminal build does not include a verified Windows Companion installer."
            case "COMPANION_INSTALLER_OFFER_FAILED",
                 "RDP_FILE_CLIPBOARD_UNAVAILABLE",
                 "RDP_CLIPBOARD_NOT_READY",
                 "RDP_CLIPBOARD_CONNECTION_CHANGED":
                return "The signed Companion installer could not be transferred through the current RDP clipboard."
            case "STATE_CONFLICT", "RDP_STATE_CONFLICT", "RDP_INPUT_FAILED":
                return CompanionInstallationError.desktopInputUnavailable.localizedDescription
            default:
                return "Windows Companion installation could not be completed through the current RDP session."
            }
        }
        return "Windows Companion installation could not be completed through the current RDP session."
    }

    private func publishCompanionInstallationFailure(
        targetID: UUID,
        message: String
    ) {
        companionInstallationStatesByTargetID[targetID] =
            WindowsCompanionInstallationState(
                phase: .failed,
                failureMessage: message
            )
    }

    func emergencyStop(targetID: UUID) async {
        invalidateAllAIAuthority(targetID: targetID)
        await CompanionDesktopRuntime.shared.close(targetID: targetID)
        if let target = targetsByID[targetID],
           let binding = try? await CompanionTargetRouteStore.shared.binding(
                targetID: targetID, targetBinding: target.mcpGrantTargetBinding) {
            // Closing control cancels default (non-detached) Windows jobs.
            // It is not a fabricated acknowledgement of remote process exit.
            CompanionDevicesModel.shared.routes[binding.deviceID]?.disconnect()
            NotificationCenter.default.post(name: .jtsCompanionDeviceTrustChanged, object: binding.deviceID)
        }
        if let sessionID = sessionIDByTargetID[targetID],
           let active = desktopsBySessionID[sessionID] {
            await active.companion?.cancelPendingOperations()
            active.companionChannelID = nil
            active.companion?.cancelAll()
            await close(active: active, cancelConnectionBoundOperations: false)
        }
    }

    func trustCertificate(targetID: UUID, persistPin: Bool) async throws {
        guard let challenge = certificateChallengesByTargetID[targetID],
              let sessionID = sessionIDByTargetID[targetID],
              let active = desktopsBySessionID[sessionID],
              targetBindingIsCurrent(active) else {
            throw WindowsMCPToolError(code: .runtimeFailure, message: "No RDP certificate decision is pending.")
        }
        guard !challenge.changed, !challenge.pinnedMismatch else {
            throw WindowsMCPToolError(
                code: .permissionDenied,
                message: "The RDP certificate changed. Remove the old pin from Server Properties only after verifying the new certificate out of band."
            )
        }
        if persistPin {
            var profile = active.target.rdpProfile
            profile.pinnedCertificateSHA256 = challenge.sha256
            try active.target.setRDPProfile(profile)
        }
        active.trustOnceFingerprint = challenge.sha256
        certificateChallengesByTargetID.removeValue(forKey: targetID)
        await close(active: active, removePublishedState: false)
        targetsByID[targetID] = active.target
        _ = try await reopenWithTrust(target: active.target, trustOnceFingerprint: challenge.sha256)
    }

    private func reopenWithTrust(target: RemoteSession, trustOnceFingerprint: String) async throws -> RDPDesktopSessionState {
        let sessionID = UUID()
        let xpc = FreeRDPXPCSession()
        let profile = target.rdpProfile
        let active = ActiveDesktop(
            target: target,
            sessionID: sessionID,
            xpc: xpc,
            requestedPixelWidth: profile.desktopWidth,
            requestedPixelHeight: profile.desktopHeight
        )
        active.trustOnceFingerprint = trustOnceFingerprint
        desktopsBySessionID[sessionID] = active
        sessionIDByTargetID[target.targetID] = sessionID
        wireCallbacks(for: active)
        publish(active)
        let trustedConnectionAttemptID = active.connectionAttemptID

        do {
            let password = try await connectionPassword(for: target)
            if let supersedingState = stateForSupersededOpenAttempt(
                active,
                expectedConnectionAttemptID: trustedConnectionAttemptID
            ) {
                return supersedingState
            }
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == trustedConnectionAttemptID else {
                xpc.invalidateImmediately()
                throw CancellationError()
            }
            let configuration = try connectionConfiguration(for: active, password: password)
            if let trustedReopenConnector {
                try await trustedReopenConnector(configuration)
            } else {
                try await connectTransport(for: active, configuration: configuration)
            }
            if let supersedingState = stateForSupersededOpenAttempt(
                active,
                expectedConnectionAttemptID: trustedConnectionAttemptID
            ) {
                return supersedingState
            }
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == trustedConnectionAttemptID else {
                xpc.invalidateImmediately()
                throw CancellationError()
            }
            active.state.runtimeAvailability = .available
            publish(active)
            return active.state
        } catch is CancellationError {
            if let supersedingState = stateForSupersededOpenAttempt(
                active,
                expectedConnectionAttemptID: trustedConnectionAttemptID
            ) {
                return supersedingState
            }
            if isCurrent(active), targetBindingIsCurrent(active),
               !active.intentionallyClosing,
               active.connectionAttemptID == trustedConnectionAttemptID {
                invalidateOpenDesktop(
                    active,
                    code: "RDP_TRUST_REOPEN_CANCELLED",
                    message: "The trusted RDP connection retry was cancelled."
                )
            } else {
                xpc.invalidateImmediately()
            }
            throw CancellationError()
        } catch {
            if let supersedingState = stateForSupersededOpenAttempt(
                active,
                expectedConnectionAttemptID: trustedConnectionAttemptID
            ) {
                return supersedingState
            }
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == trustedConnectionAttemptID else {
                xpc.invalidateImmediately()
                throw CancellationError()
            }
            let failure = normalizedOpenFailure(error)
            invalidateOpenDesktop(
                active,
                code: failure.details["machineCode"] as? String ?? "RDP_TRUST_REOPEN_FAILED",
                message: failure.message
            )
            throw failure
        }
    }

    private func wireCallbacks(for active: ActiveDesktop) {
        active.xpc.onState = { [weak self, weak active] state in
            guard let self, let active,
                  self.isCurrent(active), self.targetBindingIsCurrent(active),
                  !active.intentionallyClosing else { return }
            self.handleState(state, active: active)
        }
        active.xpc.onSurface = { [weak self, weak active] surface, metadata in
            guard let self, let active,
                  self.isCurrent(active), self.targetBindingIsCurrent(active),
                  !active.intentionallyClosing else { return }
            self.handleSurface(surface, metadata: metadata, active: active)
        }
        active.xpc.onDVCMessage = { [weak self, weak active] data, channelGeneration in
            guard let self, let active,
                  self.isCurrent(active), self.targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.companionChannelID != nil,
                  active.companionDVCGeneration == channelGeneration else { return }
            active.companion?.receive(data)
        }
        active.xpc.onCertificateChallenge = { [weak self, weak active] certificate in
            guard let self, let active,
                  self.isCurrent(active), self.targetBindingIsCurrent(active),
                  !active.intentionallyClosing else { return }
            self.handleCertificate(certificate, active: active)
        }
        if active.target.rdpProfile.clipboardEnabled {
            active.clipboardSynchronizer = RDPTextClipboardSynchronizer()
            active.xpc.onClipboardText = { [weak self, weak active] data in
                guard let self, let active,
                      self.isCurrent(active), self.targetBindingIsCurrent(active),
                      !active.intentionallyClosing,
                      active.state.phase == .connected,
                      !active.clipboardSuspendedForAI,
                      !self.hasAnyAIControlActivity(targetID: active.target.targetID),
                      active.clipboardSyncAttemptID == active.connectionAttemptID,
                      let synchronizer = active.clipboardSynchronizer else {
                    return
                }
                // Clipboard text is human-operated session data. It is never
                // recorded in diagnostics, audit events, or MCP state.
                try? synchronizer.receiveRemote(data)
            }
        }
        active.xpc.onInvalidation = { [weak self, weak active] connectionAttemptID, message in
            guard let self, let active else { return }
            self.handleInvalidation(
                connectionAttemptID: connectionAttemptID,
                message: message,
                active: active
            )
        }
    }

    private func startClipboardSync(_ active: ActiveDesktop) {
        guard active.target.rdpProfile.clipboardEnabled,
              isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.companionInstallationTaskID == nil,
              active.state.phase == .connected,
              !active.clipboardSuspendedForAI,
              !hasAnyAIControlActivity(targetID: active.target.targetID),
              active.clipboardSyncAttemptID != active.connectionAttemptID else {
            return
        }
        let synchronizer = active.clipboardSynchronizer ?? RDPTextClipboardSynchronizer()
        active.clipboardSynchronizer = synchronizer
        let expectedConnectionAttemptID = active.connectionAttemptID
        active.clipboardSyncAttemptID = expectedConnectionAttemptID
        synchronizer.start { [weak self, weak active] payload in
            guard let self, let active,
                  self.isCurrent(active), self.targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.companionInstallationTaskID == nil,
                  active.state.phase == .connected,
                  !active.clipboardSuspendedForAI,
                  !self.hasAnyAIControlActivity(targetID: active.target.targetID),
                  active.connectionAttemptID == expectedConnectionAttemptID,
                  active.clipboardSyncAttemptID == expectedConnectionAttemptID else {
                return
            }
            // The XPC request path owns timeout and reconnect handling. Do not
            // surface or log clipboard contents when a transient send fails.
            try await active.xpc.updateClipboardText(payload)
        }
    }

    private func stopClipboardSync(
        _ active: ActiveDesktop,
        discardSynchronizer: Bool = false
    ) {
        active.clipboardSynchronizer?.stop()
        active.clipboardSyncAttemptID = nil
        if discardSynchronizer {
            active.clipboardAIIsolationTask?.cancel()
            active.clipboardAIIsolationTask = nil
            active.clipboardAIIsolationTaskID = nil
            active.clipboardAIIsolationAttemptID = nil
            active.clipboardAIIsolationReadyAttemptID = nil
            active.clipboardAIResumeTask?.cancel()
            active.clipboardAIResumeTask = nil
            active.clipboardAIResumeTaskID = nil
            active.clipboardAIResumeAttemptID = nil
            active.clipboardSynchronizer = nil
            active.xpc.onClipboardText = nil
        }
    }

    private func handleInvalidation(
        connectionAttemptID: UUID,
        message: String,
        active: ActiveDesktop
    ) {
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.connectionAttemptID == connectionAttemptID else { return }
        let code = message.localizedCaseInsensitiveContains("interrupted")
            ? "RDP_XPC_INTERRUPTED"
            : "RDP_XPC_INVALIDATED"
        scheduleReconnect(
            active: active,
            failure: RDPReconnectFailure(
                phase: active.state.phase,
                code: code,
                message: message
            ),
            runtimeUnavailable: true
        )
    }

    private func handleState(_ value: [String: Any], active: ActiveDesktop) {
        guard let rawPhase = value["phase"] as? String,
              let incomingPhase = RDPConnectionPhase(rawValue: rawPhase),
              let runtimeRevision = uint64(value["stateRevision"]),
              let rawConnectionAttemptID = value["connectionAttemptId"] as? String,
              UUID(uuidString: rawConnectionAttemptID) == active.connectionAttemptID else {
            return
        }
        // Reconnecting is owned by the app's reconnect supervisor and is not a
        // helper-emitted phase. The XPC boundary rejects it; keep this handler
        // fail-closed too so an injected callback cannot retire the current
        // attempt, consume its revision ledger, or discard connection state.
        guard incomingPhase != .reconnecting else { return }
        guard let publishedRevision = active.revisionLedger.publishStateRevision(
                  runtimeRevision: runtimeRevision,
                  attemptID: active.connectionAttemptID
              ) else {
            return
        }
        let incomingCode = value["code"] as? String
        let incomingMessage = value["message"] as? String
        if let certificate = value["certificate"] as? [String: Any] {
            certificateChallengesByTargetID[active.target.targetID] = certificateChallenge(
                from: certificate,
                active: active
            )
            invalidateConnectionBoundAuthority(
                for: active,
                connectionAttemptID: active.connectionAttemptID
            )
            discardDesktopFrameState(active)
        }

        active.state.runtimeAvailability = .available
        active.state.stateRevision = publishedRevision
        active.companionInstallerClipboardReady =
            value["companionInstallerClipboardReady"] as? Bool ?? false
        if incomingPhase != .failed {
            cancelLocalNetworkDiagnostic(active)
        }
        if incomingPhase != .connected {
            cancelCompanionInstallation(
                active: active,
                failureMessage: CompanionInstallationError.sessionUnavailable.localizedDescription
            )
        }
        switch incomingPhase {
        case .connected:
            active.reconnectTask?.cancel()
            active.reconnectTask = nil
            active.reconnectTaskID = nil
            active.reconnectSupervisor.markConnected()
            active.state.phase = .connected
            active.state.reconnectAttempt = nil
            active.state.reconnectMaximumAttempts = nil
            active.state.reconnectScheduledAt = nil
            active.state.lastErrorCode = nil
            active.state.lastErrorMessage = nil
            active.localNetworkDiagnosticMode = .initial
            active.hasConnectedOnce = true
            if active.state.connectedAt == nil {
                active.state.connectedAt = Date()
            }
            if hasAnyAIControlActivity(targetID: active.target.targetID) {
                suspendClipboardForAI(active)
            } else if active.clipboardSuspendedForAI {
                resumeClipboardAfterAI(active)
            } else {
                startClipboardSync(active)
            }
            // Connected-state notifications also report Companion DVC changes.
            // They do not replace the framebuffer token used by desktop
            // actions, so keep status.latestFrameId and status.stateRevision as
            // one consistent pair while a frame is available.
            if let frameRevision = active.latestFrame?.metadata.stateRevision {
                active.state.stateRevision = frameRevision
            }
        case .awaitingCertificateTrust:
            stopClipboardSync(active)
            invalidateConnectionBoundAuthority(
                for: active,
                connectionAttemptID: active.connectionAttemptID
            )
            discardDesktopFrameState(active)
            let failure = RDPReconnectFailure(
                phase: incomingPhase,
                code: incomingCode ?? "RDP_CERTIFICATE_UNTRUSTED",
                message: incomingMessage ?? "The RDP certificate requires an explicit trust decision."
            )
            blockReconnect(active: active, failure: failure)
            active.state.phase = .awaitingCertificateTrust
            active.state.lastErrorCode = failure.code
            active.state.lastErrorMessage = failure.message
        case .failed:
            stopClipboardSync(active)
            invalidateConnectionBoundAuthority(
                for: active,
                connectionAttemptID: active.connectionAttemptID
            )
            discardDesktopFrameState(active)
            if certificateChallengesByTargetID[active.target.targetID] != nil {
                active.state.phase = .awaitingCertificateTrust
                publish(active)
                return
            }
            let failure = RDPReconnectFailure(
                phase: incomingPhase,
                code: incomingCode,
                message: incomingMessage ?? "The RDP session failed."
            )
            processConnectionFailure(failure, active: active, allowPathDiagnosis: true)
            return
        case .closed:
            stopClipboardSync(active)
            invalidateConnectionBoundAuthority(
                for: active,
                connectionAttemptID: active.connectionAttemptID
            )
            discardDesktopFrameState(active)
            active.state.phase = .closed
            active.state.lastErrorCode = incomingCode
            active.state.lastErrorMessage = incomingMessage
            if active.hasConnectedOnce || active.reconnectSupervisor.attemptCount > 0 {
                scheduleReconnect(
                    active: active,
                    failure: RDPReconnectFailure(
                        phase: .failed,
                        code: incomingCode ?? "RDP_SESSION_CLOSED",
                        message: incomingMessage ?? "The RDP session closed unexpectedly."
                    ),
                    runtimeUnavailable: false
                )
                return
            }
        case .connecting, .authenticating:
            stopClipboardSync(active)
            if active.reconnectSupervisor.attemptCount > 0 {
                active.state.phase = .reconnecting
            } else {
                active.state.phase = incomingPhase
                active.state.lastErrorCode = incomingCode
                active.state.lastErrorMessage = incomingMessage
            }
        case .reconnecting:
            return
        }

        if active.state.phase == .connected {
            let incomingDVCGeneration = uint64(value["companionDVCGeneration"]) ?? 0
            switch value["companionDVCConnected"] as? Bool {
            case false:
                markCompanionDVCUnavailable(
                    active,
                    generation: incomingDVCGeneration > 0
                        ? incomingDVCGeneration
                        : nil
                )
            case true:
                guard incomingDVCGeneration > 0 else {
                    markCompanionDVCUnavailable(active, generation: nil)
                    break
                }
                let dvcChanged = active.companionDVCConnected != true ||
                    active.companionDVCGeneration != incomingDVCGeneration
                cancelCompanionMissingTask(active)
                active.companionDVCConnected = true
                if dvcChanged {
                    resetCompanionForDVCTransition(active, availability: .unknown)
                    active.companionDVCConnected = true
                    active.companionDVCGeneration = incomingDVCGeneration
                }
                scheduleCompanionHandshake(active: active)
            case nil:
                markCompanionDVCUnavailable(active, generation: nil)
            }
        }
        publish(active)
    }

    func isCurrent(_ active: ActiveDesktop) -> Bool {
        sessionIDByTargetID[active.target.targetID] == active.sessionID
            && desktopsBySessionID[active.sessionID] === active
    }

    func targetBindingIsCurrent(_ active: ActiveDesktop) -> Bool {
        targetsByID[active.target.targetID]?.mcpGrantTargetBinding
            == active.targetBinding
    }

    func requireCurrentConnectedActionAttempt(
        _ active: ActiveDesktop,
        expectedConnectionAttemptID: UUID
    ) throws {
        let targetID = active.target.targetID
        guard isCurrent(active),
              targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.connectionAttemptID == expectedConnectionAttemptID,
              active.invalidatedControlAttemptID != expectedConnectionAttemptID,
              active.state.phase == .connected,
              certificateChallengesByTargetID[targetID] == nil else {
            throw WindowsMCPToolError(
                code: .stateConflict,
                message: "The RDP connection changed or requires certificate approval. Observe the current connected desktop before acting."
            )
        }
    }

    func requireCurrentCompanionAttempt(
        _ active: ActiveDesktop,
        companion: WindowsCompanionClient,
        expectedConnectionAttemptID: UUID
    ) throws {
        try Task.checkCancellation()
        guard active.companion === companion else {
            throw WindowsCompanionRequestFailure(
                code: "COMPANION_CONNECTION_CHANGED",
                message: "The Windows Companion client belongs to an older RDP connection.",
                retryable: true
            )
        }
        do {
            try requireCurrentConnectedActionAttempt(
                active,
                expectedConnectionAttemptID: expectedConnectionAttemptID
            )
        } catch {
            throw WindowsCompanionRequestFailure(
                code: "COMPANION_CONNECTION_CHANGED",
                message: "The RDP connection changed while the Companion operation was in flight.",
                retryable: true
            )
        }
    }

    func isCurrentCompanionAttempt(
        _ active: ActiveDesktop,
        companion: WindowsCompanionClient,
        expectedConnectionAttemptID: UUID
    ) -> Bool {
        (try? requireCurrentCompanionAttempt(
            active,
            companion: companion,
            expectedConnectionAttemptID: expectedConnectionAttemptID
        )) != nil
    }

    private func connectionConfiguration(
        for active: ActiveDesktop,
        password: String
    ) throws -> [String: Any] {
        let profile = active.target.rdpProfile
        do {
            try profile.validateForConnection()
        } catch {
            throw FreeRDPXPCFailure(
                code: "RDP_RECONNECT_CONFIGURATION_REJECTED",
                message: error.localizedDescription
            )
        }
        return [
            "sessionId": active.sessionID.uuidString.lowercased(),
            "connectionAttemptId": active.connectionAttemptID.uuidString.lowercased(),
            "host": active.target.host,
            "port": active.target.port,
            "username": active.target.username,
            "password": password,
            "domain": profile.domain,
            "width": active.requestedPixelWidth,
            "height": active.requestedPixelHeight,
            "clipboardEnabled": profile.clipboardEnabled,
            "pinnedFingerprint": profile.pinnedCertificateSHA256 ?? "",
            "trustOnceFingerprint": active.trustOnceFingerprint ?? "",
        ]
    }

    private func scheduleReconnect(
        active: ActiveDesktop,
        failure: RDPReconnectFailure,
        runtimeUnavailable: Bool
    ) {
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing else { return }
        // Any accepted reconnect outcome supersedes a transport-path probe,
        // including blocked or exhausted branches that do not create a new
        // connection attempt.
        cancelLocalNetworkDiagnostic(active)
        invalidateConnectionBoundAuthority(
            for: active,
            connectionAttemptID: active.connectionAttemptID
        )
        discardDesktopFrameState(active)

        switch active.reconnectSupervisor.plan(after: failure, now: Date()) {
        case .scheduled(let schedule):
            prepareForReconnect(
                active: active,
                failure: failure,
                schedule: schedule,
                runtimeUnavailable: runtimeUnavailable
            )
            let expectedConnectionAttemptID = active.connectionAttemptID
            let reconnectTaskID = UUID()
            active.reconnectTaskID = reconnectTaskID
            active.reconnectTask = Task { @MainActor [weak self, weak active] in
                do {
                    try await Task.sleep(for: .seconds(schedule.delaySeconds))
                } catch {
                    return
                }
                guard let self, let active,
                      self.isCurrent(active), self.targetBindingIsCurrent(active),
                      !active.intentionallyClosing,
                      active.connectionAttemptID == expectedConnectionAttemptID,
                      active.reconnectTaskID == reconnectTaskID,
                      active.reconnectSupervisor.begin(schedule) else { return }
                active.reconnectTask = nil
                active.reconnectTaskID = nil
                active.state.phase = .reconnecting
                active.state.reconnectScheduledAt = nil
                active.state.lastErrorMessage = "Reconnect attempt \(schedule.attempt)/\(schedule.maximumAttempts) is starting."
                self.publish(active)
                await self.performReconnect(
                    active: active,
                    expectedConnectionAttemptID: expectedConnectionAttemptID
                )
            }
        case .alreadyScheduled:
            break
        case .blocked:
            cancelReconnectTask(active: active)
            if failure.phase != .awaitingCertificateTrust,
               certificateChallengesByTargetID[active.target.targetID] == nil {
                active.state.phase = .failed
                active.state.lastErrorCode = failure.code
                active.state.lastErrorMessage = failure.message
            }
            publish(active)
        case .alreadyBlocked:
            break
        case .exhausted:
            cancelReconnectTask(active: active)
            active.state.phase = .failed
            active.state.runtimeAvailability = runtimeUnavailable ? .unavailable : .available
            active.state.lastErrorCode = failure.code ?? "RDP_RECONNECT_EXHAUSTED"
            active.state.lastErrorMessage = "\(failure.message) Automatic reconnect stopped after \(active.reconnectSupervisor.attemptCount) attempts."
            publish(active)
        case .stopped:
            break
        }
    }

    private func prepareForReconnect(
        active: ActiveDesktop,
        failure: RDPReconnectFailure,
        schedule: RDPReconnectSchedule,
        runtimeUnavailable: Bool
    ) {
        active.reconnectTask?.cancel()
        active.reconnectTask = nil
        active.reconnectTaskID = nil
        cancelLocalNetworkDiagnostic(active)
        cancelCompanionInstallation(
            active: active,
            failureMessage: CompanionInstallationError.sessionUnavailable.localizedDescription
        )
        resetCompanionForConnectionTransition(active)
        stopClipboardSync(active)
        active.xpc.invalidateImmediately()
        beginConnectionAttempt(active)
        discardDesktopFrameState(active)

        imagesByTargetID.removeValue(forKey: active.target.targetID)

        active.state.phase = .reconnecting
        active.state.runtimeAvailability = runtimeUnavailable ? .unavailable : .starting
        active.state.latestFrameID = nil
        active.state.remotePixelWidth = nil
        active.state.remotePixelHeight = nil
        active.state.connectedAt = nil
        active.state.reconnectAttempt = schedule.attempt
        active.state.reconnectMaximumAttempts = schedule.maximumAttempts
        active.state.reconnectScheduledAt = schedule.scheduledAt
        active.state.lastErrorCode = failure.code
        let delaySeconds = max(1, Int(ceil(schedule.delaySeconds)))
        active.state.lastErrorMessage = "\(failure.message) Reconnect attempt \(schedule.attempt)/\(schedule.maximumAttempts) starts in \(delaySeconds)s."
        publish(active)
    }

    /// A Companion client is bound to both the current RDP transport and one
    /// exact DVC channel lifecycle. No task, client, pairing presentation, or
    /// ready state may survive a transition to another connection attempt.
    private func resetCompanionForConnectionTransition(_ active: ActiveDesktop) {
        resetCompanionForDVCTransition(active, availability: .unknown)
        active.companionDVCConnected = nil
        active.companionDVCGeneration = nil
    }

    private func markCompanionDVCUnavailable(
        _ active: ActiveDesktop,
        generation: UInt64?
    ) {
        let dvcChanged = active.companionDVCConnected != false ||
            active.companionDVCGeneration != generation
        if dvcChanged {
            resetCompanionForDVCTransition(active, availability: .unknown)
            active.companionDVCConnected = false
            active.companionDVCGeneration = generation
        }
        guard active.state.companion.availability != .missing else { return }
        scheduleCompanionMissing(active)
    }

    private func scheduleCompanionMissing(_ active: ActiveDesktop) {
        guard active.companionMissingTask == nil,
              active.companionDVCConnected == false,
              active.state.phase == .connected else { return }
        let taskID = UUID()
        let connectionAttemptID = active.connectionAttemptID
        let gracePeriod = companionMissingGracePeriod
        active.companionMissingTaskID = taskID
        active.companionMissingTask = Task { @MainActor [weak self, weak active] in
            do {
                try await Task.sleep(for: gracePeriod)
            } catch {
                return
            }
            guard let self, let active else { return }
            defer {
                if active.companionMissingTaskID == taskID {
                    active.companionMissingTask = nil
                    active.companionMissingTaskID = nil
                }
            }
            guard active.companionMissingTaskID == taskID,
                  self.isCurrent(active),
                  self.targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == connectionAttemptID,
                  active.state.phase == .connected,
                  active.companionDVCConnected == false else {
                return
            }
            active.state.companion = .missing
            self.publish(active)
        }
    }

    private func cancelCompanionMissingTask(_ active: ActiveDesktop) {
        active.companionMissingTask?.cancel()
        active.companionMissingTask = nil
        active.companionMissingTaskID = nil
    }

    private func resetCompanionForDVCTransition(
        _ active: ActiveDesktop,
        availability: WindowsCompanionAvailability
    ) {
        uiaObservations.remove(targetID: active.target.targetID)
        cancelCompanionMissingTask(active)
        active.companionHandshakeTask?.cancel()
        active.companionHandshakeTask = nil
        active.companionHandshakeTaskID = nil
        active.companionAuthorizationTask?.cancel()
        active.companionAuthorizationTask = nil
        active.companionAuthorizationTaskID = nil
        active.elevationPromptInProgress = false
        active.elevationPromptOperationID = nil
        active.companionChannelID = nil
        active.companion?.cancelAll()
        active.companion = nil
        companionPairingByTargetID.removeValue(forKey: active.target.targetID)
        companionDelegationExportsByTargetID.removeValue(forKey: active.target.targetID)
        active.state.companion = WindowsCompanionState(availability: availability)
    }

    private func performReconnect(
        active: ActiveDesktop,
        expectedConnectionAttemptID: UUID
    ) async {
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.connectionAttemptID == expectedConnectionAttemptID,
              !Task.isCancelled else { return }
        do {
            let password = try await connectionPassword(for: active.target)
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == expectedConnectionAttemptID,
                  !Task.isCancelled else { return }
            try await connectTransport(for: active,
                configuration: try connectionConfiguration(for: active, password: password)
            )
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == expectedConnectionAttemptID,
                  !Task.isCancelled else { return }
            active.state.runtimeAvailability = .available
            if active.state.phase != .connected,
               certificateChallengesByTargetID[active.target.targetID] == nil {
                active.state.phase = .reconnecting
            }
            publish(active)
        } catch {
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == expectedConnectionAttemptID,
                  !Task.isCancelled else { return }
            let failure = reconnectFailure(from: error, phase: .reconnecting)
            scheduleReconnect(
                active: active,
                failure: failure,
                runtimeUnavailable: failure.code?.contains("XPC") == true
            )
        }
    }

    private func connectionPassword(
        for target: RemoteSession,
        migrateLegacyCredential: Bool = false
    ) async throws -> String {
        if let connectionPasswordProvider {
            return try await connectionPasswordProvider(target, migrateLegacyCredential)
        }
        // Capture only Sendable values before leaving the main actor. Passing
        // the SwiftData model itself to the password worker would violate its
        // model-context isolation.
        let targetID = target.targetID
        let legacyVaultAccounts = migrateLegacyCredential
            ? RDPPasswordStore.legacyVaultAccounts(
                username: target.username,
                host: target.host,
                port: target.port,
                domain: target.rdpProfile.domain
            )
            : []

        let password: String?
        do {
            if migrateLegacyCredential {
                password = try await RDPPasswordAccess.shared.readOrMigratePassword(
                    targetID: targetID,
                    legacyVaultAccounts: legacyVaultAccounts
                )
            } else {
                password = try await RDPPasswordAccess.shared.readPassword(targetID: targetID)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FreeRDPXPCFailure(
                code: "RDP_CREDENTIAL_ACCESS_FAILED",
                message: "JTS Terminal could not read the RDP credential from the encrypted vault: \(error.localizedDescription)"
            )
        }

        guard let password, !password.isEmpty else {
            throw FreeRDPXPCFailure(
                code: "RDP_CREDENTIAL_MISSING",
                message: "The RDP password is no longer available in the encrypted vault. Save it again before reconnecting."
            )
        }
        return password
    }

    private func reconnectFailure(
        from error: Error,
        phase: RDPConnectionPhase
    ) -> RDPReconnectFailure {
        if let xpcFailure = error as? FreeRDPXPCFailure {
            return RDPReconnectFailure(
                phase: phase,
                code: xpcFailure.code,
                message: xpcFailure.message
            )
        }
        if let toolError = error as? WindowsMCPToolError {
            return RDPReconnectFailure(
                phase: phase,
                code: toolError.code.rawValue,
                message: toolError.localizedDescription
            )
        }
        return RDPReconnectFailure(
            phase: phase,
            code: "RDP_XPC_START_FAILED",
            message: error.localizedDescription
        )
    }

    private func blockReconnect(active: ActiveDesktop, failure: RDPReconnectFailure) {
        active.reconnectSupervisor.block(after: failure)
        cancelReconnectTask(active: active)
    }

    private func beginConnectionAttempt(_ active: ActiveDesktop) {
        active.relayBridge?.stop(); active.relayBridge = nil
        active.transportRoute = .unknown
        let connectionAttemptID = UUID()
        active.connectionAttemptID = connectionAttemptID
        active.revisionLedger.beginAttempt(connectionAttemptID)
        active.invalidatedControlAttemptID = nil
    }

    /// Cancels AI work for one exact connection attempt without changing the
    /// persistent client grant. The attempt token makes duplicate `.failed`,
    /// `.closed`, and XPC invalidation callbacks idempotent, while the current
    /// session guard prevents a stale desktop from cancelling a reopened one.
    private func invalidateConnectionBoundAuthority(
        for active: ActiveDesktop,
        connectionAttemptID: UUID? = nil
    ) {
        guard isCurrent(active), targetBindingIsCurrent(active) else { return }
        if let connectionAttemptID {
            guard active.connectionAttemptID == connectionAttemptID,
                  active.invalidatedControlAttemptID != connectionAttemptID else {
                return
            }
            active.invalidatedControlAttemptID = connectionAttemptID
        }

        clearConnectionBoundAIActivityState(targetID: active.target.targetID)
    }

    private func invalidateAllAIAuthority(targetID: UUID) {
        clearAIActivityState(targetID: targetID)
    }

    private func cancelReconnectTask(active: ActiveDesktop) {
        active.reconnectTask?.cancel()
        active.reconnectTask = nil
        active.reconnectTaskID = nil
        active.state.reconnectAttempt = nil
        active.state.reconnectMaximumAttempts = nil
        active.state.reconnectScheduledAt = nil
    }

    private func cancelLocalNetworkDiagnostic(_ active: ActiveDesktop) {
        active.localNetworkDiagnosticTaskID = nil
        active.localNetworkDiagnosticTask?.cancel()
        active.localNetworkDiagnosticTask = nil
    }

    private func discardDesktopFrameState(_ active: ActiveDesktop) {
        active.latestFrame = nil
        active.latestSurface = nil
        active.recentFrameMetadataByID.removeAll(keepingCapacity: false)
        active.recentFrameIDs.removeAll(keepingCapacity: false)
        active.state.latestFrameID = nil
        active.state.remotePixelWidth = nil
        active.state.remotePixelHeight = nil
        imagesByTargetID.removeValue(forKey: active.target.targetID)
    }

    private func processConnectionFailure(
        _ originalFailure: RDPReconnectFailure,
        active: ActiveDesktop,
        allowPathDiagnosis: Bool
    ) {
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing else { return }
        // Every accepted failure supersedes an older diagnosis, even when the
        // helper remains in the same connection attempt. This prevents a late
        // transport probe from replacing a newer authentication, certificate,
        // or policy failure.
        cancelLocalNetworkDiagnostic(active)
        invalidateConnectionBoundAuthority(
            for: active,
            connectionAttemptID: active.connectionAttemptID
        )
        discardDesktopFrameState(active)

        let failure: RDPReconnectFailure
        if RDPLocalNetworkRecovery.isPathBlocked(code: originalFailure.code) {
            failure = RDPLocalNetworkRecovery.pathBlockedFailure(
                phase: originalFailure.phase
            )
        } else if RDPLocalNetworkRecovery.isDecisionPending(
            code: originalFailure.code
        ) {
            failure = RDPLocalNetworkRecovery.decisionPendingFailure(
                phase: originalFailure.phase
            )
        } else {
            failure = originalFailure
        }

        active.state.phase = .failed
        active.state.lastErrorCode = failure.code
        active.state.lastErrorMessage = failure.message

        if allowPathDiagnosis,
           active.transportRoute == .direct,
           RDPLocalNetworkRecovery.needsPathDiagnosis(failure),
           let endpoint = RDPLocalNetworkDiagnosticEndpoint(
               host: active.target.host,
               port: active.target.port
           ) {
            beginLocalNetworkPathDiagnosis(
                endpoint: endpoint,
                originalFailure: failure,
                active: active
            )
            publish(active)
            return
        }

        if !active.reconnectSupervisor.policy.permitsReconnect(
            phase: failure.phase,
            failureCode: failure.code
        ) {
            blockReconnect(active: active, failure: failure)
        } else if active.hasConnectedOnce || active.reconnectSupervisor.attemptCount > 0 {
            scheduleReconnect(active: active, failure: failure, runtimeUnavailable: false)
            return
        }
        publish(active)
    }

    private func beginLocalNetworkPathDiagnosis(
        endpoint: RDPLocalNetworkDiagnosticEndpoint,
        originalFailure: RDPReconnectFailure,
        active: ActiveDesktop
    ) {
        guard active.localNetworkDiagnosticTask == nil else { return }
        let diagnosticTaskID = UUID()
        let connectionAttemptID = active.connectionAttemptID
        let diagnosticMode = active.localNetworkDiagnosticMode
        let diagnoser = localNetworkDiagnoser
        active.localNetworkDiagnosticTaskID = diagnosticTaskID
        active.localNetworkDiagnosticTask = Task { @MainActor [weak self, weak active] in
            let result = await diagnoser(endpoint, diagnosticMode)
            guard let self, let active,
                  !Task.isCancelled,
                  self.isCurrent(active), self.targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == connectionAttemptID,
                  active.localNetworkDiagnosticTaskID == diagnosticTaskID,
                  active.state.phase == .failed else { return }
            active.localNetworkDiagnosticTask = nil
            active.localNetworkDiagnosticTaskID = nil

            if result == .permissionResolved {
                active.localNetworkDiagnosticMode = .initial
                self.scheduleReconnect(
                    active: active,
                    failure: originalFailure,
                    runtimeUnavailable: false
                )
                return
            }

            let resolvedFailure: RDPReconnectFailure
            switch result {
            case .pathBlocked:
                resolvedFailure = RDPLocalNetworkRecovery.pathBlockedFailure(
                    phase: originalFailure.phase
                )
            case .decisionPending:
                resolvedFailure = RDPLocalNetworkRecovery.decisionPendingFailure(
                    phase: originalFailure.phase
                )
            case .permissionResolved, .notDenied, .inconclusive:
                resolvedFailure = originalFailure
            }
            self.processConnectionFailure(
                resolvedFailure,
                active: active,
                allowPathDiagnosis: false
            )
        }
    }

    private func handleSurface(_ surface: IOSurface, metadata: [String: Any], active: ActiveDesktop) {
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              let rawConnectionAttemptID = metadata["connectionAttemptId"] as? String,
              UUID(uuidString: rawConnectionAttemptID) == active.connectionAttemptID,
              active.state.phase == .connected,
              active.invalidatedControlAttemptID != active.connectionAttemptID,
              certificateChallengesByTargetID[active.target.targetID] == nil else {
            return
        }
        do {
            let pixelData = try copyPixels(from: surface, metadata: metadata)
            handleFramePixels(
                pixelData,
                metadata: metadata,
                surface: surface,
                active: active
            )
        } catch AttemptScopedFrameError.stale {
            // The helper reuses its IOSurface. If it was repainted after this
            // callback was emitted, its seed no longer matches the metadata and
            // the newer callback is authoritative.
        } catch {
            publishFrameCopyFailure(error, active: active)
        }
    }

    private func handleFramePixels(
        _ pixels: Data,
        metadata: [String: Any],
        surface: IOSurface?,
        active: ActiveDesktop
    ) {
        do {
            let renderedFrame = try makeAttemptScopedRenderedFrame(
                pixels: pixels,
                metadata: metadata,
                active: active,
                connectionAttemptID: active.connectionAttemptID,
                encodePNG: false
            )
            let frame = renderedFrame.frame
            rememberFrameMetadata(frame.metadata, active: active)
            active.latestSurface = surface
            active.latestFrame = frame
            active.state.latestFrameID = frame.metadata.frameID
            active.state.stateRevision = frame.metadata.stateRevision
            active.state.remotePixelWidth = frame.metadata.pixelWidth
            active.state.remotePixelHeight = frame.metadata.pixelHeight
            imagesByTargetID[active.target.targetID] = renderedFrame.image
            publish(active)
        } catch AttemptScopedFrameError.stale {
            // Surface callbacks can arrive out of order. A newer frame already
            // displayed is authoritative, so the older callback is a no-op.
        } catch {
            publishFrameCopyFailure(error, active: active)
        }
    }

    private func publishFrameCopyFailure(_ error: Error, active: ActiveDesktop) {
        active.state.lastErrorCode = "FRAME_COPY_FAILED"
        active.state.lastErrorMessage = error.localizedDescription
        publish(active)
    }

    private func handleCertificate(_ value: [String: Any], active: ActiveDesktop) {
        guard let rawConnectionAttemptID = value["connectionAttemptId"] as? String,
              UUID(uuidString: rawConnectionAttemptID) == active.connectionAttemptID else {
            return
        }
        cancelLocalNetworkDiagnostic(active)
        let challenge = certificateChallenge(from: value, active: active)
        let targetID = active.target.targetID
        invalidateConnectionBoundAuthority(
            for: active,
            connectionAttemptID: active.connectionAttemptID
        )
        discardDesktopFrameState(active)
        if certificateChallengesByTargetID[targetID] == challenge,
           active.state.phase == .awaitingCertificateTrust {
            return
        }

        certificateChallengesByTargetID[targetID] = challenge
        let failureCode = challenge.changed ? "RDP_CERTIFICATE_CHANGED" : "RDP_CERTIFICATE_UNTRUSTED"
        let failureMessage = challenge.changed
            ? "The RDP certificate changed and the connection was blocked."
            : "Review the RDP certificate fingerprint before connecting."
        blockReconnect(
            active: active,
            failure: RDPReconnectFailure(
                phase: .awaitingCertificateTrust,
                code: failureCode,
                message: failureMessage
            )
        )
        active.state.phase = .awaitingCertificateTrust
        active.state.lastErrorCode = failureCode
        active.state.lastErrorMessage = failureMessage
        publish(active)
    }

    private func certificateChallenge(
        from value: [String: Any],
        active: ActiveDesktop
    ) -> RDPCertificateChallenge {
        let pinnedMismatch = value["pinnedMismatch"] as? Bool ?? false
        let changed = (value["changed"] as? Bool ?? false) || pinnedMismatch
        return RDPCertificateChallenge(
            host: value["host"] as? String ?? active.target.host,
            port: (value["port"] as? NSNumber)?.intValue ?? active.target.port,
            commonName: value["commonName"] as? String ?? "",
            subject: value["subject"] as? String ?? "",
            issuer: value["issuer"] as? String ?? "",
            sha256: value["sha256"] as? String ?? "",
            oldSHA256: (value["oldSha256"] as? String).flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            },
            changed: changed,
            hostMismatch: value["hostMismatch"] as? Bool ?? false,
            pinnedMismatch: pinnedMismatch
        )
    }

    private func scheduleCompanionHandshake(active: ActiveDesktop) {
        guard active.companionHandshakeTask == nil,
              active.state.phase == .connected,
              let companionDVCGeneration = active.companionDVCGeneration,
              companionDVCGeneration > 0,
              active.state.companion.availability == .unknown ||
                active.state.companion.availability == .missing else { return }
        let connectionAttemptID = active.connectionAttemptID
        let handshakeTaskID = UUID()
        let companionChannelID = UUID()
        active.companion?.cancelAll()
        active.companion = nil
        active.companionChannelID = companionChannelID
        active.companionHandshakeTaskID = handshakeTaskID
        active.companionHandshakeTask = Task { @MainActor [weak self, weak active] in
            guard let self, let active else { return }
            defer {
                if active.companionHandshakeTaskID == handshakeTaskID {
                    active.companionHandshakeTask = nil
                    active.companionHandshakeTaskID = nil
                }
            }
            guard active.companionHandshakeTaskID == handshakeTaskID,
                  active.companionChannelID == companionChannelID,
                  active.companionDVCGeneration == companionDVCGeneration,
                  (try? self.requireCurrentConnectedActionAttempt(
                      active,
                      expectedConnectionAttemptID: connectionAttemptID
                  )) != nil else {
                return
            }
            let companion = WindowsCompanionClient(sessionID: active.sessionID) { [weak self, weak active] data in
                guard let self, let active else {
                    throw WindowsCompanionRequestFailure(
                        code: "COMPANION_DISCONNECTED",
                        message: "The RDP desktop session closed.",
                        retryable: true
                    )
                }
                try await RDPCompanionChannelTransport.send(
                    data,
                    expectedChannelID: companionChannelID,
                    currentChannelID: { [weak active] in
                        active?.companionChannelID
                    },
                    transport: { [weak self, weak active] data in
                        guard let self, let active else {
                            throw WindowsCompanionRequestFailure(
                                code: "COMPANION_DISCONNECTED",
                                message: "The RDP desktop session closed.",
                                retryable: true
                            )
                        }
                        do {
                            try self.requireCurrentConnectedActionAttempt(
                                active,
                                expectedConnectionAttemptID: connectionAttemptID
                            )
                        } catch {
                            throw WindowsCompanionRequestFailure(
                                code: "COMPANION_CONNECTION_CHANGED",
                                message: "The RDP connection changed before the Companion message could be sent.",
                                retryable: true
                            )
                        }
                        try await active.xpc.sendDVCMessage(
                            data,
                            expectedChannelGeneration: companionDVCGeneration
                        )
                        do {
                            try self.requireCurrentConnectedActionAttempt(
                                active,
                                expectedConnectionAttemptID: connectionAttemptID
                            )
                        } catch {
                            throw WindowsCompanionRequestFailure(
                                code: "COMPANION_CONNECTION_CHANGED",
                                message: "The RDP connection changed while the Companion message was in flight.",
                                retryable: true
                            )
                        }
                    }
                )
            }
            active.companion = companion
            let companionAttemptIsCurrent: @MainActor () -> Bool = {
                guard active.companionHandshakeTaskID == handshakeTaskID else {
                    return false
                }
                guard active.companionChannelID == companionChannelID,
                      active.companionDVCGeneration == companionDVCGeneration else {
                    return false
                }
                return self.isCurrentCompanionAttempt(
                    active,
                    companion: companion,
                    expectedConnectionAttemptID: connectionAttemptID
                )
            }

            for delay in [500, 1_000, 2_000, 4_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard companionAttemptIsCurrent() else { return }
                do {
                    let peer = try await companion.performHello(targetID: active.target.targetID)
                    guard companionAttemptIsCurrent() else { return }
                    let stored = try await RDPCompanionKeychainAccess.shared.readPeerFingerprint(
                        targetID: active.target.targetID
                    )
                    guard companionAttemptIsCurrent() else { return }
                    if let stored, stored != peer.fingerprintSHA256 {
                        throw CompanionPairingDelegationFailure.identityChanged
                    }
                    self.companionPairingByTargetID[active.target.targetID] = peer
                    let delegation = try CompanionPairingDelegationStore.shared.activeGrant(
                        targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer
                    )
                    if !peer.clientAuthorization.pairingRequired,
                       stored == peer.fingerprintSHA256 || delegation != nil {
                        _ = try await companion.authorize(targetID: active.target.targetID, targetBinding: active.targetBinding)
                        guard companionAttemptIsCurrent() else { return }
                        try await RDPCompanionKeychainAccess.shared.savePeerFingerprint(
                            peer.fingerprintSHA256, targetID: active.target.targetID
                        )
                        guard companionAttemptIsCurrent() else { return }
                        active.state.companion = WindowsCompanionState(
                            availability: .ready,
                            protocolVersion: WindowsCompanionDVC.protocolVersion,
                            companionVersion: peer.agentVersion,
                            reason: nil
                        )
                        self.companionPairingByTargetID.removeValue(forKey: active.target.targetID)
                    } else if let stored, stored != peer.fingerprintSHA256 {
                        active.state.companion = WindowsCompanionState(
                            availability: .incompatible,
                            protocolVersion: WindowsCompanionDVC.protocolVersion,
                            companionVersion: peer.agentVersion,
                            reason: "The Windows Companion identity changed. Pairing was blocked before Mac authorization."
                        )
                    } else {
                        self.companionPairingByTargetID[active.target.targetID] = peer
                        if RDPCompanionDelegationPolicy.isEnabled(for: active.target) {
                            let exported = try await RDPCompanionDelegationPolicy.prepare(target: active.target, peer: peer)
                            guard companionAttemptIsCurrent() else { return }
                            self.companionDelegationExportsByTargetID[active.target.targetID] = exported
                        }
                        active.state.companion = WindowsCompanionState(
                            availability: .pairingRequired,
                            protocolVersion: WindowsCompanionDVC.protocolVersion,
                            companionVersion: peer.agentVersion,
                            reason: "Confirm the verified device fingerprint before enabling structured Windows tools."
                        )
                    }
                    self.publish(active)
                    return
                } catch let failure as FreeRDPXPCFailure where failure.code == "COMPANION_REQUIRED" {
                    guard companionAttemptIsCurrent() else { return }
                    continue
                } catch {
                    guard companionAttemptIsCurrent() else { return }
                    active.state.companion = WindowsCompanionState(
                        availability: .incompatible,
                        reason: error.localizedDescription
                    )
                    self.publish(active)
                    return
                }
            }
            guard companionAttemptIsCurrent() else { return }
            active.state.companion = .missing
            self.publish(active)
        }
    }

    private func performSemanticAction(
        active: ActiveDesktop,
        request: DesktopActionRequest,
        connectionAttemptID: UUID
    ) async throws {
        let method: String
        var parameters: [String: Any] = ["selector": semanticSelector(request.selector ?? "")]
        switch request.action {
        case .semanticInvoke:
            method = DVCOperation.uiaInvoke.rawValue
        case .semanticSetValue:
            method = DVCOperation.uiaSetValue.rawValue
            parameters["value"] = request.text ?? ""
        case .semanticSelect:
            method = "uia.select"
        case .wait:
            method = DVCOperation.uiaWait.rawValue
            parameters["timeoutMilliseconds"] = min(max(request.deadlineMilliseconds ?? 30_000, 100), 300_000)
        default:
            throw WindowsMCPToolError(code: .invalidArgument, message: "The semantic desktop action is invalid.")
        }
        try requireCurrentConnectedActionAttempt(
            active,
            expectedConnectionAttemptID: connectionAttemptID
        )
        _ = try await companionRequest(
            active: active,
            method: method,
            parameters: parameters,
            deadlineMilliseconds: request.deadlineMilliseconds,
            idempotencyKey: request.idempotencyKey,
            expectedStateRevision: request.expectedStateRevision
        )
    }

    private func performRawAction(
        active: ActiveDesktop,
        request: DesktopActionRequest,
        localManualFrame: DesktopFrameMetadata? = nil,
        connectionAttemptID: UUID
    ) async throws {
        try requireCurrentConnectedActionAttempt(
            active,
            expectedConnectionAttemptID: connectionAttemptID
        )
        switch request.action {
        case .movePointer:
            try await sendMouse(active, request, action: "move", localManualFrame: localManualFrame)
        case .click:
            try await sendMouse(active, request, action: "click", localManualFrame: localManualFrame)
        case .doubleClick:
            try await sendMouse(
                active,
                request,
                action: "doubleClick",
                localManualFrame: localManualFrame
            )
        case .mouseDown:
            try await sendMouse(active, request, action: "down", localManualFrame: localManualFrame)
        case .mouseUp:
            try await sendMouse(active, request, action: "up", localManualFrame: localManualFrame)
        case .scroll:
            try await sendMouse(active, request, action: "scroll", localManualFrame: localManualFrame)
        case .typeText:
            var input: [String: Any] = [
                "type": "text",
                "text": request.text ?? "",
                "expectedStateRevision": request.expectedStateRevision,
            ]
            if localManualFrame != nil {
                input["inputOrigin"] = "localManual"
            }
            try await sendDesktopInput(
                active: active,
                input,
                deadlineMilliseconds: request.deadlineMilliseconds
            )
        case .keyDown, .keyUp:
            let scanCode = try Self.scanCode(for: request.key)
            var input: [String: Any] = [
                "type": "scancode",
                "scancode": scanCode,
                "down": request.action == .keyDown,
                "repeat": false,
                "expectedStateRevision": request.expectedStateRevision,
            ]
            if localManualFrame != nil {
                input["inputOrigin"] = "localManual"
            }
            try await sendDesktopInput(
                active: active,
                input,
                deadlineMilliseconds: request.deadlineMilliseconds
            )
        case .keyChord:
            let codes = try (request.keyChord ?? []).map(Self.scanCode(for:))
            guard (1...32).contains(codes.count) else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Key chords require one to thirty-two key identifiers."
                )
            }
            var input: [String: Any] = [
                "type": "keyChord",
                "scancodes": codes,
                "expectedStateRevision": request.expectedStateRevision,
            ]
            if localManualFrame != nil {
                input["inputOrigin"] = "localManual"
            }
            try await sendDesktopInput(
                active: active,
                input,
                deadlineMilliseconds: request.deadlineMilliseconds
            )
        case .semanticInvoke, .semanticSetValue, .semanticSelect, .wait:
            break
        }
    }

    private func sendMouse(
        _ active: ActiveDesktop,
        _ request: DesktopActionRequest,
        action: String,
        localManualFrame: DesktopFrameMetadata?
    ) async throws {
        guard let point = request.point else {
            throw WindowsMCPToolError(code: .invalidArgument, message: "Mouse actions require framebuffer coordinates.")
        }
        var input: [String: Any] = [
            "type": "mouse",
            "action": action,
            "x": point.x,
            "y": point.y,
            "expectedFrameId": request.expectedFrameID?.uuidString.lowercased() ?? "",
            "expectedStateRevision": request.expectedStateRevision,
            "button": request.mouseButton?.rawValue ?? DesktopMouseButton.left.rawValue,
            "deltaX": request.scrollDeltaX ?? 0,
            "deltaY": request.scrollDeltaY ?? 0,
        ]
        if let localManualFrame {
            input["inputOrigin"] = "localManual"
            input["coordinateSpaceWidth"] = localManualFrame.pixelWidth
            input["coordinateSpaceHeight"] = localManualFrame.pixelHeight
        }
        try await sendDesktopInput(
            active: active,
            input,
            deadlineMilliseconds: request.deadlineMilliseconds
        )
    }

    func sendDesktopInput(
        active: ActiveDesktop,
        _ input: [String: Any],
        deadlineMilliseconds: Int?
    ) async throws {
        if let inputExecutor {
            try await inputExecutor(input, deadlineMilliseconds)
        } else {
            try await active.xpc.sendInput(
                input,
                deadlineMilliseconds: deadlineMilliseconds
            )
        }
    }

    func companionRequest(
        sessionID: UUID,
        method: String,
        parameters: [String: Any],
        deadlineMilliseconds: Int?,
        idempotencyKey: String?,
        expectedStateRevision: UInt64?
    ) async throws -> [String: Any] {
        guard let active = desktopsBySessionID[sessionID] else {
            throw WindowsMCPToolError(code: .targetNotFound, message: "The RDP desktop session is not open.")
        }
        return try await companionRequest(
            active: active,
            method: method,
            parameters: parameters,
            deadlineMilliseconds: deadlineMilliseconds,
            idempotencyKey: idempotencyKey,
            expectedStateRevision: expectedStateRevision
        )
    }

    func uploadCompanionBinary(
        sessionID: UUID,
        data: Data,
        purpose: String,
        deadlineMilliseconds: Int?,
        maximumBytes: Int64 = WindowsCompanionBinaryTransferManager.maximumTransferBytes
    ) async throws -> DVCBinaryTransferDescriptor {
        let companion = try readyCompanion(sessionID: sessionID)
        return try await companion.uploadBinary(
            data,
            purpose: purpose,
            deadlineMilliseconds: deadlineMilliseconds,
            maximumBytes: maximumBytes
        )
    }

    func downloadCompanionBinary(
        sessionID: UUID,
        descriptor: DVCBinaryTransferDescriptor,
        deadlineMilliseconds: Int?,
        maximumBytes: Int64 = WindowsCompanionBinaryTransferManager.maximumTransferBytes
    ) async throws -> Data {
        let companion = try readyCompanion(sessionID: sessionID)
        return try await companion.downloadBinary(
            descriptor,
            deadlineMilliseconds: deadlineMilliseconds,
            maximumBytes: maximumBytes
        )
    }

    func releaseCompanionBinary(
        sessionID: UUID,
        transferID: UUID,
        deadlineMilliseconds: Int?
    ) async {
        guard let active = desktopsBySessionID[sessionID], let companion = active.companion else {
            return
        }
        await companion.releaseBinary(transferID, deadlineMilliseconds: deadlineMilliseconds)
    }

    func companionPeerIdentity(sessionID: UUID) throws -> WindowsCompanionPeerIdentity {
        let companion = try readyCompanion(sessionID: sessionID)
        guard let identity = companion.peerIdentity else {
            throw WindowsMCPToolError(
                code: .companionRequired,
                message: "The paired Windows Companion identity is unavailable. Reconnect and authorize the Companion before continuing."
            )
        }
        return identity
    }

    private func readyCompanion(sessionID: UUID) throws -> WindowsCompanionClient {
        guard let active = desktopsBySessionID[sessionID] else {
            throw WindowsMCPToolError(code: .targetNotFound, message: "The RDP desktop session is not open.")
        }
        guard active.state.companion.availability == .ready,
              let companion = active.companion else {
            throw WindowsMCPToolError.companionRequired
        }
        return companion
    }

    private func currentCompanionIdentity(targetID: UUID) -> WindowsCompanionPeerIdentity? {
        guard let sessionID = sessionIDByTargetID[targetID],
              let active = desktopsBySessionID[sessionID],
              active.state.companion.availability == .ready else {
            return nil
        }
        return active.companion?.peerIdentity
    }

    private func companionRequest(
        active: ActiveDesktop,
        method: String,
        parameters: [String: Any],
        deadlineMilliseconds: Int?,
        idempotencyKey: String?,
        expectedStateRevision: UInt64?
    ) async throws -> [String: Any] {
        guard active.state.companion.availability == .ready,
              let companion = active.companion else {
            throw WindowsMCPToolError.companionRequired
        }
        try requireAIClipboardIsolationReady(active)
        let connectionAttemptID = active.connectionAttemptID
        try requireCurrentCompanionAttempt(
            active,
            companion: companion,
            expectedConnectionAttemptID: connectionAttemptID
        )
        let isElevationPrompt = method == DVCOperation.elevationRequest.rawValue
        let elevationPromptOperationID = isElevationPrompt ? UUID() : nil
        if isElevationPrompt {
            guard !active.elevationPromptInProgress,
                  active.elevationPromptOperationID == nil else {
                throw WindowsMCPToolError(
                    code: .sensitiveInteractionActive,
                    message: "Another Windows elevation request is already awaiting human review."
                )
            }
            active.elevationPromptInProgress = true
            active.elevationPromptOperationID = elevationPromptOperationID
        }
        defer {
            if let elevationPromptOperationID,
               active.elevationPromptOperationID == elevationPromptOperationID {
                active.elevationPromptInProgress = false
                active.elevationPromptOperationID = nil
            }
        }
        let result = try await companion.request(
            method: method,
            parameters: parameters,
            deadlineMilliseconds: deadlineMilliseconds,
            idempotencyKey: idempotencyKey,
            expectedStateRevision: expectedStateRevision
        )
        try requireCurrentCompanionAttempt(
            active,
            companion: companion,
            expectedConnectionAttemptID: connectionAttemptID
        )
        return result
    }

    private func close(
        active: ActiveDesktop,
        removePublishedState: Bool = true,
        cancelConnectionBoundOperations: Bool = true
    ) async {
        if cancelConnectionBoundOperations {
            invalidateConnectionBoundAuthority(for: active)
        }
        active.intentionallyClosing = true
        active.relayBridge?.stop(); active.relayBridge = nil
        if let installationTask = active.companionInstallationTask {
            active.companionInstallationCancellationState = .idle
            companionInstallationStatesByTargetID[active.target.targetID] = .idle
            installationTask.cancel()
            await installationTask.value
        }
        stopClipboardSync(active, discardSynchronizer: true)
        active.reconnectSupervisor.stop()
        active.reconnectTask?.cancel()
        active.reconnectTask = nil
        active.reconnectTaskID = nil
        cancelLocalNetworkDiagnostic(active)
        cancelCompanionMissingTask(active)
        active.companionHandshakeTask?.cancel()
        active.companionAuthorizationTask?.cancel()
        active.companionChannelID = nil
        active.companion?.cancelAll()
        await active.xpc.disconnect()
        if desktopsBySessionID[active.sessionID] === active {
            desktopsBySessionID.removeValue(forKey: active.sessionID)
        }
        guard sessionIDByTargetID[active.target.targetID] == active.sessionID else {
            return
        }
        sessionIDByTargetID.removeValue(forKey: active.target.targetID)
        certificateChallengesByTargetID.removeValue(forKey: active.target.targetID)
        companionPairingByTargetID.removeValue(forKey: active.target.targetID)
        companionDelegationExportsByTargetID.removeValue(forKey: active.target.targetID)
        companionInstallationStatesByTargetID.removeValue(
            forKey: active.target.targetID
        )
        imagesByTargetID.removeValue(forKey: active.target.targetID)
        if removePublishedState {
            var state = active.state
            state.phase = .closed
            state.companion = .unknown
            state.stateRevision = 0
            state.latestFrameID = nil
            state.remotePixelWidth = nil
            state.remotePixelHeight = nil
            state.reconnectAttempt = nil
            state.reconnectMaximumAttempts = nil
            state.reconnectScheduledAt = nil
            state.lastErrorCode = nil
            state.lastErrorMessage = nil
            statesByTargetID[active.target.targetID] = state
            openIdempotencyLedger.updateSuccessState(state)
        }
    }

    func publish(_ active: ActiveDesktop) {
        if active.companionInstallationTaskID == nil {
            let targetID = active.target.targetID
            let installation =
                companionInstallationStatesByTargetID[targetID] ?? .idle
            switch active.state.companion.availability {
            case .pairingRequired:
                companionInstallationStatesByTargetID[targetID] =
                    WindowsCompanionInstallationState(phase: .pairingRequired)
            case .ready:
                companionInstallationStatesByTargetID[targetID] =
                    WindowsCompanionInstallationState(phase: .ready)
            case .unknown, .incompatible:
                if installation.isCompleted {
                    companionInstallationStatesByTargetID[targetID] = .idle
                }
            case .missing:
                if installation.isCompleted {
                    companionInstallationStatesByTargetID[targetID] = .idle
                }
            }
        }
        statesByTargetID[active.target.targetID] = active.state
        openIdempotencyLedger.updateSuccessState(active.state)
    }

    private func publishFailure(target: RemoteSession, error: Error) {
        statesByTargetID[target.targetID] = RDPDesktopSessionState(
            sessionID: UUID(),
            targetID: target.targetID,
            phase: .failed,
            runtimeAvailability: .unavailable,
            companion: .unknown,
            stateRevision: 0,
            latestFrameID: nil,
            remotePixelWidth: nil,
            remotePixelHeight: nil,
            connectedAt: nil,
            reconnectAttempt: nil,
            reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil,
            lastErrorCode: "RDP_OPEN_FAILED",
            lastErrorMessage: error.localizedDescription
        )
    }

    private func publishInputFailure(
        active: ActiveDesktop,
        expectedConnectionAttemptID: UUID,
        error: Error
    ) {
        guard (try? requireCurrentConnectedActionAttempt(
            active,
            expectedConnectionAttemptID: expectedConnectionAttemptID
        )) != nil else { return }
        active.inputFailureGeneration = Self.nextGeneration(
            current: active.inputFailureGeneration
        )
        active.state.lastErrorCode = RDPDesktopInputFailurePolicy.machineCode(for: error)
        active.state.lastErrorMessage = error.localizedDescription
        publish(active)
    }

    private func clearPublishedInputFailure(
        active: ActiveDesktop,
        matchingGeneration: UInt64
    ) {
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.inputFailureGeneration == matchingGeneration,
              active.state.phase == .connected,
              RDPDesktopInputFailurePolicy.isTransientInputFailureCode(
                  active.state.lastErrorCode
              ) else { return }
        active.state.lastErrorCode = nil
        active.state.lastErrorMessage = nil
        publish(active)
    }

    private func rememberFrameMetadata(
        _ metadata: DesktopFrameMetadata,
        active: ActiveDesktop
    ) {
        guard active.recentFrameMetadataByID[metadata.frameID] == nil else { return }
        active.recentFrameMetadataByID[metadata.frameID] = metadata
        active.recentFrameIDs.append(metadata.frameID)
        let overflow = active.recentFrameIDs.count - Self.retainedManualFrameMetadataCount
        guard overflow > 0 else { return }
        let evicted = active.recentFrameIDs.prefix(overflow)
        active.recentFrameIDs.removeFirst(overflow)
        for frameID in evicted {
            active.recentFrameMetadataByID.removeValue(forKey: frameID)
        }
    }

    nonisolated private static func sortAIClientIdentities(
        _ lhs: RDPActiveAIClientIdentity,
        _ rhs: RDPActiveAIClientIdentity
    ) -> Bool {
        if lhs.displayIdentity == rhs.displayIdentity {
            return lhs.authorizationID < rhs.authorizationID
        }
        return lhs.displayIdentity < rhs.displayIdentity
    }

    func beginAuthorizedOperation(
        targetID: UUID,
        targetBinding: String,
        clientID: String,
        displayIdentity: String,
        capabilities: Set<RemoteCapability>,
        survivesConnectionTransition: Bool = false,
        deferClipboardSuspensionUntilPreparation: Bool = false,
        startedAt: Date = Date()
    ) throws -> RDPAuthorizedOperationToken {
        guard targetsByID[targetID]?.mcpGrantTargetBinding == targetBinding else {
            throw WindowsMCPToolError(
                code: .permissionDenied,
                message: "The saved target changed before this AI operation started. Retry after reviewing access for the current endpoint.",
                details: ["authorizationCode": "TARGET_BINDING_CHANGED"]
            )
        }
        let authorizationID = MCPAuditRecordPolicy.clientIdentifier(clientID)
        let showsControlActivity = !capabilities.isDisjoint(
            with: RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities
        )
        if showsControlActivity,
           let sessionID = sessionIDByTargetID[targetID],
           desktopsBySessionID[sessionID]?.companionInstallationTaskID != nil {
            throw WindowsMCPToolError(
                code: .sensitiveInteractionActive,
                message: "AI control is paused while the user-initiated Windows Companion installation is running."
            )
        }
        if showsControlActivity,
           let conflictingActivity = authorizedOperationsByTargetID[targetID]?.values.first(where: {
               guard $0.token.showsControlActivity else { return false }
               let retainedOperationIsCurrent =
                   isCurrentAuthorizedOperation($0.token) &&
                   $0.token.targetBinding == targetBinding
               return !retainedOperationIsCurrent ||
                   $0.token.clientID != authorizationID
           }) {
            throw WindowsMCPToolError(
                code: .permissionDenied,
                message: "Another authorized AI client is currently operating this Windows target. Retry after that operation finishes or stop the active operation manually.",
                details: [
                    "authorizationCode": "AI_CONTROL_OPERATION_CONFLICT",
                    "activeClient": conflictingActivity.displayIdentity,
                ]
            )
        }
        let token = RDPAuthorizedOperationToken(
            operationID: UUID(),
            targetID: targetID,
            targetBinding: targetBinding,
            clientID: authorizationID,
            generation: authorityGenerationByTargetID[targetID] ?? 0,
            connectionGeneration: connectionAuthorityGenerationByTargetID[targetID] ?? 0,
            showsControlActivity: showsControlActivity,
            showsViewingActivity: capabilities.contains(.desktopObserve),
            survivesConnectionTransition: survivesConnectionTransition
        )
        authorizedOperationsByTargetID[targetID, default: [:]][token.operationID] =
            AuthorizedOperationActivity(
                token: token,
                displayIdentity: MCPAuditRecordPolicy.clientIdentifier(displayIdentity),
                startedAt: startedAt,
                cancel: nil
            )
        if showsControlActivity,
           !deferClipboardSuspensionUntilPreparation,
           let sessionID = sessionIDByTargetID[targetID],
           let active = desktopsBySessionID[sessionID],
           active.targetBinding == targetBinding,
           isCurrent(active), !active.intentionallyClosing {
            suspendClipboardForAI(active)
        }
        objectWillChange.send()
        return token
    }

    /// Establishes a protocol-level clipboard barrier before an authorized AI
    /// control operation can dispatch its first remote mutation. The helper's
    /// XPC reply is intentionally delayed until Windows acknowledges the empty
    /// `CB_FORMAT_LIST`; a send-only acknowledgement is not sufficient because
    /// Windows may still have a previously materialized clipboard value.
    func prepareAuthorizedOperation(
        _ token: RDPAuthorizedOperationToken
    ) async throws {
        guard token.showsControlActivity else { return }
        try requireAuthorizedOperation(token)
        guard let sessionID = sessionIDByTargetID[token.targetID],
              let active = desktopsBySessionID[sessionID],
              active.targetBinding == token.targetBinding,
              isCurrent(active), !active.intentionallyClosing,
              active.state.phase == .connected else {
            // An operation that opens a new desktop starts with clipboard sync
            // suppressed by the token. A later operation on that connected
            // desktop must pass the barrier before it can control the session.
            return
        }
        guard active.target.rdpProfile.clipboardEnabled else { return }

        suspendClipboardForAI(active)
        let expectedAttemptID = active.connectionAttemptID
        if let resumeTask = active.clipboardAIResumeTask,
           active.clipboardAIResumeAttemptID == expectedAttemptID {
            // A new control operation may arrive while the final human
            // clipboard value is being restored. Let that ordered XPC
            // mutation finish, keep app intake suppressed, then establish a
            // fresh empty-format barrier before dispatching any AI input.
            await resumeTask.value
            try requireAuthorizedOperation(token)
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == expectedAttemptID else {
                throw CancellationError()
            }
        }
        if active.clipboardAIIsolationReadyAttemptID == expectedAttemptID {
            try requireAuthorizedOperation(token)
            return
        }

        let isolationTask: Task<Void, Error>
        let isolationTaskID: UUID
        if let existing = active.clipboardAIIsolationTask,
           let existingID = active.clipboardAIIsolationTaskID,
           active.clipboardAIIsolationAttemptID == expectedAttemptID {
            isolationTask = existing
            isolationTaskID = existingID
        } else {
            active.clipboardAIIsolationTask?.cancel()
            let taskID = UUID()
            let barrier = clipboardIsolationBarrier
            let xpc = active.xpc
            let task = Task { @MainActor in
                try Task.checkCancellation()
                if let barrier {
                    try await barrier(xpc, true, nil)
                } else {
                    try await xpc.setClipboardIsolation(true, text: nil)
                }
                try Task.checkCancellation()
            }
            active.clipboardAIIsolationTask = task
            active.clipboardAIIsolationTaskID = taskID
            active.clipboardAIIsolationAttemptID = expectedAttemptID
            isolationTask = task
            isolationTaskID = taskID
        }

        do {
            try await isolationTask.value
            let barrierIsCurrent =
                active.clipboardAIIsolationReadyAttemptID == expectedAttemptID ||
                active.clipboardAIIsolationTaskID == isolationTaskID
            guard isCurrent(active), targetBindingIsCurrent(active),
                  !active.intentionallyClosing,
                  active.connectionAttemptID == expectedAttemptID,
                  barrierIsCurrent else {
                throw CancellationError()
            }
            // Multiple operations from the same authorized client share one
            // protocol barrier. The first waiter records readiness; later
            // waiters must still be allowed to pass after the task slot clears.
            if active.clipboardAIIsolationTaskID == isolationTaskID {
                active.clipboardAIIsolationReadyAttemptID = expectedAttemptID
                active.clipboardAIIsolationTask = nil
                active.clipboardAIIsolationTaskID = nil
                active.clipboardAIIsolationAttemptID = nil
            }
            try Task.checkCancellation()
            try requireAuthorizedOperation(token)
        } catch {
            if active.clipboardAIIsolationTaskID == isolationTaskID,
               active.clipboardAIIsolationReadyAttemptID != expectedAttemptID {
                active.clipboardAIIsolationTask = nil
                active.clipboardAIIsolationTaskID = nil
                active.clipboardAIIsolationAttemptID = nil
                active.clipboardAIIsolationReadyAttemptID = nil
            }
            throw error
        }
    }

    func attachAuthorizedOperationCancellation(
        _ token: RDPAuthorizedOperationToken,
        cancel: @escaping () -> Void
    ) {
        guard var activities = authorizedOperationsByTargetID[token.targetID],
              var activity = activities[token.operationID],
              activity.token == token else {
            cancel()
            return
        }
        activity.cancel = cancel
        activities[token.operationID] = activity
        authorizedOperationsByTargetID[token.targetID] = activities
    }

    func finishAuthorizedOperation(_ token: RDPAuthorizedOperationToken) {
        guard var activities = authorizedOperationsByTargetID[token.targetID],
              activities.removeValue(forKey: token.operationID) != nil else {
            return
        }
        if activities.isEmpty {
            authorizedOperationsByTargetID.removeValue(forKey: token.targetID)
        } else {
            authorizedOperationsByTargetID[token.targetID] = activities
        }
        if !hasAnyAIControlActivity(targetID: token.targetID),
           let sessionID = sessionIDByTargetID[token.targetID],
           let active = desktopsBySessionID[sessionID],
           active.targetBinding == token.targetBinding,
           isCurrent(active), !active.intentionallyClosing,
           active.clipboardSuspendedForAI {
            resumeClipboardAfterAI(active)
        }
        objectWillChange.send()
    }

    private func hasAnyAIControlActivity(targetID: UUID) -> Bool {
        authorizedOperationsByTargetID[targetID]?.values.contains {
            $0.token.showsControlActivity
        } ?? false
    }

    private func suspendClipboardForAI(_ active: ActiveDesktop) {
        guard active.target.rdpProfile.clipboardEnabled else {
            active.clipboardSuspendedForAI = false
            return
        }
        active.clipboardSuspendedForAI = true
        stopClipboardSync(active)
    }

    private func resumeClipboardAfterAI(_ active: ActiveDesktop) {
        guard active.target.rdpProfile.clipboardEnabled else {
            active.clipboardAIIsolationTask?.cancel()
            active.clipboardAIIsolationTask = nil
            active.clipboardAIIsolationTaskID = nil
            active.clipboardAIIsolationAttemptID = nil
            active.clipboardAIIsolationReadyAttemptID = nil
            active.clipboardAIResumeTask?.cancel()
            active.clipboardAIResumeTask = nil
            active.clipboardAIResumeTaskID = nil
            active.clipboardAIResumeAttemptID = nil
            active.clipboardSuspendedForAI = false
            return
        }
        active.clipboardAIIsolationTask?.cancel()
        active.clipboardAIIsolationTask = nil
        active.clipboardAIIsolationTaskID = nil
        active.clipboardAIIsolationAttemptID = nil
        active.clipboardAIIsolationReadyAttemptID = nil
        if active.clipboardAIResumeTask != nil,
           active.clipboardAIResumeAttemptID == active.connectionAttemptID {
            return
        }
        active.clipboardAIResumeTask?.cancel()
        let taskID = UUID()
        let expectedAttemptID = active.connectionAttemptID
        let xpc = active.xpc
        let barrier = clipboardIsolationBarrier
        let synchronizer = active.clipboardSynchronizer ?? RDPTextClipboardSynchronizer()
        active.clipboardSynchronizer = synchronizer
        active.clipboardSuspendedForAI = true
        active.clipboardAIResumeTaskID = taskID
        active.clipboardAIResumeAttemptID = expectedAttemptID
        active.clipboardAIResumeTask = Task { @MainActor [weak self, weak active] in
            do {
                let payload = try synchronizer.currentPayload()
                if let barrier {
                    try await barrier(xpc, false, payload)
                } else {
                    try await xpc.setClipboardIsolation(false, text: payload)
                }
                try Task.checkCancellation()
                guard let self, let active,
                      self.isCurrent(active), self.targetBindingIsCurrent(active),
                      !active.intentionallyClosing,
                      active.connectionAttemptID == expectedAttemptID,
                      active.clipboardAIResumeTaskID == taskID else {
                    return
                }
                active.clipboardAIResumeTask = nil
                active.clipboardAIResumeTaskID = nil
                active.clipboardAIResumeAttemptID = nil
                guard !self.hasAnyAIControlActivity(
                    targetID: active.target.targetID
                ) else {
                    active.clipboardSuspendedForAI = true
                    return
                }
                active.clipboardSuspendedForAI = false
                self.startClipboardSync(active)
            } catch {
                guard let self, let active,
                      self.isCurrent(active),
                      active.clipboardAIResumeTaskID == taskID else {
                    return
                }
                active.clipboardAIResumeTask = nil
                active.clipboardAIResumeTaskID = nil
                active.clipboardAIResumeAttemptID = nil
                // Fail closed. The next human paste or connection retry shows
                // a bounded clipboard-not-ready error instead of reopening an
                // unacknowledged remote-to-local channel.
                active.clipboardSuspendedForAI = true
            }
        }
    }

    private func requireAIClipboardIsolationReady(
        _ active: ActiveDesktop
    ) throws {
        guard active.target.rdpProfile.clipboardEnabled,
              hasAnyAIControlActivity(targetID: active.target.targetID) else {
            return
        }
        guard active.clipboardSuspendedForAI,
              active.clipboardAIIsolationReadyAttemptID
                == active.connectionAttemptID else {
            throw WindowsMCPToolError(
                code: .stateConflict,
                message: "AI control is waiting for Windows to acknowledge clipboard isolation. Retry after the connected session is ready.",
                details: [
                    "machineCode": "RDP_CLIPBOARD_ISOLATION_PENDING",
                    "retryable": true,
                ]
            )
        }
    }

    private static func isClipboardPasteRequest(
        _ request: DesktopActionRequest
    ) -> Bool {
        guard request.action == .keyChord else { return false }
        let chord = request.keyChord?.map { $0.lowercased() } ?? []
        return chord == ["control", "v"]
    }

    private func prepareManualClipboardPaste(
        _ active: ActiveDesktop
    ) async throws {
        guard active.target.rdpProfile.clipboardEnabled else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while hasAnyAIControlActivity(targetID: active.target.targetID) ||
            active.clipboardSuspendedForAI {
            guard ContinuousClock.now < deadline else {
                throw FreeRDPXPCFailure(
                    code: "RDP_CLIPBOARD_CONTROL_DRAIN_TIMEOUT",
                    message: "Paste waited for the stopped AI operation to release clipboard isolation."
                )
            }
            try await Task.sleep(for: .milliseconds(10))
            try Task.checkCancellation()
        }
        guard isCurrent(active), targetBindingIsCurrent(active),
              !active.intentionallyClosing,
              active.state.phase == .connected,
              !active.clipboardSuspendedForAI,
              let synchronizer = active.clipboardSynchronizer else {
            throw FreeRDPXPCFailure(
                code: "RDP_CLIPBOARD_NOT_READY",
                message: "The text clipboard is not ready for this RDP session."
            )
        }
        // The synchronizer's sender completes only after Windows returns the
        // matching CB_FORMAT_LIST_RESPONSE, so Ctrl+V cannot overtake the new
        // Mac clipboard value on another RDP channel.
        try await synchronizer.publishCurrent(force: true)
    }

    func requireAuthorizedOperation(
        _ token: RDPAuthorizedOperationToken,
        ignoringCurrentTaskCancellation: Bool = false
    ) throws {
        guard (ignoringCurrentTaskCancellation || !Task.isCancelled),
              isCurrentAuthorizedOperation(token),
              authorizedOperationsByTargetID[token.targetID]?[token.operationID]?.token == token else {
            throw WindowsMCPToolError(
                code: .permissionDenied,
                message: "AI authority was revoked before the remote operation could continue.",
                details: ["authorizationCode": "AUTHORITY_REVOKED_DURING_OPERATION"]
            )
        }
        guard targetsByID[token.targetID]?.mcpGrantTargetBinding == token.targetBinding else {
            throw WindowsMCPToolError(
                code: .permissionDenied,
                message: "The saved target changed while this AI operation was running. Retry after reviewing access for the current endpoint.",
                details: ["authorizationCode": "TARGET_BINDING_CHANGED"]
            )
        }
    }

    private func isCurrentAuthorizedOperation(
        _ token: RDPAuthorizedOperationToken
    ) -> Bool {
        let fullAuthorityIsCurrent =
            authorityGenerationByTargetID[token.targetID] == token.generation ||
            (authorityGenerationByTargetID[token.targetID] == nil && token.generation == 0)
        guard fullAuthorityIsCurrent else { return false }
        return isCurrentConnectionAuthority(token)
    }

    private func isCurrentConnectionAuthority(
        _ token: RDPAuthorizedOperationToken
    ) -> Bool {
        guard !token.survivesConnectionTransition else { return true }
        return connectionAuthorityGenerationByTargetID[token.targetID]
            == token.connectionGeneration ||
            (connectionAuthorityGenerationByTargetID[token.targetID] == nil &&
                token.connectionGeneration == 0)
    }

    func revokeAuthorizedOperations(targetID: UUID) {
        let currentGeneration = authorityGenerationByTargetID[targetID] ?? 0
        authorityGenerationByTargetID[targetID] = Self.nextGeneration(
            current: currentGeneration
        )
        let cancellations: [() -> Void] =
            authorizedOperationsByTargetID[targetID]?.values.compactMap {
                activity -> (() -> Void)? in
                guard activity.token.generation == currentGeneration,
                      isCurrentConnectionAuthority(activity.token) else {
                    return nil
                }
                return activity.cancel
            } ?? []
        for cancel in cancellations {
            cancel()
        }
        objectWillChange.send()
    }

    /// Ends work that is bound to the current Windows connection without
    /// cancelling management calls whose purpose is to report or change that
    /// connection state. Human takeover and Emergency Stop still use the
    /// generation-based full revocation above.
    func revokeConnectionBoundAuthorizedOperations(targetID: UUID) {
        let currentGeneration = connectionAuthorityGenerationByTargetID[targetID] ?? 0
        connectionAuthorityGenerationByTargetID[targetID] = Self.nextGeneration(
            current: currentGeneration
        )
        let cancellations = authorizedOperationsByTargetID[targetID]?.values.compactMap {
            activity -> (() -> Void)? in
            guard !activity.token.survivesConnectionTransition,
                  activity.token.connectionGeneration == currentGeneration else {
                return nil
            }
            return activity.cancel
        } ?? []
        for cancel in cancellations {
            cancel()
        }
        objectWillChange.send()
    }

    func markAIViewing(
        targetID: UUID,
        clientID: String,
        displayIdentity: String
    ) {
        markAIViewing(
            targetID: targetID,
            clientID: clientID,
            displayIdentity: displayIdentity,
            observedAt: Date(),
            activityWindow: Self.aiViewingActivityWindow
        )
    }

    func markAIViewing(
        targetID: UUID,
        clientID: String,
        displayIdentity: String,
        observedAt: Date,
        activityWindow: TimeInterval
    ) {
        let authorizationID = MCPAuditRecordPolicy.clientIdentifier(clientID)
        let identity = MCPAuditRecordPolicy.clientIdentifier(displayIdentity)
        let boundedActivityWindow = max(activityWindow, 0)
        aiViewingActivityByTargetID[targetID, default: [:]][authorizationID] = AIViewingActivity(
            displayIdentity: identity,
            lastObservedAt: observedAt,
            activityWindow: boundedActivityWindow
        )
        scheduleAIViewingExpiry(targetID: targetID)
    }

    private func scheduleAIViewingExpiry(targetID: UUID) {
        aiViewingExpiryTasksByTargetID[targetID]?.cancel()
        guard let activities = aiViewingActivityByTargetID[targetID],
              let expiresAt = activities.values.map(\.expiresAt).min() else {
            aiViewingExpiryTasksByTargetID.removeValue(forKey: targetID)
            aiViewingExpiryGenerationByTargetID.removeValue(forKey: targetID)
            return
        }

        let generation = Self.nextGeneration(
            current: aiViewingExpiryGenerationByTargetID[targetID]
        )
        aiViewingExpiryGenerationByTargetID[targetID] = generation
        let delay = max(expiresAt.timeIntervalSinceNow, 0)
        aiViewingExpiryTasksByTargetID[targetID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.aiViewingExpiryGenerationByTargetID[targetID] == generation else {
                return
            }
            self.expireInactiveAIViewingClients(targetID: targetID, now: Date())
        }
    }

    private func expireInactiveAIViewingClients(targetID: UUID, now: Date) {
        guard var activities = aiViewingActivityByTargetID[targetID] else {
            clearAIViewingState(targetID: targetID)
            return
        }
        activities = activities.filter { $0.value.expiresAt > now }
        if activities.isEmpty {
            clearAIViewingState(targetID: targetID)
        } else {
            aiViewingActivityByTargetID[targetID] = activities
            scheduleAIViewingExpiry(targetID: targetID)
        }
    }

    nonisolated private static func nextGeneration(current: UInt64?) -> UInt64 {
        let generation = current ?? 0
        return generation == .max ? 0 : generation + 1
    }

    func clearAIActivityState(targetID: UUID) {
        revokeAuthorizedOperations(targetID: targetID)
        clearAIViewingState(targetID: targetID)
    }

    func currentAIAuthorityGeneration(targetID: UUID) -> UInt64 {
        authorityGenerationByTargetID[targetID] ?? 0
    }

    func clearConnectionBoundAIActivityState(targetID: UUID) {
        revokeConnectionBoundAuthorizedOperations(targetID: targetID)
        clearAIViewingState(targetID: targetID)
    }

    private func clearAIViewingState(targetID: UUID) {
        aiViewingExpiryTasksByTargetID.removeValue(forKey: targetID)?.cancel()
        aiViewingExpiryGenerationByTargetID.removeValue(forKey: targetID)
        aiViewingActivityByTargetID.removeValue(forKey: targetID)
    }

    private func clearAllAIActivityState() {
        for targetID in authorizedOperationsByTargetID.keys {
            revokeAuthorizedOperations(targetID: targetID)
        }
        for task in aiViewingExpiryTasksByTargetID.values {
            task.cancel()
        }
        aiViewingExpiryTasksByTargetID.removeAll()
        aiViewingExpiryGenerationByTargetID.removeAll()
        aiViewingActivityByTargetID.removeAll()
        authorizedOperationsByTargetID.removeAll()
        authorityGenerationByTargetID.removeAll()
        connectionAuthorityGenerationByTargetID.removeAll()
    }

    private func copyPixels(from surface: IOSurface, metadata: [String: Any]) throws -> Data {
        guard let metadataWidth = (metadata["width"] as? NSNumber)?.intValue,
              let metadataHeight = (metadata["height"] as? NSNumber)?.intValue,
              let metadataBytesPerRow = (metadata["bytesPerRow"] as? NSNumber)?.intValue,
              let layout = RDPFrameSurfaceLayout.validated(
                metadataWidth: metadataWidth,
                metadataHeight: metadataHeight,
                metadataBytesPerRow: metadataBytesPerRow,
                surfaceWidth: IOSurfaceGetWidth(surface),
                surfaceHeight: IOSurfaceGetHeight(surface),
                surfaceBytesPerRow: IOSurfaceGetBytesPerRow(surface),
                surfaceAllocationBytes: IOSurfaceGetAllocSize(surface)
              ) else {
            throw FreeRDPXPCFailure(code: "FRAME_METADATA_INVALID", message: "The RDP framebuffer metadata is invalid.")
        }
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else {
            throw FreeRDPXPCFailure(code: "FRAME_SURFACE_INVALID", message: "The RDP IOSurface could not be locked for reading.")
        }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        guard let expectedSeed = FreeRDPXPCInboundValidation.surfaceSeed(in: metadata),
              IOSurfaceGetSeed(surface) == expectedSeed else {
            throw AttemptScopedFrameError.stale
        }
        let address = IOSurfaceGetBaseAddress(surface)
        guard Int(bitPattern: address) != 0 else {
            throw FreeRDPXPCFailure(code: "FRAME_SURFACE_INVALID", message: "The RDP IOSurface has no readable memory.")
        }
        let pixels = Data(bytes: address, count: layout.requiredBytes)
        guard IOSurfaceGetSeed(surface) == expectedSeed else {
            throw AttemptScopedFrameError.stale
        }
        return pixels
    }

    private func makeAttemptScopedFrame(
        pixels: Data,
        metadata: [String: Any],
        active: ActiveDesktop,
        connectionAttemptID: UUID
    ) throws -> DesktopFrame {
        try makeAttemptScopedRenderedFrame(
            pixels: pixels,
            metadata: metadata,
            active: active,
            connectionAttemptID: connectionAttemptID,
            encodePNG: true
        ).frame
    }

    private struct RenderedDesktopFrame {
        var frame: DesktopFrame
        let image: NSImage
    }

    private func makeAttemptScopedRenderedFrame(
        pixels: Data,
        metadata: [String: Any],
        active: ActiveDesktop,
        connectionAttemptID: UUID,
        encodePNG: Bool
    ) throws -> RenderedDesktopFrame {
        guard let rawConnectionAttemptID = metadata["connectionAttemptId"] as? String,
              let metadataConnectionAttemptID = UUID(uuidString: rawConnectionAttemptID) else {
            throw FreeRDPXPCFailure(
                code: "FRAME_METADATA_INVALID",
                message: "The RDP framebuffer is missing its connection-attempt binding."
            )
        }
        guard metadataConnectionAttemptID == connectionAttemptID else {
            throw AttemptScopedFrameError.stale
        }
        var renderedFrame = try makeRenderedFrame(
            pixels: pixels,
            metadata: metadata,
            sessionID: active.sessionID,
            encodePNG: encodePNG
        )
        let runtimeRevision = renderedFrame.frame.metadata.stateRevision
        guard active.connectionAttemptID == connectionAttemptID,
              let publishedRevision = active.revisionLedger.publishFrameRevision(
                  runtimeRevision: runtimeRevision,
                  attemptID: connectionAttemptID
              ) else {
            throw AttemptScopedFrameError.stale
        }
        renderedFrame.frame.metadata.stateRevision = publishedRevision
        return renderedFrame
    }

    private func makeRenderedFrame(
        pixels: Data,
        metadata: [String: Any],
        sessionID: UUID,
        encodePNG: Bool
    ) throws -> RenderedDesktopFrame {
        guard let frameIDString = metadata["frameId"] as? String,
              let frameID = UUID(uuidString: frameIDString),
              let width = (metadata["width"] as? NSNumber)?.intValue,
              let height = (metadata["height"] as? NSNumber)?.intValue,
              let bytesPerRow = (metadata["bytesPerRow"] as? NSNumber)?.intValue,
              let stateRevision = uint64(metadata["stateRevision"]),
              (640...7_680).contains(width),
              (480...4_320).contains(height),
              width <= Int.max / 4,
              bytesPerRow >= width * 4,
              bytesPerRow <= RDPFrameSurfaceLayout.maximumFramebufferBytes,
              height <= Int.max / bytesPerRow,
              height * bytesPerRow <= RDPFrameSurfaceLayout.maximumFramebufferBytes,
              pixels.count >= height * bytesPerRow else {
            throw FreeRDPXPCFailure(code: "FRAME_METADATA_INVALID", message: "The RDP framebuffer metadata is invalid.")
        }
        let provider = CGDataProvider(data: pixels as CFData)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let provider,
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw FreeRDPXPCFailure(code: "FRAME_IMAGE_FAILED", message: "The RDP framebuffer could not be converted to an image.")
        }
        let pngData: Data
        if encodePNG {
            let representation = NSBitmapImageRep(cgImage: image)
            guard let encoded = representation.representation(using: .png, properties: [:]) else {
                throw FreeRDPXPCFailure(code: "FRAME_PNG_FAILED", message: "The RDP framebuffer could not be encoded as PNG.")
            }
            pngData = encoded
        } else {
            pngData = Data()
        }
        let capturedAt = (metadata["capturedAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        return RenderedDesktopFrame(
            frame: DesktopFrame(
                metadata: DesktopFrameMetadata(
                    frameID: frameID,
                    sessionID: sessionID,
                    stateRevision: stateRevision,
                    pixelWidth: width,
                    pixelHeight: height,
                    capturedAt: capturedAt
                ),
                pngData: pngData
            ),
            image: NSImage(
                cgImage: image,
                size: NSSize(width: width, height: height)
            )
        )
    }

    private func semanticSelector(_ value: String) -> [String: Any] {
        if let data = value.data(using: .utf8),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dictionary
        }
        return ["automationId": value]
    }

    private func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }

    static func scanCode(for key: String?) throws -> UInt32 {
        let normalized = (key ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let codes: [String: UInt32] = [
            "escape": 0x01, "esc": 0x01,
            "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06,
            "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A, "0": 0x0B,
            "-": 0x0C, "=": 0x0D, "backspace": 0x0E, "tab": 0x0F,
            "q": 0x10, "w": 0x11, "e": 0x12, "r": 0x13, "t": 0x14,
            "y": 0x15, "u": 0x16, "i": 0x17, "o": 0x18, "p": 0x19,
            "[": 0x1A, "]": 0x1B,
            "enter": 0x1C, "return": 0x1C, "control": 0x1D, "ctrl": 0x1D,
            "a": 0x1E, "s": 0x1F, "d": 0x20, "f": 0x21, "g": 0x22,
            "h": 0x23, "j": 0x24, "k": 0x25, "l": 0x26,
            ";": 0x27, "'": 0x28, "`": 0x29,
            "shift": 0x2A, "\\": 0x2B, "z": 0x2C, "x": 0x2D, "c": 0x2E, "v": 0x2F,
            "b": 0x30, "n": 0x31, "m": 0x32, "alt": 0x38, "option": 0x38,
            ",": 0x33, ".": 0x34, "/": 0x35,
            "space": 0x39, "capslock": 0x3A, "f1": 0x3B, "f2": 0x3C, "f3": 0x3D, "f4": 0x3E,
            "f5": 0x3F, "f6": 0x40, "f7": 0x41, "f8": 0x42, "f9": 0x43,
            "f10": 0x44, "f11": 0x57, "f12": 0x58,
            "home": 0x147, "up": 0x148, "pageup": 0x149, "left": 0x14B,
            "right": 0x14D, "end": 0x14F, "down": 0x150, "pagedown": 0x151,
            "insert": 0x152, "delete": 0x153,
            "meta": 0x15B, "command": 0x15B, "windows": 0x15B,
        ]
        guard let code = codes[normalized] else {
            throw WindowsMCPToolError(code: .invalidArgument, message: "Unsupported RDP key identifier: \(key ?? "empty").")
        }
        return code
    }
}

#endif
