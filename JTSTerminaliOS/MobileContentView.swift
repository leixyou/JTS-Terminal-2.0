//
//  MobileContentView.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct MobileRootView: View {
    @EnvironmentObject private var store: MobileSessionStore
    @State private var editingProfile: MobileServerProfile?
    @State private var isImportingProfiles = false
    @State private var isExportingProfiles = false
    @State private var exportDocument = MobileProfileDocument()
    @State private var importError: String?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if store.profiles.isEmpty {
                    MobileEmptyServerState(
                        addServer: { editingProfile = MobileServerProfile() },
                        importProfiles: { isImportingProfiles = true }
                    )
                } else {
                    serverList
                }
            }
            .navigationTitle("JTS Terminal")
            .navigationDestination(for: MobileServerProfile.ID.self) { profileID in
                if let profile = store.profiles.first(where: { $0.id == profileID }) {
                    MobileServerWorkspace(
                        profile: profile,
                        session: store.session(for: profile)
                    )
                        .id(profile.id)
                        .onAppear {
                            store.selectedProfileID = profile.id
                        }
                } else {
                    ContentUnavailableView(
                        "Server Not Found",
                        systemImage: "server.rack",
                        description: Text("This SSH profile is no longer available.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    profilesMenu
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingProfile = MobileServerProfile()
                    } label: {
                        Label("New Server", systemImage: "plus")
                    }
                    .accessibilityIdentifier("mobile.newServerButton")
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            MobileServerEditor(profile: profile) { updatedProfile in
                store.upsert(updatedProfile)
                navigationPath = NavigationPath()
                navigationPath.append(updatedProfile.id)
            }
        }
        .fileImporter(
            isPresented: $isImportingProfiles,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleProfileImport(result)
        }
        .fileExporter(
            isPresented: $isExportingProfiles,
            document: exportDocument,
            contentType: .json,
            defaultFilename: MobileServerProfileCodec.defaultFileName
        ) { _ in }
        .alert(
            "Profile Import",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var serverList: some View {
        ScrollView {
            serverListContent
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
        }
        .background(MobileGlassBackground())
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var serverListContent: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 18) {
                serverListStack
            }
        } else {
            serverListStack
        }
    }

    private var serverListStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            MobileServerOverview(profileCount: store.profiles.count)

            VStack(alignment: .leading, spacing: 10) {
                Text("Servers")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)

                ForEach(store.profiles) { profile in
                    NavigationLink(value: profile.id) {
                        ServerRow(profile: profile)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .mobileGlassSurface(
                                cornerRadius: 28,
                                tint: Color.accentColor.opacity(0.08)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mobile.serverRow.\(profile.address)")
                    .contextMenu {
                        Button {
                            editingProfile = profile
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        if store.hasSession(for: profile) {
                            Button(role: .destructive) {
                                store.endSession(for: profile)
                            } label: {
                                Label("Close Session", systemImage: "xmark.circle")
                            }
                        }

                        Button(role: .destructive) {
                            store.delete(profile)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var profilesMenu: some View {
        Menu {
            Button {
                isImportingProfiles = true
            } label: {
                Label("Import Profiles", systemImage: "square.and.arrow.down")
            }

            Button {
                exportProfiles()
            } label: {
                Label("Export Profiles", systemImage: "square.and.arrow.up")
            }
            .disabled(store.profiles.isEmpty)
        } label: {
            Label("Profiles", systemImage: "folder.badge.gearshape")
        }
        .accessibilityIdentifier("mobile.profilesMenu")
    }

    private func exportProfiles() {
        do {
            exportDocument = MobileProfileDocument(data: try store.exportData())
            isExportingProfiles = true
        } catch {
            importError = error.localizedDescription
        }
    }

    private func handleProfileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let stopAccess = url.startAccessingSecurityScopedResource()
            defer {
                if stopAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            let profiles = try MobileServerProfileCodec.decode(data)
            store.importProfiles(profiles)
            importError = profiles.isEmpty ? "No SSH profiles were found in this file." : nil
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct MobileEmptyServerState: View {
    let addServer: () -> Void
    let importProfiles: () -> Void

    var body: some View {
        ZStack {
            MobileGlassBackground()

            VStack(spacing: 18) {
                Image(systemName: "server.rack")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 74, height: 74)
                    .mobileGlassSurface(
                        cornerRadius: 22,
                        tint: Color.accentColor.opacity(0.16),
                        interactive: false
                    )

                VStack(spacing: 8) {
                    Text("No Servers")
                        .font(.title2.weight(.bold))
                    Text("Add an SSH profile to open Terminal and Files from this iPhone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button(action: addServer) {
                        Label("New Server", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .mobileGlassButtonStyle(prominent: true)
                    .controlSize(.large)
                    .accessibilityIdentifier("mobile.emptyNewServerButton")

                    Button(action: importProfiles) {
                        Label("Import Profiles", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .mobileGlassButtonStyle()
                    .controlSize(.large)
                    .accessibilityIdentifier("mobile.importProfilesButton")
                }
            }
            .padding(24)
            .mobileGlassSurface(cornerRadius: 32, tint: Color.white.opacity(0.08))
            .padding(.horizontal, 24)
        }
        .navigationTitle("JTS Terminal")
    }
}

private struct MobileServerOverview: View {
    let profileCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .mobileGlassSurface(cornerRadius: 15, tint: Color.accentColor.opacity(0.26))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Workspace")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("Terminal and SFTP profiles")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer()

                Text("\(profileCount)")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel("\(profileCount) saved servers")
            }

            HStack(spacing: 8) {
                MobileCapabilityBadge(title: "SSH", systemImage: "terminal")
                MobileCapabilityBadge(title: "SFTP", systemImage: "folder")
                MobileCapabilityBadge(title: "Vault", systemImage: "key.fill")
            }
        }
        .padding(18)
        .mobileGlassSurface(cornerRadius: 30, tint: Color.blue.opacity(0.08))
    }
}

private struct MobileCapabilityBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .mobileGlassSurface(cornerRadius: 18, tint: Color.white.opacity(0.08))
    }
}

private struct ServerRow: View {
    let profile: MobileServerProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.isConnectable ? "server.rack" : "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(profile.isConnectable ? Color.accentColor : .orange)
                .frame(width: 42, height: 42)
                .mobileGlassSurface(
                    cornerRadius: 13,
                    tint: profile.isConnectable ? Color.accentColor.opacity(0.14) : Color.orange.opacity(0.16)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(profile.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Text(profile.address)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(profile.remotePath, systemImage: "folder")
                        .lineLimit(1)
                    Label(credentialLabel, systemImage: credentialSystemImage)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var credentialLabel: String {
        let credentials = MobileCredentialStore.credentials(for: profile)
        switch (credentials.hasPassword, credentials.hasPrivateKey) {
        case (true, true):
            return "Password + key"
        case (true, false):
            return "Password saved"
        case (false, true):
            return "Key saved"
        case (false, false):
            return profile.identityFile.isEmpty ? "No credential" : "Key path"
        }
    }

    private var credentialSystemImage: String {
        let credentials = MobileCredentialStore.credentials(for: profile)
        return credentials.hasPassword || credentials.hasPrivateKey ? "checkmark.seal" : "key"
    }
}

private struct MobileServerWorkspace: View {
    let profile: MobileServerProfile
    @ObservedObject private var session: MobileServerSession
    @ObservedObject private var terminalController: MobileTerminalController
    @ObservedObject private var filesController: MobileRemoteFilesController
    @State private var credentialRequest: MobileWorkspaceCredentialRequest?

    init(profile: MobileServerProfile, session: MobileServerSession) {
        self.profile = profile
        _session = ObservedObject(wrappedValue: session)
        _terminalController = ObservedObject(wrappedValue: session.terminalController)
        _filesController = ObservedObject(wrappedValue: session.filesController)
    }

    var body: some View {
        ZStack {
            MobileGlassBackground()

            VStack(spacing: 12) {
                MobileWorkspaceHeader(
                    profile: profile,
                    controller: terminalController,
                    isExpanded: $session.isHeaderExpanded,
                    connect: { terminalController.connect(profile: profile) },
                    disconnect: session.disconnect
                )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                Picker("Workspace", selection: $session.selectedPanel) {
                    ForEach(MobileWorkspacePanel.allCases) { panel in
                        Label(panel.title, systemImage: panel.systemImage)
                            .tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .padding(6)
                .mobileGlassSurface(cornerRadius: 18, tint: Color.white.opacity(0.08), interactive: true)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("mobile.workspacePicker")

                Group {
                    switch session.selectedPanel {
                    case .terminal:
                        MobileTerminalPanel(controller: terminalController)
                    case .files:
                        MobileFilesPanel(controller: filesController)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onChange(of: terminalController.credentialPromptReason) { _, reason in
            presentCredentialPrompt(reason, target: .terminal)
        }
        .onChange(of: filesController.credentialPromptReason) { _, reason in
            presentCredentialPrompt(reason, target: .files)
        }
        .sheet(item: $credentialRequest, onDismiss: clearCredentialPrompts) { request in
            MobilePasswordPrompt(profile: profile, reason: request.reason) { password in
                try MobileCredentialStore.save(password, for: profile, kind: .password)
                credentialRequest = nil

                switch request.target {
                case .terminal:
                    terminalController.clearCredentialPrompt()
                    terminalController.connect(profile: profile)
                case .files:
                    filesController.clearCredentialPrompt()
                    filesController.refresh()
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func presentCredentialPrompt(
        _ reason: MobileCredentialPromptReason?,
        target: MobileWorkspaceCredentialTarget
    ) {
        guard let reason, credentialRequest == nil else { return }
        credentialRequest = MobileWorkspaceCredentialRequest(reason: reason, target: target)
    }

    private func clearCredentialPrompts() {
        terminalController.clearCredentialPrompt()
        filesController.clearCredentialPrompt()
    }
}

private enum MobileWorkspaceCredentialTarget {
    case terminal
    case files
}

private struct MobileWorkspaceCredentialRequest: Identifiable {
    let id = UUID()
    let reason: MobileCredentialPromptReason
    let target: MobileWorkspaceCredentialTarget
}

private struct MobileWorkspaceHeader: View {
    let profile: MobileServerProfile
    @ObservedObject var controller: MobileTerminalController
    @Binding var isExpanded: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "server.rack")
                    .font(isExpanded ? .title3 : .body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: iconSize, height: iconSize)
                    .mobileGlassSurface(cornerRadius: isExpanded ? 13 : 11, tint: Color.accentColor.opacity(0.14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.address)
                        .font(.subheadline.monospaced())
                        .lineLimit(1)
                    if isExpanded {
                        Text(profile.remotePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("mobile.workspaceRemotePath")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Text(controller.state.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, isExpanded ? 10 : 8)
                    .padding(.vertical, isExpanded ? 6 : 5)
                    .mobileGlassSurface(cornerRadius: 16, tint: statusTint.opacity(0.14))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("mobile.terminalStatus")

                if !isExpanded {
                    compactConnectionButton
                }

                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
                .fixedSize()
                .accessibilityLabel(isExpanded ? "Collapse connection details" : "Expand connection details")
                .accessibilityIdentifier("mobile.workspaceHeaderDisclosure")
            }

            if isExpanded {
                Button(action: toggleConnection) {
                    Label(buttonTitle, systemImage: buttonSystemImage)
                        .frame(maxWidth: .infinity)
                }
                .mobileGlassButtonStyle(prominent: true)
                .controlSize(.large)
                .tint(buttonTint)
                .accessibilityIdentifier("mobile.terminalConnectButton")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(isExpanded ? 16 : 10)
        .mobileGlassSurface(cornerRadius: isExpanded ? 28 : 20, tint: Color.accentColor.opacity(0.08))
        .animation(.snappy(duration: 0.24), value: isExpanded)
    }

    private var compactConnectionButton: some View {
        Button(action: toggleConnection) {
            Image(systemName: buttonSystemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .mobileGlassButtonStyle()
        .tint(buttonTint)
        .accessibilityLabel(buttonTitle)
        .accessibilityIdentifier("mobile.terminalConnectButton")
    }

    private var iconSize: CGFloat {
        isExpanded ? 38 : 34
    }

    private func toggleConnection() {
        switch controller.state {
        case .connected, .connecting:
            disconnect()
        case .disconnected, .failed:
            connect()
        }
    }

    private var buttonTitle: String {
        switch controller.state {
        case .connected, .connecting:
            return "Disconnect"
        case .disconnected, .failed:
            return "Connect"
        }
    }

    private var buttonSystemImage: String {
        switch controller.state {
        case .connected, .connecting:
            return "stop.fill"
        case .disconnected, .failed:
            return "play.fill"
        }
    }

    private var buttonTint: Color {
        switch controller.state {
        case .connected, .connecting:
            return .red
        case .disconnected, .failed:
            return .accentColor
        }
    }

    private var statusTint: Color {
        switch controller.state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .secondary
        case .failed:
            return .red
        }
    }
}

private struct MobileTerminalPanel: View {
    @ObservedObject var controller: MobileTerminalController

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = controller.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
                    .accessibilityIdentifier("mobile.terminalError")
            }

            MobileTerminalView(controller: controller)
                .background(Color.black)
        }
        .background(Color.black)
    }
}

private struct MobileFilesPanel: View {
    @ObservedObject var controller: MobileRemoteFilesController
    @State private var isImportingUpload = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var entryToRename: MobileRemoteFileEntry?
    @State private var renameValue = ""
    @State private var entryToDelete: MobileRemoteFileEntry?
    @State private var isExportingDownload = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        controller.parent()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .mobileGlassButtonStyle()
                    .controlSize(.regular)
                    .accessibilityLabel("Parent")
                    .disabled(controller.isLoading)

                    TextField("Remote path", text: $controller.currentPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("mobile.filesRemotePathField")
                        .onSubmit {
                            controller.refresh()
                        }

                    Button {
                        controller.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .mobileGlassButtonStyle()
                    .controlSize(.regular)
                    .accessibilityLabel("Refresh")
                    .disabled(controller.isLoading)
                    .accessibilityIdentifier("mobile.filesRefreshButton")
                }

                HStack(spacing: 8) {
                    Button {
                        isImportingUpload = true
                    } label: {
                        Label("Upload", systemImage: "square.and.arrow.up")
                    }
                    .mobileGlassButtonStyle()
                    .disabled(controller.isLoading)

                    Button {
                        newFolderName = ""
                        isCreatingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .mobileGlassButtonStyle()
                    .disabled(controller.isLoading)

                    Spacer()

                    if controller.isLoading {
                        ProgressView()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .mobileGlassSurface(cornerRadius: 24, tint: Color.white.opacity(0.08))
            .padding(.horizontal, 12)

            if let errorMessage = controller.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .mobileGlassSurface(cornerRadius: 18, tint: Color.red.opacity(0.14))
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("mobile.filesError")
            }

            List(controller.entries) { entry in
                Button {
                    controller.open(entry)
                } label: {
                    MobileFileRow(entry: entry)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !entry.isDirectory {
                        Button {
                            controller.prepareDownload(entry)
                        } label: {
                            Label("Download", systemImage: "square.and.arrow.down")
                        }
                    }

                    Button {
                        renameValue = entry.name
                        entryToRename = entry
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        entryToDelete = entry
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .overlay {
                if controller.entries.isEmpty && !controller.isLoading {
                    ContentUnavailableView(
                        "No Files Loaded",
                        systemImage: "folder",
                        description: Text("Tap Refresh after saving credentials for this server.")
                    )
                }
            }
        }
        .task {
            if controller.entries.isEmpty {
                controller.refresh()
            }
        }
        .fileImporter(
            isPresented: $isImportingUpload,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handleUploadImport(result)
        }
        .fileExporter(
            isPresented: $isExportingDownload,
            document: controller.downloadedFile ?? MobileDownloadedFileDocument(),
            contentType: .data,
            defaultFilename: controller.downloadedFileName
        ) { _ in
            controller.downloadedFile = nil
        }
        .onChange(of: controller.downloadedFile) { _, newValue in
            isExportingDownload = newValue != nil
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                controller.makeDirectory(named: newFolderName)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(
            get: { entryToRename != nil },
            set: { if !$0 { entryToRename = nil } }
        )) {
            TextField("Name", text: $renameValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                if let entryToRename {
                    controller.rename(entryToRename, to: renameValue)
                }
                entryToRename = nil
            }
            Button("Cancel", role: .cancel) {
                entryToRename = nil
            }
        }
        .confirmationDialog(
            "Delete remote item?",
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { if !$0 { entryToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entryToDelete {
                    controller.delete(entryToDelete)
                }
                entryToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        }
    }

    private func handleUploadImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let stopAccess = url.startAccessingSecurityScopedResource()
            defer {
                if stopAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            controller.upload(data: data, fileName: url.lastPathComponent)
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }
}

private struct MobileFileRow: View {
    let entry: MobileRemoteFileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text(entry.formattedSize)
                    Text(entry.permissionsText)
                    if let modifiedAt = entry.modifiedAt {
                        Text(modifiedAt, style: .date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MobileGlassBackground: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color.cyan.opacity(0.08),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )

            LinearGradient(
                colors: [
                    Color.green.opacity(0.08),
                    Color.clear
                ],
                startPoint: .bottomTrailing,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

private extension View {
    @ViewBuilder
    func mobileGlassSurface(
        cornerRadius: CGFloat,
        tint: Color = Color.white.opacity(0.06),
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26, *) {
            if interactive {
                self.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
                }
        }
    }

    @ViewBuilder
    func mobileGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
