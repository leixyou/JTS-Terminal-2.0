#if ENABLE_RDP_2
import AppKit
import Foundation
@preconcurrency import Network

nonisolated enum RDPLocalNetworkRecovery {
    static let pathBlockedCode = "RDP_LOCAL_NETWORK_PATH_BLOCKED"
    static let legacyDenialCode = "RDP_LOCAL_NETWORK_PERMISSION_DENIED"
    static let decisionPendingCode = "RDP_LOCAL_NETWORK_DECISION_PENDING"
    static let pathBlockedMessage = "Network.framework reported that macOS blocked this running JTS Terminal copy from reaching the saved local-network host. This does not prove the Local Network switch is off; a stale privacy decision or multiple app copies can produce the same result."
    static let decisionPendingMessage = "Network.framework temporarily reported a local-network denial, but macOS has not produced a stable permission decision yet. Keep this JTS Terminal copy open and retry the connection to confirm the result."

    private static let transportFailureCodes: Set<String> = [
        "ERRCONNECT_CONNECT_FAILED",
        "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
        "ERRCONNECT_DNS_ERROR",
        "ERRCONNECT_DNS_NAME_NOT_FOUND",
        "RDP_CONNECTION_LOST",
    ]

    static func isPathBlocked(code: String?) -> Bool {
        let normalizedCode = normalized(code)
        return normalizedCode == pathBlockedCode
            || normalizedCode == legacyDenialCode
    }

    static func needsPathDiagnosis(_ failure: RDPReconnectFailure) -> Bool {
        guard failure.phase == .failed || failure.phase == .reconnecting else {
            return false
        }
        if isPathBlocked(code: failure.code) {
            return false
        }

        let normalizedCode = normalized(failure.code)
        if transportFailureCodes.contains(normalizedCode) {
            return true
        }
        guard normalizedCode.isEmpty else {
            return false
        }

        let normalizedMessage = normalized(failure.message)
        return normalizedMessage.contains("NO ROUTE TO HOST")
            || normalizedMessage.contains("NETWORK IS UNREACHABLE")
            || normalizedMessage.contains("OPERATION NOT PERMITTED")
            || normalizedMessage.contains("POLICY DENIED")
    }

    static func isDecisionPending(code: String?) -> Bool {
        normalized(code) == decisionPendingCode
    }

    static func pathBlockedFailure(phase: RDPConnectionPhase) -> RDPReconnectFailure {
        RDPReconnectFailure(
            phase: phase,
            code: pathBlockedCode,
            message: pathBlockedMessage
        )
    }

    static func decisionPendingFailure(phase: RDPConnectionPhase) -> RDPReconnectFailure {
        RDPReconnectFailure(
            phase: phase,
            code: decisionPendingCode,
            message: decisionPendingMessage
        )
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
    }
}

nonisolated extension RDPDesktopSessionState {
    var isLocalNetworkPathBlocked: Bool {
        RDPLocalNetworkRecovery.isPathBlocked(code: lastErrorCode)
    }

    var isLocalNetworkDecisionPending: Bool {
        RDPLocalNetworkRecovery.isDecisionPending(code: lastErrorCode)
    }
}

nonisolated enum RDPLocalNetworkDiagnosticResult: Equatable, Sendable {
    case pathBlocked
    case decisionPending
    case permissionResolved
    case notDenied
    case inconclusive
}

nonisolated enum RDPLocalNetworkDiagnosticMode: Equatable, Sendable {
    case initial
    case confirmedRecheck

    var defaultTimeoutMilliseconds: Int {
        switch self {
        case .initial:
            8_000
        case .confirmedRecheck:
            2_000
        }
    }
}

