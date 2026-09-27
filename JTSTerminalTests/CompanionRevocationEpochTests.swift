#if ENABLE_RDP_2
import CryptoKit
import Foundation
import Testing
import JTSCompanionDevices
import JTSRelayEnrollment
@testable import JTSTerminal

@Suite struct CompanionRevocationEpochTests {
    @Test func activeRouteWinsOverNewBoundInvitationBeforeItsControlProbe() async throws {
        let fixture = try await fixture()
        let current = try await record(device: fixture.device, route: fixture.route, state: "complete")
        let nextRoute = route(deviceID: fixture.device.id, targetID: fixture.route.targetID)
        let next = try await record(device: fixture.device, route: nextRoute, state: "bound")
        #expect(next.deviceID == current.deviceID)
        #expect(next.attempt.confirmation != nil)
        #expect(nextRoute.grantID != fixture.route.grantID)

        let selected = try CompanionRevocationEpoch.resolve(device: fixture.device, route: fixture.route,
            records: [current, next])

        #expect(selected.record?.id == current.id)
        #expect(selected.record?.id != next.id)
        expectEpoch(selected.bundle, matches: fixture.route)
    }

    @Test func completeLegacyImportResolvesWithoutAnInvitationRecord() async throws {
        let fixture = try await fixture()
        let selected = try CompanionRevocationEpoch.resolve(device: fixture.device, route: fixture.route, records: [])
        #expect(selected.record == nil)
        #expect(selected.bundle.peerDeviceID == fixture.device.peerDeviceID)
        #expect(selected.bundle.peerSPKI == fixture.device.peerSPKI)
        #expect(selected.bundle.relayURL == fixture.device.relayURL)
        #expect(selected.bundle.allowWindows10TLS12 == fixture.device.allowWindows10TLS12)
        expectEpoch(selected.bundle, matches: fixture.route)
    }

