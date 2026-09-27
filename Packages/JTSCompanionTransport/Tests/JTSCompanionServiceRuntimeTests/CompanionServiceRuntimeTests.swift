import Foundation
import XCTest
import JTSCompanionIPC
import JTSCompanionTransport
@testable import JTSCompanionServiceRuntime

final class CompanionServiceRuntimeTests: XCTestCase {
    private let connection = UUID()
    private let configuration = CompanionIPCOpen(privateKey: Data(repeating: 1, count: 32),
        peerSPKI: Data(repeating: 2, count: 91), relayURL: "https://relay.example")

    private func request<P: CompanionIPCPayload>(_ op: CompanionIPCOperation, _ body: P, id: UUID = UUID(),
                                                connectionID: UUID? = nil) throws -> Data {
        try CompanionIPCCodec.encodeRequest(CompanionIPCRequest(id: id, connectionID: connectionID ?? connection,
            operation: op, payload: CompanionIPCCodec.encodePayload(body)))
    }

    private func reply(_ runtime: CompanionServiceRuntime, _ request: Data) async throws -> CompanionIPCReply {
        try CompanionIPCCodec.decodeReply(await runtime.handle(request))
    }

    func testOpenThenExplicitControlAndCloseHaveNoDesktopDependency() async throws {
        let session = RuntimeFixture()
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        let opened = try await reply(runtime, request(.open, configuration))
        XCTAssertTrue(opened.ok)
        let state = try CompanionIPCCodec.decodePayload(XCTUnwrap(opened.payload), as: CompanionIPCState.self)
        XCTAssertEqual(state.phase, "connected")
        let result = try await reply(runtime, request(.status, CompanionIPCGrant(grantID: UUID())))
        XCTAssertTrue(result.ok)
        let closed = try await reply(runtime, request(.close, CompanionIPCEmpty()))
        XCTAssertTrue(closed.ok)
        let facts = await session.facts()
        XCTAssertEqual(facts.connects, 1); XCTAssertEqual(facts.commands, 1); XCTAssertTrue(facts.closed)
        let reopening = try await reply(runtime, request(.open, configuration))
        XCTAssertEqual(reopening.errorCode, "CONNECTION_ALREADY_OPENED")
        await runtime.invalidate()
    }

    func testUnopenedControlDoesNotExecute() async throws {
        let session = RuntimeFixture()
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        let result = try await reply(runtime, request(.status, CompanionIPCGrant(grantID: UUID())))
        XCTAssertEqual(result.errorCode, "NOT_CONNECTED")
        let facts = await session.facts(); XCTAssertEqual(facts.commands, 0)
        await runtime.invalidate()
    }

    func testRequestReplayDoesNotRepeatRemoteOperation() async throws {
        let session = RuntimeFixture()
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        _ = try await reply(runtime, request(.open, configuration))
        let command = try request(.status, CompanionIPCGrant(grantID: UUID()))
        _ = try await reply(runtime, command)
        let repeated = try await reply(runtime, command)
        XCTAssertEqual(repeated.errorCode, "REQUEST_REPLAY_REJECTED")
        let facts = await session.facts(); XCTAssertEqual(facts.commands, 1)
        await runtime.invalidate()
    }

    func testWrongConnectionCannotUseOrCloseRoute() async throws {
        let session = RuntimeFixture()
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        _ = try await reply(runtime, request(.open, configuration))
        let result = try await reply(runtime, request(.close, CompanionIPCEmpty(), connectionID: UUID()))
        XCTAssertEqual(result.errorCode, "CONNECTION_MISMATCH")
        let facts = await session.facts(); XCTAssertFalse(facts.closed)
        await runtime.invalidate()
    }

    func testInvalidOperationBodyIsRejectedBeforeRemoteCall() async throws {
        let session = RuntimeFixture()
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        _ = try await reply(runtime, request(.open, configuration))
        let result = try await reply(runtime, request(.submit, CompanionIPCEmpty()))
        XCTAssertFalse(result.ok)
        let facts = await session.facts(); XCTAssertEqual(facts.commands, 0); XCTAssertFalse(facts.closed)
        await runtime.invalidate()
    }

    func testRemoteDenialLeavesConnectionButNeverRetries() async throws {
        let session = RuntimeFixture(.remoteDenied)
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        _ = try await reply(runtime, request(.open, configuration))
        let result = try await reply(runtime, request(.status, CompanionIPCGrant(grantID: UUID())))
        XCTAssertEqual(result.errorCode, "REMOTE_CONTROL_GRANT_REJECTED")
        let facts = await session.facts(); XCTAssertEqual(facts.commands, 1); XCTAssertFalse(facts.closed)
        await runtime.invalidate()
    }

