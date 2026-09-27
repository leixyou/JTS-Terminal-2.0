#if ENABLE_RDP_2
import Foundation
import JTSCompanionIPC

extension CompanionDevicesModel {
    typealias MCPAuthorityCheck = @MainActor () throws -> Void

    func mcpConnect(deviceID: UUID, grantID: UUID, authorize: @escaping MCPAuthorityCheck) async throws -> CompanionDeviceRoute {
        try authorize()
        _ = try await mcpSnapshot()
        try authorize()
        guard let route = routes[deviceID], !route.busy else { throw deviceFailure("DEVICE_BUSY", "The device is unavailable or another operation is in progress.") }
        _ = try await relayConfiguration(deviceID: deviceID, grantID: grantID)
        try authorize()
        if !route.hasRoute { await connect(deviceID: deviceID, authorize: authorize) }
        try authorize()
        guard route.hasRoute else { throw deviceFailure(route.errorCode ?? "DEVICE_CONNECTION_FAILED", "The independent Companion route did not connect.") }
        // Revalidate the Windows grant on each MCP request rather than treating cached UI state as authority.
        await checkGrant(grantID.uuidString, deviceID: deviceID, authorize: authorize)
        try authorize()
        guard route.hasRoute, route.verifiedGrant == grantID, route.errorCode == nil else {
            throw deviceFailure(route.errorCode ?? "DEVICE_GRANT_NOT_VERIFIED", "Windows did not validate the bound control grant.")
        }
        return route
    }

    func mcpSubmit(route: CompanionDeviceRoute, script: String, directory: String,
                   timeoutSeconds: Int, allowDisconnected: Bool, authorize: MCPAuthorityCheck) async throws -> CompanionDeviceJob {
        guard route.hasRoute, route.capabilities.contains("job.submit"), let grant = route.verifiedGrant,
              let client = route.connection, let token = route.begin() else { throw deviceFailure("DEVICE_BUSY", "The device cannot submit a job now.") }
        defer { route.finish(token) }
        let payload = try CompanionPowerShellRequest.payload(script: script, directory: directory)
        guard (1...86400).contains(timeoutSeconds), payload.count <= route.maximumPayloadBytes,
              let journal else { throw CompanionJobError.invalidRequest }
        let now = Date()
        let metadata = CompanionJobMetadata(id: UUID(), deviceID: route.deviceID, grantID: grant, createdAt: now,
            deadline: now.addingTimeInterval(TimeInterval(timeoutSeconds)), allowDisconnected: allowDisconnected)
        try metadata.validate()
        let request = CompanionIPCSubmit(grantID: grant, jobID: metadata.id, kind: "powershell.v1",
            deadlineUnixMilliseconds: metadata.deadlineMilliseconds, allowDisconnected: allowDisconnected, payload: payload)
        try request.validate()
        _ = try await trustedConfiguration(route, token: token); try authorize()
        try await journal.append(metadata)
        _ = try await trustedConfiguration(route, token: token); try authorize()
        let job = CompanionDeviceJob(metadata: metadata); route.jobs.insert(job, at: 0)
        do {
            let receipt = try await client.submit(request)
            _ = try await trustedConfiguration(route, token: token); try authorize()
            try job.accept(receipt)
            return job
        } catch {
            if route.generation == token { job.errorCode = "JOB_SUBMISSION_NOT_CONFIRMED" }
            // The caller must retain this ID and query it. A failed reply must never generate a second job.
            throw WindowsMCPToolError(code: .runtimeFailure, message: "Job submission was not confirmed. Inspect this jobId before submitting again.",
                details: ["jobId": job.id.uuidString.lowercased(), "deviceId": route.deviceID.uuidString.lowercased(), "submissionConfirmed": false])
        }
    }

    func mcpJob(route: CompanionDeviceRoute, jobID: UUID, cancel: Bool = false,
                authorize: MCPAuthorityCheck) async throws -> CompanionDeviceJob {
        let capability = cancel ? "job.cancel" : "job.get"
        guard route.hasRoute, route.capabilities.contains(capability), let client = route.connection,
              let job = route.jobs.first(where: { $0.id == jobID }), job.metadata.grantID == route.verifiedGrant,
              let token = route.begin() else { throw deviceFailure("JOB_NOT_AVAILABLE", "The job does not belong to this bound device/grant, or the device is busy.") }
        defer { route.finish(token) }
        _ = try await trustedConfiguration(route, token: token); try authorize()
        let receipt = try await (cancel ? client.cancel(grantID: job.metadata.grantID, jobID: jobID)
            : client.job(grantID: job.metadata.grantID, jobID: jobID))
        _ = try await trustedConfiguration(route, token: token); try authorize()
        try job.accept(receipt)
        return job
    }

    func mcpOutput(route: CompanionDeviceRoute, jobID: UUID, offset: Int, maximumBytes: Int,
                   authorize: MCPAuthorityCheck) async throws -> CompanionJobOutput {
        guard route.hasRoute, route.capabilities.contains("job.output"), let client = route.connection,
              let job = route.jobs.first(where: { $0.id == jobID }), job.metadata.grantID == route.verifiedGrant,
              let token = route.begin() else { throw deviceFailure("JOB_NOT_AVAILABLE", "The job output is unavailable for this device/grant.") }
        defer { route.finish(token) }
        let count = min(maximumBytes, route.maximumOutputChunkBytes)
        let request = CompanionIPCOutput(grantID: job.metadata.grantID, jobID: jobID, offset: offset, maximumBytes: count)
        try request.validate()
        _ = try await trustedConfiguration(route, token: token); try authorize()
        let output = try await client.output(request)
        _ = try await trustedConfiguration(route, token: token); try authorize()
        try output.validate()
        guard output.jobId == jobID.uuidString.lowercased(), output.offset == offset, output.data.count <= count else { throw CompanionJobError.invalidReply }
        return output
    }

    func deviceFailure(_ code: String, _ message: String) -> WindowsMCPToolError {
        WindowsMCPToolError(code: .runtimeFailure, message: message, details: ["deviceCode": code])
    }
}
#endif
