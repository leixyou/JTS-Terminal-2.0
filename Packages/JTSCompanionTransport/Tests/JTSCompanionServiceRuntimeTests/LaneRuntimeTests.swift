import Foundation
import XCTest
import JTSCompanionIPC
import JTSCompanionTransport
@testable import JTSCompanionServiceRuntime

final class LaneRuntimeTests: XCTestCase {
    private let connection = UUID()
    private let configuration = CompanionIPCOpen(privateKey: Data(repeating: 1, count: 32),
        peerSPKI: Data(repeating: 2, count: 91), relayURL: "https://relay.example")

    private func request<P: CompanionIPCPayload>(_ operation: CompanionIPCOperation, _ value: P,
                                                 connectionID: UUID? = nil) throws -> CompanionIPCRequest {
        CompanionIPCRequest(version: 2, id: UUID(), connectionID: connectionID ?? connection,
                            operation: operation, payload: try CompanionIPCCodec.encodePayload(value))
    }
    private func reply(_ runtime: CompanionLaneServiceRuntime, _ request: CompanionIPCRequest) async throws -> CompanionIPCReply {
        try CompanionIPCCodec.decodeReply(await runtime.handle(request))
    }
    private func open(_ runtime: CompanionLaneServiceRuntime) async throws {
        let result = try await reply(runtime, request(.openLane,
            CompanionIPCLaneOpen(configuration: configuration, lane: .rdp, grantID: UUID())))
        XCTAssertTrue(result.ok)
    }

    func testBlockedReadDoesNotBlockWriteAndKeepsBytesUnchanged() async throws {
        let entered = expectation(description: "read blocked")
        let stream = LaneSessionFixture(onRead: { entered.fulfill() })
        let runtime = CompanionLaneServiceRuntime(factory: { _ in stream })
        try await open(runtime)
        let input = try request(.readLane, CompanionIPCLaneRead(maximumBytes: 65536, sequence: 1))
        let pending = Task { await runtime.handle(input) }
        await fulfillment(of: [entered], timeout: 2)
        let bytes = Data((0..<65536).map { UInt8($0 % 256) })
        let write = try await reply(runtime, request(.writeLane, CompanionIPCLaneWrite(data: bytes, sequence: 1)))
        XCTAssertTrue(write.ok)
        let response = try CompanionIPCCodec.decodeReply(await pending.value)
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(XCTUnwrap(response.payload), as: CompanionIPCLaneBytes.self).data, bytes)
        await runtime.invalidate()
    }

    func testSequenceReplayAndWrongConnectionNeverTouchRemote() async throws {
        let stream = LaneSessionFixture(), runtime = CompanionLaneServiceRuntime(factory: { _ in LaneSessionFixture() })
        await runtime.invalidate()
        let active = CompanionLaneServiceRuntime(factory: { _ in stream })
        try await open(active)
        let write = try request(.writeLane, CompanionIPCLaneWrite(data: Data([1]), sequence: 1))
        let firstWrite = try await reply(active, write)
        XCTAssertTrue(firstWrite.ok)
        let repeated = try await reply(active, write)
        XCTAssertEqual(repeated.errorCode, "REQUEST_REPLAY_REJECTED")
        let wrong = try await reply(active, request(.writeLane, CompanionIPCLaneWrite(data: Data([2]), sequence: 2), connectionID: UUID()))
        XCTAssertEqual(wrong.errorCode, "CONNECTION_MISMATCH")
        let count = await stream.writeCount; XCTAssertEqual(count, 1)
        await active.invalidate()
    }

    func testExplicitCloseWakesPendingReadAndCannotReopen() async throws {
        let entered = expectation(description: "read blocked")
        let stream = LaneSessionFixture(onRead: { entered.fulfill() })
        let runtime = CompanionLaneServiceRuntime(factory: { _ in stream })
        try await open(runtime)
        let input = try request(.readLane, CompanionIPCLaneRead(maximumBytes: 1, sequence: 1))
        let pending = Task { await runtime.handle(input) }
        await fulfillment(of: [entered], timeout: 2)
        let close = try await reply(runtime, request(.closeLane, CompanionIPCEmpty()))
        XCTAssertTrue(close.ok)
        let read = try CompanionIPCCodec.decodeReply(await pending.value)
        XCTAssertFalse(read.ok)
        let reopen = try await reply(runtime, request(.openLane,
            CompanionIPCLaneOpen(configuration: configuration, lane: .rdp, grantID: UUID())))
        XCTAssertEqual(reopen.errorCode, "CONNECTION_ALREADY_OPENED")
        await runtime.invalidate()
    }

    func testHeartbeatFailureClosesIdleRead() async throws {
        let entered = expectation(description: "read blocked")
        let stream = LaneSessionFixture(heartbeatFailure: true, onRead: { entered.fulfill() })
        let runtime = CompanionLaneServiceRuntime(factory: { _ in stream }, heartbeatInterval: 50_000_000)
        try await open(runtime)
        let input = try request(.readLane, CompanionIPCLaneRead(maximumBytes: 1, sequence: 1))
        let pending = Task { await runtime.handle(input) }
        await fulfillment(of: [entered], timeout: 2)
        let result = try CompanionIPCCodec.decodeReply(await pending.value)
        XCTAssertFalse(result.ok)
        let closed = await stream.closed; XCTAssertTrue(closed)
        await runtime.invalidate()
    }

    func testRepeatedReadRejectedWithoutDisturbingFirstReader() async throws {
        let entered = expectation(description: "read blocked")
        let stream = LaneSessionFixture(onRead: { entered.fulfill() })
        let runtime = CompanionLaneServiceRuntime(factory: { _ in stream })
        try await open(runtime)
        let input = try request(.readLane, CompanionIPCLaneRead(maximumBytes: 1, sequence: 1))
        let pending = Task { await runtime.handle(input) }
        await fulfillment(of: [entered], timeout: 2)
        let overlap = try await reply(runtime, request(.readLane, CompanionIPCLaneRead(maximumBytes: 1, sequence: 2)))
        XCTAssertEqual(overlap.errorCode, "OPERATION_IN_PROGRESS")
        _ = try await reply(runtime, request(.writeLane, CompanionIPCLaneWrite(data: Data([5]), sequence: 1)))
        let response = try CompanionIPCCodec.decodeReply(await pending.value)
        XCTAssertTrue(response.ok)
        await runtime.invalidate()
    }
}

private actor LaneSessionFixture: CompanionLaneRuntimeSession {
    private let onRead: @Sendable () -> Void
    private let heartbeatFailure: Bool
    private var waiter: CheckedContinuation<Data, Error>?
    private(set) var writeCount = 0
    private(set) var closed = false
    init(heartbeatFailure: Bool = false, onRead: @escaping @Sendable () -> Void = {}) {
        self.heartbeatFailure = heartbeatFailure; self.onRead = onRead
    }
    func connect() throws -> CompanionIPCLaneState { CompanionIPCLaneState(lane: .rdp, sessionID: UUID()) }
    func heartbeat() throws { if heartbeatFailure { throw CompanionTransportError.connectionClosed } }
    func read(maximumBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { waiter = $0; onRead() }
    }
    func write(_ data: Data) { writeCount += 1; let current = waiter; waiter = nil; current?.resume(returning: data) }
    func close() { closed = true; let current = waiter; waiter = nil; current?.resume(throwing: CompanionTransportError.connectionClosed) }
}
