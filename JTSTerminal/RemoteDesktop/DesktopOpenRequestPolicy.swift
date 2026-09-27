#if ENABLE_RDP_2
import CryptoKit
import Foundation

nonisolated enum DesktopOpenRequestValidationFailure: LocalizedError, Equatable, Sendable {
    case invalidDeadline
    case invalidIdempotencyKey

    var errorDescription: String? {
        switch self {
        case .invalidDeadline:
            "deadlineMs must be between 100 and 60,000 milliseconds for desktop open requests."
        case .invalidIdempotencyKey:
            "idempotencyKey must contain 1 to 128 characters and no NUL byte."
        }
    }
}

nonisolated struct DesktopOpenRequestSignature: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let targetBinding: String

    init(
        pixelWidth: Int,
        pixelHeight: Int,
        targetBinding: String = "unbound-test-target"
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.targetBinding = targetBinding
    }
}

nonisolated struct DesktopOpenRequestPlan: Equatable, Sendable {
    let deadlineMilliseconds: Int
    let idempotencyKeyDigest: String?
    let idempotencyClientID: String
    let signature: DesktopOpenRequestSignature
    let startedUptime: TimeInterval
    let deadlineUptime: TimeInterval

    func remainingMilliseconds(at uptime: TimeInterval) -> Int {
        let remaining = deadlineUptime - uptime
        guard remaining > 0 else { return 0 }
        return max(1, Int(ceil(remaining * 1_000)))
    }
}

