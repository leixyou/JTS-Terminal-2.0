import Foundation
import XCTest
@testable import JTSCompanionTransport

actor TestSocket: RelayWebSocketConnection {
    var incoming: [RelayWebSocketMessage]
    var sent: [Data] = []
    var closed = false
    init(_ incoming: [RelayWebSocketMessage]) { self.incoming = incoming }
    func receive() throws -> RelayWebSocketMessage {
        guard !incoming.isEmpty else { throw CompanionTransportError.connectionClosed }
        return incoming.removeFirst()
    }
    func sendBinary(_ bytes: Data) { sent.append(bytes) }
    func close() { closed = true }
}

final class CarrierTests: XCTestCase {
    func testReadyThenBoundedByteReads() async throws {
        let binding = try makeBinding()
        let ready = "{\"ready\":true,\"sessionId\":\"\(binding.sessionId)\",\"lane\":\"control\"}"
        let socket = TestSocket([.text(ready), .binary(Data([1, 2, 3, 4]))])
        let carrier = try await RelayWebSocketCarrier.acceptReady(connection: socket, sessionID: binding.sessionId, lane: .control)
        let first = try await carrier.read(maximumBytes: 2)
        let second = try await carrier.read(maximumBytes: 4)
        XCTAssertEqual(first, Data([1, 2]))
        XCTAssertEqual(second, Data([3, 4]))
        try await carrier.write(Data([5]))
        let sent = await socket.sent
        XCTAssertEqual(sent, [Data([5])])
    }

    func testWrongReadyClosesWithoutPayload() async throws {
        let socket = TestSocket([.text("{\"ready\":true,\"sessionId\":\"wrong\",\"lane\":\"control\"}")])
        do {
            _ = try await RelayWebSocketCarrier.acceptReady(connection: socket,
                sessionID: makeBinding().sessionId, lane: .control)
            XCTFail("accepted wrong session")
        } catch { XCTAssertEqual(error as? CompanionTransportError, .invalidReady) }
        let closed = await socket.closed
        let sent = await socket.sent
        XCTAssertTrue(closed)
        XCTAssertTrue(sent.isEmpty)
    }

    func testTextAfterReadinessFailsClosed() async throws {
        let binding = try makeBinding()
        let ready = "{\"ready\":true,\"sessionId\":\"\(binding.sessionId)\",\"lane\":\"control\"}"
        let socket = TestSocket([.text(ready), .text("plaintext-command")])
        let carrier = try await RelayWebSocketCarrier.acceptReady(connection: socket, sessionID: binding.sessionId, lane: .control)
        do { _ = try await carrier.read(maximumBytes: 1024); XCTFail("accepted text") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unexpectedText) }
        let closed = await socket.closed
        XCTAssertTrue(closed)
    }
}
