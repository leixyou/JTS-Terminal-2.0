//
//  TerminalBroadcastCoordinator.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/28.
//

import Combine
import Foundation

@MainActor
final class TerminalBroadcastCoordinator: ObservableObject {
    enum Phase: Equatable {
        case selection
        case review
        case running
        case results
    }

    private struct ReviewSnapshot {
        let command: String
        let targets: [TerminalBroadcastTarget]

        var targetIDs: Set<UUID> {
            Set(targets.map(\.id))
        }
    }

    private final class ReservationLease {
        let batchID: UUID
        let targets: [TerminalBroadcastTarget]
        private(set) var isReleased = false

        init(batchID: UUID, targets: [TerminalBroadcastTarget]) {
            self.batchID = batchID
            self.targets = targets
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            for target in targets {
                target.processSession?.releaseBroadcastReservation(batchID: batchID)
            }
        }
    }

    @Published private(set) var isPresented = false
    @Published private(set) var phase: Phase = .selection
    @Published private(set) var targets: [TerminalBroadcastTarget] = []
    @Published var selectedTargetIDs: Set<UUID> = []
    @Published var command = ""
    @Published var masksCommandInReview = true
    @Published var didConfirmPromptState = false
    @Published private(set) var results: [TerminalBroadcastPaneResult] = []
    @Published private(set) var errorMessage = ""

    private var reviewSnapshot: ReviewSnapshot?
    private var executionTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var completedRunID: UUID?
    private var activeReservationLease: ReservationLease?
    private var targetSessionCancellables: [ObjectIdentifier: AnyCancellable] = [:]

    var selectedTargets: [TerminalBroadcastTarget] {
        targets.filter { selectedTargetIDs.contains($0.id) }
    }

    var eligibleTargets: [TerminalBroadcastTarget] {
        targets.filter { $0.availability.isEligible }
    }

    var canReview: Bool {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selectedTargets
        return !trimmedCommand.isEmpty &&
            selected.count >= TerminalBroadcastPolicy.minimumTargetCount &&
            selected.count <= TerminalBroadcastPolicy.maximumTargetCount &&
            selected.allSatisfy { $0.availability.isEligible }
    }

    var canRun: Bool {
        guard phase == .review,
              didConfirmPromptState,
              let reviewSnapshot else {
            return false
        }
        return command == reviewSnapshot.command &&
            selectedTargetIDs == reviewSnapshot.targetIDs &&
            reviewSnapshot.targets.allSatisfy { $0.availability.isEligible }
    }

    func open(targets: [TerminalBroadcastTarget]) {
        guard phase != .running, activeRunID == nil else { return }
        clearSensitiveState()
        self.targets = targets
        observeTargetSessions(in: targets)
        phase = .selection
        isPresented = true
    }

    func selectAllEligible() {
        guard phase == .selection else { return }
        selectedTargetIDs = Set(
            eligibleTargets
                .prefix(TerminalBroadcastPolicy.maximumTargetCount)
                .map(\.id)
        )
        invalidateReview()
        errorMessage = ""
    }

    func clearSelection() {
        guard phase == .selection else { return }
        selectedTargetIDs.removeAll()
        invalidateReview()
        errorMessage = ""
    }

    func setSelected(_ isSelected: Bool, targetID: UUID) {
        guard phase == .selection else { return }
        if isSelected {
            guard selectedTargetIDs.count < TerminalBroadcastPolicy.maximumTargetCount,
                  targets.first(where: { $0.id == targetID })?.availability.isEligible == true else {
                return
            }
            selectedTargetIDs.insert(targetID)
        } else {
            selectedTargetIDs.remove(targetID)
        }
        invalidateReview()
        errorMessage = ""
    }

