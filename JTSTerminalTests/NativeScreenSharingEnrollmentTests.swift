#if ENABLE_RDP_2
import CryptoKit
import Foundation
import JTSCompanionClient
import JTSCompanionDevices
import JTSCompanionIPC
import JTSRelayEnrollment
import Testing
@testable import JTSTerminal

@MainActor
struct NativeScreenSharingEnrollmentTests {
    @Test func verifiedMacBindingStoresExactPinAndRdpGrantWithoutWindowsControlProbe() async throws {
        let fixture = try await NativeScreenSharingEnrollmentFixture()
        let pending = try await fixture.model.create(relayURL: fixture.origin, targetID: fixture.targetID,
                                                     targetBinding: fixture.targetBinding)
        #expect(pending.state == "pending")
        let complete = try await fixture.model.advance(id: pending.id, targetID: fixture.targetID,
                                                       targetBinding: fixture.targetBinding)
        #expect(complete.state == "complete")
        let deviceID = try #require(complete.deviceID)
        let saved = try #require(fixture.devices.snapshot?.devices.first { $0.id == deviceID })
        #expect(saved.peerSPKI == fixture.exchange.peerSPKI)
        #expect(saved.peerDeviceID == EnrollmentWire.hash(fixture.exchange.peerSPKI))
        let route = try #require(try await fixture.bindings.binding(targetID: fixture.targetID, targetBinding: fixture.targetBinding))
        let request = try EnrollmentRequest.decode(complete.attempt.request)
        #expect(route.rdpGrantID == UUID(uuidString: request.rdpGrantID))
        #expect(route.pairingID == UUID(uuidString: request.pairingID))
        #expect(route.effectiveDesktopRoute == .rdp)
        #expect(fixture.controlProbes.count == 0)
        #expect(fixture.devices.routes.values.allSatisfy { !$0.hasRoute && $0.connection == nil && $0.verifiedGrant == nil })
        #expect(complete.attempt.confirmation != nil)
        // Reopening resumes the same signed epoch, never generates another invitation.
        let recovered = try await fixture.model.create(relayURL: fixture.origin, targetID: fixture.targetID,
                                                       targetBinding: fixture.targetBinding)
        #expect(recovered.id == complete.id)
        #expect(recovered.attempt.confirmation == complete.attempt.confirmation)
        #expect(await fixture.exchange.creates == 1)
    }

