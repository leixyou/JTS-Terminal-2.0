import CryptoKit
import Foundation

/// Minimal declaration required to compile the production binary-transfer
/// manager without pulling the complete Companion client and Keychain stack
/// into this standalone robustness executable.
nonisolated struct WindowsCompanionRequestFailure: LocalizedError, Sendable {
    var code: String
    var message: String
    var retryable: Bool

    var errorDescription: String? { "\(code): \(message)" }
}

private struct RobustnessSelfTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private enum RobustnessAssertions {
    private(set) static var count = 0

    static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        count += 1
        guard try condition() else {
            throw RobustnessSelfTestFailure(message: message)
        }
    }

    static func expectProtocolError(
        _ expected: DVCProtocolError,
        _ operation: () throws -> Void
    ) throws {
        count += 1
        do {
            try operation()
        } catch let error as DVCProtocolError {
            guard error == expected else {
                throw RobustnessSelfTestFailure(
                    message: "Expected \(expected), received \(error)."
                )
            }
            return
        }
        throw RobustnessSelfTestFailure(
            message: "Expected DVC protocol error \(expected)."
        )
    }

    static func expectReassemblyError(
        _ expected: DVCBinaryReassemblyError,
        _ operation: () throws -> Void
    ) throws {
        count += 1
        do {
            try operation()
        } catch let error as DVCBinaryReassemblyError {
            guard error == expected else {
                throw RobustnessSelfTestFailure(
                    message: "Expected \(expected), received \(error)."
                )
            }
            return
        }
        throw RobustnessSelfTestFailure(
            message: "Expected binary reassembly error \(expected)."
        )
    }

    static func expectRequestFailure(
        code: String,
        _ operation: () throws -> Void
    ) throws {
        count += 1
        do {
            try operation()
        } catch let error as WindowsCompanionRequestFailure {
            guard error.code == code else {
                throw RobustnessSelfTestFailure(
                    message: "Expected \(code), received \(error.code)."
                )
            }
            return
        }
        throw RobustnessSelfTestFailure(
            message: "Expected Companion request failure \(code)."
        )
    }
}

@main
@MainActor
private struct DVCBinaryChunkRobustnessSelfTest {
    private static let transferID = UUID(
        uuidString: "00112233-4455-6677-8899-aabbccddeeff"
    )!

    static func main() async throws {
        try exerciseWireCodecBoundaries()
        try exerciseSequenceAndReassembly()
        try await exerciseDisconnectCleanup()
        print(
            "DVC binary chunk robustness self-test passed: "
                + "\(RobustnessAssertions.count) assertions"
        )
    }

