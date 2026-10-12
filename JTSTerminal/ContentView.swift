//
//  ContentView.swift
//  JTSTerminal
//
//  Created by tester on 2026/4/29.
//

import AppKit
import Combine
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if canImport(SwiftTerm)
import SwiftTerm
#endif

private typealias Color = SwiftUI.Color

enum AppIconProvider {
    static var image: NSImage {
        if let namedImage = NSImage(named: "AppIcon"),
           !namedImage.representations.isEmpty {
            return namedImage
        }

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let bundledImage = NSImage(contentsOf: iconURL),
           !bundledImage.representations.isEmpty {
            return bundledImage
        }

        return NSImage(size: NSSize(width: 64, height: 64))
    }
}

private struct AppIconMark: View {
    let size: CGFloat

    /// The macOS icon follows Apple's grid: an 824 pt tile with a transparent
    /// margin on a 1024 pt canvas. Enlarge it so the tile fills the mark.
    private static let tileScale: CGFloat = 1024 / 824

    var body: some View {
        Image(nsImage: AppIconProvider.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size * Self.tileScale, height: size * Self.tileScale)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RemoteSession.updatedAt, order: .reverse) private var sessions: [RemoteSession]
    #if ENABLE_RDP_2
    @ObservedObject private var terminalWorkspaceStore = ApplicationWorkspaceRuntime.shared.terminals
    @ObservedObject private var terminalBroadcastCoordinator = ApplicationWorkspaceRuntime.shared.broadcasts
    @ObservedObject private var tunnelManagerStore = ApplicationWorkspaceRuntime.shared.tunnels
    @ObservedObject private var remoteFilesWorkspaceStore = ApplicationWorkspaceRuntime.shared.files
    @ObservedObject private var transferQueueManager = ApplicationWorkspaceRuntime.shared.transfers
    @ObservedObject private var terminalMCPBridgeServer = ApplicationWorkspaceRuntime.shared.bridge
    #else
    @StateObject private var terminalWorkspaceStore = TerminalWorkspaceStore()
    @StateObject private var terminalBroadcastCoordinator = TerminalBroadcastCoordinator()
    @StateObject private var tunnelManagerStore = SSHTunnelManagerStore()
    @StateObject private var remoteFilesWorkspaceStore = RemoteFilesWorkspaceStore()
    @StateObject private var transferQueueManager = RemoteTransferQueueManager()
    @StateObject private var terminalMCPBridgeServer = TerminalMCPBridgeServer()
    #endif
    @StateObject private var rdpDesktopRuntimeStore = RDPDesktopRuntimeStore.shared
    @StateObject private var remoteClientGrantStore = RemoteClientGrantStore.shared
    @State private var selectedSessionID: PersistentIdentifier?
    @State private var selectedWorkspaceFeature: WorkspaceFeature = .command
    @State private var sidebarSearchText = ""
    @State private var detachedDraftPropertiesSessionID: PersistentIdentifier?
    @State private var transientNewSessionID: PersistentIdentifier?
    @State private var serverPropertiesWindow: NSWindow?
    @State private var serverPropertiesWindowDelegate: ServerPropertiesWindowDelegate?
    @State private var serverPropertiesSessionID: PersistentIdentifier?
    @State private var isShowingNewGroupPrompt = false
    @State private var pendingNewGroupName = ""
    @AppStorage(WelcomeGuidePolicy.storageKey) private var hasSeenWelcomeGuide = false
    @AppStorage(TerminalMCPBridgeLaunchPolicy.userDefaultsKey) private var isTerminalMCPBridgeEnabled = false
    @State private var isShowingWelcomeGuide = false
    #if JTS_UI_TEST_SUPPORT
    @State private var didSeedUITestSession = false
    #endif
    @State private var persistenceNotice = ModelContainerFactory.persistenceNotice
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.defaultLanguage.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage.resolved(from: appLanguageRawValue)
    }

    private var windowTitle: String {
        guard let selectedSession else { return MainWindowLifecycle.title }
        let name = selectedSession.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? appLanguage.localized("Unnamed Server", "未命名服务器") : name
    }

    private var windowSubtitle: String {
        guard let selectedSession else { return "" }
        guard selectedSession.isConnectable else {
            return appLanguage.localized("Needs setup", "待配置")
        }
        return "\(selectedSession.localizedAddress(language: appLanguage)) · \(selectedSession.connectionType.displayName(language: appLanguage))"
    }

    private var selectedSession: RemoteSession? {
        let excludedSessionID = detachedMainSelectionSessionID
        if let selectedSessionID,
           selectedSessionID != excludedSessionID,
           let session = sessions.first(where: { $0.persistentModelID == selectedSessionID }) {
            return SessionSelectionPolicy.usableMainSession(
                current: session,
                sessions: sessions,
                excluding: excludedSessionID
            )
        }

        return SessionSelectionPolicy.defaultSession(from: sessions, excluding: excludedSessionID)
    }

    private var detachedMainSelectionSessionID: PersistentIdentifier? {
        guard let detachedDraftPropertiesSessionID,
              let session = sessions.first(where: { $0.persistentModelID == detachedDraftPropertiesSessionID }),
              !session.isConnectable else {
            return nil
        }

        return detachedDraftPropertiesSessionID
    }

    var body: some View {
        NavigationSplitView {
            ServerSidebar(
                sessions: sessions,
                selectedSessionID: $selectedSessionID,
                searchText: $sidebarSearchText,
                addSession: addSession,
                addGroup: requestNewGroup,
                deleteSessions: deleteSessions,
                selectSession: selectSessionFromSidebar,
                openProperties: { session in
                    showProperties(for: session, selectInMainWindow: false)
                },
                openSession: openTerminalFromSidebar
            )
        } detail: {
            Group {
                if let selectedSession {
                    RemoteWorkspace(
                        session: selectedSession,
                        sessions: sessions,
                        selectedFeature: $selectedWorkspaceFeature,
                        terminalWorkspaceStore: terminalWorkspaceStore,
                        terminalBroadcastCoordinator: terminalBroadcastCoordinator,
                        tunnelManagerStore: tunnelManagerStore,
                        remoteFilesWorkspaceStore: remoteFilesWorkspaceStore,
                        transferQueueManager: transferQueueManager,
                        rdpDesktopRuntimeStore: rdpDesktopRuntimeStore,
                        openServerProperties: {
                            showProperties(for: selectedSession)
                        }
                    )
                    .id(selectedSession.persistentModelID)
                } else {
                    EmptyWorkspace(addSession: addSession)
                }
            }
            .navigationSplitViewColumnWidth(min: 0, ideal: 1_040)
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .navigationSplitViewStyle(.balanced)
        .environment(\.appLanguage, appLanguage)
        .environment(\.locale, Locale(identifier: appLanguage.localeIdentifier))
        .toolbar {
            if let selectedSession {
                ToolbarItem(placement: .principal) {
                    WorkspaceFeaturePicker(
                        selection: $selectedWorkspaceFeature,
                        connectionType: selectedSession.connectionType,
                        language: appLanguage
                    )
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                #if ENABLE_RDP_2
                if let selectedSession,
                   RemoteGrantManagementEntryPolicy.isVisible(
                       for: selectedSession.connectionType,
                       mcpEnabled: selectedSession.mcpEnabled
                   ) {
                    RemoteGrantManagementButton(
                        session: selectedSession,
                        language: appLanguage
                    ) {
                        if selectedSession.connectionType == .rdp {
                            rdpDesktopRuntimeStore.takeManualControl(
                                targetID: selectedSession.targetID
                            )
                        } else {
                            terminalWorkspaceStore.revokeAllMCPControl()
                        }
                    }
                }
                #endif

                Button {
                    if let selectedSession {
                        showProperties(for: selectedSession)
                    }
                } label: {
                    Label(appLanguage.localized("Server Properties", "服务器属性"), systemImage: "info.circle")
                }
                .help(appLanguage.localized("Server Properties", "服务器属性"))
                .disabled(selectedSession == nil)
                .accessibilityIdentifier("toolbar-server-properties-button")
            }
        }
        .focusedSceneValue(\.jtsTerminalCommandHandlers, commandHandlers)
        .task {
            #if JTS_UI_TEST_SUPPORT
            seedUITestSessionIfNeeded()
            #endif
        }
        .onAppear {
            reconcileSelectedSessionIfNeeded()
            reconcileWorkspaceFeatureForSelectedSession()
            RemoteProcessShutdownGuard.shared.register(
                terminalWorkspaceStore: terminalWorkspaceStore,
                tunnelManagerStore: tunnelManagerStore,
                rdpDesktopRuntimeStore: rdpDesktopRuntimeStore
            )
            #if !ENABLE_RDP_2
            terminalWorkspaceStore.revokeAllMCPControl()
            #endif
            syncTerminalMCPBridgeServer()
            showWelcomeGuideIfNeeded()
        }
        .onDisappear {
            #if !ENABLE_RDP_2
            terminalWorkspaceStore.revokeAllMCPControl()
            rdpDesktopRuntimeStore.stopAllImmediately()
            terminalMCPBridgeServer.stop()
            #endif
        }
        .onReceive(terminalWorkspaceStore.$navigationRequest.compactMap(\.self)) { request in
            selectedSessionID = request.sessionID
            selectedWorkspaceFeature = .command
        }
        .onReceive(NotificationCenter.default.publisher(for: .jtsRDPDesktopRequested)) { notification in
            navigateToRDPDesktop(from: notification)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            remoteClientGrantStore.reloadFromDiskIfChanged()
            RemoteCapabilityAuditStore.shared.reloadFromDiskIfChanged()
        }
        .onChange(of: sessions.map(\.persistentModelID)) { _, _ in
            reconcileSelectedSessionIfNeeded()
            #if ENABLE_RDP_2
            RDPDesktopWindowCoordinator.shared.reconcile(validTargetIDs: Set(sessions.map(\.targetID)))
            #endif
        }
        .onChange(of: selectedSession?.connectionType) { _, _ in
            reconcileWorkspaceFeatureForSelectedSession()
        }
        .onChange(of: selectedSession?.persistentModelID) { _, _ in
            reconcileWorkspaceFeatureForSelectedSession()
        }
        .onChange(of: isTerminalMCPBridgeEnabled) { _, _ in
            syncTerminalMCPBridgeServer()
        }
        .background(MainWindowGuard())
        .alert(
            persistenceNotice?.localizedTitle(language: appLanguage)
                ?? appLanguage.localized("Data store notice", "数据存储提示"),
            isPresented: Binding(
                get: { persistenceNotice != nil },
                set: { if !$0 { persistenceNotice = nil } }
            )
        ) {
            Button(appLanguage.localized("OK", "好"), role: .cancel) {
                persistenceNotice = nil
            }
        } message: {
            Text(persistenceNotice?.localizedMessage(language: appLanguage) ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { isShowingWelcomeGuide },
                set: { newValue in
                    if newValue {
                        isShowingWelcomeGuide = true
                    } else {
                        finishWelcomeGuide(openNewServer: false)
                    }
                }
            )
        ) {
            WelcomeGuideSheet(
                onClose: {
                    finishWelcomeGuide(openNewServer: false)
                },
                onAddServer: {
                    finishWelcomeGuide(openNewServer: true)
                }
            )
        }
        .sheet(isPresented: terminalBroadcastPresentationBinding) {
            TerminalBroadcastSheet(coordinator: terminalBroadcastCoordinator)
                .environment(\.appLanguage, appLanguage)
        }
        .alert(
            appLanguage.localized("New Group", "新建分组"),
            isPresented: $isShowingNewGroupPrompt
        ) {
            TextField(appLanguage.localized("Group name", "分组名称"), text: $pendingNewGroupName)
            Button(appLanguage.localized("Create", "创建")) {
                createPendingGroup()
            }
            Button(appLanguage.localized("Cancel", "取消"), role: .cancel) {
                pendingNewGroupName = ""
            }
        } message: {
            Text(appLanguage.localized(
                "Create a new server draft inside this group.",
                "创建一个属于此分组的新服务器草稿。"
            ))
        }
    }

    private var commandHandlers: JTSTerminalCommandHandlers {
        JTSTerminalCommandHandlers(
            newServer: addSession,
            showServerProperties: {
                if let selectedSession {
                    showProperties(for: selectedSession)
                }
            },
            openSelectedServer: {
                if let selectedSession, selectedSession.isConnectable {
                    openInteractive(for: selectedSession)
                }
            },
            showDesktop: {
                selectWorkspaceFeature(.desktop)
            },
            showTerminal: {
                selectWorkspaceFeature(.command)
            },
            showFiles: {
                selectWorkspaceFeature(.files)
            },
            showTunnels: {
                selectWorkspaceFeature(.tunnels)
            },
            showCredentials: {
                selectWorkspaceFeature(.credentials)
            },
            showProfiles: {
                selectWorkspaceFeature(.profiles)
            },
            availableWorkspaceFeatures: selectedSession.map {
                WorkspaceFeature.available(for: $0.connectionType)
            } ?? [],
            hasSelectedServer: selectedSession != nil,
            selectedServerOpenCommand: JTSTerminalServerOpenCommand.resolved(
                for: selectedSession?.connectionType
            ),
            canOpenSelectedServer: selectedSession?.isConnectable == true
        )
    }

    private func addSession() {
        addSession(folder: "")
    }

    private func addSession(folder: String) {
        guard canReplaceServerPropertiesWindow else {
            NSSound.beep()
            return
        }
        sidebarSearchText = ""
        let session = RemoteSession(folder: folder)
        modelContext.insert(session)
        try? modelContext.save()
        transientNewSessionID = session.persistentModelID
        showProperties(for: session, selectInMainWindow: false)
    }

    private func requestNewGroup() {
        pendingNewGroupName = SessionGroupName.unique(
            base: appLanguage.localized("New Group", "新建分组"),
            existing: sessions.map(\.folder)
        )
        isShowingNewGroupPrompt = true
    }

    private func createPendingGroup() {
        let folderName = SessionGroupName.unique(
            base: pendingNewGroupName,
            existing: sessions.map(\.folder)
        )
        pendingNewGroupName = ""
        addSession(folder: folderName)
    }

    private func showWelcomeGuideIfNeeded() {
        guard WelcomeGuidePolicy.shouldShow(
            hasSeenGuide: hasSeenWelcomeGuide,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }

        isShowingWelcomeGuide = true
    }

    private func finishWelcomeGuide(openNewServer: Bool) {
        hasSeenWelcomeGuide = true
        isShowingWelcomeGuide = false

        guard openNewServer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            addSession()
        }
    }

    private func syncTerminalMCPBridgeServer() {
        if TerminalMCPBridgeLaunchPolicy.shouldAutoStart(isUserEnabled: isTerminalMCPBridgeEnabled) {
            terminalMCPBridgeServer.start(
                terminalWorkspaceStore: terminalWorkspaceStore,
                modelContext: modelContext
            )
        } else {
            terminalMCPBridgeServer.stop()
        }
    }

    #if JTS_UI_TEST_SUPPORT
    private func seedUITestSessionIfNeeded() {
        guard !didSeedUITestSession else { return }
        didSeedUITestSession = true

        if ProcessInfo.processInfo.environment[
            UITestSSHSessionEnvironment.importedProfileFixtureKey
        ] != nil {
            do {
                let profiles = try UITestSSHSessionEnvironment.importedProfiles() ?? []
                let importedSessions = SessionProfileImporter.insert(
                    profiles,
                    into: modelContext
                )
                try modelContext.save()
                selectedSessionID = importedSessions.first?.persistentModelID
                #if ENABLE_RDP_2
                if let session = importedSessions.first {
                    _ = UITestRDPFixtureEnvironment.seedPendingGrantIfNeeded(
                        for: session
                    )
                }
                #endif
            } catch {
                preconditionFailure("Could not import the UI test profile fixture: \(error)")
            }
            return
        }

        guard let identity = UITestSSHSessionEnvironment.seededSession() else { return }
        // UI tests run in ModelContainerFactory's in-memory store. Always insert a
        // fresh, normalized profile so the smoke test cannot inherit an identity,
        // jump host, X11 preference, RDP payload, or other field from an older row.
        let session = UITestSSHSessionEnvironment.cleanSession(for: identity)
        modelContext.insert(session)
        try? modelContext.save()
        selectedSessionID = session.persistentModelID
    }
    #endif

    private func deleteSessions(_ sessionsToDelete: [RemoteSession]) {
        let deletedIDs = Set(sessionsToDelete.map(\.persistentModelID))
        // The properties window must not keep editing a deleted model.
        if let editingID = serverPropertiesSessionID, deletedIDs.contains(editingID) {
            guard closeServerPropertiesWindow(clearDetachedDraft: false) else {
                NSSound.beep()
                return
            }
        }
        if let transientNewSessionID, deletedIDs.contains(transientNewSessionID) {
            self.transientNewSessionID = nil
        }
        if let detachedDraftPropertiesSessionID, deletedIDs.contains(detachedDraftPropertiesSessionID) {
            self.detachedDraftPropertiesSessionID = nil
        }
        for session in sessionsToDelete {
            if selectedSessionID == session.persistentModelID {
                selectedSessionID = nil
            }
            terminalWorkspaceStore.removeWorkspace(for: session.persistentModelID)
            tunnelManagerStore.removeManager(for: session.persistentModelID)
            remoteFilesWorkspaceStore.removeWorkspace(for: session.persistentModelID)
            #if ENABLE_RDP_2
            ApplicationWorkspaceRuntime.shared.macDesktops.remove(for: session.persistentModelID)
            MacSystemScreenSharingStore.shared.remove(targetID: session.targetID)
            #endif
            modelContext.delete(session)
        }
        try? modelContext.save()
        reconcileSelectedSessionIfNeeded()
    }

    private var terminalBroadcastPresentationBinding: Binding<Bool> {
        Binding(
            get: { terminalBroadcastCoordinator.isPresented },
            set: { isPresented in
                if !isPresented {
                    terminalBroadcastCoordinator.close()
                }
            }
        )
    }

    private func showProperties(for session: RemoteSession, selectInMainWindow: Bool = true) {
        guard canReplaceServerPropertiesWindow else {
            NSSound.beep()
            return
        }
        if selectInMainWindow {
            detachedDraftPropertiesSessionID = nil
            selectedSessionID = session.persistentModelID
        } else {
            detachedDraftPropertiesSessionID = session.isConnectable ? nil : session.persistentModelID
            preserveUsableMainSelection(whileEditing: session)
        }
        openServerPropertiesWindow(for: session)
    }

    private var canReplaceServerPropertiesWindow: Bool {
        serverPropertiesWindowDelegate?.allowsClose ?? true
    }

    private func preserveUsableMainSelection(whileEditing session: RemoteSession) {
        selectedSessionID = SessionSelectionPolicy.mainSessionWhileEditingProperties(
            current: selectedSession,
            editing: session,
            sessions: sessions,
            excluding: detachedMainSelectionSessionID
        )?.persistentModelID
    }

    private func openInteractive(for session: RemoteSession) {
        selectedSessionID = session.persistentModelID
        if session.connectionType == .macDesktop {
            selectedWorkspaceFeature = .desktop
            return
        }
        if session.connectionType == .rdp {
            selectedWorkspaceFeature = .desktop
            #if ENABLE_RDP_2
            RDPDesktopWindowCoordinator.shared.open(session, openProperties: { showProperties(for: session) })
            #endif
            return
        }

        selectedWorkspaceFeature = .command

        guard let kind = TerminalWorkspaceState.Kind.preferredTerminalKind(for: session) else {
            return
        }

        terminalWorkspaceStore.ensureTabIfEmpty(
            for: session.persistentModelID,
            kind: kind
        )
    }

    private func selectSessionFromSidebar(_ session: RemoteSession) {
        guard session.isConnectable else {
            showProperties(for: session, selectInMainWindow: false)
            return
        }

        selectedSessionID = session.persistentModelID
        selectedWorkspaceFeature = WorkspaceFeature.resolvedSelection(
            selectedWorkspaceFeature,
            for: session.connectionType
        )
    }

    private func openTerminalFromSidebar(for session: RemoteSession) {
        guard session.isConnectable else {
            showProperties(for: session, selectInMainWindow: false)
            return
        }

        selectedSessionID = session.persistentModelID
        if session.connectionType == .macDesktop {
            selectedWorkspaceFeature = .desktop
            return
        }
        if session.connectionType == .rdp {
            selectedWorkspaceFeature = .desktop
            #if ENABLE_RDP_2
            RDPDesktopWindowCoordinator.shared.open(session, openProperties: { showProperties(for: session) })
            #endif
            return
        }

        selectedWorkspaceFeature = .command

        guard let kind = TerminalWorkspaceState.Kind.preferredTerminalKind(for: session) else {
            return
        }

        terminalWorkspaceStore.ensureTabIfEmpty(
            for: session.persistentModelID,
            kind: kind
        )
    }

    private func reconcileSelectedSessionIfNeeded() {
        let excludedSessionID = detachedMainSelectionSessionID
        let nextSession: RemoteSession?
        if let selectedSessionID,
           selectedSessionID != excludedSessionID,
           let session = sessions.first(where: { $0.persistentModelID == selectedSessionID }) {
            nextSession = SessionSelectionPolicy.usableMainSession(
                current: session,
                sessions: sessions,
                excluding: excludedSessionID
            )
        } else {
            nextSession = SessionSelectionPolicy.defaultSession(from: sessions, excluding: excludedSessionID)
        }

        if selectedSessionID == nextSession?.persistentModelID {
            return
        }

        selectedSessionID = nextSession?.persistentModelID
    }

    private func reconcileWorkspaceFeatureForSelectedSession() {
        guard let selectedSession else { return }
        selectedWorkspaceFeature = WorkspaceFeature.resolvedSelection(
            selectedWorkspaceFeature,
            for: selectedSession.connectionType
        )
    }

    private func selectWorkspaceFeature(_ feature: WorkspaceFeature) {
        guard let selectedSession,
              feature.isAvailable(for: selectedSession.connectionType) else {
            return
        }
        selectedWorkspaceFeature = feature
    }

    private func navigateToRDPDesktop(from notification: Notification) {
        guard AppReleasePolicy.includesNativeRDP else { return }
        guard let rawTargetID = notification.userInfo?["targetId"] as? String,
              let targetID = UUID(uuidString: rawTargetID),
              let session = sessions.first(where: { $0.targetID == targetID && $0.connectionType == .rdp }) else {
            return
        }
        if notification.userInfo?["activate"] as? Bool ?? true {
            selectedSessionID = session.persistentModelID
            selectedWorkspaceFeature = .desktop
        }
        #if ENABLE_RDP_2
        RDPDesktopWindowCoordinator.shared.open(session,
            activate: notification.userInfo?["activate"] as? Bool ?? true,
            openProperties: { showProperties(for: session) })
        #else
        NSApp.activate(ignoringOtherApps: true)
        MainWindowLifecycle.ensureMainWindowVisible()
        #endif
    }

    private func openServerPropertiesWindow(for session: RemoteSession) {
        guard closeServerPropertiesWindow(clearDetachedDraft: false) else {
            NSSound.beep()
            return
        }

        let closeGuard = ServerPropertiesWindowCloseGuard()
        let isTransientDraft = transientNewSessionID == session.persistentModelID
        let content = ServerPropertiesSheet(
            session: session,
            allSessions: sessions,
            closeGuard: closeGuard,
            close: closeServerPropertiesWindow,
            openInteractive: {
                closeServerPropertiesWindow()
                openInteractive(for: session)
            },
            deleteServer: isTransientDraft ? nil : {
                deleteSessions([session])
            }
        )
        .environment(\.modelContext, modelContext)
        .environment(\.appLanguage, appLanguage)
        .environment(\.locale, Locale(identifier: appLanguage.localeIdentifier))

        let controller = NSHostingController(rootView: content)
        let window = ServerPropertiesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let delegate = ServerPropertiesWindowDelegate(
            canClose: { closeGuard.canClose },
            onClose: {
                completeServerPropertiesWindowClose(clearDetachedDraft: true)
            }
        )
        window.title = appLanguage.localized("Server Properties", "服务器属性")
        window.identifier = NSUserInterfaceItemIdentifier("server-properties-window")
        window.contentViewController = controller
        window.cancelHandler = { [weak window] in
            window?.performClose(nil)
        }
        controller.view.setAccessibilityIdentifier("server-properties-content")
        window.minSize = NSSize(width: 540, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.center()

        serverPropertiesWindowDelegate = delegate
        serverPropertiesWindow = window
        serverPropertiesSessionID = session.persistentModelID

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeServerPropertiesWindow() {
        _ = closeServerPropertiesWindow(clearDetachedDraft: true)
    }

    @discardableResult
    private func closeServerPropertiesWindow(
        clearDetachedDraft: Bool
    ) -> Bool {
        guard serverPropertiesWindowDelegate?.allowsClose ?? true else {
            return false
        }
        let window = serverPropertiesWindow
        window?.delegate = nil
        completeServerPropertiesWindowClose(
            clearDetachedDraft: clearDetachedDraft
        )
        window?.close()
        return true
    }

    private func completeServerPropertiesWindowClose(
        clearDetachedDraft: Bool
    ) {
        serverPropertiesWindow = nil
        serverPropertiesWindowDelegate = nil
        serverPropertiesSessionID = nil
        guard clearDetachedDraft else { return }

        discardTransientNewSessionIfNeeded()
        detachedDraftPropertiesSessionID = nil
        transientNewSessionID = nil
        reconcileSelectedSessionIfNeeded()
    }

    private func discardTransientNewSessionIfNeeded() {
        guard let transientNewSessionID,
              let session = sessions.first(where: { $0.persistentModelID == transientNewSessionID }),
              ServerPropertiesCancellationPolicy.shouldDiscardTransientNewSession(
                session,
                transientNewSessionID: transientNewSessionID
              ) else {
            return
        }

        if selectedSessionID == transientNewSessionID {
            selectedSessionID = nil
        }
        modelContext.delete(session)
        try? modelContext.save()
    }
}

enum WelcomeGuidePolicy {
    static let storageKey = "hasSeenWelcomeGuide.v1"

    static func shouldShow(hasSeenGuide: Bool, environment: [String: String]) -> Bool {
        guard !hasSeenGuide else { return false }
        #if JTS_UI_TEST_SUPPORT
        return environment["JTS_TERMINAL_UI_TESTING"] != "1"
        #else
        return true
        #endif
    }
}

enum SessionGroupName {
    static func unique(base: String, existing: [String]) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedBase.nilIfBlank ?? "New Group"
        let used = Set(
            existing
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        guard used.contains(candidate) else { return candidate }

        var index = 2
        while used.contains("\(candidate) \(index)") {
            index += 1
        }
        return "\(candidate) \(index)"
    }
}

enum SessionSelectionPolicy {
    static func defaultSession(
        from sessions: [RemoteSession],
        excluding excludedSessionID: PersistentIdentifier? = nil
    ) -> RemoteSession? {
        let candidates = candidates(from: sessions, excluding: excludedSessionID)
        return candidates.first(where: \.isConnectable) ?? candidates.first
    }

    static func usableMainSession(
        current: RemoteSession?,
        sessions: [RemoteSession],
        excluding excludedSessionID: PersistentIdentifier? = nil
    ) -> RemoteSession? {
        guard let current else {
            return defaultSession(from: sessions, excluding: excludedSessionID)
        }

        guard current.persistentModelID != excludedSessionID else {
            return defaultSession(from: sessions, excluding: excludedSessionID)
        }

        let candidates = candidates(from: sessions, excluding: excludedSessionID)
        guard current.isConnectable || !candidates.contains(where: \.isConnectable) else {
            return defaultSession(from: sessions, excluding: excludedSessionID)
        }

        return current
    }

    static func mainSessionWhileEditingProperties(
        current: RemoteSession?,
        editing: RemoteSession,
        sessions: [RemoteSession],
        excluding excludedSessionID: PersistentIdentifier? = nil
    ) -> RemoteSession? {
        guard let current else {
            return defaultSession(from: sessions, excluding: excludedSessionID)
        }

        guard current.persistentModelID == editing.persistentModelID,
              !current.isConnectable else {
            return current
        }

        let fallbackExclusion = excludedSessionID ?? editing.persistentModelID
        return defaultSession(from: sessions, excluding: fallbackExclusion) ?? current
    }

    private static func candidates(
        from sessions: [RemoteSession],
        excluding excludedSessionID: PersistentIdentifier?
    ) -> [RemoteSession] {
        guard let excludedSessionID else { return sessions }
        return sessions.filter { $0.persistentModelID != excludedSessionID }
    }
}

enum ServerPropertiesCancellationPolicy {
    static func shouldDiscardTransientNewSession(
        _ session: RemoteSession,
        transientNewSessionID: PersistentIdentifier?
    ) -> Bool {
        transientNewSessionID == session.persistentModelID && !session.isConnectable
    }
}

enum ServerPropertiesWindowClosePolicy {
    static func canClose(credentialOperationIsRunning: Bool) -> Bool {
        !credentialOperationIsRunning
    }
}

@MainActor
private final class ServerPropertiesWindowCloseGuard {
    var credentialOperationIsRunning = false

    var canClose: Bool {
        ServerPropertiesWindowClosePolicy.canClose(
            credentialOperationIsRunning: credentialOperationIsRunning
        )
    }
}

private final class ServerPropertiesWindow: NSWindow {
    var cancelHandler: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}

private final class ServerPropertiesWindowDelegate: NSObject, NSWindowDelegate {
    private let canClose: () -> Bool
    private let onClose: () -> Void

    init(
        canClose: @escaping () -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.canClose = canClose
        self.onClose = onClose
    }

    var allowsClose: Bool {
        canClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        allowsClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct WelcomeGuideItem: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let message: String

    static var primarySteps: [WelcomeGuideItem] {
        primarySteps(language: .defaultLanguage)
    }

    static func primarySteps(language: AppLanguage) -> [WelcomeGuideItem] {
        [
            WelcomeGuideItem(
                id: "connections",
                symbol: "server.rack",
                title: language.localized("Choose a connection", "选择连接方式"),
                message: language.localized(
                    "Create an SSH profile with a key file, the macOS ssh-agent, or an encrypted local password; a Local Shell profile needs no remote host; or add a Windows RDP profile.",
                    "可创建使用私钥文件、macOS 自带 ssh-agent 或本地加密密码的 SSH 配置；本地 Shell 无需远程主机；也可以添加 Windows RDP 配置。"
                )
            ),
            WelcomeGuideItem(
                id: "workspace",
                symbol: "rectangle.3.group",
                title: language.localized("Use the matching workspace", "使用匹配的工作区"),
                message: language.localized(
                    "SSH provides Terminal, Files, Tunnels, Password, and profile import/export. Local Shell provides Terminal and profile import/export. Windows RDP provides Desktop and profile import/export.",
                    "SSH 提供终端、文件、隧道、密码和配置导入导出；本地 Shell 提供终端和配置导入导出；Windows RDP 提供桌面和配置导入导出。"
                )
            ),
            WelcomeGuideItem(
                id: "rdp-trust",
                symbol: "checkmark.shield",
                title: language.localized("Verify Windows desktop trust", "验证 Windows 桌面信任"),
                message: language.localized(
                    "Windows RDP asks you to review its certificate before first trust and blocks unexpected certificate changes. Pairing the Windows Companion is optional and only adds structured Windows automation.",
                    "Windows RDP 会在首次信任前要求检查证书，并阻止意外的证书变更。Windows Companion 为可选配对，仅用于增加结构化 Windows 自动化能力。"
                )
            )
        ]
    }

    static var mcpSteps: [WelcomeGuideItem] {
        mcpSteps(language: .defaultLanguage)
    }

    static func mcpSteps(language: AppLanguage) -> [WelcomeGuideItem] {
        [
            WelcomeGuideItem(
                id: "mcp-enable",
                symbol: "checkmark.shield",
                title: language.localized("Explicitly allow MCP", "显式允许 MCP"),
                message: language.localized(
                    "Open AI / MCP Access in Server Properties. Only profiles you enable are exposed to MCP tools.",
                    "打开服务器属性里的 AI / MCP 访问，只对你启用的配置暴露 MCP 工具。"
                )
            ),
            WelcomeGuideItem(
                id: "mcp-register",
                symbol: "puzzlepiece.extension",
                title: language.localized("Configure clients", "自动配置客户端"),
                message: language.localized(
                    "Use the top-level MCP menu for Claude Desktop or CLI, Cursor, Codex Desktop or CLI, Grok CLI, and Antigravity. JTS Terminal finds the canonical endpoint, determines its state, and configures it without asking for a filename or path.",
                    "从顶部 MCP 菜单配置 Claude Desktop 或 CLI、Cursor、Codex Desktop 或 CLI、Grok CLI，以及 Antigravity。JTS Terminal 会自动定位标准端点、判断当前状态，无需填写文件名或路径。"
                )
            ),
            WelcomeGuideItem(
                id: "mcp-trust",
                symbol: "exclamationmark.shield",
                title: language.localized("Understand trust boundaries", "理解信任边界"),
                message: language.localized(
                    "MCP calls are trusted automation: there is no per-command confirmation, but allowlist, timeout, output limit, and audit logging still apply.",
                    "MCP 调用是受信任自动化：不会逐条弹确认框，但会受白名单、超时、输出限制和审计记录约束。"
                )
            )
        ]
    }
}

private struct WelcomeGuideSheet: View {
    @Environment(\.appLanguage) private var language
    let onClose: () -> Void
    let onAddServer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIconMark(size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(language.localized("Welcome to JTS Terminal", "欢迎使用 JTS Terminal"))
                        .font(.title2.weight(.semibold))
                    Text(language.localized(
                        "Set up SSH, Local Shell, or Windows RDP and use only the workspaces supported by that connection.",
                        "设置 SSH、本地 Shell 或 Windows RDP，并使用该连接支持的工作区。"
                    ))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(language.localized("Daily Use", "日常使用"))
                    .font(.headline)
                ForEach(WelcomeGuideItem.primarySteps(language: language)) { item in
                    WelcomeGuideRow(item: item)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(language.localized("MCP Access", "MCP 接入"))
                    .font(.headline)
                ForEach(WelcomeGuideItem.mcpSteps(language: language)) { item in
                    WelcomeGuideRow(item: item)
                }
            }

            HStack {
                Button(language.localized("Later", "稍后")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(language.localized("Add First Server", "添加第一台服务器")) {
                    onAddServer()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 660)
    }
}

private struct WelcomeGuideRow: View {
    let item: WelcomeGuideItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Text(item.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum MainWindowSizePolicy {
    static let minimumContentSize = CGSize(width: 900, height: 600)
    static let preferredContentSize = CGSize(width: 1320, height: 820)
    private static let screenPadding: CGFloat = 24
    private static let frameTolerance: CGFloat = 2

    @MainActor
    static func apply(to window: NSWindow) {
        window.contentMinSize = minimumContentSize
        window.minSize = minimumFrameSize(for: window)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        snapToFixedFrameIfNeeded(window)
        #if ENABLE_RDP_2 && JTS_UI_TEST_SUPPORT
        if UITestRDPFixtureEnvironment.requestsNarrowWindow() {
            window.setContentSize(minimumContentSize)
        }
        #endif
    }

    @MainActor
    static func minimumFrameSize(for window: NSWindow) -> CGSize {
        window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
    }

    @MainActor
    static func fixedFrameSize(for window: NSWindow) -> CGSize {
        window.frameRect(forContentRect: NSRect(origin: .zero, size: preferredContentSize)).size
    }

    @MainActor
    static func clampedFrameSize(_ proposedSize: CGSize, for window: NSWindow) -> CGSize {
        guard !window.styleMask.contains(.fullScreen) else { return proposedSize }
        let minimumSize = minimumFrameSize(for: window)
        return boundedFrameSize(
            proposedSize,
            minimumSize: minimumSize,
            maximumSize: window.screen?.visibleFrame.size
        )
    }

    static func boundedFrameSize(
        _ proposedSize: CGSize,
        minimumSize: CGSize,
        maximumSize: CGSize?
    ) -> CGSize {
        let maximumWidth = max(maximumSize?.width ?? proposedSize.width, minimumSize.width)
        let maximumHeight = max(maximumSize?.height ?? proposedSize.height, minimumSize.height)
        return CGSize(
            width: min(max(proposedSize.width, minimumSize.width), maximumWidth),
            height: min(max(proposedSize.height, minimumSize.height), maximumHeight)
        )
    }

    static func shouldGrow(contentSize: CGSize) -> Bool {
        contentSize.width < minimumContentSize.width || contentSize.height < minimumContentSize.height
    }

    @MainActor
    static func standardFrame(for window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard let visibleFrame = window.screen?.visibleFrame else {
            return defaultFrame
        }

        return visibleFrame
    }

    @MainActor
    static func snapToFixedFrameIfNeeded(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        if shouldGrow(contentSize: contentSize(for: window)) {
            setFixedFrame(for: window)
            return
        }
        constrainOversizedFrameIfNeeded(window)
    }

    @MainActor
    static func contentSize(for window: NSWindow) -> CGSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    @MainActor
    private static func constrainOversizedFrameIfNeeded(_ window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let boundedSize = boundedFrameSize(
            window.frame.size,
            minimumSize: minimumFrameSize(for: window),
            maximumSize: visibleFrame.size
        )
        guard !approximately(window.frame.size, matches: boundedSize) else { return }

        // SwiftUI may re-evaluate a representable's content minimum when the
        // first RDP frame arrives. Restore the product-level minimum before
        // shrinking any content-driven oversize frame back onto the display.
        window.contentMinSize = minimumContentSize
        window.minSize = minimumFrameSize(for: window)

        var targetFrame = window.frame
        targetFrame.origin.y = targetFrame.maxY - boundedSize.height
        targetFrame.size = boundedSize
        targetFrame = constrainedFrame(targetFrame, toVisibleFrame: visibleFrame)
        window.setFrame(targetFrame, display: true, animate: false)
    }

    @MainActor
    static func setFixedFrame(for window: NSWindow) {
        var targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: preferredContentSize))
        targetFrame.origin.x = window.frame.origin.x
        targetFrame.origin.y = window.frame.maxY - targetFrame.height

        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            targetFrame = constrainedFrame(targetFrame, toVisibleFrame: visibleFrame)
        }

        window.setFrame(targetFrame, display: true, animate: false)
    }

    @MainActor
    static func allowsFrameSize(_ size: CGSize, for window: NSWindow) -> Bool {
        guard !window.styleMask.contains(.fullScreen) else { return true }
        let minimumSize = minimumFrameSize(for: window)
        return size.width + frameTolerance >= minimumSize.width &&
            size.height + frameTolerance >= minimumSize.height
    }

    static func approximately(_ size: CGSize, matches target: CGSize) -> Bool {
        abs(size.width - target.width) <= frameTolerance &&
            abs(size.height - target.height) <= frameTolerance
    }

    static func constrainedFrame(_ frame: NSRect, toVisibleFrame visibleFrame: NSRect) -> NSRect {
        var constrainedFrame = frame
        let minX = visibleFrame.minX + screenPadding
        let maxX = visibleFrame.maxX - screenPadding
        let minY = visibleFrame.minY + screenPadding
        let maxY = visibleFrame.maxY - screenPadding

        if constrainedFrame.width <= visibleFrame.width - screenPadding * 2 {
            if constrainedFrame.maxX > maxX {
                constrainedFrame.origin.x = maxX - constrainedFrame.width
            }
            if constrainedFrame.minX < minX {
                constrainedFrame.origin.x = minX
            }
        } else {
            constrainedFrame.origin.x = visibleFrame.minX
        }

        if constrainedFrame.height <= visibleFrame.height - screenPadding * 2 {
            if constrainedFrame.maxY > maxY {
                constrainedFrame.origin.y = maxY - constrainedFrame.height
            }
            if constrainedFrame.minY < minY {
                constrainedFrame.origin.y = minY
            }
        } else {
            constrainedFrame.origin.y = visibleFrame.minY
        }

        return constrainedFrame
    }
}

private struct MainWindowGuard: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attachWhenReady(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attachWhenReady(from: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private var isClosingAfterConfirmation = false
        private var isInFullScreenTransition = false

        func attachWhenReady(from view: NSView) {
            guard let window = view.window else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let view else { return }
                    self?.attachWhenReady(from: view)
                }
                return
            }

            guard self.window !== window else { return }
            self.window = window
            window.delegate = self
            MainWindowLifecycle.configure(window)
            MainWindowSizePolicy.apply(to: window)
            DispatchQueue.main.async {
                if !JTSBackgroundLaunchPolicy.isBackgroundLaunch { MainWindowLifecycle.ensureMainWindowVisible() }
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !isClosingAfterConfirmation else { return true }
            #if ENABLE_RDP_2
            if RDPDesktopWindowCoordinator.shared.hasWindows {
                sender.orderOut(nil)
                return false
            }
            #endif
            guard RemoteProcessShutdownGuard.shared.confirmClose(kind: .window) else {
                return false
            }

            isClosingAfterConfirmation = true
            return true
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            guard !isInFullScreenTransition else { return frameSize }
            return MainWindowSizePolicy.clampedFrameSize(frameSize, for: sender)
        }

        func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
            MainWindowSizePolicy.standardFrame(for: window, defaultFrame: newFrame)
        }

        func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
            true
        }

        func windowDidResize(_ notification: Notification) {
            guard !isInFullScreenTransition,
                  let window = notification.object as? NSWindow else {
                return
            }

            MainWindowSizePolicy.snapToFixedFrameIfNeeded(window)
        }

        func windowWillEnterFullScreen(_ notification: Notification) {
            isInFullScreenTransition = true
            guard let window = notification.object as? NSWindow else { return }
            MainWindowLifecycle.fullScreenTransitionWillBegin(for: window)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            isInFullScreenTransition = false
            guard let window = notification.object as? NSWindow else { return }
            MainWindowLifecycle.fullScreenTransitionDidEnd(for: window)
        }

        func windowDidFailToEnterFullScreen(_ window: NSWindow) {
            isInFullScreenTransition = false
            MainWindowLifecycle.fullScreenTransitionDidFail(for: window)
        }

        func windowWillExitFullScreen(_ notification: Notification) {
            isInFullScreenTransition = true
            guard let window = notification.object as? NSWindow else { return }
            MainWindowLifecycle.fullScreenTransitionWillBegin(for: window)
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            isInFullScreenTransition = false
            guard let window = notification.object as? NSWindow else { return }
            MainWindowLifecycle.fullScreenTransitionDidEnd(for: window)
            MainWindowSizePolicy.snapToFixedFrameIfNeeded(window)
        }

        func windowDidFailToExitFullScreen(_ window: NSWindow) {
            isInFullScreenTransition = false
            MainWindowLifecycle.fullScreenTransitionDidFail(for: window)
        }

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            MainWindowLifecycle.fullScreenTransitionDidEnd(for: window)
        }
    }
}

