import Foundation
import XCTest
@testable import JTSCompanionIPC

final class CodecTests: XCTestCase {
    private let id = UUID(), connectionID = UUID()
    private let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    func testRequestRoundTripAndRedaction() throws {
        let secret = "do-not-print-this"
        let request = CompanionIPCRequest(id: id, connectionID: connectionID, operation: .submit, payload: Data(secret.utf8))
        let decoded = try CompanionIPCCodec.decodeRequest(CompanionIPCCodec.encodeRequest(request))
        XCTAssertEqual(decoded.payload, request.payload); XCTAssertEqual(decoded.id, id); XCTAssertEqual(decoded.operation, .submit)
        XCTAssertFalse(String(describing: decoded).contains(secret)); XCTAssertFalse(String(reflecting: decoded).contains(secret))
    }

    func testReplyIncludesExplicitNullFields() throws {
        let value = CompanionIPCReply(id: id, connectionID: connectionID, ok: true, payload: nil, errorCode: nil)
        let data = try CompanionIPCCodec.encodeReply(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "id", "connectionID", "ok", "payload", "errorCode"])
        XCTAssertTrue(object["payload"] is NSNull); XCTAssertTrue(object["errorCode"] is NSNull)
        XCTAssertTrue(try CompanionIPCCodec.decodeReply(data).ok)
    }

    func testReplyRequiresNullKeysAndRejectsUnknownKeys() throws {
        let value = CompanionIPCReply(id: id, connectionID: connectionID, ok: true, payload: nil, errorCode: nil)
        let good = try CompanionIPCCodec.encodeReply(value)
        for mutation in ["missing", "unknown"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
            if mutation == "missing" { object.removeValue(forKey: "errorCode") } else { object["extra"] = true }
            XCTAssertThrowsError(try CompanionIPCCodec.decodeReply(JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testZeroIDsVersionAndUnknownOperationRejected() throws {
        for request in [
            CompanionIPCRequest(id: zero, connectionID: connectionID, operation: .state, payload: Data()),
            CompanionIPCRequest(id: id, connectionID: zero, operation: .state, payload: Data()),
            CompanionIPCRequest(version: 2, id: id, connectionID: connectionID, operation: .state, payload: Data())
        ] { XCTAssertThrowsError(try CompanionIPCCodec.encodeRequest(request)) }
        let valid = CompanionIPCRequest(id: id, connectionID: connectionID, operation: .state, payload: Data())
        let frame = try CompanionIPCCodec.encodeRequest(valid)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any]); object["operation"] = "rdp"
        XCTAssertThrowsError(try CompanionIPCCodec.decodeRequest(JSONSerialization.data(withJSONObject: object)))
    }

    func testCanonicalBase64RequiredForEnvelopeAndPayload() throws {
        let valid = CompanionIPCRequest(id: id, connectionID: connectionID, operation: .state, payload: Data([0]))
        let frame = try CompanionIPCCodec.encodeRequest(valid)
        for text in ["AB==", "AA", "AA==\n", " AA=="] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any]); object["payload"] = text
            XCTAssertThrowsError(try CompanionIPCCodec.decodeRequest(JSONSerialization.data(withJSONObject: object)))
        }
        let open = CompanionIPCOpen(privateKey: Data(repeating: 1, count: 32), peerSPKI: Data([0]), relayURL: "https://relay.example")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionIPCCodec.encodePayload(open)) as? [String: Any])
        object["peerSPKI"] = "AB=="
        XCTAssertThrowsError(try CompanionIPCCodec.decodePayload(JSONSerialization.data(withJSONObject: object), as: CompanionIPCOpen.self))
    }

    func testFrameAndPayloadBounds() throws {
        let exact = CompanionIPCRequest(id: id, connectionID: connectionID, operation: .submit,
            payload: Data(repeating: 0, count: CompanionIPCLimits.payloadBytes))
        XCTAssertEqual(try CompanionIPCCodec.decodeRequest(CompanionIPCCodec.encodeRequest(exact)).payload.count, CompanionIPCLimits.payloadBytes)
        let oversized = CompanionIPCRequest(id: id, connectionID: connectionID, operation: .submit,
            payload: Data(repeating: 0, count: CompanionIPCLimits.payloadBytes + 1))
        XCTAssertThrowsError(try CompanionIPCCodec.encodeRequest(oversized))
        XCTAssertThrowsError(try CompanionIPCCodec.decodeRequest(Data(repeating: 32, count: CompanionIPCLimits.frameBytes + 1)))
    }

    func testFailureShapeAndErrorCodeBound() throws {
        let good = CompanionIPCReply(id: id, connectionID: connectionID, ok: false, payload: nil, errorCode: String(repeating: "A", count: 80))
        XCTAssertEqual(try CompanionIPCCodec.decodeReply(CompanionIPCCodec.encodeReply(good)).errorCode?.count, 80)
        for code in ["", "bad error", String(repeating: "A", count: 81)] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodeReply(CompanionIPCReply(id: id, connectionID: connectionID,
                ok: false, payload: nil, errorCode: code)))
        }
        XCTAssertThrowsError(try CompanionIPCCodec.encodeReply(CompanionIPCReply(id: id, connectionID: connectionID,
            ok: false, payload: Data(), errorCode: "DENIED")))
        XCTAssertThrowsError(try CompanionIPCCodec.encodeReply(CompanionIPCReply(id: id, connectionID: connectionID,
            ok: true, payload: nil, errorCode: "DENIED")))
    }
}
