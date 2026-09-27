import Foundation
import XCTest
@testable import JTSCompanionIPC

final class LanePayloadTests: XCTestCase {
    func testMaximumChunkFitsBothBase64Envelopes() throws {
        let payload = try CompanionIPCCodec.encodePayload(CompanionIPCLaneWrite(data: Data(repeating: 255, count: 65536), sequence: 1))
        let frame = try CompanionIPCCodec.encodeRequest(CompanionIPCRequest(version: 2, id: UUID(), connectionID: UUID(), operation: .writeLane, payload: payload))
        XCTAssertLessThan(payload.count, CompanionIPCLimits.payloadBytes)
        XCTAssertLessThan(frame.count, CompanionIPCLimits.frameBytes)
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(CompanionIPCCodec.decodeRequest(frame).payload, as: CompanionIPCLaneWrite.self).data.count, 65536)
    }

    func testLaneVersionCannotBeMixedWithLegacyControl() throws {
        let body = try CompanionIPCCodec.encodePayload(CompanionIPCEmpty())
        for (version, operation) in [(1, CompanionIPCOperation.closeLane), (2, .state)] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodeRequest(CompanionIPCRequest(version: version,
                id: UUID(), connectionID: UUID(), operation: operation, payload: body)))
        }
    }

    func testZeroSequenceAndOversizedOrEmptyStreamBlocksAreRejected() {
        for value in [CompanionIPCLaneRead(maximumBytes: 1, sequence: 0), .init(maximumBytes: 65537, sequence: 1)] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(value))
        }
        for count in [0, 65537] {
            XCTAssertThrowsError(try CompanionIPCCodec.encodePayload(CompanionIPCLaneWrite(data: Data(repeating: 1, count: count), sequence: 1)))
        }
    }
}
