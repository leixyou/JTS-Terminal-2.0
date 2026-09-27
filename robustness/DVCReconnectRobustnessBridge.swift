import CryptoKit
import Foundation

/// Minimal declaration required to compile the production pure reconnect
/// reducer without pulling UI, persistence, or XPC code into the robustness target.
nonisolated enum RDPConnectionPhase: String, Codable, Equatable, Sendable {
    case closed
    case connecting
    case awaitingCertificateTrust
    case authenticating
    case connected
    case reconnecting
    case failed
}

@_cdecl("JTSRobustnessSwiftDVCAndReconnect")
public func JTSRobustnessSwiftDVCAndReconnect(
    _ bytes: UnsafePointer<UInt8>?,
    _ count: Int
) -> Int32 {
    guard let bytes, count > 0, count <= 16 * 1_024 * 1_024 else {
        return 0
    }

    autoreleasepool {
        let rawInput = Data(bytes: bytes, count: count)
        let input = decodeHexCorpusEnvelope(rawInput) ?? rawInput
        guard let selector = input.first else { return }
        let payload = Data(input.dropFirst())

        switch selector & 0x07 {
        case 0:
            exerciseDVCWireCodec(payload)
        case 1:
            exerciseDVCIncrementalCodec(payload)
        case 2:
            exerciseReconnectStateMachine(payload)
        case 3:
            exerciseDVCWireCodec(payload)
            exerciseDVCIncrementalCodec(payload)
            exerciseReconnectStateMachine(payload)
            exerciseBinaryReassembler(payload)
        case 4:
            exerciseBinaryReassembler(payload)
        default:
            exerciseDVCWireCodec(payload)
            exerciseDVCIncrementalCodec(payload)
            exerciseReconnectStateMachine(payload)
            exerciseBinaryReassembler(payload)
        }
    }
    return 0
}

private func exerciseDVCWireCodec(_ input: Data) {
    do {
        let result = try DVCWireCodec.decodeAvailable(from: input)
        exerciseDecodedFrames(result.frames)

        // A retained partial tail must be safe to pass back through the same
        // parser and through the incremental buffering path.
        _ = try? DVCWireCodec.decodeAvailable(from: result.remainder)
        var decoder = DVCIncrementalDecoder()
        _ = try? decoder.append(result.remainder)
    } catch {
        // Protocol rejection is an expected outcome. Sanitizer findings,
        // traps, and invariant failures remain process-fatal.
    }
}

private func exerciseDVCIncrementalCodec(_ input: Data) {
    var decoder = DVCIncrementalDecoder()
    var decodedFrames: [DVCFrame] = []
    var cursor = 0

    do {
        while cursor < input.count {
            let requestedChunk = Int(input[input.index(input.startIndex, offsetBy: cursor)] & 0x1F) + 1
            let chunkLength = min(requestedChunk, input.count - cursor)
            let lower = input.index(input.startIndex, offsetBy: cursor)
            let upper = input.index(lower, offsetBy: chunkLength)
            decodedFrames.append(contentsOf: try decoder.append(Data(input[lower..<upper])))
            cursor += chunkLength
        }
        exerciseDecodedFrames(decodedFrames)
    } catch {
        // Malformed, oversized, replayed, and out-of-order inputs are expected.
    }
}

private func exerciseDecodedFrames(_ frames: [DVCFrame]) {
    var replayGuard = DVCSequenceReplayGuard()
    for frame in frames {
        do {
            try replayGuard.accept(frame.sequence)
        } catch {
            continue
        }

        switch frame {
        case .control(let control):
            _ = try? control.decodeRequest()
            _ = try? control.decodeResponse()
        case .binary(let binary):
            _ = try? binary.validate()
        case .ping(let heartbeat), .pong(let heartbeat):
            _ = try? heartbeat.validate()
        }

        if let encoded = try? DVCWireCodec.encode(frame),
           let roundTrip = try? DVCWireCodec.decodeAvailable(from: encoded) {
            precondition(roundTrip.remainder.isEmpty)
            precondition(roundTrip.frames == [frame])
        }
    }
}

