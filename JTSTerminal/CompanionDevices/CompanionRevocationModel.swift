#if ENABLE_RDP_2
import Foundation
import Observation
import JTSCompanionDevices
import JTSRelayEnrollment

@Observable @MainActor
final class CompanionRevocationModel {
    static let shared = CompanionRevocationModel(store: .shared)
    private(set) var records: [CompanionRevocationRecord] = []
    private let store: CompanionRevocationStore
    private let devices: CompanionDevicesModel
    private let bindings: CompanionTargetRouteStore
    @ObservationIgnored private var worker: Task<Void, Never>?
    private var busy = false

    init(store: CompanionRevocationStore, devices: CompanionDevicesModel = .shared,
         bindings: CompanionTargetRouteStore = .shared) {
        self.store = store; self.devices = devices; self.bindings = bindings
    }
    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.retryPending()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func refresh() async throws { records = try await store.records() }
    func enqueue(bundle: EnrollmentBundle, deviceID: UUID, targetID: UUID?, targetBinding: String?,
                 authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> CompanionRevocationRecord {
        try authorize(); try await refresh()
        if let existing = records.last(where: { $0.deviceID == deviceID && $0.request.pairingId == bundle.pairingID }) {
            return existing
        }
        guard let identity = try await devices.mcpSnapshot() else { throw EnrollmentError.invalidIdentity }
        let client = try await devices.enrollmentClient(relayOrigin: bundle.relayURL)
        let request = try await client.prepareRevocation(bundle)
        let record = CompanionRevocationRecord(request: request, controllerSPKI: identity.publicSPKI,
            peerSPKI: bundle.peerSPKI, deviceID: deviceID, targetID: targetID, targetBinding: targetBinding)
        try authorize()
        try await store.save(record)
        // New work is now denied even after a crash. Close all existing lanes locally.
        closeLocal(record)
        try await refresh(); start()
        return record
    }
    func retryPending() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await refresh()
            for var record in records where record.receipt == nil {
                closeLocal(record)
                do {
                    let client = try await devices.enrollmentClient(relayOrigin: record.request.relayOrigin)
                    // Exact signed request is idempotent, including a lost submit response.
                    let status = try await client.submitRevocation(record.request, peerSPKI: record.peerSPKI)
                    if let receipt = status.receipt, status.state == .complete {
                        try receipt.verify(revocation: record.request, peerSPKI: record.peerSPKI)
                        record.receipt = receipt
                        // Remove only this epoch's route, never a later binding.
                        if let target = record.targetID, let fingerprint = record.targetBinding,
                           let route = try await bindings.binding(targetID: target, targetBinding: fingerprint),
                           route.deviceID == record.deviceID, route.grantID.uuidString.lowercased() == record.request.grantId {
                            try await bindings.remove(targetID: target)
                        }
                        try await store.save(record)
                    }
                } catch { /* Retain pending; network failure is not endpoint acknowledgement. */ }
            }
            try await refresh()
        } catch { /* Device operations also fail closed when the deny journal cannot be read. */ }
    }
    private func closeLocal(_ record: CompanionRevocationRecord) {
        devices.routes[record.deviceID]?.disconnect()
        NotificationCenter.default.post(name: .jtsCompanionDeviceTrustChanged, object: record.deviceID)
    }
}
#endif
