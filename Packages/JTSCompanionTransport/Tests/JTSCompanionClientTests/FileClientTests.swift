import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionClient

final class FileClientTests: XCTestCase {
    func testFragmentedReadChecksBytesHashAndGrant() async throws {
        let grant = UUID(), lane = FileReplyStream(.valid)
        let client = CompanionFileClient(lane: lane, grantID: grant)
        let result = try await client.request(.read, parametersJSON: readParameters)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(value["dataBase64"] as? String, Data([1, 2, 3]).base64EncodedString())
        let requests = await lane.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["grantId"] as? String, grant.uuidString.lowercased())
        XCTAssertEqual(requests.first?["operation"] as? String, "file.read")
        await client.close()
    }

    func testBadCorrelationIntegrityOffsetsAndFramesCloseWithoutRetry() async throws {
        for mode in [FileReplyStream.Mode.badHash, .badOffset, .badBase64, .wrongID, .duplicate, .oversized] {
            let lane = FileReplyStream(mode)
            let observed = CompanionFileClient(lane: lane, grantID: UUID())
            do { _ = try await observed.request(.read, parametersJSON: readParameters); XCTFail("accepted \(mode)") }
            catch { XCTAssertFalse(error is CancellationError) }
            let closed = await lane.closed, count = await lane.requests.count
            XCTAssertTrue(closed); XCTAssertEqual(count, 1)
            do { _ = try await observed.request(.roots, parametersJSON: Data("{}".utf8)); XCTFail("reused") }
            catch { XCTAssertEqual(error as? CompanionClientError, .notConnected) }
        }
    }

    func testRemoteDenialIsSanitizedAndDoesNotCloseOrRetry() async throws {
        let lane = FileReplyStream(.denied), grant = UUID()
        let client = CompanionFileClient(lane: lane, grantID: grant)
        for _ in 0..<2 {
            do { _ = try await client.request(.read, parametersJSON: readParameters); XCTFail("accepted") }
            catch { XCTAssertEqual(error as? CompanionClientError, .remote("FILE_ACCESS_DENIED")) }
        }
        let closed = await lane.closed, count = await lane.requests.count
        XCTAssertFalse(closed); XCTAssertEqual(count, 2)
        await client.close()
    }

    func testLocalBoundsRejectBeforeWritingAndAcceptExactLimits() async throws {
        let lane = FileReplyStream(.valid)
        let observed = CompanionFileClient(lane: lane, grantID: UUID())
        for parameters in [
            ["rootId": "shared", "path": ".", "offset": 0, "limit": 101],
            ["rootId": "shared", "path": ".", "offset": 10_001, "limit": 100],
            ["rootId": "shared", "path": String(repeating: "a", count: 1025), "offset": 0, "limit": 1],
            ["rootId": "shared", "path": ".", "offset": false, "limit": 1]
        ] as [[String: Any]] {
            do { _ = try await observed.request(.list, parametersJSON: JSONSerialization.data(withJSONObject: parameters)); XCTFail("accepted") }
            catch { XCTAssertEqual(error as? CompanionClientError, .invalidRequest) }
        }
        let boundary = try JSONSerialization.data(withJSONObject: ["rootId": "shared", "path": String(repeating: "a", count: 1024), "offset": 10_000, "limit": 100])
        XCTAssertNoThrow(try CompanionFileContract.parameters(.list, bytes: boundary))
        let count = await lane.requests.count; XCTAssertEqual(count, 0)
        await observed.close()
    }

    func testCancellationWakesBlockedReadAndRejectsOverlappingRPC() async throws {
        let reading = expectation(description: "reading")
        let lane = FileReplyStream(.blocked, onRead: { reading.fulfill() })
        let client = CompanionFileClient(lane: lane, grantID: UUID())
        let pending = Task { try await client.request(.read, parametersJSON: readParameters) }
        await fulfillment(of: [reading], timeout: 2)
        do { _ = try await client.request(.read, parametersJSON: readParameters); XCTFail("overlap") }
        catch { XCTAssertEqual(error as? CompanionClientError, .busy) }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("cancelled") } catch { }
        let closed = await lane.closed; XCTAssertTrue(closed)
    }

    private var readParameters: Data { Data(#"{"rootId":"shared","path":"probe.bin","offset":0,"maximumBytes":32768}"#.utf8) }
}

private actor FileReplyStream: CompanionLaneByteStream {
    enum Mode { case valid, denied, badHash, badOffset, badBase64, wrongID, duplicate, oversized, blocked }
    let mode: Mode
    let onRead: @Sendable () -> Void
    private var incoming = Data(), outgoing = Data()
    private var pending: CheckedContinuation<Data, Error>?
    var requests: [[String: Any]] = []
    var closed = false
    init(_ mode: Mode, onRead: @escaping @Sendable () -> Void = {}) { self.mode = mode; self.onRead = onRead }
    func write(_ bytes: Data) throws {
        incoming.append(bytes)
        guard incoming.count >= 4 else { return }
        let size = incoming.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard incoming.count == size + 4 else { return }
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: incoming.dropFirst(4)) as? [String: Any])
        requests.append(request); incoming.removeAll()
        if mode == .blocked { return }
        if mode == .oversized { outgoing = Data([255, 255, 255, 255]); return }
        let payload = Data([1, 2, 3])
        let result: [String: Any] = ["dataBase64": mode == .badBase64 ? "AQID\n" : payload.base64EncodedString(),
            "nextOffset": mode == .badOffset ? 4 : 3, "size": 3, "eof": true,
            "sha256": mode == .badHash ? String(repeating: "0", count: 64) : SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()]
        let reply: [String: Any] = ["version": 1, "id": mode == .wrongID ? UUID().uuidString.lowercased() : request["id"]!,
            "ok": mode != .denied, "result": mode == .denied ? NSNull() : result,
            "errorCode": mode == .denied ? "FILE_ACCESS_DENIED" : NSNull()]
        var body = try JSONSerialization.data(withJSONObject: reply)
        if mode == .duplicate { body.insert(contentsOf: Array("\"version\":1,".utf8), at: 1) }
        var length = UInt32(body.count).bigEndian
        outgoing = withUnsafeBytes(of: &length) { Data($0) } + body
    }
    func read(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw CompanionClientError.notConnected }
        if mode == .blocked { return try await withCheckedThrowingContinuation { pending = $0; onRead() } }
        let bytes = Data(outgoing.prefix(min(7, maximumBytes))); outgoing.removeFirst(bytes.count); return bytes
    }
    func close() { closed = true; pending?.resume(throwing: CompanionClientError.notConnected); pending = nil }
}
