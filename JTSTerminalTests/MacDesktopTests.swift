#if ENABLE_RDP_2
import AppKit
import Foundation
import RemoteDesktopCore
import Testing
@testable import JTSTerminal

@MainActor
struct MacDesktopTests {
    @Test func desktopProfileUsesItsOwnEndpointAndDoesNotNeedSSHUsername() {
        let session = RemoteSession(name: "Mac mini", host: "mac-mini.local", username: "", port: 49871, connectionType: .macDesktop)
        #expect(session.isConnectable)
        #expect(session.address == "mac-mini.local:49871")
        #expect(session.connectionKey == "mac-desktop:mac-mini.local:49871")
        session.port = 65536
        #expect(!session.isConnectable)
        session.port = 0
        #expect(!session.isConnectable)
    }

    @Test func pairingAccountsAreSeparateFromSSHAndNormalizeHost() {
        let account = MacDesktopPairingStore.account(host: " Mac-Mini.LOCAL ", port: 49871)
        #expect(account == "mac-desktop:mac-mini.local:49871")
        let ssh = RemoteSession(host: "Mac-Mini.LOCAL", username: "mac-desktop", port: 49871)
        #expect(account != CredentialStore.account(for: ssh))
    }

    @Test func desktopProfileRoundTripsWithoutCredentialFields() throws {
        let session = RemoteSession(name: "Mac mini", host: "192.168.1.20", username: "", port: 49871, connectionType: .macDesktop)
        let data = try SessionProfileCodec.encode(sessions: [session])
        let profiles = try SessionProfileCodec.decode(data)
        let imported = try #require(profiles.first).makeSession()
        #expect(imported.connectionType == .macDesktop)
        #expect(imported.port == 49871)
        #expect(imported.host == session.host)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("psk"))
        #expect(!text.contains("token"))
        #expect(!text.contains("invitation"))
    }

    @Test func legacySSHProfileStillDecodes() throws {
        let data = Data(#"{"version":1,"exportedAt":"2026-10-01T00:00:00Z","sessions":[{"name":"Server","host":"example.com","username":"tester"}]}"#.utf8)
        let profile = try #require(SessionProfileCodec.decode(data).first)
        #expect(profile.connectionType == .ssh)
        #expect(profile.port == 22)
    }

    @Test func letterboxingDoesNotSendPointerEventsOutsideScreen() {
        let rect = MacDesktopViewport.imageRect(imageSize: CGSize(width: 1920, height: 1080), bounds: CGRect(x: 0, y: 0, width: 800, height: 800))
        #expect(rect == CGRect(x: 0, y: 175, width: 800, height: 450))
        #expect(MacDesktopViewport.normalizedPoint(CGPoint(x: 400, y: 40), imageRect: rect) == nil)
        #expect(MacDesktopViewport.normalizedPoint(CGPoint(x: 400, y: 400), imageRect: rect) == CGPoint(x: 0.5, y: 0.5))
        #expect(MacDesktopViewport.normalizedPoint(CGPoint(x: 0, y: 175), imageRect: rect) == .zero)
    }

    @Test func dragReleaseClampsToRemoteScreenEdges() {
        let rect = CGRect(x: 25, y: 50, width: 100, height: 200)
        #expect(MacDesktopViewport.normalizedPoint(CGPoint(x: 500, y: -20), imageRect: rect, clamp: true) == CGPoint(x: 1, y: 0))
        #expect(MacDesktopViewport.normalizedPoint(.zero, imageRect: .zero, clamp: true) == nil)
    }

    @Test func disablingControlReleasesHeldInput() {
        let view = MacDesktopSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        var releases = 0
        view.onRelease = { releases += 1 }
        view.inputEnabled = true
        view.inputEnabled = false
        #expect(releases >= 1)
        #expect(!view.acceptsFirstResponder)
    }

    @Test func firstModifierReleaseAfterFocusDoesNotBecomePress() {
        #expect(!MacDesktopKeyboardInput.modifierIsDown(keyCode: 56, flags: [], keyState: { _ in false }))
        // The other Shift key can remain down without making this side a press.
        #expect(!MacDesktopKeyboardInput.modifierIsDown(keyCode: 56, flags: .shift, keyState: { _ in false }))
        #expect(MacDesktopKeyboardInput.modifierIsDown(keyCode: 57, flags: .capsLock, keyState: { _ in false }))
    }

    @Test func gainingControlSynchronizesAlreadyHeldModifiers() {
        #expect(MacDesktopKeyboardInput.heldModifierKeys(flags: .command, keyState: { $0 == 55 }) == [55])
        #expect(MacDesktopKeyboardInput.heldModifierKeys(flags: [.shift, .capsLock], keyState: { $0 == 60 }) == [60, 57])
        #expect(MacDesktopKeyboardInput.heldModifierKeys(flags: [], keyState: { _ in false }).isEmpty)
    }

    @Test func keyboardFlagsExcludeDeviceSpecificBits() {
        #expect(MacDesktopKeyboardInput.modifiers(NSEvent.ModifierFlags(rawValue: 0xffffffff)) == 0x00ff0000)
    }

    @Test func desktopCannotBecomeConnectedBeforeAuthorization() {
        let workspace = MacDesktopWorkspaceState()
        workspace.receive(.ready(DesktopSessionInfo(hostName: "Unexpected Mac", width: 1920, height: 1080, canControl: true)))
        #expect(workspace.status == .failed)
        #expect(!workspace.acceptsInput)
        workspace.receive(.frame(RemoteDesktopCore.DesktopFrame(width: 1, height: 1, jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))))
        #expect(workspace.image == nil)
        #expect(workspace.status == .failed)
    }

    @Test func desktopJPEGDimensionsMustMatchMetadata() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.5]))
        let decoded = try MacDesktopFrameDecoder.decode(RemoteDesktopCore.DesktopFrame(width: 2, height: 1, jpeg: jpeg))
        #expect(decoded.image.width == 2)
        #expect(decoded.image.height == 1)
        #expect(throws: MacDesktopFrameError.self) {
            try MacDesktopFrameDecoder.decode(RemoteDesktopCore.DesktopFrame(width: 16384, height: 16384, jpeg: jpeg))
        }
    }

    @Test func invalidPairingFailsLocallyAndCanDisconnect() {
        let workspace = MacDesktopWorkspaceState()
        workspace.invitationCode = "invalid pairing code"
        workspace.connect(session: RemoteSession(connectionType: .macDesktop))
        #expect(workspace.status == .failed)
        #expect(workspace.errorMessage != nil)
        #expect(!workspace.acceptsInput)
        workspace.disconnect()
        #expect(workspace.status == .disconnected)
        #expect(workspace.image == nil)
    }
}

#endif
