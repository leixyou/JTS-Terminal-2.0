#if ENABLE_RDP_2
import CryptoKit
import Foundation

nonisolated enum WindowsCompanionDVC {
    static let channelName = "JTS.Companion.v1"
    static let protocolVersion = 1
    static let headerLength = 24
    static let maximumControlPayloadBytes = 1 * 1_024 * 1_024
    static let maximumBinaryPayloadBytes = 8 * 1_024 * 1_024
    static let maximumBufferedBytes = maximumBinaryPayloadBytes + headerLength
    static let authenticationEnvelopeLength = 4 + 64
    static let maximumAuthenticatedControlPayloadBytes =
        maximumControlPayloadBytes - authenticationEnvelopeLength
    static let maximumAuthenticatedBinaryPayloadBytes =
        maximumBinaryPayloadBytes - authenticationEnvelopeLength

    // Compatibility aliases for callers that used the pre-interoperability codec.
    static let maximumBinaryChunkBytes =
        maximumAuthenticatedBinaryPayloadBytes - DVCBinaryFrame.payloadHeaderLength
    static let maximumWirePayloadBytes = maximumBinaryPayloadBytes
}

nonisolated enum DVCOperation: String, CaseIterable, Codable, Sendable {
    case companionHello = "companion.hello"
    case companionAuthorize = "companion.authorize"
    case companionState = "companion.state"
    case companionUnpair = "companion.unpair"
    case companionCancel = "companion.cancel"
    case companionCancelPending = "companion.cancelPending"
    case uiaSnapshot = "uia.snapshot"
    case uiaFind = "uia.find"
    case uiaInvoke = "uia.invoke"
    case uiaSetValue = "uia.setValue"
    case uiaWait = "uia.wait"
    case shellExec = "shell.exec"
    case filesList = "files.list"
    case filesStat = "files.stat"
    case filesRead = "files.read"
    case filesWrite = "files.write"
    case filesUpload = "files.upload"
    case filesDownload = "files.download"
    case workerDoctor = "worker.doctor"
    case workerSubmit = "worker.submit"
    case workerStatus = "worker.status"
    case workerCancel = "worker.cancel"
    case workerCollect = "worker.collect"
    case transferBegin = "transfer.begin"
    case transferFinalize = "transfer.finalize"
    case transferDownload = "transfer.download"
    case transferRelease = "transfer.release"
    case elevationRequest = "elevation.request"
    case elevationStatus = "elevation.status"
    case elevationRelease = "elevation.release"
}

nonisolated struct DVCFrameFlags: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let final = DVCFrameFlags(rawValue: 1 << 0)
    static let error = DVCFrameFlags(rawValue: 1 << 1)
    /// Set only when the wire payload carries a `JTSA` P-256 signature envelope.
    static let authenticated = DVCFrameFlags(rawValue: 1 << 7)
}

nonisolated struct DVCFrameAuthenticationEnvelope: Equatable, Sendable {
    static let magic = Data("JTSA".utf8)
    static let signatureLength = 64

    var signature: Data

    init(signature: Data) throws {
        guard signature.count == Self.signatureLength else {
            throw DVCProtocolError.invalidFrameAuthentication
        }
        self.signature = signature
    }
}