enum WorkspaceFeature: String, CaseIterable, Identifiable {
    case desktop
    case command
    case files
    case tunnels
    case credentials
    case profiles

    var id: String { rawValue }

    var isIncludedInCurrentRelease: Bool {
        switch self {
        case .desktop:
            return AppReleasePolicy.includesNativeRDP
        case .command, .files, .tunnels, .credentials, .profiles:
            return true
        }
    }

    static var selectableCases: [WorkspaceFeature] {
        allCases.filter(\.isIncludedInCurrentRelease)
    }

    static func available(for connectionType: RemoteConnectionType) -> [WorkspaceFeature] {
        let supportedFeatures: [WorkspaceFeature]
        switch connectionType {
        case .ssh:
            supportedFeatures = [.command, .files, .tunnels, .credentials, .profiles]
        case .localShell:
            supportedFeatures = [.command, .profiles]
        case .macDesktop:
            supportedFeatures = [.desktop, .profiles]
        case .rdp:
            supportedFeatures = [.desktop, .profiles]
        }
        return supportedFeatures.filter(\.isIncludedInCurrentRelease)
    }

    static func defaultFeature(for connectionType: RemoteConnectionType) -> WorkspaceFeature {
        available(for: connectionType).first ?? .profiles
    }

    static func resolvedSelection(
        _ selection: WorkspaceFeature,
        for connectionType: RemoteConnectionType
    ) -> WorkspaceFeature {
        selection.isAvailable(for: connectionType)
            ? selection
            : defaultFeature(for: connectionType)
    }

    func isAvailable(for connectionType: RemoteConnectionType) -> Bool {
        Self.available(for: connectionType).contains(self)
    }

    var title: String {
        title(language: AppLanguage.defaultLanguage)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .desktop:
            return language.localized("Desktop", "桌面")
        case .command:
            return language.localized("Terminal", "终端")
        case .files:
            return language.localized("Files", "文件")
        case .tunnels:
            return language.localized("Tunnels", "隧道")
        case .credentials:
            return language.localized("Password", "密码")
        case .profiles:
            return language.localized("Import / Export", "导入导出")
        }
    }

    var toolbarHelp: String {
        title
    }

    func toolbarHelp(language: AppLanguage) -> String {
        title(language: language)
    }

    var subtitle: String {
        subtitle(language: AppLanguage.defaultLanguage)
    }

    func subtitle(language: AppLanguage) -> String {
        switch self {
        case .desktop:
            #if ENABLE_RDP_2
            return language.localized(
                "View and control a Windows desktop over the native RDP connection.",
                "通过原生 RDP 连接查看和控制 Windows 桌面"
            )
            #else
            return language.localized(
                "This workspace is not included in the current App Store build.",
                "当前 App Store 构建不包含此工作区。"
            )
            #endif
        case .command:
            return language.localized(
                "Enter a persistent SSH session and work interactively.",
                "进入持续 SSH 会话，像终端一样交互操作"
            )
        case .files:
            return language.localized(
                "Browse remote directories, upload, download, edit, and sync files.",
                "浏览远程目录，并在工具栏或右键菜单中上传、下载、编辑和同步"
            )
        case .tunnels:
            return language.localized(
                "Manage local, remote, and SOCKS SSH tunnels.",
                "管理 SSH 本地、远程和 SOCKS 隧道"
            )
        case .credentials:
            return language.localized(
                "Save and check encrypted local SSH passwords.",
                "保存和检查本地加密 SSH 密码"
            )
        case .profiles:
            return language.localized(
                "Move session profiles without exporting keys or passwords.",
                "迁移会话配置，不导出密钥或密码"
            )
        }
    }

    var symbol: String {
        switch self {
        case .desktop:
            return "desktopcomputer"
        case .command:
            return "terminal"
        case .files:
            return "folder"
        case .tunnels:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .credentials:
            return "key"
        case .profiles:
            return "square.and.arrow.up.on.square"
        }
    }
}

/// The window toolbar's workspace switcher: a standard segmented control,
/// shown only when the selected connection offers more than one workspace.
private struct WorkspaceFeaturePicker: View {
    @Binding var selection: WorkspaceFeature
    let connectionType: RemoteConnectionType
    let language: AppLanguage

    var body: some View {
        let features = WorkspaceFeature.available(for: connectionType)
        if features.count > 1 {
            Picker(language.localized("Workspace", "工作区"), selection: resolvedSelection) {
                ForEach(features) { feature in
                    Text(feature.title(language: language))
                        .tag(feature)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("workspace-feature-toolbar-picker")
        }
    }

    private var resolvedSelection: Binding<WorkspaceFeature> {
        Binding(
            get: { WorkspaceFeature.resolvedSelection(selection, for: connectionType) },
            set: { selection = $0 }
        )
    }
}

enum RemoteGrantManagementEntryPolicy {
    static func isVisible(
        for _: RemoteConnectionType,
        mcpEnabled _: Bool
    ) -> Bool {
        true
    }
}

struct RDPDesktopFeatureContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        #if ENABLE_RDP_2
        expandedContent
            .background {
                RDPDesktopLayoutMarker(
                    identifier: RDPDesktopLayoutIdentifiers.featureContainer
                )
            }
        #else
        expandedContent
        #endif
    }

    private var expandedContent: some View {
        content
            .frame(
                minWidth: 0,
                maxWidth: .infinity,
                minHeight: 0,
                maxHeight: .infinity,
                alignment: .topLeading
            )
    }
}

private struct RemoteWorkspace: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appLanguage) private var language
    @Bindable var session: RemoteSession
    let sessions: [RemoteSession]
    @Binding var selectedFeature: WorkspaceFeature
    @ObservedObject var terminalWorkspaceStore: TerminalWorkspaceStore
    @ObservedObject var terminalBroadcastCoordinator: TerminalBroadcastCoordinator
    @ObservedObject var tunnelManagerStore: SSHTunnelManagerStore
    @ObservedObject var remoteFilesWorkspaceStore: RemoteFilesWorkspaceStore
    @ObservedObject var transferQueueManager: RemoteTransferQueueManager
    @ObservedObject var rdpDesktopRuntimeStore: RDPDesktopRuntimeStore
    let openServerProperties: () -> Void

    var body: some View {
        selectedFeatureContainer
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-workspace-content")
        .onAppear(perform: reconcileSelectedFeature)
        .onChange(of: session.connectionType) { _, _ in
            reconcileSelectedFeature()
        }
        .onChange(of: selectedFeature) { _, _ in
            reconcileSelectedFeature()
        }
    }

    private var effectiveSelectedFeature: WorkspaceFeature {
        WorkspaceFeature.resolvedSelection(
            selectedFeature,
            for: session.connectionType
        )
    }

    @ViewBuilder
    private var selectedFeatureContainer: some View {
        switch effectiveSelectedFeature {
        case .desktop, .command:
            selectedFeatureView
                .padding(8)
                .controlSize(.small)
        case .files:
            selectedFeatureView
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .controlSize(.small)
        case .tunnels, .credentials, .profiles:
            ScrollView {
                selectedFeatureView
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var selectedFeatureView: some View {
        let feature = effectiveSelectedFeature
        VStack(alignment: .leading, spacing: feature == .desktop || feature == .command || feature == .files ? 0 : 14) {
            switch feature {
            case .desktop:
                if session.connectionType == .macDesktop {
                    #if ENABLE_RDP_2
                    MacDesktopIntegratedPanel(session: session)
                    #endif
                } else if session.connectionType == .rdp {
                    #if ENABLE_RDP_2
                    RDPDesktopLauncher(target: session, openProperties: openServerProperties)
                    #else
                    RDPDesktopFeatureContainer {
                        RDPDesktopWorkspace(
                            session: session,
                            presentation: rdpDesktopRuntimeStore.presentation(for: session),
                            openServerProperties: openServerProperties
                        )
                    }
                    #endif
                } else {
                    UnsupportedConnectionFeaturePrompt(
                        feature: feature,
                        connectionType: session.connectionType
                    )
                }
            case .command:
                if session.connectionType == .rdp {
                    UnsupportedConnectionFeaturePrompt(
                        feature: selectedFeature,
                        connectionType: session.connectionType
                    )
                } else if session.isConnectable {
                    let initialKind = TerminalWorkspaceState.Kind.preferredTerminalKind(for: session) ?? .ssh
                    EmbeddedSSHPanel(
                        session: session,
                        title: session.connectionType == .ssh
                            ? language.localized("Interactive SSH", "交互式 SSH")
                            : language.localized("Local Shell", "本地 Shell"),
                        initialKind: initialKind,
                        terminalWorkspace: terminalWorkspaceStore.workspace(
                            for: session.persistentModelID,
                            initialKind: initialKind
                        ),
                        sessions: sessions,
                        terminalWorkspaceStore: terminalWorkspaceStore,
                        terminalBroadcastCoordinator: terminalBroadcastCoordinator,
                        autoStart: shouldAutoStartSSH(for: session)
                    )
                } else {
                    ConfigureServerPrompt(openServerProperties: openServerProperties)
                }
            case .files:
                if session.connectionType == .ssh {
                    RemoteFilesPanel(
                        session: session,
                        workspace: remoteFilesWorkspaceStore.workspace(for: session.persistentModelID),
                        transferQueueManager: transferQueueManager,
                        openServerProperties: openServerProperties
                    )
                } else {
                    UnsupportedConnectionFeaturePrompt(
                        feature: feature,
                        connectionType: session.connectionType
                    )
                }
            case .tunnels:
                if session.connectionType == .ssh {
                    TunnelPanel(
                        session: session,
                        manager: tunnelManagerStore.manager(for: session.persistentModelID)
                    )
                } else {
                    UnsupportedConnectionFeaturePrompt(
                        feature: feature,
                        connectionType: session.connectionType
                    )
                }
            case .credentials:
                if session.connectionType == .ssh {
                    PasswordPanel(session: session)
                } else {
                    UnsupportedConnectionFeaturePrompt(
                        feature: feature,
                        connectionType: session.connectionType
                    )
                }
            case .profiles:
                ProfilePortabilityPanel(
                    session: session,
                    sessions: sessions,
                    importProfiles: importProfiles
                )
            }
        }
        .frame(
            maxHeight: feature == .desktop || feature == .command || feature == .files ? .infinity : nil,
            alignment: .topLeading
        )
    }

    private func reconcileSelectedFeature() {
        let resolved = effectiveSelectedFeature
        guard selectedFeature != resolved else { return }
        selectedFeature = resolved
    }

    private func importProfiles(_ profiles: [RemoteSessionProfile]) {
        SessionProfileImporter.insert(profiles, into: modelContext)
    }

    private func shouldAutoStartSSH(for session: RemoteSession) -> Bool {
        #if JTS_UI_TEST_SUPPORT
        return !UITestSSHSessionEnvironment.suppressesAutoStart(
            forHost: session.host,
            username: session.username
        )
        #else
        return true
        #endif
    }
}

struct ConfigureServerPrompt: View {
    @Environment(\.appLanguage) private var language
    let openServerProperties: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(language.localized("Finish Setting Up", "先完成配置"), systemImage: "slider.horizontal.3")
        } description: {
            Text(language.localized(
                "Add the connection details before opening a terminal or desktop.",
                "填写连接信息后才能打开终端或桌面。"
            ))
        } actions: {
            Button(language.localized("Open Server Properties", "打开服务器属性")) {
                openServerProperties()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("configure-server-button")
        }
    }
}

private struct UnsupportedConnectionFeaturePrompt: View {
    @Environment(\.appLanguage) private var language
    let feature: WorkspaceFeature
    let connectionType: RemoteConnectionType

    var body: some View {
        ContentUnavailableView {
            Label(promptTitle, systemImage: feature.symbol)
        } description: {
            Text(promptMessage)
        }
    }

    private var promptTitle: String {
        if feature == .desktop {
            #if ENABLE_RDP_2
            return language.localized("Windows Desktop Feature", "Windows 桌面功能")
            #else
            return language.localized("Feature Not Available", "此功能不可用")
            #endif
        }
        return language.localized("Feature Not Available", "此功能不可用")
    }

    private var promptMessage: String {
        if feature == .desktop {
            #if ENABLE_RDP_2
            return language.localized(
                "Desktop is available for Windows RDP profiles. Select an RDP node or change this profile's connection type in Server Properties.",
                "桌面工作区适用于 Windows RDP 配置。请选择 RDP 节点，或在服务器属性中更改此配置的连接类型。"
            )
            #else
            return language.localized(
                "This workspace is not included in the current App Store build.",
                "当前 App Store 构建不包含此工作区。"
            )
            #endif
        }

        if connectionType == .rdp {
            #if ENABLE_RDP_2
            return language.localized(
                "\(feature.title(language: language)) is not a native RDP workspace in this version. Use Desktop for visual RDP access. Structured Windows commands, files, and tasks are exposed through MCP only when a compatible paired Companion is ready.",
                "当前版本不为 RDP 提供原生的“\(feature.title(language: language))”工作区。请使用“桌面”进行可视化 RDP 访问；只有兼容且已配对的 Companion 就绪时，MCP 才会提供结构化 Windows 命令、文件和任务能力。"
            )
            #else
            return language.localized(
                "This saved connection type is not supported by the current App Store build.",
                "当前 App Store 构建不支持此已保存连接类型。"
            )
            #endif
        }

        return language.localized(
            "\(feature.title(language: language)) is available for SSH profiles. \(connectionType.displayName(language: language)) profiles use their supported workspace and MCP capabilities.",
            "\(feature.title(language: language)) 仅适用于 SSH 配置。\(connectionType.displayName(language: language)) 配置使用其支持的工作区和 MCP 能力。"
        )
    }
}

private struct ServerPropertiesDraft: Equatable {
    var name: String
    var host: String
    var username: String
    var port: Int
    var connectionType: RemoteConnectionType
    var identityFile: String
    var jumpHost: String
    var folder: String
    var enableX11Forwarding: Bool
    var remotePath: String
    var rdpDomain: String
    var rdpDesktopWidth: Int
    var rdpDesktopHeight: Int
    var rdpCertificateTrustMode: RDPCertificateTrustMode
    var rdpPinnedCertificateSHA256: String
    var rdpClipboardEnabled: Bool
    var rdpCompanionPolicy: RDPCompanionPolicy
    var rdpPersistentMCPControlEnabled: Bool
    var rdpPermissionPolicy: RemoteTargetPermissionPolicy
    var mcpEnabled: Bool
    var mcpAlwaysAllowTerminalControl: Bool
    var mcpAlias: String

    init(session: RemoteSession) {
        name = session.name
        host = session.host
        username = session.username
        port = session.port
        connectionType = session.connectionType
        identityFile = session.identityFile
        jumpHost = session.jumpHost
        folder = session.folder
        enableX11Forwarding = session.enableX11Forwarding
        remotePath = session.remotePath
        let rdpProfile = session.rdpProfile
        rdpDomain = rdpProfile.domain
        rdpDesktopWidth = rdpProfile.desktopWidth
        rdpDesktopHeight = rdpProfile.desktopHeight
        rdpCertificateTrustMode = rdpProfile.certificateTrustMode
        rdpPinnedCertificateSHA256 = rdpProfile.pinnedCertificateSHA256 ?? ""
        rdpClipboardEnabled = rdpProfile.clipboardEnabled
        rdpCompanionPolicy = rdpProfile.companionPolicy
        rdpPersistentMCPControlEnabled = rdpProfile.persistentMCPControlEnabled
        rdpPermissionPolicy = rdpProfile.permissionPolicy
        mcpEnabled = session.mcpEnabled
        mcpAlwaysAllowTerminalControl = session.mcpAlwaysAllowTerminalControl
        mcpAlias = session.mcpAlias
    }

    var isConnectable: Bool {
        switch connectionType {
        case .ssh:
            return SSHConnectionIdentity(username: username, host: host).isValidForSSHCommand
                && (1...65_535).contains(port)
        case .localShell:
            return true
        case .macDesktop:
            return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65_535).contains(port)
        case .rdp:
            let hasHost = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasUsername = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasValidPin = rdpCertificateTrustMode != .pinnedOnly ||
                RDPConnectionProfile.normalizedFingerprint(rdpPinnedCertificateSHA256) != nil
            let hasValidDesktopSize = (640...7_680).contains(rdpDesktopWidth) &&
                (480...4_320).contains(rdpDesktopHeight)
            return hasHost && hasUsername && port > 0 && port <= 65_535 && hasValidPin && hasValidDesktopSize
        }
    }

    var address: String {
        address(language: .defaultLanguage)
    }

    func address(language: AppLanguage) -> String {
        switch connectionType {
        case .ssh:
            guard !host.isBlank else { return language.localized("Host not configured", "未配置主机") }
            return "\(username)@\(host):\(port)"
        case .localShell:
            return language.localized("Local shell", "本地 Shell")
        case .macDesktop:
            return "\(host):\(port)"
        case .rdp:
            guard !host.isBlank else { return language.localized("Host not configured", "未配置主机") }
            let trimmedDomain = rdpDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            let qualifiedUser = trimmedDomain.isEmpty ? username : "\(trimmedDomain)\\\(username)"
            return "\(qualifiedUser)@\(host):\(port)"
        }
    }

    var credentialAccount: String {
        switch connectionType {
        case .ssh:
            return "\(username.trimmingCharacters(in: .whitespacesAndNewlines))@\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"
        case .localShell:
            return "local-shell"
        case .macDesktop:
            return "mac-desktop:\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"
        case .rdp:
            let trimmedDomain = rdpDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            let qualifiedUser = trimmedDomain.isEmpty ? username : "\(trimmedDomain)\\\(username)"
            return "rdp://\(qualifiedUser)@\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"
        }
    }

    func apply(to session: RemoteSession) {
        let previousBinding = session.mcpGrantTargetBinding
        session.name = name
        session.host = host
        session.username = username
        session.connectionType = connectionType
        session.port = port
        session.identityFile = identityFile
        session.jumpHost = jumpHost
        session.folder = folder
        session.enableX11Forwarding = enableX11Forwarding
        session.remotePath = remotePath
        let previousRDPPersistentMCPControlEnabled =
            session.rdpProfile.persistentMCPControlEnabled
        let rdpProfile = RDPConnectionProfile(
            domain: rdpDomain,
            desktopWidth: rdpDesktopWidth,
            desktopHeight: rdpDesktopHeight,
            certificateTrustMode: rdpCertificateTrustMode,
            pinnedCertificateSHA256: rdpPinnedCertificateSHA256,
            clipboardEnabled: rdpClipboardEnabled,
            companionPolicy: rdpCompanionPolicy,
            persistentMCPControlEnabled: rdpPersistentMCPControlEnabled,
            permissionPolicy: rdpPermissionPolicy
        )
        session.rdpProfileData = try? RDPConnectionProfileCodec.encode(rdpProfile)
        let previousMCPEnabled = session.mcpEnabled
        let previousMCPAlwaysAllowTerminalControl = session.mcpAlwaysAllowTerminalControl
        let previousMCPAlias = session.mcpAlias
        session.mcpEnabled = connectionType == .macDesktop ? false : mcpEnabled
        session.mcpAlwaysAllowTerminalControl = connectionType != .rdp && session.mcpEnabled && mcpAlwaysAllowTerminalControl
        session.mcpAlias = mcpAlias
        if previousMCPEnabled != session.mcpEnabled ||
            previousMCPAlwaysAllowTerminalControl != session.mcpAlwaysAllowTerminalControl ||
            previousRDPPersistentMCPControlEnabled !=
                session.rdpProfile.persistentMCPControlEnabled ||
            previousMCPAlias != session.mcpAlias {
            session.mcpUpdatedAt = Date()
        }
        #if ENABLE_RDP_2
        if previousBinding != session.mcpGrantTargetBinding {
            ApplicationWorkspaceRuntime.shared.macDesktops.remove(for: session.persistentModelID)
            MacSystemScreenSharingStore.shared.remove(targetID: session.targetID)
        }
        #endif
        session.updatedAt = Date()
    }
}

