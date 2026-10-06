#if ENABLE_RDP_2
import Combine
import Foundation
import JTSCompanionDevices
import JTSRelayEnrollment

nonisolated protocol NativeScreenSharingEnrollmentExchange: Sendable {
    func create(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt
    func status(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt
    func prepareConfirmation(_ attempt: EnrollmentAttempt, now: Date) async throws -> EnrollmentConfirmation
    func confirm(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt
    func cancel(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt
}
extension EnrollmentClient: NativeScreenSharingEnrollmentExchange {}

/// Mac VNC enrollment reuses the authenticated relay receipt and durable attempt;
/// completion binds the exact peer pin and RDP-byte grant without invoking Windows control RPC.
@MainActor
final class NativeScreenSharingEnrollmentModel: ObservableObject {
    static let shared = NativeScreenSharingEnrollmentModel(store: CompanionEnrollmentStore(persistence:
        CompanionVaultPersistence(account: "jts.mac-desktop.enrollment.v1")))
    @Published private(set) var records: [CompanionEnrollmentRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var errorCode: String?

    private let store: CompanionEnrollmentStore
    private let devices: CompanionDevicesModel
    private let bindings: CompanionTargetRouteStore
    private let makeClient: (String) async throws -> any NativeScreenSharingEnrollmentExchange

    init(store: CompanionEnrollmentStore, devices: CompanionDevicesModel? = nil, bindings: CompanionTargetRouteStore? = nil,
         makeClient: ((String) async throws -> any NativeScreenSharingEnrollmentExchange)? = nil) {
        let devices = devices ?? .shared
        self.store = store; self.devices = devices; self.bindings = bindings ?? .shared
        self.makeClient = makeClient ?? { try await devices.enrollmentClient(relayOrigin: $0) }
    }

    func refresh() async throws {
        guard let identity = try await devices.mcpSnapshot() else { records = []; return }
        records = try await store.records(controllerDeviceId: identity.deviceID)
    }

    func create(relayURL: String, targetID: UUID, targetBinding: String,
                authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck = {}) async throws -> CompanionEnrollmentRecord {
        guard !busy else { throw EnrollmentError.busy }
        busy = true; errorCode = nil; defer { busy = false }
        try authorize()
        guard let identity = try await devices.mcpSnapshot(createIdentity: true) else { throw CompanionDeviceError.notInitialized }
        let origin = try EnrollmentWire.origin(relayURL)
        try await refresh()
        let revocations = try await devices.revocations?.records() ?? []
        try authorize()
        guard !revocations.contains(where: {
            $0.receipt == nil && $0.targetID == targetID && $0.targetBinding == targetBinding
        }) else { throw EnrollmentError.remote("MAC_REVOCATION_PENDING") }
        if let existing = records.last(where: {
            $0.targetID == targetID && $0.targetBinding == targetBinding &&
            ["creating", "pending", "claimed", "bound", "complete"].contains($0.state) &&
            (try? EnrollmentCode($0.attempt.code).relayOrigin) == origin
        }) {
            let resumed = try await advanceRecord(existing, authorize: authorize)
            if !["cancelled", "expired"].contains(resumed.state) { return resumed }
        }
        let request = try EnrollmentRequest(controllerSPKI: identity.publicSPKI, allowWindows10TLS12: false)
        let record = CompanionEnrollmentRecord(attempt: try EnrollmentAttempt(relayOrigin: origin, request: request),
                                                targetID: targetID, targetBinding: targetBinding)
        try authorize()
        try await store.save(record, controllerDeviceId: identity.deviceID)
        try await refresh()
        return try await advanceRecord(record, authorize: authorize)
    }

    func advance(id: String, targetID: UUID, targetBinding: String,
                 authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck = {}) async throws -> CompanionEnrollmentRecord {
        guard !busy else { throw EnrollmentError.busy }
        busy = true; errorCode = nil; defer { busy = false }
        try authorize(); try await refresh()
        guard let record = records.first(where: { $0.id == id }), record.targetID == targetID,
              record.targetBinding == targetBinding else { throw EnrollmentError.changed }
        return try await advanceRecord(record, authorize: authorize)
    }

    func cancel(id: String, authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck = {}) async throws -> CompanionEnrollmentRecord {
        guard !busy else { throw EnrollmentError.busy }
        busy = true; defer { busy = false }
        try authorize(); try await refresh()
        guard var record = records.first(where: { $0.id == id }),
              !["bound", "complete"].contains(record.state) else { throw EnrollmentError.changed }
        let client = try await makeClient(EnrollmentCode(record.attempt.code).relayOrigin)
        try authorize()
        let receipt = try await client.cancel(record.attempt)
        try record.attempt.check(receipt)
        guard [.cancelled, .expired].contains(receipt.state) else { throw EnrollmentError.changed }
        try authorize(); record.state = receipt.state.rawValue; try await save(record)
        return record
    }

    func present(_ error: Error) {
        if let failure = error as? EnrollmentError, case .remote(let code) = failure { errorCode = code }
        else { errorCode = "ENROLLMENT_RETRY_REQUIRED" }
    }

    private func advanceRecord(_ original: CompanionEnrollmentRecord,
                               authorize: @escaping CompanionDevicesModel.MCPAuthorityCheck) async throws -> CompanionEnrollmentRecord {
        var record = original
        if ["cancelled", "expired", "confirmationRequired"].contains(record.state) { return record }
        if let deviceID = record.deviceID {
            let request = try EnrollmentRequest.decode(record.attempt.request)
            guard let grantID = UUID(uuidString: request.rdpGrantID) else { throw EnrollmentError.invalidMessage }
            try await devices.revocations?.requireAllowed(deviceID: deviceID, grantID: grantID)
            try authorize()
        }
        let origin = try EnrollmentCode(record.attempt.code).relayOrigin
        let client = try await makeClient(origin)
        try authorize()
        var receipt: EnrollmentReceipt
        do {
            receipt = try await (record.state == "creating" ? client.create(record.attempt) : client.status(record.attempt))
            // Keep validation here too, so injected/future exchanges cannot promote an unsigned bound receipt.
            try record.attempt.check(receipt)
        } catch {
            if let recovered = record.attempt.recoveryState(after: error, localState: record.state) {
                try authorize(); record.state = recovered; try await save(record); return record
            }
            throw error
        }
        try authorize()
        if let claim = receipt.claim, [.claimed, .bound].contains(receipt.state) {
            _ = try record.attempt.bundle(for: claim)
            record.attempt.verifiedClaim = claim
            if let proof = receipt.confirmation { record.attempt.confirmation = proof }
            record.state = receipt.state.rawValue
            try await save(record)
            if receipt.state == .claimed {
                try authorize()
                record.attempt.confirmation = try await client.prepareConfirmation(record.attempt, now: Date())
                try await save(record) // Reuse this exact authorization after an ambiguous commit or expiry.
                receipt = try await client.confirm(record.attempt)
                try record.attempt.check(receipt); try authorize()
            }
        }
        record.state = receipt.state.rawValue
        try await save(record)
        guard receipt.state == .bound, let claim = record.attempt.verifiedClaim,
              record.attempt.confirmation != nil, let targetID = record.targetID, let targetBinding = record.targetBinding else { return record }
        let bundle = try record.attempt.bundle(for: claim)
        guard let controlGrant = UUID(uuidString: bundle.grantID), let rdpGrant = UUID(uuidString: bundle.rdpGrantID),
              let fileGrant = UUID(uuidString: bundle.fileGrantID), let pairingID = UUID(uuidString: bundle.pairingID) else {
            throw EnrollmentError.invalidMessage
        }
        try authorize()
        let deviceID = try await devices.importPublicDevice(name: bundle.name, relayURL: origin, peerSPKI: bundle.peerSPKI,
            peerDeviceID: bundle.peerDeviceID, compatibility: false)
        record.deviceID = deviceID; try await save(record)
        try authorize()
        try await devices.revocations?.requireAllowed(deviceID: deviceID, grantID: rdpGrant)
        try authorize()
        try await bindings.requireAssignment(targetID: targetID, targetBinding: targetBinding, deviceID: deviceID)
        try authorize()
        try await bindings.bind(targetID: targetID, targetBinding: targetBinding, deviceID: deviceID,
            grantID: controlGrant, fileGrantID: fileGrant, rdpGrantID: rdpGrant, pairingID: pairingID, desktopRoute: .rdp)
        try authorize()
        record.state = "complete"; try await save(record)
        return record
    }

    private func save(_ record: CompanionEnrollmentRecord) async throws {
        let request = try EnrollmentRequest.decode(record.attempt.request)
        try await store.save(record, controllerDeviceId: request.controllerDeviceID)
        records = try await store.records(controllerDeviceId: request.controllerDeviceID)
    }
}
#endif
