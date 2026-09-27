//
//  MobileRemoteFilesController.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import Foundation
import Combine

@MainActor
final class MobileRemoteFilesController: ObservableObject {
    @Published var currentPath: String
    @Published private(set) var entries: [MobileRemoteFileEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var credentialPromptReason: MobileCredentialPromptReason?
    @Published var selectedEntry: MobileRemoteFileEntry?
    @Published var downloadedFile: MobileDownloadedFileDocument?
    @Published var downloadedFileName = "download"

    private let profile: MobileServerProfile
    private let transport: MobileCitadelFileTransport
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?

    init(
        profile: MobileServerProfile,
        transport: MobileCitadelFileTransport = MobileCitadelFileTransport()
    ) {
        self.profile = profile
        self.transport = transport
        self.currentPath = profile.remotePath.mobileNilIfBlank ?? "~"
    }

    func refresh() {
        run {
            let credentials = MobileCredentialStore.credentials(for: self.profile)
            self.entries = try await self.transport.listDirectory(
                profile: self.profile,
                credentials: credentials,
                path: self.currentPath
            )
            self.selectedEntry = nil
        }
    }

    func clearCredentialPrompt() {
        credentialPromptReason = nil
    }

    func disconnect() {
        operationTask?.cancel()
        operationTask = nil
        operationID = nil
        isLoading = false
        credentialPromptReason = nil
        Task {
            await transport.disconnect()
        }
    }

    func open(_ entry: MobileRemoteFileEntry) {
        guard entry.isDirectory else {
            selectedEntry = entry
            return
        }
        currentPath = entry.path
        refresh()
    }

    func parent() {
        currentPath = MobileRemotePath.parent(of: currentPath)
        refresh()
    }

    func upload(data: Data, fileName: String) {
        let remotePath = MobileRemotePath.child(fileName, in: currentPath)
        run {
            let credentials = MobileCredentialStore.credentials(for: self.profile)
            try await self.transport.upload(
                profile: self.profile,
                credentials: credentials,
                data: data,
                remotePath: remotePath
            )
            self.entries = try await self.transport.listDirectory(
                profile: self.profile,
                credentials: credentials,
                path: self.currentPath
            )
        }
    }

    func prepareDownload(_ entry: MobileRemoteFileEntry) {
        guard !entry.isDirectory else { return }
        run {
            let credentials = MobileCredentialStore.credentials(for: self.profile)
            let data = try await self.transport.download(
                profile: self.profile,
                credentials: credentials,
                remotePath: entry.path
            )
            self.downloadedFileName = entry.name
            self.downloadedFile = MobileDownloadedFileDocument(data: data)
        }
    }

    func makeDirectory(named name: String) {
        guard let name = name.mobileNilIfBlank else { return }
        run {
            let credentials = MobileCredentialStore.credentials(for: self.profile)
            try await self.transport.makeDirectory(
                profile: self.profile,
                credentials: credentials,
                path: MobileRemotePath.child(name, in: self.currentPath)
            )
            self.entries = try await self.transport.listDirectory(
                profile: self.profile,
                credentials: credentials,
                path: self.currentPath
            )
        }
    }

    func delete(_ entry: MobileRemoteFileEntry) {
        run {
            let credentials = MobileCredentialStore.credentials(for: self.profile)
            try await self.transport.delete(
                profile: self.profile,
                credentials: credentials,
                entry: entry
            )
            self.entries = try await self.transport.listDirectory(
                profile: self.profile,
                credentials: credentials,
                path: self.currentPath
            )
        }
    }

    func rename(_ entry: MobileRemoteFileEntry, to newName: String) {
        guard let newName = newName.mobileNilIfBlank else { return }
        run {
            let credentials = MobileCredentialStore.credentials(for: self.profile)
            try await self.transport.rename(
                profile: self.profile,
                credentials: credentials,
                entry: entry,
                newName: newName
            )
            self.entries = try await self.transport.listDirectory(
                profile: self.profile,
                credentials: credentials,
                path: self.currentPath
            )
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        credentialPromptReason = nil
        let currentOperationID = UUID()
        operationID = currentOperationID

        operationTask = Task {
            defer {
                if operationID == currentOperationID {
                    isLoading = false
                    operationTask = nil
                    operationID = nil
                }
            }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = MobileCitadelClientFactory.userFacingMessage(for: error)
                credentialPromptReason = MobileCitadelClientFactory.credentialPromptReason(for: error)
            }
        }
    }
}
