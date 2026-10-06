//
//  TerminalWorkspaceState.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import Combine
import Foundation
import SwiftData

@MainActor
struct TerminalWorkspaceOpenResult {
    var info: TerminalMCPBridgeTerminal
    var processSession: InteractiveProcessSession
    var didStart: Bool
    var mcpControlAuthorized: Bool
}

struct TerminalWorkspaceNavigationRequest: Equatable {
    let id = UUID()
    let sessionID: PersistentIdentifier
}

@MainActor
final class TerminalWorkspaceState: ObservableObject {
    static let maximumPanesPerTab = 4

    enum SplitAxis: String, Equatable {
        /// Places panes beside one another, separated by a vertical divider.
        case horizontal
        /// Places panes above and below one another, separated by a horizontal divider.
        case vertical
    }

    indirect enum LayoutNode: Equatable {
        case pane(UUID)
        case split(
            id: UUID,
            axis: SplitAxis,
            first: LayoutNode,
            second: LayoutNode
        )

        var paneIDs: [UUID] {
            switch self {
            case .pane(let paneID):
                return [paneID]
            case .split(_, _, let first, let second):
                return first.paneIDs + second.paneIDs
            }
        }

        func splitting(
            paneID: UUID,
            with newPaneID: UUID,
            axis: SplitAxis
        ) -> LayoutNode? {
            switch self {
            case .pane(let existingPaneID):
                guard existingPaneID == paneID else { return nil }
                return .split(
                    id: UUID(),
                    axis: axis,
                    first: .pane(existingPaneID),
                    second: .pane(newPaneID)
                )
            case .split(let id, let existingAxis, let first, let second):
                if let updatedFirst = first.splitting(
                    paneID: paneID,
                    with: newPaneID,
                    axis: axis
                ) {
                    return .split(
                        id: id,
                        axis: existingAxis,
                        first: updatedFirst,
                        second: second
                    )
                }
                if let updatedSecond = second.splitting(
                    paneID: paneID,
                    with: newPaneID,
                    axis: axis
                ) {
                    return .split(
                        id: id,
                        axis: existingAxis,
                        first: first,
                        second: updatedSecond
                    )
                }
                return nil
            }
        }

        func removing(paneID: UUID) -> LayoutNode? {
            switch self {
            case .pane(let existingPaneID):
                return existingPaneID == paneID ? nil : self
            case .split(let id, let axis, let first, let second):
                let firstContainsPane = first.paneIDs.contains(paneID)
                let secondContainsPane = second.paneIDs.contains(paneID)
                guard firstContainsPane || secondContainsPane else { return self }

                let updatedFirst = firstContainsPane ? first.removing(paneID: paneID) : first
                let updatedSecond = secondContainsPane ? second.removing(paneID: paneID) : second
                switch (updatedFirst, updatedSecond) {
                case (nil, nil):
                    return nil
                case (nil, let remaining?):
                    return remaining
                case (let remaining?, nil):
                    return remaining
                case (let updatedFirst?, let updatedSecond?):
                    return .split(
                        id: id,
                        axis: axis,
                        first: updatedFirst,
                        second: updatedSecond
                    )
                }
            }
        }
    }

    struct Tab: Identifiable, Equatable {
        let id: UUID
        var panes: [Pane]
        var layout: LayoutNode
        var focusedPaneID: UUID?

        init(
            id: UUID = UUID(),
            panes: [Pane],
            layout: LayoutNode? = nil,
            focusedPaneID: UUID? = nil
        ) {
            precondition(!panes.isEmpty, "A terminal tab must begin with one pane.")
            self.id = id
            self.panes = panes
            self.layout = layout ?? .pane(panes[0].id)
            self.focusedPaneID = focusedPaneID ?? panes.first?.id
        }
    }

    struct Pane: Identifiable, Equatable {
        let id: UUID
        var kind: Kind
        var mcpName: String

        init(id: UUID = UUID(), kind: Kind, mcpName: String = "") {
            self.id = id
            self.kind = kind
            self.mcpName = mcpName
        }
    }

    enum Kind: String, CaseIterable, Equatable {
        case ssh
        case localShell

        func isAvailable(for connectionType: RemoteConnectionType) -> Bool {
            switch (self, connectionType) {
            case (.ssh, .ssh), (.localShell, .localShell):
                return true
            case (.ssh, _), (.localShell, _):
                return false
            }
        }

        static func preferredTerminalKind(for session: RemoteSession) -> Kind? {
            switch session.connectionType {
            case .ssh:
                return .ssh
            case .localShell:
                return .localShell
            case .rdp, .macDesktop:
                return nil
            }
        }
    }

