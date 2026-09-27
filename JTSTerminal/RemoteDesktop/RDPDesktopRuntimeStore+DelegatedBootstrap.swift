#if ENABLE_RDP_2
import Foundation

@MainActor
extension RDPDesktopRuntimeStore {
    /// A purpose-built pre-pairing operation, never a general raw-input route.
    /// The caller already holds normal AI capability authorization. Direct UI
    /// calls use the same device grant and human-takeover generation checks.
    func runDelegatedPairingBootstrap(
        active: ActiveDesktop,
        exported: CompanionPairingDelegationExport,
        taskID: UUID,
        expectedConnectionAttemptID: UUID,
        expectedAuthorityGeneration: UInt64,
        deadlineMilliseconds: Int
    ) async throws {
        let plan = try RDPCompanionDelegatedBootstrap.makePlan(exported: exported)
        let deadline = try RDPCompanionDelegatedBootstrap.Deadline(
            milliseconds: deadlineMilliseconds, nowUptime: ProcessInfo.processInfo.systemUptime
        )
        guard let companion = active.companion, let peer = companion.peerIdentity else {
            throw WindowsMCPToolError.companionRequired
        }
        let grant = exported.grant
        let store = CompanionPairingDelegationStore.shared

        func requireCurrent(allowCompletedLaunchTransition: Bool = false) throws {
            try Task.checkCancellation()
            _ = try deadline.remainingMilliseconds(nowUptime: ProcessInfo.processInfo.systemUptime)
            try requireCurrentConnectedActionAttempt(active, expectedConnectionAttemptID: expectedConnectionAttemptID)
            let currentGrant = try store.activeGrant(
                targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer
            )
            guard RDPCompanionDelegationPolicy.isEnabled(for: active.target),
                  currentAIAuthorityGeneration(targetID: active.target.targetID) == expectedAuthorityGeneration,
                  !active.elevationPromptInProgress, active.companionInstallationTaskID == nil,
                  grant.matches(targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer),
                  currentGrant?.grantID == grant.grantID,
                  currentGrant?.revocationRevision == grant.revocationRevision else {
                throw CompanionPairingDelegationFailure.grantRevoked
            }
            if allowCompletedLaunchTransition, active.companion !== companion,
               active.companionAuthorizationTaskID == nil {
                // The final Return can cause the installed Setup to replace
                // the old DVC immediately. All persistent/RDP authority above
                // must still be current; no further input follows this point.
                return
            }
            guard active.companion === companion, companion.peerIdentity == peer,
                  active.companionAuthorizationTaskID == taskID else {
                throw CompanionPairingDelegationFailure.identityChanged
            }
        }

        func send(type: String, values: [String: Any], finalLaunch: Bool = false) async throws {
            try requireCurrent()
            guard let frame = active.latestFrame,
                  let revision = active.revisionLedger.runtimeRevision(
                    for: frame.metadata.stateRevision, attemptID: expectedConnectionAttemptID
                  ) else { throw RDPCompanionDelegatedBootstrap.Failure.desktopNotReady }
            var input = values
            input["type"] = type
            input["expectedStateRevision"] = revision
            // Absence of localManual keeps the helper's strict AI revision
            // check. The fixed operation does not relax generic AI input guards.
            try await sendDesktopInput(active: active, input, deadlineMilliseconds: min(
                5_000, try deadline.remainingMilliseconds(nowUptime: ProcessInfo.processInfo.systemUptime)
            ))
            try requireCurrent(allowCompletedLaunchTransition: finalLaunch)
        }

        func chord(_ keys: [String], finalLaunch: Bool = false) async throws {
            try await send(type: "keyChord", values: ["scancodes": try keys.map(Self.scanCode(for:))], finalLaunch: finalLaunch)
        }

        try requireCurrent()
        try await chord(["meta", "r"])
        try await Task.sleep(for: .milliseconds(350))
        try requireCurrent()
        try await chord(["control", "a"])
        try await send(type: "text", values: ["text": plan.powerShellLaunchCommand])
        guard let launchFrame = active.latestFrame?.metadata.frameID else {
            throw RDPCompanionDelegatedBootstrap.Failure.desktopNotReady
        }
        try await chord(["enter"])
        let launchedAt = ProcessInfo.processInfo.systemUptime
        var observedTransition = false
        while true {
            try requireCurrent()
            let elapsed = ProcessInfo.processInfo.systemUptime - launchedAt
            if let current = active.latestFrame?.metadata.frameID, current != launchFrame { observedTransition = true }
            if observedTransition, elapsed >= RDPCompanionDelegatedBootstrap.minimumReadinessSeconds { break }
            guard elapsed < RDPCompanionDelegatedBootstrap.transitionTimeoutSeconds else {
                throw RDPCompanionDelegatedBootstrap.Failure.desktopNotReady
            }
            try await Task.sleep(for: .milliseconds(50))
            try requireCurrent()
        }
        try await send(type: "text", values: ["text": plan.powerShellScript])
        try await chord(["enter"], finalLaunch: true)
    }
}
#endif