/// The payload is the exact UTF-8 JSON consumed by the .NET
/// `ControlMessageSerializer`. It is not wrapped in a second Swift-only JSON
/// envelope.
nonisolated struct DVCControlFrame: Equatable, Sendable {
    var protocolVersion: Int
    var sequence: UInt64
    var flags: DVCFrameFlags
    var payloadJSON: Data
    var authentication: DVCFrameAuthenticationEnvelope?

    init(
        protocolVersion: Int = WindowsCompanionDVC.protocolVersion,
        sequence: UInt64,
        flags: DVCFrameFlags = .final,
        payloadJSON: Data,
        authentication: DVCFrameAuthenticationEnvelope? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.flags = flags
        self.payloadJSON = payloadJSON
        self.authentication = authentication
    }

    init(request: DVCCompanionRequest, sequence: UInt64, flags: DVCFrameFlags = .final) throws {
        self.init(
            protocolVersion: request.protocolVersion,
            sequence: sequence,
            flags: flags,
            payloadJSON: try DVCControlMessageCodec.encode(request)
        )
    }

    init(response: DVCCompanionResponse, sequence: UInt64, flags: DVCFrameFlags = .final) throws {
        self.init(
            protocolVersion: response.protocolVersion,
            sequence: sequence,
            flags: flags,
            payloadJSON: try DVCControlMessageCodec.encode(response)
        )
    }

    func decodeRequest() throws -> DVCCompanionRequest {
        try DVCControlMessageCodec.decode(DVCCompanionRequest.self, from: payloadJSON)
    }

    func decodeResponse() throws -> DVCCompanionResponse {
        try DVCControlMessageCodec.decode(DVCCompanionResponse.self, from: payloadJSON)
    }

    func validate() throws {
        try DVCProtocolValidation.validateVersion(protocolVersion)
        try DVCProtocolValidation.validateSequence(sequence)
        let maximum = authentication == nil
            ? WindowsCompanionDVC.maximumControlPayloadBytes
            : WindowsCompanionDVC.maximumAuthenticatedControlPayloadBytes
        guard payloadJSON.count <= maximum else {
            throw DVCProtocolError.payloadTooLarge(payloadJSON.count)
        }
        guard (try? JSONSerialization.jsonObject(with: payloadJSON, options: .fragmentsAllowed)) != nil else {
            throw DVCProtocolError.invalidJSONPayload
        }
    }
}

/// Matches the Windows `BinaryChunkCodec` payload byte-for-byte. UUID bytes use
/// the mixed-endian layout emitted by `Guid.TryWriteBytes` on .NET.
nonisolated struct DVCBinaryFrame: Equatable, Sendable {
    static let payloadHeaderLength = 16 + 8 + 1 + 4 + 32

    var protocolVersion: Int
    var transferID: UUID
    var sequence: UInt64
    var flags: DVCFrameFlags
    var offset: Int64
    var data: Data
    var isFinal: Bool
    var authentication: DVCFrameAuthenticationEnvelope?

    init(
        protocolVersion: Int = WindowsCompanionDVC.protocolVersion,
        transferID: UUID,
        sequence: UInt64,
        flags: DVCFrameFlags = .final,
        offset: Int64,
        data: Data,
        isFinal: Bool,
        authentication: DVCFrameAuthenticationEnvelope? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.transferID = transferID
        self.sequence = sequence
        self.flags = flags
        self.offset = offset
        self.data = data
        self.isFinal = isFinal
        self.authentication = authentication
    }

    var chunkSHA256: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        try DVCProtocolValidation.validateVersion(protocolVersion)
        try DVCProtocolValidation.validateSequence(sequence)
        guard offset >= 0 else {
            throw DVCProtocolError.invalidBinaryRange
        }
        let payloadBytes = Self.payloadHeaderLength + data.count
        let maximum = authentication == nil
            ? WindowsCompanionDVC.maximumBinaryPayloadBytes
            : WindowsCompanionDVC.maximumAuthenticatedBinaryPayloadBytes
        guard payloadBytes <= maximum else {
            throw DVCProtocolError.payloadTooLarge(payloadBytes)
        }
    }
}

nonisolated struct DVCHeartbeatFrame: Equatable, Sendable {
    var protocolVersion: Int
    var sequence: UInt64
    var flags: DVCFrameFlags
    var payload: Data
    var authentication: DVCFrameAuthenticationEnvelope?

    init(
        protocolVersion: Int = WindowsCompanionDVC.protocolVersion,
        sequence: UInt64,
        flags: DVCFrameFlags = .final,
        payload: Data = Data(),
        authentication: DVCFrameAuthenticationEnvelope? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.flags = flags
        self.payload = payload
        self.authentication = authentication
    }

    func validate() throws {
        try DVCProtocolValidation.validateVersion(protocolVersion)
        try DVCProtocolValidation.validateSequence(sequence)
        let maximum = authentication == nil
            ? WindowsCompanionDVC.maximumControlPayloadBytes
            : WindowsCompanionDVC.maximumAuthenticatedControlPayloadBytes
        guard payload.count <= maximum else {
            throw DVCProtocolError.payloadTooLarge(payload.count)
        }
    }
}

