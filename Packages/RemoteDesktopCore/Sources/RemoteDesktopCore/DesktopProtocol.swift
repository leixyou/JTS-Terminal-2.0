import Foundation

public enum DesktopProtocol {
    public static let version = 2
    public static let maximumPacketBytes = 12 * 1_024 * 1_024
    public static let maximumJPEGBytes = 8 * 1_024 * 1_024
    public static let maximumDimension = 16_384
    public static let invitationIdentity = "jtsmac-invitation-v2"
}

public enum DesktopProtocolError: Error, LocalizedError, Equatable {
    case invalidMessage(String)
    case invalidInvitation
    case unsupportedVersion
    case oversizedPacket
    case truncatedPacket
    case invalidSecret
    case invitationExpired
    case invitationUnavailable
    case connectionTimeout
    case outboundQueueFull

    public var errorDescription: String? {
        switch self {
        case .invalidMessage(let field): return "Invalid remote desktop message: \(field)."
        case .invalidInvitation: return "The Mac pairing code is invalid."
        case .unsupportedVersion: return "The remote desktop protocol version is unsupported."
        case .oversizedPacket: return "The remote desktop packet exceeds the size limit."
        case .truncatedPacket: return "The remote desktop connection ended during a packet."
        case .invalidSecret: return "The remote desktop credential is invalid."
        case .invitationExpired: return "The Mac pairing invitation has expired."
        case .invitationUnavailable: return "The Mac pairing invitation is no longer available."
        case .connectionTimeout: return "The encrypted remote desktop handshake timed out."
        case .outboundQueueFull: return "The remote desktop connection is busy."
        }
    }
}

public struct DesktopHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var hostName: String
    public init(protocolVersion: Int = DesktopProtocol.version, hostName: String) {
        self.protocolVersion = protocolVersion
        self.hostName = hostName
    }
}

public struct DesktopAuthentication: Codable, Equatable, Sendable {
    public var clientID: UUID
    public var clientName: String
    public var invitationToken: String?
    public var token: String?
    public init(clientID: UUID, clientName: String, invitationToken: String? = nil, token: String? = nil) {
        self.clientID = clientID
        self.clientName = clientName
        self.invitationToken = invitationToken
        self.token = token
    }

    public func validate() throws {
        try validateDesktopText(clientName, maximumBytes: 256)
        guard (invitationToken == nil) != (token == nil) else {
            throw DesktopProtocolError.invalidMessage("authentication")
        }
        try DesktopSecret.validate(invitationToken ?? token ?? "")
    }
}

public struct DesktopPairingApproval: Codable, Equatable, Sendable {
    public var hostName: String
    public var token: String
    public var psk: Data
    public init(hostName: String, token: String, psk: Data) {
        self.hostName = hostName
        self.token = token
        self.psk = psk
    }
}

public struct DesktopSessionInfo: Codable, Equatable, Sendable {
    public var hostName: String
    public var width: Int
    public var height: Int
    public var canControl: Bool
    public init(hostName: String, width: Int, height: Int, canControl: Bool) {
        self.hostName = hostName
        self.width = width
        self.height = height
        self.canControl = canControl
    }
}

public struct DesktopFrame: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var jpeg: Data
    public init(width: Int, height: Int, jpeg: Data) {
        self.width = width
        self.height = height
        self.jpeg = jpeg
    }

    public func validate() throws {
        try validateDesktopDimensions(width, height)
        guard jpeg.count >= 4, jpeg.count <= DesktopProtocol.maximumJPEGBytes,
              jpeg.prefix(2) == Data([0xff, 0xd8]), jpeg.suffix(2) == Data([0xff, 0xd9]) else {
            throw DesktopProtocolError.invalidMessage("JPEG")
        }
    }
}

public enum DesktopMouseButton: Int, Codable, Equatable, Sendable {
    case left = 0, right = 1, center = 2
}

public enum DesktopInput: Codable, Equatable, Sendable {
    case pointer(x: Double, y: Double, button: DesktopMouseButton? = nil, isDown: Bool? = nil)
    case scroll(x: Double, y: Double, deltaX: Double, deltaY: Double)
    case key(keyCode: UInt16, isDown: Bool, modifiers: UInt64)
    case releaseAll

    public func validate() throws {
        switch self {
        case .pointer(let x, let y, let button, let isDown):
            try validateDesktopCoordinates(x, y)
            guard (button == nil) == (isDown == nil) else {
                throw DesktopProtocolError.invalidMessage("mouse button")
            }
        case .scroll(let x, let y, let deltaX, let deltaY):
            try validateDesktopCoordinates(x, y)
            guard deltaX.isFinite, deltaY.isFinite, abs(deltaX) <= 10_000, abs(deltaY) <= 10_000 else {
                throw DesktopProtocolError.invalidMessage("scroll delta")
            }
        case .key(let keyCode, _, let modifiers):
            guard keyCode <= 127, modifiers & ~UInt64(0x00ff0000) == 0 else {
                throw DesktopProtocolError.invalidMessage("keyboard event")
            }
        case .releaseAll: break
        }
    }
}

public enum RemoteDesktopMessage: Codable, Equatable, Sendable {
    case hello(DesktopHello)
    case authenticate(DesktopAuthentication)
    case pairingPending
    case pairingApproved(DesktopPairingApproval)
    case ready(DesktopSessionInfo)
    case frame(DesktopFrame)
    case input(DesktopInput)
    case sessionEnded(DesktopSessionEnd)
    case goodbye(String)
    case error(String)
    case ping(UInt64)
    case pong(UInt64)

    public func validate() throws {
        switch self {
        case .hello(let hello):
            guard hello.protocolVersion == DesktopProtocol.version else { throw DesktopProtocolError.unsupportedVersion }
            try validateDesktopText(hello.hostName, maximumBytes: 256)
        case .authenticate(let authentication): try authentication.validate()
        case .pairingApproved(let approval):
            try validateDesktopText(approval.hostName, maximumBytes: 256)
            try DesktopSecret.validate(approval.token)
            guard approval.psk.count == 32 else { throw DesktopProtocolError.invalidSecret }
        case .ready(let session):
            try validateDesktopText(session.hostName, maximumBytes: 256)
            try validateDesktopDimensions(session.width, session.height)
        case .frame(let frame): try frame.validate()
        case .input(let input): try input.validate()
        case .sessionEnded(let end): try validateDesktopText(end.message, maximumBytes: 2_048)
        case .goodbye(let reason), .error(let reason): try validateDesktopText(reason, maximumBytes: 2_048)
        case .pairingPending, .ping, .pong: break
        }
    }
}

private func validateDesktopCoordinates(_ x: Double, _ y: Double) throws {
    guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
        throw DesktopProtocolError.invalidMessage("pointer coordinates")
    }
}

func validateDesktopDimensions(_ width: Int, _ height: Int) throws {
    guard (1...DesktopProtocol.maximumDimension).contains(width),
          (1...DesktopProtocol.maximumDimension).contains(height) else {
        throw DesktopProtocolError.invalidMessage("display dimensions")
    }
}

func validateDesktopText(_ text: String, maximumBytes: Int) throws {
    guard !text.isEmpty, text.utf8.count <= maximumBytes,
          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw DesktopProtocolError.invalidMessage("text")
    }
}