private func exerciseBinaryReassembler(_ input: Data) {
    let transferID = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    let maximumBytes: Int64 = 256 * 1_024
    let maximumChunkBytes = 64 * 1_024
    let canonicalPayload = Data(input.prefix(Int(maximumBytes)))
    let canonicalDescriptor = DVCBinaryTransferDescriptor(
        transferID: transferID,
        purpose: "robustness",
        totalBytes: Int64(canonicalPayload.count),
        sha256: SHA256.hash(data: canonicalPayload).map { String(format: "%02x", $0) }.joined()
    )

    // Every input gets one valid end-to-end path so mutations do not starve
    // digest/finalization coverage behind descriptor checks.
    if var canonical = try? DVCBinaryReassembler(
        descriptor: canonicalDescriptor,
        maximumBytes: maximumBytes,
        maximumChunkBytes: maximumChunkBytes
    ) {
        if canonicalPayload.isEmpty {
            try? canonical.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 1,
                offset: 0,
                data: Data(),
                isFinal: true
            ))
        } else {
            var offset = 0
            var sequence: UInt64 = 1
            while offset < canonicalPayload.count {
                let end = min(offset + maximumChunkBytes, canonicalPayload.count)
                try? canonical.accept(DVCBinaryFrame(
                    transferID: transferID,
                    sequence: sequence,
                    offset: Int64(offset),
                    data: canonicalPayload.subdata(in: offset..<end),
                    isFinal: end == canonicalPayload.count
                ))
                offset = end
                sequence &+= 1
            }
        }
        if let verified = try? canonical.verifiedData() {
            precondition(verified == canonicalPayload)
        }
    }

    var cursor = RobustnessCursor(input)
    let totalBytes: Int64
    switch cursor.next() % 6 {
    case 0:
        totalBytes = -1
    case 1:
        totalBytes = Int64.max
    case 2:
        totalBytes = Int64(canonicalPayload.count)
    default:
        totalBytes = Int64(cursor.nextUInt32() % UInt32(maximumBytes + 1))
    }
    let advertisedDigest: String
    switch cursor.next() % 4 {
    case 0:
        advertisedDigest = "invalid"
    case 1:
        advertisedDigest = String(repeating: "0", count: 64)
    default:
        advertisedDigest = canonicalDescriptor.sha256
    }
    let descriptor = DVCBinaryTransferDescriptor(
        transferID: transferID,
        purpose: "robustness-arbitrary",
        totalBytes: totalBytes,
        sha256: advertisedDigest
    )
    guard var reassembler = try? DVCBinaryReassembler(
        descriptor: descriptor,
        maximumBytes: maximumBytes,
        maximumChunkBytes: maximumChunkBytes
    ) else {
        return
    }

    var operationCount = 0
    while !cursor.isAtEnd, operationCount < 256 {
        operationCount += 1
        if cursor.next() % 5 == 0 {
            _ = try? reassembler.verifiedData()
            continue
        }

        let offset: Int64
        switch cursor.next() % 7 {
        case 0:
            offset = Int64(reassembler.receivedByteCount)
        case 1:
            offset = 0
        case 2:
            offset = max(0, Int64(reassembler.receivedByteCount) - 1)
        case 3:
            offset = descriptor.totalBytes
        case 4:
            offset = -1
        case 5:
            offset = Int64.max
        default:
            offset = Int64(bitPattern: cursor.nextUInt64())
        }
        let frame = DVCBinaryFrame(
            transferID: cursor.next().isMultiple(of: 5) ? UUID() : transferID,
            sequence: max(1, cursor.nextUInt64()),
            offset: offset,
            data: cursor.nextData(maximum: maximumChunkBytes + 1),
            isFinal: cursor.next().isMultiple(of: 2)
        )
        _ = try? reassembler.accept(frame)
    }
    _ = try? reassembler.verifiedData()
}