    func review() {
        guard phase == .selection else { return }
        errorMessage = ""
        do {
            _ = try TerminalMCPCommandRequest(
                command: command,
                timeoutSeconds: TerminalBroadcastPolicy.timeoutSeconds,
                maxOutputBytes: TerminalBroadcastPolicy.maximumOutputBytesPerPane
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let selected = selectedTargets
        guard selected.count >= TerminalBroadcastPolicy.minimumTargetCount else {
            errorMessage = "Select at least \(TerminalBroadcastPolicy.minimumTargetCount) ready terminal panes."
            return
        }
        guard selected.count <= TerminalBroadcastPolicy.maximumTargetCount else {
            errorMessage = "A Multi-Exec batch can include at most \(TerminalBroadcastPolicy.maximumTargetCount) panes."
            return
        }
        guard selected.allSatisfy({ $0.availability.isEligible }) else {
            errorMessage = "One or more selected panes changed. Reopen Multi-Exec and review the current targets."
            return
        }

        reviewSnapshot = ReviewSnapshot(command: command, targets: selected)
        didConfirmPromptState = false
        phase = .review
    }

    func returnToSelection() {
        guard phase == .review else { return }
        invalidateReview()
        errorMessage = ""
        phase = .selection
    }

    @discardableResult
    func runConfirmedBatch() -> UUID? {
        guard phase == .review,
              let snapshot = reviewSnapshot,
              didConfirmPromptState else {
            return nil
        }
        errorMessage = ""

        guard command == snapshot.command,
              selectedTargetIDs == snapshot.targetIDs else {
            errorMessage = "The command or target selection changed after review. Nothing was sent."
            didConfirmPromptState = false
            return nil
        }
        guard snapshot.targets.allSatisfy({ $0.availability.isEligible }) else {
            errorMessage = "A selected pane changed after review. Nothing was sent."
            didConfirmPromptState = false
            return nil
        }

        let batchID = UUID()
        var reserved: [TerminalBroadcastTarget] = []
        for target in snapshot.targets {
            guard let processSession = target.processSession,
                  let generation = target.reviewedGeneration,
                  processSession.reserveBroadcast(
                    batchID: batchID,
                    expectedGeneration: generation
                  ) else {
                for priorTarget in reserved {
                    priorTarget.processSession?.releaseBroadcastReservation(batchID: batchID)
                }
                errorMessage = "A selected pane became busy or reconnected. Nothing was sent."
                didConfirmPromptState = false
                return nil
            }
            reserved.append(target)
        }

        let lease = ReservationLease(batchID: batchID, targets: reserved)
        let runID = UUID()
        activeRunID = runID
        completedRunID = nil
        activeReservationLease = lease
        phase = .running
        // Reservation succeeded for the complete frozen target set. Publish
        // the transition as one batch so observers never see a partly queued,
        // partly running state merely because MainActor child tasks were
        // scheduled at different times.
        results = reserved.map { Self.runningResult(for: $0) }

        // Create every pane task before creating the collector. This removes
        // an avoidable outer-Task scheduling hop and guarantees that the
        // entire reserved batch is enqueued before any result is awaited.
        let targetTasks = reserved.map { target in
            Task { @MainActor [weak self] in
                let result = await Self.execute(
                    target: target,
                    command: snapshot.command,
                    batchID: lease.batchID
                )
                if let self, activeRunID == runID {
                    updateResult(result)
                }
                return result
            }
        }

        executionTask = Task { [weak self, lease, targetTasks] in
            let batchResults = await Self.collectReservedTargetTasks(
                targetTasks,
                lease.targets
            )
            lease.release()

            guard let self, activeRunID == runID else { return }
            results = batchResults
            activeReservationLease = nil
            activeRunID = nil
            executionTask = nil
            phase = .results
            completedRunID = runID
        }
        return runID
    }

    /// Waits for exactly the requested run. A stale handle can neither observe
    /// nor complete a later batch, and the bounded poll remains cancellable.
    func waitForBatchCompletion(
        runID: UUID,
        timeout: Duration
    ) async -> Bool {
        if completedRunID == runID {
            return true
        }
        guard activeRunID == runID,
              executionTask != nil else {
            return false
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while activeRunID == runID,
              completedRunID != runID,
              clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return completedRunID == runID
    }

    func close() {
        guard phase != .running else { return }
        isPresented = false
        clearSensitiveState()
    }

    private func invalidateReview() {
        reviewSnapshot = nil
        didConfirmPromptState = false
    }

    private func updateResult(_ result: TerminalBroadcastPaneResult) {
        guard let index = results.firstIndex(where: { $0.id == result.id }) else {
            return
        }
        results[index] = result
    }

    private func observeTargetSessions(in targets: [TerminalBroadcastTarget]) {
        for processSession in targets.compactMap(\.processSession) {
            let identifier = ObjectIdentifier(processSession)
            guard targetSessionCancellables[identifier] == nil else {
                continue
            }
            targetSessionCancellables[identifier] = processSession.objectWillChange.sink {
                [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    private func clearSensitiveState() {
        for cancellable in targetSessionCancellables.values {
            cancellable.cancel()
        }
        targetSessionCancellables.removeAll(keepingCapacity: false)
        activeRunID = nil
        completedRunID = nil
        executionTask?.cancel()
        executionTask = nil
        activeReservationLease?.release()
        activeReservationLease = nil
        invalidateReview()
        command.removeAll(keepingCapacity: false)
        selectedTargetIDs.removeAll()
        targets.removeAll()
        results.removeAll()
        masksCommandInReview = true
        errorMessage = ""
        phase = .selection
    }

    private static func collectReservedTargetTasks(
        _ tasks: [Task<TerminalBroadcastPaneResult, Never>],
        _ reservedTargets: [TerminalBroadcastTarget]
    ) async -> [TerminalBroadcastPaneResult] {
        let completed = await withTaskCancellationHandler {
            var results: [TerminalBroadcastPaneResult] = []
            results.reserveCapacity(tasks.count)
            for task in tasks {
                results.append(await task.value)
            }
            return results
        } onCancel: {
            for task in tasks {
                task.cancel()
            }
        }
        let resultByID = Dictionary(
            uniqueKeysWithValues: completed.map { ($0.id, $0) }
        )

        return reservedTargets.map { target in
            resultByID[target.id] ?? failedResult(
                for: target,
                status: .cancelled,
                started: Date(),
                message: "Multi-Exec was cancelled before this pane started.",
                didWriteCommandBytes: false
            )
        }
    }

    private static func execute(
        target: TerminalBroadcastTarget,
        command: String,
        batchID: UUID
    ) async -> TerminalBroadcastPaneResult {
        let started = Date()
        guard let processSession = target.processSession,
              let generation = target.reviewedGeneration else {
            return failedResult(
                for: target,
                status: .notSent,
                started: started,
                message: "The terminal process was unavailable before any command bytes were sent.",
                didWriteCommandBytes: false
            )
        }

        do {
            let result = try await processSession.runBroadcastCommand(
                command: command,
                batchID: batchID,
                expectedGeneration: generation,
                timeoutSeconds: TerminalBroadcastPolicy.timeoutSeconds,
                maxOutputBytes: TerminalBroadcastPolicy.maximumOutputBytesPerPane
            )
            return TerminalBroadcastPaneResult(
                id: target.id,
                profileName: target.profileName,
                paneTitle: target.paneTitle,
                status: result.timedOut
                    ? .timedOut
                    : (result.exitCode == 0 ? .succeeded : .nonZeroExit),
                exitCode: result.exitCode,
                stdout: result.stdout,
                truncated: result.truncated,
                durationMs: result.durationMs,
                errorMessage: nil,
                didWriteCommandBytes: result.didWriteCommandBytes
            )
        } catch let error as TerminalMCPCommandError {
            switch error {
            case .notRunning:
                return failedResult(
                    for: target,
                    status: .disconnected,
                    started: started,
                    message: error.localizedDescription,
                    didWriteCommandBytes: false
                )
            case .executionInterrupted(let reason, let didWriteCommandBytes):
                return failedResult(
                    for: target,
                    status: didWriteCommandBytes ? .partialSend : .disconnected,
                    started: started,
                    message: reason,
                    didWriteCommandBytes: didWriteCommandBytes
                )
            case .rejected(let reason):
                return failedResult(
                    for: target,
                    status: .notSent,
                    started: started,
                    message: reason,
                    didWriteCommandBytes: false
                )
            case .couldNotParseResult:
                return failedResult(
                    for: target,
                    status: .failed,
                    started: started,
                    message: error.localizedDescription,
                    didWriteCommandBytes: true
                )
            }
        } catch is CancellationError {
            return failedResult(
                for: target,
                status: .cancelled,
                started: started,
                message: "Multi-Exec was cancelled.",
                didWriteCommandBytes: false
            )
        } catch {
            return failedResult(
                for: target,
                status: .failed,
                started: started,
                message: error.localizedDescription,
                didWriteCommandBytes: false
            )
        }
    }

    private static func queuedResult(
        for target: TerminalBroadcastTarget
    ) -> TerminalBroadcastPaneResult {
        stateResult(for: target, status: .queued)
    }

    private static func runningResult(
        for target: TerminalBroadcastTarget
    ) -> TerminalBroadcastPaneResult {
        stateResult(for: target, status: .running)
    }

    private static func stateResult(
        for target: TerminalBroadcastTarget,
        status: TerminalBroadcastPaneResult.Status
    ) -> TerminalBroadcastPaneResult {
        TerminalBroadcastPaneResult(
            id: target.id,
            profileName: target.profileName,
            paneTitle: target.paneTitle,
            status: status,
            exitCode: nil,
            stdout: "",
            truncated: false,
            durationMs: 0,
            errorMessage: nil,
            didWriteCommandBytes: false
        )
    }

    private static func failedResult(
        for target: TerminalBroadcastTarget,
        status: TerminalBroadcastPaneResult.Status,
        started: Date,
        message: String,
        didWriteCommandBytes: Bool
    ) -> TerminalBroadcastPaneResult {
        TerminalBroadcastPaneResult(
            id: target.id,
            profileName: target.profileName,
            paneTitle: target.paneTitle,
            status: status,
            exitCode: nil,
            stdout: "",
            truncated: false,
            durationMs: Int(Date().timeIntervalSince(started) * 1_000),
            errorMessage: message,
            didWriteCommandBytes: didWriteCommandBytes
        )
    }
}
