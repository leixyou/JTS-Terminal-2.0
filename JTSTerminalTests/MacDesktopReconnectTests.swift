#if ENABLE_RDP_2
import Foundation
import Network
import RemoteDesktopCore
import SwiftData
import Testing
@testable import JTSTerminal

@MainActor
struct MacDesktopReconnectTests {
    @Test func legacyPairingDecodesWithAutomaticReconnectAndPreferenceRoundTrips() throws {
        let pairing = MacDesktopReconnectFixture.pairing()
        let data = try JSONEncoder().encode(pairing)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "autoReconnect")
        let legacy = try JSONDecoder().decode(MacDesktopStoredPairing.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.autoReconnect)
        var disabled = legacy
        disabled.autoReconnect = false
        #expect(try JSONDecoder().decode(MacDesktopStoredPairing.self, from: JSONEncoder().encode(disabled)) == disabled)
    }

    @Test func backoffCapsAndBusyFailuresExpireUntilSuccessfulConnectionResetsPolicy() {
        var policy = MacDesktopReconnectPolicy()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect((0..<8).map { _ in policy.nextDelay(cause: .network, now: start) } == [1, 2, 4, 8, 15, 30, 30, 30])
        policy.reset()
        #expect(policy.nextDelay(cause: .temporarilyUnavailable, now: start) == 1)
        #expect(policy.nextDelay(cause: .temporarilyUnavailable, now: start.addingTimeInterval(119)) == nil)
        #expect(policy.nextDelay(cause: .network, now: start.addingTimeInterval(200)) == 2)
        policy.reset()
        #expect(policy.nextDelay(cause: .network, now: start.addingTimeInterval(200)) == 1)
    }

    @Test func openingPairedProfileConnectsOnceAndManualDisconnectStaysDisconnected() async throws {
        let fixture = MacDesktopReconnectFixture()
        let workspace = fixture.workspace()
        workspace.prepare(for: fixture.session)
        #expect(workspace.status == .connecting)
        let transport = try #require(fixture.transports.first)
        fixture.establish(transport)
        #expect(workspace.isConnected)
        workspace.disconnect()
        workspace.prepare(for: fixture.session)
        transport.onStateChange?(.cancelled) // Stale callbacks cannot schedule a retry.
        transport.onError?(NWError.posix(.ECONNRESET))
        await fixture.settle()
        #expect(workspace.status == .disconnected)
        #expect(fixture.transports.count == 1)
        #expect(transport.cancelled)
        #expect(fixture.clock.waits.isEmpty)
    }

    @Test func removedWorkspaceCannotRestartAfterOriginalEndpointAndAutomaticReconnectAreRestored() async throws {
        let fixture = MacDesktopReconnectFixture()
        let store = MacDesktopWorkspaceStore(makeWorkspace: fixture.workspace)
        let key = fixture.session.persistentModelID
        let old = store.workspace(for: key)
        old.prepare(for: fixture.session)
        let first = try #require(fixture.transports.first)
        fixture.establish(first)
        first.onError?(NWError.posix(.ECONNRESET))
        await fixture.settle()
        #expect(old.status == .reconnecting)
        #expect(fixture.storedPairing?.autoReconnect == true)
        // Resume the retry before removal, leaving its continuation already queued on MainActor.
        try fixture.clock.complete(seconds: 1)
        store.remove(for: key)
        #expect(first.cancelled)
        #expect(old.status == .disconnected)
        fixture.session.host = "edited-host.local"
        old.prepare(for: fixture.session)
        old.connect(session: fixture.session)
        fixture.session.host = "mac-mini.local"
        old.prepare(for: fixture.session)
        old.connect(session: fixture.session)
        // Stale transport callbacks, queued actions and the resumed retry cannot revive it.
        first.onStateChange?(.cancelled)
        first.onError?(NWError.posix(.ECONNRESET))
        await fixture.settle()
        #expect(fixture.transports.count == 1)
        #expect(fixture.clock.waits.isEmpty)
        #expect(old.status == .disconnected)
        #expect(fixture.storedPairing?.autoReconnect == true)

        let replacement = store.workspace(for: key)
        #expect(replacement !== old)
        replacement.prepare(for: fixture.session)
        #expect(replacement.status == .connecting)
        #expect(fixture.transports.count == 2)
        replacement.disconnect()
        await fixture.settle()
    }

    @Test func networkFailureReconnectsWithGrantedKeyAtFrozenEndpointAndSingleRetryTask() async throws {
        let fixture = MacDesktopReconnectFixture()
        let workspace = fixture.workspace()
        workspace.prepare(for: fixture.session)
        let first = try #require(fixture.transports.first)
        fixture.establish(first)
        fixture.session.host = "different-host.local"
        first.onError?(NWError.posix(.ECONNRESET))
        first.onStateChange?(.cancelled)
        await fixture.settle()
        #expect(workspace.status == .reconnecting)
        #expect(fixture.clock.waits.filter { $0.seconds == 1 }.count == 1)
        try fixture.clock.complete(seconds: 1)
        await fixture.settle()
        #expect(fixture.transports.count == 2)
        let second = try #require(fixture.transports.last)
        #expect(second.endpoint.host == "mac-mini.local")
        #expect(second.endpoint.port == 49871)
        #expect(second.endpoint.psk == fixture.storedPairing?.psk)
        #expect(second.endpoint.identity == fixture.storedPairing?.clientID.uuidString)
        fixture.establish(second)
        let authentication = try #require(second.messages.compactMap { message -> DesktopAuthentication? in
            if case .authenticate(let value) = message { return value }
            return nil
        }.first)
        #expect(authentication.invitationToken == nil)
        #expect(authentication.token == fixture.storedPairing?.token)
        #expect(workspace.isConnected)
        second.onStateChange?(.cancelled) // Clean EOF also retries.
        await fixture.settle()
        #expect(fixture.clock.waits.contains { $0.seconds == 1 }) // Successful session resets backoff.
        workspace.disconnect()
        await fixture.settle()
    }

    @Test func cancelOrForgetWhileWaitingNeverReconnects() async throws {
        for forget in [false, true] {
            let fixture = MacDesktopReconnectFixture()
            let workspace = fixture.workspace()
            workspace.prepare(for: fixture.session)
            let transport = try #require(fixture.transports.first)
            fixture.establish(transport)
            transport.onError?(NWError.posix(.ENETDOWN))
            await fixture.settle()
            #expect(workspace.status == .reconnecting)
            if forget { workspace.forgetPairing(session: fixture.session) }
            else { workspace.disconnect() }
            await fixture.settle()
            #expect(workspace.status == .disconnected)
            #expect(fixture.clock.waits.isEmpty)
            #expect(fixture.transports.count == 1)
            if forget { #expect(fixture.storedPairing == nil); #expect(!workspace.hasSavedPairing) }
        }
    }

    @Test func rejectedRevokedStoppedAndInvalidProtocolNeverRetry() async throws {
        for code in [DesktopSessionEndCode.hostStopped, .revoked, .rejected, .invalidCredentials, .protocolViolation] {
            let fixture = MacDesktopReconnectFixture()
            let workspace = fixture.workspace()
            workspace.prepare(for: fixture.session)
            let transport = try #require(fixture.transports.first)
            fixture.establish(transport)
            transport.onMessage?(.sessionEnded(.init(code: code, message: "停止连接")))
            transport.onStateChange?(.cancelled)
            await fixture.settle()
            #expect(workspace.status == .failed)
            #expect(workspace.errorMessage == "停止连接")
            #expect(fixture.clock.waits.isEmpty)
            #expect(fixture.transports.count == 1)
        }
    }

    @Test func busyAndCaptureErrorsRetryWithinGracePeriod() async throws {
        for code in [DesktopSessionEndCode.busy, .captureFailed] {
            let fixture = MacDesktopReconnectFixture()
            let workspace = fixture.workspace()
            workspace.prepare(for: fixture.session)
            let first = try #require(fixture.transports.first)
            fixture.establish(first)
            first.onMessage?(.sessionEnded(.init(code: code, message: "稍后重试")))
            await fixture.settle()
            #expect(workspace.status == .reconnecting)
            try fixture.clock.complete(seconds: 1)
            await fixture.settle()
            let second = try #require(fixture.transports.last)
            fixture.clock.now = fixture.clock.now.addingTimeInterval(119)
            second.onMessage?(.sessionEnded(.init(code: code, message: "稍后重试")))
            await fixture.settle()
            #expect(workspace.status == .failed)
            #expect(fixture.transports.count == 2)
            #expect(fixture.clock.waits.isEmpty)
        }
    }

    @Test func permissionGrantCanTakeMoreThanTwoMinutesAndManualCancelStillStopsReconnect() async throws {
        let fixture = MacDesktopReconnectFixture()
        let workspace = fixture.workspace()
        workspace.prepare(for: fixture.session)
        let first = try #require(fixture.transports.first)
        fixture.establish(first)
        first.onMessage?(.sessionEnded(.init(code: .permissionRequired, message: "请在对方 Mac 授予屏幕录制权限")))
        await fixture.settle()
        #expect(workspace.status == .reconnecting)
        try fixture.clock.complete(seconds: 1)
        await fixture.settle()
        let second = try #require(fixture.transports.last)
        // The user is still in macOS Settings and the host listener has stopped.
        fixture.clock.now = fixture.clock.now.addingTimeInterval(180)
        second.onStateChange?(.failed(.posix(.ECONNREFUSED)))
        await fixture.settle()
        #expect(workspace.status == .reconnecting)
        #expect(fixture.clock.waits.contains { $0.seconds == 2 })
        try fixture.clock.complete(seconds: 2)
        await fixture.settle()
        #expect(fixture.transports.count == 3)
        let third = try #require(fixture.transports.last)
        #expect(third.endpoint.identity == fixture.storedPairing?.clientID.uuidString)
        // Even another permission reminder must remain recoverable after this delay.
        third.onMessage?(.sessionEnded(.init(code: .permissionRequired, message: "仍在等待授权")))
        await fixture.settle()
        #expect(workspace.status == .reconnecting)
        workspace.disconnect()
        third.onStateChange?(.cancelled)
        await fixture.settle()
        #expect(workspace.status == .disconnected)
        #expect(fixture.clock.waits.isEmpty)
        #expect(fixture.transports.count == 3)
    }

    @Test func preferencePersistsAndDisablingItCancelsRetryWithoutDeletingPairing() async throws {
        let fixture = MacDesktopReconnectFixture()
        let workspace = fixture.workspace()
        workspace.prepare(for: fixture.session)
        let transport = try #require(fixture.transports.first)
        fixture.establish(transport)
        transport.onError?(NWError.posix(.ECONNRESET))
        await fixture.settle()
        workspace.setAutoReconnect(false)
        await fixture.settle()
        #expect(workspace.status == .disconnected)
        #expect(fixture.clock.waits.isEmpty)
        #expect(fixture.storedPairing?.autoReconnect == false)
        let reopened = fixture.workspace()
        reopened.prepare(for: fixture.session)
        #expect(reopened.status == .disconnected)
        #expect(reopened.hasSavedPairing)
        #expect(!reopened.autoReconnect)
        #expect(fixture.transports.count == 1)
    }

    @Test func invitationIsNeverReusedAutomaticallyButApprovalEnablesDeviceKeyReconnect() async throws {
        let fixture = MacDesktopReconnectFixture()
        fixture.storedPairing = nil
        let invitation = DesktopPairingInvitation(serverID: UUID(), host: fixture.session.host, port: UInt16(fixture.session.port),
                                                 psk: Data(repeating: 4, count: 32), invitationToken: try DesktopSecret.randomToken(),
                                                 expiresAt: fixture.clock.now.addingTimeInterval(300))
        let workspace = fixture.workspace()
        workspace.invitationCode = try invitation.encodedCode()
        workspace.connect(session: fixture.session)
        let first = try #require(fixture.transports.first)
        first.onError?(NWError.posix(.ECONNRESET))
        await fixture.settle()
        #expect(workspace.status == .failed)
        #expect(fixture.clock.waits.isEmpty)
        workspace.connect(session: fixture.session)
        let second = try #require(fixture.transports.last)
        second.onStateChange?(.ready)
        second.onMessage?(.hello(.init(hostName: "Mac mini")))
        second.onMessage?(.pairingPending)
        let deviceKey = Data(repeating: 5, count: 32)
        second.onMessage?(.pairingApproved(.init(hostName: "Mac mini", token: try DesktopSecret.randomToken(), psk: deviceKey)))
        second.onMessage?(.ready(.init(hostName: "Mac mini", width: 1920, height: 1080, canControl: true)))
        #expect(workspace.invitationCode.isEmpty)
        #expect(fixture.storedPairing?.psk == deviceKey)
        second.onError?(NWError.posix(.ECONNRESET))
        await fixture.settle()
        #expect(workspace.status == .reconnecting)
        try fixture.clock.complete(seconds: 1)
        await fixture.settle()
        #expect(fixture.transports.last?.endpoint.psk == deviceKey)
        #expect(fixture.transports.last?.endpoint.identity != DesktopProtocol.invitationIdentity)
        workspace.disconnect()
        await fixture.settle()
    }

    @Test func heartbeatTimeoutRetriesAndTLSCredentialRejectionStops() async throws {
        let fixture = MacDesktopReconnectFixture()
        let workspace = fixture.workspace()
        workspace.prepare(for: fixture.session)
        let transport = try #require(fixture.transports.first)
        fixture.establish(transport)
        await fixture.settle()
        fixture.clock.now = fixture.clock.now.addingTimeInterval(36)
        try fixture.clock.complete(seconds: 10)
        await fixture.settle()
        #expect(workspace.status == .reconnecting)
        try fixture.clock.complete(seconds: 1)
        await fixture.settle()
        let next = try #require(fixture.transports.last)
        next.onError?(NWError.tls(-9829))
        await fixture.settle()
        #expect(workspace.status == .failed)
        #expect(fixture.clock.waits.isEmpty)
    }
}

