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
}

nonisolated enum CompanionTargetRouteError: Error { case invalid, changed, busy }

/// The route is bound to the existing profile identity as well as its UUID.
/// Changing a saved endpoint cannot silently inherit another machine's route.
actor CompanionTargetRouteStore {
    static let shared = CompanionTargetRouteStore(persistence: CompanionVaultPersistence(
        account: "jts.companion.target-routes.v1"))
    private let persistence: any CompanionDevicePersistence
    private var mutating = false
    private struct Document: Codable { let version: Int; var routes: [CompanionTargetRouteBinding] }

    init(persistence: any CompanionDevicePersistence) { self.persistence = persistence }

    func binding(targetID: UUID, targetBinding: String) async throws -> CompanionTargetRouteBinding? {
        let (_, document) = try await read()
        guard let route = document.routes.first(where: { $0.targetID == targetID }) else { return nil }
        guard route.targetBinding == targetBinding else { throw CompanionTargetRouteError.changed }
        return route
    }

    func bind(targetID: UUID, targetBinding: String, deviceID: UUID, grantID: UUID,
              fileGrantID: UUID? = nil, rdpGrantID: UUID? = nil) async throws {
        guard !mutating else { throw CompanionTargetRouteError.busy }
        let route = CompanionTargetRouteBinding(targetID: targetID, targetBinding: targetBinding,
                                               deviceID: deviceID, grantID: grantID,
                                               fileGrantID: fileGrantID, rdpGrantID: rdpGrantID)
        guard Self.valid(route) else { throw CompanionTargetRouteError.invalid }
        mutating = true; defer { mutating = false }
        let (before, original) = try await read()
        var document = original
        document.routes.removeAll { $0.targetID == targetID }
        document.routes.append(route)
        guard document.routes.count <= 256 else { throw CompanionTargetRouteError.invalid }
        try await save(document, replacing: before)
        NotificationCenter.default.post(name: .jtsCompanionTargetRouteChanged, object: targetID)
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
        guard let text = try await persistence.load() else { return (nil, Document(version: 1, routes: [])) }
        guard text.utf8.count <= 256 * 1024,
              let data = text.data(using: .utf8),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1, document.routes.count <= 256,
              document.routes.allSatisfy(Self.valid),
              Set(document.routes.map(\.targetID)).count == document.routes.count else {
            throw CompanionTargetRouteError.invalid
        }
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
        let grants = [value.grantID, value.fileGrantID, value.rdpGrantID].compactMap { $0 }
        return value.targetID != zero && value.deviceID != zero && value.grantID != zero &&
            value.fileGrantID != zero && value.rdpGrantID != zero &&
            Set(grants).count == grants.count &&
            value.targetBinding.utf8.count == 64 && value.targetBinding.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

extension Notification.Name {
    static let jtsCompanionTargetRouteChanged = Notification.Name("jts.companion.target-route-changed")
    static let jtsCompanionDeviceTrustChanged = Notification.Name("jts.companion.device-trust-changed")
}
#endif
