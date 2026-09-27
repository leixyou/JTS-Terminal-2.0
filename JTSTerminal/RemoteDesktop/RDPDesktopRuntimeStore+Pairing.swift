#if ENABLE_RDP_2
import Foundation

@MainActor
extension RDPDesktopRuntimeStore {
    /// Public, non-secret metadata for the existing desktop-status tool. This
    /// read does not mint a delegation or change a device permission.
    func pairingDelegationSnapshot(sessionID: UUID) -> [String: Any]? {
        guard let active = desktopsBySessionID[sessionID], targetBindingIsCurrent(active),
              RDPCompanionDelegationPolicy.isEnabled(for: active.target),
              let grant = CompanionPairingDelegationStore.shared.grants.last(where: {
                  $0.targetID == active.target.targetID && $0.targetBinding == active.targetBinding
              }) else { return nil }
        if let peer = active.companion?.peerIdentity,
           !grant.matches(targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer) { return nil }
        let ready = !grant.isRevoked && active.state.companion.availability == .ready
        var result: [String: Any] = [
            "ready": ready,
            "state": grant.isRevoked ? (grant.pendingRemoteRevocation ? "revokedPendingWindows" : "revoked") : (ready ? "ready" : "enrollmentRequired"),
            "authorizationSource": grant.authorizationSource.rawValue,
            "grantId": grant.grantID.uuidString.lowercased(),
            "delegationIncludedInAIControl": true,
        ]
        if !grant.isRevoked, !ready,
           let exported = companionDelegationExportsByTargetID[active.target.targetID],
           exported.grant.grantID == grant.grantID {
            result.merge(RDPCompanionDelegationPolicy.enrollmentMetadata(exported)) { _, new in new }
        }
        return result
    }

    func companionPairingStatus(sessionID: UUID) async throws -> [String: Any] {
        guard let active = desktopsBySessionID[sessionID], isCurrent(active), targetBindingIsCurrent(active) else {
            throw WindowsMCPToolError.desktopNotOpen
        }
        let store = CompanionPairingDelegationStore.shared
        try store.refresh()
        var grant = store.grants.last { $0.targetID == active.target.targetID && $0.targetBinding == active.targetBinding }
        if let peer = active.companion?.peerIdentity,
           active.state.companion.availability != .ready,
           grant?.isRevoked != true,
           RDPCompanionDelegationPolicy.isEnabled(for: active.target) {
            let attempt = active.connectionAttemptID
            let exported = try await RDPCompanionDelegationPolicy.prepare(target: active.target, peer: peer)
            try requireCurrentConnectedActionAttempt(active, expectedConnectionAttemptID: attempt)
            companionDelegationExportsByTargetID[active.target.targetID] = exported
            grant = exported.grant
        }
        var result: [String: Any] = [
            "ready": active.state.companion.availability == .ready,
            "state": active.state.companion.availability == .ready ? "ready" : "enrollmentRequired",
            "delegationIncludedInAIControl": true,
        ]
        if let grant {
            result["authorizationSource"] = grant.authorizationSource.rawValue
            result["grantId"] = grant.grantID.uuidString.lowercased()
            result["windowsDeviceId"] = grant.windowsDeviceID.uuidString.lowercased()
            result["windowsFingerprintSHA256"] = grant.windowsFingerprintSHA256
            result["macDeviceId"] = grant.macDeviceID.uuidString.lowercased()
            result["macFingerprintSHA256"] = grant.macFingerprintSHA256
            if grant.isRevoked {
                result["ready"] = false
                result["state"] = grant.pendingRemoteRevocation ? "revokedPendingWindows" : "revoked"
            } else if active.state.companion.availability != .ready,
                      let exported = companionDelegationExportsByTargetID[active.target.targetID] {
                result.merge(RDPCompanionDelegationPolicy.enrollmentMetadata(exported)) { _, new in new }
            }
        } else {
            result["authorizationSource"] = "interactive"
        }
        publish(active)
        return result
    }