nonisolated enum DVCFrame: Equatable, Sendable {
    case control(DVCControlFrame)
    case binary(DVCBinaryFrame)
    case ping(DVCHeartbeatFrame)
    case pong(DVCHeartbeatFrame)

    var sequence: UInt64 {
        switch self {
        case .control(let frame): frame.sequence
        case .binary(let frame): frame.sequence
        case .ping(let frame): frame.sequence
        case .pong(let frame): frame.sequence
        }
    }

    var authentication: DVCFrameAuthenticationEnvelope? {
        switch self {
        case .control(let frame): frame.authentication
        case .binary(let frame): frame.authentication
        case .ping(let frame): frame.authentication
        case .pong(let frame): frame.authentication
        }
    }
}

nonisolated enum DVCProtocolError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case unknownFrameKind(UInt8)
    case invalidMagic
    case invalidSequence
    case replayRejected(sequence: UInt64, lastAccepted: UInt64)
    case invalidJSONPayload
    case invalidJSONValue
    case invalidBinaryRange
    case invalidBinaryDigest
    case invalidFrameDigest
    case invalidFrameLength
    case invalidFrameAuthentication
    case missingFrameAuthentication
    case payloadTooLarge(Int)
    case bufferLimitExceeded
    case malformedFrame

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported Windows Companion DVC protocol version: \(version)."
        case .unknownFrameKind(let kind):
            return "Unknown Windows Companion DVC frame kind: \(kind)."
        case .invalidMagic:
            return "Windows Companion DVC frame magic is invalid."
        case .invalidSequence:
            return "Windows Companion DVC sequence numbers must be positive."
        case .replayRejected(let sequence, let lastAccepted):
            return "Windows Companion DVC sequence \(sequence) was already used or is older than the last accepted sequence \(lastAccepted)."
        case .invalidJSONPayload:
            return "Windows Companion DVC control payload is not valid JSON."
        case .invalidJSONValue:
            return "Windows Companion DVC JSON contains an unsupported value."
        case .invalidBinaryRange:
            return "Windows Companion DVC binary chunk range is invalid."
        case .invalidBinaryDigest:
            return "Windows Companion DVC binary chunk digest is invalid."
        case .invalidFrameDigest:
            return "Windows Companion DVC frame payload digest is invalid."
        case .invalidFrameLength:
            return "Windows Companion DVC frame length is invalid."
        case .invalidFrameAuthentication:
            return "Windows Companion DVC frame authentication is invalid."
        case .missingFrameAuthentication:
            return "Windows Companion DVC frame authentication is required for this session."
        case .payloadTooLarge(let bytes):
            return "Windows Companion DVC payload is too large (\(bytes) bytes)."
        case .bufferLimitExceeded:
            return "Windows Companion DVC frame buffer limit was exceeded."
        case .malformedFrame:
            return "Windows Companion DVC frame is malformed."
        }
    }
}

/// Rejects duplicate and out-of-order frames for one connected DVC session.
/// The Windows Companion uses the same rule for frames received from the Mac,
/// so both directions fail closed against replayed wire data.
nonisolated struct DVCSequenceReplayGuard: Sendable {
    private(set) var lastAccepted: UInt64 = 0

    mutating func accept(_ sequence: UInt64) throws {
        guard sequence > lastAccepted else {
            throw DVCProtocolError.replayRejected(
                sequence: sequence,
                lastAccepted: lastAccepted
            )
        }
        lastAccepted = sequence
    }
}

