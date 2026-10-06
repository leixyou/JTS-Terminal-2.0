import Foundation

public enum DesktopPacketCodec {
    public static func encode(_ message: RemoteDesktopMessage) throws -> Data {
        try message.validate()
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= DesktopProtocol.maximumPacketBytes else { throw DesktopProtocolError.oversizedPacket }
        let length = UInt32(payload.count)
        var packet = Data([
            UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
            UInt8((length >> 8) & 255), UInt8(length & 255)
        ])
        packet.append(payload)
        return packet
    }

    public static func decodePayload(_ payload: Data) throws -> RemoteDesktopMessage {
        guard !payload.isEmpty, payload.count <= DesktopProtocol.maximumPacketBytes else {
            throw DesktopProtocolError.oversizedPacket
        }
        let message = try JSONDecoder().decode(RemoteDesktopMessage.self, from: payload)
        try message.validate()
        return message
    }

    public static func payloadLength(header: Data) throws -> Int {
        guard header.count == 4 else { throw DesktopProtocolError.truncatedPacket }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= DesktopProtocol.maximumPacketBytes else {
            throw DesktopProtocolError.oversizedPacket
        }
        return Int(length)
    }
}

/// Incremental decoder for tests and stream consumers; validates the header before allocating payload storage.
public struct DesktopPacketDecoder {
    private var buffer = Data()
    private var expectedLength: Int?

    public init() {}

    public mutating func append(_ data: Data) throws -> [RemoteDesktopMessage] {
        var messages: [RemoteDesktopMessage] = []
        var offset = 0
        while offset < data.count {
            let target = expectedLength ?? 4
            let required = target - buffer.count
            let available = min(required, data.count - offset)
            buffer.append(data[data.startIndex + offset ..< data.startIndex + offset + available])
            offset += available
            if buffer.count == target {
                if expectedLength == nil {
                    expectedLength = try DesktopPacketCodec.payloadLength(header: buffer)
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    messages.append(try DesktopPacketCodec.decodePayload(buffer))
                    buffer.removeAll(keepingCapacity: true)
                    expectedLength = nil
                }
            }
        }
        return messages
    }

    public func finish() throws {
        guard buffer.isEmpty, expectedLength == nil else { throw DesktopProtocolError.truncatedPacket }
    }
}
