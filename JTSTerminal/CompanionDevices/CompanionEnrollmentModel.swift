#if ENABLE_RDP_2
import Foundation
import Observation
import JTSCompanionDevices
import JTSRelayEnrollment

/// Enrollment lifetime is independent from RDP sessions, passwords, and desktop windows.
@Observable @MainActor
final class CompanionEnrollmentModel {
    static let shared = CompanionEnrollmentModel(store: CompanionEnrollmentStore(persistence:
        CompanionVaultPersistence(account: "jts.companion.enrollment.v1")))
    private(set) var records: [CompanionEnrollmentRecord] = []
    private(set) var busy = false
    private(set) var errorCode: String?
    private let store: CompanionEnrollmentStore
    private let devices: CompanionDevicesModel
    private let bindings: CompanionTargetRouteStore

    init(store: CompanionEnrollmentStore, devices: CompanionDevicesModel = .shared, bindings: CompanionTargetRouteStore = .shared) {
        self.store = store; self.devices = devices; self.bindings = bindings
    }
    func refresh() async throws {
        guard let identity = try await devices.mcpSnapshot() else { records = []; return }
        records = try await store.records(controllerDeviceId: identity.deviceID)
    }
    func create(relayURL: String, compatibility: Bool, targetID: UUID? = nil, targetBinding: String? = nil,
                authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck = {}) async throws -> CompanionEnrollmentRecord {
        guard !busy else { throw EnrollmentError.busy }; busy = true; errorCode = nil; defer { busy = false }
        try authorize()
        guard let identity = try await devices.mcpSnapshot(createIdentity: true) else { throw CompanionDeviceError.notInitialized }
        try await refresh()
        let origin = try EnrollmentWire.origin(relayURL)
        try await CompanionRevocationModel.shared.refresh()
        guard !CompanionRevocationModel.shared.records.contains(where: {
            $0.receipt == nil && $0.targetID == targetID && $0.targetBinding == targetBinding
        }) else { throw EnrollmentError.remote("WINDOWS_REVOCATION_PENDING") }
        if let previous = records.last(where: {
            $0.targetID == targetID && $0.targetBinding == targetBinding &&
            ["creating", "pending", "claimed", "bound"].contains($0.state) &&
            (try? EnrollmentCode($0.attempt.code).relayOrigin) == origin &&
            ((try? EnrollmentRequest.decode($0.attempt.request).allowWindows10TLS12) ?? false) == compatibility
        }) {
            let resumed = try await advanceRecord(previous, authorize: authorize)
            if !["expired", "cancelled"].contains(resumed.state) { return resumed }
        }
        let request = try EnrollmentRequest(controllerSPKI: identity.publicSPKI, allowWindows10TLS12: compatibility)
        let record = CompanionEnrollmentRecord(attempt: try EnrollmentAttempt(relayOrigin: relayURL, request: request),
                                                targetID: targetID, targetBinding: targetBinding)
        try authorize()
        try await store.save(record, controllerDeviceId: identity.deviceID)
        try await refresh()
        // Network interruption retains this exact code and request for an idempotent retry.
        return try await advanceRecord(record, authorize: authorize)
    }
    func advance(id: String, targetID: UUID? = nil, targetBinding: String? = nil,
                 authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck = {}) async throws -> CompanionEnrollmentRecord {
        guard !busy else { throw EnrollmentError.busy }; busy = true; errorCode = nil; defer { busy = false }
        try authorize(); try await refresh()
        guard let record = records.first(where: { $0.id == id }),
              targetID == nil || record.targetID == targetID && record.targetBinding == targetBinding else {
            throw EnrollmentError.changed
        }
        return try await advanceRecord(record, authorize: authorize)
    }
    func cancel(id: String, targetID: UUID? = nil, targetBinding: String? = nil,
                authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck = {}) async throws -> CompanionEnrollmentRecord {
        guard !busy else { throw EnrollmentError.busy }; busy = true; defer { busy = false }
        try authorize(); try await refresh()
        guard var record = records.first(where: { $0.id == id }),
              targetID == nil || record.targetID == targetID && record.targetBinding == targetBinding else { throw EnrollmentError.changed }
        guard !["bound", "complete"].contains(record.state) else { throw EnrollmentError.changed }
        let code = try EnrollmentCode(record.attempt.code)
        let client = try await devices.enrollmentClient(relayOrigin: code.relayOrigin)
        try authorize()
        let receipt = try await client.cancel(record.attempt)
        guard receipt.state == .cancelled || receipt.state == .expired else { throw EnrollmentError.changed }
        record.state = receipt.state.rawValue
        try await save(record); return record
    }
    func present(_ error: Error) {
        if let failure = error as? EnrollmentError, case .remote(let code) = failure { errorCode = code }
        else { errorCode = "ENROLLMENT_RETRY_REQUIRED" }
    }
    func revoke(device: CompanionSavedDevice, targetID: UUID?,
                currentBinding: CompanionTargetRouteBinding? = nil,
                authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> String {
        guard !busy else { throw EnrollmentError.busy }; busy = true; defer { busy = false }
        try authorize(); try await refresh()
        var route = currentBinding
        if route == nil, let targetID,
           let targetFingerprint = records.last(where: { $0.targetID == targetID && $0.deviceID == device.id })?.targetBinding {
            route = try await bindings.binding(targetID: targetID, targetBinding: targetFingerprint)
        }
        let candidates = records.filter { $0.targetID == targetID && $0.deviceID == device.id }
        let epoch = try CompanionRevocationEpoch.resolve(device: device, route: route, records: candidates)
        let queued = try await CompanionRevocationModel.shared.enqueue(bundle: epoch.bundle,
            deviceID: device.id, targetID: targetID, targetBinding: route?.targetBinding ?? epoch.record?.targetBinding, authorize: authorize)
        if var record = epoch.record { record.state = "cancelled"; try await save(record) }
        await CompanionRevocationModel.shared.retryPending()
        return CompanionRevocationModel.shared.records.first(where: {
            $0.request.revocationId == queued.request.revocationId
        })?.state ?? "revocationPending"
    }
    private func advanceRecord(_ original: CompanionEnrollmentRecord,
                               authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> CompanionEnrollmentRecord {
        var record = original
        if ["cancelled", "expired"].contains(record.state) { return record }
        let code = try EnrollmentCode(record.attempt.code)
        let client = try await devices.enrollmentClient(relayOrigin: code.relayOrigin)
        try authorize()
        var receipt: EnrollmentReceipt
        do {
            receipt = try await (record.state == "creating" ? client.create(record.attempt) : client.status(record.attempt))
        } catch {
            // Ask the node first: a lost successful commit remains recoverable after expiry.
            if let state = record.attempt.recoveryState(after: error, localState: record.state) {
                try authorize(); record.state = state; try await save(record); return record
            }
            throw error
        }
        try authorize()
        if let claim = receipt.claim, [.claimed, .bound].contains(receipt.state) {
            _ = try record.attempt.bundle(for: claim)
            record.attempt.verifiedClaim = claim
            if let confirmation = receipt.confirmation { record.attempt.confirmation = confirmation }
            record.state = receipt.state.rawValue
            // Save verified evidence before a possibly ambiguous remote commit response.
            try await save(record)
            if receipt.state == .claimed {
                try authorize()
                record.attempt.confirmation = try await client.prepareConfirmation(record.attempt)
                try await save(record)
                receipt = try await client.confirm(record.attempt); try authorize()
            }
        }
        record.state = receipt.state.rawValue; try await save(record)
        if [.cancelled, .expired].contains(receipt.state), let deviceID = record.deviceID {
            devices.routes[deviceID]?.disconnect()
        }
        if receipt.state == .bound, let claim = record.attempt.verifiedClaim {
            let bundle = try record.attempt.bundle(for: claim)
            try authorize()
            let deviceID = try await devices.importPublicDevice(name: bundle.name, relayURL: code.relayOrigin,
                peerSPKI: bundle.peerSPKI, peerDeviceID: bundle.peerDeviceID, compatibility: bundle.allowWindows10TLS12 ?? false)
            record.deviceID = deviceID; try await save(record)
            try authorize()
            if let targetID = record.targetID, let targetBinding = record.targetBinding {
                try await bindings.requireAssignment(targetID: targetID, targetBinding: targetBinding, deviceID: deviceID)
            }
            // Windows may still be committing its bound receipt. A failed probe retains bound state.
            do {
                _ = try await devices.mcpConnect(deviceID: deviceID, grantID: UUID(uuidString: bundle.grantID)!, authorize: authorize)
                try authorize()
                if let targetID = record.targetID, let targetBinding = record.targetBinding {
                    let existing = try await bindings.binding(targetID: targetID, targetBinding: targetBinding)
                    try await bindings.bind(targetID: targetID, targetBinding: targetBinding, deviceID: deviceID,
                        grantID: UUID(uuidString: bundle.grantID)!, fileGrantID: UUID(uuidString: bundle.fileGrantID),
                        rdpGrantID: UUID(uuidString: bundle.rdpGrantID), pairingID: UUID(uuidString: bundle.pairingID),
                        desktopRoute: existing?.effectiveDesktopRoute ?? .companion)
                }
                record.state = "complete"; try await save(record)
            } catch {
                try authorize()
                errorCode = "BOUND_CONTROL_NOT_READY"
            }
        }
        return record
    }
    private func save(_ record: CompanionEnrollmentRecord) async throws {
        let request = try EnrollmentRequest.decode(record.attempt.request)
        try await store.save(record, controllerDeviceId: request.controllerDeviceID)
        records = try await store.records(controllerDeviceId: request.controllerDeviceID)
    }
}
#endif