    func testTransportFailureClosesAndSanitizesWithoutReplay() async throws {
        let session = RuntimeFixture(.transportFailed)
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        _ = try await reply(runtime, request(.open, configuration))
        let result = try await reply(runtime, request(.status, CompanionIPCGrant(grantID: UUID())))
        XCTAssertEqual(result.errorCode, "REQUEST_FAILED")
        XCTAssertFalse(String(decoding: try CompanionIPCCodec.encodeReply(result), as: UTF8.self).contains("secret"))
        let state = try await reply(runtime, request(.state, CompanionIPCEmpty()))
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(XCTUnwrap(state.payload), as: CompanionIPCState.self).phase, "failed")
        let facts = await session.facts(); XCTAssertEqual(facts.commands, 1); XCTAssertTrue(facts.closed)
        await runtime.invalidate()
    }

    func testInvalidationDuringConnectCannotResurrectSession() async throws {
        let started = expectation(description: "connect entered")
        let session = RuntimeFixture(.blockedConnect, onWait: { started.fulfill() })
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        let bytes = try request(.open, configuration)
        let opening = Task { await runtime.handle(bytes) }
        await fulfillment(of: [started], timeout: 2)
        await runtime.invalidate()
        let output = await opening.value
        XCTAssertTrue(output.isEmpty || (try? CompanionIPCCodec.decodeReply(output).ok) == false)
        let after = await runtime.handle(try request(.state, CompanionIPCEmpty()))
        XCTAssertTrue(after.isEmpty)
        let facts = await session.facts(); XCTAssertTrue(facts.closed)
    }

    func testOpenDeadlineClosesBlockedTransport() async throws {
        let session = RuntimeFixture(.blockedConnect)
        let runtime = CompanionServiceRuntime(factory: { _ in session }, openTimeout: 10_000_000)
        let result = try await reply(runtime, request(.open, configuration))
        XCTAssertFalse(result.ok)
        let facts = await session.facts(); XCTAssertTrue(facts.closed); XCTAssertEqual(facts.connects, 1)
        await runtime.invalidate()
    }

    func testExplicitCloseCancelsPendingOpenAndCannotBecomeConnected() async throws {
        let started = expectation(description: "connect entered")
        let session = RuntimeFixture(.blockedConnect, onWait: { started.fulfill() })
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        let bytes = try request(.open, configuration)
        let opening = Task { await runtime.handle(bytes) }
        await fulfillment(of: [started], timeout: 2)
        let close = try await reply(runtime, request(.close, CompanionIPCEmpty()))
        XCTAssertTrue(close.ok)
        let previous = try CompanionIPCCodec.decodeReply(await opening.value)
        XCTAssertFalse(previous.ok)
        let result = try await reply(runtime, request(.state, CompanionIPCEmpty()))
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(XCTUnwrap(result.payload), as: CompanionIPCState.self).phase, "disconnected")
        await runtime.invalidate()
    }

    func testOverlappingRPCIsRejectedAndInvalidationDrainsIO() async throws {
        let reading = expectation(description: "request entered")
        let session = RuntimeFixture(.blockedCommand, onWait: { reading.fulfill() })
        let runtime = CompanionServiceRuntime(factory: { _ in session })
        _ = try await reply(runtime, request(.open, configuration))
        let command = try request(.status, CompanionIPCGrant(grantID: UUID()))
        let pending = Task { await runtime.handle(command) }
        await fulfillment(of: [reading], timeout: 2)
        let overlapping = try await reply(runtime, request(.status, CompanionIPCGrant(grantID: UUID())))
        XCTAssertEqual(overlapping.errorCode, "OPERATION_IN_PROGRESS")
        await runtime.invalidate()
        _ = await pending.value
        let facts = await session.facts(); XCTAssertEqual(facts.commands, 1); XCTAssertTrue(facts.closed)
    }

    func testPresenceFailureClosesAuthenticatedRoute() async throws {
        let closed = expectation(description: "route closed on lost presence")
        let session = RuntimeFixture(.heartbeatFailed, onClose: { closed.fulfill() })
        let runtime = CompanionServiceRuntime(factory: { _ in session }, heartbeatInterval: 1_000_000)
        _ = try await reply(runtime, request(.open, configuration))
        await fulfillment(of: [closed], timeout: 2)
        let result = try await reply(runtime, request(.state, CompanionIPCEmpty()))
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(XCTUnwrap(result.payload), as: CompanionIPCState.self).phase, "failed")
        await runtime.invalidate()
    }

    func testMalformedFrameDoesNotCreateRoute() async {
        let runtime = CompanionServiceRuntime(factory: { _ in XCTFail("factory invoked"); return RuntimeFixture() })
        let result = await runtime.handle(Data("{}".utf8))
        XCTAssertTrue(result.isEmpty)
        await runtime.invalidate()
    }

    func testProductionFactoryRejectsInvalidPinnedIdentityBeforeNetwork() throws {
        XCTAssertThrowsError(try PinnedCompanionRuntimeSession(configuration))
    }
}

private actor RuntimeFixture: CompanionRuntimeSession {
    enum Mode { case normal, remoteDenied, transportFailed, blockedConnect, blockedCommand, heartbeatFailed }
    struct Facts { let connects, commands: Int; let closed: Bool }
    private let mode: Mode
    private let onWait, onClose: @Sendable () -> Void
    private var waiter: CheckedContinuation<Void, Error>?
    private var connects = 0, commands = 0
    private var closed = false

    init(_ mode: Mode = .normal, onWait: @escaping @Sendable () -> Void = {}, onClose: @escaping @Sendable () -> Void = {}) {
        self.mode = mode; self.onWait = onWait; self.onClose = onClose
    }
    func connect() async throws -> String {
        connects += 1
        if mode == .blockedConnect { try await wait() }
        guard !closed else { throw CompanionTransportError.connectionClosed }
        return UUID().uuidString.lowercased()
    }
    func heartbeat() throws {
        if mode == .heartbeatFailed { throw CompanionTransportError.connectionClosed }
    }
    func execute(_ request: CompanionIPCRequest) async throws -> Data {
        commands += 1
        if mode == .remoteDenied { throw CompanionControlError.remote("CONTROL_GRANT_REJECTED") }
        if mode == .transportFailed { throw NSError(domain: "secret-path-password", code: 123) }
        if mode == .blockedCommand { try await wait() }
        return Data("{}".utf8)
    }
    func close() {
        if !closed { onClose() }
        closed = true
        let pending = waiter; waiter = nil
        pending?.resume(throwing: CompanionTransportError.connectionClosed)
    }
    private func wait() async throws {
        try await withCheckedThrowingContinuation { waiter = $0; onWait() }
    }
    func facts() -> Facts { Facts(connects: connects, commands: commands, closed: closed) }
}
