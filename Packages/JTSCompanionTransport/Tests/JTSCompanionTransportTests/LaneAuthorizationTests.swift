import Foundation
import XCTest
@testable import JTSCompanionTransport

final class LaneAuthorizationTests: XCTestCase {
    func testEachLaneChecksItsGrantWithoutConsumingFollowingStreamBytes() async throws {
        for lane in [RelayLane.file, .rdp] {
            let channel = try LaneOpeningChannel(.valid, lane: lane), grant = UUID()
            try await CompanionLaneAuthorization.authorize(channel: channel, grantID: grant)
            let receivedOperation = await channel.operation, receivedGrant = await channel.grant
            XCTAssertEqual(receivedOperation, lane.rawValue + ".open")
            XCTAssertEqual(receivedGrant, grant.uuidString.lowercased())
            let tail = try await channel.receive(maximumBytes: 1)
            XCTAssertEqual(tail, Data([0x03]))
            let closed = await channel.closed; XCTAssertFalse(closed)
            await channel.close()
        }
    }

    func testDenialMalformedCorrelationAndUnreadyPeerFailClosed() async throws {
        for mode in [LaneOpeningChannel.Mode.denied, .wrongID, .duplicate, .extraResult, .notReady, .oversized] {
            let channel = try LaneOpeningChannel(mode)
            do { try await CompanionLaneAuthorization.authorize(channel: channel, grantID: UUID()); XCTFail("accepted \(mode)") }
            catch {
                if mode == .denied { XCTAssertEqual(error as? CompanionControlError, .remote("LANE_GRANT_REQUIRED")) }
            }
            let closed = await channel.closed, count = await channel.requests
            XCTAssertTrue(closed); XCTAssertEqual(count, 1)
        }
    }

    func testControlAndEmptyGrantAreRejectedWithoutSending() async throws {
        let control = try LaneOpeningChannel(.valid, lane: .control)
        do { try await CompanionLaneAuthorization.authorize(channel: control, grantID: UUID()); XCTFail("control") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unsupportedLane) }
        let file = try LaneOpeningChannel(.valid, lane: .file)
        do {
            try await CompanionLaneAuthorization.authorize(channel: file,
                grantID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
            XCTFail("empty grant")
        } catch { XCTAssertEqual(error as? CompanionControlError, .invalidRequest) }
        let count = await control.requests + file.requests; XCTAssertEqual(count, 0)
    }

    func testCancellationClosesAndWakesPendingAuthorization() async throws {
        let reading = expectation(description: "authorization response blocked")
        let channel = try LaneOpeningChannel(.blocked, onRead: { reading.fulfill() })
        let operation = Task { try await CompanionLaneAuthorization.authorize(channel: channel, grantID: UUID()) }
        await fulfillment(of: [reading], timeout: 2)
        operation.cancel()
        do { try await operation.value; XCTFail("cancelled") } catch { }
        let closed = await channel.closed; XCTAssertTrue(closed)
    }
}

private actor LaneOpeningChannel: CompanionSecureChannel {
    enum Mode { case valid, denied, wrongID, duplicate, extraResult, notReady, oversized, blocked }
    nonisolated let binding: CompanionLaneBinding
    private let mode: Mode
    private let onRead: @Sendable () -> Void
    private var outgoing = Data()
    private var pending: CheckedContinuation<Data, Error>?
    var closed = false
    var requests = 0
    var operation: String?
    var grant: String?

    init(_ mode: Mode, lane: RelayLane = .rdp, onRead: @escaping @Sendable () -> Void = {}) throws {
        self.mode = mode; self.onRead = onRead
        binding = try CompanionLaneBinding(sessionID: UUID().uuidString.lowercased(), lane: lane,
            controllerDeviceID: String(repeating: "a", count: 64), companionDeviceID: String(repeating: "b", count: 64))
    }
    func send(_ bytes: Data) throws {
        requests += 1
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes.dropFirst(4)) as? [String: Any])
        operation = request["operation"] as? String; grant = request["grantId"] as? String
        if mode == .blocked { return }
        if mode == .oversized { outgoing = Data([255, 255, 255, 255]); return }
        var result: [String: Any] = ["ready": mode != .notReady]
        if mode == .extraResult { result["unexpected"] = true }
        let reply: [String: Any] = ["version": 1, "id": mode == .wrongID ? UUID().uuidString.lowercased() : request["id"]!,
            "ok": mode != .denied, "result": mode == .denied ? NSNull() : result,
            "errorCode": mode == .denied ? "LANE_GRANT_REQUIRED" : NSNull()]
        var body = try JSONSerialization.data(withJSONObject: reply)
        if mode == .duplicate { body.insert(contentsOf: Array("\"version\":1,".utf8), at: 1) }
        var size = UInt32(body.count).bigEndian
        outgoing = withUnsafeBytes(of: &size) { Data($0) } + body + Data([0x03])
    }
    func receive(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw CompanionTransportError.connectionClosed }
        if mode == .blocked { return try await withCheckedThrowingContinuation { pending = $0; onRead() } }
        let bytes = Data(outgoing.prefix(min(3, maximumBytes))); outgoing.removeFirst(bytes.count); return bytes
    }
    func close() { closed = true; pending?.resume(throwing: CompanionTransportError.connectionClosed); pending = nil }
}
