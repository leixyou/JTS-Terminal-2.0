import Combine
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct TerminalBroadcastCoordinatorObservationTests {
    @Test func duplicatePaneTargetsForwardOneSessionChangeAndDetachOnClose() throws {
        let process = InteractiveProcessSession()
        process.start(
            executable: "/bin/sh",
            arguments: [],
            label: "duplicate broadcast observation shell"
        )
        defer {
            process.stop()
        }
        process.setBroadcastReady(true)
        let generation = try #require(process.executionGeneration)
        let targets = [
            target(
                process: process,
                generation: generation,
                profileName: "Duplicate A",
                paneTitle: "Pane A"
            ),
            target(
                process: process,
                generation: generation,
                profileName: "Duplicate B",
                paneTitle: "Pane B"
            ),
        ]

        let coordinator = TerminalBroadcastCoordinator()
        coordinator.open(targets: targets)
        coordinator.selectAllEligible()
        coordinator.command = "printf 'READY'"
        #expect(coordinator.canReview)

        var publicationCount = 0
        let observation = coordinator.objectWillChange.sink {
            publicationCount += 1
        }
        let externalBatchID = UUID()
        #expect(process.reserveBroadcast(
            batchID: externalBatchID,
            expectedGeneration: generation
        ))

        #expect(publicationCount == 1)
        #expect(coordinator.selectedTargets.allSatisfy {
            $0.availability == .busy
        })
        #expect(!coordinator.canReview)

        coordinator.close()
        publicationCount = 0
        process.releaseBroadcastReservation(batchID: externalBatchID)
        #expect(publicationCount == 0)

        withExtendedLifetime(observation) {}
    }

    @Test func reviewedBatchPublishesBusyAndRecoveryAndCannotRun() async throws {
        let firstProcess = InteractiveProcessSession()
        let secondProcess = InteractiveProcessSession()
        for process in [firstProcess, secondProcess] {
            process.start(
                executable: "/bin/sh",
                arguments: [],
                label: "review invalidation shell"
            )
            process.setMCPControlEnabled(true)
            process.setBroadcastReady(true)
        }
        defer {
            firstProcess.stop()
            secondProcess.stop()
        }

        let firstGeneration = try #require(firstProcess.executionGeneration)
        let secondGeneration = try #require(secondProcess.executionGeneration)
        let firstTarget = target(
            process: firstProcess,
            generation: firstGeneration,
            profileName: "First",
            paneTitle: "Pane 1"
        )
        let secondTarget = target(
            process: secondProcess,
            generation: secondGeneration,
            profileName: "Second",
            paneTitle: "Pane 2"
        )
        let coordinator = TerminalBroadcastCoordinator()
        coordinator.open(targets: [firstTarget, secondTarget])
        coordinator.selectAllEligible()
        coordinator.command = "printf 'REVIEWED'"
        coordinator.review()
        coordinator.didConfirmPromptState = true
        #expect(coordinator.canRun)

        var publicationCount = 0
        let observation = coordinator.objectWillChange.sink {
            publicationCount += 1
        }
        let timeoutTask = Task {
            try await firstProcess.runMCPCommand(
                command: "sleep 2",
                timeoutSeconds: 1,
                maxOutputBytes: 64
            )
        }

        let busyDeadline = Date().addingTimeInterval(2)
        while !firstProcess.isStructuredCommandBusy, Date() < busyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(firstProcess.isStructuredCommandBusy)
        #expect(publicationCount > 0)
        #expect(firstTarget.availability == .busy)
        #expect(!coordinator.canRun)

        let result = try await timeoutTask.value
        #expect(result.timedOut)
        #expect(firstProcess.requiresStructuredCommandRecovery)
        #expect(firstTarget.availability == .recoveryRequired)
        #expect(!coordinator.canRun)

        coordinator.close()
        withExtendedLifetime(observation) {}
    }

    @Test func maximumSizeBatchStartsEveryReservedPaneBeforeAwaitingResults() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-multi-exec-start-barrier-\(UUID().uuidString)",
                isDirectory: true
            )
        let releaseURL = temporaryRoot.appendingPathComponent("release")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )

        var processes: [InteractiveProcessSession] = []
        defer {
            for process in processes {
                process.stop()
            }
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        var targets: [TerminalBroadcastTarget] = []
        for index in 0..<TerminalBroadcastPolicy.maximumTargetCount {
            let process = InteractiveProcessSession()
            process.start(
                executable: "/bin/sh",
                arguments: [],
                label: "broadcast start barrier \(index + 1)"
            )
            process.setBroadcastReady(true)
            let generation = try #require(process.executionGeneration)
            processes.append(process)
            targets.append(target(
                process: process,
                generation: generation,
                profileName: "Target \(index + 1)",
                paneTitle: "Pane \(index + 1)"
            ))
        }

        let coordinator = TerminalBroadcastCoordinator()
        coordinator.open(targets: targets)
        coordinator.selectAllEligible()
        coordinator.command = """
        while [ ! -e \(SSHCommandBuilder.shellQuote(releaseURL.path)) ]; do sleep 0.02; done
        printf 'START_BARRIER_DONE\\n'
        """
        coordinator.review()
        coordinator.didConfirmPromptState = true
        let runID = try #require(coordinator.runConfirmedBatch())

        #expect(coordinator.phase == .running)
        #expect(coordinator.results.count == TerminalBroadcastPolicy.maximumTargetCount)
        #expect(coordinator.results.allSatisfy { $0.status == .running })

        try Data().write(to: releaseURL)
        let didComplete = await coordinator.waitForBatchCompletion(
            runID: runID,
            timeout: .seconds(30)
        )

        #expect(didComplete)
        #expect(coordinator.phase == .results)
        #expect(coordinator.results.allSatisfy { result in
            result.status == .succeeded &&
                result.stdout.contains("START_BARRIER_DONE")
        })
        coordinator.close()
    }

    @Test func staleBatchCompletionHandleCannotCompleteReplacementBatch() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-multi-exec-run-id-\(UUID().uuidString)",
                isDirectory: true
            )
        let releaseURL = temporaryRoot.appendingPathComponent("release")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )

        let processes = [InteractiveProcessSession(), InteractiveProcessSession()]
        defer {
            for process in processes {
                process.stop()
            }
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        var targets: [TerminalBroadcastTarget] = []
        for (index, process) in processes.enumerated() {
            process.start(
                executable: "/bin/sh",
                arguments: [],
                label: "broadcast run identifier \(index + 1)"
            )
            process.setBroadcastReady(true)
            targets.append(target(
                process: process,
                generation: try #require(process.executionGeneration),
                profileName: "Target \(index + 1)",
                paneTitle: "Pane \(index + 1)"
            ))
        }

        let coordinator = TerminalBroadcastCoordinator()
        coordinator.open(targets: targets)
        coordinator.selectAllEligible()
        coordinator.command = "printf 'FIRST_RUN'"
        coordinator.review()
        coordinator.didConfirmPromptState = true
        let firstRunID = try #require(coordinator.runConfirmedBatch())
        let didCompleteFirstRun = await coordinator.waitForBatchCompletion(
            runID: firstRunID,
            timeout: .seconds(30)
        )
        #expect(didCompleteFirstRun)
        #expect(coordinator.results.allSatisfy { $0.status == .succeeded })

        coordinator.close()
        coordinator.open(targets: targets)
        coordinator.selectAllEligible()
        coordinator.command = """
        while [ ! -e \(SSHCommandBuilder.shellQuote(releaseURL.path)) ]; do sleep 0.02; done
        printf 'SECOND_RUN'
        """
        coordinator.review()
        coordinator.didConfirmPromptState = true
        let secondRunID = try #require(coordinator.runConfirmedBatch())

        let didStaleHandleComplete = await coordinator.waitForBatchCompletion(
            runID: firstRunID,
            timeout: .milliseconds(100)
        )
        #expect(!didStaleHandleComplete)
        #expect(coordinator.phase == .running)
        #expect(coordinator.results.allSatisfy { $0.status == .running })

        try Data().write(to: releaseURL)
        let didCompleteSecondRun = await coordinator.waitForBatchCompletion(
            runID: secondRunID,
            timeout: .seconds(30)
        )
        #expect(didCompleteSecondRun)
        #expect(coordinator.phase == .results)
        #expect(coordinator.results.allSatisfy { result in
            result.status == .succeeded && result.stdout == "SECOND_RUN"
        })
        coordinator.close()
    }

    private func target(
        process: InteractiveProcessSession,
        generation: UUID,
        profileName: String,
        paneTitle: String
    ) -> TerminalBroadcastTarget {
        TerminalBroadcastTarget(
            id: UUID(),
            profileName: profileName,
            address: "local",
            paneTitle: paneTitle,
            kind: .localShell,
            reviewedPID: process.pid,
            reviewedGeneration: generation,
            processSession: process
        )
    }
}
