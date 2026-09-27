import Foundation

public struct CompanionLaneBinding: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let sessionId: String
    public let lane: RelayLane
    public let controllerDeviceId: String
    public let companionDeviceId: String

    public init(sessionID: String, lane: RelayLane, controllerDeviceID: String,
                companionDeviceID: String) throws {
        guard UUID(uuidString: sessionID) != nil,
              RelayIdentity.validateDeviceID(controllerDeviceID),
              RelayIdentity.validateDeviceID(companionDeviceID),
              controllerDeviceID != companionDeviceID else { throw CompanionTransportError.invalidBinding }
        protocolVersion = 1
        sessionId = sessionID
        self.lane = lane
        controllerDeviceId = controllerDeviceID
        companionDeviceId = companionDeviceID
    }

    public func framed() throws -> Data {
        let payload = try RelayJSON.encode(self)
        guard payload.count <= RelayLimits.bindingBytes else { throw CompanionTransportError.frameTooLarge }
        var count = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: &count) { Data($0) } + payload
    }

    public static func validate(payload: Data, expected: Self) throws {
        guard !payload.isEmpty, payload.count <= RelayLimits.bindingBytes,
              (try? StrictRelayJSON.validate(payload, requiredKeys: ["protocolVersion", "sessionId", "lane",
                  "controllerDeviceId", "companionDeviceId"])) != nil,
              let actual = try? JSONDecoder().decode(Self.self, from: payload), actual == expected else {
            throw CompanionTransportError.invalidBinding
        }
    }
}

/// Incrementally reads one length-prefixed binding without consuming following application bytes.
public struct CompanionBindingDecoder: Sendable {
    private var buffer = Data()
    private var expectedLength: Int?
    public private(set) var completed = false

    public init() {}

    public var bytesNeeded: Int {
        if completed { return 0 }
        return expectedLength.map { $0 + 4 - buffer.count } ?? (4 - buffer.count)
    }

    public mutating func append(_ data: Data, expected: CompanionLaneBinding) throws {
        guard !completed, !data.isEmpty, data.count <= bytesNeeded else {
            throw CompanionTransportError.invalidBinding
        }
        buffer.append(data)
        if buffer.count == 4 && expectedLength == nil {
            let length = buffer.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= RelayLimits.bindingBytes else {
                throw CompanionTransportError.frameTooLarge
            }
            expectedLength = Int(length)
        }
        if let length = expectedLength, buffer.count == length + 4 {
            try CompanionLaneBinding.validate(payload: Data(buffer.dropFirst(4)), expected: expected)
            buffer.removeAll(keepingCapacity: false)
            completed = true
        }
    }
}
