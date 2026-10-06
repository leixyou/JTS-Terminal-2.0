import Foundation
import XCTest
import JTSCompanionIPC
@testable import JTSCompanionClient

final class LaneClientTests: XCTestCase {
    func testEachLaneOpensAndUsesIndependentVersionTwoByteProtocol() async throws {
        for lane in [CompanionIPCLane.file, .rdp, .desktop] {
            let mock = MockTransport(), grant = UUID()
            let client = CompanionLaneClient(transportFactory: { mock })
            let state = try await client.open(configuration: testConfiguration(), lane: lane, grantID: grant)
            XCTAssertEqual(state.lane, lane); XCTAssertEqual(state.maximumChunkBytes, 65536)
            let bytes = try await client.read(maximumBytes: 1); XCTAssertEqual(bytes, Data([42]))
            try await client.write(Data(repeating: 17, count: 65536))
            XCTAssertEqual(mock.requests.map(\.version), [2, 2, 2])
            let open = try CompanionIPCCodec.decodePayload(mock.requests[0].payload, as: CompanionIPCLaneOpen.self)
            XCTAssertEqual(open.grantID, grant)
            let write = try CompanionIPCCodec.decodePayload(mock.requests[2].payload, as: CompanionIPCLaneWrite.self)
            XCTAssertEqual(write.data.count, 65536); XCTAssertEqual(write.sequence, 1)
            await client.close()
        }
    }

    func testReadAndWriteOverlapWhileSameDirectionRemainsSerialized() async throws {
        let mock = MockTransport(); mock.hold([.readLane, .writeLane])
        let client = CompanionLaneClient(transportFactory: { mock })
        _ = try await client.open(configuration: testConfiguration(), lane: .rdp, grantID: UUID())
        let read = Task { try await client.read() }
        try await waitForRequests(mock, count: 2)
        let write = Task { try await client.write(Data([1])) }
        try await waitForRequests(mock, count: 3)
        await requireFailure({ try await client.read() }, .busy)
        await requireFailure({ try await client.write(Data([2])) }, .busy)
        XCTAssertEqual(mock.requests.count, 3)
        await client.close()
        await requireFailure({ try await read.value }, .cancelled)
        await requireFailure({ try await write.value }, .cancelled)
        XCTAssertEqual(mock.invalidationCount, 1)
    }

    func testReadCancellationClosesBothDirectionsWithoutReplay() async throws {
        let mock = MockTransport(); mock.hold([.readLane, .writeLane])
        let client = CompanionLaneClient(transportFactory: { mock })
        _ = try await client.open(configuration: testConfiguration(), lane: .file, grantID: UUID())
        let read = Task { try await client.read() }; try await waitForRequests(mock, count: 2)
        let write = Task { try await client.write(Data([1])) }; try await waitForRequests(mock, count: 3)
        read.cancel()
        await requireFailure({ try await read.value }, .cancelled)
        await requireFailure({ try await write.value }, .cancelled)
        XCTAssertEqual(mock.requests.count, 3)
    }

    func testMalformedSizesDoNotSendOrConsumeSequence() async throws {
        let mock = MockTransport(), client = CompanionLaneClient(transportFactory: { MockTransport() })
        await requireFailure({ try await client.read() }, .notConnected)
        let connected = CompanionLaneClient(transportFactory: { mock })
        _ = try await connected.open(configuration: testConfiguration(), lane: .rdp, grantID: UUID())
        for size in [0, 65537] {
            await requireFailure({ try await connected.read(maximumBytes: size) }, .invalidRequest)
            await requireFailure({ try await connected.write(Data(repeating: 1, count: size)) }, .invalidRequest)
        }
        XCTAssertEqual(mock.requests.count, 1)
        try await connected.write(Data([1]))
        XCTAssertEqual(try CompanionIPCCodec.decodePayload(mock.requests[1].payload, as: CompanionIPCLaneWrite.self).sequence, 1)
        await connected.close()
    }

    func testOldReplyCannotAffectReplacementLane() async throws {
        let old = MockTransport(), next = MockTransport(); old.hold([.readLane])
        let factory = MockFactory(old, next)
        let client = CompanionLaneClient(transportFactory: { try factory.make() })
        _ = try await client.open(configuration: testConfiguration(), lane: .rdp, grantID: UUID())
        let reading = Task { try await client.read() }; try await waitForRequests(old, count: 2)
        await client.close(); await requireFailure({ try await reading.value }, .cancelled)
        _ = try await client.open(configuration: testConfiguration(), lane: .file, grantID: UUID())
        old.deliver(.success(try old.success(at: 1)), at: 1); old.lose()
        let data = try await client.read(); XCTAssertEqual(data, Data([42]))
        XCTAssertEqual(next.invalidationCount, 0)
        await client.close()
    }

    func testWriteDeadlineWakesAnIdleRead() async throws {
        let mock = MockTransport(); mock.hold([.readLane, .writeLane])
        let client = CompanionLaneClient(transportFactory: { mock }, testTimeoutNanoseconds: 80_000_000)
        _ = try await client.open(configuration: testConfiguration(), lane: .rdp, grantID: UUID())
        let reading = Task { try await client.read() }; try await waitForRequests(mock, count: 2)
        await requireFailure({ try await client.write(Data([1])) }, .timedOut)
        await requireFailure({ try await reading.value }, .timedOut)
        XCTAssertEqual(mock.invalidationCount, 1)
    }

    func testWrongVersionAndOversizedReadInvalidateTheLane() async throws {
        for wrongVersion in [false, true] {
            let mock = MockTransport(); mock.hold([.readLane])
            let client = CompanionLaneClient(transportFactory: { mock })
            _ = try await client.open(configuration: testConfiguration(), lane: .rdp, grantID: UUID())
            let read = Task { try await client.read(maximumBytes: 1) }; try await waitForRequests(mock, count: 2)
            let request = mock.requests[1]
            let payload = try CompanionIPCCodec.encodePayload(CompanionIPCLaneBytes(Data([1, 2])))
            let reply = CompanionIPCReply(version: wrongVersion ? 1 : 2, id: request.id, connectionID: request.connectionID,
                                          ok: true, payload: payload, errorCode: nil)
            mock.deliver(.success(try CompanionIPCCodec.encodeReply(reply)), at: 1)
            await requireFailure({ try await read.value }, .invalidReply)
            XCTAssertEqual(mock.invalidationCount, 1)
        }
    }
}
