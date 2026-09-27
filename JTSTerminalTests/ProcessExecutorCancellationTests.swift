import Darwin
import Foundation
import Testing
@testable import JTSTerminal

struct ProcessExecutorCancellationTests {
    @Test func unrelatedPTYCannotRetainCollectorReadDescriptor() async throws {
        let collector = try ProcessPipeCollector(maximumBytes: 1_024)
        let writer = try startBusyWriter(for: collector)
        defer { writer.requestStop() }
        let readiness = Pipe()
        let readDescriptor = readiness.fileHandleForReading.fileDescriptor
        let readyDescriptor = readiness.fileHandleForWriting.fileDescriptor
        defer {
            readiness.fileHandleForReading.closeFile()
            readiness.fileHandleForWriting.closeFile()
        }
        try #require(fcntl(readDescriptor, F_SETFL, O_NONBLOCK) == 0)
        // An explicit private channel must survive even when it starts out
        // CLOEXEC; every unrelated descriptor must be closed by the child.
        try #require(fcntl(readyDescriptor, F_SETFD, FD_CLOEXEC) == 0)
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let script = """
        [ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 41
        [ "$JTS_INHERITANCE_TEST" = ready ] || exit 42
        printf '%s' "$$" >&\(readyDescriptor)
        exec \(readyDescriptor)>&-
        exec /bin/sleep 30
        """
        let child = try PTYProcessLauncher.launch(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: ["PATH=/usr/bin:/bin", "JTS_INHERITANCE_TEST=ready"],
            preservingDescriptor: readyDescriptor,
            windowSize: &size
        )
        defer {
            _ = Darwin.kill(child.pid, SIGKILL)
            var status: Int32 = 0
            while Darwin.waitpid(child.pid, &status, 0) < 0, errno == EINTR {}
            _ = Darwin.close(child.masterFd)
        }
        #expect(fcntl(readyDescriptor, F_GETFD) & FD_CLOEXEC != 0,
                "Allowing child inheritance must not change the parent's descriptor flags")
        readiness.fileHandleForWriting.closeFile()
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var acknowledgement = Data()
        while ContinuousClock.now < readyDeadline, acknowledgement.isEmpty {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = Darwin.read(readDescriptor, &buffer, buffer.count)
            if count > 0 { acknowledgement.append(contentsOf: buffer.prefix(count)) }
            if count == 0 { break }
            if acknowledgement.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        }
        try #require(String(data: acknowledgement, encoding: .utf8) == String(child.pid))

