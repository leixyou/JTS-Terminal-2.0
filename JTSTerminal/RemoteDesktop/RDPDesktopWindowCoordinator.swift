#if ENABLE_RDP_2
import AppKit
import Combine
import SwiftUI

/// Windows present app-owned sessions. Closing a window never tears down a
/// connection; app termination and the explicit Disconnect command own that.
@MainActor
final class RDPDesktopWindowCoordinator: ObservableObject {
    static let shared = RDPDesktopWindowCoordinator(runtime: .shared)
    @Published private(set) var targets: [RemoteSession] = []
    private var controllers: [UUID: NSWindowController] = [:]
    private var delegates: [UUID: RDPDesktopWindowDelegate] = [:]
    let runtime: RDPDesktopRuntimeStore

    init(runtime: RDPDesktopRuntimeStore) { self.runtime = runtime }
    var hasWindows: Bool { !controllers.isEmpty }
    func window(for targetID: UUID) -> NSWindow? { controllers[targetID]?.window }

    func open(_ target: RemoteSession, activate: Bool = true, openProperties: @escaping () -> Void = {}) {
        guard target.connectionType == .rdp else { return }
        let id = target.targetID
        if controllers[id] == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("jts.rdp.desktop.\(id.uuidString.lowercased())")
            window.title = "\(target.name) — Windows"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenPrimary]
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 640, height: 480)
            window.center()
            let frameName = "JTS.RDP.Desktop.\(id.uuidString.lowercased())"
            window.setFrameUsingName(frameName)
            let initialFrame = window.frame
            let delegate = RDPDesktopWindowDelegate(frameName: frameName)
            window.delegate = delegate
            delegates[id] = delegate
            let content = RDPDesktopWindowContent(target: target, runtime: runtime,
                openProperties: openProperties, toggleFullScreen: { [weak self] in self?.toggleFullScreen(targetID: id) })
            window.contentViewController = Self.hostingController(rootView: content)
            // Attaching a flexible hosting controller can briefly adopt its
            // zero ideal size. Restore the chosen native frame before enabling
            // autosave, so that temporary minimum size never replaces it.
            window.setFrame(initialFrame, display: false)
            window.setFrameAutosaveName(frameName)
            controllers[id] = NSWindowController(window: window)
            targets.append(target)
        }
        guard let window = controllers[id]?.window else { return }
        delegates[id]?.cancelPendingHide()
        if !window.styleMask.contains(.fullScreen), delegates[id]?.isTransitioning != true,
           let screen = window.screen ?? NSScreen.main {
            let frame = Self.frameWithinVisibleScreen(window.frame, visible: screen.visibleFrame)
            if frame != window.frame { window.setFrame(frame, display: false) }
        }
        window.title = "\(target.name) — Windows"
        if activate {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if !window.isVisible && !window.isMiniaturized {
            // Never deminiaturize, activate, change key window or order above the
            // user's current app for a background MCP open.
            window.orderBack(nil)
        }
    }

    func show(targetID: UUID) {
        guard let target = targets.first(where: { $0.targetID == targetID }) else { return }
        open(target)
    }

    func toggleFullScreen(targetID: UUID) {
        guard let window = window(for: targetID), let delegate = delegates[targetID],
              !delegate.isTransitioning else { return }
        delegate.cancelPendingHide()
        window.toggleFullScreen(nil)
    }

    func reconcile(validTargetIDs: Set<UUID>) {
        for id in Array(controllers.keys) where !validTargetIDs.contains(id) {
            if let window = controllers[id]?.window {
                delegates[id]?.prepareForClose(window)
            }
            controllers[id]?.window?.delegate = nil
            controllers.removeValue(forKey: id)?.close()
            delegates.removeValue(forKey: id)
        }
        targets.removeAll { !validTargetIDs.contains($0.targetID) }
    }

    func closeAllWindows() { reconcile(validTargetIDs: []) }

    /// Freeze ordinary window placement before session shutdown swaps the live
    /// desktop for a smaller state view and before AppKit tears down hosting.
    func prepareForTermination() {
        for (id, controller) in controllers {
            if let window = controller.window { delegates[id]?.prepareForClose(window) }
        }
    }

    /// AppKit owns the viewport. A changing remote framebuffer must not feed
    /// SwiftUI's ideal/preferred content size back into the native window.
    static func hostingController<Content: View>(rootView: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = []
        return controller
    }

    static func frameWithinVisibleScreen(_ frame: CGRect, visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return frame }
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }
}

@MainActor
final class RDPDesktopWindowDelegate: NSObject, NSWindowDelegate {
    private let frameName: String
    private(set) var isTransitioning = false
    private var hideAfterExit = false
    private var isPreparedForClose = false
    private var isFullScreen = false

    init(frameName: String) { self.frameName = frameName }