    @Test func unsignedBoundReceiptCannotImportMacPinOrGrant() async throws {
        let fixture = try await NativeScreenSharingEnrollmentFixture()
        let pending = try await fixture.model.create(relayURL: fixture.origin, targetID: fixture.targetID,
                                                     targetBinding: fixture.targetBinding)
        await fixture.exchange.returnUnsignedBound()
        do {
            _ = try await fixture.model.advance(id: pending.id, targetID: fixture.targetID, targetBinding: fixture.targetBinding)
            Issue.record("Unsigned relay receipt became Mac authorization.")
        } catch { #expect(error as? EnrollmentError == .invalidResponse) }
        #expect(fixture.devices.snapshot?.devices.isEmpty == true)
        #expect(try await fixture.bindings.binding(targetID: fixture.targetID, targetBinding: fixture.targetBinding) == nil)
        #expect(fixture.model.records.first?.state == "pending")
    }

    @Test func changingTargetOrOwnerAuthorizationCannotCommitMacRoute() async throws {
        let fixture = try await NativeScreenSharingEnrollmentFixture()
        let pending = try await fixture.model.create(relayURL: fixture.origin, targetID: fixture.targetID,
                                                     targetBinding: fixture.targetBinding)
        do {
            _ = try await fixture.model.advance(id: pending.id, targetID: UUID(), targetBinding: fixture.targetBinding)
            Issue.record("Another profile borrowed the enrollment.")
        } catch { #expect(error as? EnrollmentError == .changed) }
        do {
            _ = try await fixture.model.advance(id: pending.id, targetID: fixture.targetID,
                targetBinding: fixture.targetBinding, authorize: { throw EnrollmentError.changed })
            Issue.record("Revoked owner approval committed a route.")
        } catch { #expect(error as? EnrollmentError == .changed) }
        #expect(fixture.devices.snapshot?.devices.isEmpty == true)
        #expect(fixture.devices.routes.isEmpty)
    }

    @Test func pendingRevocationCannotResumeOrRebindOldMacEpoch() async throws {
        let fixture = try await NativeScreenSharingEnrollmentFixture()
        let pending = try await fixture.model.create(relayURL: fixture.origin, targetID: fixture.targetID,
                                                     targetBinding: fixture.targetBinding)
        let complete = try await fixture.model.advance(id: pending.id, targetID: fixture.targetID,
                                                       targetBinding: fixture.targetBinding)
        let deviceID = try #require(complete.deviceID)
        let claim = try #require(complete.attempt.verifiedClaim)
        let bundle = try complete.attempt.bundle(for: claim)
        let signer = try await fixture.devices.enrollmentClient(relayOrigin: fixture.origin)
        let identity = try #require(fixture.devices.snapshot)
        let request = try await signer.prepareRevocation(bundle)
        try await fixture.revocations.save(CompanionRevocationRecord(request: request,
            controllerSPKI: identity.publicSPKI, peerSPKI: bundle.peerSPKI, deviceID: deviceID,
            targetID: fixture.targetID, targetBinding: fixture.targetBinding))
        try await fixture.bindings.remove(targetID: fixture.targetID)
        do {
            _ = try await fixture.model.advance(id: complete.id, targetID: fixture.targetID,
                                                targetBinding: fixture.targetBinding)
            Issue.record("A denied Mac epoch was restored after revocation.")
        } catch { #expect(error as? CompanionDeviceError == .deviceRevoked) }
        do {
            _ = try await fixture.model.create(relayURL: fixture.origin, targetID: fixture.targetID,
                                               targetBinding: fixture.targetBinding)
            Issue.record("A pending Mac revocation allowed another invitation.")
        } catch { #expect(error as? EnrollmentError == .remote("MAC_REVOCATION_PENDING")) }
        #expect(try await fixture.bindings.binding(targetID: fixture.targetID, targetBinding: fixture.targetBinding) == nil)
        #expect(await fixture.exchange.creates == 1)
        #expect(fixture.controlProbes.count == 0)
    }
}

@MainActor
private struct NativeScreenSharingEnrollmentFixture {
    let targetID = UUID()
    let targetBinding = String(repeating: "a", count: 64)
    let origin = "https://relay.example.test"
    let devices: CompanionDevicesModel
    let bindings: CompanionTargetRouteStore
    let exchange: NativeScreenSharingEnrollmentTestExchange
    let model: NativeScreenSharingEnrollmentModel
    let revocations: CompanionRevocationStore
    let controlProbes = NativeScreenSharingControlProbeCounter()

    init() async throws {
        let registry = CompanionDeviceRegistry(persistence: NativeScreenSharingMemoryPersistence())
        revocations = CompanionRevocationStore(persistence: NativeScreenSharingMemoryPersistence())
        let controlProbes = controlProbes
        devices = CompanionDevicesModel(registry: registry, revocations: revocations,
                                        makeConnection: { controlProbes.makeConnection() })
        _ = try await devices.mcpSnapshot(createIdentity: true)
        let signer = try await registry.enrollmentClient(relayOrigin: "https://relay.example.test")
        exchange = NativeScreenSharingEnrollmentTestExchange(signer: signer)
        bindings = CompanionTargetRouteStore(persistence: NativeScreenSharingMemoryPersistence())
        let exchange = exchange
        model = NativeScreenSharingEnrollmentModel(store: CompanionEnrollmentStore(persistence: NativeScreenSharingMemoryPersistence()),
                                                  devices: devices, bindings: bindings, makeClient: { _ in exchange })
    }
}

nonisolated private final class NativeScreenSharingControlProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func makeConnection() -> any CompanionDeviceConnection {
        lock.lock(); value += 1; lock.unlock()
        return NativeScreenSharingForbiddenControlConnection()
    }
}

private actor NativeScreenSharingForbiddenControlConnection: CompanionDeviceConnection {
    func open(_ configuration: CompanionIPCOpen) async throws -> CompanionIPCState { throw CompanionClientError.unavailable }
    func status(grantID: UUID) async throws -> CompanionControlStatus { throw CompanionClientError.unavailable }
    func submit(_ request: CompanionIPCSubmit) async throws -> CompanionJobReceipt { throw CompanionClientError.unavailable }
    func job(grantID: UUID, jobID: UUID) async throws -> CompanionJobReceipt { throw CompanionClientError.unavailable }
    func cancel(grantID: UUID, jobID: UUID) async throws -> CompanionJobReceipt { throw CompanionClientError.unavailable }
    func output(_ request: CompanionIPCOutput) async throws -> CompanionJobOutput { throw CompanionClientError.unavailable }
    func invalidate() async {}
}

private actor NativeScreenSharingMemoryPersistence: CompanionDevicePersistence {
    private var value: String?
    func load() async throws -> String? { value }
    func create(_ value: String) async throws {
        guard self.value == nil else { throw CompanionDevicePersistenceError.alreadyExists }
        self.value = value
    }
    func replace(expected: String, with value: String) async throws {
        guard self.value == expected else { throw CompanionDevicePersistenceError.conflict }
        self.value = value
    }
}

private actor NativeScreenSharingEnrollmentTestExchange: NativeScreenSharingEnrollmentExchange {
    private let signer: EnrollmentClient
    private let peer = P256.Signing.PrivateKey()
    nonisolated let peerSPKI: Data
    private var claims: [String: EnrollmentClaim] = [:]
    private var unsignedBound = false
    private(set) var creates = 0

    init(signer: EnrollmentClient) {
        self.signer = signer
        peerSPKI = peer.publicKey.derRepresentation
    }
    func returnUnsignedBound() { unsignedBound = true }
    func create(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt {
        creates += 1
        return try receipt(attempt, state: "pending")
    }
    func status(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt {
        try receipt(attempt, state: unsignedBound || attempt.confirmation != nil ? "bound" : "claimed")
    }
    func prepareConfirmation(_ attempt: EnrollmentAttempt, now: Date) async throws -> EnrollmentConfirmation {
        try await signer.prepareConfirmation(attempt, now: now)
    }
    func confirm(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt { try receipt(attempt, state: "bound") }
    func cancel(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt { try receipt(attempt, state: "cancelled") }

    private func receipt(_ attempt: EnrollmentAttempt, state: String) throws -> EnrollmentReceipt {
        let request = try EnrollmentRequest.decode(attempt.request)
        var object: [String: Any] = ["invitationId": attempt.id, "controllerDeviceId": request.controllerDeviceID,
            "state": state, "expiresAtUnixSeconds": attempt.expiresAtUnixSeconds, "offerBase64": attempt.offer.base64EncodedString()]
        if ["claimed", "bound"].contains(state) {
            let claim = try claim(attempt, request: request)
            object["claim"] = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(claim))
            if !unsignedBound, let confirmation = attempt.confirmation {
                object["confirmation"] = try JSONSerialization.jsonObject(with: EnrollmentWire.encode(confirmation))
            }
        }
        return try JSONDecoder().decode(EnrollmentReceipt.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func claim(_ attempt: EnrollmentAttempt, request: EnrollmentRequest) throws -> EnrollmentClaim {
        if let cached = claims[attempt.id] { return cached }
        let code = try EnrollmentCode(attempt.code)
        let bundle: [String: Any] = ["version": 1, "name": "Mac mini fixture", "relayURL": code.relayOrigin,
            "peerSPKIBase64": peerSPKI.base64EncodedString(), "peerDeviceID": EnrollmentWire.hash(peerSPKI),
            "pairingID": request.pairingID, "grantID": request.grantID, "fileGrantID": request.fileGrantID, "rdpGrantID": request.rdpGrantID]
        let wrapped: [String: Any] = ["version": 1, "invitationId": attempt.id, "relayOrigin": code.relayOrigin,
            "requestSha256": EnrollmentWire.hash(attempt.request),
            "enrollmentBase64": try JSONSerialization.data(withJSONObject: bundle).base64EncodedString()]
        let response = try code.sealResponse(JSONSerialization.data(withJSONObject: wrapped), offer: attempt.offer)
        let transcript = EnrollmentClaim.transcript(invitationId: attempt.id, controllerDeviceId: request.controllerDeviceID,
                                                    offer: attempt.offer, response: response, spki: peerSPKI)
        let object: [String: Any] = ["peerSPKIBase64": peerSPKI.base64EncodedString(), "responseBase64": response.base64EncodedString(),
            "signatureBase64": try peer.signature(for: transcript).rawRepresentation.base64EncodedString(), "claimHash": EnrollmentWire.hash(transcript)]
        let claim = try JSONDecoder().decode(EnrollmentClaim.self, from: JSONSerialization.data(withJSONObject: object))
        claims[attempt.id] = claim
        return claim
    }
}
#endif
