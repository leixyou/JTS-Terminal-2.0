#if ENABLE_RDP_2
import CryptoKit
import Foundation

@MainActor
final class WindowsCompanionBinaryTransferManager {
    nonisolated static let maximumTransferBytes: Int64 = 512 * 1_024 * 1_024
    nonisolated static let chunkBytes = 4 * 1_024 * 1_024
    nonisolated static let maximumConcurrentDownloads = 4

    typealias Request = @MainActor (
        _ method: String,
        _ parameters: [String: Any],
        _ deadlineMilliseconds: Int?
    ) async throws -> [String: Any]
    typealias SendChunk = @MainActor (
        _ transferID: UUID,
        _ offset: Int64,
        _ data: Data,
        _ isFinal: Bool
    ) async throws -> Void

    private final class DownloadState {
        private var reassembler: DVCBinaryReassembler

        init(descriptor: DVCBinaryTransferDescriptor, maximumBytes: Int64) throws {
            guard maximumBytes <= WindowsCompanionBinaryTransferManager.maximumTransferBytes else {
                throw WindowsCompanionRequestFailure(
                    code: "TRANSFER_SIZE_INVALID",
                    message: "The Companion transfer size is outside the configured limit.",
                    retryable: false
                )
            }
            do {
                reassembler = try DVCBinaryReassembler(
                    descriptor: descriptor,
                    maximumBytes: maximumBytes,
                    maximumChunkBytes: WindowsCompanionBinaryTransferManager.chunkBytes
                )
            } catch {
                throw WindowsCompanionRequestFailure(
                    code: "TRANSFER_SIZE_INVALID",
                    message: "The Companion transfer descriptor is outside the configured limits.",
                    retryable: false
                )
            }
        }

        func accept(_ frame: DVCBinaryFrame) throws {
            do {
                try reassembler.accept(frame)
            } catch {
                throw DVCProtocolError.invalidBinaryRange
            }
        }

        func verifiedData() throws -> Data {
            do {
                return try reassembler.verifiedData()
            } catch DVCBinaryReassemblyError.incomplete {
                throw WindowsCompanionRequestFailure(
                    code: "TRANSFER_INCOMPLETE",
                    message: "The Companion binary download is incomplete.",
                    retryable: true
                )
            } catch {
                throw WindowsCompanionRequestFailure(
                    code: "TRANSFER_HASH_MISMATCH",
                    message: "The Companion binary download failed SHA-256 verification.",
                    retryable: false
                )
            }
        }

        var receivedByteCount: Int { reassembler.receivedByteCount }
    }

    private let request: Request
    private let sendChunk: SendChunk
    private var downloads: [UUID: DownloadState] = [:]

    init(request: @escaping Request, sendChunk: @escaping SendChunk) {
        self.request = request
        self.sendChunk = sendChunk
    }

