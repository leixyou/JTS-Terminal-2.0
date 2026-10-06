import Foundation

@objc(JTSCompanionTransportServiceProtocol)
public protocol CompanionTransportServiceProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum CompanionIPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: CompanionTransportServiceProtocol.self)
        let classes = NSSet(object: NSData.self) as! Set<AnyHashable>
        let selector = #selector(CompanionTransportServiceProtocol.perform(_:withReply:))
        interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: false)
        interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: true)
        return interface
    }
}

public enum CompanionIPCError: Error, Equatable, Sendable {
    case invalidFrame, invalidPayload, unsupportedVersion
}

public enum CompanionIPCLimits {
    public static let frameBytes = 160 * 1024
    public static let payloadBytes = 96 * 1024
    public static let maximumDepth = 16
}

public enum CompanionIPCOperation: String, Codable, Sendable {
    case open, state, close, status, submit, job, cancel, output
    case authorizeDesktop
    case openLane, readLane, writeLane, closeLane

    public var isLaneOperation: Bool {
        switch self {
        case .openLane, .readLane, .writeLane, .closeLane: return true
        default: return false
        }
    }
}

public struct CompanionIPCRequest: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let version: Int
    public let id, connectionID: UUID
    public let operation: CompanionIPCOperation
    public let payload: Data

    public init(version: Int = 1, id: UUID, connectionID: UUID, operation: CompanionIPCOperation, payload: Data) {
        self.version = version; self.id = id; self.connectionID = connectionID
        self.operation = operation; self.payload = payload
    }
    public var description: String { "CompanionIPCRequest (contents redacted)" }
    public var debugDescription: String { description }
}

public struct CompanionIPCReply: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let version: Int
    public let id, connectionID: UUID
    public let ok: Bool
    public let payload: Data?
    public let errorCode: String?

    public init(version: Int = 1, id: UUID, connectionID: UUID, ok: Bool, payload: Data?, errorCode: String?) {
        self.version = version; self.id = id; self.connectionID = connectionID
        self.ok = ok; self.payload = payload; self.errorCode = errorCode
    }
    public var description: String { "CompanionIPCReply (contents redacted)" }
    public var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey { case version, id, connectionID, ok, payload, errorCode }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(version, forKey: .version); try fields.encode(id, forKey: .id)
        try fields.encode(connectionID, forKey: .connectionID); try fields.encode(ok, forKey: .ok)
        try fields.encode(payload, forKey: .payload); try fields.encode(errorCode, forKey: .errorCode)
    }
}