    private static func exerciseWireCodecBoundaries() throws {
        for data in [Data(), Data([0xA5])] {
            let frame = DVCBinaryFrame(
                transferID: transferID,
                sequence: 1,
                offset: Int64.max,
                data: data,
                isFinal: true
            )
            let encoded = try DVCWireCodec.encode(.binary(frame))
            let decoded = try DVCWireCodec.decodeAvailable(from: encoded)
            try RobustnessAssertions.require(
                decoded.frames == [.binary(frame)] && decoded.remainder.isEmpty,
                "Binary frame boundary round trip failed."
            )
        }

        let maximumData = Data(
            repeating: 0x5A,
            count: WindowsCompanionDVC.maximumBinaryChunkBytes
        )
        let authentication = try DVCFrameAuthenticationEnvelope(
            signature: Data(
                repeating: 0xA5,
                count: DVCFrameAuthenticationEnvelope.signatureLength
            )
        )
        let maximumFrame = DVCBinaryFrame(
            transferID: transferID,
            sequence: 2,
            flags: [.final, .authenticated],
            offset: 0,
            data: maximumData,
            isFinal: true,
            authentication: authentication
        )
        let maximumEncoded = try DVCWireCodec.encode(.binary(maximumFrame))
        try RobustnessAssertions.require(
            maximumEncoded.count
                == WindowsCompanionDVC.headerLength
                    + WindowsCompanionDVC.maximumBinaryPayloadBytes,
            "Authenticated maximum binary frame did not fill the exact wire boundary."
        )
        let maximumDecoded = try DVCWireCodec.decodeAvailable(from: maximumEncoded)
        try RobustnessAssertions.require(
            maximumDecoded.frames == [.binary(maximumFrame)]
                && maximumDecoded.remainder.isEmpty,
            "Authenticated maximum binary frame did not round trip."
        )
        try RobustnessAssertions.expectProtocolError(
            .payloadTooLarge(
                DVCBinaryFrame.payloadHeaderLength
                    + WindowsCompanionDVC.maximumBinaryChunkBytes + 1
            )
        ) {
            _ = try DVCWireCodec.encode(.binary(DVCBinaryFrame(
                transferID: transferID,
                sequence: 3,
                flags: [.final, .authenticated],
                offset: 0,
                data: Data(
                    repeating: 0,
                    count: WindowsCompanionDVC.maximumBinaryChunkBytes + 1
                ),
                isFinal: true,
                authentication: authentication
            )))
        }

        let payload = Data("binary-data".utf8)
        let frame = DVCBinaryFrame(
            transferID: transferID,
            sequence: 4,
            offset: 4_096,
            data: payload,
            isFinal: true
        )
        let encoded = try DVCWireCodec.encode(.binary(frame))
        let retainedPrefixLengths = [
            0,
            1,
            WindowsCompanionDVC.headerLength - 1,
            WindowsCompanionDVC.headerLength,
            encoded.count - 1,
        ]
        for length in retainedPrefixLengths {
            let prefix = Data(encoded.prefix(length))
            let decoded = try DVCWireCodec.decodeAvailable(from: prefix)
            try RobustnessAssertions.require(
                decoded.frames.isEmpty && decoded.remainder == prefix,
                "Truncated binary frame was not retained exactly."
            )
        }

        var incremental = DVCIncrementalDecoder()
        for (index, byte) in encoded.enumerated() {
            let frames = try incremental.append(Data([byte]))
            if index + 1 == encoded.count {
                try RobustnessAssertions.require(
                    frames == [.binary(frame)] && incremental.bufferedData.isEmpty,
                    "Byte-at-a-time binary frame decoding failed at completion."
                )
            } else {
                try RobustnessAssertions.require(
                    frames.isEmpty,
                    "Truncated byte-at-a-time input produced a premature frame."
                )
            }
        }

        var newSessionDecoder = DVCIncrementalDecoder()
        _ = try newSessionDecoder.append(Data(encoded.prefix(17)))
        newSessionDecoder = DVCIncrementalDecoder()
        try RobustnessAssertions.require(
            try newSessionDecoder.append(encoded) == [.binary(frame)],
            "A fresh decoder retained bytes from a disconnected session."
        )

        var outerDigestChanged = encoded
        outerDigestChanged[outerDigestChanged.index(
            outerDigestChanged.startIndex,
            offsetBy: 20
        )] ^= 0x80
        try RobustnessAssertions.expectProtocolError(.invalidFrameDigest) {
            _ = try DVCWireCodec.decodeAvailable(from: outerDigestChanged)
        }

        var invalidFinal = encoded
        invalidFinal[invalidFinal.index(
            invalidFinal.startIndex,
            offsetBy: WindowsCompanionDVC.headerLength + 24
        )] = 2
        repairOuterDigest(&invalidFinal)
        try RobustnessAssertions.expectProtocolError(.malformedFrame) {
            _ = try DVCWireCodec.decodeAvailable(from: invalidFinal)
        }

        var negativeOffset = encoded
        replaceBigEndian(
            UInt64.max,
            in: &negativeOffset,
            at: WindowsCompanionDVC.headerLength + 16
        )
        repairOuterDigest(&negativeOffset)
        try RobustnessAssertions.expectProtocolError(.invalidBinaryRange) {
            _ = try DVCWireCodec.decodeAvailable(from: negativeOffset)
        }

        var negativeDataLength = encoded
        replaceBigEndian(
            UInt32.max,
            in: &negativeDataLength,
            at: WindowsCompanionDVC.headerLength + 25
        )
        repairOuterDigest(&negativeDataLength)
        try RobustnessAssertions.expectProtocolError(.invalidFrameLength) {
            _ = try DVCWireCodec.decodeAvailable(from: negativeDataLength)
        }

        var inconsistentDataLength = encoded
        replaceBigEndian(
            UInt32(payload.count + 1),
            in: &inconsistentDataLength,
            at: WindowsCompanionDVC.headerLength + 25
        )
        repairOuterDigest(&inconsistentDataLength)
        try RobustnessAssertions.expectProtocolError(.invalidFrameLength) {
            _ = try DVCWireCodec.decodeAvailable(from: inconsistentDataLength)
        }

        var binaryDigestChanged = encoded
        binaryDigestChanged[binaryDigestChanged.index(
            binaryDigestChanged.startIndex,
            offsetBy: WindowsCompanionDVC.headerLength + 29
        )] ^= 0x01
        repairOuterDigest(&binaryDigestChanged)
        try RobustnessAssertions.expectProtocolError(.invalidBinaryDigest) {
            _ = try DVCWireCodec.decodeAvailable(from: binaryDigestChanged)
        }

        var binaryDataChanged = encoded
        binaryDataChanged[binaryDataChanged.index(
            binaryDataChanged.startIndex,
            offsetBy: binaryDataChanged.count - 1
        )] ^= 0x01
        repairOuterDigest(&binaryDataChanged)
        try RobustnessAssertions.expectProtocolError(.invalidBinaryDigest) {
            _ = try DVCWireCodec.decodeAvailable(from: binaryDataChanged)
        }

        var overLimitHeader = Data(repeating: 0, count: WindowsCompanionDVC.headerLength)
        overLimitHeader.replaceSubrange(0..<4, with: Data("JTSD".utf8))
        replaceBigEndian(UInt16(1), in: &overLimitHeader, at: 4)
        overLimitHeader[overLimitHeader.index(overLimitHeader.startIndex, offsetBy: 6)] = 2
        overLimitHeader[overLimitHeader.index(overLimitHeader.startIndex, offsetBy: 7)] = 1
        replaceBigEndian(UInt64(1), in: &overLimitHeader, at: 8)
        replaceBigEndian(
            UInt32(WindowsCompanionDVC.maximumBinaryPayloadBytes + 1),
            in: &overLimitHeader,
            at: 16
        )
        try RobustnessAssertions.expectProtocolError(
            .payloadTooLarge(WindowsCompanionDVC.maximumBinaryPayloadBytes + 1)
        ) {
            _ = try DVCWireCodec.decodeAvailable(from: overLimitHeader)
        }

        var bufferLimited = DVCIncrementalDecoder()
        try RobustnessAssertions.expectProtocolError(.bufferLimitExceeded) {
            _ = try bufferLimited.append(Data(
                repeating: 0,
                count: WindowsCompanionDVC.maximumBufferedBytes + 1
            ))
        }
    }

