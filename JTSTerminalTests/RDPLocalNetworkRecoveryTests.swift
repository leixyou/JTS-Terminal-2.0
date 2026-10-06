#if ENABLE_RDP_2
import Foundation
@preconcurrency import Network
import Testing
@testable import JTSTerminal

@Suite(.serialized)
@MainActor
struct RDPLocalNetworkRecoveryTests {
    @Test func freeRDPTransportFailuresRequestTargetedPathDiagnosis() {
        let transportFailures = [
            "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
            "ERRCONNECT_CONNECT_FAILED",
            "ERRCONNECT_DNS_ERROR",
            "ERRCONNECT_DNS_NAME_NOT_FOUND",
            "RDP_CONNECTION_LOST",
        ]

        for code in transportFailures {
            #expect(RDPLocalNetworkRecovery.needsPathDiagnosis(
                RDPReconnectFailure(
                    phase: .failed,
                    code: code,
                    message: "FreeRDP could not connect."
                )
            ))
        }

        #expect(RDPLocalNetworkRecovery.needsPathDiagnosis(
            RDPReconnectFailure(
                phase: .reconnecting,
                code: nil,
                message: "No route to host"
            )
        ))
    }

    @Test func authenticationCertificateAndClosedFailuresNeverTriggerPermissionProbe() {
        let failures = [
            RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_LOGON_FAILURE",
                message: "Authentication failed."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_LOGON_FAILURE",
                message: "Authentication policy denied the operation."
            ),
            RDPReconnectFailure(
                phase: .awaitingCertificateTrust,
                code: "RDP_CERTIFICATE_UNTRUSTED",
                message: "Certificate approval required."
            ),
            RDPReconnectFailure(
                phase: .closed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "User closed the session."
            ),
        ]

        for failure in failures {
            #expect(!RDPLocalNetworkRecovery.needsPathDiagnosis(failure))
        }
    }

    @Test func explicitPathBlockUsesAccurateMachineCodeAndRecoveryCopy() {
        let failure = RDPLocalNetworkRecovery.pathBlockedFailure(phase: .failed)

        #expect(failure.code == "RDP_LOCAL_NETWORK_PATH_BLOCKED")
        #expect(failure.message.contains("does not prove the Local Network switch is off"))
        #expect(RDPLocalNetworkRecovery.isPathBlocked(code: failure.code))
        #expect(RDPLocalNetworkRecovery.isPathBlocked(
            code: "RDP_LOCAL_NETWORK_PERMISSION_DENIED"
        ))
        #expect(!RDPLocalNetworkRecovery.isPathBlocked(code: "NETWORK_POLICY_DENIED"))
        #expect(!RDPLocalNetworkRecovery.isPathBlocked(code: "ERRCONNECT_LOGON_FAILURE"))
    }

    @Test func pendingDecisionUsesASeparateMachineCodeAndDoesNotClaimDenial() {
        let failure = RDPLocalNetworkRecovery.decisionPendingFailure(phase: .failed)

        #expect(failure.code == "RDP_LOCAL_NETWORK_DECISION_PENDING")
        #expect(failure.message.contains("not produced a stable permission decision"))
        #expect(RDPLocalNetworkRecovery.isDecisionPending(code: failure.code))
        #expect(!RDPLocalNetworkRecovery.isPathBlocked(code: failure.code))
        #expect(!RDPReconnectPolicy.standard.permitsReconnect(
            phase: failure.phase,
            failureCode: failure.code
        ))

        let state = RDPDesktopSessionState(
            sessionID: UUID(),
            targetID: UUID(),
            phase: .failed,
            runtimeAvailability: .available,
            companion: .unknown,
            stateRevision: 1,
            latestFrameID: nil,
            remotePixelWidth: nil,
            remotePixelHeight: nil,
            connectedAt: nil,
            reconnectAttempt: nil,
            reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil,
            lastErrorCode: failure.code,
            lastErrorMessage: failure.message
        )
        #expect(state.isLocalNetworkDecisionPending)
        #expect(!state.isLocalNetworkPathBlocked)
    }

    @Test func onlyExplicitNetworkFrameworkReasonClassifiesPathAsBlocked() {
        #expect(
            RDPLocalNetworkPathDiagnostic.result(
                for: .unsatisfied,
                unsatisfiedReason: .localNetworkDenied
            )
                == .pathBlocked
        )
        #expect(RDPLocalNetworkPathDiagnostic.result(
            for: .unsatisfied,
            unsatisfiedReason: .wifiDenied
        ) == nil)
        #expect(RDPLocalNetworkPathDiagnostic.result(
            for: .satisfied,
            unsatisfiedReason: .localNetworkDenied
        ) == nil)
        #expect(RDPLocalNetworkPathDiagnostic.result(
            for: .requiresConnection,
            unsatisfiedReason: .localNetworkDenied
        ) == nil)
        #expect(RDPLocalNetworkPathDiagnostic.result(
            for: .unsatisfied,
            unsatisfiedReason: nil
        ) == nil)
    }

    @Test func initialDenialRemainsPendingForTheFullObservationWindow() {
        #expect(RDPLocalNetworkDiagnosticMode.initial.defaultTimeoutMilliseconds == 8_000)
        var policy = RDPLocalNetworkDiagnosticPolicy(mode: .initial)

        policy.observePath(
            status: .unsatisfied,
            unsatisfiedReason: .localNetworkDenied
        )

        #expect(policy.observedLocalNetworkDenial)
        #expect(policy.isCurrentlyLocalNetworkDenied)
        #expect(policy.timeoutResult() == .decisionPending)
    }

    @Test func confirmedRecheckRequiresDenialToRemainCurrentAtTimeout() {
        #expect(
            RDPLocalNetworkDiagnosticMode.confirmedRecheck.defaultTimeoutMilliseconds == 2_000
        )
        var policy = RDPLocalNetworkDiagnosticPolicy(mode: .confirmedRecheck)
        policy.observePath(
            status: .unsatisfied,
            unsatisfiedReason: .localNetworkDenied
        )
        #expect(policy.timeoutResult() == .pathBlocked)

        policy.observePath(
            status: .requiresConnection,
            unsatisfiedReason: nil
        )
        #expect(policy.observedLocalNetworkDenial)
        #expect(!policy.isCurrentlyLocalNetworkDenied)
        #expect(policy.timeoutResult() == .inconclusive)
    }

    @Test func readyDistinguishesResolvedPermissionFromANeverDeniedPath() {
        var resolvedPolicy = RDPLocalNetworkDiagnosticPolicy(mode: .initial)
        resolvedPolicy.observePath(
            status: .unsatisfied,
            unsatisfiedReason: .localNetworkDenied
        )
        resolvedPolicy.observePath(
            status: .satisfied,
            unsatisfiedReason: nil
        )
        #expect(resolvedPolicy.readyResult() == .permissionResolved)

        let readyPolicy = RDPLocalNetworkDiagnosticPolicy(mode: .initial)
        #expect(readyPolicy.readyResult() == .notDenied)
        #expect(readyPolicy.timeoutResult() == .inconclusive)
    }

    @Test func terminalFailureDoesNotCancelAnObservedDenialWindow() {
        var deniedPolicy = RDPLocalNetworkDiagnosticPolicy(mode: .initial)
        deniedPolicy.observePath(
            status: .unsatisfied,
            unsatisfiedReason: .localNetworkDenied
        )
        #expect(deniedPolicy.failureResult() == nil)
        #expect(deniedPolicy.timeoutResult() == .decisionPending)

        let neverDeniedPolicy = RDPLocalNetworkDiagnosticPolicy(mode: .initial)
        #expect(neverDeniedPolicy.failureResult() == .inconclusive)
    }

    @Test func diagnosticOperationCompletesExactlyOnceWhenReadyAndTimeoutRace() {
        for _ in 0..<100 {
            let completions = DiagnosticCompletionRecorder()
            let operation = RDPLocalNetworkDiagnosticOperation(
                policy: RDPLocalNetworkDiagnosticPolicy(mode: .initial)
            ) { result in
                completions.record(result)
            }

            DispatchQueue.concurrentPerform(iterations: 2) { iteration in
                if iteration == 0 {
                    operation.resolveReady()
                } else {
                    operation.resolveTimeout()
                }
            }

            #expect(completions.results.count == 1)
            #expect(
                completions.results.first == .notDenied
                    || completions.results.first == .inconclusive
            )
        }
    }

    @Test func diagnosticFailureKeepsAnObservedDenialAliveUntilTimeout() {
        let completions = DiagnosticCompletionRecorder()
        let operation = RDPLocalNetworkDiagnosticOperation(
            policy: RDPLocalNetworkDiagnosticPolicy(mode: .initial)
        ) { result in
            completions.record(result)
        }

        operation.observePath(
            status: .unsatisfied,
            unsatisfiedReason: .localNetworkDenied
        )
        operation.resolveFailure()
        #expect(completions.results.isEmpty)

        operation.resolveTimeout()
        #expect(completions.results == [.decisionPending])
    }

    @Test func recoveryCopyDoesNotClaimTheSettingsSwitchIsOff() {
        let englishTitle = RDPDesktopLocalNetworkBlockedContent.title(language: .english)
        let englishDetail = RDPDesktopLocalNetworkBlockedContent.detail(
            host: "192.168.10.20",
            language: .english
        )
        let chineseTitle = RDPDesktopLocalNetworkBlockedContent.title(
            language: .simplifiedChinese
        )
        let chineseDetail = RDPDesktopLocalNetworkBlockedContent.detail(
            host: "192.168.10.20",
            language: .simplifiedChinese
        )

        #expect(!englishTitle.contains("Access Is Off"))
        #expect(englishDetail.contains("does not mean"))
        #expect(englishDetail.contains("stable location"))
        #expect(!chineseTitle.contains("访问已关闭"))
        #expect(chineseDetail.contains("不表示"))
        #expect(chineseDetail.contains("固定位置"))
    }

    @Test func pendingDecisionCopyNamesTheExactAppCopyAndSavedHost() {
        let englishTitle = RDPDesktopLocalNetworkDecisionPendingContent.title(
            language: .english
        )
        let englishDetail = RDPDesktopLocalNetworkDecisionPendingContent.detail(
            host: "192.168.10.20",
            language: .english
        )
        let chineseTitle = RDPDesktopLocalNetworkDecisionPendingContent.title(
            language: .simplifiedChinese
        )
        let chineseDetail = RDPDesktopLocalNetworkDecisionPendingContent.detail(
            host: "192.168.10.20",
            language: .simplifiedChinese
        )

        #expect(englishTitle.contains("This App Copy"))
        #expect(englishDetail.contains("192.168.10.20"))
        #expect(englishDetail.contains("another JTS Terminal copy"))
        #expect(!englishDetail.contains("switch is off"))
        #expect(chineseTitle.contains("当前副本"))
        #expect(chineseDetail.contains("192.168.10.20"))
        #expect(chineseDetail.contains("其他 JTS Terminal 副本"))
        #expect(!chineseDetail.contains("开关已关闭"))
    }

    @Test func diagnosticEndpointIsExactlyOneValidatedSavedHostAndPort() throws {
        let endpoint = try #require(RDPLocalNetworkDiagnosticEndpoint(
            host: "  windows-studio.local  ",
            port: 3_389
        ))

        #expect(endpoint.host == "windows-studio.local")
        #expect(endpoint.port == 3_389)
        #expect(RDPLocalNetworkDiagnosticEndpoint(host: "", port: 3_389) == nil)
        #expect(RDPLocalNetworkDiagnosticEndpoint(host: "192.168.1.20", port: 0) == nil)
        #expect(RDPLocalNetworkDiagnosticEndpoint(host: "192.168.1.20", port: 70_000) == nil)
    }

    @Test(arguments: [RDPDesktopTransportRoute.relay, .unknown])
    func relayAndUnresolvedRoutesNeverProbeTheSavedDirectEndpoint(route: RDPDesktopTransportRoute) async {
        let target = RemoteSession(name: "Relay Windows", host: "192.168.10.20",
                                   username: "operator", connectionType: .rdp)
        let store = makeRuntimeStore { _, _ in
            Issue.record("A relay or unresolved route must not probe the saved direct endpoint.")
            return .pathBlocked
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target, phase: .connecting, hasConnectedOnce: false,
            transportRouteForTesting: route)
        store.processConnectionFailureForTesting(sessionID: sessionID,
            failure: RDPReconnectFailure(phase: .failed, code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                                         message: "The authenticated transport failed."))
        #expect(!store.hasLocalNetworkDiagnosticForTesting(sessionID: sessionID))
        #expect(store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID) == nil)
        await Task.yield()
        #expect(store.state(for: target.targetID)?.lastErrorCode == "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
    }

    @Test func reconnectClearsThePreviousDirectRouteBeforeAnyNewLookup() {
        let target = RemoteSession(name: "Windows", host: "192.168.10.20",
                                   username: "operator", connectionType: .rdp)
        let store = makeRuntimeStore { _, _ in .inconclusive }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target, transportRouteForTesting: .direct)
        #expect(store.transportRouteForTesting(sessionID: sessionID) == .direct)
        store.receiveDesktopInvalidationForTesting(sessionID: sessionID, message: "The helper was interrupted.")
        #expect(store.state(for: target.targetID)?.phase == .reconnecting)
        #expect(store.transportRouteForTesting(sessionID: sessionID) == .unknown)
    }

    @Test func explicitPathDiagnosticRewritesOnlyTheCurrentTransportFailure() async throws {
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, _ in .pathBlocked }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "FreeRDP could not connect."
            )
        )
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )
        await diagnostic.value

        let state = store.state(for: target.targetID)
        #expect(state?.lastErrorCode == "RDP_LOCAL_NETWORK_PATH_BLOCKED")
        #expect(state?.isLocalNetworkPathBlocked == true)
        #expect(!store.hasLocalNetworkDiagnosticForTesting(sessionID: sessionID))
    }

    @Test func inconclusiveDiagnosticPreservesTheOriginalFreeRDPFailure() async throws {
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, _ in .inconclusive }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "Original transport failure."
            )
        )
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )
        await diagnostic.value

        let state = store.state(for: target.targetID)
        #expect(state?.lastErrorCode == "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
        #expect(state?.lastErrorMessage == "Original transport failure.")
        #expect(state?.isLocalNetworkPathBlocked == false)
    }

    @Test func pendingDecisionStopsAutomaticReconnectUntilExplicitRecheck() async throws {
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, mode in
            #expect(mode == .initial)
            return .decisionPending
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .reconnecting,
            hasConnectedOnce: true
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "Transport failed while macOS was deciding."
            )
        )
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )
        await diagnostic.value

        let state = try #require(store.state(for: target.targetID))
        #expect(state.phase == .failed)
        #expect(state.lastErrorCode == "RDP_LOCAL_NETWORK_DECISION_PENDING")
        #expect(state.reconnectAttempt == nil)
        #expect(state.reconnectScheduledAt == nil)
    }

    @Test func resolvedPermissionSchedulesOneBoundedReconnect() async throws {
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, mode in
            #expect(mode == .initial)
            return .permissionResolved
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false,
            reconnectPolicyForTesting: RDPReconnectPolicy(
                maximumAttempts: 1,
                initialDelaySeconds: 60,
                maximumDelaySeconds: 60
            )
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "Transport failed before permission settled."
            )
        )
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )
        await diagnostic.value

        let state = try #require(store.state(for: target.targetID))
        #expect(state.phase == .reconnecting)
        #expect(state.reconnectAttempt == 1)
        #expect(state.reconnectMaximumAttempts == 1)
        #expect(state.reconnectScheduledAt != nil)
        #expect(!store.hasLocalNetworkDiagnosticForTesting(sessionID: sessionID))
    }

    @Test func explicitRecheckModeCannotLeakPastAJoinedOpen() async throws {
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let gate = LocalNetworkOpenGate()
        defer { gate.release() }
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                try await gate.execute(target: target)
            },
            localNetworkDiagnoserForTesting: { _, _ in .inconclusive }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .failed,
            hasConnectedOnce: false
        )
        store.setPublishedDesktopErrorForTesting(
            sessionID: sessionID,
            code: RDPLocalNetworkRecovery.decisionPendingCode,
            message: RDPLocalNetworkRecovery.decisionPendingMessage
        )

        let connect = try #require(store.presentation(for: target).connect)
        connect()
        try await gate.waitUntilStarted()
        #expect(
            store.pendingLocalNetworkDiagnosticModeForTesting(
                targetID: target.targetID
            ) == .confirmedRecheck
        )

        connect()
        for _ in 0..<100 {
            if store.activeOpenWaiterCountForTesting == 2 {
                break
            }
            await Task.yield()
        }
        #expect(store.activeOpenOperationCountForTesting == 1)
        #expect(store.activeOpenWaiterCountForTesting == 2)
        #expect(
            store.pendingLocalNetworkDiagnosticModeForTesting(
                targetID: target.targetID
            ) == .confirmedRecheck
        )

        gate.release()
        for _ in 0..<100 {
            if store.pendingLocalNetworkDiagnosticModeForTesting(
                targetID: target.targetID
            ) == nil {
                break
            }
            await Task.yield()
        }
        #expect(
            store.pendingLocalNetworkDiagnosticModeForTesting(
                targetID: target.targetID
            ) == nil
        )
    }

    @Test func cancelledOldDiagnosticCannotOverwriteANewerConnectedAttempt() async throws {
        let gate = LocalNetworkDiagnosticGate()
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, _ in
            await gate.diagnose()
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "Attempt A failed."
            )
        )
        await gate.waitUntilStarted()
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected
        )
        gate.resolve(.pathBlocked)
        await diagnostic.value

        let state = try #require(store.state(for: target.targetID))
        #expect(state.phase == .connected)
        #expect(state.lastErrorCode == nil)
        #expect(!store.hasLocalNetworkDiagnosticForTesting(sessionID: sessionID))
    }

    @Test func oldSameAttemptDiagnosticCannotOverwriteANewerAuthenticationFailure() async throws {
        let gate = LocalNetworkDiagnosticGate()
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, _ in await gate.diagnose() }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "Transport failure A."
            )
        )
        await gate.waitUntilStarted()
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_LOGON_FAILURE",
                message: "Authentication policy denied the operation."
            )
        )
        gate.resolve(.pathBlocked)
        await diagnostic.value

        let state = try #require(store.state(for: target.targetID))
        #expect(state.phase == .failed)
        #expect(state.lastErrorCode == "ERRCONNECT_LOGON_FAILURE")
        #expect(state.lastErrorMessage == "Authentication policy denied the operation.")
        #expect(!store.hasLocalNetworkDiagnosticForTesting(sessionID: sessionID))
    }

    @Test func closedStateCancelsAndRetiresTheCurrentDiagnostic() async throws {
        let gate = LocalNetworkDiagnosticGate()
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, _ in await gate.diagnose() }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "Transport failure."
            )
        )
        await gate.waitUntilStarted()
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .closed,
            code: "RDP_LOGOFF_BY_USER",
            message: "The user logged off."
        )
        gate.resolve(.pathBlocked)
        await diagnostic.value

        let state = try #require(store.state(for: target.targetID))
        #expect(state.phase == .closed)
        #expect(state.lastErrorCode == "RDP_LOGOFF_BY_USER")
        #expect(!store.hasLocalNetworkDiagnosticForTesting(sessionID: sessionID))
    }

    @Test func certificateChallengeCancelsAndRetiresTheCurrentDiagnostic() async throws {
        let gate = LocalNetworkDiagnosticGate()
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, _ in await gate.diagnose() }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "Transport failure."
            )
        )
        await gate.waitUntilStarted()
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )

        store.receiveDesktopCertificateForTesting(
            sessionID: sessionID,
            certificate: [
                "host": target.host,
                "port": target.port,
                "sha256": String(repeating: "A", count: 64),
            ]
        )
        gate.resolve(.pathBlocked)
        await diagnostic.value

        let state = try #require(store.state(for: target.targetID))
        #expect(state.phase == .awaitingCertificateTrust)
        #expect(state.lastErrorCode == "RDP_CERTIFICATE_UNTRUSTED")
        #expect(!store.hasLocalNetworkDiagnosticForTesting(sessionID: sessionID))
    }

    @Test func exhaustedXPCInvalidationCancelsAndRetiresTheCurrentDiagnostic() async throws {
        let gate = LocalNetworkDiagnosticGate()
        let target = RemoteSession(
            name: "LAN Windows",
            host: "192.168.10.20",
            username: "operator",
            connectionType: .rdp
        )
        let store = makeRuntimeStore { _, _ in await gate.diagnose() }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .reconnecting,
            hasConnectedOnce: true,
            reconnectPolicyForTesting: RDPReconnectPolicy(
                maximumAttempts: 0,
                initialDelaySeconds: 0,
                maximumDelaySeconds: 0
            )
        )

        store.processConnectionFailureForTesting(
            sessionID: sessionID,
            failure: RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                message: "Transport failure from the exhausted attempt."
            )
        )
        await gate.waitUntilStarted()
        let diagnostic = try #require(
            store.localNetworkDiagnosticTaskForTesting(sessionID: sessionID)
        )

        store.receiveDesktopInvalidationForTesting(
            sessionID: sessionID,
            message: "The XPC connection was invalidated."
        )
        gate.resolve(.pathBlocked)
        await diagnostic.value

        let state = try #require(store.state(for: target.targetID))
        #expect(state.phase == .failed)
        #expect(state.runtimeAvailability == .unavailable)
        #expect(state.lastErrorCode == "RDP_XPC_INVALIDATED")
        #expect(state.lastErrorMessage?.contains("Automatic reconnect stopped") == true)
        #expect(!store.hasLocalNetworkDiagnosticForTesting(sessionID: sessionID))
    }

    @Test func cancelledNetworkFrameworkDiagnosticCompletesInconclusively() async throws {
        let endpoint = try #require(RDPLocalNetworkDiagnosticEndpoint(
            host: "203.0.113.1",
            port: 65_535
        ))
        let diagnostic = Task {
            await RDPLocalNetworkPathDiagnostic.diagnose(
                endpoint: endpoint,
                timeoutMilliseconds: 30_000
            )
        }

        diagnostic.cancel()

        #expect(await diagnostic.value == .inconclusive)
    }

    @Test func localNetworkSettingsUsesCurrentDeepLinkBeforeLegacyAndRootFallbacks() throws {
        let destinations = RDPLocalNetworkSystemSettings.destinationURLs
        #expect(destinations.count == 3)
        #expect(destinations[0].absoluteString ==
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
        #expect(destinations[1].absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")

        var opened: [URL] = []
        let didOpen = RDPLocalNetworkSystemSettings.open(
            openURL: { url in
                opened.append(url)
                return url == destinations[2]
            },
            settingsApplicationURL: URL(fileURLWithPath: "/System/Applications/System Settings.app")
        )

        #expect(didOpen)
        #expect(opened == destinations)
    }

    @Test func localNetworkSettingsFallsBackToSystemSettingsApplicationAndFailsSafely() {
        let settingsApplicationURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        var opened: [URL] = []
        let didOpenApplication = RDPLocalNetworkSystemSettings.open(
            openURL: { url in
                opened.append(url)
                return url == settingsApplicationURL
            },
            settingsApplicationURL: settingsApplicationURL
        )

        #expect(didOpenApplication)
        #expect(opened.last == settingsApplicationURL)

        let didOpenWithoutApplication = RDPLocalNetworkSystemSettings.open(
            openURL: { _ in false },
            settingsApplicationURL: nil
        )
        #expect(!didOpenWithoutApplication)
    }

    private func makeRuntimeStore(
        diagnoser: @escaping RDPDesktopRuntimeStore.LocalNetworkDiagnoser
    ) -> RDPDesktopRuntimeStore {
        RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { _, _, _ in
                throw CancellationError()
            },
            localNetworkDiagnoserForTesting: diagnoser
        )
    }

}