/// Pure decision policy for the Network.framework observation window.
///
/// A first local-network denial is provisional because macOS can report it
/// while presenting or refreshing the privacy decision. The initial pass
/// therefore leaves the decision pending. Only a short, explicit recheck may
/// turn a denial that remains current for the full window into `pathBlocked`.
nonisolated struct RDPLocalNetworkDiagnosticPolicy: Sendable {
    let mode: RDPLocalNetworkDiagnosticMode
    private(set) var observedLocalNetworkDenial = false
    private(set) var isCurrentlyLocalNetworkDenied = false

    init(mode: RDPLocalNetworkDiagnosticMode) {
        self.mode = mode
    }

    mutating func observePath(
        status: NWPath.Status,
        unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) {
        let isDenied = RDPLocalNetworkPathDiagnostic.result(
            for: status,
            unsatisfiedReason: unsatisfiedReason
        ) == .pathBlocked
        observedLocalNetworkDenial = observedLocalNetworkDenial || isDenied
        isCurrentlyLocalNetworkDenied = isDenied
    }

    func readyResult() -> RDPLocalNetworkDiagnosticResult {
        observedLocalNetworkDenial ? .permissionResolved : .notDenied
    }

    func timeoutResult() -> RDPLocalNetworkDiagnosticResult {
        guard observedLocalNetworkDenial else {
            return .inconclusive
        }
        switch mode {
        case .initial:
            return .decisionPending
        case .confirmedRecheck:
            return isCurrentlyLocalNetworkDenied ? .pathBlocked : .inconclusive
        }
    }

    func failureResult() -> RDPLocalNetworkDiagnosticResult? {
        observedLocalNetworkDenial ? nil : .inconclusive
    }
}

nonisolated struct RDPLocalNetworkDiagnosticEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16

    init?(host: String, port: Int) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              let port = UInt16(exactly: port),
              port > 0 else {
            return nil
        }
        self.host = trimmedHost
        self.port = port
    }
}

/// Checks only the exact saved endpoint after FreeRDP reports a transport
/// failure. It performs no Bonjour browsing, subnet enumeration, or listening.
/// No application bytes are sent; the connection exists only long enough to
/// inspect Network.framework's path denial reason.
nonisolated enum RDPLocalNetworkPathDiagnostic {
    static func diagnose(
        endpoint: RDPLocalNetworkDiagnosticEndpoint,
        mode: RDPLocalNetworkDiagnosticMode = .initial,
        timeoutMilliseconds: Int? = nil
    ) async -> RDPLocalNetworkDiagnosticResult {
        guard let networkPort = NWEndpoint.Port(rawValue: endpoint.port) else {
            return .inconclusive
        }
        let observationMilliseconds = max(
            250,
            timeoutMilliseconds ?? mode.defaultTimeoutMilliseconds
        )
        let cancellation = RDPLocalNetworkDiagnosticCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let operation = RDPLocalNetworkDiagnosticOperation(
                    policy: RDPLocalNetworkDiagnosticPolicy(mode: mode)
                ) { result in
                    continuation.resume(returning: result)
                }
                cancellation.install(operation)
                guard !Task.isCancelled else {
                    cancellation.cancel()
                    return
                }

                let connection = NWConnection(
                    host: NWEndpoint.Host(endpoint.host),
                    port: networkPort,
                    using: .tcp
                )
                connection.pathUpdateHandler = { path in
                    operation.observePath(
                        status: path.status,
                        unsatisfiedReason: path.unsatisfiedReason
                    )
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        operation.resolveReady()
                    case .waiting:
                        if let path = connection.currentPath {
                            operation.observePath(
                                status: path.status,
                                unsatisfiedReason: path.unsatisfiedReason
                            )
                        }
                    case .failed:
                        if let path = connection.currentPath {
                            operation.observePath(
                                status: path.status,
                                unsatisfiedReason: path.unsatisfiedReason
                            )
                        }
                        operation.resolveFailure()
                    case .setup, .preparing:
                        break
                    case .cancelled:
                        operation.resolve(.inconclusive)
                    @unknown default:
                        operation.resolve(.inconclusive)
                    }
                }

                let queue = DispatchQueue(
                    label: "com.lljts.JTSTerminal.rdp.local-network-diagnostic"
                )
                guard operation.start(connection, queue: queue) else {
                    return
                }
                queue.asyncAfter(
                    deadline: .now() + .milliseconds(observationMilliseconds)
                ) {
                    operation.resolveTimeout()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func result(
        for status: NWPath.Status,
        unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) -> RDPLocalNetworkDiagnosticResult? {
        status == .unsatisfied && unsatisfiedReason == .localNetworkDenied
            ? .pathBlocked
            : nil
    }
}

private nonisolated final class RDPLocalNetworkDiagnosticCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: RDPLocalNetworkDiagnosticOperation?
    private var isCancelled = false

    func install(_ operation: RDPLocalNetworkDiagnosticOperation) {
        let shouldCancel = lock.withLock {
            guard !isCancelled else { return true }
            self.operation = operation
            return false
        }
        if shouldCancel {
            operation.resolve(.inconclusive)
        }
    }

    func cancel() {
        let operation = lock.withLock {
            isCancelled = true
            let operation = self.operation
            self.operation = nil
            return operation
        }
        operation?.resolve(.inconclusive)
    }
}

