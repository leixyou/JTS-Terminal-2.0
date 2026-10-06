import Foundation
import JTSCompanionIPC

public extension CompanionTransportClient {
    func authorizeDesktop(_ request: CompanionIPCDesktopAuthorization) async throws -> CompanionDesktopAcknowledgement {
        try await perform(.authorizeDesktop, payload: request, response: CompanionDesktopAcknowledgement.self)
    }
    func state() async throws -> CompanionIPCState {
        try await perform(.state, payload: CompanionIPCEmpty(), response: CompanionIPCState.self)
    }
    func status(grantID: UUID) async throws -> CompanionControlStatus {
        try await perform(.status, payload: CompanionIPCGrant(grantID: grantID), response: CompanionControlStatus.self)
    }
    func submit(_ request: CompanionIPCSubmit) async throws -> CompanionJobReceipt {
        try await perform(.submit, payload: request, response: CompanionJobReceipt.self)
    }
    func job(grantID: UUID, jobID: UUID) async throws -> CompanionJobReceipt {
        try await perform(.job, payload: CompanionIPCJob(grantID: grantID, jobID: jobID), response: CompanionJobReceipt.self)
    }
    func cancel(grantID: UUID, jobID: UUID) async throws -> CompanionJobReceipt {
        try await perform(.cancel, payload: CompanionIPCJob(grantID: grantID, jobID: jobID), response: CompanionJobReceipt.self)
    }
    func output(_ request: CompanionIPCOutput) async throws -> CompanionJobOutput {
        try await perform(.output, payload: request, response: CompanionJobOutput.self)
    }
}