nonisolated enum DesktopOpenRequestPolicy {
    static let defaultDeadlineMilliseconds = 10_000
    static let minimumDeadlineMilliseconds = 100
    static let maximumDeadlineMilliseconds = 60_000
    static let maximumIdempotencyKeyCharacters = 128

    static func plan(
        request: DesktopOpenRequest,
        profile: RDPConnectionProfile,
        targetBinding: String = "unbound-test-target",
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws -> DesktopOpenRequestPlan {
        let deadline = request.deadlineMilliseconds ?? defaultDeadlineMilliseconds
        guard (minimumDeadlineMilliseconds...maximumDeadlineMilliseconds).contains(deadline) else {
            throw DesktopOpenRequestValidationFailure.invalidDeadline
        }

        let idempotencyKeyDigest: String?
        if let rawKey = request.idempotencyKey {
            let normalized = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized.utf16.count <= maximumIdempotencyKeyCharacters,
                  !normalized.contains("\0") else {
                throw DesktopOpenRequestValidationFailure.invalidIdempotencyKey
            }
            idempotencyKeyDigest = SHA256.hash(data: Data(normalized.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        } else {
            idempotencyKeyDigest = nil
        }
        let idempotencyClientID = request.clientID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(128)
        let scopedClientID = idempotencyClientID.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
            ?? "local-ui"

        let width = min(max(request.requestedPixelWidth ?? profile.desktopWidth, 640), 7_680)
        let height = min(max(request.requestedPixelHeight ?? profile.desktopHeight, 480), 4_320)
        let relativeDeadlineUptime = nowUptime + TimeInterval(deadline) / 1_000
        let propagatedDeadlineUptime = request.deadlineUptimeMilliseconds.map {
            TimeInterval($0) / 1_000
        }
        return DesktopOpenRequestPlan(
            deadlineMilliseconds: deadline,
            idempotencyKeyDigest: idempotencyKeyDigest,
            idempotencyClientID: scopedClientID,
            signature: DesktopOpenRequestSignature(
                pixelWidth: width,
                pixelHeight: height,
                targetBinding: targetBinding
            ),
            startedUptime: nowUptime,
            deadlineUptime: min(propagatedDeadlineUptime ?? relativeDeadlineUptime, relativeDeadlineUptime)
        )
    }
}

nonisolated struct DesktopOpenIdempotencyScope: Hashable, Sendable {
    let targetID: UUID
    let clientID: String
    let keyDigest: String
}

nonisolated struct DesktopOpenStoredFailure: Equatable, Sendable {
    let code: String
    let message: String
    let machineCode: String?
    let retryable: Bool
}

nonisolated struct DesktopOpenIdempotencyCapacityExceeded: LocalizedError, Equatable, Sendable {
    var errorDescription: String? {
        "The in-flight desktop open already has the maximum number of waiting requests or idempotency aliases."
    }
}

nonisolated enum DesktopOpenIdempotencyOutcome: Equatable, Sendable {
    case pending(operationID: UUID)
    case success(RDPDesktopSessionState)
    case failure(DesktopOpenStoredFailure)
}

nonisolated struct DesktopOpenIdempotencyConflict: LocalizedError, Equatable, Sendable {
    let scope: DesktopOpenIdempotencyScope

    var errorDescription: String? {
        "The idempotencyKey was already used for different desktop parameters or target configuration."
    }
}

/// A bounded, in-memory replay ledger. It never persists credentials or
/// request payloads beyond the normalized dimensions needed for conflict
/// detection.
nonisolated struct DesktopOpenIdempotencyLedger {
    static let defaultRetentionSeconds: TimeInterval = 10 * 60
    static let defaultMaximumRecords = 256
    static let defaultMaximumPendingAliasesPerOperation = 32

    private struct Record {
        let signature: DesktopOpenRequestSignature
        var outcome: DesktopOpenIdempotencyOutcome
        let acceptedUptime: TimeInterval
    }

    private var records: [DesktopOpenIdempotencyScope: Record] = [:]
    private let retentionSeconds: TimeInterval
    private let maximumRecords: Int
    private let maximumPendingAliasesPerOperation: Int

    init(
        retentionSeconds: TimeInterval = defaultRetentionSeconds,
        maximumRecords: Int = defaultMaximumRecords,
        maximumPendingAliasesPerOperation: Int = defaultMaximumPendingAliasesPerOperation
    ) {
        precondition(retentionSeconds > 0 && retentionSeconds.isFinite)
        precondition(maximumRecords > 0)
        precondition(maximumPendingAliasesPerOperation > 0)
        self.retentionSeconds = retentionSeconds
        self.maximumRecords = maximumRecords
        self.maximumPendingAliasesPerOperation = min(
            maximumPendingAliasesPerOperation,
            maximumRecords
        )
    }

    var recordCount: Int { records.count }

    mutating func lookup(
        scope: DesktopOpenIdempotencyScope,
        signature: DesktopOpenRequestSignature,
        nowUptime: TimeInterval
    ) throws -> DesktopOpenIdempotencyOutcome? {
        pruneExpired(nowUptime: nowUptime)
        guard let record = records[scope] else { return nil }
        guard record.signature == signature else {
            throw DesktopOpenIdempotencyConflict(scope: scope)
        }
        return record.outcome
    }

    mutating func reserve(
        scope: DesktopOpenIdempotencyScope,
        signature: DesktopOpenRequestSignature,
        operationID: UUID,
        nowUptime: TimeInterval
    ) throws -> DesktopOpenIdempotencyOutcome? {
        if let existing = try lookup(
            scope: scope,
            signature: signature,
            nowUptime: nowUptime
        ) {
            return existing
        }
        let pendingAliasCount = records.values.reduce(into: 0) { count, record in
            if record.outcome == .pending(operationID: operationID) {
                count += 1
            }
        }
        guard pendingAliasCount < maximumPendingAliasesPerOperation else {
            throw DesktopOpenIdempotencyCapacityExceeded()
        }
        try makeCapacityForPendingRecord()
        records[scope] = Record(
            signature: signature,
            outcome: .pending(operationID: operationID),
            acceptedUptime: nowUptime
        )
        trimCompletedRecordsIfNeeded()
        return nil
    }

    mutating func storeImmediateSuccess(
        scope: DesktopOpenIdempotencyScope,
        signature: DesktopOpenRequestSignature,
        state: RDPDesktopSessionState,
        nowUptime: TimeInterval
    ) throws {
        if try lookup(scope: scope, signature: signature, nowUptime: nowUptime) != nil {
            return
        }
        try makeCapacityForPendingRecord()
        records[scope] = Record(
            signature: signature,
            outcome: .success(state),
            acceptedUptime: nowUptime
        )
        trimCompletedRecordsIfNeeded()
    }

    mutating func complete(
        operationID: UUID,
        outcome: DesktopOpenIdempotencyOutcome
    ) {
        precondition(!outcome.isPending, "A completed desktop open cannot remain pending.")
        for scope in Array(records.keys) {
            guard var record = records[scope],
                  record.outcome == .pending(operationID: operationID) else {
                continue
            }
            record.outcome = outcome
            records[scope] = record
        }
        trimCompletedRecordsIfNeeded()
    }

    mutating func discardPending(
        scope: DesktopOpenIdempotencyScope,
        operationID: UUID
    ) {
        guard records[scope]?.outcome == .pending(operationID: operationID) else { return }
        records.removeValue(forKey: scope)
    }

    mutating func updateSuccessState(_ state: RDPDesktopSessionState) {
        for scope in Array(records.keys) {
            guard var record = records[scope],
                  case let .success(previous) = record.outcome,
                  previous.sessionID == state.sessionID else {
                continue
            }
            record.outcome = .success(state)
            records[scope] = record
        }
    }

    mutating func removeAll() {
        records.removeAll(keepingCapacity: false)
    }

    private mutating func pruneExpired(nowUptime: TimeInterval) {
        records = records.filter { _, record in
            nowUptime < record.acceptedUptime
                || nowUptime - record.acceptedUptime <= retentionSeconds
        }
    }

    private mutating func trimCompletedRecordsIfNeeded() {
        while records.count > maximumRecords {
            guard let oldestCompleted = records
                .filter({ !$0.value.outcome.isPending })
                .min(by: { $0.value.acceptedUptime < $1.value.acceptedUptime })?.key else {
                // Pending opens are bounded separately by their 60-second
                // maximum deadline; do not evict one and permit a duplicate.
                return
            }
            records.removeValue(forKey: oldestCompleted)
        }
    }

    private mutating func makeCapacityForPendingRecord() throws {
        while records.count >= maximumRecords {
            guard let oldestCompleted = records
                .filter({ !$0.value.outcome.isPending })
                .min(by: { $0.value.acceptedUptime < $1.value.acceptedUptime })?.key else {
                throw DesktopOpenIdempotencyCapacityExceeded()
            }
            records.removeValue(forKey: oldestCompleted)
        }
    }
}

nonisolated private extension DesktopOpenIdempotencyOutcome {
    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}
#endif
