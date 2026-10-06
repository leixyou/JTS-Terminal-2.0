#if ENABLE_RDP_2
import Foundation
import JTSCompanionClient
import JTSCompanionDevices
import Testing
@testable import JTSTerminal

@MainActor
struct MacSystemScreenSharingPolicyTests {
    @Test func routeChangeBeforeFirstSuspensionCancelsConnect() {
        let targetID = UUID()
        let state = MacSystemScreenSharingState(targetID: targetID)
        state.connect(targetBinding: "pending-route") {}
        #expect(state.active)
        NotificationCenter.default.post(name: .jtsCompanionTargetRouteChanged, object: targetID)
        #expect(!state.active)
        state.retire()
    }

    @Test func removedProfileCannotReconnectThroughRetainedViewState() {
        let store = MacSystemScreenSharingStore()
        let targetID = UUID()
        let retainedState = store.state(for: targetID)
        store.remove(targetID: targetID)
        let authorization = AuthorizationProbe()
        retainedState.connect(targetBinding: "removed-profile") { authorization.called = true }
        #expect(!retainedState.active)
        #expect(!authorization.called)
        let replacement = store.state(for: targetID)
        #expect(replacement !== retainedState)
        store.remove(targetID: targetID)
    }

    @Test func permanentTrustAndGrantFailuresStopReconnect() {
        #expect(!MacSystemScreenSharingState.canRetry(CompanionDeviceError.deviceRevoked))
        #expect(!MacSystemScreenSharingState.canRetry(CompanionDeviceError.identityChanged))
        #expect(!MacSystemScreenSharingState.canRetry(CompanionTargetRouteError.changed))
        #expect(!MacSystemScreenSharingState.canRetry(CompanionClientError.remote("GRANT_REVOKED")))
        #expect(!MacSystemScreenSharingState.canRetry(CompanionClientError.remote("TLS_PEER_REJECTED")))
        #expect(!MacSystemScreenSharingState.canRetry(CancellationError()))
    }
    @Test func transientNetworkFailureCanReconnectButViewerClosureCannot() {
        #expect(MacSystemScreenSharingState.canRetry(CompanionClientError.interrupted))
        #expect(MacSystemScreenSharingState.canRetry(CompanionClientError.remote("DEVICE_OFFLINE")))
        #expect(MacSystemScreenSharingState.canRetry(URLError(.networkConnectionLost)))
        #expect(!MacSystemScreenSharingState.canRetry(NativeScreenSharingBridgeError.viewerDisconnected))
        #expect(!MacSystemScreenSharingState.canRetry(NativeScreenSharingBridgeError.viewerTimedOut))
        #expect(!MacSystemScreenSharingState.canRetry(NativeScreenSharingBridgeError.transportRejected))
    }
    @Test func macImportCannotAcquireWindowsOrTerminalMCPControl() throws {
        let session = RemoteSession(name: "Mac", host: "localhost", username: "", port: 49871, connectionType: .macDesktop)
        session.mcpEnabled = true
        session.mcpAlwaysAllowTerminalControl = true
        let profile = try #require(SessionProfileCodec.decode(SessionProfileCodec.encode(sessions: [session])).first)
        #expect(!profile.mcpEnabled)
        #expect(!profile.makeSession().mcpAlwaysAllowTerminalControl)
        #expect(session.mcpPermissionPolicy.maximumCapabilities.isEmpty)
    }
}

@MainActor
private final class AuthorizationProbe {
    var called = false
}
#endif
