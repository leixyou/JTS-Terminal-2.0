#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices

nonisolated enum CompanionDesktopRoutePreference: String, Codable, Sendable { case rdp, companion }

nonisolated struct CompanionPendingDesktopAuthorization: Codable, Equatable, Sendable {
    let grantID: UUID
    let issuedAt: Date
    let expiresAt: Date
}

nonisolated struct CompanionTargetRouteBinding: Codable, Equatable, Sendable {
    let targetID: UUID
    let targetBinding: String
    let deviceID: UUID
    let grantID: UUID
    var fileGrantID: UUID? = nil
    var rdpGrantID: UUID? = nil
    var pairingID: UUID? = nil
    var desktopRoute: CompanionDesktopRoutePreference? = nil
    var desktopGrantID: UUID? = nil
    var desktopGrantExpiresAt: Date? = nil
    var pendingDesktopAuthorization: CompanionPendingDesktopAuthorization? = nil
    var effectiveDesktopRoute: CompanionDesktopRoutePreference { desktopRoute ?? .rdp }
}

nonisolated enum CompanionTargetRouteError: Error, Equatable { case invalid, changed, busy, deviceAssigned, targetAssigned }

/// The route is bound to the existing profile identity as well as its UUID.
/// Changing a saved endpoint cannot silently inherit another machine's route.
actor CompanionTargetRouteStore {
    static let shared = CompanionTargetRouteStore(persistence: CompanionVaultPersistence(
        account: "jts.companion.target-routes.v1"))
    private let persistence: any CompanionDevicePersistence
    private var mutating = false
    private struct Owner: Codable, Equatable {
        let targetID: UUID
        let targetBinding: String
        let deviceID: UUID
    }
    private struct Document: Codable {
        var version: Int
        var routes: [CompanionTargetRouteBinding]
        var owners: [Owner]?
    }

    init(persistence: any CompanionDevicePersistence) { self.persistence = persistence }

    func binding(targetID: UUID, targetBinding: String) async throws -> CompanionTargetRouteBinding? {
        let (_, document) = try await read()
        guard let route = document.routes.first(where: { $0.targetID == targetID }) else { return nil }
        guard route.targetBinding == targetBinding else { throw CompanionTargetRouteError.changed }
        return route
    }

    func bind(targetID: UUID, targetBinding: String, deviceID: UUID, grantID: UUID,
              fileGrantID: UUID? = nil, rdpGrantID: UUID? = nil, pairingID: UUID? = nil,
              desktopRoute: CompanionDesktopRoutePreference? = nil) async throws {
        guard !mutating else { throw CompanionTargetRouteError.busy }
        var route = CompanionTargetRouteBinding(targetID: targetID, targetBinding: targetBinding,
                                               deviceID: deviceID, grantID: grantID,
                                               fileGrantID: fileGrantID, rdpGrantID: rdpGrantID, pairingID: pairingID)
        route.desktopRoute = desktopRoute
        guard Self.valid(route) else { throw CompanionTargetRouteError.invalid }
        mutating = true; defer { mutating = false }
        let (before, original) = try await read()
        var document = original
        try Self.checkOwner(targetID: targetID, targetBinding: targetBinding, deviceID: deviceID, document: document)
        if let previous = document.routes.first(where: { $0.targetID == targetID && $0.deviceID == deviceID && $0.grantID == grantID }) {
            // A normal bind can omit epoch metadata; it must not erase or rewrite
            // the verified epoch needed to revoke this same control grant.
            for (old, new) in [(previous.pairingID, pairingID), (previous.fileGrantID, fileGrantID), (previous.rdpGrantID, rdpGrantID)] {
                if let old, let new, old != new { throw CompanionTargetRouteError.changed }
            }
            route.pairingID = pairingID ?? previous.pairingID
            route.fileGrantID = fileGrantID ?? previous.fileGrantID
            route.rdpGrantID = rdpGrantID ?? previous.rdpGrantID
            route.desktopRoute = desktopRoute ?? previous.desktopRoute
            route.desktopGrantID = previous.desktopGrantID
            route.desktopGrantExpiresAt = previous.desktopGrantExpiresAt
            route.pendingDesktopAuthorization = previous.pendingDesktopAuthorization
            guard Self.valid(route) else { throw CompanionTargetRouteError.invalid }
        }
        if !(document.owners ?? []).contains(where: { $0.deviceID == deviceID }) {
            document.owners = (document.owners ?? []) + [Owner(targetID: targetID, targetBinding: targetBinding, deviceID: deviceID)]
        }
        document.routes.removeAll { $0.targetID == targetID }
        document.routes.append(route)
        guard document.routes.count <= 256, (document.owners?.count ?? 0) <= 256 else { throw CompanionTargetRouteError.invalid }
        try await save(document, replacing: before)
        NotificationCenter.default.post(name: .jtsCompanionTargetRouteChanged, object: targetID)
    }

    /// Called only after a pinned Windows signature confirms durable desktop
    /// authorization. Persisted legacy RDP routes never acquire it implicitly.
    func saveDesktopAuthorization(expected: CompanionTargetRouteBinding, grantID: UUID, expiresAt: Date) async throws {
        guard !mutating else { throw CompanionTargetRouteError.busy }
        mutating = true; defer { mutating = false }
        let (before, original) = try await read()
        guard let index = original.routes.firstIndex(of: expected), expected.effectiveDesktopRoute == .companion,
              expected.pairingID != nil, expiresAt > Date() else { throw CompanionTargetRouteError.changed }
        var document = original
        document.routes[index].desktopGrantID = grantID
        if let pending = expected.pendingDesktopAuthorization {
            guard pending.grantID == grantID, abs(pending.expiresAt.timeIntervalSince(expiresAt)) < 1 else {
                throw CompanionTargetRouteError.changed
            }
        }
        document.routes[index].desktopGrantExpiresAt = expiresAt
        document.routes[index].pendingDesktopAuthorization = nil
        guard Self.valid(document.routes[index]) else { throw CompanionTargetRouteError.invalid }
        try await save(document, replacing: before)
        NotificationCenter.default.post(name: .jtsCompanionTargetRouteChanged, object: expected.targetID)
    }

    /// Preserve the exact unsigned transcript before crossing the network. A
    /// lost Windows acknowledgement retries the same delegation, not a new ID.
    func prepareDesktopAuthorization(expected: CompanionTargetRouteBinding, now: Date = Date()) async throws -> CompanionTargetRouteBinding {
        guard !mutating else { throw CompanionTargetRouteError.busy }
        mutating = true; defer { mutating = false }
        let (before, original) = try await read()
        guard let index = original.routes.firstIndex(of: expected), expected.effectiveDesktopRoute == .companion,
              expected.pairingID != nil else { throw CompanionTargetRouteError.changed }
        if let pending = expected.pendingDesktopAuthorization, pending.expiresAt > now { return expected }
        var document = original
        document.routes[index].pendingDesktopAuthorization = CompanionPendingDesktopAuthorization(grantID: UUID(),
            issuedAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)),
            expiresAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 30 * 86400))
        guard Self.valid(document.routes[index]) else { throw CompanionTargetRouteError.invalid }
        try await save(document, replacing: before)
        return document.routes[index]
    }

    /// Only an authenticated, explicit stale-uncommitted rejection permits a
    /// new proof. A timeout or lost acknowledgement keeps the original proof.
    func discardRejectedDesktopAuthorization(expected: CompanionTargetRouteBinding) async throws -> CompanionTargetRouteBinding {
        guard !mutating else { throw CompanionTargetRouteError.busy }
        mutating = true; defer { mutating = false }
        let (before, original) = try await read()
        guard let index = original.routes.firstIndex(of: expected), expected.pendingDesktopAuthorization != nil else {
            throw CompanionTargetRouteError.changed
        }
        var document = original; document.routes[index].pendingDesktopAuthorization = nil
        try await save(document, replacing: before)
        return document.routes[index]
    }

    func chooseDesktopRoute(expected: CompanionTargetRouteBinding, preference: CompanionDesktopRoutePreference) async throws {
        guard !mutating else { throw CompanionTargetRouteError.busy }
        mutating = true; defer { mutating = false }
        let (before, original) = try await read()
        guard let index = original.routes.firstIndex(of: expected) else { throw CompanionTargetRouteError.changed }
        var document = original; document.routes[index].desktopRoute = preference
        try await save(document, replacing: before)
        NotificationCenter.default.post(name: .jtsCompanionTargetRouteChanged, object: expected.targetID)
    }

    /// Check before contacting a saved peer. Public device/grant IDs are not
    /// authority to borrow another profile's machine or replace its identity.
    func requireAssignment(targetID: UUID, targetBinding: String, deviceID: UUID) async throws {
        let (_, document) = try await read()
        try Self.checkOwner(targetID: targetID, targetBinding: targetBinding, deviceID: deviceID, document: document)
    }

    private static func checkOwner(targetID: UUID, targetBinding: String, deviceID: UUID, document: Document) throws {
        for owner in document.owners ?? [] {
            if owner.deviceID == deviceID && (owner.targetID != targetID || owner.targetBinding != targetBinding) {
                throw CompanionTargetRouteError.deviceAssigned
            }
            if owner.targetID == targetID && (owner.deviceID != deviceID || owner.targetBinding != targetBinding) {
                throw CompanionTargetRouteError.targetAssigned
            }
        }
    }

    func remove(targetID: UUID) async throws {
        guard !mutating else { throw CompanionTargetRouteError.busy }
        mutating = true; defer { mutating = false }
        let (before, original) = try await read()
        guard original.routes.contains(where: { $0.targetID == targetID }) else { return }
        var document = original
        document.routes.removeAll { $0.targetID == targetID }
        try await save(document, replacing: before)
        NotificationCenter.default.post(name: .jtsCompanionTargetRouteChanged, object: targetID)
    }

    private func read() async throws -> (String?, Document) {
        guard let text = try await persistence.load() else { return (nil, Document(version: 2, routes: [], owners: [])) }
        guard text.utf8.count <= 256 * 1024,
              let data = text.data(using: .utf8),
              var document = try? JSONDecoder().decode(Document.self, from: data),
              [1, 2].contains(document.version), document.routes.count <= 256,
              document.routes.allSatisfy(Self.valid),
              Set(document.routes.map(\.targetID)).count == document.routes.count else {
            throw CompanionTargetRouteError.invalid
        }
        if document.version == 1 {
            guard document.owners == nil else { throw CompanionTargetRouteError.invalid }
            document.owners = document.routes.map { Owner(targetID: $0.targetID, targetBinding: $0.targetBinding, deviceID: $0.deviceID) }
            document.version = 2
        }
        guard let owners = document.owners, owners.count <= 256,
              Set(owners.map(\.deviceID)).count == owners.count,
              Set(owners.map(\.targetID)).count == owners.count,
              owners.allSatisfy({ $0.targetID != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) &&
                  $0.deviceID != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) && Self.validBinding($0.targetBinding) }),
              document.routes.allSatisfy({ route in owners.contains(Owner(targetID: route.targetID,
                  targetBinding: route.targetBinding, deviceID: route.deviceID)) }) else { throw CompanionTargetRouteError.invalid }
        return (text, document)
    }

    private func save(_ document: Document, replacing previous: String?) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = String(decoding: try encoder.encode(document), as: UTF8.self)
        if let previous { try await persistence.replace(expected: previous, with: value) }
        else { try await persistence.create(value) }
    }

    private static func valid(_ value: CompanionTargetRouteBinding) -> Bool {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let grants = [value.grantID, value.fileGrantID, value.rdpGrantID, value.pairingID, value.desktopGrantID, value.pendingDesktopAuthorization?.grantID].compactMap { $0 }
        return value.targetID != zero && value.deviceID != zero && value.grantID != zero &&
            value.fileGrantID != zero && value.rdpGrantID != zero && value.pairingID != zero &&
            value.desktopGrantID != zero &&
            (value.pendingDesktopAuthorization.map({ $0.grantID != zero && $0.expiresAt > $0.issuedAt &&
                $0.expiresAt.timeIntervalSince($0.issuedAt) <= 366 * 86400 && value.pairingID != nil }) ?? true) &&
            ((value.desktopGrantID == nil && value.desktopGrantExpiresAt == nil) ||
             (value.desktopGrantID != nil && value.desktopGrantExpiresAt != nil && value.pairingID != nil)) &&
            Set(grants).count == grants.count &&
            validBinding(value.targetBinding)
    }

    private static func validBinding(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

extension Notification.Name {
    static let jtsCompanionTargetRouteChanged = Notification.Name("jts.companion.target-route-changed")
    static let jtsCompanionDeviceTrustChanged = Notification.Name("jts.companion.device-trust-changed")
}
#endif
