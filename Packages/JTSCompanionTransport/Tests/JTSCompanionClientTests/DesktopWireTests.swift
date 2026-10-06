import Foundation
import XCTest
import JTSCompanionIPC
@testable import JTSCompanionClient

final class DesktopWireTests: XCTestCase {
    func testDesktopEnvelopeRejectsDuplicateDeepAndInvalidPayload() throws {
        let envelope = CompanionDesktopEnvelope(kind: "request", id: UUID().uuidString.lowercased(), operation: "status",
            generation: UUID(), sessionId: 2, body: [:])
        let frame = try CompanionDesktopWire.encode(envelope)
        XCTAssertEqual(frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }, frame.count-4)
        let data = Data(frame.dropFirst(4))
        XCTAssertEqual(try CompanionDesktopWire.decode(data).operation, "status")
        var duplicate = data; duplicate.insert(contentsOf: Data("\"version\":1,".utf8), at: 1)
        XCTAssertThrowsError(try CompanionDesktopWire.decode(duplicate))
        XCTAssertThrowsError(try CompanionDesktopWire.decode(Data([0xFF])))
        let bad = CompanionDesktopEnvelope(kind: "response", id: nil, operation: nil, generation: UUID(), sessionId: 1,
            body: [:], payloadBase64: Data([1]).base64EncodedString())
        XCTAssertThrowsError(try CompanionDesktopWire.encode(bad))
        XCTAssertFalse(envelope.description.contains("generation"))
    }

    func testObserveBindsGenerationSessionCoordinatesAndTime() throws {
        let generation = UUID(), now = Date()
        let body: [String: DesktopJSONValue] = ["frameID": .string(UUID().uuidString), "observationID": .string(UUID().uuidString),
            "width": .integer(1920), "height": .integer(1080), "originX": .integer(-1920), "originY": .integer(0),
            "dpiX": .number(144), "dpiY": .number(144), "capturedAt": .string(ISO8601DateFormatter().string(from: now)), "codec": .string("jpeg")]
        let value = CompanionDesktopEnvelope(kind: "frame", id: UUID().uuidString, operation: "observe", generation: generation,
            sessionId: 4, body: body, payloadBase64: Data([1,2]).base64EncodedString())
        let observed = try CompanionDesktopObservation(value, now: now)
        XCTAssertEqual(observed.originX, -1920)
        try observed.requireFresh(generation: generation, sessionID: 4, now: now)
        XCTAssertThrowsError(try observed.requireFresh(generation: UUID(), sessionID: 4, now: now))
        XCTAssertThrowsError(try observed.requireFresh(generation: generation, sessionID: 5, now: now))
        XCTAssertThrowsError(try observed.requireFresh(generation: generation, sessionID: 4, now: now.addingTimeInterval(31)))
        var invalidBody = body; invalidBody["width"] = .integer(10_000)
        let invalid = CompanionDesktopEnvelope(kind: "frame", id: value.id, operation: "observe", generation: generation,
            sessionId: 4, body: invalidBody, payloadBase64: value.payloadBase64)
        XCTAssertThrowsError(try CompanionDesktopObservation(invalid, now: now))
    }
    func testDesktopLaneHasSeparateIPCConnectionAndGrant() async throws {
        let transport = MockTransport()
        let lane = CompanionLaneClient(transportFactory: { transport })
        let grant = UUID()
        _ = try await lane.open(configuration: testConfiguration(), lane: .desktop, grantID: grant)
        let request = try XCTUnwrap(transport.requests.first)
        let opened = try CompanionIPCCodec.decodePayload(request.payload, as: CompanionIPCLaneOpen.self)
        XCTAssertEqual(opened.lane, .desktop); XCTAssertEqual(opened.grantID, grant)
        await lane.close()
        XCTAssertGreaterThan(transport.invalidationCount, 0)
    }
}
