#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices
import Testing
@testable import JTSTerminal

@Suite struct CompanionTargetRouteTests {
    @Test func bindingSurvivesReloadButCannotFollowAChangedProfile() async throws {
        let persistence = RouteTestPersistence()
        let first = CompanionTargetRouteStore(persistence: persistence)
        let target = UUID(), device = UUID(), control = UUID(), file = UUID(), rdp = UUID()
        let endpoint = String(repeating: "a", count: 64)
        try await first.bind(targetID: target, targetBinding: endpoint, deviceID: device,
                             grantID: control, fileGrantID: file, rdpGrantID: rdp)
        let reopened = CompanionTargetRouteStore(persistence: persistence)
        let route = try #require(await reopened.binding(targetID: target, targetBinding: endpoint))
        #expect(route.deviceID == device && route.grantID == control)
        #expect(route.fileGrantID == file && route.rdpGrantID == rdp)
        await #expect(throws: CompanionTargetRouteError.self) {
            try await reopened.binding(targetID: target, targetBinding: String(repeating: "b", count: 64))
        }
        try await reopened.remove(targetID: target)
        #expect(try await first.binding(targetID: target, targetBinding: endpoint) == nil)
    }

    @Test func corruptOrUnavailableStateNeverTurnsIntoAnUnboundDirectRoute() async throws {
        let persistence = RouteTestPersistence()
        await persistence.set("{bad-json}")
        let routes = CompanionTargetRouteStore(persistence: persistence)
        await #expect(throws: CompanionTargetRouteError.self) {
            try await routes.binding(targetID: UUID(), targetBinding: String(repeating: "a", count: 64))
        }
        await persistence.setUnavailable()
        await #expect(throws: CompanionDevicePersistenceError.self) {
            try await routes.binding(targetID: UUID(), targetBinding: String(repeating: "a", count: 64))
        }
    }

    @Test func failedPersistenceDoesNotPublishANewRoute() async throws {
        let persistence = RouteTestPersistence()
        let routes = CompanionTargetRouteStore(persistence: persistence)
        let target = UUID(), binding = String(repeating: "a", count: 64), device = UUID()
        try await routes.bind(targetID: target, targetBinding: binding, deviceID: device, grantID: UUID())
        await persistence.rejectReplacements()
        await #expect(throws: CompanionDevicePersistenceError.self) {
            try await routes.bind(targetID: target, targetBinding: binding, deviceID: UUID(), grantID: UUID())
        }
        #expect(try await routes.binding(targetID: target, targetBinding: binding)?.deviceID == device)
    }
}

private actor RouteTestPersistence: CompanionDevicePersistence {
    private var value: String?
    private var unavailable = false
    private var reject = false
    func set(_ value: String) { self.value = value }
    func setUnavailable() { unavailable = true }
    func rejectReplacements() { reject = true }
    func load() throws -> String? {
        if unavailable { throw CompanionDevicePersistenceError.unavailable }
        return value
    }
    func create(_ value: String) throws {
        guard self.value == nil else { throw CompanionDevicePersistenceError.alreadyExists }
        self.value = value
    }
    func replace(expected: String, with value: String) throws {
        guard !reject, self.value == expected else { throw CompanionDevicePersistenceError.conflict }
        self.value = value
    }
}
#endif
