#if ENABLE_RDP_2
import Foundation
import Observation
import JTSCompanionClient
import JTSCompanionIPC

nonisolated protocol CompanionDeviceConnection: Sendable {
    func open(_ configuration: CompanionIPCOpen) async throws -> CompanionIPCState
    func status(grantID: UUID) async throws -> CompanionControlStatus
    func submit(_ request: CompanionIPCSubmit) async throws -> CompanionJobReceipt
    func job(grantID: UUID, jobID: UUID) async throws -> CompanionJobReceipt
    func cancel(grantID: UUID, jobID: UUID) async throws -> CompanionJobReceipt
    func output(_ request: CompanionIPCOutput) async throws -> CompanionJobOutput
    func invalidate() async
}
extension CompanionTransportClient: CompanionDeviceConnection {}

/// Application-owned, one serialized control connection per verified device.
@Observable @MainActor
final class CompanionDeviceRoute {
    let deviceID: UUID
    var busy = false
    var errorCode: String?
    var openedAt: Date?
    var verifiedAt: Date?
    var verifiedGrant: UUID?
    var capabilities: [String] = []
    var maximumPayloadBytes = 0
    var maximumOutputChunkBytes = 0
    var hasRoute = false
    var jobs: [CompanionDeviceJob] = []
    @ObservationIgnored var connection: (any CompanionDeviceConnection)?
    @ObservationIgnored var generation = UUID()

    init(deviceID: UUID) { self.deviceID = deviceID }

    func begin() -> UUID? {
        guard !busy else { return nil }
        busy = true; errorCode = nil
        return generation
    }
    func finish(_ token: UUID) { if generation == token { busy = false } }
    func clearGrant() {
        verifiedAt = nil; verifiedGrant = nil; capabilities = []
        maximumPayloadBytes = 0; maximumOutputChunkBytes = 0
    }
    func disconnect() {
        generation = UUID(); busy = false
        let old = connection; connection = nil
        hasRoute = false; openedAt = nil; clearGrant()
        // Last remote receipts are historical observations. Closing a transport is not stop confirmation.
        for job in jobs { job.output = Data() }
        if let old { Task { await old.invalidate() } }
    }
}
#endif