    /// Consumes a Windows grant enrolled by the authorized current-user Setup.
    /// It never sends an authorize request that could open a human consent prompt.
    func confirmDelegatedCompanionPairing(
        sessionID: UUID, deadlineMilliseconds: Int? = nil
    ) async throws -> [String: Any] {
        guard let initialActive = desktopsBySessionID[sessionID] else { throw WindowsMCPToolError.desktopNotOpen }
        let initialAttempt = initialActive.connectionAttemptID
        let initialAuthority = currentAIAuthorityGeneration(targetID: initialActive.target.targetID)
        let status = try await companionPairingStatus(sessionID: sessionID)
        guard let active = desktopsBySessionID[sessionID], let companion = active.companion else {
            throw WindowsMCPToolError.companionRequired
        }
        try requireCurrentConnectedActionAttempt(active, expectedConnectionAttemptID: initialAttempt)
        guard active === initialActive,
              currentAIAuthorityGeneration(targetID: active.target.targetID) == initialAuthority else {
            throw CompanionPairingDelegationFailure.grantRevoked
        }
        guard RDPCompanionDelegationPolicy.isEnabled(for: active.target) else {
            throw WindowsMCPToolError(code: .permissionDenied, message: "Device AI control is disabled.")
        }
        if status["ready"] as? Bool == true { return status }
        let store = CompanionPairingDelegationStore.shared
        guard let expected = companionPairingByTargetID[active.target.targetID] ?? companion.peerIdentity,
              let grant = try store.activeGrant(targetID: active.target.targetID, targetBinding: active.targetBinding, peer: expected) else {
            throw CompanionPairingDelegationFailure.grantMissing
        }
        guard active.companionAuthorizationTaskID == nil else {
            throw WindowsCompanionRequestFailure(code: "PAIRING_AUTHORIZATION_IN_PROGRESS",
                message: "Companion pairing is already in progress.", retryable: true)
        }
        let attempt = active.connectionAttemptID
        let taskID = UUID()
        let deadline = min(120_000, max(100, deadlineMilliseconds ?? 30_000))
        let expiresAt = ProcessInfo.processInfo.systemUptime + Double(deadline) / 1_000
        func remainingDeadline() throws -> Int {
            let remaining = Int((expiresAt - ProcessInfo.processInfo.systemUptime) * 1_000)
            guard remaining > 0 else {
                throw WindowsCompanionRequestFailure(code: "DEADLINE_EXCEEDED", message: "Delegated pairing timed out.", retryable: true)
            }
            return remaining
        }
        active.companionAuthorizationTaskID = taskID
        defer {
            if active.companionAuthorizationTaskID == taskID { active.companionAuthorizationTaskID = nil }
        }
        func requireCurrent() throws {
            try requireCurrentCompanionAttempt(active, companion: companion, expectedConnectionAttemptID: attempt)
            guard active.companionAuthorizationTaskID == taskID,
                  currentAIAuthorityGeneration(targetID: active.target.targetID) == initialAuthority,
                  RDPCompanionDelegationPolicy.isEnabled(for: active.target) else {
                throw CompanionPairingDelegationFailure.grantRevoked
            }
        }
        do {
            let peer = try await companion.performHello(targetID: active.target.targetID, timeoutMilliseconds: try remainingDeadline())
            try requireCurrent()
            guard grant.matches(targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer),
                  try store.activeGrant(targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer)?.grantID == grant.grantID else {
                throw CompanionPairingDelegationFailure.identityChanged
            }
            companionPairingByTargetID[active.target.targetID] = peer
            if peer.clientAuthorization.pairingRequired {
                let exported = try await RDPCompanionDelegationPolicy.prepare(target: active.target, peer: peer)
                try requireCurrent()
                guard exported.grant.grantID == grant.grantID,
                      exported.grant.revocationRevision == grant.revocationRevision else {
                    throw CompanionPairingDelegationFailure.grantRevoked
                }
                companionDelegationExportsByTargetID[active.target.targetID] = exported
                try await runDelegatedPairingBootstrap(
                    active: active, exported: exported, taskID: taskID,
                    expectedConnectionAttemptID: attempt, expectedAuthorityGeneration: initialAuthority,
                    deadlineMilliseconds: try remainingDeadline()
                )
                // Setup replaces the current Agent/DVC. Its new hello will
                // consume the matching grant; do not await the obsolete peer.
                if active.companionAuthorizationTaskID == taskID {
                    active.state.companion = WindowsCompanionState(
                        availability: .pairingRequired,
                        protocolVersion: WindowsCompanionDVC.protocolVersion,
                        companionVersion: peer.agentVersion,
                        reason: "Device enrollment started. Waiting for the new Companion connection."
                    )
                    publish(active)
                }
                return ["ready": false, "state": "enrollmentStarted",
                        "authorizationSource": "ownerDelegated", "grantId": grant.grantID.uuidString.lowercased(),
                        "delegationIncludedInAIControl": true]
            }
            let authorization = try await companion.authorize(
                targetID: active.target.targetID, targetBinding: active.targetBinding,
                timeoutMilliseconds: try remainingDeadline()
            )
            try requireCurrent()
            try store.validateAuthorization(authorization, targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer)
            try await RDPCompanionKeychainAccess.shared.savePeerFingerprint(peer.fingerprintSHA256, targetID: active.target.targetID)
            try requireCurrent()
            try store.validateAuthorization(authorization, targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer)
            active.state.companion = WindowsCompanionState(availability: .ready,
                protocolVersion: WindowsCompanionDVC.protocolVersion, companionVersion: peer.agentVersion, reason: nil)
            companionPairingByTargetID.removeValue(forKey: active.target.targetID)
            companionDelegationExportsByTargetID.removeValue(forKey: active.target.targetID)
            RDPCompanionDelegationPolicy.audit(target: active.target, action: "pairing.delegate.confirm", result: .approved)
            return try await companionPairingStatus(sessionID: sessionID)
        } catch {
            if active.companionAuthorizationTaskID == taskID {
                companion.cancelAll()
                active.state.companion = WindowsCompanionState(availability: .incompatible, reason: error.localizedDescription)
                publish(active)
            }
            throw error
        }
    }