nonisolated final class RDPLocalNetworkDiagnosticOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((RDPLocalNetworkDiagnosticResult) -> Void)?
    private var connection: NWConnection?
    private var policy: RDPLocalNetworkDiagnosticPolicy

    init(
        policy: RDPLocalNetworkDiagnosticPolicy,
        completion: @escaping (RDPLocalNetworkDiagnosticResult) -> Void
    ) {
        self.policy = policy
        self.completion = completion
    }

    func start(_ connection: NWConnection, queue: DispatchQueue) -> Bool {
        let shouldStart = lock.withLock {
            guard completion != nil else { return false }
            self.connection = connection
            connection.start(queue: queue)
            return true
        }
        if !shouldStart {
            connection.cancel()
        }
        return shouldStart
    }

    func observePath(
        status: NWPath.Status,
        unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) {
        lock.withLock {
            guard completion != nil else { return }
            policy.observePath(
                status: status,
                unsatisfiedReason: unsatisfiedReason
            )
        }
    }

    func resolveReady() {
        finish { policy in
            policy.readyResult()
        }
    }

    func resolveTimeout() {
        finish { policy in
            policy.timeoutResult()
        }
    }

    func resolveFailure() {
        finish { policy in
            policy.failureResult()
        }
    }

    func resolve(_ result: RDPLocalNetworkDiagnosticResult) {
        finish { _ in result }
    }

    private func finish(
        deciding: (inout RDPLocalNetworkDiagnosticPolicy) -> RDPLocalNetworkDiagnosticResult?
    ) {
        let captured: (
            connection: NWConnection?,
            completion: (RDPLocalNetworkDiagnosticResult) -> Void,
            result: RDPLocalNetworkDiagnosticResult
        )? = lock.withLock {
            guard let completion,
                  let result = deciding(&policy) else {
                return nil
            }
            let connection = self.connection
            self.connection = nil
            self.completion = nil
            return (connection, completion, result)
        }
        guard let captured else { return }
        captured.connection?.stateUpdateHandler = nil
        captured.connection?.pathUpdateHandler = nil
        captured.connection?.cancel()
        captured.completion(captured.result)
    }
}

nonisolated enum RDPLocalNetworkSystemSettings {
    /// The first URL targets the current System Settings extension. The second
    /// supports older macOS releases; the third is a safe Privacy & Security
    /// fallback when the Local Network anchor is unavailable.
    static let destinationURLs: [URL] = [
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork"),
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"),
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
    ].compactMap { $0 }

    @MainActor
    static func open() -> Bool {
        open(
            openURL: { NSWorkspace.shared.open($0) },
            settingsApplicationURL: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.systempreferences"
            )
        )
    }

    static func open(
        openURL: (URL) -> Bool,
        settingsApplicationURL: URL?
    ) -> Bool {
        for destination in destinationURLs where openURL(destination) {
            return true
        }
        guard let settingsApplicationURL else { return false }
        return openURL(settingsApplicationURL)
    }
}
#endif