    func upload(
        _ data: Data,
        purpose: String,
        deadlineMilliseconds: Int?,
        maximumBytes: Int64 = WindowsCompanionBinaryTransferManager.maximumTransferBytes
    ) async throws -> DVCBinaryTransferDescriptor {
        guard maximumBytes >= 0,
              maximumBytes <= Self.maximumTransferBytes,
              Int64(data.count) <= maximumBytes else {
            throw WindowsCompanionRequestFailure(
                code: "TRANSFER_SIZE_INVALID",
                message: "The Companion upload exceeds the configured limit.",
                retryable: false
            )
        }
        let descriptor = DVCBinaryTransferDescriptor(
            transferID: UUID(),
            purpose: purpose,
            totalBytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )

        do {
            for attempt in 0..<2 {
                do {
                    try Task.checkCancellation()
                    let begin = try await request(
                        "transfer.begin",
                        descriptor.parameters,
                        deadlineMilliseconds
                    )
                    guard let nextOffset = Self.int64(begin["nextOffset"]),
                          nextOffset >= 0,
                          nextOffset <= descriptor.totalBytes else {
                        throw WindowsCompanionRequestFailure(
                            code: "TRANSFER_OFFSET_INVALID",
                            message: "The Companion returned an invalid upload resume offset.",
                            retryable: false
                        )
                    }
                    var offset = Int(nextOffset)
                    if data.isEmpty, begin["completed"] as? Bool != true {
                        try Task.checkCancellation()
                        try await sendChunk(descriptor.transferID, 0, Data(), true)
                    }
                    while offset < data.count {
                        try Task.checkCancellation()
                        let end = min(offset + Self.chunkBytes, data.count)
                        try await sendChunk(
                            descriptor.transferID,
                            Int64(offset),
                            data.subdata(in: offset..<end),
                            end == data.count
                        )
                        offset = end
                    }
                    try Task.checkCancellation()
                    let finalized = try await request(
                        "transfer.finalize",
                        ["transferId": descriptor.transferID.uuidString.lowercased()],
                        deadlineMilliseconds
                    )
                    try Self.validateCompletion(finalized, descriptor: descriptor)
                    return descriptor
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as WindowsCompanionRequestFailure
                    where attempt == 0 && failure.retryable {
                    continue
                } catch where attempt == 0 {
                    continue
                }
            }
            throw WindowsCompanionRequestFailure(
                code: "TRANSFER_UPLOAD_FAILED",
                message: "The Companion binary upload could not be completed.",
                retryable: true
            )
        } catch {
            try? await release(descriptor.transferID, deadlineMilliseconds: deadlineMilliseconds)
            throw error
        }
    }

    func download(
        _ descriptor: DVCBinaryTransferDescriptor,
        deadlineMilliseconds: Int?,
        maximumBytes: Int64 = WindowsCompanionBinaryTransferManager.maximumTransferBytes
    ) async throws -> Data {
        guard downloads.count < Self.maximumConcurrentDownloads else {
            throw WindowsCompanionRequestFailure(
                code: "TRANSFER_CONCURRENCY_LIMIT",
                message: "The Companion binary transfer concurrency limit was reached.",
                retryable: true
            )
        }
        let state = try DownloadState(descriptor: descriptor, maximumBytes: maximumBytes)
        downloads[descriptor.transferID] = state
        defer { downloads.removeValue(forKey: descriptor.transferID) }

        do {
            for attempt in 0..<2 {
                do {
                    try Task.checkCancellation()
                    let result = try await request(
                        "transfer.download",
                        [
                            "transferId": descriptor.transferID.uuidString.lowercased(),
                            "offset": state.receivedByteCount,
                        ],
                        deadlineMilliseconds
                    )
                    try Self.validateCompletion(result, descriptor: descriptor)
                    let data = try state.verifiedData()
                    try? await release(descriptor.transferID, deadlineMilliseconds: deadlineMilliseconds)
                    return data
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as WindowsCompanionRequestFailure
                    where attempt == 0 && failure.retryable {
                    continue
                }
            }
            throw WindowsCompanionRequestFailure(
                code: "TRANSFER_DOWNLOAD_FAILED",
                message: "The Companion binary download could not be completed.",
                retryable: true
            )
        } catch {
            try? await release(descriptor.transferID, deadlineMilliseconds: deadlineMilliseconds)
            throw error
        }
    }

    func receive(_ frame: DVCBinaryFrame) throws {
        guard let download = downloads[frame.transferID] else {
            throw WindowsCompanionRequestFailure(
                code: "TRANSFER_NOT_EXPECTED",
                message: "The Companion sent an unexpected binary transfer.",
                retryable: false
            )
        }
        try download.accept(frame)
    }

    func release(_ transferID: UUID, deadlineMilliseconds: Int?) async throws {
        _ = try await request(
            "transfer.release",
            ["transferId": transferID.uuidString.lowercased()],
            deadlineMilliseconds
        )
    }

    func cancelAll() {
        downloads.removeAll()
    }

    private static func validateCompletion(
        _ result: [String: Any],
        descriptor: DVCBinaryTransferDescriptor
    ) throws {
        guard result["completed"] as? Bool == true,
              (result["transferId"] as? String).flatMap(UUID.init(uuidString:)) == descriptor.transferID,
              int64(result["totalBytes"]) == descriptor.totalBytes,
              (result["sha256"] as? String)?.lowercased() == descriptor.sha256.lowercased() else {
            throw WindowsCompanionRequestFailure(
                code: "TRANSFER_METADATA_MISMATCH",
                message: "The Companion binary transfer metadata did not match its request.",
                retryable: false
            )
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? UInt64, value <= UInt64(Int64.max) { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}

private extension DVCBinaryTransferDescriptor {
    var parameters: [String: Any] {
        [
            "transferId": transferID.uuidString.lowercased(),
            "purpose": purpose,
            "totalBytes": totalBytes,
            "sha256": sha256,
        ]
    }
}

#endif