    func revokeCompanionDelegation(
        sessionID: UUID, deadlineMilliseconds: Int? = nil
    ) async throws -> [String: Any] {
        guard let active = desktopsBySessionID[sessionID], isCurrent(active), targetBindingIsCurrent(active) else {
            throw WindowsMCPToolError.desktopNotOpen
        }
        let store = CompanionPairingDelegationStore.shared
        let grant: CompanionPairingDelegationGrant
        do {
            try store.refresh()
            guard let current = store.grants.last(where: {
                $0.targetID == active.target.targetID && $0.targetBinding == active.targetBinding
            }) else { throw CompanionPairingDelegationFailure.grantMissing }
            grant = current
            if let peer = active.companion?.peerIdentity,
               !grant.matches(targetID: active.target.targetID, targetBinding: active.targetBinding, peer: peer) {
                throw CompanionPairingDelegationFailure.identityChanged
            }
            // Persist before the first network await, including repeated revocations.
            try store.revoke(grantID: grant.grantID)
        } catch {
            blockCompanionAfterDelegationFailure(active, error: error)
            throw error
        }
        clearConnectionBoundAIActivityState(targetID: active.target.targetID)
        companionDelegationExportsByTargetID.removeValue(forKey: active.target.targetID)
        active.companionAuthorizationTaskID = nil
        active.companionAuthorizationTask?.cancel()
        active.companionAuthorizationTask = nil
        active.companionHandshakeTaskID = nil
        active.companionHandshakeTask?.cancel()
        active.companionHandshakeTask = nil
        RDPCompanionDelegationPolicy.audit(target: active.target, action: "pairing.delegate.revoke", result: .revoked)
        if active.state.companion.availability == .ready {
            try await unpairCompanion(targetID: active.target.targetID,
                preservePairingManagement: true, deadlineMilliseconds: deadlineMilliseconds)
            try store.markRemoteRevocationConfirmed(grantID: grant.grantID)
        } else {
            active.companion?.cancelAll()
            active.state.companion = WindowsCompanionPairingLifecycle.blockedPairingState(
                companionVersion: active.state.companion.companionVersion,
                reason: "AI pairing delegation revoked on this Mac. Windows revocation is pending."
            )
        }
        return try await companionPairingStatus(sessionID: sessionID)
    }