enum CredentialOperationKind: Equatable, Sendable {
    case save
    case check
    case delete
}

struct CredentialTargetIdentity: Equatable, Sendable {
    let connectionType: RemoteConnectionType
    let account: String
}

struct CredentialOperationRequest: Equatable, Sendable {
    let id: UUID
    let kind: CredentialOperationKind
    let target: CredentialTargetIdentity
    let identityGeneration: UInt64
    let inputRevision: UInt64
}

enum CredentialOperationCompletionDisposition: Equatable, Sendable {
    case current
    case inputChanged
    case targetChanged
}

struct CredentialOperationState: Equatable, Sendable {
    private(set) var activeRequest: CredentialOperationRequest? = nil

    var isRunning: Bool {
        activeRequest != nil
    }

    var activeKind: CredentialOperationKind? {
        activeRequest?.kind
    }

    mutating func begin(
        _ kind: CredentialOperationKind,
        target: CredentialTargetIdentity,
        identityGeneration: UInt64,
        inputRevision: UInt64
    ) -> CredentialOperationRequest? {
        guard activeRequest == nil else { return nil }
        let request = CredentialOperationRequest(
            id: UUID(),
            kind: kind,
            target: target,
            identityGeneration: identityGeneration,
            inputRevision: inputRevision
        )
        activeRequest = request
        return request
    }

    mutating func complete(
        _ request: CredentialOperationRequest,
        currentTarget: CredentialTargetIdentity?,
        identityGeneration: UInt64,
        inputRevision: UInt64
    ) -> CredentialOperationCompletionDisposition? {
        guard activeRequest?.id == request.id else { return nil }
        activeRequest = nil

        guard request.target == currentTarget,
              request.identityGeneration == identityGeneration else {
            return .targetChanged
        }
        guard request.inputRevision == inputRevision else {
            return .inputChanged
        }
        return .current
    }
}

enum CredentialOperationPolicy {
    enum SavedCredentialPresence: Equatable {
        case unknown
        case absent
        case present
    }

    static func canStart(
        _ kind: CredentialOperationKind,
        supportsPasswordStorage: Bool,
        isConnectable: Bool,
        identityIsCurrent: Bool,
        passwordIsEmpty: Bool,
        hasUnsavedInput: Bool,
        savedCredentialPresence: SavedCredentialPresence,
        operationState: CredentialOperationState
    ) -> Bool {
        guard supportsPasswordStorage,
              isConnectable,
              identityIsCurrent,
              !operationState.isRunning else {
            return false
        }
        switch kind {
        case .save:
            return !passwordIsEmpty && hasUnsavedInput
        case .check:
            return true
        case .delete:
            return savedCredentialPresence != .absent
        }
    }

    static func hasUnsavedInput(
        currentValue: String,
        baselineValue: String
    ) -> Bool {
        currentValue != baselineValue
    }
}

/// Server Properties as a grouped Form. `trailing` adds the connection
/// actions section below the editable fields.
private struct SessionEditor<Trailing: View>: View {
    @Environment(\.appLanguage) private var language
    let targetID: UUID
    let closeGuard: ServerPropertiesWindowCloseGuard
    @Binding var draft: ServerPropertiesDraft
    @Binding var credentialOperationState: CredentialOperationState
    @Binding var credentialHasUnsavedInput: Bool
    @ViewBuilder var trailing: Trailing
    @State private var password = ""
    @State private var credentialInputBaseline = ""
    @State private var passwordStatus = ""
    @State private var trackedCredentialTarget: CredentialTargetIdentity? = nil
    @State private var credentialIdentityGeneration: UInt64 = 0
    @State private var credentialInputRevision: UInt64 = 0
    @State private var didInitializeCredentialTarget = false
    @State private var isConfirmingPasswordDeletion = false
    @State private var savedCredentialPresence:
        CredentialOperationPolicy.SavedCredentialPresence = .unknown

    var body: some View {
        Form {
            Section(language.localized("General", "通用")) {
                TextField(text: $draft.name, prompt: Text(language.localized("e.g. web-01", "例如 web-01"))) {
                    Text(language.localized("Name", "名称"))
                }
                .accessibilityIdentifier("session-name-field")

                TextField(text: $draft.folder, prompt: Text(language.localized("Optional, e.g. Production", "可选，例如生产环境"))) {
                    Text(language.localized("Group", "分组"))
                }
                .accessibilityIdentifier("session-group-name-field")

                Picker(language.localized("Connection type", "连接类型"), selection: $draft.connectionType) {
                    ForEach(RemoteConnectionType.selectableCases) { type in
                        Text(type.displayName(language: language))
                            .tag(type)
                    }
                }
                .accessibilityIdentifier("session-connection-type-picker")
            }

            switch draft.connectionType {
            case .ssh:
                sshSections
            case .localShell:
                localShellSections
            case .macDesktop:
                macDesktopSections
            case .rdp:
                rdpSections
            }

            trailing
        }
        .formStyle(.grouped)
        .onAppear(perform: initializeCredentialTarget)
        .onChange(of: draft.connectionType) { oldType, newType in
            if draft.port == oldType.defaultPort {
                draft.port = newType.defaultPort
            }
        }
        .onChange(of: currentCredentialTarget) { _, newTarget in
            credentialTargetDidChange(to: newTarget)
        }
    }

    private var hostField: some View {
        TextField(text: $draft.host, prompt: Text(language.localized("e.g. 192.168.1.10", "例如 192.168.1.10"))) {
            Text(language.localized("Host", "主机"))
        }
        .textContentType(.URL)
        .accessibilityIdentifier("session-host-field")
    }

    private var portField: some View {
        TextField(value: $draft.port, format: .number.grouping(.never)) {
            Text(language.localized("Port", "端口"))
        }
        .accessibilityIdentifier("session-port-field")
    }

    @ViewBuilder
    private var macDesktopSections: some View {
        Section {
            hostField
            portField
        } header: {
            Text(language.localized("Connection", "连接"))
        } footer: {
            Text(language.localized(
                "Install JTS Mac Companion on that Mac, then pair it in the Desktop workspace. System Screen Sharing uses that Mac's own login.",
                "在被控 Mac 上安装 JTS Mac Companion，然后在桌面工作区配对。系统屏幕共享使用那台 Mac 自己的登录。"
            ))
        }
    }

    @ViewBuilder
    private var sshSections: some View {
        Section(language.localized("Connection", "连接")) {
            hostField

            TextField(text: $draft.username, prompt: Text(language.localized("e.g. deploy", "例如 deploy"))) {
                Text(language.localized("Username", "用户名"))
            }
            .accessibilityIdentifier("session-username-field")

            portField

            TextField(text: $draft.jumpHost, prompt: Text(language.localized("Optional bastion host", "可选跳板机"))) {
                Text(language.localized("Jump host", "跳板机"))
            }
            .accessibilityIdentifier("session-jump-host-field")
        }

        Section {
            passwordRows
            identityFileRow
        } header: {
            Text(language.localized("Authentication", "身份验证"))
        } footer: {
            Text(passwordStorageHelpText)
        }

        Section {
            DisclosureGroup(language.localized("Advanced", "高级")) {
                Toggle(language.localized("X11 forwarding (-X)", "X11 转发 (-X)"), isOn: $draft.enableX11Forwarding)

                TextField(text: $draft.remotePath, prompt: Text("~")) {
                    Text(language.localized("Default path", "默认路径"))
                }
                .accessibilityIdentifier("session-remote-path-field")
            }
        } footer: {
            Text(language.localized(
                "X11 forwarding shows remote Linux apps on this Mac and needs XQuartz running.",
                "X11 转发会把远程 Linux 应用显示在这台 Mac 上，需要运行 XQuartz。"
            ))
        }

        mcpSection
    }

