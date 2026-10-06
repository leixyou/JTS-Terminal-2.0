import Foundation
import Testing
@testable import JTSMacCompanion

struct CompanionAutoSharePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private var enabled: CompanionHostSettings { CompanionHostSettings(host: "10.1.1.2", automaticSharing: true) }

    @Test func startupNeverSharesWithoutOptInPermissionsEnrollmentAndUserSession() {
        let policy = CompanionAutoSharePolicy()
        var settings = enabled
        settings.automaticSharing = false
        #expect(decision(policy, settings: settings) == .disabled)
        #expect(decision(policy, canCapture: false) == .screenPermissionRequired)
        #expect(decision(policy, hasPairedClient: false) == .pairingRequired)
        #expect(decision(policy, hasUserSession: false) == .userSessionRequired)
    }

    @Test func manualPauseSurvivesRelaunchAndPermissionRestoration() {
        var settings = enabled
        settings.sharingPaused = true
        let relaunchedPolicy = CompanionAutoSharePolicy()
        #expect(decision(relaunchedPolicy, settings: settings) == .paused)
        #expect(decision(relaunchedPolicy, settings: settings, canCapture: false) == .paused)
        settings.sharingPaused = false
        #expect(decision(relaunchedPolicy, settings: settings) == .startAuthorizedDevices)
    }

    @Test func automaticStartupHasOnlyAnAuthorizedDeviceStartPath() {
        let policy = CompanionAutoSharePolicy()
        #expect(decision(policy) == .startAuthorizedDevices)
        #expect(decision(policy, isSharing: true) == .alreadySharing)
        #expect(decision(policy, hasPairedClient: false) == .pairingRequired)
    }

    @Test func transientFailuresBackOffAndWakeCanResetTheWait() {
        var policy = CompanionAutoSharePolicy()
        policy.failed(at: now)
        #expect(policy.nextAttempt == now.addingTimeInterval(2))
        #expect(decision(policy) == .waitingForRetry)
        #expect(policy.decision(settings: enabled, canCapture: true, hasPairedClient: true,
            hasUserSession: true, isSharing: false, now: now.addingTimeInterval(2)) == .startAuthorizedDevices)
        for _ in 0..<20 { policy.failed(at: now) }
        #expect(policy.nextAttempt == now.addingTimeInterval(60))
        policy.reset()
        #expect(decision(policy) == .startAuthorizedDevices)
    }

    private func decision(_ policy: CompanionAutoSharePolicy, settings: CompanionHostSettings? = nil,
                          canCapture: Bool = true, hasPairedClient: Bool = true,
                          hasUserSession: Bool = true, isSharing: Bool = false) -> CompanionAutoSharePolicy.Decision {
        policy.decision(settings: settings ?? enabled, canCapture: canCapture,
            hasPairedClient: hasPairedClient, hasUserSession: hasUserSession, isSharing: isSharing, now: now)
    }
}