/// The 24-byte header is shared with `CompanionFrameCodec` in the .NET
/// Companion:
///
/// `JTSD | UInt16BE version | UInt8 type | UInt8 flags | UInt64BE sequence |
///  Int32BE payloadLength | SHA256(payload)[0...3]`
///
/// The incremental decoder retains a partial tail so DVC packets may be split
/// at arbitrary boundaries.
nonisolated enum DVCWireCodec {
    private static let magic = Data("JTSD".utf8)
    private static let controlKind: UInt8 = 1
    private static let binaryKind: UInt8 = 2
    private static let pingKind: UInt8 = 3
    private static let pongKind: UInt8 = 4

    static func encode(_ frame: DVCFrame) throws -> Data {
        let metadata = try applicationMetadata(for: frame)
        let payload = try wirePayload(
            applicationPayload: metadata.payload,
            flags: metadata.flags,
            authentication: frame.authentication
        )
        try validatePayloadLength(payload.count, kind: metadata.kind)
        guard metadata.version <= Int(UInt16.max), payload.count <= Int(Int32.max) else {
            throw DVCProtocolError.malformedFrame
        }

        var output = Data(capacity: WindowsCompanionDVC.headerLength + payload.count)
        output.append(magic)
        output.appendBigEndian(UInt16(metadata.version))
        output.append(metadata.kind)
        output.append(metadata.flags.rawValue)
        output.appendBigEndian(metadata.sequence)
        output.appendBigEndian(Int32(payload.count))
        output.append(contentsOf: SHA256.hash(data: payload).prefix(4))
        output.append(payload)
        return output
    }

    static func decodeAvailable(from data: Data) throws -> (frames: [DVCFrame], remainder: Data) {
        var frames: [DVCFrame] = []
        var offset = 0

        while data.count - offset >= WindowsCompanionDVC.headerLength {
            guard data.bytes(in: offset..<(offset + 4)) == magic else {
                throw DVCProtocolError.invalidMagic
            }

            let version = Int(data.readUInt16BigEndian(at: offset + 4))
            try DVCProtocolValidation.validateVersion(version)
            let kind = data.byte(at: offset + 6)
            guard [controlKind, binaryKind, pingKind, pongKind].contains(kind) else {
                throw DVCProtocolError.unknownFrameKind(kind)
            }
            let flags = DVCFrameFlags(rawValue: data.byte(at: offset + 7))
            let sequence = data.readUInt64BigEndian(at: offset + 8)
            try DVCProtocolValidation.validateSequence(sequence)

            let encodedLength = data.readUInt32BigEndian(at: offset + 16)
            guard encodedLength <= UInt32(Int32.max) else {
                throw DVCProtocolError.invalidFrameLength
            }
            let length = Int(encodedLength)
            try validatePayloadLength(length, kind: kind)

            let (frameEnd, overflow) = offset
                .addingReportingOverflow(WindowsCompanionDVC.headerLength + length)
            guard !overflow else {
                throw DVCProtocolError.invalidFrameLength
            }
            guard frameEnd <= data.count else {
                break
            }

            let payloadStart = offset + WindowsCompanionDVC.headerLength
            let wirePayload = data.bytes(in: payloadStart..<frameEnd)
            let expectedDigest = data.bytes(in: (offset + 20)..<(offset + 24))
            let actualDigest = Data(SHA256.hash(data: wirePayload).prefix(4))
            guard constantTimeEqual(expectedDigest, actualDigest) else {
                throw DVCProtocolError.invalidFrameDigest
            }

            let unwrapped = try unwrapWirePayload(wirePayload, flags: flags)
            let payload = unwrapped.applicationPayload
            switch kind {
            case controlKind:
                let frame = DVCControlFrame(
                    protocolVersion: version,
                    sequence: sequence,
                    flags: flags,
                    payloadJSON: payload,
                    authentication: unwrapped.authentication
                )
                try frame.validate()
                frames.append(.control(frame))
            case binaryKind:
                frames.append(.binary(try decodeBinaryPayload(
                    payload,
                    protocolVersion: version,
                    sequence: sequence,
                    flags: flags,
                    authentication: unwrapped.authentication
                )))
            case pingKind:
                frames.append(.ping(DVCHeartbeatFrame(
                    protocolVersion: version,
                    sequence: sequence,
                    flags: flags,
                    payload: payload,
                    authentication: unwrapped.authentication
                )))
            case pongKind:
                frames.append(.pong(DVCHeartbeatFrame(
                    protocolVersion: version,
                    sequence: sequence,
                    flags: flags,
                    payload: payload,
                    authentication: unwrapped.authentication
                )))
            default:
                throw DVCProtocolError.unknownFrameKind(kind)
            }
            offset = frameEnd
        }

        return (frames, data.bytes(in: offset..<data.count))
    }

    private static func validatePayloadLength(_ length: Int, kind: UInt8) throws {
        let maximum = kind == binaryKind
            ? WindowsCompanionDVC.maximumBinaryPayloadBytes
            : WindowsCompanionDVC.maximumControlPayloadBytes
        guard length >= 0, length <= maximum else {
            throw DVCProtocolError.payloadTooLarge(length)
        }
    }

    static func applicationMetadata(
        for frame: DVCFrame
    ) throws -> (version: Int, kind: UInt8, flags: DVCFrameFlags, sequence: UInt64, payload: Data) {
        switch frame {
        case .control(let control):
            try control.validate()
            return (control.protocolVersion, controlKind, control.flags, control.sequence, control.payloadJSON)
        case .binary(let binary):
            try binary.validate()
            return (
                binary.protocolVersion,
                binaryKind,
                binary.flags,
                binary.sequence,
                try encodeBinaryPayload(binary)
            )
        case .ping(let heartbeat):
            try heartbeat.validate()
            return (heartbeat.protocolVersion, pingKind, heartbeat.flags, heartbeat.sequence, heartbeat.payload)
        case .pong(let heartbeat):
            try heartbeat.validate()
            return (heartbeat.protocolVersion, pongKind, heartbeat.flags, heartbeat.sequence, heartbeat.payload)
        }
    }

    private static func wirePayload(
        applicationPayload: Data,
        flags: DVCFrameFlags,
        authentication: DVCFrameAuthenticationEnvelope?
    ) throws -> Data {
        guard flags.contains(.authenticated) == (authentication != nil) else {
            throw DVCProtocolError.invalidFrameAuthentication
        }
        guard let authentication else { return applicationPayload }
        var payload = Data(capacity: WindowsCompanionDVC.authenticationEnvelopeLength + applicationPayload.count)
        payload.append(DVCFrameAuthenticationEnvelope.magic)
        payload.append(authentication.signature)
        payload.append(applicationPayload)
        return payload
    }

    private static func unwrapWirePayload(
        _ payload: Data,
        flags: DVCFrameFlags
    ) throws -> (applicationPayload: Data, authentication: DVCFrameAuthenticationEnvelope?) {
        guard flags.contains(.authenticated) else {
            return (payload, nil)
        }
        guard payload.count >= WindowsCompanionDVC.authenticationEnvelopeLength,
              payload.bytes(in: 0..<4) == DVCFrameAuthenticationEnvelope.magic else {
            throw DVCProtocolError.invalidFrameAuthentication
        }
        return (
            payload.bytes(in: WindowsCompanionDVC.authenticationEnvelopeLength..<payload.count),
            try DVCFrameAuthenticationEnvelope(signature: payload.bytes(in: 4..<68))
        )
    }

    private static func encodeBinaryPayload(_ frame: DVCBinaryFrame) throws -> Data {
        var payload = Data(capacity: DVCBinaryFrame.payloadHeaderLength + frame.data.count)
        payload.append(contentsOf: DotNetGuidCodec.encode(frame.transferID))
        payload.appendBigEndian(frame.offset)
        payload.append(frame.isFinal ? 1 : 0)
        payload.appendBigEndian(Int32(frame.data.count))
        payload.append(contentsOf: SHA256.hash(data: frame.data))
        payload.append(frame.data)
        return payload
    }

    private static func decodeBinaryPayload(
        _ payload: Data,
        protocolVersion: Int,
        sequence: UInt64,
        flags: DVCFrameFlags,
        authentication: DVCFrameAuthenticationEnvelope?
    ) throws -> DVCBinaryFrame {
        guard payload.count >= DVCBinaryFrame.payloadHeaderLength else {
            throw DVCProtocolError.invalidFrameLength
        }
        let encodedLength = payload.readUInt32BigEndian(at: 25)
        guard encodedLength <= UInt32(Int32.max) else {
            throw DVCProtocolError.invalidFrameLength
        }
        let dataLength = Int(encodedLength)
        guard DVCBinaryFrame.payloadHeaderLength + dataLength == payload.count else {
            throw DVCProtocolError.invalidFrameLength
        }
        let finalByte = payload.byte(at: 24)
        guard finalByte == 0 || finalByte == 1 else {
            throw DVCProtocolError.malformedFrame
        }
        let chunk = payload.bytes(in: DVCBinaryFrame.payloadHeaderLength..<payload.count)
        let expectedDigest = payload.bytes(in: 29..<(29 + 32))
        let actualDigest = Data(SHA256.hash(data: chunk))
        guard constantTimeEqual(expectedDigest, actualDigest) else {
            throw DVCProtocolError.invalidBinaryDigest
        }

        guard let transferID = DotNetGuidCodec.decode(payload.bytes(in: 0..<16)) else {
            throw DVCProtocolError.malformedFrame
        }
        let offsetBits = payload.readUInt64BigEndian(at: 16)
        let frame = DVCBinaryFrame(
            protocolVersion: protocolVersion,
            transferID: transferID,
            sequence: sequence,
            flags: flags,
            offset: Int64(bitPattern: offsetBits),
            data: chunk,
            isFinal: finalByte == 1,
            authentication: authentication
        )
        try frame.validate()
        return frame
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8.zero) { difference, pair in
            difference | (pair.0 ^ pair.1)
        } == 0
    }
}

