import Foundation
import XCTest
@testable import JTSCompanionTransport

final class ControlClientTests: XCTestCase {
    func testRemoteDenialDoesNotCloseOrReplay() async throws {
        let channel = try ControlReplyChannel(.denied)
        let client = try CompanionControlClient(channel: channel)
        for _ in 0..<2 {
            do { _ = try await client.status(grantID: UUID()); XCTFail("accepted") }
            catch { XCTAssertEqual(error as? CompanionControlError, .remote("CONTROL_GRANT_REJECTED")) }
        }
        let count = await channel.requests, closed = await channel.closed
        XCTAssertEqual(count, 2); XCTAssertFalse(closed)
        await client.close()
    }

    func testMalformedAndUncorrelatedRepliesCloseWithoutRetry() async throws {
        for mode in [ControlReplyChannel.Mode.correlation, .duplicate, .unknownResult, .oversized, .wrongType] {
            let channel = try ControlReplyChannel(mode)
            let client = try CompanionControlClient(channel: channel)
            do { _ = try await client.status(grantID: UUID()); XCTFail("invalid response accepted: \(mode)") }
            catch { XCTAssertFalse(error is CancellationError) }
            let closed = await channel.closed, count = await channel.requests
            XCTAssertTrue(closed); XCTAssertEqual(count, 1)
            do { _ = try await client.status(grantID: UUID()); XCTFail("closed client reused") }
            catch { XCTAssertEqual(error as? CompanionTransportError, .connectionClosed) }
        }
    }

    func testOutputOffsetsAndCanonicalDataAreChecked() async throws {
        let channel = try ControlReplyChannel(.invalidOutput)
        let client = try CompanionControlClient(channel: channel)
        do { _ = try await client.output(jobID: UUID(), grantID: UUID()); XCTFail("invalid output accepted") }
        catch { XCTAssertEqual(error as? CompanionControlError, .invalidResponse) }
        let closed = await channel.closed; XCTAssertTrue(closed)
    }

    func testInvalidLocalRequestsDoNotWriteAndOtherLanesAreRejected() async throws {
        let channel = try ControlReplyChannel(.valid)
        let client = try CompanionControlClient(channel: channel)
        do { _ = try await client.submit(jobID: UUID(), grantID: UUID(), kind: "powershell", deadline: Date(), payload: Data()); XCTFail("empty payload") }
        catch { XCTAssertEqual(error as? CompanionControlError, .invalidRequest) }
        do { _ = try await client.status(grantID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!); XCTFail("zero grant") }
        catch { XCTAssertEqual(error as? CompanionControlError, .invalidRequest) }
        do { _ = try await client.output(jobID: UUID(), grantID: UUID(), maximumBytes: 32769); XCTFail("large output") }
        catch { XCTAssertEqual(error as? CompanionControlError, .invalidRequest) }
        let count = await channel.requests; XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try CompanionControlClient(channel: ControlReplyChannel(.valid, lane: .file)))
        await client.close()
    }

    func testCancellationDrainsBlockedIOAndConcurrentRPCIsRejected() async throws {
        let reading = expectation(description: "response read blocked")
        let channel = try ControlReplyChannel(.blocked, onRead: { reading.fulfill() })
        let client = try CompanionControlClient(channel: channel)
        let operation = Task { try await client.status(grantID: UUID()) }
        await fulfillment(of: [reading], timeout: 2)
        do { _ = try await client.status(grantID: UUID()); XCTFail("overlapping RPC") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .operationInProgress) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("cancelled operation succeeded") } catch { }
        let closed = await channel.closed, count = await channel.requests
        XCTAssertTrue(closed); XCTAssertEqual(count, 1)
    }
}

private actor ControlReplyChannel: CompanionSecureChannel {
    enum Mode { case valid, denied, correlation, duplicate, unknownResult, oversized, wrongType, invalidOutput, blocked }
    nonisolated let binding: CompanionLaneBinding
    private let mode: Mode
    private let onRead: @Sendable () -> Void
    private var incoming = Data(), outgoing = Data()
    private var blockedRead: CheckedContinuation<Data, Error>?
    var closed = false
    var requests = 0

    init(_ mode: Mode, lane: RelayLane = .control, onRead: @escaping @Sendable () -> Void = {}) throws {
        self.mode = mode; self.onRead = onRead
        binding = try CompanionLaneBinding(sessionID: UUID().uuidString.lowercased(), lane: lane,
            controllerDeviceID: String(repeating: "a", count: 64), companionDeviceID: String(repeating: "b", count: 64))
    }
    func send(_ plaintext: Data) throws {
        guard !closed else { throw CompanionTransportError.connectionClosed }
        incoming += plaintext
        guard incoming.count >= 4 else { return }
        let size = incoming.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard incoming.count == size + 4 else { return }
        requests += 1
        let request = try JSONSerialization.jsonObject(with: incoming.dropFirst(4)) as! [String: Any]
        incoming.removeAll()
        guard mode != .blocked else { return }
        if mode == .oversized { outgoing = Data([255, 255, 255, 255]); return }
        var result: [String: Any] = ["capabilities": ["device.status"], "maximumPayloadBytes": 65536, "maximumOutputChunkBytes": 32768]
        if mode == .unknownResult { result["unexpected"] = true }
        if mode == .invalidOutput {
            let args = request["parameters"] as! [String: Any]
            result = ["jobId": args["jobId"]!, "offset": 0, "nextOffset": 7, "outputBytes": 1, "dataBase64": "AQ=="]
        }
        let reply: [String: Any] = ["version": mode == .wrongType ? "1" : 1,
            "id": mode == .correlation ? UUID().uuidString.lowercased() : request["id"]!,
            "ok": mode != .denied, "result": mode == .denied ? NSNull() : result,
            "errorCode": mode == .denied ? "CONTROL_GRANT_REJECTED" : NSNull()]
        var body = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        if mode == .duplicate { body.insert(contentsOf: Array("\"version\":1,".utf8), at: 1) }
        var length = UInt32(body.count).bigEndian
        outgoing = withUnsafeBytes(of: &length) { Data($0) } + body
    }
    func receive(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw CompanionTransportError.connectionClosed }
        if mode == .blocked {
            return try await withCheckedThrowingContinuation { continuation in
                blockedRead = continuation; onRead()
            }
        }
        guard !outgoing.isEmpty else { throw CompanionTransportError.connectionClosed }
        let result = Data(outgoing.prefix(min(maximumBytes, 7))) // Deliberately fragment even the header.
        outgoing.removeFirst(result.count); return result
    }
    func close() {
        closed = true; blockedRead?.resume(throwing: CompanionTransportError.connectionClosed); blockedRead = nil
    }
}
