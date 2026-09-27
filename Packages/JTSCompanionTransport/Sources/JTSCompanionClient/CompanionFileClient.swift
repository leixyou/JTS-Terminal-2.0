import Foundation
import JTSCompanionIPC

public protocol CompanionLaneByteStream: Sendable {
    func read(maximumBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}
extension CompanionLaneClient: CompanionLaneByteStream {}

public enum CompanionFileOperation: String, Sendable {
    case roots = "file.roots", list = "file.list", stat = "file.stat", read = "file.read"
    case beginWrite = "file.write.begin", writeChunk = "file.write.chunk", commitWrite = "file.write.commit"
    case mkdir = "file.mkdir", remove = "file.remove", move = "file.move"
}

/// Bounded file RPC over a separately opened, grant-authorized File lane.
/// Upload begin/chunk/commit preserve the remote atomic-publication boundary.
public actor CompanionFileClient {
    private let lane: any CompanionLaneByteStream
    private let grantID: UUID
    private var busy = false
    private var closed = false

    public init(lane: any CompanionLaneByteStream, grantID: UUID) {
        self.lane = lane; self.grantID = grantID
    }

    public func request(_ operation: CompanionFileOperation, parametersJSON: Data) async throws -> Data {
        guard !closed else { throw CompanionClientError.notConnected }
        guard !busy else { throw CompanionClientError.busy }
        let parameters = try CompanionFileContract.parameters(operation, bytes: parametersJSON)
        guard grantID.uuidString != "00000000-0000-0000-0000-000000000000" else { throw CompanionClientError.invalidRequest }
        let id = UUID().uuidString.lowercased()
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "id": id,
            "operation": operation.rawValue, "grantId": grantID.uuidString.lowercased(), "parameters": parameters], options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= CompanionFileContract.frameLimit else { throw CompanionClientError.invalidRequest }
        busy = true; defer { busy = false }
        do {
            let response = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await self.exchange(bytes) }
                    group.addTask { [lane] in
                        try await Task.sleep(nanoseconds: 25_000_000_000)
                        await lane.close(); throw CompanionClientError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } onCancel: { [lane] in Task { await lane.close() } }
            try Task.checkCancellation()
            guard !closed else { throw CompanionClientError.notConnected }
            try StrictCompanionJSON.validate(response, requiredKeys: ["version", "id", "ok", "result", "errorCode"],
                                             maximumBytes: CompanionFileContract.frameLimit)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  CompanionFileContract.integer(object["version"]) == 1, object["id"] as? String == id,
                  let ok = CompanionFileContract.boolean(object["ok"]) else { throw CompanionClientError.invalidReply }
            if !ok {
                guard object["result"] is NSNull, let code = object["errorCode"] as? String,
                      (1...64).contains(code.utf8.count), code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                    throw CompanionClientError.invalidReply
                }
                throw CompanionClientError.remote(code)
            }
            guard object["errorCode"] is NSNull, let result = object["result"] as? [String: Any] else {
                throw CompanionClientError.invalidReply
            }
            try CompanionFileContract.validate(result, operation: operation, parameters: parameters)
            return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch CompanionClientError.remote(let code) { throw CompanionClientError.remote(code) }
        catch { closed = true; await lane.close(); throw error }
    }

    public func close() async { closed = true; await lane.close() }

    private func exchange(_ bytes: Data) async throws -> Data {
        var length = UInt32(bytes.count).bigEndian
        try await lane.write(withUnsafeBytes(of: &length) { Data($0) })
        for start in stride(from: 0, to: bytes.count, by: 32 * 1024) {
            try await lane.write(bytes.subdata(in: start..<min(start + 32 * 1024, bytes.count)))
        }
        let header = try await readExactly(4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...CompanionFileContract.frameLimit).contains(count) else { throw CompanionClientError.invalidReply }
        return try await readExactly(count)
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let maximum = min(32 * 1024, count - result.count)
            let bytes = try await lane.read(maximumBytes: maximum)
            guard !bytes.isEmpty, bytes.count <= maximum else { throw CompanionClientError.invalidReply }
            result.append(bytes)
        }
        return result
    }
}
