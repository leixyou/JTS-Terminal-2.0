//
//  RemoteTransferQueue.swift
//  JTSTerminal
//
//  Created by Codex on 2026/5/2.
//

import Combine
import Foundation
import SwiftData

struct RemoteTransferLaunchSnapshot: Equatable {
    let direction: RemoteTransferDirection
    let remotePath: String
    let localPath: String
    let recursive: Bool

    init(task: RemoteTransferTask) {
        direction = task.direction
        remotePath = task.remotePath
        localPath = task.localPath
        recursive = task.recursive
    }
}

@MainActor
final class RemoteTransferQueueManager: ObservableObject {
    private struct Request {
        let task: RemoteTransferTask
        let session: RemoteSession
        let transfer: RemoteTransferLaunchSnapshot
        let context: ModelContext
        let shouldResumeTransfer: Bool
    }

    @Published private(set) var activeTaskID: PersistentIdentifier?
    private var queuedRequests: [Request] = []
    private let transport = RemoteSFTPTransport()

    var isRunning: Bool {
        activeTaskID != nil
    }

    func enqueue(
        _ task: RemoteTransferTask,
        session: RemoteSession,
        context: ModelContext
    ) {
        guard task.status.canResume || task.status == .running else { return }
        guard !isAlreadyManaged(task) else { return }

        let shouldResumeTransfer = task.shouldResumeTransferOnNextAttempt
        let frozenSession = SSHSessionLaunchSnapshot(session: session).materializedSession()
        let transfer = RemoteTransferLaunchSnapshot(task: task)
        task.markQueued()
        try? context.save()
        queuedRequests.append(Request(
            task: task,
            session: frozenSession,
            transfer: transfer,
            context: context,
            shouldResumeTransfer: shouldResumeTransfer
        ))
        startNextIfNeeded()
    }

    func isActive(_ task: RemoteTransferTask) -> Bool {
        activeTaskID == task.persistentModelID
    }

    private func isAlreadyManaged(_ task: RemoteTransferTask) -> Bool {
        activeTaskID == task.persistentModelID ||
        queuedRequests.contains { $0.task.persistentModelID == task.persistentModelID }
    }

    private func startNextIfNeeded() {
        guard activeTaskID == nil, !queuedRequests.isEmpty else { return }
        let request = queuedRequests.removeFirst()
        activeTaskID = request.task.persistentModelID
        request.task.markRunning()
        try? request.context.save()

        Task { @MainActor in
            await run(request)
        }
    }

    private func run(_ request: Request) async {
        let stopSecurityScopedAccess = request.task.startAccessingLocalSecurityScopedResource()
        let progressPoller = startProgressPolling(for: request)
        defer {
            progressPoller?.cancel()
            stopSecurityScopedAccess()
        }

        do {
            let result: CommandResult
            switch request.transfer.direction {
            case .download:
                result = try await transport.download(
                    session: request.session,
                    remotePath: request.transfer.remotePath,
                    localPath: request.transfer.localPath,
                    recursive: request.transfer.recursive,
                    resume: request.shouldResumeTransfer
                )
            case .upload:
                result = try await transport.upload(
                    session: request.session,
                    localPath: request.transfer.localPath,
                    remotePath: request.transfer.remotePath,
                    recursive: request.transfer.recursive,
                    resume: request.shouldResumeTransfer
                )
            }
            request.task.refreshTransferredByteCountFromLocalFile()
            request.task.markFinished(result: result)
        } catch {
            request.task.refreshTransferredByteCountFromLocalFile()
            request.task.markFailed(error.localizedDescription)
        }

        try? request.context.save()
        if activeTaskID == request.task.persistentModelID {
            activeTaskID = nil
        }
        startNextIfNeeded()
    }

    private func startProgressPolling(for request: Request) -> Task<Void, Never>? {
        guard request.task.direction == .download,
              request.task.expectedByteCount != nil else {
            return nil
        }

        return Task { @MainActor in
            while !Task.isCancelled {
                request.task.refreshTransferredByteCountFromLocalFile()
                try? request.context.save()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }
}
