#if ENABLE_RDP_2
import Foundation

/// Camel-case control envelope consumed by the .NET `CompanionRequest` record.
nonisolated struct DVCCompanionRequest: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var requestID: UUID
    var method: String
    var deadlineUnixMilliseconds: Int64?
    var idempotencyKey: String?
    var expectedStateRevision: UInt64?
    var parameters: DVCJSONValue

    init(
        protocolVersion: Int = WindowsCompanionDVC.protocolVersion,
        requestID: UUID = UUID(),
        method: String,
        deadlineUnixMilliseconds: Int64? = nil,
        idempotencyKey: String? = nil,
        expectedStateRevision: UInt64? = nil,
        parameters: DVCJSONValue = .object([:])
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.method = method
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.idempotencyKey = idempotencyKey
        self.expectedStateRevision = expectedStateRevision
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID = "requestId"
        case method
        case deadlineUnixMilliseconds
        case idempotencyKey
        case expectedStateRevision
        case parameters
    }
}

nonisolated struct DVCCompanionError: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var retryable: Bool

    init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// Camel-case control envelope emitted by the .NET `CompanionResponse` record.
nonisolated struct DVCCompanionResponse: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var requestID: UUID
    var success: Bool
    var result: DVCJSONValue?
    var error: DVCCompanionError?

    init(
        protocolVersion: Int = WindowsCompanionDVC.protocolVersion,
        requestID: UUID,
        success: Bool,
        result: DVCJSONValue? = nil,
        error: DVCCompanionError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.success = success
        self.result = result
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID = "requestId"
        case success
        case result
        case error
    }
}

nonisolated enum DVCControlMessageCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw DVCProtocolError.invalidJSONPayload
        }
    }
}

/// Sendable, lossless-enough JSON representation used for Companion parameters
/// and results. Integer cases avoid rounding 64-bit state revisions through a
/// `Double`.
nonisolated enum DVCJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case array([DVCJSONValue])
    case object([String: DVCJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DVCJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DVCJSONValue].self) {
            self = .object(value)
        } else {
            throw DVCProtocolError.invalidJSONValue
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

#endif
