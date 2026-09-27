import Foundation
import XCTest
import JTSCompanionIPC
@testable import JTSCompanionClient

final class ClientLifecycleTests: XCTestCase {
    func testLazySignedBoundaryAndExplicitOpenStateClose() async throws {
        let mock = MockTransport(), factory = MockFactory(MockTransport())
        let client = CompanionTransportClient(transportFactory: { try factory.make() })
        XCTAssertEqual(factory.count, 0)
        await requireFailure({ try await client.state() }, .notConnected)
        XCTAssertEqual(factory.count, 0)
        let direct = CompanionTransportClient(transportFactory: { mock })
        let opened = try await direct.open(testConfiguration())
        XCTAssertEqual(opened.sessionID, mock.sessionID)
        let state = try await direct.state(); XCTAssertEqual(state.phase, "connected")
        try await direct.close()
        XCTAssertEqual(mock.requests.map(\.operation), [.open, .state, .close]); XCTAssertEqual(mock.invalidationCount, 1)
        await requireFailure({ try await direct.state() }, .notConnected)
        XCTAssertEqual(CompanionHelperIdentity.serviceName, "com.lljts.JTSTerminal.CompanionTransportService")
        XCTAssertTrue(CompanionHelperIdentity.signingRequirement.contains("anchor apple generic"))
        XCTAssertTrue(CompanionHelperIdentity.signingRequirement.contains("YOURTEAMID"))
    }

    func testOneInflightRequestAndExplicitCloseCancelsIt() async throws {
        let mock = MockTransport(); mock.hold([.state])
        let client = CompanionTransportClient(transportFactory: { mock })
        _ = try await client.open(testConfiguration())
        let pending = Task { try await client.state() }
        try await waitForRequests(mock, count: 2)
        await requireFailure({ try await client.state() }, .busy)
        await requireFailure({ try await client.open(testConfiguration()) }, .busy)
        XCTAssertEqual(mock.requests.count, 2)
        try await client.close()
        await requireFailure({ try await pending.value }, .cancelled)
        XCTAssertEqual(mock.invalidationCount, 1); XCTAssertEqual(mock.requests.count, 2)
    }

    func testInterruptionFailsPendingWithoutReplay() async throws {
        let first = MockTransport(), second = MockTransport(); first.hold([.state])
        let factory = MockFactory(first, second)
        let client = CompanionTransportClient(transportFactory: { try factory.make() })
        _ = try await client.open(testConfiguration())
        let pending = Task { try await client.state() }; try await waitForRequests(first, count: 2)
        first.lose()
        await requireFailure({ try await pending.value }, .interrupted)
        XCTAssertEqual(factory.count, 1); XCTAssertEqual(first.invalidationCount, 1)
        await requireFailure({ try await client.state() }, .notConnected)
        _ = try await client.open(testConfiguration())
        XCTAssertEqual(factory.count, 2); XCTAssertEqual(second.requests.map(\.operation), [.open])
        XCTAssertNotEqual(first.requests[0].connectionID, second.requests[0].connectionID)
        await client.invalidate()
    }

    func testLateReplyAndLateFailureCannotDamageReplacementGeneration() async throws {
        let first = MockTransport(), second = MockTransport(); first.hold([.state])
        let factory = MockFactory(first, second)
        let client = CompanionTransportClient(transportFactory: { try factory.make() })
        _ = try await client.open(testConfiguration())
        let old = Task { try await client.state() }; try await waitForRequests(first, count: 2)
        await client.invalidate(); await requireFailure({ try await old.value }, .invalidated)
        _ = try await client.open(testConfiguration())
        first.deliver(.success(try first.success(at: 1)), at: 1); first.lose(.unavailable)
        let state = try await client.state(); XCTAssertEqual(state.sessionID, second.sessionID)
        XCTAssertEqual(second.invalidationCount, 0); await client.invalidate()
    }

    func testTaskCancellationAndDeadlineInvalidateWithoutReplay() async throws {
        for timeout in [false, true] {
            let mock = MockTransport(); mock.hold([.state])
            let client = CompanionTransportClient(transportFactory: { mock }, testTimeoutNanoseconds: 80_000_000)
            _ = try await client.open(testConfiguration())
            let pending = Task { try await client.state() }; try await waitForRequests(mock, count: 2)
            if !timeout { pending.cancel() }
            await requireFailure({ try await pending.value }, timeout ? .timedOut : .cancelled)
            XCTAssertEqual(mock.requests.count, 2); XCTAssertEqual(mock.invalidationCount, 1)
            await requireFailure({ try await client.state() }, .notConnected)
        }
    }

    func testOpenTimeoutAndFactoryFailureDoNotLeaveUsableConnection() async throws {
        let held = MockTransport(); held.hold([.open])
        let client = CompanionTransportClient(transportFactory: { held }, testTimeoutNanoseconds: 30_000_000)
        await requireFailure({ try await client.open(testConfiguration()) }, .timedOut)
        XCTAssertEqual(held.invalidationCount, 1)
        await requireFailure({ try await client.state() }, .notConnected)
        let unavailable = CompanionTransportClient(transportFactory: { throw CompanionClientError.unavailable })
        await requireFailure({ try await unavailable.open(testConfiguration()) }, .unavailable)
        await requireFailure({ try await unavailable.state() }, .notConnected)
    }
}
