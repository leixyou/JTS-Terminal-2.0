#if ENABLE_RDP_2
import CryptoKit
import Foundation
import JTSCompanionClient
import JTSCompanionIPC

extension CompanionDeviceMCPHandler {
    func files(_ request: CompanionDeviceMCPRequest, binding: CompanionTargetRouteBinding,
               authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> [String: Any] {
        guard let grant = binding.fileGrantID else {
            throw WindowsMCPToolError(code: .permissionDenied, message: "This target has no Windows-issued file lane grant. Re-import its complete public enrollment bundle.")
        }
        let plan = try CompanionDeviceFilePlan(request)
        let configuration = try await devices.relayConfiguration(deviceID: binding.deviceID)
        try authorize()
        let lane = CompanionLaneClient()
        do {
            _ = try await lane.open(configuration: configuration, lane: .file, grantID: grant)
            try authorize()
            let client = CompanionFileClient(lane: lane, grantID: grant)
            let result = try await plan.perform { operation, parameters in
                _ = try await self.devices.relayConfiguration(deviceID: binding.deviceID)
                guard try await self.bindings.binding(targetID: binding.targetID, targetBinding: binding.targetBinding) == binding else {
                    throw WindowsMCPToolError(code: .permissionDenied, message: "The file route binding was changed or removed.")
                }
                try authorize()
                let bytes = try await client.request(operation, parametersJSON: JSONSerialization.data(withJSONObject: parameters, options: .sortedKeys))
                _ = try await self.devices.relayConfiguration(deviceID: binding.deviceID)
                try authorize()
                guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CompanionClientError.invalidReply }
                return result
            }
            await client.close()
            return result
        } catch {
            await lane.close()
            throw error
        }
    }
}

/// File publication uses begin/chunks/commit; no script generation or remote keystrokes.
@MainActor
struct CompanionDeviceFilePlan {
    let action: String
    let parameters: [String: Any]
    let content: Data?
    let encoding: String

    init(_ request: CompanionDeviceMCPRequest) throws {
        let values = request.arguments
        action = request.action
        encoding = values["encoding"] as? String ?? "base64"
        guard ["utf8", "base64"].contains(encoding) else { throw CompanionDeviceMCPRequest.invalid("encoding must be utf8 or base64.") }
        guard try !CompanionDeviceMCPRequest.boolean("recursive", values) else { throw CompanionDeviceMCPRequest.invalid("Recursive file removal is not supported by this device route.") }
        _ = try CompanionDeviceMCPRequest.boolean("overwrite", values)
        if action == "roots" { parameters = [:]; content = nil; return }
        guard let root = values["rootId"] as? String, !root.isEmpty,
              let path = values["path"] as? String else { throw CompanionDeviceMCPRequest.invalid("rootId and path are required.") }
        var parameters: [String: Any] = ["rootId": root, "path": path]
        switch action {
        case "list":
            parameters["offset"] = try CompanionDeviceMCPRequest.integer("offset", values, range: 0...1_048_576, default: 0)
            parameters["limit"] = try CompanionDeviceMCPRequest.integer("limit", values, range: 1...100, default: 100)
        case "stat": parameters["includeSha256"] = true
        case "read":
            parameters["offset"] = try CompanionDeviceMCPRequest.integer("offset", values, range: 0...268435456, default: 0)
            parameters["maximumBytes"] = try CompanionDeviceMCPRequest.integer("maximumBytes", values, range: 1...32768, default: 32768)
        case "rename":
            guard let destination = values["destination"] as? String else { throw CompanionDeviceMCPRequest.invalid("destination is required.") }
            parameters["destinationPath"] = destination; parameters["overwrite"] = values["overwrite"] as? Bool ?? false
        default: break
        }
        self.parameters = parameters
        if action == "write" {
            guard let text = values["content"] as? String, text.utf8.count <= 1_400_000 else { throw CompanionDeviceMCPRequest.invalid("content is required and bounded to 1 MiB decoded.") }
            let data = encoding == "utf8" ? Data(text.utf8) : Data(base64Encoded: text)
            guard let data, data.count <= 1_048_576, encoding != "base64" || data.base64EncodedString() == text else { throw CompanionDeviceMCPRequest.invalid("Invalid file content or encoding.") }
            content = data
            self.overwrite = values["overwrite"] as? Bool ?? false
        } else { content = nil }
    }
    private var overwrite = false

    func perform(_ send: (CompanionFileOperation, [String: Any]) async throws -> [String: Any]) async throws -> [String: Any] {
        if let content {
            let id = UUID().uuidString.lowercased()
            let sha = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            var begin = parameters
            begin.merge(["transferId": id, "totalBytes": content.count, "sha256": sha, "overwrite": overwrite]) { _, new in new }
            _ = try await send(.beginWrite, begin)
            var offset = 0
            repeat {
                let end = min(offset + 32768, content.count)
                _ = try await send(.writeChunk, ["transferId": id, "offset": offset,
                    "dataBase64": content.subdata(in: offset..<end).base64EncodedString(), "final": end == content.count])
                offset = end
            } while offset < content.count
            let result = try await send(.commitWrite, ["transferId": id])
            guard result["sha256"] as? String == sha, (result["size"] as? NSNumber)?.intValue == content.count else {
                throw CompanionClientError.invalidReply
            }
            return result
        }
        let operation: CompanionFileOperation
        switch action {
        case "roots": operation = .roots
        case "list": operation = .list
        case "stat": operation = .stat
        case "read": operation = .read
        case "mkdir": operation = .mkdir
        case "rename": operation = .move
        case "remove": operation = .remove
        default: throw CompanionDeviceMCPRequest.invalid("Unsupported file operation.")
        }
        var result = try await send(operation, parameters)
        if action == "read", encoding == "utf8", let encoded = result["dataBase64"] as? String,
           let bytes = Data(base64Encoded: encoded) { result["content"] = String(decoding: bytes, as: UTF8.self) }
        return result
    }
}
#endif
