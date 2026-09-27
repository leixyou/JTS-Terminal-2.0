import Foundation
import XCTest
@testable import JTSCompanionTransport

final class ReadyCancellationTests: XCTestCase {
    func testCancellationClosesSocketBlockedBeforeReady() async throws {
        let reading = expectation(description: "waiting for relay ready")
        let finished = expectation(description: "cancelled readiness finished")
        let socket = PendingReadySocket(onRead: { reading.fulfill() })
        let task = Task {
            do {
                _ = try await RelayWebSocketCarrier.acceptReady(connection: socket,
                    sessionID: UUID().uuidString.lowercased(), lane: .control)
                XCTFail("cancelled readiness returned a carrier")
            } catch { /* Closing the socket or cancellation may win. */ }
            finished.fulfill()
        }
        await fulfillment(of: [reading], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        let facts = await socket.facts()
        // Drain even when a regression times out, rather than leaking the test's continuation.
        await socket.close()
        await task.value
        XCTAssertTrue(facts.closed)
        XCTAssertEqual(facts.reads, 1)
        XCTAssertEqual(facts.writes, 0)
    }

    func testAlreadyCancelledReadinessClosesWithoutStartingReceive() async {
        let finished = expectation(description: "pre-cancelled readiness finished")
        let socket = PendingReadySocket()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await RelayWebSocketCarrier.acceptReady(connection: socket,
                    sessionID: UUID().uuidString.lowercased(), lane: .control)
                XCTFail("pre-cancelled readiness returned a carrier")
            } catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        let facts = await socket.facts()
        await socket.close()
        await task.value
        XCTAssertTrue(facts.closed)
        XCTAssertEqual(facts.reads, 0)
        XCTAssertEqual(facts.writes, 0)
    }

    func testCancellationDeliveredWithReadyCannotReturnCarrier() async {
        let id = UUID().uuidString.lowercased()
        let ready = "{\"ready\":true,\"sessionId\":\"\(id)\",\"lane\":\"control\"}"
        let socket = PendingReadySocket(cancelWithReady: ready)
        let task = Task {
            do {
                _ = try await RelayWebSocketCarrier.acceptReady(connection: socket, sessionID: id, lane: .control)
                XCTFail("readiness resumed after cancellation returned a carrier")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        let facts = await socket.facts()
        XCTAssertTrue(facts.closed)
        XCTAssertEqual(facts.reads, 1)
        XCTAssertEqual(facts.writes, 0)
    }
}

/// Intentionally ignores Swift cancellation: only close() wakes a pending read.
private actor PendingReadySocket: RelayWebSocketConnection {
    private let onRead: @Sendable () -> Void
    private let cancelWithReady: String?
    private var waiter: CheckedContinuation<RelayWebSocketMessage, Error>?
    private var closed = false
    private var reads = 0, writes = 0

    init(cancelWithReady: String? = nil, onRead: @escaping @Sendable () -> Void = {}) {
        self.cancelWithReady = cancelWithReady; self.onRead = onRead
    }

    func receive() async throws -> RelayWebSocketMessage {
        reads += 1
        guard !closed else { throw CompanionTransportError.connectionClosed }
        if let cancelWithReady {
            withUnsafeCurrentTask { $0?.cancel() }
            return .text(cancelWithReady)
        }
        return try await withCheckedThrowingContinuation { waiter = $0; onRead() }
    }

    func sendBinary(_ bytes: Data) { writes += 1 }

    func close() {
        closed = true
        let pending = waiter; waiter = nil
        pending?.resume(throwing: CompanionTransportError.connectionClosed)
    }

    func facts() -> (closed: Bool, reads: Int, writes: Int) { (closed, reads, writes) }
}