    func prepareForClose(_ window: NSWindow) {
        guard !isPreparedForClose else { return }
        isPreparedForClose = true
        hideAfterExit = false
        if !window.styleMask.contains(.fullScreen), !isFullScreen, !isTransitioning {
            window.saveFrame(usingName: frameName)
        }
        window.setFrameAutosaveName("")
    }

    func cancelPendingHide() { hideAfterExit = false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.styleMask.contains(.fullScreen) || isTransitioning {
            hideAfterExit = true
            if !isTransitioning { sender.toggleFullScreen(nil) }
        } else {
            saveOrdinaryFrame(sender)
            sender.orderOut(nil)
        }
        return false
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            // willEnter still carries the ordinary frame. Persist it before
            // any animation can feed full-screen geometry to autosave.
            if !isPreparedForClose, !isFullScreen, !isTransitioning {
                window.saveFrame(usingName: frameName)
            }
            isTransitioning = true
            window.setFrameAutosaveName("")
        } else { isTransitioning = true }
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        isTransitioning = true
        (notification.object as? NSWindow)?.setFrameAutosaveName("")
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        isTransitioning = false
        if !isPreparedForClose, hideAfterExit, let window = notification.object as? NSWindow {
            window.toggleFullScreen(nil)
        }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        isTransitioning = false
        if let window = notification.object as? NSWindow { resumeOrdinaryAutosave(window) }
        if hideAfterExit { (notification.object as? NSWindow)?.orderOut(nil); hideAfterExit = false }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isFullScreen = false
        isTransitioning = false
        resumeOrdinaryAutosave(window)
        if hideAfterExit { window.orderOut(nil); hideAfterExit = false }
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isFullScreen = true
        isTransitioning = false
        hideAfterExit = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveOrdinaryFrame(window) }
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveOrdinaryFrame(window) }
    }

    private func saveOrdinaryFrame(_ window: NSWindow) {
        guard !isPreparedForClose, !isFullScreen, !isTransitioning,
              !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: frameName)
    }

    private func resumeOrdinaryAutosave(_ window: NSWindow) {
        guard !isPreparedForClose, !window.styleMask.contains(.fullScreen) else { return }
        let ordinaryFrame = window.frame
        window.setFrameAutosaveName(frameName)
        if window.frame != ordinaryFrame { window.setFrame(ordinaryFrame, display: false) }
        saveOrdinaryFrame(window)
    }
}

private struct RDPDesktopWindowContent: View {
    let target: RemoteSession
    @ObservedObject var runtime: RDPDesktopRuntimeStore
    let openProperties: () -> Void
    let toggleFullScreen: () -> Void
    @ObservedObject private var companion = CompanionDesktopRuntime.shared
    @State private var route: CompanionDesktopRoutePreference = .rdp
    @State private var routeError: String?
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.defaultLanguage.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Desktop", selection: Binding(get: { route }, set: { selected in
                    Task {
                        do {
                            await runtime.close(targetID: target.targetID)
                            try await companion.choose(selected, target: target)
                            route = selected; routeError = nil
                        } catch { routeError = companion.safeCode(error) }
                    }
                })) {
                    Text("RDP").tag(CompanionDesktopRoutePreference.rdp)
                    Text("Companion").tag(CompanionDesktopRoutePreference.companion)
                }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
                if let routeError { Text(routeError).font(.caption).foregroundStyle(.orange) }
            }.padding(8)
            if route == .companion {
                CompanionDesktopWorkspace(target: target, toggleFullScreen: toggleFullScreen)
            } else {
                RDPDesktopWindowSurface(target: target, presentation: runtime.presentation(for: target),
                    openServerProperties: openProperties, toggleFullScreen: toggleFullScreen)
            }
        }
            .controlSize(.small)
            .environment(\.appLanguage, AppLanguage(rawValue: languageRawValue) ?? .defaultLanguage)
            .accessibilityIdentifier("rdp-independent-desktop")
            .task { if let binding = try? await companion.route(for: target) { route = binding.effectiveDesktopRoute } }
            .onReceive(NotificationCenter.default.publisher(for: .jtsCompanionTargetRouteChanged)) { notification in
                guard notification.object as? UUID == target.targetID else { return }
                Task { if let binding = try? await companion.route(for: target) { route = binding.effectiveDesktopRoute } }
            }
    }
}

/// Give the independent window the same bounded, top-leading feature viewport
/// as the main workspace. In particular, full-screen and resize proposals must
/// reach the AppKit framebuffer instead of centering an ideal-sized child.
struct RDPDesktopWindowSurface: View {
    let target: RemoteSession
    let presentation: RDPDesktopWorkspacePresentation
    let openServerProperties: () -> Void
    let toggleFullScreen: () -> Void

    var body: some View {
        GeometryReader { proxy in
            RDPDesktopFeatureContainer {
                RDPDesktopWorkspace(session: target, presentation: presentation,
                    openServerProperties: openServerProperties, toggleFullScreen: toggleFullScreen)
            }
            .padding(8)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}
#endif
