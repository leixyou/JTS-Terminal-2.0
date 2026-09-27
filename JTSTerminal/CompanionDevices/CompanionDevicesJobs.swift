#if ENABLE_RDP_2
import Foundation
import JTSCompanionIPC

extension CompanionDevicesModel {
    var canSubmitJob: Bool {
        guard let route = selectedRoute else { return false }
        return route.hasRoute && !route.busy && route.verifiedGrant != nil && route.capabilities.contains("job.submit")
    }

    /// A fresh ID is never retried automatically after uncertain delivery.
    @discardableResult
    func submitJob(script: String, directory: String, timeoutSeconds: Int, allowDisconnected: Bool, deviceID: UUID? = nil) async -> UUID? {
        guard let target = deviceID ?? selectedID, let route = routes[target], route.hasRoute,
              route.capabilities.contains("job.submit"), let client = route.connection,
              let grant = route.verifiedGrant, let token = route.begin() else { return nil }
        defer { route.finish(token) }
        var submitted: CompanionDeviceJob?
        do {
            guard (1...86_400).contains(timeoutSeconds) else { throw CompanionJobError.invalidRequest }
            let payload = try CompanionPowerShellRequest.payload(script: script, directory: directory)
            guard payload.count <= route.maximumPayloadBytes else { throw CompanionJobError.invalidRequest }
            let now = Date()
            let metadata = CompanionJobMetadata(id: UUID(), deviceID: route.deviceID, grantID: grant,
                createdAt: now, deadline: now.addingTimeInterval(TimeInterval(timeoutSeconds)), allowDisconnected: allowDisconnected)
            try metadata.validate()
            let request = CompanionIPCSubmit(grantID: grant, jobID: metadata.id, kind: "powershell.v1",
                deadlineUnixMilliseconds: metadata.deadlineMilliseconds, allowDisconnected: allowDisconnected, payload: payload)
            try request.validate()
            _ = try await trustedConfiguration(route, token: token)
            guard let journal else { throw CompanionJobError.journalUnavailable }
            try await journal.append(metadata)
            // Journal persistence can suspend; a disconnect or revoke must still prevent submission.
            _ = try await trustedConfiguration(route, token: token)
            let job = CompanionDeviceJob(metadata: metadata); submitted = job; route.jobs.insert(job, at: 0)
            let receipt = try await client.submit(request)
            _ = try await trustedConfiguration(route, token: token)
            try job.accept(receipt)
            return job.id
        } catch {
            if route.generation == token {
                submitted?.errorCode = "JOB_SUBMISSION_NOT_CONFIRMED"
                jobFailure(error, route: route, token: token)
            }
            return submitted?.id
        }
    }

    func refreshJob(_ id: UUID, deviceID: UUID? = nil) async { await performJob(id, deviceID: deviceID, action: .refresh) }
    func cancelJob(_ id: UUID, deviceID: UUID? = nil) async { await performJob(id, deviceID: deviceID, action: .cancel) }
    func readJobOutput(_ id: UUID, deviceID: UUID? = nil) async { await performJob(id, deviceID: deviceID, action: .output) }
    func clearJobOutput(_ id: UUID) { selectedRoute?.jobs.first { $0.id == id }?.output = Data() }

    func forgetFinishedJob(_ id: UUID, deviceID: UUID) async {
        guard let route = routes[deviceID], let job = route.jobs.first(where: { $0.id == id }),
              job.isTerminal, let journal, let token = route.begin() else { return }
        defer { route.finish(token) }
        do {
            try await journal.remove(id)
            // Only local metadata is removed. This never requests remote deletion or cancellation.
            route.jobs.removeAll { $0.id == id }
        } catch { if route.generation == token { route.errorCode = "JOB_JOURNAL_UNAVAILABLE" } }
    }

    private enum JobAction: String { case refresh = "job.get", cancel = "job.cancel", output = "job.output" }
    private func performJob(_ id: UUID, deviceID: UUID?, action: JobAction) async {
        guard let target = deviceID ?? selectedID, let route = routes[target], route.hasRoute,
              let client = route.connection, let job = route.jobs.first(where: { $0.id == id }),
              route.verifiedGrant == job.metadata.grantID, route.capabilities.contains(action.rawValue),
              let token = route.begin() else { return }
        defer { route.finish(token) }
        do {
            _ = try await trustedConfiguration(route, token: token)
            if action == .output {
                let offset = job.output.count
                guard offset < 1_048_576, route.maximumOutputChunkBytes > 0 else { return }
                let maximumBytes = min(32768, route.maximumOutputChunkBytes)
                let output = try await client.output(CompanionIPCOutput(grantID: job.metadata.grantID,
                    jobID: id, offset: offset, maximumBytes: maximumBytes))
                _ = try await trustedConfiguration(route, token: token)
                try output.validate()
                guard output.jobId == id.uuidString.lowercased(), output.offset == offset,
                      output.data.count <= maximumBytes else { throw CompanionJobError.invalidReply }
                job.output.append(output.data); job.errorCode = nil
            } else {
                let receipt = try await (action == .cancel
                    ? client.cancel(grantID: job.metadata.grantID, jobID: id)
                    : client.job(grantID: job.metadata.grantID, jobID: id))
                _ = try await trustedConfiguration(route, token: token)
                try job.accept(receipt)
            }
        } catch {
            guard route.generation == token else { return }
            job.errorCode = action == .cancel ? "JOB_CANCELLATION_NOT_CONFIRMED" : "JOB_OBSERVATION_NOT_CONFIRMED"
            jobFailure(error, route: route, token: token)
        }
    }

    private func jobFailure(_ error: Error, route: CompanionDeviceRoute, token: UUID) {
        if let error = error as? CompanionJobError {
            switch error {
            case .invalidRequest: route.errorCode = "JOB_REQUEST_INVALID"
            case .journalUnavailable: route.errorCode = "JOB_JOURNAL_UNAVAILABLE"
            case .journalFull: route.errorCode = "JOB_JOURNAL_FULL"
            case .invalidReply: failed(error, route: route, token: token)
            }
        } else { failed(error, route: route, token: token) }
    }
}
#endif
