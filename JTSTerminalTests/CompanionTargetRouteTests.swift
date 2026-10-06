#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices
import Testing
@testable import JTSTerminal

@Suite struct CompanionTargetRouteTests {
    @Test func pendingDesktopProofSurvivesRestartAndOnlyExplicitRejectionDiscardsIt() async throws {
        let persistence = RouteTestPersistence(), routes = CompanionTargetRouteStore(persistence: persistence)
        let target = UUID(), fingerprint = String(repeating: "f", count: 64)
        try await routes.bind(targetID: target, targetBinding: fingerprint, deviceID: UUID(),
            grantID: UUID(), pairingID: UUID(), desktopRoute: .companion)
        let initial = try #require(await routes.binding(targetID: target, targetBinding: fingerprint))
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 300)
        let prepared = try await routes.prepareDesktopAuthorization(expected: initial, now: now)
        let reopened = CompanionTargetRouteStore(persistence: persistence)
        let restored = try #require(await reopened.binding(targetID: target, targetBinding: fingerprint))
        #expect(restored == prepared)
        #expect(try await reopened.prepareDesktopAuthorization(expected: restored) == prepared)
        let rejected = try await reopened.discardRejectedDesktopAuthorization(expected: restored)
        #expect(rejected.pendingDesktopAuthorization == nil)
        let replacement = try await reopened.prepareDesktopAuthorization(expected: rejected)
        #expect(replacement.pendingDesktopAuthorization?.grantID != prepared.pendingDesktopAuthorization?.grantID)
        await #expect(throws: CompanionTargetRouteError.changed) {
            try await reopened.saveDesktopAuthorization(expected: prepared,
                grantID: try #require(prepared.pendingDesktopAuthorization).grantID,
                expiresAt: try #require(prepared.pendingDesktopAuthorization).expiresAt)
        }
    }
    @Test func nativeDesktopChoiceAndGrantAreIndependentOfLegacyRDP() async throws {
        let persistence = RouteTestPersistence(), routes = CompanionTargetRouteStore(persistence: persistence)
        let target = UUID(), device = UUID(), control = UUID(), pairing = UUID(), rdp = UUID()
        let fingerprint = String(repeating: "e", count: 64)
        try await routes.bind(targetID: target, targetBinding: fingerprint, deviceID: device,
            grantID: control, rdpGrantID: rdp, pairingID: pairing)
        let old = try #require(await routes.binding(targetID: target, targetBinding: fingerprint))
        #expect(old.effectiveDesktopRoute == .rdp && old.desktopGrantID == nil)
        await #expect(throws: CompanionTargetRouteError.changed) {
            try await routes.saveDesktopAuthorization(expected: old, grantID: UUID(), expiresAt: Date().addingTimeInterval(60))
        }
        try await routes.chooseDesktopRoute(expected: old, preference: .companion)
        let selected = try #require(await routes.binding(targetID: target, targetBinding: fingerprint))
        await #expect(throws: CompanionTargetRouteError.invalid) {
            try await routes.saveDesktopAuthorization(expected: selected, grantID: rdp, expiresAt: Date().addingTimeInterval(60))
        }
        let desktop = UUID()
        try await routes.saveDesktopAuthorization(expected: selected, grantID: desktop, expiresAt: Date().addingTimeInterval(60))
        let reopened = CompanionTargetRouteStore(persistence: persistence)
        let native = try #require(await reopened.binding(targetID: target, targetBinding: fingerprint))
        #expect(native.desktopGrantID == desktop && native.rdpGrantID == rdp)
        #expect(native.effectiveDesktopRoute == .companion)
        try await reopened.bind(targetID: target, targetBinding: fingerprint, deviceID: device, grantID: control)
        #expect(try await reopened.binding(targetID: target, targetBinding: fingerprint) == native)
        await #expect(throws: CompanionTargetRouteError.changed) {
            try await reopened.saveDesktopAuthorization(expected: selected, grantID: UUID(), expiresAt: Date().addingTimeInterval(60))
        }
    }
    @Test func bindingSurvivesReloadButCannotFollowAChangedProfile() async throws {
        let persistence = RouteTestPersistence()
        let first = CompanionTargetRouteStore(persistence: persistence)
        let target = UUID(), device = UUID(), control = UUID(), file = UUID(), rdp = UUID(), pairing = UUID()
        let endpoint = String(repeating: "a", count: 64)
        try await first.bind(targetID: target, targetBinding: endpoint, deviceID: device,
                             grantID: control, fileGrantID: file, rdpGrantID: rdp, pairingID: pairing)
        let reopened = CompanionTargetRouteStore(persistence: persistence)
        let route = try #require(await reopened.binding(targetID: target, targetBinding: endpoint))
        #expect(route.deviceID == device && route.grantID == control)
        #expect(route.fileGrantID == file && route.rdpGrantID == rdp)
        #expect(route.pairingID == pairing)
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

    @Test func ordinaryRebindPreservesEpochButANewGrantCannotInheritIt() async throws {
        let persistence = RouteTestPersistence(), target = UUID(), device = UUID(), grant = UUID()
        let pairing = UUID(), file = UUID(), rdp = UUID(), fingerprint = String(repeating: "c", count: 64)
        let routes = CompanionTargetRouteStore(persistence: persistence)
        try await routes.bind(targetID: target, targetBinding: fingerprint, deviceID: device,
            grantID: grant, fileGrantID: file, rdpGrantID: rdp, pairingID: pairing)
        let original = try #require(await routes.binding(targetID: target, targetBinding: fingerprint))
        try await routes.bind(targetID: target, targetBinding: fingerprint, deviceID: device, grantID: grant)
        #expect(try await routes.binding(targetID: target, targetBinding: fingerprint) == original)
        await #expect(throws: CompanionTargetRouteError.changed) {
            try await routes.bind(targetID: target, targetBinding: fingerprint, deviceID: device, grantID: grant, pairingID: UUID())
        }
        await #expect(throws: CompanionTargetRouteError.changed) {
            try await routes.bind(targetID: target, targetBinding: fingerprint, deviceID: device, grantID: grant, fileGrantID: UUID())
        }
        try await routes.bind(targetID: target, targetBinding: fingerprint, deviceID: device, grantID: UUID())
        let replacement = try #require(await routes.binding(targetID: target, targetBinding: fingerprint))
        #expect(replacement.pairingID == nil && replacement.fileGrantID == nil && replacement.rdpGrantID == nil)
    }

    @Test func legacyMissingEpochStaysMissingUntilVerifiedImportAndAllIdentifiersAreDistinct() async throws {
        let persistence = RouteTestPersistence(), target = UUID(), device = UUID(), grant = UUID()
        let fingerprint = String(repeating: "d", count: 64)
        let routes = CompanionTargetRouteStore(persistence: persistence)
        try await routes.bind(targetID: target, targetBinding: fingerprint, deviceID: device, grantID: grant)
        let reopened = CompanionTargetRouteStore(persistence: persistence)
        #expect(try await reopened.binding(targetID: target, targetBinding: fingerprint)?.pairingID == nil)
        await #expect(throws: CompanionTargetRouteError.invalid) {
            try await reopened.bind(targetID: target, targetBinding: fingerprint, deviceID: device, grantID: grant, pairingID: grant)
        }
        let pairing = UUID()
        try await reopened.bind(targetID: target, targetBinding: fingerprint, deviceID: device, grantID: grant, pairingID: pairing)
        #expect(try await reopened.binding(targetID: target, targetBinding: fingerprint)?.pairingID == pairing)
    }

    @Test func failedPersistenceDoesNotPublishANewRoute() async throws {
        let persistence = RouteTestPersistence()
        let routes = CompanionTargetRouteStore(persistence: persistence)
        let target = UUID(), binding = String(repeating: "a", count: 64), device = UUID()
        try await routes.bind(targetID: target, targetBinding: binding, deviceID: device, grantID: UUID())
        await persistence.rejectReplacements()
        await #expect(throws: CompanionDevicePersistenceError.self) {
            try await routes.bind(targetID: target, targetBinding: binding, deviceID: device, grantID: UUID())
        }
        #expect(try await routes.binding(targetID: target, targetBinding: binding)?.deviceID == device)
    }

    @Test func deviceOwnershipSurvivesUnbindAndReload() async throws {
        let persistence = RouteTestPersistence(), target = UUID(), other = UUID(), device = UUID()
        let binding = String(repeating: "a", count: 64)
        let routes = CompanionTargetRouteStore(persistence: persistence)
        try await routes.bind(targetID: target, targetBinding: binding, deviceID: device, grantID: UUID())
        try await routes.remove(targetID: target)
        let reopened = CompanionTargetRouteStore(persistence: persistence)
        await #expect(throws: CompanionTargetRouteError.deviceAssigned) {
            try await reopened.bind(targetID: other, targetBinding: binding, deviceID: device, grantID: UUID())
        }
        await #expect(throws: CompanionTargetRouteError.targetAssigned) {
            try await reopened.bind(targetID: target, targetBinding: binding, deviceID: UUID(), grantID: UUID())
        }
        try await reopened.bind(targetID: target, targetBinding: binding, deviceID: device, grantID: UUID())
        #expect(try await reopened.binding(targetID: target, targetBinding: binding)?.deviceID == device)
    }

    @Test func legacyOwnershipIsPreservedAndAmbiguousAliasesFailClosed() async throws {
        let persistence = RouteTestPersistence(), target = UUID(), device = UUID(), grant = UUID()
        let binding = String(repeating: "b", count: 64)
        let route: [String: Any] = ["targetID": target.uuidString, "deviceID": device.uuidString,
            "grantID": grant.uuidString, "targetBinding": binding]
        func legacy(_ records: [[String: Any]]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["version": 1, "routes": records]), as: UTF8.self)
        }
        await persistence.set(try legacy([route]))
        let routes = CompanionTargetRouteStore(persistence: persistence)
        try await routes.remove(targetID: target)
        await #expect(throws: CompanionTargetRouteError.deviceAssigned) {
            try await routes.requireAssignment(targetID: UUID(), targetBinding: binding, deviceID: device)
        }
        var alias = route; alias["targetID"] = UUID().uuidString
        await persistence.set(try legacy([route, alias]))
        await #expect(throws: CompanionTargetRouteError.invalid) {
            try await routes.binding(targetID: target, targetBinding: binding)
        }
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