    private func blockCompanionAfterDelegationFailure(_ active: ActiveDesktop, error: Error) {
        active.companionAuthorizationTaskID = nil
        active.companionAuthorizationTask?.cancel()
        active.companionAuthorizationTask = nil
        active.companionHandshakeTaskID = nil
        active.companionHandshakeTask?.cancel()
        active.companionHandshakeTask = nil
        active.companion?.cancelAll()
        clearConnectionBoundAIActivityState(targetID: active.target.targetID)
        active.state.companion = WindowsCompanionState(availability: .incompatible, reason: error.localizedDescription)
        publish(active)
    }

    func restoreCompanionDelegation(targetID: UUID) async throws {
        guard let sessionID = sessionIDByTargetID[targetID], let active = desktopsBySessionID[sessionID],
              let peer = companionPairingByTargetID[targetID] ?? active.companion?.peerIdentity else {
            throw WindowsMCPToolError.companionRequired
        }
        let attempt = active.connectionAttemptID
        let exported = try await RDPCompanionDelegationPolicy.prepare(
            target: active.target, peer: peer, allowReplacingRevokedGrant: true
        )
        try requireCurrentConnectedActionAttempt(active, expectedConnectionAttemptID: attempt)
        companionDelegationExportsByTargetID[targetID] = exported
        companionPairingByTargetID[targetID] = peer
        RDPCompanionDelegationPolicy.audit(target: active.target, action: "pairing.delegate.restore", result: .approved)
        publish(active)
    }