@MainActor
private final class LocalNetworkDiagnosticGate {
    private var resultContinuation:
        CheckedContinuation<RDPLocalNetworkDiagnosticResult, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func diagnose() async -> RDPLocalNetworkDiagnosticResult {
        await withCheckedContinuation { continuation in
            resultContinuation = continuation
            started = true
            let waiters = startWaiters
            startWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resolve(_ result: RDPLocalNetworkDiagnosticResult) {
        let continuation = resultContinuation
        resultContinuation = nil
        continuation?.resume(returning: result)
    }
}

private final class DiagnosticCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedResults: [RDPLocalNetworkDiagnosticResult] = []

    var results: [RDPLocalNetworkDiagnosticResult] {
        lock.withLock { recordedResults }
    }

    func record(_ result: RDPLocalNetworkDiagnosticResult) {
        lock.withLock {
            recordedResults.append(result)
        }
    }
}

@MainActor
private final class LocalNetworkOpenGate {
    private var releaseContinuation: CheckedContinuation<Void, Error>?
    private var started = false
    private var released = false

    func execute(target: RemoteSession) async throws -> RDPDesktopSessionState {
        try Task.checkCancellation()
        try #require(!started, "Joined opens must not start the injected executor twice")
        started = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if released {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        try Task.checkCancellation()
        return RDPDesktopSessionState(
            sessionID: UUID(),
            targetID: target.targetID,
            phase: .connected,
            runtimeAvailability: .available,
            companion: .unknown,
            stateRevision: 1,
            latestFrameID: nil,
            remotePixelWidth: nil,
            remotePixelHeight: nil,
            connectedAt: Date(),
            reconnectAttempt: nil,
            reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil,
            lastErrorCode: nil,
            lastErrorMessage: nil
        )
    }

    func waitUntilStarted(timeout: Duration = .seconds(30)) async throws {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        // The real open may expire before the injected executor ever runs.
        // Bound fixture readiness independently instead of stranding XCTest.
        while !started, clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        try #require(started, "The injected desktop open executor did not start before the fixture deadline")
    }

    func release() {
        released = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }

    private func cancel() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}
#endif