    private static func exerciseSequenceAndReassembly() throws {
        var replayGuard = DVCSequenceReplayGuard()
        try replayGuard.accept(9)
        try RobustnessAssertions.expectProtocolError(
            .replayRejected(sequence: 9, lastAccepted: 9)
        ) {
            try replayGuard.accept(9)
        }
        try RobustnessAssertions.expectProtocolError(
            .replayRejected(sequence: 8, lastAccepted: 9)
        ) {
            try replayGuard.accept(8)
        }
        try replayGuard.accept(10)
        try RobustnessAssertions.require(
            replayGuard.lastAccepted == 10,
            "Replay guard did not advance after a valid chunk sequence."
        )

        let data = Data("abcdefgh".utf8)
        let descriptor = DVCBinaryTransferDescriptor(
            transferID: transferID,
            purpose: "robustness",
            totalBytes: Int64(data.count),
            sha256: sha256(data)
        )
        var reassembler = try DVCBinaryReassembler(
            descriptor: descriptor,
            maximumBytes: 8,
            maximumChunkBytes: 4
        )
        let first = DVCBinaryFrame(
            transferID: transferID,
            sequence: 1,
            offset: 0,
            data: data.subdata(in: 0..<4),
            isFinal: false
        )
        let second = DVCBinaryFrame(
            transferID: transferID,
            sequence: 2,
            offset: 4,
            data: data.subdata(in: 4..<8),
            isFinal: true
        )

        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(second)
        }
        try RobustnessAssertions.require(
            reassembler.receivedByteCount == 0 && !reassembler.sawFinal,
            "Out-of-order chunk changed reassembly state."
        )
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: UUID(),
                sequence: 3,
                offset: 0,
                data: first.data,
                isFinal: false
            ))
        }
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 4,
                offset: -1,
                data: Data(),
                isFinal: false
            ))
        }
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 5,
                offset: Int64.max,
                data: Data([0]),
                isFinal: false
            ))
        }
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 6,
                offset: 0,
                data: Data(repeating: 0, count: 5),
                isFinal: false
            ))
        }
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 7,
                offset: 0,
                data: first.data,
                isFinal: true
            ))
        }

        try reassembler.accept(first)
        try reassembler.accept(first)
        try RobustnessAssertions.require(
            reassembler.receivedByteCount == 4 && !reassembler.sawFinal,
            "Exact duplicate retry changed partial reassembly state."
        )
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 8,
                offset: 0,
                data: Data("abce".utf8),
                isFinal: false
            ))
        }
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 9,
                offset: 2,
                data: Data("cdef".utf8),
                isFinal: false
            ))
        }
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 10,
                offset: 5,
                data: Data("fgh".utf8),
                isFinal: true
            ))
        }
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 11,
                offset: 4,
                data: second.data,
                isFinal: false
            ))
        }

        try reassembler.accept(second)
        try reassembler.accept(second)
        try RobustnessAssertions.require(
            reassembler.sawFinal && reassembler.receivedByteCount == data.count,
            "Final duplicate retry changed complete reassembly state."
        )
        try RobustnessAssertions.require(
            try reassembler.verifiedData() == data,
            "Complete transfer failed SHA-256 verification."
        )
        try RobustnessAssertions.expectReassemblyError(.invalidChunk) {
            try reassembler.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 12,
                offset: Int64(data.count),
                data: Data(),
                isFinal: true
            ))
        }

        var incomplete = try DVCBinaryReassembler(
            descriptor: descriptor,
            maximumBytes: 8,
            maximumChunkBytes: 4
        )
        try incomplete.accept(first)
        try RobustnessAssertions.expectReassemblyError(.incomplete) {
            _ = try incomplete.verifiedData()
        }

        var wrongHash = try DVCBinaryReassembler(
            descriptor: DVCBinaryTransferDescriptor(
                transferID: transferID,
                purpose: "robustness",
                totalBytes: Int64(data.count),
                sha256: String(repeating: "0", count: 64)
            ),
            maximumBytes: 8,
            maximumChunkBytes: 8
        )
        try wrongHash.accept(DVCBinaryFrame(
            transferID: transferID,
            sequence: 1,
            offset: 0,
            data: data,
            isFinal: true
        ))
        try RobustnessAssertions.expectReassemblyError(.hashMismatch) {
            _ = try wrongHash.verifiedData()
        }

        try RobustnessAssertions.expectReassemblyError(.invalidDescriptor) {
            _ = try DVCBinaryReassembler(
                descriptor: DVCBinaryTransferDescriptor(
                    transferID: transferID,
                    purpose: "robustness",
                    totalBytes: 9,
                    sha256: sha256(data)
                ),
                maximumBytes: 8,
                maximumChunkBytes: 4
            )
        }
        try RobustnessAssertions.expectReassemblyError(.invalidDescriptor) {
            _ = try DVCBinaryReassembler(
                descriptor: DVCBinaryTransferDescriptor(
                    transferID: transferID,
                    purpose: "robustness",
                    totalBytes: 0,
                    sha256: "not-a-digest"
                ),
                maximumBytes: 8,
                maximumChunkBytes: 4
            )
        }

        var empty = try DVCBinaryReassembler(
            descriptor: DVCBinaryTransferDescriptor(
                transferID: transferID,
                purpose: "robustness",
                totalBytes: 0,
                sha256: sha256(Data())
            ),
            maximumBytes: 0,
            maximumChunkBytes: 4
        )
        let emptyFinal = DVCBinaryFrame(
            transferID: transferID,
            sequence: 1,
            offset: 0,
            data: Data(),
            isFinal: true
        )
        try empty.accept(emptyFinal)
        try empty.accept(emptyFinal)
        try RobustnessAssertions.require(
            try empty.verifiedData().isEmpty,
            "Empty final chunk did not verify."
        )
    }

    private static func exerciseDisconnectCleanup() async throws {
        let data = Data("disconnect-cleanup".utf8)
        let descriptor = DVCBinaryTransferDescriptor(
            transferID: transferID,
            purpose: "robustness",
            totalBytes: Int64(data.count),
            sha256: sha256(data)
        )
        let box = TransferManagerBox()
        var downloadAttempt = 0
        let manager = WindowsCompanionBinaryTransferManager(
            request: { method, _, _ in
                switch method {
                case "transfer.release":
                    return [
                        "transferId": descriptor.transferID.uuidString.lowercased(),
                        "released": true,
                    ]
                case "transfer.download":
                    downloadAttempt += 1
                    guard let activeManager = box.value else {
                        throw RobustnessSelfTestFailure(
                            message: "Transfer manager was unavailable."
                        )
                    }
                    if downloadAttempt == 1 {
                        try activeManager.receive(DVCBinaryFrame(
                            transferID: descriptor.transferID,
                            sequence: 1,
                            offset: 0,
                            data: data.subdata(in: 0..<4),
                            isFinal: false
                        ))
                        activeManager.cancelAll()
                        try RobustnessAssertions.expectRequestFailure(
                            code: "TRANSFER_NOT_EXPECTED"
                        ) {
                            try activeManager.receive(DVCBinaryFrame(
                                transferID: descriptor.transferID,
                                sequence: 2,
                                offset: 4,
                                data: data.subdata(in: 4..<data.count),
                                isFinal: true
                            ))
                        }
                        throw WindowsCompanionRequestFailure(
                            code: "SIMULATED_DISCONNECT",
                            message: "The DVC session disconnected.",
                            retryable: false
                        )
                    }

                    try activeManager.receive(DVCBinaryFrame(
                        transferID: descriptor.transferID,
                        sequence: 1,
                        offset: 0,
                        data: data,
                        isFinal: true
                    ))
                    return [
                        "transferId": descriptor.transferID.uuidString.lowercased(),
                        "totalBytes": descriptor.totalBytes,
                        "sha256": descriptor.sha256,
                        "completed": true,
                    ]
                default:
                    throw RobustnessSelfTestFailure(
                        message: "Unexpected transfer method \(method)."
                    )
                }
            },
            sendChunk: { _, _, _, _ in }
        )
        box.value = manager

        do {
            _ = try await manager.download(
                descriptor,
                deadlineMilliseconds: 1_000
            )
            throw RobustnessSelfTestFailure(
                message: "The simulated disconnect unexpectedly completed."
            )
        } catch let error as WindowsCompanionRequestFailure {
            try RobustnessAssertions.require(
                error.code == "SIMULATED_DISCONNECT",
                "The simulated disconnect returned the wrong error."
            )
        }

        let restarted = try await manager.download(
            descriptor,
            deadlineMilliseconds: 1_000
        )
        try RobustnessAssertions.require(
            restarted == data,
            "A fresh transfer retained partial bytes from the disconnected session."
        )
        try RobustnessAssertions.require(
            downloadAttempt == 2,
            "The fresh transfer did not restart at a clean request boundary."
        )
    }

    private static func repairOuterDigest(_ encoded: inout Data) {
        let payload = encoded.dropFirst(WindowsCompanionDVC.headerLength)
        let digest = Data(SHA256.hash(data: payload).prefix(4))
        encoded.replaceSubrange(20..<24, with: digest)
    }

    private static func replaceBigEndian<T: FixedWidthInteger>(
        _ value: T,
        in data: inout Data,
        at offset: Int
    ) {
        var bigEndian = value.bigEndian
        let bytes = withUnsafeBytes(of: &bigEndian) { Data($0) }
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private final class TransferManagerBox {
        var value: WindowsCompanionBinaryTransferManager?
    }
}
