#if ENABLE_RDP_2
import Foundation
import CoreFoundation

/// The UIA reader shares selector validation with semantic actions, but never
/// accepts a mutation payload or opens a desktop as a side effect.
struct WindowsUIAQuery {
    enum Operation: String { case snapshot, find }
    let operation: Operation
    let parameters: [String: Any]
    let maximumNodes: Int
    let maximumDepth: Int
    let deadlineMilliseconds: Int

    var method: String { operation == .snapshot ? "uia.snapshot" : "uia.find" }

    init(_ arguments: [String: Any]) throws {
        let envelope: Set<String> = ["targetId", "sessionId", "expectedStateRevision", "deadlineMs",
            "operation", "_jtsClientID", "_jtsClientDisplayIdentity", "_jtsDeadlineUptimeMilliseconds"]
        guard let raw = arguments["operation"] as? String, let operation = Operation(rawValue: raw) else {
            throw Self.invalid("operation must be snapshot or find.")
        }
        self.operation = operation
        if let revision = arguments["expectedStateRevision"], Self.unsignedInteger(revision) == nil {
            throw Self.invalid("expectedStateRevision must be an exact non-negative desktop state revision.")
        }
        deadlineMilliseconds = try Self.bounded(arguments["deadlineMs"], default: 10_000, range: 100...30_000)
        switch operation {
        case .snapshot:
            guard Set(arguments.keys).isSubset(of: envelope.union(["maximumDepth", "maximumNodes"])) else {
                throw Self.invalid("snapshot contains unsupported arguments.")
            }
            maximumDepth = try Self.bounded(arguments["maximumDepth"], default: 4, range: 1...10)
            maximumNodes = try Self.bounded(arguments["maximumNodes"], default: 200, range: 1...1_000)
            parameters = ["maximumDepth": maximumDepth, "maximumNodes": maximumNodes]
        case .find:
            guard Set(arguments.keys).isSubset(of: envelope.union(["selector", "maximumResults"])),
                  let selector = arguments["selector"] as? String, selector.utf8.count <= 16_384 else {
                throw Self.invalid("find requires a bounded JSON selector and supported arguments.")
            }
            try WindowsMCPDesktopActionRequestParser.validateSelector(selector, requiresMutationIdentity: false)
            let value = try JSONSerialization.jsonObject(with: Data(selector.utf8))
            maximumDepth = 0
            maximumNodes = try Self.bounded(arguments["maximumResults"], default: 50, range: 1...500)
            parameters = ["selector": value, "maximumResults": maximumNodes]
        }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Int(String) rejects fractions, infinity and out-of-range values without trapping.
        return Int(number.stringValue)
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }

    private static func bounded(_ value: Any?, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value else { return fallback }
        guard let number = integer(value), range.contains(number) else {
            throw invalid("UIA limits must be exact integers within the advertised bounds.")
        }
        return number
    }

    private static func invalid(_ message: String) -> WindowsMCPToolError {
        WindowsMCPToolError(code: .invalidArgument, message: message)
    }
}

/// Transient observation references are scoped to the exact caller and runtime
/// generations, so reconnect, takeover and revocation invalidate old references.
nonisolated struct RDPUIAObservationLedger {
    private struct Entry {
        let token: RDPAuthorizedOperationToken
        let sessionID: UUID
        let expiresAt: TimeInterval
    }
    private var entries: [UUID: Entry] = [:]
    static let capacity = 128
    static let lifetime: TimeInterval = 60

    mutating func record(token: RDPAuthorizedOperationToken, sessionID: UUID,
                         now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID {
        entries = entries.filter { $0.value.expiresAt > now }
        if entries.count >= Self.capacity,
           let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        let id = UUID()
        entries[id] = Entry(token: token, sessionID: sessionID, expiresAt: now + Self.lifetime)
        return id
    }

    func validate(_ id: UUID, token: RDPAuthorizedOperationToken, sessionID: UUID,
                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard let entry = entries[id], entry.expiresAt > now, entry.sessionID == sessionID,
              entry.token.targetID == token.targetID, entry.token.targetBinding == token.targetBinding,
              entry.token.clientID == token.clientID, entry.token.generation == token.generation,
              entry.token.connectionGeneration == token.connectionGeneration else {
            throw WindowsMCPToolError(code: .stateConflict,
                message: "The UI Automation observation expired or its desktop/control context changed. Observe again.")
        }
    }

    mutating func removeAll() { entries.removeAll() }

    mutating func remove(targetID: UUID) {
        entries = entries.filter { $0.value.token.targetID != targetID }
    }
}
#endif
