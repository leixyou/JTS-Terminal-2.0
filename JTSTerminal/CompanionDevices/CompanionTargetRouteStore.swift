#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices

nonisolated struct CompanionTargetRouteBinding: Codable, Equatable, Sendable {
    let targetID: UUID
    let targetBinding: String
    let deviceID: UUID
    let grantID: UUID
    var fileGrantID: UUID? = nil
    var rdpGrantID: UUID? = nil
    var pairingID: UUID? = nil
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
              fileGrantID: UUID? = nil, rdpGrantID: UUID? = nil, pairingID: UUID? = nil) async throws {
        guard !mutating else { throw CompanionTargetRouteError.busy }
        var route = CompanionTargetRouteBinding(targetID: targetID, targetBinding: targetBinding,
                                               deviceID: deviceID, grantID: grantID,
                                               fileGrantID: fileGrantID, rdpGrantID: rdpGrantID, pairingID: pairingID)
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
        let grants = [value.grantID, value.fileGrantID, value.rdpGrantID, value.pairingID].compactMap { $0 }
        return value.targetID != zero && value.deviceID != zero && value.grantID != zero &&
            value.fileGrantID != zero && value.rdpGrantID != zero && value.pairingID != zero &&
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