    @Published private(set) var tabs: [Tab]
    @Published var selectedTabID: UUID?
    private var processSessions: [UUID: InteractiveProcessSession] = [:]
    private var terminalSurfaces: [UUID: AnyObject] = [:]

    init(initialKind: Kind = .ssh) {
        let firstTab = Tab(panes: [Pane(kind: initialKind)])
        self.tabs = [firstTab]
        self.selectedTabID = firstTab.id
    }

    var selectedTab: Tab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    var selectedPane: Pane? {
        guard let tab = selectedTab else { return nil }
        if let focusedPaneID = tab.focusedPaneID,
           let focusedPane = tab.panes.first(where: { $0.id == focusedPaneID }) {
            return focusedPane
        }
        return tab.panes.first
    }

    var canSplitSelectedPane: Bool {
        guard let tab = selectedTab else { return false }
        return !tab.panes.isEmpty && tab.panes.count < Self.maximumPanesPerTab
    }

    func canSplitSelectedPane(
        axis: SplitAxis,
        availableSize: CGSize
    ) -> Bool {
        guard canSplitSelectedPane,
              let tab = selectedTab,
              let sourcePaneID = selectedPane?.id,
              let candidateLayout = tab.layout.splitting(
                  paneID: sourcePaneID,
                  with: UUID(),
                  axis: axis
              ) else {
            return false
        }
        return TerminalSplitLayoutPolicy.fits(
            candidateLayout,
            in: availableSize
        )
    }

    var runningProcessSummaries: [String] {
        tabs.enumerated().flatMap { tabIndex, tab in
            tab.panes.enumerated().compactMap { paneIndex, pane in
                guard let processSession = processSessions[pane.id],
                      processSession.isRunning else {
                    return nil
                }

                let kindLabel: String
                switch pane.kind {
                case .ssh:
                    kindLabel = "SSH"
                case .localShell:
                    kindLabel = "Local shell"
                }

                let pidLabel = processSession.pid.map { " pid \($0)" } ?? ""
                return "\(paneTitle(tabIndex: tabIndex, paneIndex: paneIndex)): \(kindLabel)\(pidLabel)"
            }
        }
    }

    var hasRunningProcesses: Bool {
        !runningProcessSummaries.isEmpty
    }