        collector.discardAndCloseAsynchronously()
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < closeDeadline, !writer.hasFinished {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(writer.hasFinished)
        #expect(writer.terminalErrno == EPIPE,
                "An unrelated, still-live PTY must not keep the collector's reader open")
        var exitStatus: Int32 = 0
        #expect(Darwin.waitpid(child.pid, &exitStatus, WNOHANG) == 0,
                "The writer must receive EPIPE before the unrelated PTY exits")
        _ = collector.finish()
    }

    @Test func collectorClosesReadSourceImmediatelyAtEOF() async throws {
        let closeCompletion = CancellationOperationCompletion()
        let collector = try ProcessPipeCollector(
            maximumBytes: 1_024,
            onReadSourceCancelled: {
                closeCompletion.markFinished()
            }
        )
        let writeHandle = collector.pipe.fileHandleForWriting

        try writeHandle.write(contentsOf: Data("complete".utf8))
        writeHandle.closeFile()

        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < closeDeadline,
              closeCompletion.finishedAt == nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(
            closeCompletion.finishedAt != nil,
            "EOF must cancel the read source instead of repeatedly delivering zero-byte reads"
        )
        #expect(collector.finish() == "complete")
    }

    @Test func discardingBusyCollectorClosesReaderWithoutStrandingWriter() async throws {
        let collector = try ProcessPipeCollector(maximumBytes: 1_024)
        let writer = try startBusyWriter(for: collector)
        defer { writer.requestStop() }

        let writerReadyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < writerReadyDeadline, writer.writtenByteCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(
            writer.writtenByteCount > 0,
            "The fixture must keep the collector's dispatch source readable"
        )

        let discardStartedAt = ContinuousClock.now
        collector.discardAndCloseAsynchronously()
        #expect(
            discardStartedAt.duration(to: .now) < .milliseconds(100),
            "Discarding a collector must never wait for its drain queue"
        )

        // Keep the production-facing discard return bound strict above. The
        // peer cleanup runs on a global queue and can be delayed when the full
        // XCTest matrix executes many suites concurrently.
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < closeDeadline, !writer.hasFinished {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(
            writer.hasFinished,
            "Closing the read side must release a continuously writing peer"
        )
        #expect(
            writer.terminalErrno == EPIPE,
            "The writer must stop because the collector closed its read side"
        )
        _ = collector.finish()

        // The source cancel handler has completed. A fresh pipe must remain
        // usable even if the system immediately reuses a descriptor number.
        let replacementPipe = Pipe()
        try replacementPipe.fileHandleForWriting.write(contentsOf: Data([0x5A]))
        replacementPipe.fileHandleForWriting.closeFile()
        let replacementData = try replacementPipe.fileHandleForReading.readToEnd()
        replacementPipe.fileHandleForReading.closeFile()
        #expect(replacementData == Data([0x5A]))
    }

    @Test func finishingBusyCollectorIsBoundedAndReportsPotentialOutputLoss() async throws {
        let collector = try ProcessPipeCollector(
            maximumBytes: 1_024,
            finalReadOperationLimit: 0
        )
        let writer = try startBusyWriter(for: collector)
        defer { writer.requestStop() }

        let writerReadyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < writerReadyDeadline, writer.writtenByteCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(writer.writtenByteCount > 0)

        let finishStartedAt = ContinuousClock.now
        let output = collector.finish()
        #expect(
            finishStartedAt.duration(to: .now) < .seconds(1),
            "Final collection must stay bounded even while a writer remains active"
        )

        // This only bounds asynchronous fixture cleanup; finish() must still
        // satisfy the one-second API latency assertion above.
        let writerStopDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < writerStopDeadline, !writer.hasFinished {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(writer.hasFinished)
        #expect(writer.terminalErrno == EPIPE)
        #expect(
            output.contains(
                "[output collection stopped after the bounded final drain; additional bytes may have been discarded]"
            )
        )
    }

    private func startBusyWriter(
        for collector: ProcessPipeCollector
    ) throws -> BusyPipeWriterCompletion {
        let pipeWriteHandle = collector.pipe.fileHandleForWriting
        let writerDescriptor = Darwin.dup(pipeWriteHandle.fileDescriptor)
        guard writerDescriptor >= 0 else {
            throw currentPOSIXError()
        }

        guard fcntl(writerDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let error = currentPOSIXError()
            _ = Darwin.close(writerDescriptor)
            pipeWriteHandle.closeFile()
            throw error
        }
        let writerFlags = fcntl(writerDescriptor, F_GETFL)
        guard writerFlags >= 0,
              fcntl(
                  writerDescriptor,
                  F_SETFL,
                  writerFlags | O_NONBLOCK
              ) == 0 else {
            let error = currentPOSIXError()
            _ = Darwin.close(writerDescriptor)
            pipeWriteHandle.closeFile()
            throw error
        }
        pipeWriteHandle.closeFile()

        let writer = BusyPipeWriterCompletion()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { _ = Darwin.close(writerDescriptor) }
            var payload = [UInt8](repeating: 0x41, count: 64 * 1_024)

            while !writer.shouldStop {
                errno = 0
                let writtenByteCount = payload.withUnsafeMutableBytes { bytes in
                    Darwin.write(
                        writerDescriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
                if writtenByteCount > 0 {
                    writer.recordWrite(byteCount: writtenByteCount)
                    continue
                }
                if writtenByteCount < 0, errno == EINTR {
                    continue
                }
                if writtenByteCount < 0,
                   errno == EAGAIN || errno == EWOULDBLOCK {
                    Darwin.usleep(100)
                    continue
                }

                writer.markFinished(
                    terminalErrno: writtenByteCount < 0 ? errno : nil
                )
                return
            }

            writer.markFinished(terminalErrno: nil)
        }
        return writer
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    @Test func cancellingTaskTerminatesProcessTreeAndPreventsLateSideEffect() async throws {
        let readyMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-process-cancel-ready-\(UUID().uuidString)")
        let releaseMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-process-cancel-release-\(UUID().uuidString)")
        let sideEffectMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-process-cancel-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: readyMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
            try? FileManager.default.removeItem(at: sideEffectMarker)
        }
        let executor = ProcessExecutor()
        let completion = CancellationOperationCompletion()
        // The readiness allowance below is 30 seconds. Keep the child blocked
        // substantially longer so scheduler contention cannot let the fixture
        // finish normally before this test gets to request cancellation.
        let fixtureMaximumWaitAttempts = 1_800
        // The project defaults to MainActor isolation. Run the nonisolated,
        // Sendable executor from a detached task so this latency assertion
        // measures process cancellation instead of unrelated MainActor
        // contention from the full test matrix.
        let operation = Task.detached {
            defer { completion.markFinished() }
            return try await executor.run(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "/usr/bin/printf '%s\\n' \"$$\" > \"$1\"; attempts=0; while [ ! -e \"$2\" ] && [ \"$attempts\" -lt \(fixtureMaximumWaitAttempts) ]; do /bin/sleep 0.05; attempts=$((attempts + 1)); done; if [ -e \"$2\" ]; then /usr/bin/touch \"$3\"; fi",
                    "jts-cancellation-test",
                    readyMarker.path,
                    releaseMarker.path,
                    sideEffectMarker.path,
                ]
            )
        }

        // Full x86_64/Rosetta runs start hundreds of tests concurrently and
        // can defer the fixture's first process timeslice well beyond five
        // seconds. Readiness is not the behavior under test, so keep this
        // scheduler allowance generous but bounded; the cancellation return
        // itself remains subject to the strict three-second assertion below.
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        var publishedPID: Int32?
        while ContinuousClock.now < readyDeadline, publishedPID == nil {
            if let data = try? Data(contentsOf: readyMarker),
               let text = String(data: data, encoding: .utf8) {
                publishedPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if publishedPID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let launchedPID = try #require(
            publishedPID,
            "The fixture must publish its process ID before cancellation"
        )
        try #require(
            completion.finishedAt == nil,
            "The cancellation fixture must still be blocked when cancellation begins"
        )

        let cancellationStartedAt = ContinuousClock.now
        operation.cancel()

        let cancellationDeadline = cancellationStartedAt.advanced(by: .seconds(3))
        while ContinuousClock.now < cancellationDeadline,
              completion.finishedAt == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let cancellationFinishedAt = completion.finishedAt
        #expect(
            cancellationFinishedAt != nil,
            "Cancelling ProcessExecutor must return within three seconds"
        )
        guard let cancellationFinishedAt else {
            // Do not release the fixture's potential side effect when the
            // operation failed to return. Its bounded loop will exit cleanly.
            return
        }
        #expect(cancellationStartedAt.duration(to: cancellationFinishedAt) < .seconds(3))

        do {
            _ = try await operation.value
            Issue.record("Cancelling ProcessExecutor must throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let processExitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var processIsGone = false
        while ContinuousClock.now < processExitDeadline {
            errno = 0
            if Darwin.kill(launchedPID, 0) == -1, errno == ESRCH {
                processIsGone = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            processIsGone,
            "ProcessExecutor must reap the cancelled child before returning"
        )

        #expect(FileManager.default.createFile(atPath: releaseMarker.path, contents: Data()))
        try await Task.sleep(for: .milliseconds(250))
        #expect(!FileManager.default.fileExists(atPath: sideEffectMarker.path))
    }

    @Test func alreadyCancelledTaskNeverLaunchesProcess() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-process-precancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let executor = ProcessExecutor()
        let operation = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await executor.run(
                executable: "/usr/bin/touch",
                arguments: [marker.path]
            )
        }

        do {
            _ = try await operation.value
            Issue.record("A cancelled task must not launch a process")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

nonisolated private final class CancellationOperationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFinishedAt: ContinuousClock.Instant?

    var finishedAt: ContinuousClock.Instant? {
        lock.withLock { storedFinishedAt }
    }

    func markFinished() {
        lock.withLock {
            storedFinishedAt = .now
        }
    }
}

private final class BusyPipeWriterCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedShouldStop = false
    private var storedWrittenByteCount = 0
    private var storedHasFinished = false
    private var storedTerminalErrno: Int32?

    var shouldStop: Bool {
        lock.withLock { storedShouldStop }
    }

    var writtenByteCount: Int {
        lock.withLock { storedWrittenByteCount }
    }

    var hasFinished: Bool {
        lock.withLock { storedHasFinished }
    }

    var terminalErrno: Int32? {
        lock.withLock { storedTerminalErrno }
    }

    func recordWrite(byteCount: Int) {
        lock.withLock {
            storedWrittenByteCount += byteCount
        }
    }

    func requestStop() {
        lock.withLock {
            storedShouldStop = true
        }
    }

    func markFinished(terminalErrno: Int32?) {
        lock.withLock {
            storedTerminalErrno = terminalErrno
            storedHasFinished = true
        }
    }
}
