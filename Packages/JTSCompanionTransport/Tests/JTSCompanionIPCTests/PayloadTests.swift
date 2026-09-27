import Foundation
import XCTest
import JTSCompanionIPC

final class PayloadTests: XCTestCase {
    private let grant = UUID(), job = UUID()
    private let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    func testOpenRoundTripRedactsKeyAndRelay() throws {
        let open = CompanionIPCOpen(privateKey: Data(repeating: 123, count: 32), peerSPKI: Data([1, 2, 3]),
            relayURL: "https://private.example:8443", allowWindows10TLS12: true)
        let result = try CompanionIPCCodec.decodePayload(CompanionIPCCodec.encodePayload(open), as: CompanionIPCOpen.self)
        XCTAssertEqual(result.privateKey, open.privateKey); XCTAssertTrue(result.allowWindows10TLS12)
        for description in [String(describing: open), String(reflecting: open)] {
            XCTAssertFalse(description.contains("private.example")); XCTAssertFalse(description.contains(open.privateKey.base64EncodedString()))
        }
    }
    func testUnsafeOriginsAndKeyShapeRejected() {
        for origin in ["http://relay.example", "https://user:pass@relay.example", "https://relay.example/path",
                       "https://relay.example?q=1", "https://relay.example/#a", "https://relay.example\\evil", "https://relay.example:0"] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(CompanionIPCOpen(privateKey: Data(repeating: 1, count: 32),
                peerSPKI: Data([1]), relayURL: origin)))
        }
        for count in [0, 31, 33, 4096] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(CompanionIPCOpen(privateKey: Data(repeating: 1, count: count),
                peerSPKI: Data([1]), relayURL: "https://relay.example")))
        }
    }
    func testStateEncodesNullAndChecksSessionBinding() throws {
        let bytes = try CompanionIPCCodec.encodePayload(CompanionIPCState(phase: "disconnected"))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\"sessionID\":null"))
        let connected = CompanionIPCState(phase: "connected", sessionID: UUID().uuidString.lowercased())
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(CompanionIPCCodec.encodePayload(connected), as: CompanionIPCState.self), connected)
        for value in [CompanionIPCState(phase: "connected"), CompanionIPCState(phase: "rdp"),
                      CompanionIPCState(phase: "failed", sessionID: UUID().uuidString), CompanionIPCState(phase: "connected", sessionID: zero.uuidString)] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(value))
        }
    }
    func testGrantJobOutputAndSubmitBounds() throws {
        XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(CompanionIPCGrant(grantID: zero)))
        XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(CompanionIPCJob(grantID: grant, jobID: zero)))
        for value in [CompanionIPCOutput(grantID: grant, jobID: job, offset: -1),
                      CompanionIPCOutput(grantID: grant, jobID: job, offset: 1_048_577),
                      CompanionIPCOutput(grantID: grant, jobID: job, maximumBytes: 0),
                      CompanionIPCOutput(grantID: grant, jobID: job, maximumBytes: 32769)] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(value))
        }
        let submit = CompanionIPCSubmit(grantID: grant, jobID: job, kind: "powershell.v1", deadlineUnixMilliseconds: 10,
            allowDisconnected: true, payload: Data(repeating: 42, count: 65536))
        XCTAssertLessThanOrEqual(try CompanionIPCCodec.encodePayload(submit).count, CompanionIPCLimits.payloadBytes)
        XCTAssertFalse(String(reflecting: submit).contains(submit.payload.base64EncodedString()))
        for kind in ["", "bad kind", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(CompanionIPCSubmit(grantID: grant, jobID: job,
                kind: kind, deadlineUnixMilliseconds: 10, allowDisconnected: false, payload: Data([1]))))
        }
    }
    func testTypedKeysMustBeExactIncludingEmptyPayload() throws {
        let empty = try CompanionIPCCodec.encodePayload(CompanionIPCEmpty())
        XCTAssertEqual(String(decoding: empty, as: UTF8.self), "{}")
        XCTAssertThrowsError(try CompanionIPCCodec.decodePayload(Data("{\"x\":1}".utf8), as: CompanionIPCEmpty.self))
        XCTAssertThrowsError(try CompanionIPCCodec.decodePayload(Data("{\"phase\":\"failed\"}".utf8), as: CompanionIPCState.self))
    }
}
