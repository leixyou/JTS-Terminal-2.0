#if ENABLE_RDP_2
import Foundation

nonisolated struct RDPReconnectPolicy: Equatable, Sendable {
    static let standard = RDPReconnectPolicy(
        maximumAttempts: 5,
        initialDelaySeconds: 1,
        maximumDelaySeconds: 16
    )

    let maximumAttempts: Int
    let initialDelaySeconds: TimeInterval
    let maximumDelaySeconds: TimeInterval

    init(
        maximumAttempts: Int,
        initialDelaySeconds: TimeInterval,
        maximumDelaySeconds: TimeInterval
    ) {
        self.maximumAttempts = max(0, maximumAttempts)
        self.initialDelaySeconds = max(0, initialDelaySeconds)
        self.maximumDelaySeconds = max(self.initialDelaySeconds, maximumDelaySeconds)
    }

    func delaySeconds(forAttempt attempt: Int) -> TimeInterval {
        let boundedExponent = min(max(attempt - 1, 0), 30)
        return min(
            initialDelaySeconds * pow(2, Double(boundedExponent)),
            maximumDelaySeconds
        )
    }

    func permitsReconnect(phase: RDPConnectionPhase, failureCode: String?) -> Bool {
        guard phase != .closed, phase != .awaitingCertificateTrust else {
            return false
        }

        let normalizedCode = failureCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard !normalizedCode.isEmpty else {
            return true
        }

        let explicitlyRetryable: Set<String> = [
            "RDP_CONNECTION_LOST",
            "RDP_XPC_INVALIDATED",
            "RDP_XPC_INTERRUPTED",
            "RDP_XPC_START_FAILED",
            "XPC_NOT_CONNECTED",
            "XPC_PROXY_UNAVAILABLE",
            "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
            "ERRCONNECT_DNS_NAME_NOT_FOUND",
            "ERRCONNECT_DNS_ERROR",
            "ERRCONNECT_CONNECT_FAILED",
        ]
        if explicitlyRetryable.contains(normalizedCode) {
            return true
        }

        if normalizedCode == RDPLocalNetworkRecovery.decisionPendingCode {
            return false
        }

        let nonRetryableFragments = [
            "CERT",
            "AUTH",
            "LOGOFF",
            "LOGON",
            "PASSWORD",
            "ACCOUNT",
            "CREDENTIAL",
            "NLA",
            "TLS",
            "SECURITY",
            "POLICY",
            "PRIVILEGE",
            "PERMISSION",
            "DENIED",
            "REVOKED",
            "BLOCKED",
            "REJECTED",
            "CANCELLED",
            "CANCELED",
            "INVALID_CONFIGURATION",
            "SETTINGS",
            "REDIRECTION",
            "RESOLUTION",
            "LICENSE",
        ]
        return !nonRetryableFragments.contains { normalizedCode.contains($0) }
    }
}

nonisolated struct RDPReconnectFailure: Equatable, Sendable {
    var phase: RDPConnectionPhase
    var code: String?
    var message: String
}

nonisolated struct RDPReconnectSchedule: Equatable, Sendable {
    var attempt: Int
    var maximumAttempts: Int
    var delaySeconds: TimeInterval
    var scheduledAt: Date
    fileprivate var generation: UInt64
}

nonisolated enum RDPReconnectStatus: Equatable, Sendable {
    case idle
    case scheduled(RDPReconnectSchedule)
    case reconnecting(attempt: Int)
    case blocked(code: String?)
    case exhausted(attempts: Int)
    case stopped
}

nonisolated enum RDPReconnectPlan: Equatable, Sendable {
    case scheduled(RDPReconnectSchedule)
    case alreadyScheduled
    case blocked
    case alreadyBlocked
    case exhausted
    case stopped
}

/// Pure reconnect state machine. The runtime owns the sleeping `Task`; this
/// type owns retry classification, the bounded attempt budget, and generation
/// tokens so a user stop invalidates work that wakes up later.
nonisolated struct RDPReconnectSupervisor: Sendable {
    let policy: RDPReconnectPolicy

    private(set) var status: RDPReconnectStatus = .idle
    private(set) var attemptCount = 0
    private var generation: UInt64 = 0

    var hasPendingAttempt: Bool {
        switch status {
        case .scheduled, .reconnecting:
            true
        case .idle, .blocked, .exhausted, .stopped:
            false
        }
    }

    init(policy: RDPReconnectPolicy = .standard) {
        self.policy = policy
    }

    mutating func plan(after failure: RDPReconnectFailure, now: Date) -> RDPReconnectPlan {
        guard status != .stopped else {
            return .stopped
        }
        if case .blocked = status {
            return .alreadyBlocked
        }
        guard policy.permitsReconnect(phase: failure.phase, failureCode: failure.code) else {
            block(after: failure)
            return .blocked
        }
        if case .scheduled = status {
            return .alreadyScheduled
        }
        guard attemptCount < policy.maximumAttempts else {
            generation &+= 1
            status = .exhausted(attempts: attemptCount)
            return .exhausted
        }

        attemptCount += 1
        generation &+= 1
        let delay = policy.delaySeconds(forAttempt: attemptCount)
        let schedule = RDPReconnectSchedule(
            attempt: attemptCount,
            maximumAttempts: policy.maximumAttempts,
            delaySeconds: delay,
            scheduledAt: now.addingTimeInterval(delay),
            generation: generation
        )
        status = .scheduled(schedule)
        return .scheduled(schedule)
    }

    mutating func begin(_ schedule: RDPReconnectSchedule) -> Bool {
        guard case .scheduled(let pending) = status,
              pending.generation == schedule.generation,
              generation == schedule.generation else {
            return false
        }
        status = .reconnecting(attempt: schedule.attempt)
        return true
    }

    mutating func markConnected() {
        generation &+= 1
        attemptCount = 0
        status = .idle
    }

    mutating func block(after failure: RDPReconnectFailure) {
        generation &+= 1
        status = .blocked(code: failure.code)
    }

    mutating func stop() {
        generation &+= 1
        attemptCount = 0
        status = .stopped
    }
}
#endif
