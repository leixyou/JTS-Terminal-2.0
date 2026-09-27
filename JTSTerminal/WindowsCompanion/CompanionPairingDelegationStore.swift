#if ENABLE_RDP_2
import Combine
import CryptoKit
import Foundation

@MainActor
final class CompanionPairingDelegationStore: ObservableObject {
    static let shared = CompanionPairingDelegationStore()

    @Published private(set) var grants: [CompanionPairingDelegationGrant] = []
    @Published private(set) var persistenceError: String?
    private let persistence: CompanionPairingDelegationPersistence
    private let localIdentityLoader: WindowsCompanionClient.LocalIdentityLoader
    /// Even a failed disk write revokes authority for this process. Every
    /// following transaction retries these exact tombstones before proceeding.
    private struct PendingTombstone {
        var date: Date
        var eventCount: UInt64
    }
    private var pendingTombstones: [UUID: PendingTombstone] = [:]

    init(
        directoryURL: URL = CompanionPairingDelegationStore.defaultDirectoryURL,
        localIdentityLoader: @escaping WindowsCompanionClient.LocalIdentityLoader = {
            try await RDPCompanionKeychainAccess.shared.localIdentity(targetID: $0)
        }
    ) {
        persistence = CompanionPairingDelegationPersistence(directoryURL: directoryURL)
        self.localIdentityLoader = localIdentityLoader
        try? refresh()
    }

    /// Call only when the profile's existing AI desktop-control permission is
    /// enabled. Replacing a revoked grant additionally requires an explicit
    /// re-enable/reset of that permission; reconnect alone is insufficient.
    func createExport(
        targetID: UUID,
        targetBinding: String,
        peer: WindowsCompanionPeerIdentity,
        at date: Date = Date(),
        validFor: TimeInterval = 30 * 60,
        allowReplacingRevokedGrant: Bool = false
    ) async throws -> CompanionPairingDelegationExport {
        let restoreSnapshot: [CompanionPairingDelegationGrant]?
        if allowReplacingRevokedGrant {
            restoreSnapshot = try transaction { records in
                let targetRecords = records.filter { $0.targetID == targetID }
                // A saturated event counter cannot establish a newer restore
                // boundary. Keep that device blocked rather than wrap it.
                guard !targetRecords.contains(where: { $0.revocationRevision == .max }) else {
                    throw CompanionPairingDelegationFailure.grantRevoked
                }
                return targetRecords
            }
        } else {
            restoreSnapshot = nil
        }
        let localIdentity = try await localIdentityLoader(targetID)
        try Task.checkCancellation()
        guard localIdentity.clientDeviceID == peer.clientDeviceID,
              WindowsCompanionAuthorizationProof.fingerprint(
                publicKeyDER: localIdentity.signingKey.publicKey.derRepresentation
              ) == peer.clientFingerprintSHA256,
              WindowsCompanionAuthorizationProof.fingerprint(publicKeyDER: peer.publicKeyDER)
                == peer.fingerprintSHA256 else {
            throw CompanionPairingDelegationFailure.identityChanged
        }
        return try transaction { records in
            let targetGrants = records.filter { $0.targetID == targetID }
            if let restoreSnapshot, targetGrants != restoreSnapshot {
                throw CompanionPairingDelegationFailure.grantRevoked
            }
            if !allowReplacingRevokedGrant,
               targetGrants.contains(where: \.isRevoked),
               !targetGrants.contains(where: { !$0.isRevoked }) {
                throw CompanionPairingDelegationFailure.grantRevoked
            }
            let grant: CompanionPairingDelegationGrant
            if let current = targetGrants.first(where: { !$0.isRevoked }) {
                guard current.matches(targetID: targetID, targetBinding: targetBinding, peer: peer) else {
                    throw CompanionPairingDelegationFailure.identityChanged
                }
                grant = current
            } else {
                grant = CompanionPairingDelegationGrant(
                    grantID: UUID(), targetID: targetID, targetBinding: targetBinding,
                    macDeviceID: peer.clientDeviceID,
                    macFingerprintSHA256: peer.clientFingerprintSHA256,
                    windowsDeviceID: peer.deviceID,
                    windowsFingerprintSHA256: peer.fingerprintSHA256,
                    createdAt: date
                )
                records.append(grant)
            }
            let request = try CompanionPairingDelegationEnrollmentRequest(
                grant: grant, localIdentity: localIdentity, issuedAt: date, validFor: validFor
            )
            return CompanionPairingDelegationExport(grant: grant, requestJSON: try request.encoded())
        }
    }