nonisolated struct DVCIncrementalDecoder {
    private(set) var bufferedData = Data()

    mutating func append(_ data: Data) throws -> [DVCFrame] {
        guard data.count <= WindowsCompanionDVC.maximumBufferedBytes - bufferedData.count else {
            throw DVCProtocolError.bufferLimitExceeded
        }
        bufferedData.append(data)
        let decoded = try DVCWireCodec.decodeAvailable(from: bufferedData)
        bufferedData = decoded.remainder
        return decoded.frames
    }
}

private nonisolated enum DVCProtocolValidation {
    static func validateVersion(_ version: Int) throws {
        guard version == WindowsCompanionDVC.protocolVersion else {
            throw DVCProtocolError.unsupportedVersion(version)
        }
    }

    static func validateSequence(_ sequence: UInt64) throws {
        guard sequence > 0 else {
            throw DVCProtocolError.invalidSequence
        }
    }
}

private nonisolated enum DotNetGuidCodec {
    static func encode(_ uuid: UUID) -> [UInt8] {
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        return [
            bytes[3], bytes[2], bytes[1], bytes[0],
            bytes[5], bytes[4],
            bytes[7], bytes[6],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        ]
    }

    static func decode(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = Array(data)
        let networkBytes: [UInt8] = [
            bytes[3], bytes[2], bytes[1], bytes[0],
            bytes[5], bytes[4],
            bytes[7], bytes[6],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        ]
        let tuple: uuid_t = (
            networkBytes[0], networkBytes[1], networkBytes[2], networkBytes[3],
            networkBytes[4], networkBytes[5], networkBytes[6], networkBytes[7],
            networkBytes[8], networkBytes[9], networkBytes[10], networkBytes[11],
            networkBytes[12], networkBytes[13], networkBytes[14], networkBytes[15]
        )
        return UUID(uuid: tuple)
    }
}

private extension Data {
    nonisolated mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    nonisolated func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    nonisolated func bytes(in offsets: Range<Int>) -> Data {
        let lower = index(startIndex, offsetBy: offsets.lowerBound)
        let upper = index(startIndex, offsetBy: offsets.upperBound)
        return self[lower..<upper]
    }

    nonisolated func readUInt16BigEndian(at offset: Int) -> UInt16 {
        UInt16(byte(at: offset)) << 8 |
            UInt16(byte(at: offset + 1))
    }

    nonisolated func readUInt32BigEndian(at offset: Int) -> UInt32 {
        UInt32(byte(at: offset)) << 24 |
            UInt32(byte(at: offset + 1)) << 16 |
            UInt32(byte(at: offset + 2)) << 8 |
            UInt32(byte(at: offset + 3))
    }

    nonisolated func readUInt64BigEndian(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64.zero) { value, index in
            value << 8 | UInt64(byte(at: offset + index))
        }
    }
}

#endif
