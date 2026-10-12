//
//  ServerSidebar.swift
//  JTSTerminal
//

import SwiftData
import SwiftUI

/// The main window's server list: a native sidebar List with folder sections,
/// keyboard selection, search, the Delete key and double-click to open.
struct ServerSidebar: View {
    @Environment(\.appLanguage) private var language
    let sessions: [RemoteSession]
    @Binding var selectedSessionID: PersistentIdentifier?
    @Binding var searchText: String
    let addSession: () -> Void
    let addGroup: () -> Void
    let deleteSessions: ([RemoteSession]) -> Void
    let selectSession: (RemoteSession) -> Void
    let openProperties: (RemoteSession) -> Void
    let openSession: (RemoteSession) -> Void
    @State private var sessionsPendingDeletion: [RemoteSession] = []

    var body: some View {
        List(selection: selection) {
            ForEach(groupedSessions, id: \.folder) { group in
                Section(sectionTitle(for: group.folder)) {
                    ForEach(group.sessions) { session in
                        ServerSidebarRow(session: session)
                            .tag(session.persistentModelID)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if groupedSessions.isEmpty {
                emptyState
                    .accessibilityIdentifier("sidebar-empty-state")
            }
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { identifiers in
            contextMenu(for: identifiers)
        } primaryAction: { identifiers in
            guard let session = session(for: identifiers) else { return }
            if session.isConnectable {
                openSession(session)
            } else {
                openProperties(session)
            }
        }
        .onDeleteCommand {
            if let selectedSession {
                sessionsPendingDeletion = [selectedSession]
            }
        }
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: Text(language.localized("Search", "搜索"))
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { !sessionsPendingDeletion.isEmpty },
                set: { if !$0 { sessionsPendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(language.localized("Delete", "删除"), role: .destructive) {
                let pending = sessionsPendingDeletion
                sessionsPendingDeletion = []
                deleteSessions(pending)
            }
            Button(language.localized("Cancel", "取消"), role: .cancel) {
                sessionsPendingDeletion = []
            }
        } message: {
            Text(language.localized(
                "Its open terminals, tunnels and desktops are closed. Saved passwords stay available to other profiles that use the same account.",
                "该服务器打开的终端、隧道和桌面会被关闭。保存的密码会保留，供使用同一账号的其他配置继续使用。"
            ))
        }
    }

    /// Selecting an incomplete draft opens its properties instead of making
    /// it the main workspace, matching the main window's selection policy.
    private var selection: Binding<PersistentIdentifier?> {
        Binding(
            get: { selectedSessionID },
            set: { newValue in
                guard let newValue,
                      let session = sessions.first(where: { $0.persistentModelID == newValue }) else {
                    return
                }
                selectSession(session)
            }
        )
    }

    private var selectedSession: RemoteSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.persistentModelID == selectedSessionID }
    }

    private var hasSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredSessions: [RemoteSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            [
                session.name,
                session.host,
                session.username,
                session.address,
                session.folder,
                session.connectionType.displayName,
                session.rdpProfile.domain,
            ]
            .contains { $0.lowercased().contains(query) }
        }
    }

    private var groupedSessions: [(folder: String, sessions: [RemoteSession])] {
        Dictionary(grouping: filteredSessions, by: \.folderDisplayName)
            .map { (folder: $0.key, sessions: $0.value.sorted(by: Self.isOrderedBefore)) }
            .sorted { lhs, rhs in
                if lhs.folder == Self.ungroupedFolder { return false }
                if rhs.folder == Self.ungroupedFolder { return true }
                return lhs.folder.localizedCaseInsensitiveCompare(rhs.folder) == .orderedAscending
            }
    }

    private static let ungroupedFolder = "Ungrouped"

    private static func isOrderedBefore(_ lhs: RemoteSession, _ rhs: RemoteSession) -> Bool {
        let order = displayName(lhs).localizedStandardCompare(displayName(rhs))
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return lhs.createdAt < rhs.createdAt
    }

    private static func displayName(_ session: RemoteSession) -> String {
        session.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sectionTitle(for folder: String) -> String {
        folder == Self.ungroupedFolder
            ? language.localized("Ungrouped", "未分组")
            : folder
    }

    private func session(for identifiers: Set<PersistentIdentifier>) -> RemoteSession? {
        guard identifiers.count == 1, let identifier = identifiers.first else { return nil }
        return sessions.first { $0.persistentModelID == identifier }
    }

    @ViewBuilder
    private func contextMenu(for identifiers: Set<PersistentIdentifier>) -> some View {
        if let session = session(for: identifiers) {
            if session.isConnectable {
                Button(language.localized("Open", "打开")) {
                    openSession(session)
                }
            }
            Button(language.localized("Server Properties", "服务器属性")) {
                openProperties(session)
            }
            Divider()
            Button(language.localized("Delete Server…", "删除服务器…"), role: .destructive) {
                sessionsPendingDeletion = [session]
            }
            .accessibilityIdentifier("server-row-delete-button")
        } else {
            Button(language.localized("New Server", "新建服务器"), action: addSession)
                .accessibilityIdentifier("sidebar-context-new-server-button")
            Button(language.localized("New Group", "新建分组"), action: addGroup)
                .accessibilityIdentifier("sidebar-context-new-group-button")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasSearch {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView {
                Label(language.localized("No Servers", "还没有服务器"), systemImage: "server.rack")
            } description: {
                Text(language.localized(
                    "Add an SSH server, a Local Shell or a remote desktop.",
                    "添加 SSH 服务器、本地 Shell 或远程桌面。"
                ))
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            Button(action: addSession) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .help(language.localized("New Server", "新建服务器"))
            .accessibilityLabel(language.localized("New Server", "新建服务器"))
            .accessibilityIdentifier("add-server-button")

            Button(action: addGroup) {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .help(language.localized("New Group", "新建分组"))
            .accessibilityLabel(language.localized("New Group", "新建分组"))
            .accessibilityIdentifier("add-group-button")

            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var deletionTitle: String {
        if sessionsPendingDeletion.count == 1, let session = sessionsPendingDeletion.first {
            let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? language.localized("Unnamed Server", "未命名服务器") : trimmed
            return language.localized("Delete “\(name)”?", "删除“\(name)”？")
        }
        return language.localized(
            "Delete \(sessionsPendingDeletion.count) servers?",
            "删除 \(sessionsPendingDeletion.count) 台服务器？"
        )
    }
}

/// One server in the sidebar. Incomplete drafts show a warning symbol; the
/// address is available as the row's help text.
struct ServerSidebarRow: View {
    @Environment(\.appLanguage) private var language
    let session: RemoteSession

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            if session.isConnectable {
                Image(systemName: ServerSymbol.name(for: session.connectionType))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        }
        .help(session.isConnectable
            ? session.localizedAddress(language: language)
            : language.localized("Needs setup", "待配置"))
        .accessibilityIdentifier("server-row")
    }

    private var title: String {
        let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? language.localized("Unnamed Server", "未命名服务器") : trimmed
    }
}

/// SF Symbols for each connection type, shared by the sidebar and toolbar.
enum ServerSymbol {
    static func name(for connectionType: RemoteConnectionType) -> String {
        switch connectionType {
        case .ssh:
            return "server.rack"
        case .localShell:
            return "apple.terminal"
        case .macDesktop:
            return "desktopcomputer"
        case .rdp:
            return "pc"
        }
    }
}