@MainActor
private final class MacDesktopReconnectFixture {
    let session = RemoteSession(name: "Mac mini", host: "mac-mini.local", username: "", port: 49871, connectionType: .macDesktop)
    let clock = MacDesktopManualClock()
    var storedPairing: MacDesktopStoredPairing? = pairing()
    var transports: [MacDesktopFakeTransport] = []

    static func pairing() -> MacDesktopStoredPairing {
        MacDesktopStoredPairing(serverID: UUID(), psk: Data(repeating: 3, count: 32), clientID: UUID(), clientName: "Current Mac",
                                token: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    }

    func workspace() -> MacDesktopWorkspaceState {
        var dependencies = MacDesktopClientDependencies()
        dependencies.readPairing = { [unowned self] _, _ in storedPairing }
        dependencies.savePairing = { [unowned self] pairing, _, _ in storedPairing = pairing }
        dependencies.deletePairing = { [unowned self] _, _ in storedPairing = nil }
        dependencies.makeTransport = { [unowned self] host, port, key, identity in
            let transport = MacDesktopFakeTransport(endpoint: .init(host: host, port: port, psk: key, identity: identity))
            transports.append(transport)
            return transport
        }
        dependencies.sleep = { [clock] seconds in try await clock.sleep(seconds) }
        dependencies.now = { [clock] in clock.now }
        return MacDesktopWorkspaceState(dependencies: dependencies)
    }

    func establish(_ transport: MacDesktopFakeTransport) {
        transport.onStateChange?(.ready)
        transport.onMessage?(.hello(.init(hostName: "Mac mini")))
        transport.onMessage?(.ready(.init(hostName: "Mac mini", width: 1920, height: 1080, canControl: true)))
    }

    func settle() async { for _ in 0..<40 { await Task.yield() } }
}

@MainActor
private final class MacDesktopManualClock {
    struct Wait {
        let id: UUID
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    var waits: [Wait] = []

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waits.append(Wait(id: id, seconds: seconds, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.waits.firstIndex(where: { $0.id == id }) else { return }
                self.waits.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    func complete(seconds: TimeInterval) throws {
        let index = try #require(waits.firstIndex { $0.seconds == seconds })
        waits.remove(at: index).continuation.resume()
    }
}

@MainActor
private final class MacDesktopFakeTransport: MacDesktopTransport {
    struct Endpoint {
        var host: String
        var port: UInt16
        var psk: Data
        var identity: String
    }
    let endpoint: Endpoint
    var onStateChange: ((NWConnection.State) -> Void)?
    var onMessage: ((RemoteDesktopMessage) -> Void)?
    var onError: ((Error) -> Void)?
    var messages: [RemoteDesktopMessage] = []
    var cancelled = false

    init(endpoint: Endpoint) { self.endpoint = endpoint }
    func start(queue: DispatchQueue) {}
    func cancel() { cancelled = true }
    func send(_ message: RemoteDesktopMessage, completion: ((Error?) -> Void)?) {
        messages.append(message)
        completion?(nil)
    }
}

#endif