    @Test func legacyImportWithoutPairingIDCannotInventARevocationEpoch() async throws {
        let fixture = try await fixture()
        var incomplete = fixture.route
        incomplete.pairingID = nil
        #expect(throws: EnrollmentError.remote("VERIFIED_PAIRING_EPOCH_REQUIRED")) {
            try CompanionRevocationEpoch.resolve(device: fixture.device, route: incomplete, records: [])
        }
    }

    @Test func newInvitationCannotReplaceCompleteLegacyRoute() async throws {
        let fixture = try await fixture()
        let next = try await record(device: fixture.device,
            route: route(deviceID: fixture.device.id, targetID: fixture.route.targetID), state: "bound")
        let selected = try CompanionRevocationEpoch.resolve(device: fixture.device, route: fixture.route, records: [next])
        #expect(selected.record == nil)
        expectEpoch(selected.bundle, matches: fixture.route)
    }

    private func expectEpoch(_ bundle: EnrollmentBundle, matches route: CompanionTargetRouteBinding) {
        #expect(bundle.pairingID == route.pairingID?.uuidString.lowercased())
        #expect(bundle.grantID == route.grantID.uuidString.lowercased())
        #expect(bundle.fileGrantID == route.fileGrantID?.uuidString.lowercased())
        #expect(bundle.rdpGrantID == route.rdpGrantID?.uuidString.lowercased())
    }

    private func route(deviceID: UUID, targetID: UUID = UUID()) -> CompanionTargetRouteBinding {
        CompanionTargetRouteBinding(targetID: targetID, targetBinding: String(repeating: "a", count: 64),
            deviceID: deviceID, grantID: UUID(), fileGrantID: UUID(), rdpGrantID: UUID(), pairingID: UUID())
    }

    private func fixture() async throws -> (device: CompanionSavedDevice, route: CompanionTargetRouteBinding) {
        let registry = CompanionDeviceRegistry(persistence: EpochTestPersistence())
        _ = try await registry.initialize()
        let spki = try key(2).publicKey.derRepresentation
        let device = try await registry.addDevice(name: "Fixture Windows", relayURL: "https://relay.example.test:9443",
            peerSPKI: spki, allowWindows10TLS12: true, verifiedPeerDeviceID: EnrollmentWire.hash(spki))
        return (device, route(deviceID: device.id))
    }

    private func record(device: CompanionSavedDevice, route: CompanionTargetRouteBinding,
                        state: String) async throws -> CompanionEnrollmentRecord {
        // Public test scalars 1 and 2; each epoch uses a real encrypted response and signed claim/confirmation.
        let controller = try key(1), peer = try key(2)
        let now = Date(timeIntervalSince1970: 1_790_467_500)
        let initial = try EnrollmentRequest(controllerSPKI: controller.publicKey.derRepresentation,
            allowWindows10TLS12: true, now: now)
        var requestObject = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(initial)) as! [String: Any]
        requestObject["pairingID"] = route.pairingID!.uuidString.lowercased()
        requestObject["grantID"] = route.grantID.uuidString.lowercased()
        requestObject["fileGrantID"] = route.fileGrantID!.uuidString.lowercased()
        requestObject["rdpGrantID"] = route.rdpGrantID!.uuidString.lowercased()
        let request = try EnrollmentRequest.decode(JSONSerialization.data(withJSONObject: requestObject))
        var attempt = try EnrollmentAttempt(relayOrigin: device.relayURL, request: request)
        let bundle: [String: Any] = ["version": 1, "name": device.name, "relayURL": device.relayURL,
            "peerSPKIBase64": device.peerSPKI.base64EncodedString(), "peerDeviceID": device.peerDeviceID,
            "pairingID": request.pairingID, "grantID": request.grantID, "fileGrantID": request.fileGrantID,
            "rdpGrantID": request.rdpGrantID, "allowWindows10TLS12": true,
            "installationState": "installedAwaitingRelayAdmission"]
        let responseObject: [String: Any] = ["version": 1, "invitationId": attempt.id, "relayOrigin": device.relayURL,
            "requestSha256": EnrollmentWire.hash(attempt.request),
            "enrollmentBase64": try JSONSerialization.data(withJSONObject: bundle).base64EncodedString()]
        let response = try EnrollmentCode(attempt.code).sealResponse(
            JSONSerialization.data(withJSONObject: responseObject), offer: attempt.offer)
        let transcript = EnrollmentClaim.transcript(invitationId: attempt.id, controllerDeviceId: request.controllerDeviceID,
            offer: attempt.offer, response: response, spki: device.peerSPKI)
        let claimObject: [String: Any] = ["peerSPKIBase64": device.peerSPKI.base64EncodedString(),
            "responseBase64": response.base64EncodedString(), "claimHash": EnrollmentWire.hash(transcript),
            "signatureBase64": try peer.signature(for: transcript).rawRepresentation.base64EncodedString()]
        attempt.verifiedClaim = try JSONDecoder().decode(EnrollmentClaim.self,
            from: JSONSerialization.data(withJSONObject: claimObject))
        let client = try EnrollmentClient(privateKey: controller.rawRepresentation, relayOrigin: device.relayURL)
        attempt.confirmation = try await client.prepareConfirmation(attempt, now: now)
        try attempt.validate(controllerDeviceId: request.controllerDeviceID)
        var record = CompanionEnrollmentRecord(attempt: attempt, targetID: route.targetID, targetBinding: route.targetBinding)
        record.deviceID = device.id
        record.state = state
        return record
    }

    private func key(_ scalar: UInt8) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([scalar]))
    }
}

private actor EpochTestPersistence: CompanionDevicePersistence {
    private var value: String?
    func load() async throws -> String? { value }
    func create(_ value: String) async throws {
        guard self.value == nil else { throw CompanionDevicePersistenceError.conflict }
        self.value = value
    }
    func replace(expected: String, with value: String) async throws {
        guard self.value == expected else { throw CompanionDevicePersistenceError.conflict }
        self.value = value
    }
}
#endif