    func activeGrant(
        targetID: UUID, targetBinding: String, peer: WindowsCompanionPeerIdentity
    ) throws -> CompanionPairingDelegationGrant? {
        try transaction { records in
            guard let grant = records.first(where: { $0.targetID == targetID && !$0.isRevoked }) else {
                return nil
            }
            guard grant.matches(targetID: targetID, targetBinding: targetBinding, peer: peer) else {
                throw CompanionPairingDelegationFailure.identityChanged
            }
            return grant
        }
    }

    @discardableResult
    func revoke(grantID: UUID, at date: Date = Date()) throws -> CompanionPairingDelegationGrant {
        let pending = pendingTombstones[grantID]
        pendingTombstones[grantID] = PendingTombstone(
            date: pending?.date ?? date,
            eventCount: Self.addingRevocations(pending?.eventCount ?? 0, 1)
        )
        if let index = grants.firstIndex(where: { $0.grantID == grantID }) {
            grants[index].revokedAt = grants[index].revokedAt ?? date
            grants[index].pendingRemoteRevocation = true
            grants[index].revocationRevision = Self.addingRevocations(grants[index].revocationRevision, 1)
        }
        return try transaction { records in
            guard let grant = records.first(where: { $0.grantID == grantID }) else {
                throw CompanionPairingDelegationFailure.grantMissing
            }
            return grant
        }
    }

    func markRemoteRevocationConfirmed(grantID: UUID) throws {
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.grantID == grantID }),
                  records[index].isRevoked else {
                throw CompanionPairingDelegationFailure.grantMissing
            }
            records[index].pendingRemoteRevocation = false
        }
    }

    /// Must be called on the frame-authenticated authorization result both
    /// during initial pairing and automatic reconnect. Revoked records remain
    /// authoritative even if Windows still reports its old persisted pairing.
    func validateAuthorization(
        _ authorization: WindowsCompanionAuthorizationResult,
        targetID: UUID,
        targetBinding: String,
        peer: WindowsCompanionPeerIdentity
    ) throws {
        try transaction { records in
            let matching = records.filter { $0.matches(targetID: targetID, targetBinding: targetBinding, peer: peer) }
            if authorization.authorizationSource == .interactive {
                guard authorization.delegationGrantID == nil else {
                    throw CompanionPairingDelegationFailure.receiptMismatch
                }
                // Do not silently downgrade an enrolled/revoked device into a
                // legacy interactive authorization after reconnect.
                guard matching.isEmpty else { throw CompanionPairingDelegationFailure.receiptMismatch }
                return
            }
            guard let id = authorization.delegationGrantID,
                  let grant = matching.first(where: { $0.grantID == id }) else {
                throw CompanionPairingDelegationFailure.grantMissing
            }
            guard !grant.isRevoked else { throw CompanionPairingDelegationFailure.grantRevoked }
            guard authorization.clientDeviceID == grant.macDeviceID,
                  authorization.clientFingerprintSHA256 == grant.macFingerprintSHA256 else {
                throw CompanionPairingDelegationFailure.receiptMismatch
            }
        }
    }

    func refresh() throws {
        try transaction { _ in () }
    }

    private func transaction<T>(
        _ body: (inout [CompanionPairingDelegationGrant]) throws -> T
    ) throws -> T {
        do {
            // Commit revocations separately so a rejected operation cannot
            // roll back a pending tombstone in the same transaction.
            if !pendingTombstones.isEmpty {
                let tombstones = pendingTombstones
                let (_, updated) = try persistence.transaction { records in
                    for (id, tombstone) in tombstones {
                        guard let index = records.firstIndex(where: { $0.grantID == id }) else { continue }
                        records[index].revokedAt = records[index].revokedAt ?? tombstone.date
                        records[index].pendingRemoteRevocation = true
                        records[index].revocationRevision = Self.addingRevocations(
                            records[index].revocationRevision, tombstone.eventCount
                        )
                    }
                }
                grants = updated
                pendingTombstones.removeAll()
            }
            let (value, updated) = try persistence.transaction(body)
            grants = updated
            persistenceError = nil
            return value
        } catch {
            persistenceError = error.localizedDescription
            throw error
        }
    }

    private static func addingRevocations(_ revision: UInt64, _ count: UInt64) -> UInt64 {
        let (next, overflow) = revision.addingReportingOverflow(count)
        return overflow ? .max : next
    }

    nonisolated static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("JTS Terminal/Security/Companion Pairing", isDirectory: true)
    }
}
#endif