    func addTab(kind: Kind) {
        let tab = Tab(panes: [Pane(kind: kind)])
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func ensureTabIfEmpty(kind: Kind) {
        guard tabs.isEmpty else {
            if selectedTabID == nil {
                selectedTabID = tabs.first?.id
            }
            return
        }

        addTab(kind: kind)
    }

    func closeSelectedTab() {
        guard let selectedTabID else { return }
        closeTab(id: selectedTabID)
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let panesToClose = tabs[index].panes
        for pane in panesToClose {
            releaseResources(for: pane.id)
        }
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedTabID = nil
            return
        }

        if selectedTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
        }
    }

    @discardableResult
    func splitSelectedPane(axis: SplitAxis) -> Pane? {
        guard let tabID = selectedTab?.id,
              let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              !tabs[tabIndex].panes.isEmpty,
              tabs[tabIndex].panes.count < Self.maximumPanesPerTab else {
            return nil
        }

        let sourceIndex = focusedPaneIndex(in: tabs[tabIndex]) ?? 0
        let sourcePane = tabs[tabIndex].panes[sourceIndex]
        let newPane = Pane(kind: sourcePane.kind)
        guard let updatedLayout = tabs[tabIndex].layout.splitting(
            paneID: sourcePane.id,
            with: newPane.id,
            axis: axis
        ) else {
            return nil
        }

        tabs[tabIndex].panes.insert(newPane, at: sourceIndex + 1)
        tabs[tabIndex].layout = updatedLayout
        tabs[tabIndex].focusedPaneID = newPane.id
        return newPane
    }

    @discardableResult
    func splitSelectedPane(
        axis: SplitAxis,
        availableSize: CGSize
    ) -> Pane? {
        guard canSplitSelectedPane(
            axis: axis,
            availableSize: availableSize
        ) else {
            return nil
        }
        return splitSelectedPane(axis: axis)
    }

    func focusPane(id paneID: UUID) {
        guard let location = paneLocation(for: paneID) else { return }
        let tabID = tabs[location.tabIndex].id
        let needsTabSelection = selectedTabID != tabID
        let needsPaneFocus = tabs[location.tabIndex].focusedPaneID != paneID
        guard needsTabSelection || needsPaneFocus else { return }

        if needsPaneFocus {
            tabs[location.tabIndex].focusedPaneID = paneID
        }
        if needsTabSelection {
            selectedTabID = tabID
        }
    }

    func closeFocusedPane() {
        guard let paneID = selectedPane?.id else { return }
        closePane(id: paneID)
    }

    func closePane(id paneID: UUID) {
        guard let location = paneLocation(for: paneID) else { return }
        let tabID = tabs[location.tabIndex].id

        if tabs[location.tabIndex].panes.count == 1 {
            closeTab(id: tabID)
            return
        }

        releaseResources(for: paneID)
        tabs[location.tabIndex].panes.remove(at: location.paneIndex)
        if let updatedLayout = tabs[location.tabIndex].layout.removing(paneID: paneID) {
            tabs[location.tabIndex].layout = updatedLayout
        } else {
            // The last pane is handled above, so reaching this branch means the
            // model was inconsistent. Close the tab rather than leaving a
            // non-renderable workspace behind.
            closeTab(id: tabID)
            return
        }

        if tabs[location.tabIndex].focusedPaneID == paneID {
            let replacementIndex = min(
                location.paneIndex,
                tabs[location.tabIndex].panes.count - 1
            )
            tabs[location.tabIndex].focusedPaneID =
                tabs[location.tabIndex].panes[replacementIndex].id
        }
    }

    func processSession(for pane: Pane) -> InteractiveProcessSession? {
        guard paneLocation(for: pane.id) != nil else {
            return nil
        }
        if let existing = processSessions[pane.id] {
            return existing
        }

        let session = InteractiveProcessSession()
        processSessions[pane.id] = session
        return session
    }

    func stopProcess(for pane: Pane) {
        processSessions[pane.id]?.stop()
    }

    func terminalSurface(for pane: Pane, make: () -> AnyObject) -> AnyObject? {
        guard paneLocation(for: pane.id) != nil else {
            return nil
        }
        if let existing = terminalSurfaces[pane.id] {
            return existing
        }

        let surface = make()
        terminalSurfaces[pane.id] = surface
        return surface
    }

    func setMCPName(_ name: String, for paneID: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for tabIndex in tabs.indices {
            guard let paneIndex = tabs[tabIndex].panes.firstIndex(where: { $0.id == paneID }) else {
                continue
            }
            tabs[tabIndex].panes[paneIndex].mcpName = trimmed
            return
        }
    }

    func mcpDisplayName(for pane: Pane, session: RemoteSession) -> String {
        let explicitName = pane.mcpName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitName.isEmpty {
            return explicitName
        }
        guard let location = paneLocation(for: pane.id) else {
            return "\(session.effectiveMCPAlias) terminal"
        }
        return "\(session.effectiveMCPAlias) · \(paneTitle(tabIndex: location.tabIndex, paneIndex: location.paneIndex))"
    }

    func openSSHTerminal(for session: RemoteSession) -> TerminalWorkspaceOpenResult {
        openTerminal(for: session, kind: .ssh)
    }

    func openPreferredTerminal(for session: RemoteSession) -> TerminalWorkspaceOpenResult? {
        guard let kind = Kind.preferredTerminalKind(for: session) else { return nil }
        return openTerminal(for: session, kind: kind)
    }

    private func openTerminal(for session: RemoteSession, kind: Kind) -> TerminalWorkspaceOpenResult {
        let resolved = resolvePane(kind: kind)
        guard let processSession = processSession(for: resolved.pane) else {
            preconditionFailure("Resolved terminal pane must belong to its workspace.")
        }
        let didStart = !processSession.isRunning
        if didStart {
            switch kind {
            case .ssh:
                processSession.startSSH(session: session)
            case .localShell:
                processSession.startLocalShell()
            }
        }

        return TerminalWorkspaceOpenResult(
            info: terminalInfo(
                for: session,
                pane: resolved.pane,
                tabIndex: resolved.tabIndex,
                paneIndex: resolved.paneIndex,
                processSession: processSession
            ),
            processSession: processSession,
            didStart: didStart,
            mcpControlAuthorized: session.mcpAlwaysAllowTerminalControl || processSession.isMCPControlEnabled
        )
    }

    func stopAllProcesses() {
        for processSession in processSessions.values {
            processSession.stop()
        }
    }

    func revokeMCPControl() {
        for processSession in processSessions.values {
            processSession.setMCPControlEnabled(false)
        }
    }

    func broadcastTargets(for session: RemoteSession) -> [TerminalBroadcastTarget] {
        guard session.isConnectable,
              let expectedKind = Kind.preferredTerminalKind(for: session) else {
            return []
        }

        let profileName = session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? session.address
            : session.name
        return tabs.enumerated().flatMap { tabIndex, tab in
            tab.panes.enumerated().compactMap { paneIndex, pane in
                guard pane.kind == expectedKind,
                      let processSession = processSessions[pane.id] else {
                    return nil
                }
                return TerminalBroadcastTarget(
                    id: pane.id,
                    profileName: profileName,
                    address: session.address,
                    paneTitle: paneTitle(tabIndex: tabIndex, paneIndex: paneIndex),
                    kind: pane.kind,
                    reviewedPID: processSession.pid,
                    reviewedGeneration: processSession.executionGeneration,
                    processSession: processSession
                )
            }
        }
    }

    func dispose() {
        let paneIDs = tabs.flatMap { $0.panes.map(\.id) }
        for paneID in paneIDs {
            releaseResources(for: paneID)
        }
        tabs.removeAll()
        selectedTabID = nil
    }

    func authorizedOpenTerminals(for session: RemoteSession) -> [TerminalMCPAttachedTerminal] {
        guard session.mcpEnabled,
              session.isConnectable,
              let expectedKind = Kind.preferredTerminalKind(for: session) else {
            return []
        }

        return tabs.enumerated().flatMap { tabIndex, tab in
            tab.panes.enumerated().compactMap { paneIndex, pane in
                guard pane.kind == expectedKind,
                      let processSession = processSessions[pane.id],
                      processSession.isRunning else {
                    return nil
                }
                guard session.mcpAlwaysAllowTerminalControl || processSession.isMCPControlEnabled else {
                    return nil
                }

                let info = terminalInfo(
                    for: session,
                    pane: pane,
                    tabIndex: tabIndex,
                    paneIndex: paneIndex,
                    processSession: processSession
                )
                return TerminalMCPAttachedTerminal(
                    info: info,
                    remoteSession: session,
                    processSession: processSession
                )
            }
        }
    }

    private func resolvePane(kind: Kind) -> (tabIndex: Int, paneIndex: Int, pane: Pane) {
        ensureTabIfEmpty(kind: kind)

        if let selectedTabID,
           let tabIndex = tabs.firstIndex(where: { $0.id == selectedTabID }),
           let paneIndex = preferredPaneIndex(in: tabs[tabIndex], kind: kind) {
            tabs[tabIndex].focusedPaneID = tabs[tabIndex].panes[paneIndex].id
            return (tabIndex, paneIndex, tabs[tabIndex].panes[paneIndex])
        }

        for tabIndex in tabs.indices {
            if let paneIndex = tabs[tabIndex].panes.firstIndex(where: { $0.kind == kind }) {
                selectedTabID = tabs[tabIndex].id
                tabs[tabIndex].focusedPaneID = tabs[tabIndex].panes[paneIndex].id
                return (tabIndex, paneIndex, tabs[tabIndex].panes[paneIndex])
            }
        }

        addTab(kind: kind)
        let tabIndex = tabs.count - 1
        return (tabIndex, 0, tabs[tabIndex].panes[0])
    }

    private func paneLocation(for paneID: UUID) -> (tabIndex: Int, paneIndex: Int)? {
        for tabIndex in tabs.indices {
            if let paneIndex = tabs[tabIndex].panes.firstIndex(where: { $0.id == paneID }) {
                return (tabIndex, paneIndex)
            }
        }
        return nil
    }

    private func focusedPaneIndex(in tab: Tab) -> Int? {
        guard let focusedPaneID = tab.focusedPaneID else { return nil }
        return tab.panes.firstIndex(where: { $0.id == focusedPaneID })
    }

    private func preferredPaneIndex(in tab: Tab, kind: Kind) -> Int? {
        if let focusedPaneIndex = focusedPaneIndex(in: tab),
           tab.panes[focusedPaneIndex].kind == kind {
            return focusedPaneIndex
        }
        return tab.panes.firstIndex(where: { $0.kind == kind })
    }

    private func releaseResources(for paneID: UUID) {
        processSessions[paneID]?.stop()
        processSessions[paneID] = nil
        terminalSurfaces[paneID] = nil
    }

    private func paneTitle(tabIndex: Int, paneIndex: Int) -> String {
        let tabTitle = "Terminal tab \(tabIndex + 1)"
        guard tabs.indices.contains(tabIndex),
              tabs[tabIndex].panes.count > 1 else {
            return tabTitle
        }
        return "\(tabTitle), pane \(paneIndex + 1)"
    }

    private func terminalInfo(
        for session: RemoteSession,
        pane: Pane,
        tabIndex: Int,
        paneIndex: Int,
        processSession: InteractiveProcessSession
    ) -> TerminalMCPBridgeTerminal {
        let paneTitle = paneTitle(tabIndex: tabIndex, paneIndex: paneIndex)
        let displayName = session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? session.address
            : session.name
        return TerminalMCPBridgeTerminal(
            terminalID: pane.id.uuidString,
            serverAlias: session.effectiveMCPAlias,
            connectionType: session.connectionType.rawValue,
            displayName: displayName,
            mcpName: mcpDisplayName(for: pane, session: session),
            pid: processSession.pid,
            paneTitle: paneTitle,
            automationRecoveryRequired:
                processSession.requiresStructuredCommandRecovery
        )
    }

}