private func exerciseReconnectStateMachine(_ input: Data) {
    var cursor = RobustnessCursor(input)
    let maximumAttempts = Int(cursor.next() % 8)
    let initialDelay = TimeInterval(cursor.next() % 5)
    let maximumDelay = TimeInterval(cursor.next() % 33)
    var supervisor = RDPReconnectSupervisor(policy: RDPReconnectPolicy(
        maximumAttempts: maximumAttempts,
        initialDelaySeconds: initialDelay,
        maximumDelaySeconds: maximumDelay
    ))
    var observedSchedules: [RDPReconnectSchedule] = []
    let phases: [RDPConnectionPhase] = [
        .closed,
        .connecting,
        .awaitingCertificateTrust,
        .authenticating,
        .connected,
        .reconnecting,
        .failed,
    ]
    let failureCodes: [String?] = [
        nil,
        "RDP_CONNECTION_LOST",
        "RDP_XPC_INVALIDATED",
        "ERRCONNECT_CONNECT_FAILED",
        "AUTH_FAILED",
        "CERT_REJECTED",
        "RDP_CONNECT_CANCELLED",
        "RESOLUTION_INVALID",
    ]

    while !cursor.isAtEnd {
        switch cursor.next() % 8 {
        case 0, 1:
            let phase = phases[Int(cursor.next()) % phases.count]
            let code = failureCodes[Int(cursor.next()) % failureCodes.count]
            let timestamp = TimeInterval(cursor.nextUInt32())
            let plan = supervisor.plan(
                after: RDPReconnectFailure(phase: phase, code: code, message: "robustness"),
                now: Date(timeIntervalSince1970: timestamp)
            )
            if case .scheduled(let schedule) = plan {
                observedSchedules.append(schedule)
            }
        case 2:
            guard !observedSchedules.isEmpty else { continue }
            let index = Int(cursor.next()) % observedSchedules.count
            _ = supervisor.begin(observedSchedules[index])
        case 3:
            let staleSchedules = observedSchedules
            supervisor.stop()
            precondition(!supervisor.hasPendingAttempt)
            precondition(supervisor.attemptCount == 0)
            for schedule in staleSchedules.suffix(4) {
                precondition(!supervisor.begin(schedule))
            }
            let stoppedPlan = supervisor.plan(
                after: RDPReconnectFailure(
                    phase: .failed,
                    code: "RDP_CONNECTION_LOST",
                    message: "late disconnect"
                ),
                now: Date(timeIntervalSince1970: 0)
            )
            precondition(stoppedPlan == .stopped)
        case 4:
            let staleSchedules = observedSchedules
            supervisor.markConnected()
            precondition(!supervisor.hasPendingAttempt)
            precondition(supervisor.attemptCount == 0)
            for schedule in staleSchedules.suffix(4) {
                precondition(!supervisor.begin(schedule))
            }
        case 5:
            supervisor.block(after: RDPReconnectFailure(
                phase: .awaitingCertificateTrust,
                code: "CERT_DECISION_REQUIRED",
                message: "robustness"
            ))
            precondition(!supervisor.hasPendingAttempt)
        case 6:
            _ = supervisor.plan(
                after: RDPReconnectFailure(
                    phase: .failed,
                    code: "AUTH_FAILED",
                    message: "robustness"
                ),
                now: Date(timeIntervalSince1970: 0)
            )
        default:
            _ = supervisor.plan(
                after: RDPReconnectFailure(
                    phase: .failed,
                    code: "RDP_CONNECTION_LOST",
                    message: "robustness"
                ),
                now: Date(timeIntervalSince1970: 0)
            )
        }

        precondition(supervisor.attemptCount >= 0)
        precondition(supervisor.attemptCount <= maximumAttempts)
        switch supervisor.status {
        case .blocked, .exhausted, .idle, .stopped:
            precondition(!supervisor.hasPendingAttempt)
        case .scheduled, .reconnecting:
            precondition(supervisor.hasPendingAttempt)
        }
    }
}

private func decodeHexCorpusEnvelope(_ input: Data) -> Data? {
    guard input.starts(with: Data("hex:".utf8)),
          let text = String(data: input.dropFirst(4), encoding: .utf8) else {
        return nil
    }
    let digits = text.filter { !$0.isWhitespace }
    guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }

    var output = Data(capacity: digits.count / 2)
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
        output.append(byte)
        index = next
    }
    return output
}

private struct RobustnessCursor {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func next() -> UInt8 {
        guard offset < bytes.count else { return 0 }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func nextUInt32() -> UInt32 {
        (0..<4).reduce(UInt32.zero) { value, _ in
            value << 8 | UInt32(next())
        }
    }

    mutating func nextUInt64() -> UInt64 {
        (0..<8).reduce(UInt64.zero) { value, _ in
            value << 8 | UInt64(next())
        }
    }

    mutating func nextData(maximum: Int) -> Data {
        guard maximum > 0 else { return Data() }
        let requested = Int(nextUInt32() % UInt32(maximum + 1))
        let length = min(requested, bytes.count - offset)
        guard length > 0 else { return Data() }
        defer { offset += length }
        return Data(bytes[offset..<(offset + length)])
    }
}
