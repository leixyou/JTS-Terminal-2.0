import Foundation

/// Automatic starts always accept authorized devices only. Invitations are a
/// separate, explicit user action and never a side effect of startup or retry.
struct CompanionAutoSharePolicy {
    enum Decision: Equatable {
        case disabled, paused, userSessionRequired, screenPermissionRequired, pairingRequired
        case alreadySharing, waitingForRetry, startAuthorizedDevices
    }

    private(set) var nextAttempt: Date?
    private(set) var failureCount = 0

    func decision(settings: CompanionHostSettings, canCapture: Bool, hasPairedClient: Bool,
                  hasUserSession: Bool, isSharing: Bool, now: Date) -> Decision {
        guard settings.automaticSharing else { return .disabled }
        guard !settings.sharingPaused else { return .paused }
        guard hasUserSession else { return .userSessionRequired }
        guard canCapture else { return .screenPermissionRequired }
        guard hasPairedClient else { return .pairingRequired }
        guard !isSharing else { return .alreadySharing }
        if let nextAttempt, nextAttempt > now { return .waitingForRetry }
        return .startAuthorizedDevices
    }

    mutating func failed(at now: Date) {
        failureCount = min(failureCount + 1, 6)
        let delay = min(60, pow(2, Double(failureCount)))
        nextAttempt = now.addingTimeInterval(delay)
    }

    mutating func reset() {
        failureCount = 0
        nextAttempt = nil
    }
}