    func approveCompanionPairing(targetID: UUID) throws {
        guard let peer = companionPairingByTargetID[targetID],
              let sessionID = sessionIDByTargetID[targetID],
              let active = desktopsBySessionID[sessionID],
              let companion = active.companion else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_NOT_PENDING",
                message: "No verified Windows Companion pairing is pending.",
                retryable: false
            )
        }
        guard active.companionAuthorizationTaskID == nil else { return }
        let connectionAttemptID = active.connectionAttemptID
        try requireCurrentCompanionAttempt(
            active,
            companion: companion,
            expectedConnectionAttemptID: connectionAttemptID
        )
        active.state.companion = WindowsCompanionState(
            availability: .pairingRequired,
            protocolVersion: WindowsCompanionDVC.protocolVersion,
            companionVersion: peer.agentVersion,
            reason: "Waiting for explicit Windows pairing confirmation."
        )
        publish(active)

        let authorizationTaskID = UUID()
        active.companionAuthorizationTaskID = authorizationTaskID
        active.companionAuthorizationTask = Task { @MainActor [weak self, weak active] in
            guard let self, let active else { return }
            defer {
                if active.companionAuthorizationTaskID == authorizationTaskID {
                    active.companionAuthorizationTask = nil
                    active.companionAuthorizationTaskID = nil
                }
            }
            let authorizationAttemptIsCurrent: @MainActor () -> Bool = {
                guard active.companionAuthorizationTaskID == authorizationTaskID else {
                    return false
                }
                return self.isCurrentCompanionAttempt(
                    active,
                    companion: companion,
                    expectedConnectionAttemptID: connectionAttemptID
                )
            }
            do {
                let refreshedPeer = try await companion.performHello(targetID: targetID)
                guard authorizationAttemptIsCurrent() else { return }
                guard refreshedPeer.deviceID == peer.deviceID,
                      refreshedPeer.fingerprintSHA256 == peer.fingerprintSHA256,
                      refreshedPeer.publicKeyDER == peer.publicKeyDER,
                      refreshedPeer.clientDeviceID == peer.clientDeviceID,
                      refreshedPeer.clientFingerprintSHA256 == peer.clientFingerprintSHA256 else {
                    throw WindowsCompanionRequestFailure(
                        code: "PAIRING_IDENTITY_CHANGED",
                        message: "The Windows or Mac pairing identity changed during confirmation.",
                        retryable: false
                    )
                }
                self.companionPairingByTargetID[targetID] = refreshedPeer
                _ = try await companion.authorize(targetID: targetID, targetBinding: active.targetBinding)
                guard authorizationAttemptIsCurrent() else { return }
                try await RDPCompanionKeychainAccess.shared.savePeerFingerprint(
                    refreshedPeer.fingerprintSHA256,
                    targetID: targetID
                )
                guard authorizationAttemptIsCurrent() else { return }
                active.state.companion = WindowsCompanionState(
                    availability: .ready,
                    protocolVersion: WindowsCompanionDVC.protocolVersion,
                    companionVersion: refreshedPeer.agentVersion,
                    reason: nil
                )
                self.companionPairingByTargetID.removeValue(forKey: targetID)
                self.publish(active)
            } catch is CancellationError {
                return
            } catch {
                guard authorizationAttemptIsCurrent() else { return }
                let code = (error as? WindowsCompanionRequestFailure)?.code
                let identityFailure = [
                    "PAIRING_IDENTITY_CHANGED",
                    "PAIRING_IDENTITY_MISMATCH",
                    "PAIRING_LOCAL_IDENTITY_CHANGED",
                    "PAIRING_SIGNATURE_INVALID",
                ].contains(code)
                active.state.companion = WindowsCompanionState(
                    availability: identityFailure ? .incompatible : .pairingRequired,
                    protocolVersion: WindowsCompanionDVC.protocolVersion,
                    companionVersion: peer.agentVersion,
                    reason: error.localizedDescription
                )
                self.publish(active)
            }
        }
    }

    /// Revokes the Windows-side grant while leaving the visible RDP session,
    /// saved profile, Windows identity pin, and this profile's local Mac key in
    /// place. Structured Companion access is blocked before the request starts
    /// and is never restored from an ambiguous response.
    func unpairCompanion(targetID: UUID, preservePairingManagement: Bool = false, deadlineMilliseconds: Int? = nil) async throws {
        guard let sessionID = sessionIDByTargetID[targetID],
              let active = desktopsBySessionID[sessionID],
              let companion = active.companion else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_REQUIRED",
                message: "Only the currently authorized Companion peer can unpair this Windows device.",
                retryable: false
            )
        }
        let connectionAttemptID = active.connectionAttemptID
        try requireCurrentCompanionAttempt(
            active,
            companion: companion,
            expectedConnectionAttemptID: connectionAttemptID
        )
        let unpairAttemptIsCurrent: @MainActor () -> Bool = {
            self.isCurrentCompanionAttempt(
                active,
                companion: companion,
                expectedConnectionAttemptID: connectionAttemptID
            )
        }
        let authorizedPeer = try WindowsCompanionPairingLifecycle.requireAuthorizedPeer(
            availability: active.state.companion.availability,
            peerIdentity: companion.peerIdentity
        )
        guard active.companionAuthorizationTaskID == nil else {
            throw WindowsCompanionRequestFailure(
                code: "PAIRING_AUTHORIZATION_IN_PROGRESS",
                message: "Wait for the current Companion authorization exchange to finish.",
                retryable: true
            )
        }

        let delegationStore = CompanionPairingDelegationStore.shared
        var delegatedGrant: CompanionPairingDelegationGrant?
        do {
            try delegationStore.refresh()
            delegatedGrant = delegationStore.grants.last {
                $0.matches(targetID: targetID, targetBinding: active.targetBinding, peer: authorizedPeer)
            }
            if let delegatedGrant, !delegatedGrant.isRevoked {
                try delegationStore.revoke(grantID: delegatedGrant.grantID)
            }
        } catch {
            blockCompanionAfterDelegationFailure(active, error: error)
            throw error
        }
        if preservePairingManagement {
            clearConnectionBoundAIActivityState(targetID: targetID)
        } else {
            clearAIActivityState(targetID: targetID)
        }
        companionDelegationExportsByTargetID.removeValue(forKey: targetID)
        companionPairingByTargetID.removeValue(forKey: targetID)
        active.state.companion = WindowsCompanionPairingLifecycle.blockedPairingState(
            companionVersion: authorizedPeer.agentVersion,
            reason: "Unpair is in progress. Structured Companion access is blocked."
        )
        publish(active)

        do {
            let result = try await companion.request(
                method: DVCOperation.companionUnpair.rawValue,
                parameters: [:],
                deadlineMilliseconds: min(120_000, max(100, deadlineMilliseconds ?? 10_000)),
                idempotencyKey: nil,
                expectedStateRevision: nil
            )
            try requireCurrentCompanionAttempt(
                active,
                companion: companion,
                expectedConnectionAttemptID: connectionAttemptID
            )
            _ = try WindowsCompanionPairingLifecycle.validateUnpairResponse(result)
            if let delegatedGrant {
                try delegationStore.markRemoteRevocationConfirmed(grantID: delegatedGrant.grantID)
            }
        } catch {
            guard unpairAttemptIsCurrent() else { throw error }
            active.companionChannelID = nil
            companion.cancelAll()
            active.state.companion = WindowsCompanionState(
                availability: .incompatible,
                protocolVersion: WindowsCompanionDVC.protocolVersion,
                companionVersion: authorizedPeer.agentVersion,
                reason: "Unpair could not be confirmed. Companion access remains blocked; disconnect and reconnect before trying again."
            )
            publish(active)
            throw error
        }

        try requireCurrentCompanionAttempt(
            active,
            companion: companion,
            expectedConnectionAttemptID: connectionAttemptID
        )

        do {
            let refreshedPeer = try await companion.performHello(targetID: targetID)
            try requireCurrentCompanionAttempt(
                active,
                companion: companion,
                expectedConnectionAttemptID: connectionAttemptID
            )
            guard refreshedPeer.deviceID == authorizedPeer.deviceID,
                  refreshedPeer.fingerprintSHA256 == authorizedPeer.fingerprintSHA256,
                  refreshedPeer.publicKeyDER == authorizedPeer.publicKeyDER,
                  refreshedPeer.clientDeviceID == authorizedPeer.clientDeviceID,
                      refreshedPeer.clientFingerprintSHA256 == authorizedPeer.clientFingerprintSHA256 else {
                active.companionChannelID = nil
                companion.cancelAll()
                active.state.companion = WindowsCompanionState(
                    availability: .incompatible,
                    protocolVersion: WindowsCompanionDVC.protocolVersion,
                    companionVersion: refreshedPeer.agentVersion,
                    reason: "Unpaired, but the Windows or Mac identity changed before re-pair discovery. Reconnect and verify both fingerprints."
                )
                publish(active)
                return
            }
            guard refreshedPeer.clientAuthorization.pairingRequired else {
                active.companionChannelID = nil
                companion.cancelAll()
                active.state.companion = WindowsCompanionState(
                    availability: .incompatible,
                    protocolVersion: WindowsCompanionDVC.protocolVersion,
                    companionVersion: refreshedPeer.agentVersion,
                    reason: "Windows still reports an approved client after unpair. Companion access remains blocked; reconnect and verify pairing state."
                )
                publish(active)
                return
            }
            companionPairingByTargetID[targetID] = refreshedPeer
            active.state.companion = WindowsCompanionPairingLifecycle.blockedPairingState(
                companionVersion: refreshedPeer.agentVersion
            )
            publish(active)
        } catch {
            guard unpairAttemptIsCurrent() else { throw error }
            active.companionChannelID = nil
            companion.cancelAll()
            active.state.companion = WindowsCompanionPairingLifecycle.blockedPairingState(
                companionVersion: authorizedPeer.agentVersion,
                reason: "Unpaired successfully. Reconnect this RDP profile to begin a new fingerprint confirmation."
            )
            publish(active)
        }
    }

}
#endif
