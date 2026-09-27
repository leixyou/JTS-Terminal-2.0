#if ENABLE_RDP_2
import CryptoKit
import Foundation

nonisolated struct DVCBinaryTransferDescriptor: Equatable, Sendable {
    let transferID: UUID
    let purpose: String
    let totalBytes: Int64
    let sha256: String
}

nonisolated enum DVCBinaryReassemblyError: LocalizedError, Equatable, Sendable {
    case invalidDescriptor
    case invalidChunk
    case incomplete
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor:
            return "The Companion binary transfer descriptor is invalid."
        case .invalidChunk:
            return "The Companion binary chunk conflicts with the transfer state."
        case .incomplete:
            return "The Companion binary transfer is incomplete."
        case .hashMismatch:
            return "The Companion binary transfer SHA-256 does not match its descriptor."
        }
    }
}

/// Pure, bounded state machine for one Companion binary download.
///
/// The DVC wire decoder validates frame lengths and chunk digests. This layer
/// binds those chunks to one advertised transfer, requires a contiguous byte
/// stream, permits only byte-identical retransmission, and verifies the final
/// digest. Keeping it free of UI and transport state lets production and the
/// sanitizer harness execute the exact same reassembly logic.
nonisolated struct DVCBinaryReassembler: Sendable {
    let descriptor: DVCBinaryTransferDescriptor

    private let maximumChunkBytes: Int
    private let expectedSHA256: Data
    private var buffer: Data
    private(set) var sawFinal = false

    init(
        descriptor: DVCBinaryTransferDescriptor,
        maximumBytes: Int64,
        maximumChunkBytes: Int
    ) throws {
        guard maximumBytes >= 0,
              maximumChunkBytes > 0,
              descriptor.totalBytes >= 0,
              descriptor.totalBytes <= maximumBytes,
              descriptor.totalBytes <= Int64(Int.max),
              let expectedSHA256 = Data(hexadecimal: descriptor.sha256),
              expectedSHA256.count == 32 else {
            throw DVCBinaryReassemblyError.invalidDescriptor
        }

        self.descriptor = descriptor
        self.maximumChunkBytes = maximumChunkBytes
        self.expectedSHA256 = expectedSHA256
        self.buffer = Data()

        // The peer controls totalBytes. Reserving the complete advertised size
        // would let four valid descriptors force up to 2 GiB of eager memory.
        // Reserve at most one bounded chunk and grow only as bytes arrive.
        self.buffer.reserveCapacity(min(Int(descriptor.totalBytes), maximumChunkBytes))
    }

    var receivedByteCount: Int {
        buffer.count
    }

    mutating func accept(_ frame: DVCBinaryFrame) throws {
        guard frame.transferID == descriptor.transferID,
              frame.offset >= 0,
              frame.data.count <= maximumChunkBytes else {
            throw DVCBinaryReassemblyError.invalidChunk
        }

        let (end, overflow) = frame.offset.addingReportingOverflow(Int64(frame.data.count))
        guard !overflow,
              end <= descriptor.totalBytes,
              end <= Int64(Int.max) else {
            throw DVCBinaryReassemblyError.invalidChunk
        }

        let received = Int64(buffer.count)
        if descriptor.totalBytes == 0,
           sawFinal,
           frame.offset == 0,
           frame.data.isEmpty,
           frame.isFinal {
            return
        }

        if frame.offset < received {
            guard end <= received,
                  frame.isFinal == (end == descriptor.totalBytes),
                  buffer.subdata(in: Int(frame.offset)..<Int(end)) == frame.data else {
                throw DVCBinaryReassemblyError.invalidChunk
            }
            return
        }

        guard !sawFinal,
              frame.offset == received,
              frame.isFinal == (end == descriptor.totalBytes) else {
            throw DVCBinaryReassemblyError.invalidChunk
        }

        buffer.append(frame.data)
        sawFinal = frame.isFinal
    }

    func verifiedData() throws -> Data {
        guard sawFinal, Int64(buffer.count) == descriptor.totalBytes else {
            throw DVCBinaryReassemblyError.incomplete
        }

        let actualSHA256 = Data(SHA256.hash(data: buffer))
        guard Self.constantTimeEqual(actualSHA256, expectedSHA256) else {
            throw DVCBinaryReassemblyError.hashMismatch
        }
        return buffer
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8.zero) { result, bytes in
            result | (bytes.0 ^ bytes.1)
        } == 0
    }
}

private extension Data {
    nonisolated init?(hexadecimal value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
#endif
