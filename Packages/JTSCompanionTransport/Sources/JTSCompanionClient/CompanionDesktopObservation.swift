import Foundation

public struct CompanionDesktopObservation: Equatable, Sendable {
    public let frameID, observationID, generation: UUID
    public let sessionID, width, height, originX, originY: Int
    public let capturedAt: Date
    private let receivedAt: Date
    public let codec: String
    public let bytes: Data
    public init(_ value: CompanionDesktopEnvelope, now: Date = Date()) throws {
        guard value.kind == "frame", let frame = value.body["frameID"]?.stringValue,
              let frameID = UUID(uuidString: frame), let observation = value.body["observationID"]?.stringValue,
              let observationID = UUID(uuidString: observation), let width = value.body["width"]?.integerValue,
              let height = value.body["height"]?.integerValue, (1...7680).contains(width), (1...4320).contains(height),
              width * height <= 33_177_600, let codec = value.body["codec"]?.stringValue, ["jpeg", "h264"].contains(codec),
              let text = value.payloadBase64, let bytes = Data(base64Encoded: text), !bytes.isEmpty,
              let captured = value.body["capturedAt"]?.stringValue,
              let date = Self.parseDate(captured), abs(date.timeIntervalSince(now)) <= 120 else {
            throw CompanionDesktopError.invalidFrame
        }
        self.frameID = frameID; self.observationID = observationID; generation = value.generation
        sessionID = value.sessionId; self.width = Int(width); self.height = Int(height)
        originX = Int(value.body["originX"]?.integerValue ?? 0); originY = Int(value.body["originY"]?.integerValue ?? 0)
        capturedAt = date; receivedAt = now; self.codec = codec; self.bytes = bytes
    }
    public func requireFresh(generation: UUID, sessionID: Int, now: Date = Date()) throws {
        guard self.generation == generation, self.sessionID == sessionID else { throw CompanionDesktopError.sessionChanged }
        guard (0...10).contains(now.timeIntervalSince(receivedAt)) else { throw CompanionDesktopError.staleObservation }
    }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
