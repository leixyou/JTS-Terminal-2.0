#if ENABLE_RDP_2
import Foundation

nonisolated enum FreeRDPXPCCoalescingAdmission: Equatable, Sendable {
    case scheduleDrain
    case coalesced
    case firstRejection
    case rejected
}

/// Keeps at most one queued payload in addition to the payload currently being
/// delivered. Each retained payload owns a separate limiter reservation, while
/// newer queued values replace the older queued value in place. High-frequency
/// framebuffer notifications are state snapshots, so replaying every
/// intermediate frame only delays the current desktop and can starve control
/// callbacks.
nonisolated final class FreeRDPXPCLatestCallbackSlot<Payload>: @unchecked Sendable {
    private let lock = NSLock()
    private let limiter: FreeRDPXPCInboundLimiter
    private let reservedByteCost: Int
    private var latestPayload: Payload?
    private var drainScheduled = false
    private var deliveryInFlight = false

    init(
        limiter: FreeRDPXPCInboundLimiter,
        reservedByteCost: Int
    ) {
        precondition(reservedByteCost >= 0)
        self.limiter = limiter
        self.reservedByteCost = reservedByteCost
    }

    func submit(_ payload: Payload) -> FreeRDPXPCCoalescingAdmission {
        lock.withLock {
            guard !limiter.hasRejectedInput else {
                return .rejected
            }
            if latestPayload != nil {
                latestPayload = payload
                return .coalesced
            }

            switch limiter.admit(byteCost: reservedByteCost) {
            case .accepted:
                latestPayload = payload
                if deliveryInFlight {
                    return .coalesced
                }
                drainScheduled = true
                return .scheduleDrain
            case .firstRejection:
                return .firstRejection
            case .rejected:
                return .rejected
            }
        }
    }

    func takeLatestForDelivery() -> Payload? {
        lock.withLock {
            guard drainScheduled, !deliveryInFlight, let payload = latestPayload else {
                return nil
            }
            latestPayload = nil
            drainScheduled = false
            deliveryInFlight = true
            return payload
        }
    }

    /// Returns true when a newer payload arrived during delivery. The caller
    /// should yield and schedule one more drain in that case.
    func finishDelivery() -> Bool {
        lock.withLock {
            guard deliveryInFlight else {
                return false
            }
            deliveryInFlight = false
            limiter.complete(byteCost: reservedByteCost)
            if latestPayload != nil {
                drainScheduled = true
                return true
            }
            return false
        }
    }
}
#endif
