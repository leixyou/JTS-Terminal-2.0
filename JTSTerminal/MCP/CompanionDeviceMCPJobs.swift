#if ENABLE_RDP_2
import Foundation
import JTSCompanionIPC

extension CompanionDeviceMCPHandler {
    func job(_ request: CompanionDeviceMCPRequest, route: CompanionDeviceRoute,
             authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> [String: Any] {
        let values = request.arguments
        if request.tool == .exec || request.action == "submit" {
            let job = try await devices.mcpSubmit(route: route, script: values["script"] as? String ?? "",
                directory: values["workingDirectory"] as? String ?? ".",
                timeoutSeconds: CompanionDeviceMCPRequest.integer("timeoutSeconds", values, range: 1...86400, default: 60),
                allowDisconnected: request.tool == .task && values["allowDisconnected"] as? Bool == true,
                authorize: authorize)
            if request.tool == .task { return try receipt(job) }
            let wait = try CompanionDeviceMCPRequest.integer("waitSeconds", values, range: 1...60, default: 30)
            let limit = try CompanionDeviceMCPRequest.integer("maximumOutputBytes", values, range: 1...1_048_576, default: 32768)
            let deadline = ContinuousClock.now.advanced(by: .seconds(wait))
            while !job.isTerminal && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(150))
                try authorize()
                _ = try await devices.mcpJob(route: route, jobID: job.id, authorize: authorize)
            }
            var data = Data()
            while data.count < limit && data.count < (job.receipt?.outputBytes ?? 0) {
                let chunk = try await devices.mcpOutput(route: route, jobID: job.id, offset: data.count,
                    maximumBytes: min(32768, limit - data.count), authorize: authorize)
                guard !chunk.data.isEmpty else { break }
                data.append(chunk.data)
            }
            var result = try receipt(job)
            result["output"] = String(decoding: data, as: UTF8.self)
            result["outputBase64"] = data.base64EncodedString()
            result["nextOffset"] = data.count
            result["truncated"] = data.count < (job.receipt?.outputBytes ?? 0)
            result["completed"] = job.isTerminal
            // This protocol confirms success/nonzero, but does not provide the exact nonzero process exit code.
            result["exitCode"] = job.receipt?.state == .succeeded ? 0 : NSNull()
            return result
        }
        let id = try CompanionDeviceMCPRequest.identifier("jobId", values)
        if request.action == "output" {
            let output = try await devices.mcpOutput(route: route, jobID: id,
                offset: CompanionDeviceMCPRequest.integer("offset", values, range: 0...1_048_576, default: 0),
                maximumBytes: CompanionDeviceMCPRequest.integer("maximumBytes", values, range: 1...32768, default: 32768),
                authorize: authorize)
            var result = try jsonObject(output)
            result["output"] = String(decoding: output.data, as: UTF8.self)
            return result
        }
        return try receipt(await devices.mcpJob(route: route, jobID: id, cancel: request.action == "cancel", authorize: authorize))
    }

    private func receipt(_ job: CompanionDeviceJob) throws -> [String: Any] {
        guard let receipt = job.receipt else { throw CompanionJobError.invalidReply }
        var result = try jsonObject(receipt)
        result["submissionConfirmed"] = true
        return result
    }
    func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw CompanionJobError.invalidReply }
        return result
    }
}
#endif
