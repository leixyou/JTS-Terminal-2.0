#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices
import JTSCompanionIPC

extension CompanionDevicesModel {
    /// Async lane opens must not accept an earlier origin after a settings change.
    /// Re-read after installing change observers and at file request boundaries.
    func requireRelayConfiguration(deviceID: UUID, expected: CompanionIPCOpen) async throws {
        let current = try await relayConfiguration(deviceID: deviceID)
        guard current.relayURL == expected.relayURL, current.peerSPKI == expected.peerSPKI,
              current.allowWindows10TLS12 == expected.allowWindows10TLS12,
              current.privateKey == expected.privateKey else { throw CompanionDeviceError.storageConflict }
    }

    /// Verify every pinned peer before storing any device change. Temporary checks
    /// never inherit the live route or submit work. The catalog is staged separately
    /// so a failed device write always leaves the old usable station available.
    func moveRelay(devices expected: [CompanionSavedDevice], to origin: String,
                   replacingOrigin: String? = nil,
                   prepareCatalog: () async throws -> Void) async throws {
        guard !storeBusy else { throw CompanionDeviceError.operationInProgress }
        storeBusy = true
        defer { storeBusy = false }
        if let replacingOrigin {
            let current = try await withRegistry { try await registry.snapshot() }
            let actual = current?.devices.filter { $0.revokedAt == nil && $0.relayURL == replacingOrigin } ?? []
            guard Set(actual.map(\.id)) == Set(expected.map(\.id)) else { throw CompanionDeviceError.storageConflict }
        }
        for device in expected {
            try Task.checkCancellation()
            let original = try await withRegistry { try await registry.openConfiguration(deviceID: device.id) }
            guard original.relayURL == device.relayURL, original.peerSPKI == device.peerSPKI else {
                throw CompanionDeviceError.storageConflict
            }
            let candidate = CompanionIPCOpen(privateKey: original.privateKey, peerSPKI: original.peerSPKI,
                relayURL: origin, allowWindows10TLS12: original.allowWindows10TLS12)
            let client = makeConnection()
            do {
                let state = try await client.open(candidate)
                try state.validate()
                guard state.phase == "connected" else { throw CompanionDeviceError.invalidInput }
                await client.invalidate()
            } catch {
                await client.invalidate()
                throw error
            }
        }
        try Task.checkCancellation()
        try await prepareCatalog()
        try Task.checkCancellation()
        guard !expected.isEmpty else { return }
        let value = try await withRegistry {
            try await registry.updateRelay(devices: expected, relayURL: origin, replacingOrigin: replacingOrigin)
        }
        applyRelaySnapshot(value, changedIDs: expected.map(\.id))
    }
}
#endif
