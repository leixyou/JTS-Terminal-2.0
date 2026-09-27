import Foundation
import XCTest
import JTSCompanionIPC
@testable import JTSCompanionClient

final class MockTransport: CompanionIPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: (@Sendable (CompanionClientError) -> Void)?
    private var calls: [(CompanionIPCRequest, @Sendable (Result<Data, CompanionClientError>) -> Void)] = []
    private var held: Set<CompanionIPCOperation> = []
    private var starts = 0, invalidations = 0
    let sessionID = UUID().uuidString.lowercased()

    var startCount: Int { locked { starts } }
    var invalidationCount: Int { locked { invalidations } }
    var requests: [CompanionIPCRequest] { locked { calls.map(\.0) } }
    func hold(_ operations: Set<CompanionIPCOperation>) { locked { held = operations } }
    func start(onFailure: @escaping @Sendable (CompanionClientError) -> Void) throws {
        locked { starts += 1; failures = onFailure }
    }
    func send(_ request: Data, reply: @escaping @Sendable (Result<Data, CompanionClientError>) -> Void) {
        do {
            let decoded = try CompanionIPCCodec.decodeRequest(request)
            let shouldHold = locked { calls.append((decoded, reply)); return held.contains(decoded.operation) }
            if !shouldHold { reply(.success(try success(decoded))) }
        } catch { reply(.failure(.invalidReply)) }
    }
    func invalidate() { locked { invalidations += 1 } }
    func lose(_ error: CompanionClientError = .interrupted) { locked { failures }?(error) }
    func deliver(_ result: Result<Data, CompanionClientError>, at index: Int) { locked { calls[index].1 }(result) }
    func success(at index: Int, id: UUID? = nil, connectionID: UUID? = nil, payload: Data? = nil) throws -> Data {
        try success(locked { calls[index].0 }, id: id, connectionID: connectionID, payload: payload)
    }
    private func success(_ request: CompanionIPCRequest, id: UUID? = nil, connectionID: UUID? = nil, payload: Data? = nil) throws -> Data {
        let body: Data
        if let payload { body = payload }
        else if request.operation == .openLane {
            let open = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCLaneOpen.self)
            body = try CompanionIPCCodec.encodePayload(CompanionIPCLaneState(lane: open.lane, sessionID: UUID(uuidString: sessionID)!))
        } else if request.operation == .readLane { body = try CompanionIPCCodec.encodePayload(CompanionIPCLaneBytes(Data([42]))) }
        else if request.operation == .writeLane { body = try CompanionIPCCodec.encodePayload(CompanionIPCEmpty()) }
        else { body = try CompanionIPCCodec.encodePayload(CompanionIPCState(phase: "connected", sessionID: sessionID)) }
        return try CompanionIPCCodec.encodeReply(CompanionIPCReply(version: request.version, id: id ?? request.id, connectionID: connectionID ?? request.connectionID,
            ok: true, payload: body, errorCode: nil))
    }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
}

final class MockFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let mocks: [MockTransport]
    private var next = 0
    init(_ mocks: MockTransport...) { self.mocks = mocks }
    var count: Int { lock.lock(); defer { lock.unlock() }; return next }
    func make() throws -> any CompanionIPCTransport {
        lock.lock(); defer { lock.unlock() }
        guard next < mocks.count else { throw CompanionClientError.unavailable }
        defer { next += 1 }; return mocks[next]
    }
}

func testConfiguration() -> CompanionIPCOpen {
    CompanionIPCOpen(privateKey: Data(repeating: 1, count: 32), peerSPKI: Data([1]), relayURL: "https://relay.example")
}

func waitForRequests(_ transport: MockTransport, count: Int) async throws {
    for _ in 0..<2000 {
        if transport.requests.count >= count { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Mock request did not arrive"); throw CompanionClientError.timedOut
}

func requireFailure<T>(_ operation: @Sendable () async throws -> T, _ expected: CompanionClientError,
                       file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await operation(); XCTFail("Expected client failure", file: file, line: line) }
    catch { XCTAssertEqual(error as? CompanionClientError, expected, file: file, line: line) }
}
