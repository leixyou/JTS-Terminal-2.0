#if ENABLE_RDP_2
import Foundation

/// Holds a target's opening transaction across suspensions. Cancellation cannot
/// let the old transaction finish or clear a replacement transaction's lease.
struct CompanionDesktopOpeningGate {
    private var tokens: [UUID: UUID] = [:]
    mutating func begin(_ target: UUID) -> UUID? {
        guard tokens[target] == nil else { return nil }
        let token = UUID(); tokens[target] = token; return token
    }
    func isCurrent(_ target: UUID, token: UUID) -> Bool { tokens[target] == token }
    mutating func finish(_ target: UUID, token: UUID) {
        if isCurrent(target, token: token) { tokens[target] = nil }
    }
    mutating func cancel(_ target: UUID) { tokens[target] = nil }
}
#endif
