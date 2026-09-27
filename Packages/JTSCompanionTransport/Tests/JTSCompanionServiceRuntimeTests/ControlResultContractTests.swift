import Foundation
import XCTest
import JTSCompanionIPC

final class ControlResultContractTests: XCTestCase {
    private let job = "a54f69c4-d584-446e-8950-b25f03022588"
    private let grant = "638ba95b-8bba-4f74-8845-84e8c777104c"

    func testReceiptRoundTripPreservesExplicitNullFields() throws {
        let model = try CompanionIPCCodec.decodePayload(bytes(receipt()), as: CompanionJobReceipt.self)
        let encoded = try CompanionIPCCodec.encodePayload(model)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), CompanionJobReceipt.requiredKeys)
        XCTAssertTrue(object["startedAtUnixMilliseconds"] is NSNull)
        XCTAssertTrue(object["completedAtUnixMilliseconds"] is NSNull)
        XCTAssertTrue(object["resultCode"] is NSNull)
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(encoded, as: CompanionJobReceipt.self).jobId, job)
    }

    func testReceiptIdentityAndBoundsAreNotAssumedFromHelper() throws {
        for change: [String: Any] in [
            ["grantId": "00000000-0000-0000-0000-000000000000"], ["jobId": job.uppercased()],
            ["outputBytes": 1_048_577], ["deadlineUnixMilliseconds": -1], ["kind": "bad command"],
            ["resultCode": String(repeating: "x", count: 129)]
        ] {
            var value = receipt(); value.merge(change) { _, new in new }
            XCTAssertThrowsError(try CompanionIPCCodec.decodePayload(bytes(value), as: CompanionJobReceipt.self))
        }
    }

    func testOutputRoundTripBindsOffsetsAndRedactsContent() throws {
        let content = Data("private remote output".utf8)
        let value: [String: Any] = ["jobId": job, "offset": 3, "nextOffset": 3+content.count,
                                   "outputBytes": 3+content.count, "dataBase64": content.base64EncodedString()]
        let model = try CompanionIPCCodec.decodePayload(bytes(value), as: CompanionJobOutput.self)
        XCTAssertEqual(model.data, content)
        XCTAssertFalse(String(describing: model).contains("private remote"))
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(CompanionIPCCodec.encodePayload(model), as: CompanionJobOutput.self).data, content)
        var invalid = value; invalid["nextOffset"] = 4
        XCTAssertThrowsError(try CompanionIPCCodec.decodePayload(bytes(invalid), as: CompanionJobOutput.self))
        invalid = value; invalid["offset"] = Int.max
        XCTAssertThrowsError(try CompanionIPCCodec.decodePayload(bytes(invalid), as: CompanionJobOutput.self))
    }

    func testStatusCannotAdvertiseUnknownOrDuplicateCapabilities() throws {
        for capabilities in [["device.status", "device.status"], ["SYSTEM.shell"], ["file.upload"]] {
            let value: [String: Any] = ["capabilities": capabilities, "maximumPayloadBytes": 65536, "maximumOutputChunkBytes": 32768]
            XCTAssertThrowsError(try CompanionIPCCodec.decodePayload(bytes(value), as: CompanionControlStatus.self))
        }
    }

    private func receipt() -> [String: Any] {
        ["jobId": job, "grantId": grant, "kind": "powershell", "deadlineUnixMilliseconds": 2_000,
         "allowDisconnected": false, "state": "queued", "submittedAtUnixMilliseconds": 1_000,
         "startedAtUnixMilliseconds": NSNull(), "completedAtUnixMilliseconds": NSNull(), "resultCode": NSNull(),
         "outputBytes": 0, "dataExpired": false]
    }
    private func bytes(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
