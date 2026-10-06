import Foundation
import XCTest
import JTSCompanionIPC
@testable import JTSCompanionClient

final class DesktopClientTests: XCTestCase {
    func testStateMessagesDoNotMeasureVideoAndRetiredFramesCannotRebindTheSession() async throws {
        let transport = MockTransport(); transport.hold([.readLane])
        let client = CompanionDesktopClient(lane: CompanionLaneClient(transportFactory: { transport }))
        let events = DesktopTestEvents(), first = UUID(), replacement = UUID()
        await client.setEventHandler { await events.append($0) }
        try await client.open(configuration: testConfiguration(), grantID: UUID())
        try await deliver(CompanionDesktopEnvelope(kind: "state", id: nil, operation: nil,
            generation: first, sessionId: 1, body: [:]), transport: transport, sequence: 1)
        try await waitForRequests(transport, count: 4)
        let noVideo = await client.deliveryMetrics()
        XCTAssertNil(noVideo)
        try await deliver(CompanionDesktopEnvelope(kind: "frame", id: nil, operation: nil,
            generation: first, sessionId: 1, body: [:], payloadBase64: "AQID"), transport: transport, sequence: 3)
        try await waitForRequests(transport, count: 6)
        let measured = await client.deliveryMetrics(), video = try XCTUnwrap(measured)
        try await deliver(CompanionDesktopEnvelope(kind: "state", id: nil, operation: nil,
            generation: replacement, sessionId: 2, body: [:]), transport: transport, sequence: 5)
        try await waitForRequests(transport, count: 8)
        let afterState = await client.deliveryMetrics()
        XCTAssertEqual(afterState?.bytes, video.bytes)
        XCTAssertEqual(afterState?.milliseconds, video.milliseconds)
        try await deliver(CompanionDesktopEnvelope(kind: "frame", id: nil, operation: nil,
            generation: first, sessionId: 1, body: [:], payloadBase64: "AQID"), transport: transport, sequence: 7)
        try await waitForRequests(transport, count: 10)
        let count = await events.count
        XCTAssertEqual(count, 3)
        let action = Task { try await client.request("action", expectedGeneration: replacement, expectedSessionId: 2) }
        try await waitForRequests(transport, count: 11)
        let sent = try XCTUnwrap(transport.requests.first(where: { $0.operation == .writeLane }))
        let write = try CompanionIPCCodec.decodePayload(sent.payload, as: CompanionIPCLaneWrite.self)
        let request = try CompanionDesktopWire.decode(write.data.subdata(in: 4..<write.data.count))
        try await deliver(CompanionDesktopEnvelope(kind: "response", id: request.id, operation: "action",
            generation: replacement, sessionId: 2, body: [:]), transport: transport, sequence: 9)
        _ = try await action.value
        await client.close()
    }
    func testUnsolicitedFrameIsDeliveredWithoutConsumingThePendingRPC() async throws {
        let transport = MockTransport(); transport.hold([.readLane])
        let client = CompanionDesktopClient(lane: CompanionLaneClient(transportFactory: { transport }))
        let received = DesktopTestEvents(), generation = UUID()
        await client.setEventHandler { frame in await received.append(frame) }
        try await client.open(configuration: testConfiguration(), grantID: UUID())
        let status = Task { try await client.request("status") }
        try await waitForRequests(transport, count: 3)
        let pushed = CompanionDesktopEnvelope(kind: "frame", id: nil, operation: nil, generation: generation,
            sessionId: 1, body: [:], payloadBase64: Data([1, 2, 3]).base64EncodedString())
        try await deliver(pushed, transport: transport, sequence: 1)
        for _ in 0..<200 {
            if await received.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let count = await received.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(transport.requests.filter { $0.operation == .writeLane }.count, 1)
        let sent = try XCTUnwrap(transport.requests.first(where: { $0.operation == .writeLane }))
        let write = try CompanionIPCCodec.decodePayload(sent.payload, as: CompanionIPCLaneWrite.self)
        let request = try CompanionDesktopWire.decode(write.data.subdata(in: 4..<write.data.count))
        try await deliver(CompanionDesktopEnvelope(kind: "response", id: request.id, operation: "status",
            generation: generation, sessionId: 1, body: ["status": .string("ready")]), transport: transport, sequence: 3)
        let response = try await status.value
        XCTAssertEqual(response.id, request.id)
        await client.close()
    }
    func testAUserRequestCannotBlockASeparateFrameLaneAndCancellationNeverReplays() async throws {
        let video = MockTransport(), user = MockTransport()
        video.hold([.readLane]); user.hold([.readLane])
        let screen = CompanionDesktopClient(lane: CompanionLaneClient(transportFactory: { video }))
        let commands = CompanionDesktopClient(lane: CompanionLaneClient(transportFactory: { user }))
        let generation = UUID(), grant = UUID()
        try await screen.open(configuration: testConfiguration(), grantID: grant)
        try await commands.open(configuration: testConfiguration(), grantID: grant)
        let binding = Task { try await commands.request("bindUserSession", body: [
            "generation": .string(generation.uuidString.lowercased()), "sessionId": .integer(1)],
            expectedGeneration: generation, expectedSessionId: 1) }
        try await reply(user, writeIndex: 1, generation: generation)
        _ = try await binding.value
        let command = Task { try await commands.request("user.command", body: ["timeoutMilliseconds": .integer(600_000)],
            expectedGeneration: generation, expectedSessionId: 1) }
        try await waitForRequests(user, count: 6)
        // The command's read remains pending while the screen obtains a reply.
        let status = Task { try await screen.request("status") }
        try await reply(video, writeIndex: 1, generation: generation)
        let observed = try await status.value
        XCTAssertEqual(observed.generation, generation)
        XCTAssertEqual(user.requests.count, 6)
        command.cancel()
        do { _ = try await command.value; XCTFail("Cancelled command succeeded") } catch {}
        XCTAssertEqual(user.requests.filter { $0.operation == .writeLane }.count, 2)
        XCTAssertEqual(user.invalidationCount, 1)
        XCTAssertEqual(video.invalidationCount, 0)
        await screen.close()
    }

    func testWrongSessionGenerationIsRejectedBeforeSendingAnAction() async throws {
        let transport = MockTransport(); transport.hold([.readLane])
        let client = CompanionDesktopClient(lane: CompanionLaneClient(transportFactory: { transport }))
        let generation = UUID()
        try await client.open(configuration: testConfiguration(), grantID: UUID())
        let status = Task { try await client.request("status") }
        try await reply(transport, writeIndex: 1, generation: generation)
        _ = try await status.value
        let count = transport.requests.count
        do {
            _ = try await client.request("action", body: ["kind": .string("click")],
                expectedGeneration: UUID(), expectedSessionId: 1)
            XCTFail("Wrong generation succeeded")
        } catch { XCTAssertEqual(error as? CompanionDesktopError, .sessionChanged) }
        XCTAssertEqual(transport.requests.count, count)
        await client.close()
    }

    private func reply(_ transport: MockTransport, writeIndex: Int, generation: UUID) async throws {
        try await waitForRequests(transport, count: 3)
        let sent = try XCTUnwrap(transport.requests.firstIndex(where: { $0.operation == .writeLane }))
        let payload = try CompanionIPCCodec.decodePayload(transport.requests[sent].payload, as: CompanionIPCLaneWrite.self)
        let request = try CompanionDesktopWire.decode(payload.data.subdata(in: 4..<payload.data.count))
        let response = CompanionDesktopEnvelope(kind: "response", id: request.id, operation: request.operation,
            generation: generation, sessionId: 1, body: ["status": .string("ready")])
        let bytes = try CompanionDesktopWire.encode(response)
        let header = try CompanionIPCCodec.encodePayload(CompanionIPCLaneBytes(bytes.prefix(4)))
        let headerIndex = try XCTUnwrap(transport.requests.firstIndex(where: { $0.operation == .readLane }))
        transport.deliver(.success(try transport.success(at: headerIndex, payload: header)), at: headerIndex)
        try await waitForRequests(transport, count: 4)
        let bodyIndex = try XCTUnwrap(transport.requests.lastIndex(where: { $0.operation == .readLane }))
        let body = try CompanionIPCCodec.encodePayload(CompanionIPCLaneBytes(bytes.dropFirst(4)))
        transport.deliver(.success(try transport.success(at: bodyIndex, payload: body)), at: bodyIndex)
    }

    private func deliver(_ message: CompanionDesktopEnvelope, transport: MockTransport, sequence: UInt64) async throws {
        let bytes = try CompanionDesktopWire.encode(message)
        for (number, content) in [(sequence, Data(bytes.prefix(4))), (sequence + 1, Data(bytes.dropFirst(4)))] {
            var index: Int?
            for _ in 0..<2000 {
                index = transport.requests.firstIndex { request in
                    request.operation == .readLane &&
                    (try? CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCLaneRead.self).sequence) == number
                }
                if index != nil { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let target = try XCTUnwrap(index)
            let payload = try CompanionIPCCodec.encodePayload(CompanionIPCLaneBytes(content))
            transport.deliver(.success(try transport.success(at: target, payload: payload)), at: target)
        }
    }
}

private actor DesktopTestEvents {
    private var values: [CompanionDesktopEnvelope] = []
    var count: Int { values.count }
    func append(_ value: CompanionDesktopEnvelope) { values.append(value) }
}
