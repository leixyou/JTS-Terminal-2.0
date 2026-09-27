#if ENABLE_RDP_2
import AppKit
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
@Suite(.serialized)
struct RDPDesktopWindowTests {
    @Test func fullScreenTransitionsPreserveOrdinaryPlacementAndResumeSavingAfterExitOrFailedEntry() throws {
        let (window, delegate, frameName) = makeDelegateWindow()
        let preferenceKey = "NSWindow Frame \(frameName)"
        defer { cleanUpDelegateWindow(window, frameName: frameName) }
        window.setContentSize(CGSize(width: 960, height: 620))
        delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        let resized = try #require(UserDefaults.standard.string(forKey: preferenceKey))
        window.setFrameOrigin(CGPoint(x: window.frame.minX + 12, y: window.frame.minY + 8))
        delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        let ordinaryFrame = window.frame
        let savedOrdinary = try #require(UserDefaults.standard.string(forKey: preferenceKey))
        #expect(savedOrdinary != resized)

        // Drive AppKit's delegate lifecycle without changing the user's Space.
        delegate.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(window.frameAutosaveName.isEmpty)
        window.setFrame(CGRect(x: 0, y: 0, width: 1_400, height: 900), display: false)
        delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedOrdinary)
        delegate.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedOrdinary)

        delegate.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
        delegate.windowDidFailToExitFullScreen(window)
        delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(window.frameAutosaveName.isEmpty)
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedOrdinary)
        delegate.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
        window.setFrame(ordinaryFrame, display: false)
        #expect(window.frameAutosaveName.isEmpty)
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedOrdinary)
        delegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(window.frameAutosaveName == frameName)
        #expect(window.frame == ordinaryFrame)
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedOrdinary)

        window.setContentSize(CGSize(width: 880, height: 580))
        delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        let nextOrdinaryFrame = window.frame
        let savedNextOrdinary = try #require(UserDefaults.standard.string(forKey: preferenceKey))
        #expect(savedNextOrdinary != savedOrdinary)
        delegate.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setFrame(CGRect(x: 0, y: 0, width: 1_400, height: 900), display: false)
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedNextOrdinary)
        window.setFrame(nextOrdinaryFrame, display: false)
        delegate.windowDidFailToEnterFullScreen(window)
        #expect(window.frameAutosaveName == frameName)
        #expect(window.frame == nextOrdinaryFrame)
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedNextOrdinary)
    }

    @Test func terminationDuringFullScreenIgnoresLateExitAndResizeNotifications() throws {
        let (window, delegate, frameName) = makeDelegateWindow()
        let preferenceKey = "NSWindow Frame \(frameName)"
        defer { cleanUpDelegateWindow(window, frameName: frameName) }
        window.setContentSize(CGSize(width: 960, height: 620))
        delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        let ordinaryFrame = window.frame
        let savedOrdinary = try #require(UserDefaults.standard.string(forKey: preferenceKey))
        delegate.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(!delegate.windowShouldClose(window)) // Queue a hide while entry is still animating.
        window.setFrame(CGRect(x: 0, y: 0, width: 1_400, height: 900), display: false)
        delegate.prepareForClose(window)
        delegate.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        #expect(window.fullScreenToggleCount == 0)
        delegate.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
        window.setFrame(CGRect(x: 40, y: 40, width: 640, height: 480), display: false)
        delegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        delegate.windowDidFailToEnterFullScreen(window)
        delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(window.frameAutosaveName.isEmpty)
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedOrdinary)

        let restored = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        restored.isReleasedWhenClosed = false
        defer { restored.close() }
        #expect(restored.setFrameUsingName(frameName))
        #expect(restored.frame == ordinaryFrame)
    }

    private func makeDelegateWindow() -> (RDPDesktopTestWindow, RDPDesktopWindowDelegate, String) {
        _ = NSApplication.shared
        let frameName = "JTS.RDP.Desktop.Test.\(UUID().uuidString.lowercased())"
        let window = RDPDesktopTestWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        let delegate = RDPDesktopWindowDelegate(frameName: frameName)
        window.delegate = delegate
        window.setFrameAutosaveName(frameName)
        return (window, delegate, frameName)
    }

    private func cleanUpDelegateWindow(_ window: NSWindow, frameName: String) {
        window.setFrameAutosaveName("")
        window.delegate = nil
        window.close()
        NSWindow.removeFrame(usingName: frameName)
    }

    @Test func terminationPreservesTheUserFrameAcrossCoordinatorTeardownAndLateHostLayout() throws {
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw WindowsMCPToolError(code: .runtimeFailure, message: "No connection expected.")
        })
        let windows = RDPDesktopWindowCoordinator(runtime: runtime)
        let reopened = RDPDesktopWindowCoordinator(runtime: runtime)
        let target = RemoteSession(name: "Lifecycle size", host: "lifecycle-size.test", username: "operator", connectionType: .rdp)
        let frameName = "JTS.RDP.Desktop.\(target.targetID.uuidString.lowercased())"
        let preferenceKey = "NSWindow Frame \(frameName)"
        defer {
            windows.closeAllWindows(); reopened.closeAllWindows(); runtime.stopAllImmediately()
            NSWindow.removeFrame(usingName: frameName)
        }
        windows.open(target, activate: false)
        let window = try #require(windows.window(for: target.targetID))
        runtime.installActiveDesktopForTesting(target: target)
        window.setContentSize(CGSize(width: 960, height: 620))
        settle(window)
        let expectedFrame = window.frame

        // Same ordering as accepted Cmd-Q: freeze placement before publishing
        // closed session state, then release the native window/hosting tree.
        windows.prepareForTermination()
        let savedFrame = try #require(UserDefaults.standard.string(forKey: preferenceKey))
        #expect(window.frameAutosaveName.isEmpty)
        runtime.stopAllImmediately()
        settle(window)
        windows.closeAllWindows()
        window.contentViewController = nil
        window.setContentSize(CGSize(width: 640, height: 480))
        settle(window)
        #expect(UserDefaults.standard.string(forKey: preferenceKey) == savedFrame)

        reopened.open(target, activate: false)
        let restored = try #require(reopened.window(for: target.targetID))
        settle(restored)
        #expect(restored.frame == expectedFrame)
        #expect(restored !== window)
    }

    @Test func firstCoordinatorWindowKeepsItsDefaultContentSizeAfterHostingAttaches() throws {
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw WindowsMCPToolError(code: .runtimeFailure, message: "No connection expected.")
        })
        let windows = RDPDesktopWindowCoordinator(runtime: runtime)
        let target = RemoteSession(name: "Default size", host: "default-size.test", username: "operator", connectionType: .rdp)
        let frameName = "JTS.RDP.Desktop.\(target.targetID.uuidString.lowercased())"
        defer {
            windows.closeAllWindows(); runtime.stopAllImmediately()
            NSWindow.removeFrame(usingName: frameName)
        }
        windows.open(target, activate: false)
        let window = try #require(windows.window(for: target.targetID))
        settle(window)
        let content = window.contentRect(forFrameRect: window.frame)
        let screen = try #require(window.screen ?? NSScreen.main)
        let titlebarHeight = window.frame.height - content.height
        #expect(abs(content.width - min(1_120, screen.visibleFrame.width)) <= 1)
        #expect(abs(content.height - min(760, screen.visibleFrame.height - titlebarHeight)) <= 1)

        window.setContentSize(CGSize(width: 960, height: 620))
        let selectedFrame = window.frame
        let delegate = try #require(window.delegate as? RDPDesktopWindowDelegate)
        #expect(!delegate.windowShouldClose(window))
        windows.open(target, activate: false)
        settle(window)
        #expect(window.frame == selectedFrame)
    }

    @Test func coordinatorRestoresAReasonableSavedFrameBeforeEnablingAutosave() throws {
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw WindowsMCPToolError(code: .runtimeFailure, message: "No connection expected.")
        })
        let windows = RDPDesktopWindowCoordinator(runtime: runtime)
        let target = RemoteSession(name: "Saved size", host: "saved-size.test", username: "operator", connectionType: .rdp)
        let frameName = "JTS.RDP.Desktop.\(target.targetID.uuidString.lowercased())"
        let saved = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        saved.isReleasedWhenClosed = false
        saved.center()
        let expected = saved.frame
        saved.saveFrame(usingName: frameName)
        saved.close()
        defer {
            windows.closeAllWindows(); runtime.stopAllImmediately()
            NSWindow.removeFrame(usingName: frameName)
        }
        windows.open(target, activate: false)
        let window = try #require(windows.window(for: target.targetID))
        settle(window)
        #expect(window.frame == expected)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
    }

    @Test func windowReuseAndClosePreserveExactTargetSessions() throws {
        _ = NSApplication.shared
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw WindowsMCPToolError(code: .runtimeFailure, message: "Opening a window must not connect.")
        })
        let windows = RDPDesktopWindowCoordinator(runtime: runtime)
        defer { windows.closeAllWindows(); runtime.stopAllImmediately() }
        let first = RemoteSession(name: "Windows A", host: "a.test", username: "operator", connectionType: .rdp)
        let second = RemoteSession(name: "Windows B", host: "b.test", username: "operator", connectionType: .rdp)
        windows.open(first, activate: false)
        windows.open(second, activate: false)
        let a = try #require(windows.window(for: first.targetID))
        let b = try #require(windows.window(for: second.targetID))
        #expect(a !== b)
        #expect(windows.targets.count == 2)
        #expect(runtime.sessionID(for: first.targetID) == nil)
        let firstSession = runtime.installActiveDesktopForTesting(target: first)
        let secondSession = runtime.installActiveDesktopForTesting(target: second)
        windows.open(first, activate: false)
        #expect(windows.window(for: first.targetID) === a)
        #expect(windows.targets.count == 2)
        #expect(a.collectionBehavior.contains(.fullScreenPrimary))
        #expect(a.tabbingMode == .disallowed)
        let delegate = try #require(a.delegate as? RDPDesktopWindowDelegate)
        #expect(delegate.windowShouldClose(a) == false)
        #expect(!a.isVisible)
        #expect(runtime.sessionID(for: first.targetID) == firstSession)
        #expect(runtime.sessionID(for: second.targetID) == secondSession)
        #expect(windows.window(for: first.targetID) === a)
        #expect(windows.window(for: second.targetID) === b)
        windows.reconcile(validTargetIDs: [second.targetID])
        #expect(windows.window(for: first.targetID) == nil)
        #expect(windows.window(for: second.targetID) === b)
    }

    @Test func backgroundOpenDoesNotReplaceTheKeyWindow() throws {
        _ = NSApplication.shared
        let local = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        local.isReleasedWhenClosed = false
        local.makeKeyAndOrderFront(nil)
        let previousKey = NSApp.keyWindow
        defer { local.close() }
        let runtime = RDPDesktopRuntimeStore(openOperationExecutorForTesting: { _, _, _ in
            throw WindowsMCPToolError(code: .runtimeFailure, message: "No connection expected.")
        })
        let windows = RDPDesktopWindowCoordinator(runtime: runtime)
        defer { windows.closeAllWindows(); runtime.stopAllImmediately() }
        windows.open(RemoteSession(name: "Background", host: "background.test", username: "operator", connectionType: .rdp), activate: false)
        #expect(NSApp.keyWindow === previousKey)
    }

    @Test func backgroundLaunchArgumentsKeepTheBundlePathAsOneArgument() {
        let path = "/Applications/JTS Terminal.app"
        #expect(JTSBackgroundLaunchPolicy.openArguments(bundlePath: path, activate: true) == [path])
        #expect(JTSBackgroundLaunchPolicy.openArguments(bundlePath: path, activate: false)
            == ["-g", path, "--args", "--jts-background-desktop"])
        let old = try? JSONDecoder().decode(DesktopOpenRequest.self, from: Data("{}".utf8))
        #expect(old != nil)
        #expect(old?.activateWindow == nil)
    }
}

@MainActor
private final class RDPDesktopTestWindow: NSWindow {
    private(set) var fullScreenToggleCount = 0

    override func toggleFullScreen(_ sender: Any?) {
        fullScreenToggleCount += 1
    }
}
#endif
