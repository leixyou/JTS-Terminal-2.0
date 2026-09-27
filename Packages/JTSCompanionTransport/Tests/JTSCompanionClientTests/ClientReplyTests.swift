import Foundation
import XCTest
import JTSCompanionIPC
@testable import JTSCompanionClient

final class ClientReplyTests: XCTestCase {
    func testWrongCorrelationMalformedAndEmptyRepliesInvalidate() async throws {
        for mode in ["id", "connection", "malformed", "empty", "oversized", "typed"] {
            let mock = MockTransport(); mock.hold([.state])
            let client = CompanionTransportClient(transportFactory: { mock })
            _ = try await client.open(testConfiguration())
            let pending = Task { try await client.state() }; try await waitForRequests(mock, count: 2)
            let frame: Data
            switch mode {
            case "id": frame = try mock.success(at: 1, id: UUID())
            case "connection": frame = try mock.success(at: 1, connectionID: UUID())
            case "malformed": frame = Data("not-json".utf8)
            case "empty": frame = Data()
            case "oversized": frame = Data(repeating: 32, count: CompanionIPCLimits.frameBytes + 1)
            default: frame = try mock.success(at: 1, payload: Data("{\"phase\":\"connected\"}".utf8))
            }
            mock.deliver(.success(frame), at: 1)
            await requireFailure({ try await pending.value }, .invalidReply)
            XCTAssertEqual(mock.invalidationCount, 1)
            await requireFailure({ try await client.state() }, .notConnected)
        }
    }

    func testRemoteBusinessDenialPreservesConnectionWithoutReplay() async throws {
        let mock = MockTransport(); mock.hold([.state])
        let client = CompanionTransportClient(transportFactory: { mock })
        _ = try await client.open(testConfiguration())
        let pending = Task { try await client.state() }; try await waitForRequests(mock, count: 2)
        let request = mock.requests[1]
        let rejected = try CompanionIPCCodec.encodeReply(CompanionIPCReply(id: request.id, connectionID: request.connectionID,
            ok: false, payload: nil, errorCode: "REMOTE_GRANT_REVOKED"))
        mock.deliver(.success(rejected), at: 1)
        await requireFailure({ try await pending.value }, .remote("REMOTE_GRANT_REVOKED"))
        XCTAssertEqual(mock.requests.count, 2); XCTAssertEqual(mock.invalidationCount, 0)
        mock.hold([])
        let state = try await client.state(); XCTAssertEqual(state.phase, "connected")
        XCTAssertEqual(mock.requests.count, 3); await client.invalidate()
    }

    func testLocalServiceFailureTerminatesGeneration() async throws {
        let mock = MockTransport(); mock.hold([.state])
        let client = CompanionTransportClient(transportFactory: { mock })
        _ = try await client.open(testConfiguration())
        let pending = Task { try await client.state() }; try await waitForRequests(mock, count: 2)
        let request = mock.requests[1]
        let rejected = try CompanionIPCCodec.encodeReply(CompanionIPCReply(id: request.id, connectionID: request.connectionID,
            ok: false, payload: nil, errorCode: "CHANNEL_FAILED"))
        mock.deliver(.success(rejected), at: 1)
        await requireFailure({ try await pending.value }, .remote("CHANNEL_FAILED"))
        XCTAssertEqual(mock.invalidationCount, 1)
        await requireFailure({ try await client.state() }, .notConnected)
    }

    func testInvalidLocalPayloadDoesNotSendOrDestroyWorkingConnection() async throws {
        let mock = MockTransport(); let client = CompanionTransportClient(transportFactory: { mock })
        _ = try await client.open(testConfiguration())
        for payload in [Data("[]".utf8), Data("{\"x\":1,\"x\":2}".utf8), Data(repeating: 0, count: 96 * 1024 + 1)] {
            await requireFailure({ try await client.invoke(operation: .state, payload: payload) }, .invalidRequest)
        }
        await requireFailure({ try await client.invoke(operation: .open, payload: Data("{}".utf8)) }, .invalidRequest)
        XCTAssertEqual(mock.requests.count, 1); XCTAssertEqual(mock.invalidationCount, 0)
        _ = try await client.state(); await client.invalidate()
    }

    func testDuplicateOldCallbackCannotCompleteNextRequest() async throws {
        let mock = MockTransport(); mock.hold([.state])
        let client = CompanionTransportClient(transportFactory: { mock })
        _ = try await client.open(testConfiguration())
        let first = Task { try await client.state() }; try await waitForRequests(mock, count: 2)
        let oldReply = try mock.success(at: 1); mock.deliver(.success(oldReply), at: 1); _ = try await first.value
        let second = Task { try await client.state() }; try await waitForRequests(mock, count: 3)
        mock.deliver(.success(oldReply), at: 1)
        mock.deliver(.success(try mock.success(at: 2)), at: 2)
        let state = try await second.value; XCTAssertEqual(state.sessionID, mock.sessionID)
        XCTAssertEqual(mock.invalidationCount, 0); await client.invalidate()
    }
}
