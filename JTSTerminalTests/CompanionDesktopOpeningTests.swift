#if ENABLE_RDP_2
import Foundation
import Testing
@testable import JTSTerminal

struct CompanionDesktopOpeningTests {
    @Test func concurrentOpenCannotAllocateASecondPrimaryLane() throws {
        var gate = CompanionDesktopOpeningGate()
        let target = UUID()
        let started = gate.begin(target), first = try #require(started)
        let duplicate = gate.begin(target), other = gate.begin(UUID())
        #expect(duplicate == nil)
        #expect(other != nil)
        gate.finish(target, token: UUID())
        #expect(gate.isCurrent(target, token: first))
        gate.finish(target, token: first)
        let reopened = gate.begin(target)
        #expect(reopened != nil)
    }
    @Test func cancelledOpenCannotClearAReplacementTransaction() throws {
        var gate = CompanionDesktopOpeningGate()
        let target = UUID()
        let started = gate.begin(target), original = try #require(started)
        gate.cancel(target)
        let restarted = gate.begin(target), replacement = try #require(restarted)
        #expect(!gate.isCurrent(target, token: original))
        gate.finish(target, token: original)
        #expect(gate.isCurrent(target, token: replacement))
    }
}
#endif