    private var identityFileRow: some View {
        LabeledContent(language.localized("Private key", "私钥")) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    TextField(text: $draft.identityFile, prompt: Text(language.localized("Optional, e.g. ~/.ssh/id_ed25519", "可选，例如 ~/.ssh/id_ed25519"))) {
                        Text(language.localized("Private key", "私钥"))
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("session-identity-field")

                    Button(language.localized("Browse…", "浏览…")) {
                        chooseIdentityFile()
                    }
                    .accessibilityIdentifier("session-identity-browse-button")
                    .help(language.localized("Choose a private key file", "选择 SSH 私钥文件"))
                }

                if !draft.identityFile.isBlank,
                   !SSHIdentityFileAccess.hasStoredAccess(for: draft.identityFile) {
                    Label(
                        language.localized(
                            "Choose this key with Browse so JTS Terminal can still read it after relaunch.",
                            "请用“浏览”选择此私钥，JTS Terminal 才能在重新打开后继续读取它。"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("session-identity-access-hint")
                }

                if case .blockedBySandbox(let socketPath) = SSHAgentSandboxPolicy.availability() {
                    Label(
                        language.localized(
                            "The ssh-agent at \(socketPath) can't be reached from App Sandbox. Load the key into the macOS ssh-agent with ssh-add, or choose the key file with Browse.",
                            "App Sandbox 无法访问位于 \(socketPath) 的 ssh-agent。请用 ssh-add 将密钥载入 macOS 自带的 ssh-agent，或通过“浏览”选择私钥文件。"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("session-ssh-agent-sandbox-hint")
                }
            }
        }
    }

    @ViewBuilder
    private var localShellSections: some View {
        Section {
            LabeledContent(
                language.localized("Runs on", "运行于"),
                value: language.localized("This Mac", "这台 Mac")
            )
        } footer: {
            Text(language.localized(
                "Opens an interactive shell on this Mac. If you switch a pane to root, AI terminal commands in that pane run as root too.",
                "在这台 Mac 上打开交互式 shell。如果你把某个窗格切到 root，AI 在该窗格中的终端命令也会以 root 执行。"
            ))
        }

        mcpSection
    }

    #if ENABLE_RDP_2
    @ViewBuilder
    private var rdpSections: some View {
        Section {
            hostField

            TextField(text: $draft.username, prompt: Text("Administrator")) {
                Text(language.localized("Windows username", "Windows 用户名"))
            }
            .accessibilityIdentifier("session-username-field")

            portField

            TextField(text: $draft.rdpDomain, prompt: Text(language.localized("Optional", "可选"))) {
                Text(language.localized("Domain", "域"))
            }
            .accessibilityIdentifier("session-rdp-domain-field")
        } header: {
            Text(language.localized("Connection", "连接"))
        } footer: {
            Text(language.localized(
                "Connects directly to this host. For a Windows PC on another network, pair its Windows Companion through a relay station.",
                "直接连接此主机。如需连接其他网络中的 Windows 电脑，请通过中转站配对它的 Windows Companion。"
            ))
        }

        Section {
            passwordRows
        } header: {
            Text(passwordSectionTitle)
        } footer: {
            Text(passwordStorageHelpText)
        }

        Section(language.localized("Desktop", "桌面")) {
            LabeledContent(language.localized("Size", "尺寸")) {
                HStack(spacing: 6) {
                    TextField("1920", value: $draft.rdpDesktopWidth, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 72)
                        .accessibilityIdentifier("session-rdp-width-field")
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("1080", value: $draft.rdpDesktopHeight, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 72)
                        .accessibilityIdentifier("session-rdp-height-field")
                }
            }

            if !(640...7_680).contains(draft.rdpDesktopWidth) ||
                !(480...4_320).contains(draft.rdpDesktopHeight) {
                Label(
                    language.localized(
                        "Use 640–7680 × 480–4320 pixels.",
                        "请使用 640–7680 × 480–4320 像素。"
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Toggle(isOn: $draft.rdpClipboardEnabled) {
                Text(language.localized("Share text clipboard", "共享文本剪贴板"))
                Text(language.localized(
                    "Text only, in both directions. Never available to AI.",
                    "仅文本，双向同步。不会提供给 AI。"
                ))
            }
            .accessibilityIdentifier("session-rdp-text-clipboard-toggle")
        }

        Section {
            Picker(language.localized("Trust", "信任方式"), selection: $draft.rdpCertificateTrustMode) {
                Text(language.localized("System trust or pinned fingerprint", "系统信任或固定指纹"))
                    .tag(RDPCertificateTrustMode.systemOrPinned)
                Text(language.localized("Pinned fingerprint only", "仅固定指纹"))
                    .tag(RDPCertificateTrustMode.pinnedOnly)
            }
            .accessibilityIdentifier("session-rdp-certificate-trust-picker")

            TextField(
                text: $draft.rdpPinnedCertificateSHA256,
                prompt: Text(language.localized("64 hexadecimal characters", "64 位十六进制字符"))
            ) {
                Text(language.localized("SHA-256 fingerprint", "SHA-256 指纹"))
            }
            .font(.body.monospaced())
            .accessibilityIdentifier("session-rdp-certificate-fingerprint-field")

            if draft.rdpCertificateTrustMode == .pinnedOnly,
               RDPConnectionProfile.normalizedFingerprint(draft.rdpPinnedCertificateSHA256) == nil {
                Label(
                    language.localized(
                        "Enter the complete fingerprint to save with pinned-only trust.",
                        "使用“仅固定指纹”时，请填写完整指纹后再保存。"
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            Text(language.localized("Certificate", "证书"))
        } footer: {
            Text(language.localized(
                "You approve a self-signed certificate the first time you connect. A later fingerprint change blocks the connection.",
                "首次连接时需确认自签名证书；之后指纹变化会阻断连接。"
            ))
        }

        Section {
            Picker(language.localized("Requirement", "要求"), selection: $draft.rdpCompanionPolicy) {
                Text(language.localized("Optional", "可选"))
                    .tag(RDPCompanionPolicy.optional)
                Text(language.localized("Required for AI tools", "AI 工具必需"))
                    .tag(RDPCompanionPolicy.required)
            }
            .accessibilityIdentifier("session-rdp-companion-policy-picker")
        } header: {
            Text("Windows Companion")
        } footer: {
            Text(language.localized(
                "Not needed to view and control the desktop yourself. Without it, AI tools for UI Automation, PowerShell, files and tasks are unavailable.",
                "自己查看和操作桌面不需要它。没有它时，AI 的界面自动化、PowerShell、文件和任务工具不可用。"
            ))
        }

        mcpSection
    }
    #else
    private var rdpSections: some View {
        EmptyView()
    }
    #endif

    private var passwordSectionTitle: String {
        #if ENABLE_RDP_2
        if draft.connectionType == .rdp {
            return language.localized("Windows Credential", "Windows 凭据")
        }
        #endif
        return language.localized("Password", "密码")
    }

    private var passwordFieldPlaceholder: String {
        #if ENABLE_RDP_2
        if draft.connectionType == .rdp {
            return language.localized(
                "Windows password, saved to local encrypted vault",
                "Windows 密码，保存到本地加密密码库"
            )
        }
        #endif
        return language.localized("SSH password, saved to local encrypted vault", "SSH 密码，保存到本地加密密码库")
    }

    private var passwordStorageHelpText: String {
        #if ENABLE_RDP_2
        if draft.connectionType == .rdp {
            return language.localized(
                "Saved encrypted on this Mac for this target only. Never exported.",
                "仅为此目标加密保存在这台 Mac 上，不会导出。"
            )
        }
        #endif
        return language.localized(
            "The password is saved encrypted on this Mac and used when the server asks for it. Keys and the macOS ssh-agent work without a password.",
            "密码加密保存在这台 Mac 上，服务器要求时自动使用。使用私钥或 macOS ssh-agent 时无需密码。"
        )
    }

    @ViewBuilder
    private var passwordRows: some View {
        LabeledContent(passwordSectionTitle) {
            PasswordRevealField(
                passwordFieldPlaceholder,
                text: passwordInputBinding,
                isDisabled: false,
                accessibilityIdentifier: "connection-password-field",
                onSubmit: savePassword
            )
        }

        if draft.connectionType == .ssh {
            SSHPasswordInputMetadata(password: password)
        }

        HStack(spacing: 8) {
            Text(passwordStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("connection-password-status")

            Spacer(minLength: 8)

            Button(language.localized("Check Saved", "检查已保存")) {
                checkPassword()
            }
            .accessibilityIdentifier("connection-check-password-button")
            .disabled(!canStartCredentialOperation(.check))

            Button(language.localized("Delete", "删除"), role: .destructive) {
                isConfirmingPasswordDeletion = true
            }
            .accessibilityIdentifier("connection-delete-password-button")
            .disabled(!canStartCredentialOperation(.delete))

            Button(language.localized("Save Password", "保存密码")) {
                savePassword()
            }
            .accessibilityIdentifier("connection-save-password-button")
            .disabled(!canStartCredentialOperation(.save))
        }
        .confirmationDialog(
            passwordDeletionConfirmationTitle,
            isPresented: $isConfirmingPasswordDeletion,
            titleVisibility: .visible
        ) {
            Button(
                language.localized(
                    "Delete Saved Password",
                    "删除已保存密码"
                ),
                role: .destructive,
                action: deletePassword
            )
            .accessibilityIdentifier(
                "connection-confirm-delete-password-button"
            )
            .disabled(!canStartCredentialOperation(.delete))

            Button(language.localized("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(language.localized(
                "This removes the saved password for \(draft.address(language: language)) from the local encrypted vault and clears the current password field. This cannot be undone.",
                "这会从本地加密密码库中删除 \(draft.address(language: language)) 的已保存密码，并清空当前密码输入，且无法撤销。"
            ))
        }
    }

    private var passwordDeletionConfirmationTitle: String {
        #if ENABLE_RDP_2
        if draft.connectionType == .rdp {
            return language.localized(
                "Delete saved Windows password?",
                "删除已保存的 Windows 密码？"
            )
        }
        #endif
        return language.localized(
            "Delete saved SSH password?",
            "删除已保存的 SSH 密码？"
        )
    }

    private var mcpSection: some View {
        Section {
            Toggle(mcpEnabledTitle, isOn: $draft.mcpEnabled)
                .accessibilityIdentifier("session-mcp-enabled-toggle")

            Toggle(persistentMCPControlTitle, isOn: persistentMCPControlBinding)
                .disabled(!draft.mcpEnabled)
                .accessibilityIdentifier("session-mcp-always-control-toggle")

            TextField(text: $draft.mcpAlias, prompt: Text(proposedMCPAlias)) {
                Text(language.localized("MCP alias", "MCP 别名"))
            }
            .disabled(!draft.mcpEnabled)
            .accessibilityIdentifier("session-mcp-alias-field")
        } header: {
            Text(language.localized("AI & MCP", "AI 与 MCP"))
        } footer: {
            Text(mcpAccessDescription)
        }
    }

    private var proposedMCPAlias: String {
        let source = draft.mcpAlias.nilIfBlank
            ?? draft.name.nilIfBlank
            ?? draft.host.nilIfBlank
            ?? draft.credentialAccount
        return MCPAlias.normalized(source)
    }

    private var mcpEnabledTitle: String {
        switch draft.connectionType {
        case .ssh:
            return language.localized("Allow AI to use this server", "允许 AI 使用此服务器")
        case .localShell:
            return language.localized("Allow AI to use this Local Shell", "允许 AI 使用此本地 Shell")
        case .macDesktop:
            return language.localized("Mac desktop is configured in the Desktop workspace.", "在桌面工作区配置 Mac 桌面。")
        case .rdp:
            #if ENABLE_RDP_2
            return language.localized("Allow AI to use this Windows target", "允许 AI 使用此 Windows 目标")
            #else
            return language.localized("Enable MCP discovery", "启用 MCP 发现")
            #endif
        }
    }

    private var persistentMCPControlTitle: String {
        switch draft.connectionType {
        case .ssh, .localShell:
            return language.localized(
                "AI can control every terminal of this profile",
                "AI 可控制此配置的所有终端"
            )
        case .macDesktop:
            return language.localized("Mac desktop is configured in the Desktop workspace.", "在桌面工作区配置 Mac 桌面。")
        case .rdp:
            return language.localized(
                "Allow registered AI clients persistent control of this target",
                "允许已注册 AI 客户端长期控制此目标"
            )
        }
    }

    private var mcpAccessDescription: String {
        switch draft.connectionType {
        case .ssh:
            return language.localized(
                "Registered AI clients can run commands and read and write files on this server. Without the second switch, turn AI control on per terminal tab. A pane in a root shell runs AI commands as root. Manage AI clients in Settings > MCP.",
                "已注册的 AI 客户端可以在这台服务器上执行命令、读写文件。未开启第二个开关时，需要在终端标签栏中逐个开启 AI 控制。处于 root shell 的窗格会以 root 执行 AI 命令。在“设置 > MCP”中管理 AI 客户端。"
            )
        case .localShell:
            return language.localized(
                "Registered AI clients can use the terminals of this profile. Without the second switch, turn AI control on per terminal tab. A pane you switched to root runs AI commands as root. Manage AI clients in Settings > MCP.",
                "已注册的 AI 客户端可以使用此配置的终端。未开启第二个开关时，需要在终端标签栏中逐个开启 AI 控制。你切到 root 的窗格会以 root 执行 AI 命令。在“设置 > MCP”中管理 AI 客户端。"
            )
        case .macDesktop:
            return ""
        case .rdp:
            return language.localized(
                "Registered AI clients can use this Windows target within the enabled scope until you revoke them in AI Access. Usage is recorded there. AI never gets the clipboard.",
                "已注册的 AI 客户端可以在已开启的范围内使用此 Windows 目标，直到你在“AI 访问”中撤销。使用情况会记录在那里。AI 不会获得剪贴板。"
            )
        }
    }

    private var persistentMCPControlBinding: Binding<Bool> {
        Binding(
            get: {
                guard draft.mcpEnabled else { return false }
                return draft.connectionType == .rdp
                    ? draft.rdpPersistentMCPControlEnabled
                    : draft.mcpAlwaysAllowTerminalControl
            },
            set: { isEnabled in
                if draft.connectionType == .rdp {
                    draft.rdpPersistentMCPControlEnabled = isEnabled && draft.mcpEnabled
                } else {
                    draft.mcpAlwaysAllowTerminalControl = isEnabled && draft.mcpEnabled
                }
            }
        )
    }

    private var supportsPasswordStorage: Bool {
        #if ENABLE_RDP_2
        return draft.connectionType == .ssh || draft.connectionType == .rdp
        #else
        return draft.connectionType == .ssh
        #endif
    }

    private var currentCredentialTarget: CredentialTargetIdentity? {
        guard supportsPasswordStorage else { return nil }
        return CredentialTargetIdentity(
            connectionType: draft.connectionType,
            account: draft.credentialAccount
        )
    }

    private var credentialIdentityIsCurrent: Bool {
        didInitializeCredentialTarget && trackedCredentialTarget == currentCredentialTarget
    }

    private var passwordInputBinding: Binding<String> {
        Binding(
            get: { password },
            set: { newValue in
                guard newValue != password else { return }
                password = newValue
                credentialInputRevision &+= 1
                credentialHasUnsavedInput =
                    CredentialOperationPolicy.hasUnsavedInput(
                        currentValue: newValue,
                        baselineValue: credentialInputBaseline
                    )
            }
        )
    }

    private func updateCredentialInputBaseline(
        _ baseline: String,
        replaceCurrentInput: Bool
    ) {
        credentialInputBaseline = baseline
        if replaceCurrentInput {
            password = baseline
        }
        credentialHasUnsavedInput =
            CredentialOperationPolicy.hasUnsavedInput(
                currentValue: password,
                baselineValue: baseline
            )
    }

    private func canStartCredentialOperation(_ kind: CredentialOperationKind) -> Bool {
        CredentialOperationPolicy.canStart(
            kind,
            supportsPasswordStorage: supportsPasswordStorage,
            isConnectable: draft.isConnectable,
            identityIsCurrent: credentialIdentityIsCurrent,
            passwordIsEmpty: password.isEmpty,
            hasUnsavedInput: credentialHasUnsavedInput,
            savedCredentialPresence: savedCredentialPresence,
            operationState: credentialOperationState
        )
    }

    private func initializeCredentialTarget() {
        guard !didInitializeCredentialTarget else { return }
        didInitializeCredentialTarget = true
        trackedCredentialTarget = currentCredentialTarget
        credentialIdentityGeneration &+= 1
        credentialInputRevision &+= 1
        password = ""
        updateCredentialInputBaseline("", replaceCurrentInput: true)
        savedCredentialPresence = .unknown
        updatePasswordStatus()
    }

    private func credentialTargetDidChange(to newTarget: CredentialTargetIdentity?) {
        guard didInitializeCredentialTarget else {
            initializeCredentialTarget()
            return
        }
        guard trackedCredentialTarget != newTarget else { return }

        trackedCredentialTarget = newTarget
        credentialIdentityGeneration &+= 1
        credentialInputRevision &+= 1
        password = ""
        updateCredentialInputBaseline("", replaceCurrentInput: true)
        savedCredentialPresence = .unknown

        guard newTarget != nil else {
            passwordStatus = ""
            savedCredentialPresence = .absent
            return
        }
        guard draft.isConnectable else {
            passwordStatus = language.localized(
                "Fill in Host, Username, and Port before checking a saved password.",
                "先填写主机、用户名和端口，再检查已保存密码。"
            )
            return
        }
        #if JTS_UI_TEST_SUPPORT
        if draft.connectionType == .ssh,
           UITestSSHSessionEnvironment.bypassesPersistentCredentialVault(
               forHost: draft.host,
               username: draft.username
           ) {
            password = ""
            passwordStatus = language.localized(
                "Formal smoke credential is provided once at connection time and is never stored.",
                "正式冒烟凭据仅在连接时提供一次，绝不会写入本地密码库。"
            )
            savedCredentialPresence = .absent
            return
        }
        #endif
        passwordStatus = language.localized(
            "Credential target changed. Select Check Saved before using a stored password.",
            "凭据目标已更改；使用已保存密码前请先点“检查已保存”。"
        )
    }

    private func updatePasswordStatus() {
        guard supportsPasswordStorage else {
            updateCredentialInputBaseline("", replaceCurrentInput: true)
            passwordStatus = ""
            savedCredentialPresence = .absent
            return
        }
        #if JTS_UI_TEST_SUPPORT
        if draft.connectionType == .ssh,
           UITestSSHSessionEnvironment.bypassesPersistentCredentialVault(
               forHost: draft.host,
               username: draft.username
           ) {
            updateCredentialInputBaseline("", replaceCurrentInput: true)
            passwordStatus = language.localized(
                "Formal smoke credential is provided once at connection time and is never stored.",
                "正式冒烟凭据仅在连接时提供一次，绝不会写入本地密码库。"
            )
            savedCredentialPresence = .absent
            return
        }
        #endif
        checkPassword()
    }

    private func beginCredentialOperation(
        _ kind: CredentialOperationKind
    ) -> CredentialOperationRequest? {
        guard canStartCredentialOperation(kind),
              let target = currentCredentialTarget,
              target == trackedCredentialTarget else {
            return nil
        }
        var state = credentialOperationState
        let request = state.begin(
            kind,
            target: target,
            identityGeneration: credentialIdentityGeneration,
            inputRevision: credentialInputRevision
        )
        credentialOperationState = state
        closeGuard.credentialOperationIsRunning = state.isRunning
        return request
    }

    private func completeCredentialOperation(
        _ request: CredentialOperationRequest
    ) -> CredentialOperationCompletionDisposition? {
        var state = credentialOperationState
        let disposition = state.complete(
            request,
            currentTarget: currentCredentialTarget,
            identityGeneration: credentialIdentityGeneration,
            inputRevision: credentialInputRevision
        )
        credentialOperationState = state
        closeGuard.credentialOperationIsRunning = state.isRunning
        return disposition
    }

    private func savePassword() {
        guard let request = beginCredentialOperation(.save) else { return }
        let account = request.target.account
        let address = draft.address(language: language)
        let secret = password
        let connectionType = request.target.connectionType
        passwordStatus = language.localized("Saving to local encrypted vault...", "正在保存到本地加密密码库...")
        #if ENABLE_RDP_2
        let legacyVaultAccounts = RDPPasswordStore.legacyVaultAccounts(
            username: draft.username,
            host: draft.host,
            port: draft.port,
            domain: draft.rdpDomain
        )
        #endif

        Task {
            do {
                #if ENABLE_RDP_2
                if connectionType == .rdp {
                    try await RDPPasswordAccess.shared.savePassword(
                        secret,
                        targetID: targetID,
                        legacyVaultAccounts: legacyVaultAccounts
                    )
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try SSHCredentialVaultAccess.save(secret: secret, account: account)
                    }.value
                }
                #else
                try await Task.detached(priority: .userInitiated) {
                    try SSHCredentialVaultAccess.save(secret: secret, account: account)
                }.value
                #endif
                guard let disposition = completeCredentialOperation(request) else { return }
                guard disposition != .targetChanged else { return }
                savedCredentialPresence = .present
                updateCredentialInputBaseline(
                    secret,
                    replaceCurrentInput: false
                )
                switch disposition {
                case .targetChanged:
                    return
                case .inputChanged:
                    guard credentialHasUnsavedInput else { break }
                    passwordStatus = language.localized(
                        "The earlier password was saved, but the field now contains newer unsaved changes.",
                        "之前的密码已保存，但输入框中还有更新且未保存的更改。"
                    )
                    return
                case .current:
                    break
                }
                #if ENABLE_RDP_2
                if connectionType == .rdp {
                    passwordStatus = language.localized(
                        "Windows password saved in the local encrypted vault for \(address).",
                        "Windows 密码已存入本地加密密码库，用于 \(address)。"
                    )
                } else {
                    passwordStatus = language.localized(
                        "Password saved to the local encrypted vault for \(address).",
                        "密码已保存到本地加密密码库，用于 \(address)。"
                    )
                }
                #else
                passwordStatus = language.localized(
                    "Password saved to the local encrypted vault for \(address).",
                    "密码已保存到本地加密密码库，用于 \(address)。"
                )
                #endif
            } catch {
                guard let disposition = completeCredentialOperation(request) else { return }
                switch disposition {
                case .targetChanged:
                    return
                case .inputChanged:
                    passwordStatus = language.localized(
                        "Password save failed; the current field still has unsaved changes. \(error.localizedDescription)",
                        "密码保存失败；当前输入框仍有未保存更改。\(error.localizedDescription)"
                    )
                case .current:
                    passwordStatus = error.localizedDescription
                }
            }
        }
    }

    private func checkPassword() {
        guard supportsPasswordStorage else {
            passwordStatus = ""
            return
        }
        guard let request = beginCredentialOperation(.check) else {
            guard !draft.isConnectable else { return }
            passwordStatus = language.localized(
                "Fill in Host, Username, and Port before saving a password.",
                "先填写主机、用户名和端口，再保存密码。"
            )
            return
        }

        let account = request.target.account
        let connectionType = request.target.connectionType
        passwordStatus = language.localized("Checking local encrypted vault...", "正在检查本地加密密码库...")
        #if ENABLE_RDP_2
        let legacyVaultAccounts = RDPPasswordStore.legacyVaultAccounts(
            username: draft.username,
            host: draft.host,
            port: draft.port,
            domain: draft.rdpDomain
        )
        #endif

        Task {
            do {
                let stored: String?
                #if ENABLE_RDP_2
                if connectionType == .rdp {
                    stored = try await RDPPasswordAccess.shared.readOrMigratePassword(
                        targetID: targetID,
                        legacyVaultAccounts: legacyVaultAccounts
                    )
                } else {
                    stored = try await Task.detached(priority: .userInitiated) {
                        try SSHCredentialVaultAccess.read(account: account)
                    }.value
                }
                #else
                stored = try await Task.detached(priority: .userInitiated) {
                    try SSHCredentialVaultAccess.read(account: account)
                }.value
                #endif
                guard let disposition = completeCredentialOperation(request) else { return }
                guard disposition != .targetChanged else { return }
                savedCredentialPresence = stored == nil ? .absent : .present
                let storedValue = stored ?? ""
                switch disposition {
                case .targetChanged:
                    return
                case .inputChanged:
                    updateCredentialInputBaseline(
                        storedValue,
                        replaceCurrentInput: false
                    )
                    guard credentialHasUnsavedInput else { break }
                    passwordStatus = language.localized(
                        "Saved-password check finished, but the current input was not replaced because you edited it.",
                        "已完成保存密码检查；由于你编辑了当前输入，未用检查结果覆盖它。"
                    )
                    return
                case .current:
                    updateCredentialInputBaseline(
                        storedValue,
                        replaceCurrentInput: true
                    )
                }
                if let stored {
                    #if ENABLE_RDP_2
                    if connectionType == .rdp {
                        passwordStatus = language.localized(
                            "A Windows password exists in the local encrypted vault and is loaded into the masked field above.",
                            "本地加密密码库中已有 Windows 密码，已载入上方掩码输入框。"
                        )
                    } else {
                        passwordStatus = language.localized(
                            "A password exists in the local encrypted vault and is loaded into the masked field above.",
                            "本地加密密码库中已有此服务器密码，已保持在上方掩码输入框中。"
                        )
                    }
                    #else
                    passwordStatus = language.localized(
                        "A password exists in the local encrypted vault and is loaded into the masked field above.",
                        "本地加密密码库中已有此服务器密码，已保持在上方掩码输入框中。"
                    )
                    #endif
                } else {
                    #if ENABLE_RDP_2
                    if connectionType == .rdp {
                        passwordStatus = language.localized(
                            "No Windows password is saved. Save one before opening the RDP desktop.",
                            "尚未保存 Windows 密码；请先保存，再打开 RDP 桌面。"
                        )
                    } else {
                        passwordStatus = language.localized(
                            "No saved password. You can continue using an SSH key or ssh-agent.",
                            "未保存密码。也可以继续使用 SSH key / ssh-agent。"
                        )
                    }
                    #else
                    passwordStatus = language.localized(
                        "No saved password. You can continue using an SSH key or ssh-agent.",
                        "未保存密码。也可以继续使用 SSH key / ssh-agent。"
                    )
                    #endif
                }
            } catch {
                guard let disposition = completeCredentialOperation(request) else { return }
                if disposition != .targetChanged {
                    savedCredentialPresence = .unknown
                }
                switch disposition {
                case .targetChanged:
                    return
                case .inputChanged:
                    passwordStatus = language.localized(
                        "Saved-password check failed; your current input was left unchanged. \(error.localizedDescription)",
                        "保存密码检查失败；当前输入保持不变。\(error.localizedDescription)"
                    )
                case .current:
                    passwordStatus = error.localizedDescription
                }
            }
        }
    }

    private func deletePassword() {
        guard let request = beginCredentialOperation(.delete) else { return }
        let account = request.target.account
        let connectionType = request.target.connectionType
        passwordStatus = language.localized("Deleting saved password...", "正在删除保存的密码...")
        #if ENABLE_RDP_2
        let legacyVaultAccounts = RDPPasswordStore.legacyVaultAccounts(
            username: draft.username,
            host: draft.host,
            port: draft.port,
            domain: draft.rdpDomain
        )
        #endif

        Task {
            do {
                #if ENABLE_RDP_2
                if connectionType == .rdp {
                    try await RDPPasswordAccess.shared.deletePassword(
                        targetID: targetID,
                        legacyVaultAccounts: legacyVaultAccounts
                    )
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try SSHCredentialVaultAccess.delete(account: account)
                    }.value
                }
                #else
                try await Task.detached(priority: .userInitiated) {
                    try SSHCredentialVaultAccess.delete(account: account)
                }.value
                #endif
                guard let disposition = completeCredentialOperation(request) else { return }
                guard disposition != .targetChanged else { return }
                savedCredentialPresence = .absent
                switch disposition {
                case .targetChanged:
                    return
                case .inputChanged:
                    updateCredentialInputBaseline(
                        "",
                        replaceCurrentInput: false
                    )
                    guard credentialHasUnsavedInput else { break }
                    passwordStatus = language.localized(
                        "The saved password was deleted, but the field now contains newer unsaved changes.",
                        "已删除保存的密码，但输入框中还有更新且未保存的更改。"
                    )
                    return
                case .current:
                    updateCredentialInputBaseline(
                        "",
                        replaceCurrentInput: true
                    )
                }
                #if ENABLE_RDP_2
                if connectionType == .rdp {
                    passwordStatus = language.localized(
                        "The Windows password was deleted from the local encrypted vault.",
                        "已从本地加密密码库删除 Windows 密码。"
                    )
                } else {
                    passwordStatus = language.localized(
                        "Saved password deleted for this server.",
                        "已删除此服务器保存的密码。"
                    )
                }
                #else
                passwordStatus = language.localized(
                    "Saved password deleted for this server.",
                    "已删除此服务器保存的密码。"
                )
                #endif
            } catch {
                guard let disposition = completeCredentialOperation(request) else { return }
                switch disposition {
                case .targetChanged:
                    return
                case .inputChanged:
                    passwordStatus = language.localized(
                        "Password deletion failed; the current field still has unsaved changes. \(error.localizedDescription)",
                        "密码删除失败；当前输入框仍有未保存更改。\(error.localizedDescription)"
                    )
                case .current:
                    passwordStatus = error.localizedDescription
                }
            }
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = language.localized("Choose SSH private key", "选择 SSH 私钥")
        panel.message = language.localized(
            "Select the private key file used by ssh -i.",
            "选择 ssh -i 使用的私钥文件。"
        )
        panel.prompt = language.localized("Choose", "选择")
        panel.directoryURL = SSHIdentityFileSelectionPolicy.defaultDirectoryURL(
            currentPath: draft.identityFile
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Keep read access across launches and in the MCP process; App
        // Sandbox otherwise denies ssh the key after this launch.
        SSHIdentityFileAccess.remember(url)
        draft.identityFile = SSHIdentityFileSelectionPolicy.displayPath(for: url)
    }
}

enum SSHIdentityFileSelectionPolicy {
    static func defaultDirectoryURL(
        currentPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        let expandedCurrentPath = expandedPath(currentPath, homeDirectory: homeDirectory)
        if let currentDirectory = directoryURL(forExpandedPath: expandedCurrentPath, fileManager: fileManager) {
            return currentDirectory
        }

        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        if directoryExists(at: sshDirectory, fileManager: fileManager) {
            return sshDirectory
        }

        return homeDirectory
    }

    static func displayPath(
        for url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let path = url.path
        let homePath = homeDirectory.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~/" + String(path.dropFirst(homePath.count + 1))
        }
        return path
    }

    private static func expandedPath(_ path: String, homeDirectory: URL) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == "~" { return homeDirectory.path }
        if trimmed.hasPrefix("~/") {
            return homeDirectory
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .path
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func directoryURL(forExpandedPath path: String, fileManager: FileManager) -> URL? {
        guard !path.isEmpty else { return nil }

        let url = URL(fileURLWithPath: path)
        if directoryExists(at: url, fileManager: fileManager) {
            return url
        }

        let parent = url.deletingLastPathComponent()
        return directoryExists(at: parent, fileManager: fileManager) ? parent : nil
    }

    private static func directoryExists(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private struct ServerPropertiesSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    let allSessions: [RemoteSession]
    let closeGuard: ServerPropertiesWindowCloseGuard
    let close: () -> Void
    let openInteractive: () -> Void
    let deleteServer: (() -> Void)?
    @State private var draft: ServerPropertiesDraft
    @State private var saveStatus = ""
    @State private var credentialOperationState = CredentialOperationState()
    @State private var credentialHasUnsavedInput = false
    @State private var isConfirmingDeletion = false

    init(
        session: RemoteSession,
        allSessions: [RemoteSession],
        closeGuard: ServerPropertiesWindowCloseGuard,
        close: @escaping () -> Void,
        openInteractive: @escaping () -> Void,
        deleteServer: (() -> Void)? = nil
    ) {
        self.session = session
        self.allSessions = allSessions
        self.closeGuard = closeGuard
        self.close = close
        self.openInteractive = openInteractive
        self.deleteServer = deleteServer
        _draft = State(initialValue: ServerPropertiesDraft(session: session))
    }

    private var hasChanges: Bool {
        draft != ServerPropertiesDraft(session: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionEditor(
                targetID: session.targetID,
                closeGuard: closeGuard,
                draft: $draft,
                credentialOperationState: $credentialOperationState,
                credentialHasUnsavedInput: $credentialHasUnsavedInput
            ) {
                Section(language.localized("Test and Open", "测试与打开")) {
                    if hasChanges {
                        Text(language.localized(
                            "Save your changes to test or open this connection.",
                            "保存更改后才能测试或打开此连接。"
                        ))
                        .foregroundStyle(.secondary)
                    } else {
                        ConnectionActions(
                            session: session,
                            openInteractive: openInteractive,
                            disabledReason: credentialActionsDisabledReason
                        )
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                if deleteServer != nil {
                    Button(language.localized("Delete Server…", "删除服务器…"), role: .destructive) {
                        isConfirmingDeletion = true
                    }
                    .disabled(credentialOperationState.isRunning)
                    .accessibilityIdentifier("server-properties-delete-button")
                }

                Spacer(minLength: 12)

                if !saveStatus.isBlank {
                    Text(saveStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Button(language.localized("Cancel", "取消")) {
                    guard !credentialOperationState.isRunning else { return }
                    close()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(credentialOperationState.isRunning)
                .accessibilityIdentifier("server-properties-cancel-button")

                Button(language.localized("Save", "保存")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !hasChanges ||
                    !draft.isConnectable ||
                    credentialOperationState.isRunning ||
                    credentialHasUnsavedInput
                )
                .accessibilityIdentifier("server-properties-save-button")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 520, idealHeight: 720)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("server-properties-content")
        .confirmationDialog(
            language.localized("Delete this server?", "删除此服务器？"),
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(language.localized("Delete", "删除"), role: .destructive) {
                guard !credentialOperationState.isRunning else { return }
                deleteServer?()
            }
            Button(language.localized("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(language.localized(
                "Open terminals, tunnels and desktops of this server are closed. Unsaved changes in this window are discarded.",
                "该服务器打开的终端、隧道和桌面会被关闭，本窗口中未保存的更改将被丢弃。"
            ))
        }
    }

    private func save() {
        guard !credentialOperationState.isRunning,
              !credentialHasUnsavedInput else {
            saveStatus = language.localized(
                "Save or clear the password input before saving Server Properties.",
                "请先保存或清除密码输入，再保存服务器属性。"
            )
            return
        }
        var preparedDraft = draft
        if preparedDraft.mcpEnabled {
            let aliasSource = preparedDraft.mcpAlias.nilIfBlank
                ?? preparedDraft.name.nilIfBlank
                ?? preparedDraft.host.nilIfBlank
                ?? preparedDraft.credentialAccount
            preparedDraft.mcpAlias = uniqueMCPAlias(for: MCPAlias.normalized(aliasSource))
        } else {
            preparedDraft.mcpEnabled = false
            preparedDraft.mcpAlias = ""
        }

        preparedDraft.apply(to: session)
        do {
            try modelContext.save()
            saveStatus = language.localized(
                "Saved \(session.localizedAddress(language: language)).",
                "已保存 \(session.localizedAddress(language: language))。"
            )
            close()
        } catch {
            saveStatus = language.localized("Save failed: \(error.localizedDescription)", "保存失败：\(error.localizedDescription)")
        }
    }

    private var credentialActionsDisabledReason: String? {
        if let operation = credentialOperationState.activeKind {
            let action: String
            switch operation {
            case .save:
                action = language.localized("saving the password", "保存密码")
            case .check:
                action = language.localized("checking the saved password", "检查已保存密码")
            case .delete:
                action = language.localized("deleting the saved password", "删除已保存密码")
            }
            return language.localized(
                "Wait until JTS Terminal finishes \(action) before opening or testing this connection.",
                "请等待 JTS Terminal 完成\(action)，再打开或测试此连接。"
            )
        }
        if credentialHasUnsavedInput {
            return language.localized(
                "Save the password, check the saved value, or delete the input before opening or testing this connection.",
                "请先保存密码、检查已保存值或删除当前输入，再打开或测试此连接。"
            )
        }
        return nil
    }

    private func uniqueMCPAlias(for alias: String) -> String {
        let used = Set(
            allSessions
                .filter {
                    $0.persistentModelID != session.persistentModelID &&
                    $0.mcpEnabled
                }
                .map(\.effectiveMCPAlias)
        )

        guard used.contains(alias) else { return alias }

        var index = 2
        while used.contains("\(alias)-\(index)") {
            index += 1
        }
        return "\(alias)-\(index)"
    }

}

private struct ConnectionActions: View {
    private static let sshConnectionTestTimeoutSeconds: TimeInterval = 20

    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    let openInteractive: () -> Void
    var disabledReason: String?
    @StateObject private var testCoordinator = SSHConnectionTestCoordinator(
        timeoutSeconds: sshConnectionTestTimeoutSeconds
    )
    #if JTS_UI_TEST_SUPPORT
    @State private var appReviewStatus: CommandResult?
    @State private var appReviewErrorMessage: String?
    @State private var isAppReviewTestRunning = false
    @State private var latestAppReviewSmokeNonce: String?
    @State private var latestAppReviewCredentialConsumed: Bool?
    @State private var appReviewTestRequestID: UUID?
    @State private var appReviewTestTask: Task<Void, Never>?
    private let executor = ProcessExecutor()
    #endif

    private var actionsDisabled: Bool { disabledReason != nil }

    private var connectionStatus: CommandResult? {
        #if JTS_UI_TEST_SUPPORT
        if isAppReviewTestRunning || appReviewStatus != nil || appReviewErrorMessage != nil {
            appReviewStatus
        } else {
            testCoordinator.status
        }
        #else
        testCoordinator.status
        #endif
    }

    private var connectionErrorMessage: String? {
        #if JTS_UI_TEST_SUPPORT
        if isAppReviewTestRunning || appReviewStatus != nil || appReviewErrorMessage != nil {
            appReviewErrorMessage
        } else {
            testCoordinator.errorMessage
        }
        #else
        testCoordinator.errorMessage
        #endif
    }

    private var isConnectionTestRunning: Bool {
        #if JTS_UI_TEST_SUPPORT
        isAppReviewTestRunning || testCoordinator.isRunning
        #else
        testCoordinator.isRunning
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                switch session.connectionType {
                case .ssh:
                    Button(
                        isConnectionTestRunning
                            ? language.localized("Testing…", "正在测试…")
                            : language.localized("Test Connection", "测试连接")
                    ) {
                        runTestConnection()
                    }
                    .accessibilityLabel(
                        isConnectionTestRunning
                            ? language.localized("Testing...", "正在测试...")
                            : language.localized("Test SSH Connection", "测试 SSH 连接")
                    )
                    .accessibilityIdentifier("test-ssh-connection-button")
                    .disabled(!session.isConnectable || isConnectionTestRunning || actionsDisabled)

                    Button(language.localized("Open Terminal", "打开终端")) {
                        openInteractiveIfEnabled()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("open-interactive-ssh-button")
                    .disabled(!session.isConnectable || actionsDisabled)
                case .localShell:
                    Button(language.localized("Open Local Shell", "打开本地 Shell")) {
                        openInteractiveIfEnabled()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("open-local-shell-button")
                    .disabled(actionsDisabled)
                case .rdp, .macDesktop:
                    #if ENABLE_RDP_2
                    Button(language.localized("Open Desktop", "打开桌面")) {
                        openInteractiveIfEnabled()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("open-rdp-desktop-button")
                    .disabled(!session.isConnectable || actionsDisabled)
                    #else
                    Text(language.localized(
                        "This saved profile type is not included in the current App Store build.",
                        "当前 App Store 构建不包含此已保存配置类型。"
                    ))
                    .foregroundStyle(.secondary)
                    #endif
                }
            }

            Label {
                Text(disabledReason ?? connectionStatus?.displayText ?? connectionErrorMessage ?? defaultStatusText)
                    .font(.caption.monospaced())
                    .foregroundStyle(connectionErrorMessage == nil && disabledReason == nil ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection-status-text")
                    .accessibilityLabel(disabledReason ?? connectionStatus?.displayText ?? connectionErrorMessage ?? defaultStatusText)
            } icon: {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
            }
            #if JTS_UI_TEST_SUPPORT
            uiTestingSmokeStatusAnchor
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(item: testCredentialPromptBinding) { descriptor in
            SSHCredentialPromptSheet(
                descriptor: descriptor,
                purpose: .test,
                isSubmitting: testCoordinator.isSubmittingCredential,
                errorMessage: testCoordinator.errorMessage,
                cancel: {
                    testCoordinator.cancel(requestID: descriptor.id)
                },
                useKeyOrAgent: {
                    testCoordinator.useKeyOrAgent(requestID: descriptor.id)
                },
                submitOnce: { secret in
                    testCoordinator.connectOnce(secret: secret, requestID: descriptor.id)
                },
                saveAndSubmit: { secret in
                    testCoordinator.saveAndTest(secret: secret, requestID: descriptor.id)
                }
            )
            .environment(\.appLanguage, language)
            .id(descriptor.id)
        }
        .onDisappear {
            testCoordinator.cancel()
            #if JTS_UI_TEST_SUPPORT
            cancelAppReviewTest()
            #endif
        }
    }

    private var statusIcon: String {
        if disabledReason != nil { return "exclamationmark.triangle.fill" }
        return connectionStatus?.succeeded == true ? "circle.fill" : "circle.dashed"
    }

    private var statusColor: Color {
        if disabledReason != nil { return .orange }
        return connectionStatus?.succeeded == true ? Color.green : Color.secondary
    }

    private var defaultStatusText: String {
        switch session.connectionType {
        case .ssh:
            return language.localized("Connection not tested yet.", "尚未测试连接。")
        case .localShell:
            return language.localized("Local shell profile is ready.", "本地 Shell 配置已就绪。")
        case .macDesktop:
            return language.localized("Mac desktop is configured in the Desktop workspace.", "在桌面工作区配置 Mac 桌面。")
        case .rdp:
            #if ENABLE_RDP_2
            return language.localized("RDP profile is ready to open in the Desktop workspace.", "RDP 配置已就绪，可在桌面工作区中打开。")
            #else
            return language.localized("This profile type is not supported in this build.", "当前构建不支持此配置类型。")
            #endif
        }
    }

    private func openInteractiveIfEnabled() {
        guard !actionsDisabled, session.isConnectable else { return }
        openInteractive()
    }

    #if JTS_UI_TEST_SUPPORT
    @ViewBuilder
    private var uiTestingSmokeStatusAnchor: some View {
        if let report = uiTestingSmokeStatusReport,
           let data = try? UITestSSHSessionEnvironment.smokeStatusData(report),
           let json = String(data: data, encoding: .utf8),
           let identifier = try? UITestSSHSessionEnvironment.smokeStatusAccessibilityIdentifier(report) {
            Text(json)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("App Review SSH smoke status")
                .accessibilityValue(json)
        }
    }

    private var uiTestingSmokeStatusReport: UITestSSHSmokeStatus? {
        let currentNonce = UITestSSHSessionEnvironment.appReviewSmokeNonce(
            forHost: session.host,
            username: session.username,
            credentialAccount: CredentialStore.account(for: session)
        )
        guard let nonce = latestAppReviewSmokeNonce ?? currentNonce else {
            return nil
        }
        if let appReviewStatus {
            return .completed(
                nonce: nonce,
                result: appReviewStatus,
                expectedMarker: UITestSSHSessionEnvironment.formalSmokeMarker,
                credentialConsumed: latestAppReviewCredentialConsumed == true
            )
        }
        if appReviewErrorMessage != nil {
            return .failed(nonce: nonce)
        }
        return isAppReviewTestRunning ? .started(nonce: nonce) : .ready(nonce: nonce)
    }
    #endif

    private func runTestConnection() {
        guard session.connectionType == .ssh, session.isConnectable, !actionsDisabled else { return }

        // Freeze the target synchronously, before Task scheduling or vault
        // access can suspend. RemoteSession is editable from this same view;
        // using it inside the task after a delayed credential read could send
        // the prior account's password to newly edited host fields.
        let remoteCommand = "printf 'connected '; hostname; uname -a"
        let launchSnapshot = SSHConnectionTestLaunchSnapshot(
            session: session,
            remoteCommand: remoteCommand
        )
        #if JTS_UI_TEST_SUPPORT
        if launchSnapshot.appReviewBrokerRequest != nil ||
            launchSnapshot.appReviewBrokerConfigurationError != nil {
            runAppReviewTest(snapshot: launchSnapshot)
            return
        }
        appReviewStatus = nil
        appReviewErrorMessage = nil
        isAppReviewTestRunning = false
        latestAppReviewSmokeNonce = nil
        latestAppReviewCredentialConsumed = nil
        #endif

        testCoordinator.begin(
            snapshot: launchSnapshot,
            displayLabel: session.address
        )
    }

    private var testCredentialPromptBinding: Binding<SSHCredentialPromptDescriptor?> {
        Binding(
            get: { testCoordinator.pendingCredentialPrompt },
            set: { newValue in
                guard newValue == nil,
                      !testCoordinator.isSubmittingCredential,
                      let requestID = testCoordinator.pendingCredentialPrompt?.id else {
                    return
                }
                testCoordinator.cancel(requestID: requestID)
            }
        )
    }

    #if JTS_UI_TEST_SUPPORT
    private func runAppReviewTest(snapshot: SSHConnectionTestLaunchSnapshot) {
        cancelAppReviewTest()
        testCoordinator.cancel()
        let requestID = UUID()
        appReviewTestRequestID = requestID
        appReviewStatus = nil
        appReviewErrorMessage = nil
        isAppReviewTestRunning = true
        latestAppReviewSmokeNonce = snapshot.appReviewSmokeNonce
        latestAppReviewCredentialConsumed = nil

        let appReviewBrokerRequest = snapshot.appReviewBrokerRequest
        let appReviewBrokerConfigurationError = snapshot.appReviewBrokerConfigurationError
        appReviewTestTask = Task {
            defer {
                if appReviewTestRequestID == requestID {
                    appReviewTestTask = nil
                    appReviewTestRequestID = nil
                    isAppReviewTestRunning = false
                }
            }
            do {
                if let appReviewBrokerConfigurationError {
                    throw ProcessExecutorError.launchFailed(appReviewBrokerConfigurationError)
                }
                guard let appReviewBrokerRequest else {
                    throw ProcessExecutorError.launchFailed(
                        "The formal App Review SSH credential broker is unavailable."
                    )
                }
                let appReviewCredential = try await Task.detached(priority: .userInitiated) {
                    try AppReviewSSHCredentialBrokerClient.receiveCredential(
                        for: appReviewBrokerRequest
                    )
                }.value
                defer { _ = appReviewCredential.cleanup() }
                guard !Task.isCancelled,
                      appReviewTestRequestID == requestID else { return }
                let appReviewSecret = appReviewCredential.password
                guard appReviewCredential.knownHostsFilePath
                        == snapshot.appReviewKnownHostsFilePath,
                      let appReviewArguments = snapshot.appReviewPasswordArguments else {
                    throw UITestSSHSessionEnvironmentError.invalidKnownHostsFile
                }
                let askpassContext = try SSHCredentialAskpass.launchContext(
                    account: snapshot.credentialAccount,
                    secret: appReviewSecret
                )
                defer { askpassContext.cleanup() }
                let result = try await executor.run(
                    executable: "/usr/bin/ssh",
                    arguments: appReviewArguments,
                    environment: askpassContext.environment,
                    timeoutSeconds: Self.sshConnectionTestTimeoutSeconds
                )
                guard !Task.isCancelled,
                      appReviewTestRequestID == requestID else { return }
                latestAppReviewCredentialConsumed = askpassContext.credentialConsumed
                guard appReviewCredential.cleanup() else {
                    throw AppReviewSSHCredentialBrokerError.insecureBoundary
                }
                appReviewStatus = result
            } catch {
                guard !Task.isCancelled,
                      appReviewTestRequestID == requestID else { return }
                if appReviewBrokerRequest != nil {
                    latestAppReviewCredentialConsumed = false
                }
                appReviewErrorMessage = error.localizedDescription
            }
        }
    }

    private func cancelAppReviewTest() {
        appReviewTestTask?.cancel()
        appReviewTestTask = nil
        appReviewTestRequestID = nil
        isAppReviewTestRunning = false
    }
    #endif

}

enum RemoteFileSortMode: String, CaseIterable, Identifiable {
    case name = "Name"
    case type = "Type"
    case size = "Size"
    case modified = "Modified"

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .name:
            return language.localized("Name", "名称")
        case .type:
            return language.localized("Type", "类型")
        case .size:
            return language.localized("Size", "大小")
        case .modified:
            return language.localized("Modified", "修改时间")
        }
    }
}

@MainActor
final class RemoteFilesWorkspaceState: ObservableObject {
    @Published var result: CommandResult?
    @Published var entries: [RemoteFileEntry] = []
    @Published var selectedEntryID: RemoteFileEntry.ID?
    @Published var newFolderName = "new-folder"
    @Published var renameTargetName = ""
    @Published var errorMessage: String?
    @Published var operationMessage = "Ready."
    @Published var sortMode = RemoteFileSortMode.name
    @Published var isRunning = false
    @Published var editDraft: RemoteEditDraft?
    @Published private(set) var loadedConnectionKey: String?
    @Published private(set) var loadedPath: String?
    private var activeOperationID: UUID?

    func beginOperation() -> UUID {
        let operationID = UUID()
        activeOperationID = operationID
        isRunning = true
        return operationID
    }

    func isCurrentOperation(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    @discardableResult
    func finishOperation(_ operationID: UUID) -> Bool {
        guard activeOperationID == operationID else { return false }
        activeOperationID = nil
        isRunning = false
        return true
    }

    func markLoaded(session: RemoteSession, path: String) {
        loadedConnectionKey = session.connectionKey
        loadedPath = normalizedPath(path)
    }

    func hasLoadedCurrentDirectory(for session: RemoteSession) -> Bool {
        isRunning || (
            loadedConnectionKey == session.connectionKey &&
            loadedPath == normalizedPath(session.remotePath) &&
            (result != nil || errorMessage != nil || !entries.isEmpty)
        )
    }

    func clearForConnectionChange() {
        result = nil
        entries = []
        selectedEntryID = nil
        errorMessage = nil
        operationMessage = "Ready."
        isRunning = false
        activeOperationID = nil
        loadedConnectionKey = nil
        loadedPath = nil
    }

    private func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "~"
    }
}

@MainActor
final class RemoteFilesWorkspaceStore: ObservableObject {
    private var workspaces: [PersistentIdentifier: RemoteFilesWorkspaceState] = [:]

    func workspace(for sessionID: PersistentIdentifier) -> RemoteFilesWorkspaceState {
        if let existing = workspaces[sessionID] {
            return existing
        }

        let workspace = RemoteFilesWorkspaceState()
        workspaces[sessionID] = workspace
        return workspace
    }

    func removeWorkspace(for sessionID: PersistentIdentifier) {
        workspaces.removeValue(forKey: sessionID)
    }
}

private struct RemoteFilesPanel: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RemoteTransferTask.updatedAt, order: .reverse) private var transferTasks: [RemoteTransferTask]
    @Bindable var session: RemoteSession
    @ObservedObject var workspace: RemoteFilesWorkspaceState
    @ObservedObject var transferQueueManager: RemoteTransferQueueManager
    let openServerProperties: () -> Void
    @State private var isTransferHistoryPresented = false
    @State private var isCreatingFolder = false
    @State private var isRenaming = false
    @State private var entryPendingDeletion: RemoteFileEntry?

    private let sftpTransport = RemoteSFTPTransport()
    private let remoteCommandRunner = AuthenticatedRemoteCommandRunner()
    private var sessionTransferHistory: [RemoteTransferTask] {
        transferTasks
            .filter { $0.sessionConnectionKey == session.connectionKey }
    }
    private var visibleTransferQueueTasks: [RemoteTransferTask] {
        sessionTransferHistory
            .filter { $0.shouldRemainVisibleInQueue || transferQueueManager.isActive($0) }
            .prefix(6)
            .map { $0 }
    }
    private var selectedEntry: RemoteFileEntry? {
        workspace.entries.first { $0.id == workspace.selectedEntryID }
    }
    private var sortedEntries: [RemoteFileEntry] {
        workspace.entries.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory && !right.isDirectory
            }

            switch workspace.sortMode {
            case .name:
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .type:
                if left.typeLabel != right.typeLabel {
                    return left.typeLabel < right.typeLabel
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .size:
                let leftSize = left.byteSize ?? -1
                let rightSize = right.byteSize ?? -1
                if leftSize != rightSize {
                    return leftSize < rightSize
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .modified:
                if left.modified != right.modified {
                    return left.modified > right.modified
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    goToParent()
                } label: {
                    Label(language.localized("Parent", "上级"), systemImage: "chevron.up")
                }
                .disabled(!session.isConnectable || workspace.isRunning)

                Button {
                    session.remotePath = "~"
                    listDirectory()
                } label: {
                    Label(language.localized("Home", "主目录"), systemImage: "house")
                }
                .disabled(!session.isConnectable || workspace.isRunning)

                TextField(language.localized("Remote path", "远程路径"), text: $session.remotePath)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        listDirectory()
                    }
                    .accessibilityIdentifier("remote-files-path-field")

                Button(language.localized("Go", "前往")) {
                    listDirectory()
                }
                .disabled(!session.isConnectable || workspace.isRunning)

                Picker(language.localized("Sort", "排序"), selection: $workspace.sortMode) {
                    ForEach(RemoteFileSortMode.allCases) { mode in
                        Text(mode.title(language: language)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(language.localized("Sort", "排序"))

                Button {
                    listDirectory()
                } label: {
                    Label(
                        workspace.isRunning
                            ? language.localized("Loading", "加载中")
                            : language.localized("Refresh", "刷新"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!session.isConnectable || workspace.isRunning)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    uploadIntoCurrentDirectory()
                } label: {
                    Label(language.localized("Upload", "上传"), systemImage: "square.and.arrow.up")
                }
                .disabled(!session.isConnectable || workspace.isRunning)

                Button {
                    downloadSelected()
                } label: {
                    Label(language.localized("Download", "下载"), systemImage: "square.and.arrow.down")
                }
                .disabled(selectedEntry == nil || workspace.isRunning)

                Button {
                    openSelectedForEditing()
                } label: {
                    Label(language.localized("Edit", "编辑"), systemImage: "pencil")
                }
                .disabled(selectedEntry?.isRegularFile != true || workspace.isRunning)

                Menu {
                    Button {
                        workspace.newFolderName = ""
                        isCreatingFolder = true
                    } label: {
                        Label(language.localized("New Folder…", "新建文件夹…"), systemImage: "folder.badge.plus")
                    }
                    .disabled(!session.isConnectable || workspace.isRunning)

                    Button {
                        beginRename(selectedEntry)
                    } label: {
                        Label(language.localized("Rename…", "重命名…"), systemImage: "pencil")
                    }
                    .disabled(selectedEntry == nil || workspace.isRunning)

                    Button {
                        uploadEditedCopy()
                    } label: {
                        Label(language.localized("Sync Edited Copy", "同步编辑副本"), systemImage: "arrow.up.doc")
                    }
                    .disabled(workspace.editDraft == nil || workspace.isRunning)

                    Button {
                        revealEditedCopy()
                    } label: {
                        Label(language.localized("Reveal Local Edit Copy", "在访达中显示编辑副本"), systemImage: "folder")
                    }
                    .disabled(workspace.editDraft == nil)

                    Divider()

                    Button(role: .destructive) {
                        entryPendingDeletion = selectedEntry
                    } label: {
                        Label(language.localized("Delete…", "删除…"), systemImage: "trash")
                    }
                    .disabled(selectedEntry == nil || workspace.isRunning)
                } label: {
                    Label(language.localized("More", "更多"), systemImage: "ellipsis.circle")
                }
                .fixedSize()

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(statusText)
            }
            .padding(.horizontal, 2)

            ZStack {
                Table(sortedEntries, selection: $workspace.selectedEntryID) {
                TableColumn(language.localized("Name", "名称")) { entry in
	                    HStack {
	                        Image(systemName: iconName(for: entry))
	                            .foregroundStyle(iconColor(for: entry))
	                        Text(entry.displayName)
	                            .lineLimit(1)
	                    }
	                    .contentShape(Rectangle())
	                    .onTapGesture(count: 2) {
	                        open(entry)
	                    }
	                    .contextMenu {
	                        fileContextMenu(for: entry)
	                    }
	                }
                TableColumn(language.localized("Type", "类型"), value: \.typeLabel)
                    .width(80)
                TableColumn(language.localized("Size", "大小")) { entry in
                    Text(entry.isDirectory ? "--" : entry.formattedSize)
                        .foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn(language.localized("Owner", "所有者"), value: \.owner)
                    .width(90)
                TableColumn(language.localized("Permissions", "权限"), value: \.permissions)
                    .width(115)
                TableColumn(language.localized("Modified", "修改时间"), value: \.modified)
                    .width(min: 150, ideal: 180)
                }
                .contextMenu {
                    if let selectedEntry {
                        fileContextMenu(for: selectedEntry)
                    }
                }

                if workspace.isRunning {
                    ProgressView(workspace.operationMessage)
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if workspace.entries.isEmpty {
                    ContentUnavailableView(
                        emptyDirectoryTitle,
                        systemImage: workspace.errorMessage == nil ? "folder" : "exclamationmark.triangle",
                        description: Text(emptyDirectoryDescription)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            transferQueueView

            HStack {
                if workspace.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text(workspace.operationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let errorMessage = workspace.errorMessage {
                    HStack(spacing: 8) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)

                        Button {
                            openServerProperties()
                        } label: {
                            Label(language.localized("Server Properties", "服务器属性"), systemImage: "info.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                } else if let result = workspace.result, !result.succeeded {
                    Text(RemoteSFTPTransport.failureMessage(for: result))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                if let editDraft = workspace.editDraft {
                    Text(language.localized("Editing: \(editDraft.remoteName)", "正在编辑：\(editDraft.remoteName)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(editDraft.summary)
                }

                if let selectedEntry {
                    Text("\(selectedEntry.typeLabel) · \(selectedEntry.permissions)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .controlSize(.small)
        .onChange(of: workspace.selectedEntryID) { _, _ in
            workspace.renameTargetName = selectedEntry?.name ?? ""
        }
        .onAppear {
            if session.isConnectable, !workspace.hasLoadedCurrentDirectory(for: session) {
                listDirectory()
            }
        }
        .onChange(of: session.connectionKey) { _, _ in
            workspace.clearForConnectionChange()
            if session.isConnectable {
                listDirectory()
            }
        }
        .alert(language.localized("New Folder", "新建文件夹"), isPresented: $isCreatingFolder) {
            TextField(language.localized("Folder name", "文件夹名称"), text: $workspace.newFolderName)
            Button(language.localized("Create", "创建")) {
                guard !workspace.newFolderName.isBlank else { return }
                makeDirectory()
            }
            Button(language.localized("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(language.localized(
                "Creates the folder in \(session.remotePath.nilIfBlank ?? "~").",
                "在 \(session.remotePath.nilIfBlank ?? "~") 中创建文件夹。"
            ))
        }
        .alert(language.localized("Rename", "重命名"), isPresented: $isRenaming) {
            TextField(language.localized("New name", "新名称"), text: $workspace.renameTargetName)
            Button(language.localized("Rename", "重命名")) {
                guard !workspace.renameTargetName.isBlank,
                      workspace.renameTargetName != selectedEntry?.name else { return }
                renameSelected()
            }
            Button(language.localized("Cancel", "取消"), role: .cancel) {}
        }
        .confirmationDialog(
            language.localized("Delete this remote item?", "删除此远程项目？"),
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: entryPendingDeletion
        ) { entry in
            Button(language.localized("Delete \(entry.displayName)", "删除 \(entry.displayName)"), role: .destructive) {
                entryPendingDeletion = nil
                delete(entry)
            }
            Button(language.localized("Cancel", "取消"), role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: { entry in
            Text(entry.isDirectory
                ? language.localized(
                    "The folder is removed from the server. This cannot be undone.",
                    "该文件夹将从服务器上删除，此操作无法撤销。"
                )
                : language.localized(
                    "The file is removed from the server. This cannot be undone.",
                    "该文件将从服务器上删除，此操作无法撤销。"
                ))
        }
    }

    private func beginRename(_ entry: RemoteFileEntry?) {
        guard let entry else { return }
        workspace.selectedEntryID = entry.id
        workspace.renameTargetName = entry.name
        isRenaming = true
    }

    @ViewBuilder
    private var transferQueueView: some View {
        if !sessionTransferHistory.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        isTransferHistoryPresented.toggle()
                    } label: {
                        Label(language.localized("Transfer Queue", "传输队列"), systemImage: "arrow.up.arrow.down.circle")
                            .font(.caption.weight(.semibold))
	                    }
	                    .buttonStyle(.plain)

	                    Spacer()

                    Button {
                        isTransferHistoryPresented.toggle()
                    } label: {
                        Text(transferHistorySummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
	                    }
	                    .buttonStyle(.plain)
	                }
	                .popover(isPresented: $isTransferHistoryPresented, arrowEdge: .bottom) {
	                    transferHistoryPopover
	                }

	                if visibleTransferQueueTasks.isEmpty {
                    Text(language.localized(
                        "No active transfers. Click Transfer Queue to view this server's transfer history.",
                        "当前没有进行中的传输。点击“传输队列”查看此服务器的传输记录。"
                    ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    ForEach(visibleTransferQueueTasks) { task in
                        transferQueueRow(task)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(.bar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var transferHistorySummary: String {
        let completedDownloads = sessionTransferHistory.filter { $0.direction == .download && $0.status == .succeeded }.count
        let active = visibleTransferQueueTasks.count

        if active > 0 {
            return language.localized(
                "\(active) active · \(sessionTransferHistory.count) history",
                "\(active) 个进行中 · \(sessionTransferHistory.count) 条记录"
            )
        }

        if completedDownloads > 0 {
            return language.localized("\(completedDownloads) downloaded", "已下载 \(completedDownloads) 个")
        }

        return language.localized(
            "\(sessionTransferHistory.count) history",
            "\(sessionTransferHistory.count) 条记录"
        )
    }

    private func transferQueueRow(_ task: RemoteTransferTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: transferIcon(for: task))
                .foregroundStyle(transferColor(for: task))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(transferDirectionLabel(task.direction)): \(task.displayName)")
                    .font(.caption)
                    .lineLimit(1)
                Text(task.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if task.status != .succeeded, let progressFraction = task.progressFraction {
                    ProgressView(value: progressFraction)
                        .controlSize(.small)
                        .help(task.progressLabel)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(transferStatusLabel(for: task))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(transferColor(for: task))
                Text(task.progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if canResumeTransfer(task) {
                Button(language.localized("Resume", "继续")) {
                    transferQueueManager.enqueue(task, session: session, context: modelContext)
                }
                .disabled(!session.isConnectable)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(task.lastError.nilIfBlank ?? task.summary)
    }

    private var transferHistoryPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.localized("Transfer History", "传输记录"))
                        .font(.headline)
                    Text(session.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(sessionTransferHistory.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            if sessionTransferHistory.isEmpty {
                ContentUnavailableView(
                    language.localized("No Transfer History", "暂无传输记录"),
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text(language.localized(
                        "Downloads and uploads for this server will appear here.",
                        "此服务器的下载和上传会显示在这里。"
                    ))
                )
                .frame(width: 420, height: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(sessionTransferHistory) { task in
                            transferHistoryRow(task)
                        }
                    }
                }
                .frame(width: 520, height: 320)
            }
        }
        .padding(14)
    }

    private func transferHistoryRow(_ task: RemoteTransferTask) -> some View {
        HStack(spacing: 9) {
            Image(systemName: transferIcon(for: task))
                .foregroundStyle(transferColor(for: task))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(transferDirectionLabel(task.direction)): \(task.displayName)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(task.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(transferTimestamp(for: task))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(transferStatusLabel(for: task))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(transferColor(for: task))
                Text(task.progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if task.direction == .download, task.status == .succeeded {
                Button {
                    revealTransfer(task)
                } label: {
                    Label(language.localized("Reveal", "显示"), systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .help(language.localized("Reveal in Finder", "在访达中显示"))
            }

            if canResumeTransfer(task) {
                Button(language.localized("Resume", "继续")) {
                    transferQueueManager.enqueue(task, session: session, context: modelContext)
                }
                .disabled(!session.isConnectable)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var pathHint: String {
        let path = session.remotePath.nilIfBlank ?? "~"
        return language.localized(
            "Current remote path: \(path). Double-click folders to navigate, or files to download and open a local edit copy.",
            "当前远程路径：\(path)。双击文件夹进入，双击文件可下载并打开本地编辑副本。"
        )
    }

    private var statusText: String {
        let path = session.remotePath.nilIfBlank ?? "~"
        if workspace.entries.isEmpty {
            if loadedEmptyDirectory {
                return language.localized(
                    "0 entries · 0 folders · 0 files · \(path)",
                    "0 项 · 0 个文件夹 · 0 个文件 · \(path)"
                )
            }

            let output = workspace.result?.displayText.nilIfBlank
            return output.map {
                language.localized(
                    "No file rows parsed from \(path). Last output: \($0)",
                    "未能从 \(path) 解析出文件。最后输出：\($0)"
                )
            } ?? language.localized("No entries loaded from \(path).", "尚未从 \(path) 读取到项目。")
        }

        let folders = workspace.entries.filter(\.isDirectory).count
        let files = workspace.entries.filter(\.isRegularFile).count
        return language.localized(
            "\(workspace.entries.count) entries · \(folders) folders · \(files) files · \(path)",
            "\(workspace.entries.count) 项 · \(folders) 个文件夹 · \(files) 个文件 · \(path)"
        )
    }

    private var loadedEmptyDirectory: Bool {
        workspace.entries.isEmpty &&
        workspace.errorMessage == nil &&
        workspace.hasLoadedCurrentDirectory(for: session) &&
        (workspace.result?.succeeded == true)
    }

    private var emptyDirectoryTitle: String {
        loadedEmptyDirectory
            ? language.localized("Empty Folder", "空文件夹")
            : language.localized("No Files Loaded", "尚未加载文件")
    }

    private var emptyDirectoryDescription: String {
        if let errorMessage = workspace.errorMessage {
            return errorMessage
        }

        if loadedEmptyDirectory {
            return language.localized(
                "The current path has no files or folders.",
                "当前路径下没有文件或文件夹。"
            )
        }

        return language.localized(
            "Refresh the current path or check Server Properties.",
            "请刷新当前路径，或检查服务器属性。"
        )
    }

    private func matchesCurrentDestination(
        connection: RemoteSession,
        path: String
    ) -> Bool {
        SSHSessionLaunchSnapshot(session: session)
            == SSHSessionLaunchSnapshot(session: connection)
            && session.remotePath == path
    }

    private func listDirectory() {
        guard session.isConnectable else { return }
        let connection = SSHSessionLaunchSnapshot(session: session).materializedSession()
        let requestedPath = session.remotePath
        let operationID = workspace.beginOperation()
        workspace.operationMessage = language.localized(
            "Loading \(requestedPath.nilIfBlank ?? "~")…",
            "正在加载 \(requestedPath.nilIfBlank ?? "~")…"
        )
        workspace.errorMessage = nil

        Task {
            do {
                let sftpResult = try await sftpTransport.listDirectory(
                    session: connection,
                    path: requestedPath
                )
                var loadedEntries = RemoteSFTPFileListParser.parse(sftpResult.standardOutput)
                var resolvedResult = sftpResult
                var resolvedMessage: String?

                if RemoteSFTPTransport.shouldAttemptSSHListingFallback(result: sftpResult, parsedEntries: loadedEntries) {
                    let fallback = try await remoteCommandRunner.runSSH(
                        session: connection,
                        remoteCommand: SSHCommandBuilder.structuredDirectoryListingCommand(path: requestedPath)
                    )
                    let fallbackEntries = RemoteStructuredFileListParser.parse(fallback.standardOutput)
                    if fallback.succeeded {
                        resolvedResult = fallback
                        loadedEntries = fallbackEntries
                        resolvedMessage = language.localized(
                            "Loaded \(fallbackEntries.count) remote entries over SSH fallback.",
                            "已通过 SSH 备用方式加载 \(fallbackEntries.count) 个远程项目。"
                        )
                    } else if sftpResult.succeeded {
                        resolvedResult = fallback
                    }
                }

                guard workspace.isCurrentOperation(operationID) else { return }
                guard matchesCurrentDestination(connection: connection, path: requestedPath) else {
                    workspace.finishOperation(operationID)
                    return
                }

                workspace.selectedEntryID = nil
                workspace.result = resolvedResult
                if sftpResult.succeeded || resolvedResult.succeeded {
                    workspace.entries = loadedEntries
                    workspace.errorMessage = nil
                    workspace.markLoaded(session: connection, path: requestedPath)
                    workspace.operationMessage = resolvedMessage
                        ?? language.localized(
                            "Loaded \(workspace.entries.count) remote entries over SFTP.",
                            "已通过 SFTP 加载 \(workspace.entries.count) 个远程项目。"
                        )
                } else {
                    workspace.entries = []
                    workspace.errorMessage = RemoteSFTPTransport.failureMessage(for: sftpResult)
                    workspace.operationMessage = language.localized("SFTP listing failed.", "SFTP 列表读取失败。")
                    workspace.markLoaded(session: connection, path: requestedPath)
                }
            } catch {
                guard workspace.isCurrentOperation(operationID) else { return }
                guard matchesCurrentDestination(connection: connection, path: requestedPath) else {
                    workspace.finishOperation(operationID)
                    return
                }
                workspace.errorMessage = error.localizedDescription
                workspace.markLoaded(session: connection, path: requestedPath)
            }
            workspace.finishOperation(operationID)
        }
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.isDirectory {
            if entry.name == ".." {
                goToParent()
            } else if session.remotePath.hasSuffix("/") {
                session.remotePath += entry.name
            } else {
                session.remotePath += "/\(entry.name)"
            }

            listDirectory()
        } else if entry.isRegularFile {
            openForEditing(entry)
        }
    }

    private func goToParent() {
        let path = session.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path != "~", path != "/" else {
            session.remotePath = "~"
            listDirectory()
            return
        }

        session.remotePath = parentPath(for: path)
        listDirectory()
    }

    private func makeDirectory() {
        let connection = SSHSessionLaunchSnapshot(session: session).materializedSession()
        let folderName = workspace.newFolderName
        let targetPath = remotePath(name: folderName, in: session.remotePath)
        runSFTPOperation(
            message: language.localized("Creating folder \(folderName)…", "正在创建文件夹 \(folderName)…"),
            connectionKey: connection.connectionKey
        ) {
            try await sftpTransport.makeDirectory(session: connection, path: targetPath)
        }
    }

    private func deleteSelected() {
        guard let selectedEntry else { return }
        delete(selectedEntry)
    }

    private func delete(_ entry: RemoteFileEntry) {
        let connection = SSHSessionLaunchSnapshot(session: session).materializedSession()
        let targetPath = remotePath(name: entry.name, in: session.remotePath)
        runSFTPOperation(
            message: language.localized("Deleting \(entry.name)…", "正在删除 \(entry.name)…"),
            connectionKey: connection.connectionKey
        ) {
            if entry.isDirectory {
                return try await sftpTransport.removeDirectory(session: connection, path: targetPath)
            }
            return try await sftpTransport.removeFile(session: connection, path: targetPath)
        }
    }

    private func renameSelected() {
        guard let selectedEntry else { return }
        let connection = SSHSessionLaunchSnapshot(session: session).materializedSession()
        let currentPath = session.remotePath
        let sourcePath = remotePath(name: selectedEntry.name, in: currentPath)
        let renameTargetName = workspace.renameTargetName
        let targetPath = remotePath(name: renameTargetName, in: currentPath)
        runSFTPOperation(
            message: language.localized("Renaming \(selectedEntry.name)…", "正在重命名 \(selectedEntry.name)…"),
            connectionKey: connection.connectionKey
        ) {
            try await sftpTransport.rename(
                session: connection,
                oldPath: sourcePath,
                newPath: targetPath
            )
        }
    }

    private func uploadIntoCurrentDirectory() {
        chooseAndUpload(into: session.remotePath)
    }

    private func uploadIntoDirectory(_ entry: RemoteFileEntry) {
        guard entry.isDirectory else {
            uploadIntoCurrentDirectory()
            return
        }

        chooseAndUpload(into: joinRemotePath(entry.name))
    }

    private func chooseAndUpload(into remoteDirectory: String) {
        guard session.isConnectable, !workspace.isRunning else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = language.localized("Upload", "上传")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let remoteDestination = SSHCommandBuilder.remotePath(directory: remoteDirectory, name: url.lastPathComponent)

        let transfer = RemoteTransferTask(
            session: session,
            direction: .upload,
            remotePath: remoteDestination,
            localPath: url.path,
            recursive: isDirectory.boolValue,
            resumeSupported: !isDirectory.boolValue,
            expectedByteCount: isDirectory.boolValue ? nil : localFileSize(at: url.path),
            localSecurityScopedBookmark: RemoteTransferTask.securityScopedBookmark(for: url)
        )
        modelContext.insert(transfer)
        try? modelContext.save()
        transferQueueManager.enqueue(transfer, session: session, context: modelContext)
        workspace.operationMessage = language.localized(
            "Queued upload \(url.lastPathComponent).",
            "已加入上传队列：\(url.lastPathComponent)。"
        )
        workspace.errorMessage = nil
    }

    private func downloadSelected() {
        guard let selectedEntry else { return }
        download(selectedEntry)
    }

    private func download(_ entry: RemoteFileEntry) {
        guard session.isConnectable, !workspace.isRunning else { return }

        let remoteSource = joinRemotePath(entry.name)
        let recursive = entry.isDirectory
        let localDestinationURL: URL?

        if recursive {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = language.localized("Download", "下载")
            localDestinationURL = panel.runModal() == .OK ? panel.url : nil
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            panel.prompt = language.localized("Download", "下载")
            localDestinationURL = panel.runModal() == .OK ? panel.url : nil
        }

        guard let localDestinationURL else { return }

        let transfer = RemoteTransferTask(
            session: session,
            direction: .download,
            remotePath: remoteSource,
            localPath: localDestinationURL.path,
            recursive: recursive,
            resumeSupported: !recursive,
            expectedByteCount: recursive ? nil : entry.byteSize,
            localSecurityScopedBookmark: RemoteTransferTask.securityScopedBookmark(for: localDestinationURL)
        )
        modelContext.insert(transfer)
        try? modelContext.save()
        transferQueueManager.enqueue(transfer, session: session, context: modelContext)
        workspace.operationMessage = language.localized(
            "Queued download \(entry.name).",
            "已加入下载队列：\(entry.name)。"
        )
        workspace.errorMessage = nil
    }

    private func openSelectedForEditing() {
        guard let selectedEntry, selectedEntry.isRegularFile else { return }
        openForEditing(selectedEntry)
    }

    private func openForEditing(_ entry: RemoteFileEntry) {
        guard session.isConnectable, entry.isRegularFile, !workspace.isRunning else { return }

        let connection = SSHSessionLaunchSnapshot(session: session).materializedSession()
        let remoteSource = remotePath(name: entry.name, in: session.remotePath)
        let entryName = entry.name
        let operationID = workspace.beginOperation()
        workspace.operationMessage = language.localized(
            "Preparing editable copy of \(entry.name)…",
            "正在准备 \(entry.name) 的编辑副本…"
        )
        workspace.errorMessage = nil

        Task {
            var draftToCleanUp: RemoteEditDraft?
            do {
                let draft = try RemoteEditWorkspace.makeDraft(
                    sessionKey: connection.connectionKey,
                    remotePath: remoteSource
                )
                draftToCleanUp = draft
                let downloadResult = try await sftpTransport.download(
                    session: connection,
                    remotePath: remoteSource,
                    localPath: draft.localURL.path
                )
                guard workspace.isCurrentOperation(operationID) else {
                    removeLocalEditDraft(draft)
                    return
                }
                workspace.result = downloadResult

                guard downloadResult.succeeded else {
                    workspace.errorMessage = downloadResult.displayText
                    workspace.operationMessage = language.localized(
                        "Could not open editable copy for \(entryName).",
                        "无法打开 \(entryName) 的编辑副本。"
                    )
                    removeLocalEditDraft(draft)
                    workspace.finishOperation(operationID)
                    return
                }

                workspace.editDraft = draft
                draftToCleanUp = nil
                NSWorkspace.shared.open(draft.localURL)
                workspace.operationMessage = language.localized(
                    "Opened editable copy. Save it locally, then choose More → Sync Edited Copy.",
                    "已打开编辑副本。在本地保存后，选择“更多 → 同步编辑副本”。"
                )
            } catch {
                guard workspace.isCurrentOperation(operationID) else {
                    if let draftToCleanUp { removeLocalEditDraft(draftToCleanUp) }
                    return
                }
                if let draftToCleanUp { removeLocalEditDraft(draftToCleanUp) }
                workspace.errorMessage = error.localizedDescription
            }
            workspace.finishOperation(operationID)
        }
    }

    private func uploadEditedCopy() {
        guard let editDraft = workspace.editDraft else { return }
        guard FileManager.default.fileExists(atPath: editDraft.localURL.path) else {
            workspace.errorMessage = language.localized(
                "Local edit copy no longer exists: \(editDraft.localURL.path)",
                "本地编辑副本已不存在：\(editDraft.localURL.path)"
            )
            return
        }
        let connection = SSHSessionLaunchSnapshot(session: session).materializedSession()
        guard connection.connectionKey == editDraft.sessionKey else {
            workspace.errorMessage = language.localized(
                "This edit copy belongs to the server identity that originally downloaded it. The profile has changed; open a new editable copy before uploading.",
                "此编辑副本属于最初下载它的服务器身份。配置已更改，请重新打开编辑副本后再上传。"
            )
            return
        }

        let operationID = workspace.beginOperation()
        workspace.operationMessage = language.localized(
            "Uploading edited copy of \(editDraft.remoteName)…",
            "正在上传 \(editDraft.remoteName) 的编辑副本…"
        )
        workspace.errorMessage = nil

        Task {
            do {
                let uploadResult = try await sftpTransport.upload(
                    session: connection,
                    localPath: editDraft.localURL.path,
                    remotePath: editDraft.remotePath
                )
                guard workspace.isCurrentOperation(operationID) else { return }
                workspace.result = uploadResult

                if uploadResult.succeeded {
                    workspace.operationMessage = language.localized(
                        "Uploaded edited copy to \(editDraft.remotePath).",
                        "已将编辑副本上传到 \(editDraft.remotePath)。"
                    )
                    workspace.finishOperation(operationID)
                    listDirectory()
                    return
                }

                workspace.errorMessage = uploadResult.displayText
                workspace.operationMessage = language.localized("Could not upload edited copy.", "无法上传编辑副本。")
            } catch {
                guard workspace.isCurrentOperation(operationID) else { return }
                workspace.errorMessage = error.localizedDescription
            }
            workspace.finishOperation(operationID)
        }
    }

    private func revealEditedCopy() {
        guard let editDraft = workspace.editDraft else { return }
        NSWorkspace.shared.activateFileViewerSelecting([editDraft.localURL])
    }

    @ViewBuilder
    private func fileContextMenu(for entry: RemoteFileEntry) -> some View {
        if entry.isDirectory {
            Button {
                open(entry)
            } label: {
                Label(language.localized("Open Folder", "打开文件夹"), systemImage: "folder")
            }

            Button {
                uploadIntoDirectory(entry)
            } label: {
                Label(language.localized("Upload Here…", "上传到此处…"), systemImage: "square.and.arrow.up")
            }

            Button {
                download(entry)
            } label: {
                Label(language.localized("Download Folder…", "下载文件夹…"), systemImage: "square.and.arrow.down")
            }
        } else {
            Button {
                openForEditing(entry)
            } label: {
                Label(language.localized("Open Editable Copy", "打开编辑副本"), systemImage: "pencil.and.outline")
            }
            .disabled(!entry.isRegularFile)

            Button {
                download(entry)
            } label: {
                Label(language.localized("Download…", "下载…"), systemImage: "square.and.arrow.down")
            }
            .disabled(!entry.isRegularFile)
        }

        Divider()

        Button {
            uploadIntoCurrentDirectory()
        } label: {
            Label(language.localized("Upload to Current Folder…", "上传到当前文件夹…"), systemImage: "arrow.up.doc")
        }

        Button {
            copyRemotePath(for: entry)
        } label: {
            Label(language.localized("Copy Remote Path", "拷贝远程路径"), systemImage: "doc.on.doc")
        }

        Button {
            beginRename(entry)
        } label: {
            Label(language.localized("Rename…", "重命名…"), systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            entryPendingDeletion = entry
        } label: {
            Label(language.localized("Delete…", "删除…"), systemImage: "trash")
        }
    }

    private func copyRemotePath(for entry: RemoteFileEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joinRemotePath(entry.name), forType: .string)
    }

    private func runSFTPOperation(
        message: String,
        connectionKey: String,
        operation: @escaping () async throws -> CommandResult
    ) {
        guard session.isConnectable else { return }
        let operationID = workspace.beginOperation()
        workspace.operationMessage = message
        workspace.errorMessage = nil

        Task {
            do {
                let operationResult = try await operation()
                guard workspace.isCurrentOperation(operationID) else { return }
                workspace.result = operationResult
                workspace.finishOperation(operationID)
                if session.connectionKey == connectionKey {
                    listDirectory()
                }
            } catch {
                guard workspace.isCurrentOperation(operationID) else { return }
                workspace.errorMessage = error.localizedDescription
                workspace.finishOperation(operationID)
            }
        }
    }

    private func joinRemotePath(_ name: String) -> String {
        remotePath(name: name, in: session.remotePath)
    }

    private func remotePath(name: String, in directory: String) -> String {
        SSHCommandBuilder.remotePath(directory: directory, name: name)
    }

    private func removeLocalEditDraft(_ draft: RemoteEditDraft) {
        try? FileManager.default.removeItem(at: draft.localURL.deletingLastPathComponent())
    }

    private func parentPath(for path: String) -> String {
        if path.hasPrefix("~/") {
            let remainder = String(path.dropFirst(2))
            guard remainder.contains("/") else { return "~" }
            return "~/" + (remainder as NSString).deletingLastPathComponent
        }

        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "~" : parent
    }

    private func localFileSize(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber else {
            return nil
        }
        return fileSize.int64Value
    }

    private func iconName(for entry: RemoteFileEntry) -> String {
        if entry.isDirectory {
            return "folder.fill"
        }

        if entry.isSymbolicLink {
            return "link"
        }

        return "doc"
    }

    private func iconColor(for entry: RemoteFileEntry) -> Color {
        if entry.isDirectory {
            return .accentColor
        }

        if entry.isSymbolicLink {
            return .cyan
        }

        return .secondary
    }

    private func transferIcon(for task: RemoteTransferTask) -> String {
        if transferQueueManager.isActive(task) {
            return "arrow.triangle.2.circlepath"
        }

        if task.status == .running {
            return "pause.circle.fill"
        }

        switch task.status {
        case .queued:
            return "clock"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "pause.circle.fill"
        }
    }

    private func transferColor(for task: RemoteTransferTask) -> Color {
        if transferQueueManager.isActive(task) {
            return .blue
        }

        if task.status == .running {
            return .orange
        }

        switch task.status {
        case .queued:
            return .secondary
        case .running:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private func transferStatusLabel(for task: RemoteTransferTask) -> String {
        if transferQueueManager.isActive(task) {
            return language.localized("Running", "进行中")
        }

        if task.status == .running {
            return language.localized("Interrupted", "已中断")
        }

        switch task.status {
        case .queued:
            return language.localized("Queued", "排队中")
        case .running:
            return language.localized("Running", "进行中")
        case .succeeded:
            return language.localized("Done", "完成")
        case .failed:
            return language.localized("Failed", "失败")
        case .cancelled:
            return language.localized("Cancelled", "已取消")
        }
    }

    private func transferDirectionLabel(_ direction: RemoteTransferDirection) -> String {
        switch direction {
        case .download:
            return language.localized("Download", "下载")
        case .upload:
            return language.localized("Upload", "上传")
        }
    }

    private func transferTimestamp(for task: RemoteTransferTask) -> String {
        let date = task.finishedAt ?? task.startedAt ?? task.createdAt
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func revealTransfer(_ task: RemoteTransferTask) {
        let url = URL(fileURLWithPath: (task.localPath as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func canResumeTransfer(_ task: RemoteTransferTask) -> Bool {
        task.status.canResume || (task.status == .running && !transferQueueManager.isActive(task))
    }
}

private struct TunnelPanel: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedSSHTunnel.updatedAt, order: .reverse) private var savedTunnels: [SavedSSHTunnel]
    let session: RemoteSession
    @ObservedObject var manager: SSHTunnelManager
    @State private var configuration = SSHTunnelConfiguration()
    @State private var selectedSavedTunnelID: PersistentIdentifier?

    private var sessionTunnels: [SavedSSHTunnel] {
        savedTunnels.filter { $0.sessionConnectionKey == session.connectionKey }
    }

    private var validationMessage: String? {
        configuration.validationMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle(language.localized("SSH Tunnels", "SSH 隧道"))
                Spacer()
                if manager.isRunning || manager.isReconnectScheduled {
                    Button(role: .destructive) {
                        manager.stop()
                    } label: {
                        Label(
                            manager.isReconnectScheduled
                                ? language.localized("Cancel Reconnect", "取消重连")
                                : language.localized("Stop", "停止"),
                            systemImage: "stop.fill"
                        )
                    }
                } else {
                    Button {
                        manager.start(session: session, configuration: configuration)
                    } label: {
                        Label(language.localized("Start Tunnel", "启动隧道"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.isConnectable || validationMessage != nil)
                }
            }

            if !sessionTunnels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.localized("Saved tunnel profiles", "已保存的隧道配置"))
                        .font(.headline)

                    ForEach(sessionTunnels) { tunnel in
                        HStack {
                            Button {
                                load(tunnel)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tunnel.name)
                                        .font(.headline)
                                    Text(tunnel.configuration.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if tunnel.configuration.autoReconnect {
                                        Label(language.localized("Auto reconnect", "自动重连"), systemImage: "arrow.clockwise")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            if selectedSavedTunnelID == tunnel.persistentModelID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.teal)
                            }

                            Button(role: .destructive) {
                                delete(tunnel)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(language.localized("Delete saved tunnel profile", "删除已保存的隧道配置"))
                            .accessibilityLabel(language.localized("Delete saved tunnel profile", "删除已保存的隧道配置"))
                        }
                        .padding(10)
                        .background(
                            selectedSavedTunnelID == tunnel.persistentModelID ? .teal.opacity(0.12) : .black.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                }
            }

            HStack {
                TextField(language.localized("Name", "名称"), text: $configuration.name)
                Picker(language.localized("Kind", "类型"), selection: $configuration.kind) {
                    ForEach(SSHTunnelKind.allCases) { kind in
                        Text(tunnelKindTitle(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack {
                TextField(language.localized("Bind address", "绑定地址"), text: $configuration.bindAddress)
                TextField(language.localized("Local port", "本地端口"), value: $configuration.localPort, format: .number.grouping(.never))
                    .frame(width: 110)
            }

            if configuration.kind != .dynamic {
                HStack {
                    TextField(language.localized("Destination host", "目标主机"), text: $configuration.destinationHost)
                    TextField(language.localized("Destination port", "目标端口"), value: $configuration.destinationPort, format: .number.grouping(.never))
                        .frame(width: 130)
                }
            }

            Toggle(language.localized("Auto reconnect if the tunnel drops", "隧道断开时自动重连"), isOn: $configuration.autoReconnect)
                .font(.callout)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label(
                    configuration.supportsLocalReadinessCheck
                        ? language.localized(
                            "Readiness check will probe \(configuration.localEndpointSummary) after startup.",
                            "启动后会探测 \(configuration.localEndpointSummary) 以确认隧道就绪。"
                        )
                        : language.localized(
                            "Remote tunnels start on the server side and cannot be probed locally.",
                            "远程隧道在服务器端启动，无法在本地探测。"
                        ),
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    saveCurrent()
                } label: {
                    Label(
                        selectedSavedTunnelID == nil
                            ? language.localized("Save Tunnel Profile", "保存隧道配置")
                            : language.localized("Update Saved Profile", "更新已保存配置"),
                        systemImage: "tray.and.arrow.down.fill"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!session.isConnectable || validationMessage != nil)

                Button {
                    selectedSavedTunnelID = nil
                    configuration = SSHTunnelConfiguration()
                } label: {
                    Label(language.localized("New Profile", "新建配置"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            Label(manager.lastMessage, systemImage: manager.isRunning ? "circle.fill" : "circle.dashed")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(manager.isRunning ? Color.green : (manager.isReconnectScheduled ? Color.orange : Color.secondary))
                .textSelection(.enabled)
        }
        .padding(20)
        .panelBackground()
        .onAppear {
            if let activeConfiguration = manager.activeConfiguration {
                configuration = activeConfiguration
            }
        }
    }

    private func load(_ tunnel: SavedSSHTunnel) {
        configuration = tunnel.configuration
        selectedSavedTunnelID = tunnel.persistentModelID
    }

    private func tunnelKindTitle(_ kind: SSHTunnelKind) -> String {
        switch kind {
        case .local:
            return language.localized("Local", "本地")
        case .remote:
            return language.localized("Remote", "远程")
        case .dynamic:
            return language.localized("Dynamic SOCKS", "动态 SOCKS")
        }
    }

    private func saveCurrent() {
        if let selectedSavedTunnelID,
           let tunnel = sessionTunnels.first(where: { $0.persistentModelID == selectedSavedTunnelID }) {
            tunnel.update(from: configuration, session: session)
        } else {
            let tunnel = SavedSSHTunnel(session: session, configuration: configuration)
            modelContext.insert(tunnel)
            selectedSavedTunnelID = tunnel.persistentModelID
        }
    }

    private func delete(_ tunnel: SavedSSHTunnel) {
        if selectedSavedTunnelID == tunnel.persistentModelID {
            selectedSavedTunnelID = nil
        }
        modelContext.delete(tunnel)
    }
}

private struct EmbeddedSSHPanel: View {
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    let title: String
    @ObservedObject var terminalWorkspace: TerminalWorkspaceState
    let sessions: [RemoteSession]
    @ObservedObject var terminalWorkspaceStore: TerminalWorkspaceStore
    @ObservedObject var terminalBroadcastCoordinator: TerminalBroadcastCoordinator
    let autoStart: Bool
    @State private var terminalViewportSize = CGSize.zero

    init(
        session: RemoteSession,
        title: String = "PTY Terminal",
        initialKind: TerminalWorkspaceState.Kind = .ssh,
        terminalWorkspace: TerminalWorkspaceState,
        sessions: [RemoteSession],
        terminalWorkspaceStore: TerminalWorkspaceStore,
        terminalBroadcastCoordinator: TerminalBroadcastCoordinator,
        autoStart: Bool = false
    ) {
        self.session = session
        self.title = title
        self.terminalWorkspace = terminalWorkspace
        self.sessions = sessions
        self.terminalWorkspaceStore = terminalWorkspaceStore
        self.terminalBroadcastCoordinator = terminalBroadcastCoordinator
        self.autoStart = autoStart
        _ = initialKind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TerminalTabStrip(
                    session: session,
                    workspace: terminalWorkspace
                )
                .frame(minWidth: 112)

                Spacer(minLength: 8)

                adaptiveToolbarActions
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.bar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let tab = terminalWorkspace.selectedTab {
                TerminalTabView(
                    session: session,
                    workspace: terminalWorkspace,
                    tab: tab,
                    autoStart: autoStart,
                    viewportSizeDidChange: { terminalViewportSize = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TerminalBlankPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var adaptiveToolbarActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                multiExecButton
                splitMenu
                newTabMenu(compact: false)
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 6) {
                compactTerminalActionsMenu
                newTabMenu(compact: true)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var multiExecButton: some View {
        Button(action: openMultiExec) {
            Label(
                language.localized("Multi-Exec", "批量执行"),
                systemImage: "rectangle.3.group.bubble"
            )
        }
        .buttonStyle(.bordered)
        .help(multiExecHelpText)
        .accessibilityIdentifier("terminal-multi-exec-button")
    }

    private var splitMenu: some View {
        Menu {
            splitActions
        } label: {
            Label(language.localized("Split", "分屏"), systemImage: "rectangle.split.2x1")
        }
        .menuStyle(.button)
        .disabled(terminalWorkspace.selectedPane == nil)
        .help(splitMenuHelpText)
        .accessibilityIdentifier("terminal-split-menu")
    }

    private var compactTerminalActionsMenu: some View {
        Menu {
            Button(action: openMultiExec) {
                Label(
                    language.localized("Multi-Exec", "批量执行"),
                    systemImage: "rectangle.3.group.bubble"
                )
            }
            .accessibilityIdentifier("terminal-multi-exec-button")

            Divider()
            splitActions
        } label: {
            Label(
                language.localized("Terminal Actions", "终端操作"),
                systemImage: "ellipsis.circle"
            )
            .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .help(language.localized(
            "Multi-Exec and split-pane actions.",
            "批量执行和终端分屏操作。"
        ))
        .accessibilityLabel(language.localized("Terminal Actions", "终端操作"))
        .accessibilityIdentifier("terminal-compact-actions-menu")
    }

    @ViewBuilder
    private var splitActions: some View {
        Button {
            _ = terminalWorkspace.splitSelectedPane(
                axis: .horizontal,
                availableSize: terminalViewportSize
            )
        } label: {
            Label(
                language.localized("Split Right", "向右分屏"),
                systemImage: "rectangle.split.2x1"
            )
        }
        .disabled(!canSplit(.horizontal))
        .help(splitActionHelp(.horizontal))
        .accessibilityIdentifier("terminal-split-right-button")

        Button {
            _ = terminalWorkspace.splitSelectedPane(
                axis: .vertical,
                availableSize: terminalViewportSize
            )
        } label: {
            Label(
                language.localized("Split Below", "向下分屏"),
                systemImage: "rectangle.split.1x2"
            )
        }
        .disabled(!canSplit(.vertical))
        .help(splitActionHelp(.vertical))
        .accessibilityIdentifier("terminal-split-below-button")

        Divider()

        Button(role: .destructive) {
            terminalWorkspace.closeFocusedPane()
        } label: {
            Label(
                language.localized("Close Active Pane", "关闭当前窗格"),
                systemImage: "xmark.rectangle"
            )
        }
        .disabled(terminalWorkspace.selectedPane == nil)
        .accessibilityIdentifier("terminal-close-active-pane-button")
    }

    private func newTabMenu(compact: Bool) -> some View {
        Menu {
            Button {
                terminalWorkspace.addTab(kind: .ssh)
            } label: {
                Label(
                    language.localized("New SSH Tab", "新建 SSH 标签页"),
                    systemImage: "terminal.fill"
                )
            }
            .disabled(session.connectionType != .ssh || !session.isConnectable)

            Button {
                terminalWorkspace.addTab(kind: .localShell)
            } label: {
                Label(
                    language.localized("New Local Shell Tab", "新建本地 Shell 标签页"),
                    systemImage: "apple.terminal"
                )
            }
        } label: {
            if compact {
                Label(language.localized("New Tab", "新建标签页"), systemImage: "plus")
                    .labelStyle(.iconOnly)
            } else {
                Label(language.localized("New Tab", "新建标签页"), systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
        }
        .help(language.localized("Open a new terminal tab.", "新建终端标签页。"))
        .accessibilityLabel(language.localized("New Tab", "新建标签页"))
        .accessibilityIdentifier("terminal-new-tab-menu")
    }

    private func openMultiExec() {
        terminalBroadcastCoordinator.open(
            targets: terminalWorkspaceStore.broadcastTargets(sessions: sessions)
        )
    }

    private var multiExecHelpText: String {
        language.localized(
            "Review one command and run it in two or more terminal panes that you explicitly marked Ready.",
            "审阅一条命令，并在两个或更多已明确标记为“就绪”的终端窗格中执行。"
        )
    }

    private var splitMenuHelpText: String {
        canSplit(.horizontal) || canSplit(.vertical)
            ? language.localized(
                "Split the active terminal pane where the current workspace has room.",
                "在当前工作区空间允许时拆分活动终端窗格。"
            )
            : terminalWorkspace.canSplitSelectedPane
                ? language.localized(
                    "Enlarge the terminal workspace to create another pane.",
                    "请放大终端工作区后再创建窗格。"
                )
                : language.localized(
                    "This tab already has the maximum number of panes.",
                    "当前标签页已达到窗格数量上限。"
                )
    }

    private func canSplit(
        _ axis: TerminalWorkspaceState.SplitAxis
    ) -> Bool {
        terminalWorkspace.canSplitSelectedPane(
            axis: axis,
            availableSize: terminalViewportSize
        )
    }

    private func splitActionHelp(
        _ axis: TerminalWorkspaceState.SplitAxis
    ) -> String {
        guard canSplit(axis) else {
            if !terminalWorkspace.canSplitSelectedPane {
                return language.localized(
                    "This tab already has the maximum number of panes.",
                    "当前标签页已达到窗格数量上限。"
                )
            }
            return language.localized(
                "The current terminal workspace is too small for this split direction.",
                "当前终端工作区空间不足，无法按此方向拆分。"
            )
        }
        switch axis {
        case .horizontal:
            return language.localized(
                "Split the active pane to the right.",
                "将活动窗格向右拆分。"
            )
        case .vertical:
            return language.localized(
                "Split the active pane below.",
                "将活动窗格向下拆分。"
            )
        }
    }
}

private struct TerminalBlankPane: View {
    @Environment(\.appLanguage) private var language

    var body: some View {
        Color(nsColor: TerminalCanvasView.backgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(language.localized("Blank terminal area", "空白终端区域"))
    }
}

private struct TerminalTabStrip: View {
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    @ObservedObject var workspace: TerminalWorkspaceState

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(workspace.tabs) { tab in
                    let isSelected = workspace.selectedTabID == tab.id
                    let title = tabTitle(for: tab)

                    TerminalTabChip(
                        title: title,
                        isSelected: isSelected,
                        canClose: true,
                        onSelect: {
                            workspace.selectedTabID = tab.id
                        },
                        onClose: {
                            if workspace.hasRunningProcesses(inTab: tab.id),
                               !confirmClosingRunningTab(title: title) {
                                return
                            }
                            workspace.closeTab(id: tab.id)
                        }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    /// Closing a window already asks before ending sessions; a tab close
    /// button is easier to hit by accident, so it asks as well.
    private func confirmClosingRunningTab(title: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = language.localized("Close “\(title)”?", "关闭“\(title)”？")
        alert.informativeText = language.localized(
            "The terminal session in this tab is still running. Closing the tab disconnects it.",
            "此标签页中的终端会话仍在运行，关闭标签页会断开连接。"
        )
        alert.addButton(withTitle: language.localized("Close Tab", "关闭标签页"))
        alert.addButton(withTitle: language.localized("Cancel", "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func tabTitle(for tab: TerminalWorkspaceState.Tab) -> String {
        guard let kind = tab.panes.first?.kind else {
            return language.localized("Terminal", "终端")
        }
        let baseTitle: String
        switch kind {
        case .ssh:
            baseTitle = session.host.nilIfBlank.map { "SSH: \($0)" } ?? "SSH"
        case .localShell:
            baseTitle = language.localized("Local", "本地")
        }
        guard tab.panes.count > 1 else { return baseTitle }
        return "\(baseTitle) · \(tab.panes.count)"
    }
}

private struct TerminalTabChip: View {
    @Environment(\.appLanguage) private var language
    let title: String
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHoveringClose = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onSelect) {
                Text(title)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityValue(
                isSelected
                    ? language.localized("Selected", "已选择")
                    : language.localized("Not selected", "未选择")
            )

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isHoveringClose ? .primary : .secondary)
                .opacity(isHoveringClose || isSelected ? 0.78 : 0.42)
                .accessibilityLabel(language.localized("Close tab", "关闭标签页"))
                .onHover { isHoveringClose = $0 }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .padding(.leading, 8)
        .padding(.trailing, canClose ? 5 : 8)
        .padding(.vertical, 3)
        .background(
            isSelected ? AppTheme.selectionStrong : AppTheme.surface,
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct TerminalTabView: View {
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    @ObservedObject var workspace: TerminalWorkspaceState
    let tab: TerminalWorkspaceState.Tab
    let autoStart: Bool
    let viewportSizeDidChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { geometry in
            splitNode(tab.layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    viewportSizeDidChange(geometry.size)
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewportSizeDidChange(newSize)
                }
        }
    }

    private func splitNode(_ node: TerminalWorkspaceState.LayoutNode) -> AnyView {
        switch node {
        case .pane(let paneID):
            guard let pane = tab.panes.first(where: { $0.id == paneID }) else {
                return AnyView(invalidLayoutPrompt)
            }
            return AnyView(
                terminalPane(pane)
                    .frame(
                        minWidth:
                            TerminalSplitLayoutPolicy.minimumPaneSize.width,
                        minHeight:
                            TerminalSplitLayoutPolicy.minimumPaneSize.height
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                workspace.selectedPane?.id == pane.id
                                    ? Color.accentColor
                                    : Color.clear,
                                lineWidth: 2
                            )
                            .allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(
                        "terminal-pane-\((tab.layout.paneIDs.firstIndex(of: pane.id) ?? 0) + 1)"
                    )
            )
        case .split(_, let axis, let first, let second):
            switch axis {
            case .horizontal:
                return AnyView(HSplitView {
                    splitNode(first)
                    splitNode(second)
                })
            case .vertical:
                return AnyView(VSplitView {
                    splitNode(first)
                    splitNode(second)
                })
            }
        }
    }

    @ViewBuilder
    private func terminalPane(_ pane: TerminalWorkspaceState.Pane) -> some View {
        if pane.kind.isAvailable(for: session.connectionType) {
            if let processSession = workspace.processSession(for: pane) {
                TerminalPaneView(
                session: session,
                kind: pane.kind,
                mcpPaneName: pane.mcpName,
                mcpPaneDisplayName: workspace.mcpDisplayName(for: pane, session: session),
                setMCPPaneName: { workspace.setMCPName($0, for: pane.id) },
                interactiveSession: processSession,
                autoStart: autoStart && pane.kind == TerminalWorkspaceState.Kind.preferredTerminalKind(for: session),
                swiftTermSurface: swiftTermSurface(for: pane),
                isFocused: workspace.selectedPane?.id == pane.id,
                onFocus: { [weak workspace] in
                    workspace?.focusPane(id: pane.id)
                }
                )
                .id(pane.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                invalidLayoutPrompt
            }
        } else {
            UnsupportedConnectionFeaturePrompt(
                feature: .command,
                connectionType: session.connectionType
            )
            .onAppear {
                workspace.stopProcess(for: pane)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var invalidLayoutPrompt: some View {
        ContentUnavailableView(
            language.localized("Terminal pane unavailable", "终端窗格不可用"),
            systemImage: "exclamationmark.triangle",
            description: Text(language.localized(
                "Close this tab and open a new one.",
                "请关闭此标签页并重新打开。"
            ))
        )
    }

    private func swiftTermSurface(for pane: TerminalWorkspaceState.Pane) -> AnyObject? {
        #if canImport(SwiftTerm)
        return workspace.terminalSurface(for: pane) {
            SwiftTermPersistentSurface()
        }
        #else
        return nil
        #endif
    }
}

enum TerminalGridMetrics {
    static let minimumColumns = 40
    static let minimumRows = 8
    static let preferredColumns = 80
    static let preferredRows = 12
    static let approximateCellWidth: CGFloat = 8
    static let approximateCellHeight: CGFloat = 16

    static var minimumPixelSize: CGSize {
        CGSize(
            width: CGFloat(minimumColumns) * approximateCellWidth,
            height: CGFloat(minimumRows) * approximateCellHeight
        )
    }

    static var preferredPixelSize: CGSize {
        CGSize(
            width: CGFloat(preferredColumns) * approximateCellWidth,
            height: CGFloat(preferredRows) * approximateCellHeight
        )
    }

    static func clampedGrid(columns: Int, rows: Int) -> (columns: Int, rows: Int) {
        (
            columns: max(columns, minimumColumns),
            rows: max(rows, minimumRows)
        )
    }

    static func clampedPixelSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width, minimumPixelSize.width),
            height: max(size.height, minimumPixelSize.height)
        )
    }
}

enum TerminalFollowOutputPolicy {
    static let bottomThreshold = 0.98

    static func shouldFollowOutput(
        currentlyFollowing: Bool,
        canScroll: Bool,
        scrollPosition: Double,
        fedText: String,
        isRefreshOnly: Bool = false
    ) -> Bool {
        guard shouldAutoScroll(after: fedText, isRefreshOnly: isRefreshOnly) else { return false }
        return currentlyFollowing || !canScroll || scrollPosition >= bottomThreshold
    }

    static func shouldFollowAfterUserScroll(position: Double) -> Bool {
        position >= bottomThreshold
    }

    static func shouldAutoScroll(after fedText: String, isRefreshOnly: Bool = false) -> Bool {
        guard !fedText.isEmpty else { return false }
        guard !isRefreshOnly else { return false }
        if fedText.contains("\n") { return true }
        return !fedText.contains("\r")
    }
}

enum TerminalOutputFeedPolicy {
    static func isRefreshOnly(_ fedText: String) -> Bool {
        fedText.contains("\r") && !fedText.contains("\n")
    }
}

enum TerminalRightClickAction: Equatable {
    case showCopyMenu
    case pasteClipboard
}

enum TerminalRightClickPolicy {
    static func action(selectedText: String?) -> TerminalRightClickAction {
        action(hasSelectedText: selectedText?.isEmpty == false)
    }

    static func action(hasSelectedText: Bool) -> TerminalRightClickAction {
        hasSelectedText ? .showCopyMenu : .pasteClipboard
    }
}

private struct TerminalPaneView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    let kind: TerminalWorkspaceState.Kind
    let mcpPaneName: String
    let mcpPaneDisplayName: String
    let setMCPPaneName: (String) -> Void
    @ObservedObject var interactiveSession: InteractiveProcessSession
    let autoStart: Bool
    let swiftTermSurface: AnyObject?
    let isFocused: Bool
    let onFocus: () -> Void

    @State private var didAutoStart = false
    @State private var hasMeasuredTerminalGrid = false
    @State private var pendingAutoStartWorkItem: DispatchWorkItem?
    @State private var mcpProfileSaveError = ""
    @State private var isShowingMCPNamePrompt = false
    @State private var pendingMCPPaneName = ""
    @State private var didCopyMCPPaneName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button(action: onFocus) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isFocused ? Color.accentColor : Color.secondary.opacity(0.45))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)

                            Text(paneTitle)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(isFocused ? .primary : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(language.localized("Make this the active pane", "将此窗格设为当前窗格"))
                    .accessibilityLabel(language.localized(
                        "Activate terminal pane \(paneTitle)",
                        "激活终端窗格 \(paneTitle)"
                    ))
                    .accessibilityAddTraits(isFocused ? .isSelected : [])
                    .accessibilityValue(
                        isFocused
                            ? language.localized("Active pane", "当前窗格")
                            : language.localized("Inactive pane", "非当前窗格")
                    )
                    .accessibilityIdentifier("terminal-pane-activate-button")

                    Spacer()

                    if isMCPControllablePane {
                        Toggle(isOn: broadcastReadyBinding) {
                            Label(
                                language.localized("Multi-Exec Ready", "批量执行就绪"),
                                systemImage: interactiveSession.isBroadcastReady
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(interactiveSession.isBroadcastReady ? .orange : .accentColor)
                        .disabled(!canChangeBroadcastReadiness)
                        .help(broadcastReadyHelpText)
                        .fixedSize()
                        .accessibilityIdentifier("terminal-multi-exec-ready-toggle")

                        Button {
                            beginRenamingMCPPane()
                        } label: {
                            Label(mcpPaneDisplayName, systemImage: "tag")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 160)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(language.localized(
                            "MCP name for this terminal pane. AI tools see this name in jts_list_open_terminals.",
                            "这个终端窗格的 MCP 名称。AI 工具会在 jts_list_open_terminals 里看到它。"
                        ))
                        .fixedSize()
                        .accessibilityIdentifier("terminal-mcp-pane-name-button")

                        Button {
                            copyMCPPaneDisplayName()
                        } label: {
                            Image(systemName: didCopyMCPPaneName ? "checkmark" : "doc.on.doc")
                                .imageScale(.small)
                                .frame(width: 14, height: 14)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(language.localized(
                            "Copy this MCP pane name for AI tools.",
                            "复制这个 MCP 窗格名称，便于发给 AI 识别。"
                        ))
                        .accessibilityLabel(language.localized("Copy MCP pane name", "复制 MCP 窗格名称"))
                        .accessibilityIdentifier("terminal-mcp-pane-name-copy-button")
                        .disabled(mcpPaneDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .fixedSize()

                        Menu {
                            Toggle(isOn: mcpProfileEnabledBinding) {
                                Label(language.localized("Enable MCP", "启用 MCP"), systemImage: "checkmark.shield")
                            }
                            .help(mcpProfileEnabledHelpText)
                            .accessibilityIdentifier("terminal-mcp-profile-enabled-toggle")

                            Toggle(isOn: persistentMCPProfileBinding) {
                                Label(language.localized("Persistent Control", "长期控制"), systemImage: "bolt.shield")
                            }
                            .disabled(!session.mcpEnabled)
                            .help(persistentMCPProfileHelpText)
                            .accessibilityIdentifier("terminal-mcp-persistent-control-toggle")

                            Toggle(isOn: mcpControlBinding) {
                                Label(language.localized("Pane Control", "本窗格控制"), systemImage: "exclamationmark.shield")
                            }
                            .disabled(!session.mcpEnabled || !interactiveSession.isRunning || isPersistentMCPControlAllowed)
                            .help(mcpControlHelpText)
                            .accessibilityIdentifier("terminal-mcp-control-toggle")
                        } label: {
                            Label("MCP", systemImage: mcpControlMenuSymbol)
                                .lineLimit(1)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(mcpControlMenuHelpText)
                        .fixedSize()
                        .accessibilityIdentifier("terminal-mcp-control-menu")
                    }

                    if interactiveSession.isRunning ||
                        interactiveSession.isReconnectScheduled ||
                        interactiveSession.isSSHStartPending {
                        Button(role: .destructive) {
                            interactiveSession.stop()
                        } label: {
                            Label(
                                interactiveSession.isSSHStartPending
                                    ? language.localized("Cancel Connection", "取消连接")
                                    : language.localized("Stop", "停止"),
                                systemImage: "stop.fill"
                            )
                        }
                        .accessibilityLabel(
                            interactiveSession.isSSHStartPending
                                ? language.localized("Cancel Connection", "取消连接")
                                : language.localized("Stop", "停止")
                        )
                        .fixedSize()
                        .accessibilityIdentifier("terminal-stop-button")
                    } else {
                        Button {
                            start()
                        } label: {
                            Label(language.localized("Start", "启动"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(kind == .ssh && (session.connectionType != .ssh || !session.isConnectable))
                        .accessibilityLabel(language.localized("Start", "启动"))
                        .fixedSize()
                        .accessibilityIdentifier("terminal-start-button")
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 2)

                compactPaneHeader
                    .font(.caption)
                    .padding(.horizontal, 2)
            }

            if !interactiveSession.reconnectStatus.isBlank {
                Label(interactiveSession.reconnectStatus, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            if interactiveSession.isSSHStartPending,
               interactiveSession.pendingSSHCredentialPrompt == nil {
                Label(
                    language.localized(
                        "Checking the local encrypted credential vault...",
                        "正在检查本地加密密码库..."
                    ),
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            }

            if !mcpProfileSaveError.isBlank {
                Label(mcpProfileSaveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 2)
            }

            if let recovery = interactiveSession.structuredCommandRecovery {
                structuredCommandRecoveryBanner(recovery)
                    .padding(.horizontal, 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("terminal-structured-command-recovery-banner")
            }

            if isPaneAuthorizedForMCPControl &&
                !interactiveSession.requiresStructuredCommandRecovery {
                Label(
                    mcpControlStatusText,
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 2)
            }

            #if canImport(SwiftTerm)
            SwiftTermPTYView(
                transcript: interactiveSession.transcript,
                isRunning: interactiveSession.isRunning,
                isFocused: isFocused,
                copyMenuTitle: language.localized("Copy", "复制"),
                sendRaw: { interactiveSession.sendRaw($0) },
                resize: { columns, rows in
                    resizePTY(columns: columns, rows: rows)
                },
                onFocus: onFocus,
                surface: swiftTermSurface as? SwiftTermPersistentSurface
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("swiftterm-pty-view")
            #else
            TerminalPTYView(
                transcript: interactiveSession.transcript,
                isRunning: interactiveSession.isRunning,
                isFocused: isFocused,
                sendRaw: { interactiveSession.sendRaw($0) },
                resize: { columns, rows in
                    resizePTY(columns: columns, rows: rows)
                },
                onFocus: onFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("terminal-pty-view")
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard autoStart,
                  !didAutoStart,
                  !interactiveSession.hasStarted,
                  !interactiveSession.isSSHStartPending else { return }
            scheduleAutoStartAfterInitialSize()
        }
        .onDisappear {
            pendingAutoStartWorkItem?.cancel()
            pendingAutoStartWorkItem = nil
        }
        .alert(
            language.localized("MCP Pane Name", "MCP 窗格名称"),
            isPresented: $isShowingMCPNamePrompt
        ) {
            TextField(
                language.localized("Name shown to AI tools", "显示给 AI 工具的名称"),
                text: $pendingMCPPaneName
            )
            Button(language.localized("Save", "保存")) {
                setMCPPaneName(pendingMCPPaneName)
            }
            Button(language.localized("Clear", "清除")) {
                setMCPPaneName("")
                pendingMCPPaneName = ""
            }
            Button(language.localized("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(language.localized(
                "Use a short name like prod-root, build-shell, or logs-tail so AI tools can choose the right open terminal.",
                "使用 prod-root、build-shell、logs-tail 这类短名称，方便 AI 工具选择正确的已打开终端。"
            ))
        }
        .sheet(item: sshCredentialPromptBinding) { descriptor in
            SSHCredentialPromptSheet(
                descriptor: descriptor,
                purpose: .connect,
                isSubmitting: interactiveSession.isSubmittingSSHCredential,
                errorMessage: interactiveSession.sshCredentialPromptError,
                cancel: {
                    interactiveSession.cancelSSHCredentialPrompt(requestID: descriptor.id)
                },
                useKeyOrAgent: {
                    interactiveSession.continueSSHWithKeyOrAgent(requestID: descriptor.id)
                },
                submitOnce: { secret in
                    interactiveSession.connectOnceWithSSHPassword(
                        secret,
                        requestID: descriptor.id
                    )
                },
                saveAndSubmit: { secret in
                    interactiveSession.saveAndConnectWithSSHPassword(
                        secret,
                        requestID: descriptor.id
                    )
                }
            )
            .environment(\.appLanguage, language)
        }
        .alert(
            language.localized("Save Password?", "保存密码？"),
            isPresented: Binding(
                get: { interactiveSession.pendingCredentialSaveRequest != nil },
                set: { isPresented in
                    if !isPresented {
                        interactiveSession.discardPendingCredentialSaveRequest()
                    }
                }
            ),
            presenting: interactiveSession.pendingCredentialSaveRequest
        ) { _ in
            Button(language.localized("Save", "保存")) {
                interactiveSession.savePendingCredential()
            }
            Button(language.localized("Not Now", "暂不保存"), role: .cancel) {
                interactiveSession.discardPendingCredentialSaveRequest()
            }
        } message: { request in
            Text(language.localized(
                "Save the password for \(request.label) to the local encrypted SQLite vault and enter it automatically next time this server asks for a password.",
                "将 \(request.label) 的密码保存到本地加密 SQLite 密码库，下次该服务器要求密码时自动输入。"
            ))
        }
    }

    private var compactPaneHeader: some View {
        HStack(spacing: 6) {
            compactPaneActivationButton
                .layoutPriority(1)

            Spacer(minLength: 4)

            if isMCPControllablePane {
                compactBroadcastReadyToggle
                compactPaneActionsMenu
            }

            compactProcessControlButton
        }
        .frame(maxWidth: .infinity)
    }

    private var compactPaneActivationButton: some View {
        Button(action: onFocus) {
            HStack(spacing: 5) {
                Circle()
                    .fill(
                        isFocused
                            ? Color.accentColor
                            : Color.secondary.opacity(0.45)
                    )
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(paneTitle)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help(language.localized(
            "Make this the active pane",
            "将此窗格设为当前窗格"
        ))
        .accessibilityLabel(language.localized(
            "Activate terminal pane \(paneTitle)",
            "激活终端窗格 \(paneTitle)"
        ))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityValue(
            isFocused
                ? language.localized("Active pane", "当前窗格")
                : language.localized("Inactive pane", "非当前窗格")
        )
        .accessibilityIdentifier("terminal-pane-activate-button")
    }

    private var compactBroadcastReadyToggle: some View {
        Toggle(isOn: broadcastReadyBinding) {
            Label(
                language.localized("Ready", "就绪"),
                systemImage: interactiveSession.isBroadcastReady
                    ? "checkmark.circle.fill"
                    : "circle"
            )
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(interactiveSession.isBroadcastReady ? .orange : .accentColor)
        .disabled(!canChangeBroadcastReadiness)
        .help(broadcastReadyHelpText)
        .fixedSize()
        .accessibilityLabel(
            language.localized("Multi-Exec Ready", "批量执行就绪")
        )
        .accessibilityIdentifier("terminal-multi-exec-ready-toggle")
    }

    private var compactPaneActionsMenu: some View {
        Menu {
            Button {
                beginRenamingMCPPane()
            } label: {
                Label(
                    language.localized("Rename MCP Pane", "重命名 MCP 窗格"),
                    systemImage: "tag"
                )
            }
            .accessibilityIdentifier("terminal-mcp-pane-name-button")

            Button {
                copyMCPPaneDisplayName()
            } label: {
                Label(
                    language.localized("Copy MCP Pane Name", "复制 MCP 窗格名称"),
                    systemImage: didCopyMCPPaneName
                        ? "checkmark"
                        : "doc.on.doc"
                )
            }
            .disabled(
                mcpPaneDisplayName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
            .accessibilityIdentifier("terminal-mcp-pane-name-copy-button")

            Divider()

            Toggle(isOn: mcpProfileEnabledBinding) {
                Label(
                    language.localized("Enable MCP", "启用 MCP"),
                    systemImage: "checkmark.shield"
                )
            }
            .help(mcpProfileEnabledHelpText)
            .accessibilityIdentifier("terminal-mcp-profile-enabled-toggle")

            Toggle(isOn: persistentMCPProfileBinding) {
                Label(
                    language.localized("Persistent Control", "长期控制"),
                    systemImage: "bolt.shield"
                )
            }
            .disabled(!session.mcpEnabled)
            .help(persistentMCPProfileHelpText)
            .accessibilityIdentifier(
                "terminal-mcp-persistent-control-toggle"
            )

            Toggle(isOn: mcpControlBinding) {
                Label(
                    language.localized("Pane Control", "本窗格控制"),
                    systemImage: "exclamationmark.shield"
                )
            }
            .disabled(
                !session.mcpEnabled
                    || !interactiveSession.isRunning
                    || isPersistentMCPControlAllowed
            )
            .help(mcpControlHelpText)
            .accessibilityIdentifier("terminal-mcp-control-toggle")
        } label: {
            Label(
                language.localized("Pane", "窗格"),
                systemImage: "ellipsis.circle"
            )
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .fixedSize()
        .help(language.localized(
            "MCP name and control settings for this pane.",
            "管理此窗格的 MCP 名称和控制设置。"
        ))
        .accessibilityLabel(language.localized(
            "Pane Actions",
            "窗格操作"
        ))
        .accessibilityIdentifier("terminal-pane-actions-menu")
    }

    @ViewBuilder
    private var compactProcessControlButton: some View {
        if interactiveSession.isRunning
            || interactiveSession.isReconnectScheduled
            || interactiveSession.isSSHStartPending {
            Button(role: .destructive) {
                interactiveSession.stop()
            } label: {
                Label(
                    interactiveSession.isSSHStartPending
                        ? language.localized("Cancel", "取消")
                        : language.localized("Stop", "停止"),
                    systemImage: "stop.fill"
                )
            }
            .fixedSize()
            .accessibilityLabel(
                interactiveSession.isSSHStartPending
                    ? language.localized("Cancel Connection", "取消连接")
                    : language.localized("Stop", "停止")
            )
            .accessibilityIdentifier("terminal-stop-button")
        } else {
            Button {
                start()
            } label: {
                Label(
                    language.localized("Start", "启动"),
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                kind == .ssh
                    && (session.connectionType != .ssh
                        || !session.isConnectable)
            )
            .fixedSize()
            .accessibilityLabel(language.localized("Start", "启动"))
            .accessibilityIdentifier("terminal-start-button")
        }
    }

    private var paneTitle: String {
        switch kind {
        case .ssh:
            return session.localizedAddress(language: language)
        case .localShell:
            return language.localized("Local shell", "本地 Shell")
        }
    }

    private var sshCredentialPromptBinding: Binding<SSHCredentialPromptDescriptor?> {
        Binding(
            get: {
                guard kind == .ssh else { return nil }
                return interactiveSession.pendingSSHCredentialPrompt
            },
            set: { newValue in
                guard newValue == nil,
                      !interactiveSession.isSubmittingSSHCredential,
                      let requestID = interactiveSession.pendingSSHCredentialPrompt?.id else {
                    return
                }
                interactiveSession.cancelSSHCredentialPrompt(requestID: requestID)
            }
        )
    }

    private var isMCPControllablePane: Bool {
        TerminalWorkspaceState.Kind.preferredTerminalKind(for: session) == kind
    }

    private var broadcastReadyBinding: Binding<Bool> {
        Binding(
            get: { interactiveSession.isBroadcastReady },
            set: { interactiveSession.setBroadcastReady($0) }
        )
    }

    private var canChangeBroadcastReadiness: Bool {
        interactiveSession.isRunning &&
            interactiveSession.pendingSSHCredentialPrompt == nil &&
            !interactiveSession.isSSHStartPending &&
            !interactiveSession.isReconnectScheduled &&
            !interactiveSession.requiresStructuredCommandRecovery &&
            !interactiveSession.isStructuredCommandBusy
    }

    private var broadcastReadyHelpText: String {
        if interactiveSession.requiresStructuredCommandRecovery {
            return language.localized(
                "Automation is paused until you manually return this pane to a shell prompt and confirm recovery.",
                "自动化已暂停；请先手动让此窗格回到 shell 提示符并确认恢复。"
            )
        }
        return language.localized(
            "Temporarily make this running pane selectable in Multi-Exec. Confirm that it is at a shell prompt. Readiness resets when the process stops or reconnects.",
            "临时允许在“批量执行”中选择这个运行中的窗格。请确认它当前位于 shell 提示符；进程停止或重连后会自动取消就绪。"
        )
    }

    private var mcpProfileEnabledBinding: Binding<Bool> {
        Binding(
            get: { isMCPControllablePane && session.mcpEnabled },
            set: { setMCPProfileEnabled($0) }
        )
    }

    private var persistentMCPProfileBinding: Binding<Bool> {
        Binding(
            get: { isMCPControllablePane && session.mcpEnabled && session.mcpAlwaysAllowTerminalControl },
            set: { setPersistentMCPControl($0) }
        )
    }

    private var mcpControlBinding: Binding<Bool> {
        Binding(
            get: { isPaneAuthorizedForMCPControl },
            set: { newValue in
                guard !isPersistentMCPControlAllowed else { return }
                interactiveSession.setMCPControlEnabled(newValue && session.mcpEnabled)
            }
        )
    }

    private var isPersistentMCPControlAllowed: Bool {
        session.mcpEnabled && session.mcpAlwaysAllowTerminalControl
    }

    private var isPaneAuthorizedForMCPControl: Bool {
        isMCPControllablePane &&
            session.mcpEnabled &&
            interactiveSession.isRunning &&
            (isPersistentMCPControlAllowed || interactiveSession.isMCPControlEnabled)
    }

    private var mcpControlMenuSymbol: String {
        if interactiveSession.requiresStructuredCommandRecovery {
            return "pause.circle.fill"
        }
        if isPaneAuthorizedForMCPControl {
            return "exclamationmark.shield.fill"
        }
        if session.mcpEnabled {
            return "checkmark.shield"
        }
        return "shield"
    }

    private var mcpControlMenuHelpText: String {
        if interactiveSession.requiresStructuredCommandRecovery {
            return language.localized(
                "Automation is paused until you manually return this pane to a shell prompt and confirm recovery.",
                "自动化已暂停；请先手动让此窗格回到 shell 提示符并确认恢复。"
            )
        }
        if isPaneAuthorizedForMCPControl {
            return mcpControlStatusText
        }
        if session.mcpEnabled {
            return language.localized(
                "MCP is enabled for this profile. Open this menu to manage persistent or pane-level control.",
                "此配置已启用 MCP。打开此菜单可管理长期控制或本窗格控制。"
            )
        }
        return language.localized(
            "Open MCP controls for this terminal pane.",
            "打开这个终端窗格的 MCP 控制。"
        )
    }

    private func structuredCommandRecoveryBanner(
        _ recovery: InteractiveProcessSession.StructuredCommandRecovery
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                structuredCommandRecoveryMessage
                Spacer(minLength: 8)
                structuredCommandRecoveryButton(recovery)
            }

            VStack(alignment: .leading, spacing: 8) {
                structuredCommandRecoveryMessage
                HStack {
                    Spacer(minLength: 0)
                    structuredCommandRecoveryButton(recovery)
                }
            }
        }
        .padding(8)
        .background(
            Color.orange.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var structuredCommandRecoveryMessage: some View {
        Label(
            language.localized(
                "Automation paused after an interrupted command. Return this pane to a shell prompt before resuming.",
                "命令中断后自动化已暂停。请先让此窗格返回 shell 提示符，再恢复自动化。"
            ),
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private func structuredCommandRecoveryButton(
        _ recovery: InteractiveProcessSession.StructuredCommandRecovery
    ) -> some View {
        Button(language.localized("I’m at the prompt", "已回到提示符")) {
            _ = interactiveSession.confirmStructuredCommandRecovery(id: recovery.id)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.mini)
        .fixedSize()
        .disabled(!interactiveSession.canConfirmStructuredCommandRecovery(id: recovery.id))
        .help(structuredCommandRecoveryHelp(recovery))
        .accessibilityLabel(language.localized(
            "Confirm \(paneTitle) is back at the shell prompt and resume automation",
            "确认 \(paneTitle) 已回到 shell 提示符并恢复自动化"
        ))
        .accessibilityIdentifier("terminal-structured-command-recovery-button")
    }

    private func structuredCommandRecoveryHelp(
        _ recovery: InteractiveProcessSession.StructuredCommandRecovery
    ) -> String {
        guard interactiveSession.isRunning,
              interactiveSession.executionGeneration == recovery.launchID else {
            return language.localized(
                "The terminal process changed. Restart the pane before resuming automation.",
                "终端进程已变化。请重新启动窗格后再恢复自动化。"
            )
        }
        if interactiveSession.isStructuredCommandBusy {
            return language.localized(
                "Wait for the active terminal operation to finish before confirming recovery.",
                "请等待当前终端操作结束后再确认恢复。"
            )
        }
        if interactiveSession.isSSHStartPending ||
            interactiveSession.isReconnectScheduled ||
            interactiveSession.pendingSSHCredentialPrompt != nil {
            return language.localized(
                "Finish connecting or authentication before confirming recovery.",
                "请先完成连接或身份验证，再确认恢复。"
            )
        }
        if !interactiveSession.canConfirmStructuredCommandRecovery(id: recovery.id) {
            return language.localized(
                "Finish the active terminal input or operation before confirming recovery.",
                "请先完成当前终端输入或操作，再确认恢复。"
            )
        }
        return language.localized(
            "Only resume after you can see the shell prompt and the previous foreground program has stopped.",
            "仅当你已看到 shell 提示符，且此前的前台程序已经停止时再恢复。"
        )
    }

    private var mcpControlHelpText: String {
        if isPersistentMCPControlAllowed {
            switch session.connectionType {
            case .ssh:
                return language.localized(
                    "MCP Control is always allowed for every running SSH terminal pane of this server in Server Properties.",
                    "已在服务器属性中长期允许 MCP 控制此服务器的每个运行中 SSH 终端窗格。"
                )
            case .localShell:
                return language.localized(
                    "MCP Control is always allowed for every running Local Shell pane of this profile in Server Properties.",
                    "已在服务器属性中长期允许 MCP 控制这个配置的每个运行中本地 Shell 窗格。"
                )
            case .macDesktop:
                return language.localized("MCP control is unavailable for this Mac profile.", "此 Mac 配置尚未开放 MCP 控制。")
            case .rdp:
                #if ENABLE_RDP_2
                return language.localized(
                    "RDP desktop control uses a persistent per-client grant that remains valid until revoked.",
                    "RDP 桌面控制使用按客户端独立保存的长期授权，直到主动撤销。"
                )
                #else
                return language.localized(
                    "MCP Control is not available for this profile type in this build.",
                    "当前构建不为此配置类型提供 MCP 控制。"
                )
                #endif
            }
        }

        return language.localized(
            "Allow MCP tools to send queued commands to this exact terminal. If this shell is root, MCP commands run as root.",
            "允许 MCP 工具向这个终端发送队列命令。如果该 shell 是 root，MCP 命令也会以 root 执行。"
        )
    }

    private var mcpProfileEnabledHelpText: String {
        switch session.connectionType {
        case .ssh:
            return language.localized(
                "Syncs with Server Properties > AI / MCP Access > Enable MCP for this SSH server.",
                "同步服务器属性 > AI / MCP 访问 > 为这台 SSH 服务器启用 MCP。"
            )
        case .localShell:
            return language.localized(
                "Syncs with Server Properties > AI / MCP Access > Enable MCP for this Local Shell.",
                "同步服务器属性 > AI / MCP 访问 > 为这个本地 Shell 启用 MCP。"
            )
        case .macDesktop:
            return language.localized("Mac desktop is configured in the Desktop workspace.", "在桌面工作区配置 Mac 桌面。")
        case .rdp:
            #if ENABLE_RDP_2
            return language.localized(
                "RDP desktop control uses Windows MCP tools and a persistent per-client grant managed from AI Access Management.",
                "RDP 桌面控制使用 Windows MCP 工具，并通过“AI 访问管理”管理按客户端保存的长期授权。"
            )
            #else
            return language.localized(
                "This profile type is not included in the current App Store build.",
                "当前 App Store 构建不包含此配置类型。"
            )
            #endif
        }
    }

    private var persistentMCPProfileHelpText: String {
        language.localized(
            "Syncs with Server Properties > AI / MCP Access > Always allow MCP Control for all terminal sessions.",
            "同步服务器属性 > AI / MCP 访问 > 长期允许 MCP 控制此服务器的所有终端会话。"
        )
    }

    private var mcpControlStatusText: String {
        if isPersistentMCPControlAllowed {
            return language.localized(
                "MCP can control this terminal as \(mcpPaneDisplayName) because this server allows persistent MCP Control.",
                "MCP 可通过 \(mcpPaneDisplayName) 控制这个终端，因为此服务器已开启长期 MCP 控制。"
            )
        }

        return language.localized(
            "MCP can control this terminal as \(mcpPaneDisplayName), including a root shell.",
            "MCP 可通过 \(mcpPaneDisplayName) 控制这个终端，包括 root shell。"
        )
    }

    private func beginRenamingMCPPane() {
        pendingMCPPaneName = mcpPaneName.trimmingCharacters(in: .whitespacesAndNewlines)
        isShowingMCPNamePrompt = true
    }

    private func copyMCPPaneDisplayName() {
        let name = mcpPaneDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
        didCopyMCPPaneName = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopyMCPPaneName = false
        }
    }

    private func setMCPProfileEnabled(_ isEnabled: Bool) {
        guard isMCPControllablePane else { return }
        guard session.mcpEnabled != isEnabled else { return }

        session.mcpEnabled = isEnabled
        if !isEnabled {
            session.mcpAlwaysAllowTerminalControl = false
            interactiveSession.setMCPControlEnabled(false)
        }
        saveMCPProfileSettings()
    }

    private func setPersistentMCPControl(_ isEnabled: Bool) {
        guard isMCPControllablePane else { return }
        guard session.mcpEnabled else { return }
        guard session.mcpAlwaysAllowTerminalControl != isEnabled else { return }

        session.mcpAlwaysAllowTerminalControl = isEnabled
        saveMCPProfileSettings()
    }

    private func saveMCPProfileSettings() {
        session.mcpUpdatedAt = Date()
        session.updatedAt = Date()

        do {
            try modelContext.save()
            mcpProfileSaveError = ""
        } catch {
            mcpProfileSaveError = language.localized(
                "Failed to save MCP profile settings: \(error.localizedDescription)",
                "保存 MCP 配置失败：\(error.localizedDescription)"
            )
        }
    }

    private func start() {
        switch kind {
        case .ssh:
            guard session.connectionType == .ssh else { return }
            interactiveSession.startSSH(session: session)
        case .localShell:
            interactiveSession.startLocalShell()
        }
    }

    private func resizePTY(columns: Int, rows: Int) {
        let safeGrid = TerminalGridMetrics.clampedGrid(columns: columns, rows: rows)
        let safeColumns = safeGrid.columns
        let safeRows = safeGrid.rows
        guard (1...Int(UInt16.max)).contains(safeColumns),
              (1...Int(UInt16.max)).contains(safeRows) else {
            return
        }
        hasMeasuredTerminalGrid = true
        interactiveSession.resize(columns: UInt16(safeColumns), rows: UInt16(safeRows))
        attemptPendingAutoStart()
    }

    private func scheduleAutoStartAfterInitialSize() {
        pendingAutoStartWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            attemptPendingAutoStart(force: true)
        }
        pendingAutoStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        attemptPendingAutoStart()
    }

    private func attemptPendingAutoStart(force: Bool = false) {
        guard autoStart,
              !didAutoStart,
              !interactiveSession.hasStarted,
              !interactiveSession.isSSHStartPending,
              force || hasMeasuredTerminalGrid else {
            return
        }

        pendingAutoStartWorkItem?.cancel()
        pendingAutoStartWorkItem = nil
        didAutoStart = true
        start()
    }

}

private struct PasswordRevealField: View {
    @Environment(\.appLanguage) private var language
    let title: String
    @Binding var text: String
    var isDisabled = false
    var accessibilityIdentifier: String
    var autoFocus = false
    var onSubmit: () -> Void = {}
    @State private var isRevealed = false
    @State private var didAutoFocus = false
    @FocusState private var isFocused: Bool

    init(
        _ title: String,
        text: Binding<String>,
        isDisabled: Bool = false,
        accessibilityIdentifier: String,
        autoFocus: Bool = false,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.title = title
        _text = text
        self.isDisabled = isDisabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.autoFocus = autoFocus
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 6) {
            passwordField
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .disableAutocorrection(true)
                .focused($isFocused)
                .disabled(isDisabled)
                .onSubmit(onSubmit)
                .accessibilityIdentifier(accessibilityIdentifier)

            Button {
                isRevealed.toggle()
                DispatchQueue.main.async {
                    isFocused = true
                }
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .imageScale(.medium)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isDisabled)
            .accessibilityLabel(revealAccessibilityLabel)
            .help(revealAccessibilityLabel)
            .accessibilityIdentifier("\(accessibilityIdentifier)-reveal-button")
        }
        .onAppear(perform: focusIfNeeded)
    }

    @ViewBuilder
    private var passwordField: some View {
        if isRevealed {
            TextField(title, text: $text)
                .font(.system(.body, design: .monospaced))
        } else {
            SecureField(title, text: $text)
        }
    }

    private var revealAccessibilityLabel: String {
        isRevealed
            ? language.localized("Hide password", "隐藏密码")
            : language.localized("Show password", "显示密码")
    }

    private func focusIfNeeded() {
        guard autoFocus, !didAutoFocus else { return }
        didAutoFocus = true
        DispatchQueue.main.async {
            isFocused = true
        }
    }
}

private struct SSHPasswordInputMetadata: View {
    @Environment(\.appLanguage) private var language
    let password: String

    var body: some View {
        if !password.isEmpty {
            Group {
                if let advisory = SSHCredentialPromptPolicy.inputAdvisory(for: password) {
                    Label(
                        advisoryMessage(for: advisory),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("ssh-password-input-advisory")
                } else {
                    Text(byteCountText(password.utf8.count))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ssh-password-input-byte-count")
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func advisoryMessage(for advisory: SSHCredentialInputAdvisory) -> String {
        let byteCount = byteCountText(advisory.utf8ByteCount)
        switch advisory.kind {
        case .matchingASCIIQuote, .matchingASCIISingleQuote:
            return language.localized(
                "This password starts and ends with command-line quote characters. JTS Terminal will send those quote characters literally; do not include shell quotes unless they are part of the server password. \(byteCount)",
                "当前密码以命令行引号开头和结尾。JTS Terminal 会把这些引号当作密码内容发送；除非服务器密码本身包含引号，否则不要输入 shell 引号。\(byteCount)"
            )
        case .matchingCurlyDoubleQuote, .matchingCurlySingleQuote:
            return language.localized(
                "This password starts and ends with smart quote characters. JTS Terminal will send those quote characters literally. \(byteCount)",
                "当前密码以弯引号开头和结尾。JTS Terminal 会把这些引号当作密码内容发送。\(byteCount)"
            )
        case .leadingOrTrailingWhitespace:
            return language.localized(
                "This password starts or ends with whitespace. JTS Terminal will send that whitespace literally. \(byteCount)",
                "当前密码开头或结尾包含空白字符。JTS Terminal 会把这些空白字符当作密码内容发送。\(byteCount)"
            )
        case .nonASCIIPunctuation:
            return language.localized(
                "This password contains non-ASCII punctuation. If the server password uses ASCII characters such as '.', '-', or '+', switch to an ASCII input mode before saving. \(byteCount)",
                "当前密码包含非 ASCII 标点。如果服务器密码使用的是 '.', '-' 或 '+' 这类 ASCII 字符，请先切换到 ASCII 输入模式再保存。\(byteCount)"
            )
        }
    }

    private func byteCountText(_ count: Int) -> String {
        language.localized(
            "Current input: \(count) UTF-8 bytes.",
            "当前输入：\(count) 个 UTF-8 字节。"
        )
    }
}

private struct SSHCredentialPromptSheet: View {
    enum Purpose {
        case connect
        case test
    }

    @Environment(\.appLanguage) private var language
    let descriptor: SSHCredentialPromptDescriptor
    let purpose: Purpose
    let isSubmitting: Bool
    let errorMessage: String?
    let cancel: () -> Void
    let useKeyOrAgent: () -> Void
    let submitOnce: (String) -> Void
    let saveAndSubmit: (String) -> Void
    @State private var password = ""
    @State private var localValidationError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: descriptor.allowsPasswordSubmission ? "lock.shield" : "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(sheetTitle)
                        .font(.title3.weight(.semibold))
                    Text(descriptor.displayLabel)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if descriptor.allowsPasswordSubmission {
                PasswordRevealField(
                    language.localized("SSH password", "SSH 密码"),
                    text: $password,
                    isDisabled: isSubmitting,
                    accessibilityIdentifier: "ssh-credential-prompt-password-field",
                    autoFocus: true,
                    onSubmit: saveAndSubmitAction
                )
                .onChange(of: password) {
                    localValidationError = nil
                }

                SSHPasswordInputMetadata(password: password)

                Text(persistenceExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    language.localized(
                        "Saved or newly entered destination passwords are not auto-filled through a jump host.",
                        "通过跳板机连接时，不会自动填入已保存或新输入的目标服务器密码。"
                    ),
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let error = localValidationError ?? errorMessage,
               !error.isBlank {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ssh-credential-prompt-error")
            }

            Divider()

            HStack(spacing: 10) {
                Button(role: .cancel, action: cancelAction) {
                    Text(language.localized("Cancel", "取消"))
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
                .accessibilityIdentifier("ssh-credential-prompt-cancel-button")

                Spacer()

                Button(action: useKeyOrAgentAction) {
                    Text(keyOrAgentButtonTitle)
                }
                .buttonStyle(.bordered)
                .disabled(isSubmitting)
                .accessibilityIdentifier("ssh-credential-prompt-key-agent-button")

                if descriptor.allowsPasswordSubmission {
                    Button(action: submitOnceAction) {
                        Text(onceTitle)
                    }
                    .buttonStyle(.bordered)
                    .disabled(password.isEmpty || isSubmitting)
                    .accessibilityIdentifier(onceButtonAccessibilityIdentifier)

                    Button(action: saveAndSubmitAction) {
                        if isSubmitting {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(savingTitle)
                            }
                        } else {
                            Text(saveTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isSubmitting)
                    .accessibilityIdentifier(saveButtonAccessibilityIdentifier)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ssh-credential-prompt-sheet")
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear(perform: clearLocalPassword)
    }

    private var sheetTitle: String {
        guard descriptor.allowsPasswordSubmission else {
            return language.localized("Jump Host Authentication", "跳板机身份验证")
        }
        if descriptor.reason == .rejectedSavedPassword {
            return language.localized(
                "Saved SSH Password Rejected",
                "已保存的 SSH 密码被拒绝"
            )
        }
        switch purpose {
        case .connect:
            return language.localized("SSH Password Required", "需要 SSH 密码")
        case .test:
            return language.localized("SSH Password Required to Test", "测试需要 SSH 密码")
        }
    }

    private var saveButtonAccessibilityIdentifier: String {
        switch purpose {
        case .connect:
            return "ssh-credential-prompt-save-connect-button"
        case .test:
            return "ssh-credential-prompt-save-test-button"
        }
    }

    private var onceButtonAccessibilityIdentifier: String {
        switch purpose {
        case .connect:
            return "ssh-credential-prompt-connect-once-button"
        case .test:
            return "ssh-credential-prompt-test-once-button"
        }
    }

    private var explanation: String {
        if descriptor.allowsPasswordSubmission {
            if descriptor.reason == .rejectedSavedPassword {
                return language.localized(
                    "SSH rejected password authentication after JTS Terminal supplied the saved credential. The saved password is still unchanged. Enter a replacement for this attempt only, overwrite it and reconnect, or use an SSH key or ssh-agent. If a replacement is also rejected, verify the username and server settings.",
                    "JTS Terminal 提交已保存凭据后，SSH 拒绝了密码认证。原密码仍保持不变。你可以输入新密码仅用于本次连接、覆盖保存后重新连接，或改用 SSH 密钥 / ssh-agent；如果新密码仍被拒绝，请检查用户名和服务器设置。"
                )
            }
            switch purpose {
            case .connect:
                return language.localized(
                    "No password is saved for this connection. Enter one for this connection only, save it to the local encrypted vault, or continue with an SSH key or ssh-agent.",
                    "此连接没有已保存的密码。你可以仅为本次连接输入密码、将密码保存到本地加密密码库，或改用 SSH 密钥或 ssh-agent。"
                )
            case .test:
                return language.localized(
                    "No password is saved for this connection. Enter one for this test only, save it to the local encrypted vault and test, or test with an SSH key or ssh-agent.",
                    "此连接没有已保存的密码。你可以仅为本次测试输入密码、将密码保存到本地加密密码库后测试，或改用 SSH 密钥或 ssh-agent 测试。"
                )
            }
        }
        return language.localized(
            "This profile uses a jump host. SSH can ask for both the jump-host and destination credentials in the same terminal, so JTS Terminal cannot safely decide which server should receive one automatic password. Continue to use keys or enter each password manually in the terminal.",
            "此配置使用跳板机。SSH 可能在同一终端中分别请求跳板机和目标服务器凭据，JTS Terminal 无法安全判断一个自动密码应交给哪台服务器。请继续使用密钥，或在终端中分别手动输入密码。"
        )
    }

    private var persistenceExplanation: String {
        if descriptor.reason == .rejectedSavedPassword {
            return language.localized(
                "Save overwrites the rejected password in the local encrypted vault before reconnecting. Press Return to save and reconnect. Connect Once uses the new value only for this attempt and leaves the saved password unchanged.",
                "保存会先覆盖本地加密密码库中被拒绝的密码，再重新连接；按 Return 即可保存并重连。“仅本次连接”只在这次使用新值，不会修改已保存密码。"
            )
        }
        switch purpose {
        case .connect:
            return language.localized(
                "Save writes the password to the local encrypted vault. Press Return to save and connect. Connection delivery uses the signed one-shot helper; the password is never added to the profile, process arguments, environment, or terminal transcript.",
                "保存会将密码写入本地加密密码库；按 Return 即可保存并连接。连接时由签名的一次性凭据助手传递，密码不会写入配置、进程参数、环境变量或终端记录。"
            )
        case .test:
            return language.localized(
                "Save writes the password to the local encrypted vault. Press Return to save and test. Connection delivery uses the signed one-shot helper; the password is never added to the profile, process arguments, environment, or terminal transcript.",
                "保存会将密码写入本地加密密码库；按 Return 即可保存并测试。连接时由签名的一次性凭据助手传递，密码不会写入配置、进程参数、环境变量或终端记录。"
            )
        }
    }

    private var keyOrAgentButtonTitle: String {
        guard descriptor.allowsPasswordSubmission else {
            return purpose == .connect
                ? language.localized("Continue Manually", "继续手动连接")
                : language.localized("Test Key / Agent", "测试密钥 / Agent")
        }
        return purpose == .connect
            ? language.localized("Use Key / Agent", "使用密钥 / Agent")
            : language.localized("Test Key / Agent", "测试密钥 / Agent")
    }

    private var onceTitle: String {
        purpose == .connect
            ? language.localized("Connect Once", "仅本次连接")
            : language.localized("Test Once", "仅本次测试")
    }

    private var saveTitle: String {
        if purpose == .connect,
           descriptor.reason == .rejectedSavedPassword {
            return language.localized("Save & Reconnect", "保存并重连")
        }
        return purpose == .connect
            ? language.localized("Save & Connect", "保存并连接")
            : language.localized("Save & Test", "保存并测试")
    }

    private var savingTitle: String {
        language.localized("Saving...", "正在保存...")
    }

    private func cancelAction() {
        clearLocalPassword()
        cancel()
    }

    private func submitOnceAction() {
        guard validatePassword() else { return }
        let submittedPassword = password
        clearLocalPassword()
        submitOnce(submittedPassword)
    }

    private func saveAndSubmitAction() {
        guard validatePassword() else { return }
        let submittedPassword = password
        clearLocalPassword()
        saveAndSubmit(submittedPassword)
    }

    private func useKeyOrAgentAction() {
        clearLocalPassword()
        useKeyOrAgent()
    }

    private func validatePassword() -> Bool {
        guard let error = SSHCredentialPromptPolicy.validationError(for: password) else {
            localValidationError = nil
            return true
        }
        switch error {
        case .empty:
            localValidationError = language.localized(
                "Enter an SSH password before continuing.",
                "请输入 SSH 密码后再继续。"
            )
        case .tooLarge(let maximumBytes):
            localValidationError = language.localized(
                "The SSH password is larger than the supported \(maximumBytes)-byte limit.",
                "SSH 密码超过支持的 \(maximumBytes) 字节上限。"
            )
        case .containsUnsupportedCharacters:
            localValidationError = language.localized(
                "The SSH password cannot contain a null byte or a line break.",
                "SSH 密码不能包含空字节或换行符。"
            )
        }
        return false
    }

    private func clearLocalPassword() {
        password.removeAll(keepingCapacity: false)
    }
}

#if canImport(SwiftTerm)
private struct SwiftTermPTYView: NSViewRepresentable {
    let transcript: String
    let isRunning: Bool
    let isFocused: Bool
    let copyMenuTitle: String
    let sendRaw: (String) -> Void
    let resize: (Int, Int) -> Void
    let onFocus: () -> Void
    let surface: SwiftTermPersistentSurface?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminalSurface = surface ?? context.coordinator.fallbackSurface
        let terminalView = terminalSurface.terminalView
        terminalSurface.update(
            sendRaw: sendRaw,
            resize: resize,
            copyMenuTitle: copyMenuTitle,
            onFocus: onFocus
        )
        terminalSurface.prepareForAttachment()
        terminalSurface.feed(transcript)
        return terminalView
    }

    func updateNSView(_ terminalView: TerminalView, context: Context) {
        let terminalSurface = surface ?? context.coordinator.fallbackSurface
        terminalSurface.update(
            sendRaw: sendRaw,
            resize: resize,
            copyMenuTitle: copyMenuTitle,
            onFocus: onFocus
        )
        terminalSurface.prepareForAttachment()
        terminalSurface.feed(transcript)

        if !isRunning || !isFocused {
            context.coordinator.didFocusRunningSession = false
        }

        if isRunning,
           isFocused,
           !context.coordinator.didFocusRunningSession,
           terminalView.window?.firstResponder !== terminalView {
            context.coordinator.didFocusRunningSession = true
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }

    final class Coordinator {
        let fallbackSurface = SwiftTermPersistentSurface()
        var didFocusRunningSession = false
    }
}

private final class StableSwiftTermTerminalView: TerminalView {
    var copyMenuTitle = "Copy"
    var onFocus: () -> Void = {}
    private var focusEventMonitor: Any?

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI can temporarily lay representable views out at near-zero width
        // during tab/feature switches. Letting SwiftTerm accept that size reflows
        // its local buffer into one or two columns before the remote PTY clamp runs.
        super.setFrameSize(TerminalGridMetrics.clampedPixelSize(newSize))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshFocusEventMonitor()
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocus()
        window?.makeFirstResponder(self)

        switch TerminalRightClickPolicy.action(selectedText: getSelection()) {
        case .showCopyMenu:
            showCopyContextMenu(with: event)
        case .pasteClipboard:
            paste(self)
        }
    }

    deinit {
        if let focusEventMonitor {
            NSEvent.removeMonitor(focusEventMonitor)
        }
    }

    private func refreshFocusEventMonitor() {
        if let focusEventMonitor {
            NSEvent.removeMonitor(focusEventMonitor)
            self.focusEventMonitor = nil
        }

        guard window != nil else { return }
        focusEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  !self.isHidden else {
                return event
            }

            if event.type == .keyDown, self.window?.firstResponder === self {
                self.onFocus()
            } else if event.type == .leftMouseDown {
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.visibleRect.contains(location) else { return event }
                self.onFocus()
            }
            return event
        }
    }

    private func showCopyContextMenu(with event: NSEvent) {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: copyMenuTitle, action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private final class SwiftTermPersistentSurface: NSObject, TerminalViewDelegate {
    let terminalView: StableSwiftTermTerminalView
    private var sendRaw: (String) -> Void = { _ in }
    private var resize: (Int, Int) -> Void = { _, _ in }
    private var transcriptTracker = TerminalTranscriptDeltaTracker()
    private var observedColumns = 0
    private var observedRows = 0
    private var shouldFollowOutput = true

    override init() {
        terminalView = StableSwiftTermTerminalView(
            frame: CGRect(origin: .zero, size: TerminalGridMetrics.preferredPixelSize),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        super.init()
        terminalView.terminalDelegate = self
        terminalView.nativeBackgroundColor = TerminalCanvasView.backgroundColor
        terminalView.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        terminalView.caretColor = NSColor.controlAccentColor
        terminalView.allowMouseReporting = true
        terminalView.backspaceSendsControlH = false
    }

    func update(
        sendRaw: @escaping (String) -> Void,
        resize: @escaping (Int, Int) -> Void,
        copyMenuTitle: String,
        onFocus: @escaping () -> Void
    ) {
        self.sendRaw = sendRaw
        self.resize = resize
        terminalView.copyMenuTitle = copyMenuTitle
        terminalView.onFocus = onFocus
    }

    func prepareForAttachment() {
        let stableSize = TerminalGridMetrics.clampedPixelSize(terminalView.frame.size)
        if terminalView.frame.size != stableSize {
            terminalView.setFrameSize(stableSize)
        }
    }

    func feed(_ transcript: String) {
        let didFeed: Bool

        switch transcriptTracker.update(transcript) {
        case .none:
            return
        case let .append(delta):
            didFeed = feedTerminal(delta)
        case let .reset(replacement):
            terminalView.getTerminal().resetToInitialState()
            terminalView.needsDisplay = true
            if replacement.isEmpty {
                didFeed = false
            } else {
                didFeed = feedTerminal(replacement)
            }
        }

        if didFeed {
            terminalView.needsDisplay = true
        }
    }

    private func feedTerminal(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        terminalView.feed(text: text)

        return true
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendRaw(String(decoding: data, as: UTF8.self))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        let safeGrid = TerminalGridMetrics.clampedGrid(columns: newCols, rows: newRows)
        let safeColumns = safeGrid.columns
        let safeRows = safeGrid.rows
        guard observedColumns != safeColumns || observedRows != safeRows else { return }
        observedColumns = safeColumns
        observedRows = safeRows
        resize(safeColumns, safeRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {
        shouldFollowOutput = TerminalFollowOutputPolicy.shouldFollowAfterUserScroll(position: position)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif

private struct TerminalPTYView: NSViewRepresentable {
    let transcript: String
    let isRunning: Bool
    let isFocused: Bool
    let sendRaw: (String) -> Void
    let resize: (Int, Int) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let terminalView = TerminalCanvasView()
        terminalView.isActivePane = isFocused
        terminalView.onFocus = onFocus
        terminalView.onTerminalInput = { value in
            guard isRunning else { return }
            sendRaw(value)
        }

        let scrollView = TerminalInputScrollView()
        scrollView.terminalView = terminalView
        scrollView.onFocus = onFocus
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TerminalCanvasView.backgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = terminalView
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 12
        scrollView.layer?.masksToBounds = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let terminalView = scrollView.documentView as? TerminalCanvasView else { return }
        terminalView.isActivePane = isFocused
        terminalView.onFocus = onFocus
        (scrollView as? TerminalInputScrollView)?.onFocus = onFocus
        terminalView.onTerminalInput = { value in
            guard isRunning else { return }
            sendRaw(value)
        }

        let gridSize = terminalView.gridSize(for: scrollView.contentView.bounds.size)
        if context.coordinator.observedColumns != gridSize.columns ||
            context.coordinator.observedRows != gridSize.rows {
            context.coordinator.observedColumns = gridSize.columns
            context.coordinator.observedRows = gridSize.rows
            resize(gridSize.columns, gridSize.rows)
        }

        let didUpdate = terminalView.updateTranscript(
            transcript,
            columns: gridSize.columns,
            viewportWidth: scrollView.contentView.bounds.width
        )
        if didUpdate {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(terminalView.bounds.height - scrollView.contentView.bounds.height, 0)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        if !isRunning || !isFocused {
            context.coordinator.didFocusRunningSession = false
        }

        if isRunning,
           isFocused,
           !context.coordinator.didFocusRunningSession,
           terminalView.window?.firstResponder !== terminalView {
            context.coordinator.didFocusRunningSession = true
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }

    final class Coordinator {
        var didFocusRunningSession = false
        var observedColumns = 0
        var observedRows = 0
    }
}

private final class TerminalInputScrollView: NSScrollView {
    weak var terminalView: TerminalCanvasView?
    var onFocus: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onFocus()
        if let terminalView {
            window?.makeFirstResponder(terminalView)
        } else {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let terminalView {
            terminalView.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "v",
              let terminalView else {
            return super.performKeyEquivalent(with: event)
        }

        terminalView.pasteFromClipboard()
        return true
    }
}

private final class TerminalCanvasView: NSView {
    static let backgroundColor = NSColor(red: 0.03, green: 0.04, blue: 0.045, alpha: 1)

    var onTerminalInput: ((String) -> Void)?
    var onFocus: () -> Void = {}
    var isActivePane = false

    private let contentInset = NSSize(width: 14, height: 14)
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    private var renderedTranscript = ""
    private var renderedColumns = 120
    private var displayFrame = TerminalANSIParser.render("PTY-backed SSH session is stopped.", columns: 120)
    private var lineHeight: CGFloat = 18
    private var characterWidth: CGFloat = 8

    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.backgroundColor.cgColor
        lineHeight = font.ascender - font.descender + font.leading + 3
        characterWidth = NSString(string: "W").size(withAttributes: [.font: font]).width
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isActivePane {
            window?.makeFirstResponder(self)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onFocus()
        window?.makeFirstResponder(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocus()
        window?.makeFirstResponder(self)
        pasteFromClipboard()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocus()
        }
        return didBecomeFirstResponder
    }

    func updateTranscript(_ transcript: String, columns: Int, viewportWidth: CGFloat) -> Bool {
        let terminalColumns = max(columns, 1)
        let availableWidth = max(viewportWidth, 360)
        let renderedFrame = TerminalANSIParser.render(transcript, columns: terminalColumns)
        let requiredWidth = max(
            availableWidth,
            CGFloat(renderedFrame.maxColumnCount) * characterWidth + contentInset.width * 2
        )

        if transcript == renderedTranscript,
           terminalColumns == renderedColumns,
           abs(bounds.width - requiredWidth) < 1 {
            return false
        }

        renderedTranscript = transcript
        renderedColumns = terminalColumns
        displayFrame = renderedFrame

        let requiredHeight = max(
            lineHeight * CGFloat(max(displayFrame.lines.count, 1)) + contentInset.height * 2,
            220
        )
        frame = NSRect(x: 0, y: 0, width: requiredWidth, height: requiredHeight)
        needsDisplay = true
        return true
    }

    func gridSize(for viewportSize: NSSize) -> (columns: Int, rows: Int) {
        let width = max(viewportSize.width - contentInset.width * 2, characterWidth)
        let height = max(viewportSize.height - contentInset.height * 2, lineHeight)
        let columns = max(Int(width / characterWidth), TerminalGridMetrics.minimumColumns)
        let rows = max(Int(height / lineHeight), TerminalGridMetrics.minimumRows)
        return (columns, rows)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.backgroundColor.setFill()
        dirtyRect.fill()

        for (index, line) in displayFrame.lines.enumerated() {
            let y = contentInset.height + CGFloat(index) * lineHeight
            draw(line: line, at: NSPoint(x: contentInset.width, y: y))
        }

        if window?.firstResponder === self {
            drawCursor()
        }
    }

    private func draw(line: TerminalDisplayLine, at origin: NSPoint) {
        var x = origin.x

        for run in line.runs {
            let width = CGFloat(run.text.count) * characterWidth
            let style = resolvedStyle(run.style)

            if let background = style.background {
                background.setFill()
                NSBezierPath(rect: NSRect(x: x, y: origin.y, width: width, height: lineHeight)).fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: run.style.isBold ? boldFont : font,
                .foregroundColor: style.foreground
            ]
            NSString(string: run.text).draw(at: origin.applying(CGAffineTransform(translationX: x - origin.x, y: 0)), withAttributes: attributes)
            x += width
        }
    }

    private func resolvedStyle(_ style: TerminalTextStyle) -> (foreground: NSColor, background: NSColor?) {
        let defaultForeground = NSColor(white: style.isDim ? 0.66 : 0.91, alpha: 1)
        let foreground = nsColor(for: style.foreground) ?? defaultForeground
        let background = nsColor(for: style.background)

        if style.isInverse {
            return (background ?? Self.backgroundColor, foreground)
        }

        return (foreground, background)
    }

    private func nsColor(for color: TerminalANSIColor?) -> NSColor? {
        guard let color else { return nil }

        switch color {
        case .basic(let index):
            return basicANSIColor(index)
        case .indexed(let index):
            return indexedANSIColor(index)
        case .rgb(let red, let green, let blue):
            return NSColor(
                calibratedRed: CGFloat(max(0, min(red, 255))) / 255,
                green: CGFloat(max(0, min(green, 255))) / 255,
                blue: CGFloat(max(0, min(blue, 255))) / 255,
                alpha: 1
            )
        }
    }

    private func basicANSIColor(_ index: Int) -> NSColor {
        let palette: [NSColor] = [
            NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 0.86, green: 0.20, blue: 0.22, alpha: 1),
            NSColor(calibratedRed: 0.28, green: 0.74, blue: 0.36, alpha: 1),
            NSColor(calibratedRed: 0.91, green: 0.71, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.96, alpha: 1),
            NSColor(calibratedRed: 0.70, green: 0.42, blue: 0.91, alpha: 1),
            NSColor(calibratedRed: 0.14, green: 0.74, blue: 0.78, alpha: 1),
            NSColor(calibratedWhite: 0.82, alpha: 1),
            NSColor(calibratedWhite: 0.46, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.38, alpha: 1),
            NSColor(calibratedRed: 0.48, green: 0.91, blue: 0.53, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.39, alpha: 1),
            NSColor(calibratedRed: 0.44, green: 0.67, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 0.85, green: 0.58, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 0.31, green: 0.90, blue: 0.93, alpha: 1),
            NSColor(calibratedWhite: 0.95, alpha: 1)
        ]

        return palette[max(0, min(index, palette.count - 1))]
    }

    private func indexedANSIColor(_ index: Int) -> NSColor {
        if index < 16 {
            return basicANSIColor(index)
        }

        if index >= 16, index <= 231 {
            let offset = index - 16
            let red = offset / 36
            let green = (offset % 36) / 6
            let blue = offset % 6

            func component(_ value: Int) -> CGFloat {
                value == 0 ? 0 : CGFloat(55 + value * 40) / 255
            }

            return NSColor(
                calibratedRed: component(red),
                green: component(green),
                blue: component(blue),
                alpha: 1
            )
        }

        let clampedIndex = max(232, min(index, 255))
        let gray = CGFloat(8 + (clampedIndex - 232) * 10) / 255
        return NSColor(calibratedWhite: gray, alpha: 1)
    }

    private func drawCursor() {
        let x = contentInset.width + CGFloat(displayFrame.cursorColumn) * characterWidth
        let y = contentInset.height + CGFloat(max(displayFrame.cursorRow, 0)) * lineHeight + 2
        NSColor.controlAccentColor.setFill()
        NSBezierPath(rect: NSRect(x: x, y: y, width: max(characterWidth * 0.9, 7), height: lineHeight - 4)).fill()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "v" {
                pasteFromClipboard()
            } else {
                super.keyDown(with: event)
            }
            return
        }

        if let sequence = terminalSequence(for: event) {
            onTerminalInput?(sequence)
            return
        }

        if modifiers.contains(.control),
           let controlSequence = controlSequence(for: event) {
            onTerminalInput?(controlSequence)
            return
        }

        if modifiers.contains(.option),
           let characters = event.charactersIgnoringModifiers,
           !characters.isEmpty {
            onTerminalInput?("\u{1b}\(characters)")
            return
        }

        if let characters = event.characters, !characters.isEmpty {
            onTerminalInput?(characters)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return super.performKeyEquivalent(with: event)
        }

        pasteFromClipboard()
        return true
    }

    func pasteFromClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string),
              !value.isEmpty else {
            return
        }

        let normalized = value.replacingOccurrences(of: "\n", with: "\r")
        onTerminalInput?(normalized)
    }

    private func controlSequence(for event: NSEvent) -> String? {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
              scalar.isASCII else {
            return nil
        }

        let value = UInt8(scalar.value)
        if value >= 64, value <= 95 {
            return String(UnicodeScalar(value & 0x1f))
        }

        let uppercase = UInt8(Unicode.Scalar(String(scalar).uppercased())?.value ?? 0)
        guard uppercase >= 64, uppercase <= 95 else { return nil }
        return String(UnicodeScalar(uppercase & 0x1f))
    }

    private func terminalSequence(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76:
            return "\r"
        case 48:
            return "\t"
        case 51:
            return "\u{7f}"
        case 53:
            return "\u{1b}"
        case 115:
            return "\u{1b}[1~"
        case 117:
            return "\u{1b}[3~"
        case 119:
            return "\u{1b}[4~"
        case 121:
            return "\u{1b}[6~"
        case 123:
            return "\u{1b}[D"
        case 124:
            return "\u{1b}[C"
        case 125:
            return "\u{1b}[B"
        case 126:
            return "\u{1b}[A"
        default:
            return nil
        }
    }
}

private enum TerminalDisplaySanitizer {
    static func clean(_ text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character == "\u{001B}" {
                index = skipEscapeSequence(in: text, from: index)
                continue
            }

            if character == "\u{0008}" {
                if !result.isEmpty {
                    result.removeLast()
                }
                index = text.index(after: index)
                continue
            }

            if character == "\r" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\n" {
                    index = next
                } else {
                    result.append("\n")
                }
                index = text.index(after: index)
                continue
            }

            if character == "\u{0007}" {
                index = text.index(after: index)
                continue
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    private static func skipEscapeSequence(in text: String, from start: String.Index) -> String.Index {
        var index = text.index(after: start)
        guard index < text.endIndex else { return index }

        switch text[index] {
        case "[":
            index = text.index(after: index)
            while index < text.endIndex {
                let scalar = text[index].unicodeScalars.first?.value ?? 0
                index = text.index(after: index)
                if scalar >= 0x40, scalar <= 0x7e {
                    break
                }
            }
            return index
        case "]":
            index = text.index(after: index)
            while index < text.endIndex {
                if text[index] == "\u{0007}" {
                    return text.index(after: index)
                }
                if text[index] == "\u{001B}" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\\" {
                        return text.index(after: next)
                    }
                }
                index = text.index(after: index)
            }
            return index
        case "(", ")", "*", "+", "-", ".", "/":
            return text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
        default:
            return text.index(after: index)
        }
    }
}

private struct PasswordPanel: View {
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    @State private var secret = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(language.localized("Local Password Vault", "本地密码库"))

            PasswordRevealField(
                language.localized("Password or passphrase", "密码或密钥口令"),
                text: $secret,
                accessibilityIdentifier: "credential-secret-field"
            )

            SSHPasswordInputMetadata(password: secret)

            HStack {
                Button {
                    save()
                } label: {
                    Label(language.localized("Save to Vault", "保存到密码库"), systemImage: "lock.doc")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("save-credential-button")
                .disabled(!session.isConnectable || secret.isEmpty)

                Button {
                    load()
                } label: {
                    Label(language.localized("Check Saved", "检查已保存"), systemImage: "magnifyingglass")
                }
                .disabled(!session.isConnectable)

                Button(role: .destructive) {
                    delete()
                } label: {
                    Label(language.localized("Delete", "删除"), systemImage: "trash")
                }
                .disabled(!session.isConnectable)
            }

            Text(status ?? language.localized("No password loaded.", "尚未读取密码。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(language.localized(
                "Passwords are stored in the local encrypted SQLite vault. JTS Terminal reads saved values for SSH, SFTP, SCP, and tunnel workflows when a password is needed. For key authentication, choose the private key with Browse in Server Properties, or load it into the macOS ssh-agent with ssh-add. Third-party agents such as 1Password or Secretive cannot be reached from App Sandbox.",
                "密码会保存到本地加密 SQLite 密码库。JTS Terminal 的 SSH、SFTP、SCP 和隧道流程会在需要密码时读取这里保存的值。使用密钥认证时，请在服务器属性中通过“浏览”选择私钥，或用 ssh-add 将密钥载入 macOS 自带的 ssh-agent。App Sandbox 无法访问 1Password、Secretive 等第三方 agent。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .panelBackground()
    }

    private func save() {
        let account = CredentialStore.account(for: session)
        let address = session.localizedAddress(language: language)
        let secretToSave = secret
        status = language.localized("Saving password to local encrypted vault...", "正在保存密码到本地加密密码库...")

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SSHCredentialVaultAccess.save(secret: secretToSave, account: account)
                }.value
                secret = ""
                status = language.localized("Password saved for \(address).", "已为 \(address) 保存密码。")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func load() {
        let account = CredentialStore.account(for: session)
        status = language.localized("Checking local encrypted vault...", "正在检查本地加密密码库...")

        Task {
            do {
                let stored = try await Task.detached(priority: .userInitiated) {
                    try SSHCredentialVaultAccess.read(account: account)
                }.value
                status = stored == nil
                    ? language.localized("No password saved.", "未保存密码。")
                    : language.localized("Password exists in the local encrypted vault.", "本地加密密码库中已有密码。")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func delete() {
        let account = CredentialStore.account(for: session)
        status = language.localized("Deleting saved password...", "正在删除保存的密码...")

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SSHCredentialVaultAccess.delete(account: account)
                }.value
                status = language.localized("Password deleted.", "密码已删除。")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

private struct ProfilePortabilityPanel: View {
    @Environment(\.appLanguage) private var language
    let session: RemoteSession
    let sessions: [RemoteSession]
    let importProfiles: ([RemoteSessionProfile]) -> Void
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(language.localized("Import / Export Profiles", "导入导出配置"))

            HStack {
                Button {
                    export([session], suggestedName: safeFilename(session.name.nilIfBlank ?? session.host.nilIfBlank ?? "session"))
                } label: {
                    Label(language.localized("Export Current", "导出当前"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    export(sessions, suggestedName: "jts-terminal-mac-sessions")
                } label: {
                    Label(language.localized("Export All", "全部导出"), systemImage: "archivebox")
                }
                .buttonStyle(.borderedProminent)
                .disabled(sessions.isEmpty)

                Button {
                    importFile()
                } label: {
                    Label(language.localized("Import", "导入"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }

            Text(status ?? language.localized(
                "Exported profiles do not include saved password secrets.",
                "导出的配置不包含已保存的密码。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(20)
        .panelBackground()
    }

    private func export(_ sessions: [RemoteSession], suggestedName: String) {
        do {
            let data = try SessionProfileCodec.encode(sessions: sessions)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(suggestedName).json"
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else {
                status = language.localized("Export cancelled.", "已取消导出。")
                return
            }

            try data.write(to: url, options: .atomic)
            status = language.localized(
                "Exported \(sessions.count) profile(s) to \(url.lastPathComponent). Saved password secrets were not exported.",
                "已将 \(sessions.count) 个配置导出到 \(url.lastPathComponent)。已保存的密码未被导出。"
            )
        } catch {
            status = language.localized(
                "Export failed: \(error.localizedDescription)",
                "导出失败：\(error.localizedDescription)"
            )
        }
    }

    private func importFile() {
        do {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else {
                status = language.localized("Import cancelled.", "已取消导入。")
                return
            }

            let profiles = try SessionProfileCodec.decode(Data(contentsOf: url))
            importProfiles(profiles)
            status = language.localized(
                "Imported \(profiles.count) profile(s) from \(url.lastPathComponent). Passwords are never imported; JTS Terminal will ask before the first password-based connection.",
                "已从 \(url.lastPathComponent) 导入 \(profiles.count) 个配置。密码不会被导入；首次使用密码连接前 JTS Terminal 会询问。"
            )
        } catch {
            status = language.localized(
                "Import failed: \(error.localizedDescription)",
                "导入失败：\(error.localizedDescription)"
            )
        }
    }

    private func safeFilename(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
}

private struct EmptyWorkspace: View {
    @Environment(\.appLanguage) private var language
    let addSession: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(language.localized("No Server Selected", "未选择服务器"), systemImage: "server.rack")
        } description: {
            Text(language.localized(
                "Add an SSH server, a Local Shell or a remote desktop to get started.",
                "添加 SSH 服务器、本地 Shell 或远程桌面即可开始。"
            ))
        } actions: {
            Button(language.localized("Add Server", "添加服务器"), action: addSession)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("empty-workspace-content")
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

private enum AppTheme {
    static let signal = Color.accentColor
    static let signalSoft = Color.accentColor.opacity(0.12)
    static let ember = Color.orange
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .controlBackgroundColor)
    static let panel = Color(nsColor: .textBackgroundColor)
    static let surface = Color(nsColor: .quaternaryLabelColor).opacity(0.18)
    static let border = Color(nsColor: .separatorColor).opacity(0.55)
    static let selection = Color.accentColor.opacity(0.14)
    static let selectionBorder = Color.accentColor.opacity(0.28)
    static let selectionStrong = Color.accentColor.opacity(0.20)
    static let selectionBorderStrong = Color.accentColor.opacity(0.42)
}

private struct PanelBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.025), radius: 8, x: 0, y: 3)
    }
}

private extension View {
    func panelBackground(cornerRadius: CGFloat = 24) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var nilIfBlank: String? {
        isBlank ? nil : self
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                RemoteSession.self,
                SavedSSHTunnel.self,
                CommandHistoryEntry.self,
                SavedCommandMacro.self
            ],
            inMemory: true
        )
}