@MainActor
final class TerminalWorkspaceStore: ObservableObject {
    @Published private(set) var navigationRequest: TerminalWorkspaceNavigationRequest?
    private var workspaces: [PersistentIdentifier: TerminalWorkspaceState] = [:]

    func workspace(
        for sessionID: PersistentIdentifier,
        initialKind: TerminalWorkspaceState.Kind = .ssh
    ) -> TerminalWorkspaceState {
        if let existing = workspaces[sessionID] {
            return existing
        }

        let workspace = TerminalWorkspaceState(initialKind: initialKind)
        workspaces[sessionID] = workspace
        return workspace
    }

    @discardableResult
    func ensureTabIfEmpty(
        for sessionID: PersistentIdentifier,
        kind: TerminalWorkspaceState.Kind = .ssh
    ) -> TerminalWorkspaceState {
        let workspace = workspace(for: sessionID, initialKind: kind)
        workspace.ensureTabIfEmpty(kind: kind)
        return workspace
    }

    var runningProcessSummaries: [String] {
        workspaces.values.flatMap(\.runningProcessSummaries)
    }

    var hasRunningProcesses: Bool {
        workspaces.values.contains(where: \.hasRunningProcesses)
    }

    func stopAllProcesses() {
        for workspace in workspaces.values {
            workspace.stopAllProcesses()
        }
    }

