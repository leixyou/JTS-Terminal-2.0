import Foundation
import JTSCompanionIPC

public enum CompanionDesktopError: Error, Equatable, Sendable {
    case invalidFrame, invalidRequest, disconnected, busy, staleObservation, sessionChanged, remote(String)
}

public enum DesktopJSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String), array([DesktopJSONValue]), object([String: DesktopJSONValue])
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let x = try? value.decode(Bool.self) { self = .bool(x) }
        else if let x = try? value.decode(Int64.self) { self = .integer(x) }
        else if let x = try? value.decode(Double.self), x.isFinite { self = .number(x) }
        else if let x = try? value.decode(String.self) { self = .string(x) }
        else if let x = try? value.decode([DesktopJSONValue].self) { self = .array(x) }
        else { self = .object(try value.decode([String: DesktopJSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let x): try value.encode(x)
        case .integer(let x): try value.encode(x)
        case .number(let x):
            guard x.isFinite else { throw CompanionDesktopError.invalidFrame }
            try value.encode(x)
        case .string(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .object(let x): try value.encode(x)
        }
    }
    public var stringValue: String? { if case .string(let x) = self { return x }; return nil }
    public var integerValue: Int64? { if case .integer(let x) = self { return x }; return nil }
    public var objectValue: [String: DesktopJSONValue]? { if case .object(let x) = self { return x }; return nil }
}

/// No implicit logging of text, command or credential contents.
public struct CompanionDesktopEnvelope: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let version: Int
    public let kind: String
    public let id, operation: String?
    public let generation: UUID
    public let sessionId: Int
    public let body: [String: DesktopJSONValue]
    public let payloadBase64: String?
    public var description: String { "CompanionDesktopEnvelope (contents omitted)" }
    public var debugDescription: String { description }
    public init(kind: String, id: String?, operation: String?, generation: UUID, sessionId: Int,
                body: [String: DesktopJSONValue], payloadBase64: String? = nil) {
        version = 1; self.kind = kind; self.id = id; self.operation = operation; self.generation = generation
        self.sessionId = sessionId; self.body = body; self.payloadBase64 = payloadBase64
    }
    private enum CodingKeys: String, CodingKey { case version, kind, id, operation, generation, sessionId, body, payloadBase64 }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(version, forKey: .version); try value.encode(kind, forKey: .kind)
        try value.encode(id, forKey: .id); try value.encode(operation, forKey: .operation)
        try value.encode(generation.uuidString.lowercased(), forKey: .generation); try value.encode(sessionId, forKey: .sessionId)
        try value.encode(body, forKey: .body); try value.encode(payloadBase64, forKey: .payloadBase64)
    }
}

public enum CompanionDesktopWire {
    public static let maximumBytes = 8 * 1024 * 1024
    public static func encode(_ value: CompanionDesktopEnvelope) throws -> Data {
        try validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw CompanionDesktopError.invalidFrame }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data); return frame
    }
    public static func decode(_ data: Data) throws -> CompanionDesktopEnvelope {
        do {
            try StrictCompanionJSON.validateDesktop(data, requiredKeys: ["version", "kind", "id", "operation", "generation", "sessionId", "body", "payloadBase64"])
            let value = try JSONDecoder().decode(CompanionDesktopEnvelope.self, from: data)
            try validate(value); return value
        } catch { throw CompanionDesktopError.invalidFrame }
    }
    private static func validate(_ value: CompanionDesktopEnvelope) throws {
        guard value.version == 1, ["request", "response", "state", "frame"].contains(value.kind),
              (0...Int(Int32.max)).contains(value.sessionId), value.body.count <= 64,
              value.id.map({ UUID(uuidString: $0) != nil }) ?? true,
              value.operation.map({ $0.utf8.count <= 64 && $0.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || $0 == 46
              }) }) ?? true else { throw CompanionDesktopError.invalidFrame }
        if let text = value.payloadBase64 {
            guard value.kind == "frame", let bytes = Data(base64Encoded: text), !bytes.isEmpty,
                  bytes.count <= 6 * 1024 * 1024, bytes.base64EncodedString() == text else { throw CompanionDesktopError.invalidFrame }
        }
    }
}