    func revokeAllMCPControl() {
        for workspace in workspaces.values {
            workspace.revokeMCPControl()
        }
    }

    func removeWorkspace(for sessionID: PersistentIdentifier) {
        guard let workspace = workspaces.removeValue(forKey: sessionID) else { return }
        workspace.dispose()
        if navigationRequest?.sessionID == sessionID {
            navigationRequest = nil
        }
    }

    @discardableResult
    func openSSHTerminal(for session: RemoteSession) -> TerminalWorkspaceOpenResult {
        let workspace = workspace(for: session.persistentModelID, initialKind: .ssh)
        let result = workspace.openSSHTerminal(for: session)
        navigationRequest = TerminalWorkspaceNavigationRequest(sessionID: session.persistentModelID)
        return result
    }

    @discardableResult
    func openPreferredTerminal(for session: RemoteSession) -> TerminalWorkspaceOpenResult? {
        guard let kind = TerminalWorkspaceState.Kind.preferredTerminalKind(for: session) else { return nil }
        let workspace = workspace(for: session.persistentModelID, initialKind: kind)
        guard let result = workspace.openPreferredTerminal(for: session) else { return nil }
        navigationRequest = TerminalWorkspaceNavigationRequest(sessionID: session.persistentModelID)
        return result
    }

    func authorizedOpenTerminals(sessions: [RemoteSession]) -> [TerminalMCPAttachedTerminal] {
        sessions.flatMap { session in
            guard let workspace = workspaces[session.persistentModelID] else {
                return [TerminalMCPAttachedTerminal]()
            }
            return workspace.authorizedOpenTerminals(for: session)
        }
    }

    func broadcastTargets(sessions: [RemoteSession]) -> [TerminalBroadcastTarget] {
        sessions.flatMap { session in
            workspaces[session.persistentModelID]?.broadcastTargets(for: session) ?? []
        }
    }
}

@MainActor
final class SSHTunnelManagerStore: ObservableObject {
    private var managers: [PersistentIdentifier: SSHTunnelManager] = [:]

    func manager(for sessionID: PersistentIdentifier) -> SSHTunnelManager {
        if let existing = managers[sessionID] {
            return existing
        }

        let manager = SSHTunnelManager()
        managers[sessionID] = manager
        return manager
    }

    var runningTunnelSummaries: [String] {
        managers.values.compactMap(\.runningSummary)
    }

    var hasRunningTunnels: Bool {
        managers.values.contains(where: \.hasActiveOrScheduledWork)
    }

    func stopAllTunnels() {
        for manager in managers.values where manager.hasActiveOrScheduledWork {
            manager.stop()
        }
    }
}
