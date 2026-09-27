import Darwin
import Foundation
import Testing
@testable import JTSTerminal

private final class SleepingSSHTestFixtureBundleToken: NSObject {}

enum SleepingSSHTestFixture {
    static let readyMarker = "SLEEPING_SSH_READY"

    static func readyMarkerURL(for brokerSocketURL: URL) -> URL {
        brokerSocketURL.appendingPathExtension("ready")
    }

    static func executableURL() throws -> URL {
        let bundle = Bundle(for: SleepingSSHTestFixtureBundleToken.self)
        let executable = bundle.url(
            forResource: "sleeping_ssh",
            withExtension: "sh",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "sleeping_ssh", withExtension: "sh")
        guard let executable else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return executable
    }

    static func recoveringExecutableURL() throws -> URL {
        let bundle = Bundle(for: SleepingSSHTestFixtureBundleToken.self)
        let executable = bundle.url(
            forResource: "ssh",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "ssh", withExtension: nil)
        guard let executable else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return executable
    }
}

@Suite("Interactive PTY stream safety")
struct InteractivePTYStreamSafetyTests {
    @Test func utf8DecoderPreservesUnicodeAcrossEveryByteBoundary() {
        let expected = "密碼🔐e\u{301}\r\n"
        let bytes = Array(expected.utf8)

        for boundary in 0...bytes.count {
            var decoder = TerminalUTF8StreamDecoder()
            var decoded = decoder.decode(bytes[..<boundary])
            decoded += decoder.decode(bytes[boundary...])
            decoded += decoder.finish()

            #expect(decoded == expected)
            #expect(!decoded.contains("\u{FFFD}"))
        }

        var byteAtATimeDecoder = TerminalUTF8StreamDecoder()
        var byteAtATime = ""
        for byte in bytes {
            byteAtATime += byteAtATimeDecoder.decode([byte][...])
        }
        byteAtATime += byteAtATimeDecoder.finish()
        #expect(byteAtATime == expected)
    }

    @Test func utf8DecoderFlushesIncompleteSuffixAndResets() {
        var decoder = TerminalUTF8StreamDecoder()

        #expect(decoder.decode([0xE2, 0x82][...]).isEmpty)
        #expect(decoder.finish() == "\u{FFFD}")
        #expect(decoder.decode(Array("OK".utf8)[...]) == "OK")
        #expect(decoder.finish().isEmpty)
    }

    @Test func unicodePasswordEchoIsRedactedAcrossRawByteBoundaries() {
        let secret = "密碼🔐"
        let rawOutput = Array("\(secret)\r\nAUTH:OK\r\n".utf8)
        var decoder = TerminalUTF8StreamDecoder()
        var redactor = TerminalSensitiveInputEchoRedactor()
        var safeOutput = ""

        redactor.recordInput("\(secret)\r")
        redactor.submit(secret: secret)
        for byte in rawOutput {
            let decoded = decoder.decode([byte][...])
            safeOutput += redactor.redact(decoded)
        }
        safeOutput += redactor.redact(decoder.finish())
        safeOutput += redactor.finish()

        #expect(safeOutput.contains("AUTH:OK"))
        #expect(!safeOutput.contains(secret))
        #expect(!safeOutput.contains("\u{FFFD}"))
    }

    @Test func unterminatedSensitivePrefixDoesNotSwallowNormalSuffix() {
        let secret = "saved-secret"
        var redactor = TerminalSensitiveInputEchoRedactor()
        redactor.recordInput("\(secret)\r")
        redactor.submit(secret: secret)

        let safeOutput = redactor.redact("\(secret)AUTH:OK")

        #expect(safeOutput == "AUTH:OK")
        #expect(redactor.isComplete)
        #expect(!safeOutput.contains(secret))
    }

    @Test func oversizedNormalSuffixIsReleasedWithoutLeakingSensitivePrefix() {
        let secret = "overflow-secret"
        let normalOutput = String(repeating: "N", count: 70_000)
        var redactor = TerminalSensitiveInputEchoRedactor()
        redactor.recordInput("\(secret)\r")
        redactor.submit(secret: secret)

        let safeOutput = redactor.redact(secret + normalOutput)

        #expect(safeOutput == normalOutput)
        #expect(redactor.isComplete)
        #expect(!safeOutput.contains(secret))
    }

    @Test func unsubmittedCaptureStreamsUnrelatedOutputAndRemainsArmed() {
        let secret = "partial-secret"
        var redactor = TerminalSensitiveInputEchoRedactor()
        redactor.recordInput(secret)

        #expect(redactor.redact(secret).isEmpty)
        #expect(redactor.redact("SERVER-NOTICE") == "SERVER-NOTICE")
        #expect(!redactor.isComplete)
        #expect(redactor.finish().isEmpty)
        #expect(redactor.isComplete)
    }

    @Test func launchGateFailsClosedWhenStandardInputIsNotPTY() throws {
        let status = try runLaunchGate(
            releaseBytes: TerminalProcessLaunchGate.releaseBytes,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(status == 125)
    }

    @Test func systemSSHPTYIsPreconfiguredWithOpenSSHRawMode() throws {
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        #expect(openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0)
        guard masterDescriptor >= 0, slaveDescriptor >= 0 else { return }
        defer {
            Darwin.close(masterDescriptor)
            Darwin.close(slaveDescriptor)
        }

        try SSHPTYTerminalMode.configureRawMode(on: masterDescriptor)

        var observed = termios()
        #expect(Darwin.tcgetattr(slaveDescriptor, &observed) == 0)
        let forbiddenInputFlags = tcflag_t(ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXANY | IXOFF)
        let forbiddenLocalFlags = tcflag_t(ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHONL | IEXTEN)
        #expect(observed.c_iflag & tcflag_t(IGNPAR) != 0)
        #expect(observed.c_iflag & forbiddenInputFlags == 0)
        #expect(observed.c_lflag & forbiddenLocalFlags == 0)
        #expect(observed.c_oflag & tcflag_t(OPOST) == 0)
        #expect(observed.c_cc.16 == 1)
        #expect(observed.c_cc.17 == 0)
        #expect(SSHPTYTerminalMode.requiresRawPreconfiguration(
            for: "/usr/bin/ssh",
            arguments: ["-o", "RequestTTY=force", "--", "user@example.test"]
        ))
        #expect(!SSHPTYTerminalMode.requiresRawPreconfiguration(
            for: "/usr/bin/ssh",
            arguments: ["--", "user@example.test", "hostname"]
        ))
        #expect(!SSHPTYTerminalMode.requiresRawPreconfiguration(
            for: "/usr/bin/ssh",
            arguments: ["--", "user@example.test", "RequestTTY=force"]
        ))
        #expect(!SSHPTYTerminalMode.requiresRawPreconfiguration(
            for: "/usr/bin/ssh",
            arguments: ["--", "user@example.test", "-o", "RequestTTY=force"]
        ))
        #expect(!SSHPTYTerminalMode.requiresRawPreconfiguration(
            for: "/tmp/ssh",
            arguments: ["-o", "RequestTTY=force"]
        ))
    }

    @Test func openSSHRawModePreservesControlCarriageReturnAndUTF8Bytes() throws {
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        #expect(openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0)
        guard masterDescriptor >= 0, slaveDescriptor >= 0 else { return }
        defer {
            Darwin.close(masterDescriptor)
            Darwin.close(slaveDescriptor)
        }

        try SSHPTYTerminalMode.configureRawMode(on: masterDescriptor)
        let payload = [0x03, 0x0D, 0x1A, 0x7F] + Array("密🔐".utf8)
        try writeAll(payload, to: masterDescriptor)

        #expect(try readExactly(payload.count, from: slaveDescriptor) == payload)
    }

    @Test func launchGateAcceptsTerminalIOWithoutRequiringControllingTTY() throws {
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        #expect(openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0)
        guard masterDescriptor >= 0, slaveDescriptor >= 0 else { return }
        defer {
            if masterDescriptor >= 0 { Darwin.close(masterDescriptor) }
            if slaveDescriptor >= 0 { Darwin.close(slaveDescriptor) }
        }

        try SSHPTYTerminalMode.configureRawMode(on: masterDescriptor)

        let process = Process()
        let readyPipe = Pipe()
        let slaveHandle = FileHandle(
            fileDescriptor: slaveDescriptor,
            closeOnDealloc: false
        )
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            TerminalProcessLaunchGate.script,
            "jts-pty-no-controlling-tty-test",
            "/usr/bin/true",
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            TerminalProcessLaunchGate.readyFileDescriptorEnvironmentKey: "2",
        ]
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = readyPipe

        try process.run()
        Darwin.close(slaveDescriptor)
        slaveDescriptor = -1
        try readyPipe.fileHandleForWriting.close()
        try writeAll(
            TerminalProcessLaunchGate.releaseBytes,
            to: masterDescriptor
        )
        process.waitUntilExit()
        let acknowledgement = try readyPipe.fileHandleForReading.readToEnd() ?? Data()

        #expect(process.terminationStatus == 0)
        #expect(Array(acknowledgement) == TerminalProcessLaunchGate.terminalIOReadyBytes)
    }

    @Test func launchedChildKeepsPTYStreamsAndHidesReadyChannel() async throws {
        let session = await MainActor.run { InteractiveProcessSession() }
        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: [
                    "-lc",
                    "if [ -n \"${JTS_PTY_READY_FD:-}\" ]; then printf 'READY_ENV_LEAK\\n'; elif [ -t 0 ] && [ -t 1 ]; then printf 'PTY_STREAMS_OK\\n'; else printf 'PTY_STREAMS_UNAVAILABLE\\n'; fi",
                ],
                label: "sandbox-compatible PTY capability test"
            )
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var transcript = ""
        while ContinuousClock.now < deadline {
            transcript = await MainActor.run { session.transcript }
            if transcript.contains("PTY_STREAMS_OK")
                || transcript.contains("PTY_STREAMS_UNAVAILABLE")
                || transcript.contains("Failed to create PTY session") {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        transcript = await MainActor.run {
            session.stop()
            return session.transcript
        }

        #expect(transcript.contains("PTY_STREAMS_OK"))
        #expect(!transcript.contains("PTY_STREAMS_UNAVAILABLE"))
        #expect(!transcript.contains("READY_ENV_LEAK"))
        #expect(!transcript.contains("Failed to create PTY session"))
    }

    @Test func ptyExitDiagnosticsDecodeStatusAndPreserveRemoteLineEndings() async throws {
        // Use CR and ANSI bytes without changing the PTY's default OPOST mode.
        // Sandboxed children cannot rely on stty's terminal-discipline ioctl;
        // unmodified LF coverage belongs to the pure formatter tests.
        let remoteOutput = "REMOTE_START\u{1b}[31m\r  REMOTE_END\u{1b}[0m"
        let session = await MainActor.run { InteractiveProcessSession() }
        await MainActor.run {
            session.start(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf 'REMOTE_START\\033[31m\\r  REMOTE_END\\033[0m'; exit 255",
                ],
                label: "PTY exit diagnostic boundary test"
            )
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await MainActor.run(body: { !session.isRunning }) {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let (transcript, stoppedNaturally) = await MainActor.run {
            let result = (session.transcript, !session.isRunning)
            if session.isRunning {
                session.stop()
            }
            return result
        }

        #expect(stoppedNaturally)
        #expect(transcript.contains(remoteOutput + "\r\n[PTY session exited with status 255]\r\n"))
        #expect(!transcript.contains("status 65280"))
        #expect(!transcript.contains("Failed to create PTY session"))
    }

    @Test func orderedPTYDeliversMoreThanOneFiniteReadWindowBeforeExit() async throws {
        let payloadSize = 192 * 1024
        let completionMarker = "LARGE_PTY_OUTPUT_END"
        let exitMarker = "[PTY session exited with status "
        let session = await MainActor.run { InteractiveProcessSession() }
        let childPID = await MainActor.run { () -> pid_t? in
            session.start(
                executable: "/usr/bin/perl",
                arguments: [
                    "-e",
                    "$chunk = 'x' x 4096; print $chunk for 1..48; print \"\(completionMarker)\\n\";",
                ],
                label: "large ordered PTY output test"
            )
            return session.pid
        }
        let validPID = try #require(childPID)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var transcript = ""
        var stoppedNaturally = false
        while ContinuousClock.now < deadline {
            (transcript, stoppedNaturally) = await MainActor.run {
                (session.transcript, !session.isRunning)
            }
            if stoppedNaturally
                || transcript.contains("Failed to create PTY session") {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        transcript = await MainActor.run {
            let finalTranscript = session.transcript
            if session.isRunning {
                session.stop()
            }
            return finalTranscript
        }

        #expect(stoppedNaturally)
        #expect(transcript.contains(completionMarker))
        #expect(transcript.filter { $0 == "x" }.count >= payloadSize)
        let completionRange = transcript.range(of: completionMarker)
        let exitRange = transcript.range(of: exitMarker)
        #expect(completionRange != nil)
        #expect(exitRange != nil)
        if let completionRange, let exitRange {
            #expect(completionRange.lowerBound < exitRange.lowerBound)
        }
        #expect(transcript.components(separatedBy: exitMarker).count == 2)
        #expect(!transcript.contains("Failed to create PTY session"))
        #expect(try await waitUntilProcessIsGone(validPID))
    }

    @Test func runningPTYChildReceivesDynamicWindowSizeChanges() async throws {
        let session = await MainActor.run { InteractiveProcessSession() }
        await MainActor.run {
            session.resize(columns: 80, rows: 24)
            session.start(
                executable: "/usr/bin/perl",
                arguments: [
                    "-e",
                    "select(STDOUT); $| = 1; sub report_size { my $size = pack('S4', 0, 0, 0, 0); ioctl(STDIN, 0x40087468, $size) or die \"TIOCGWINSZ: $!\\n\"; my ($rows, $columns) = unpack('S4', $size); print \"WINCH:$rows:$columns\\n\"; } $SIG{WINCH} = \\&report_size; print \"RESIZE_READY\\n\"; while (1) { sleep 1; }",
                ],
                label: "dynamic PTY resize test"
            )
        }

        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var transcript = ""
        while ContinuousClock.now < readyDeadline {
            transcript = await MainActor.run { session.transcript }
            if transcript.contains("RESIZE_READY")
                || transcript.contains("Failed to create PTY session") {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(transcript.contains("RESIZE_READY"))
        await MainActor.run {
            session.resize(columns: 101, rows: 41)
        }

        let resizeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < resizeDeadline {
            transcript = await MainActor.run { session.transcript }
            if transcript.contains("WINCH:41:101")
                || transcript.contains("Failed to create PTY session") {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        await MainActor.run {
            session.stop()
        }

        #expect(transcript.contains("WINCH:41:101"))
        #expect(!transcript.contains("Failed to create PTY session"))
    }

    @Test func stoppingPTYReapsChildWithoutLeavingZombie() async throws {
        for iteration in 0..<3 {
            let session = await MainActor.run { InteractiveProcessSession() }
            let childPID = await MainActor.run { () -> pid_t? in
                session.start(
                    executable: "/bin/sleep",
                    arguments: ["5"],
                    label: "PTY reap test \(iteration)"
                )
                return session.pid
            }
            let validPID = try #require(childPID)

            await MainActor.run {
                session.stop()
            }

            #expect(try await waitUntilProcessIsGone(validPID))
        }
    }

    @Test @MainActor
    func releasingPTYSessionReapsChildWithoutExplicitStop() async throws {
        var session: InteractiveProcessSession? = InteractiveProcessSession()
        session?.start(
            executable: "/bin/sleep",
            arguments: ["5"],
            label: "PTY deinit reap test"
        )
        let validPID = try #require(session?.pid)

        session = nil

        #expect(try await waitUntilProcessIsGone(validPID))
    }

    @Test func savedCredentialBrokerLivesForPTYAndIsCleanedOnStop() async throws {
        let fakeSSH = try SleepingSSHTestFixture.executableURL()

        let session = await MainActor.run {
            InteractiveProcessSession(
                credentialReader: { _ in "synthetic-lifecycle-secret" },
                sshExecutable: fakeSSH.path
            )
        }
        let profile = RemoteSession(
            host: "lifecycle.example.test",
            username: "tester",
            port: 22
        )

        await MainActor.run {
            session.startSSH(session: profile)
        }

        var brokerSocketURL: URL?
        var readyMarkerURL: URL?
        var fixtureWasReady = false
        var wasRunning = false
        for _ in 0..<400 {
            (brokerSocketURL, wasRunning) = await MainActor.run {
                (session.activeCredentialBrokerSocketURL, session.isRunning)
            }

            if let brokerSocketURL {
                let candidate = SleepingSSHTestFixture.readyMarkerURL(
                    for: brokerSocketURL
                )
                readyMarkerURL = candidate
                let observedMarker = try? String(
                    contentsOf: candidate,
                    encoding: .utf8
                )
                if observedMarker?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    == SleepingSSHTestFixture.readyMarker {
                    fixtureWasReady = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let socketExistedDuringLaunch = brokerSocketURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let contextStayedRetained = await MainActor.run {
            session.isRunning
                && session.activeCredentialBrokerSocketURL == brokerSocketURL
        }

        if let readyMarkerURL {
            try? FileManager.default.removeItem(at: readyMarkerURL)
        }
        await MainActor.run {
            session.stop()
        }

        if let brokerSocketURL {
            let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while ContinuousClock.now < cleanupDeadline,
                  FileManager.default.fileExists(atPath: brokerSocketURL.path) {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        let activeContextAfterStop = await MainActor.run {
            session.activeCredentialBrokerSocketURL
        }

        #expect(wasRunning)
        #expect(fixtureWasReady)
        #expect(socketExistedDuringLaunch)
        #expect(contextStayedRetained)
        #expect(activeContextAfterStop == nil)
        if let readyMarkerURL {
            try? FileManager.default.removeItem(at: readyMarkerURL)
        }
        if let brokerSocketURL {
            #expect(!FileManager.default.fileExists(atPath: brokerSocketURL.path))
            try? FileManager.default.removeItem(
                at: brokerSocketURL.deletingLastPathComponent()
            )
        }
    }

    private func runLaunchGate(
        releaseBytes: [UInt8],
        environment: [String: String]
    ) throws -> Int32 {
        let process = Process()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            TerminalProcessLaunchGate.script,
            "jts-pty-stream-safety-test",
            "/usr/bin/true",
        ]
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        try standardInput.fileHandleForWriting.write(contentsOf: Data(releaseBytes))
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func writeAll(_ bytes: [UInt8], to fileDescriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func readExactly(_ expectedCount: Int, from fileDescriptor: Int32) throws -> [UInt8] {
        var result: [UInt8] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while result.count < expectedCount, ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, 100)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if pollResult == 0 { continue }

            var buffer = [UInt8](repeating: 0, count: expectedCount - result.count)
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(Int(count)))
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            } else {
                break
            }
        }
        return result
    }

    private func waitUntilProcessIsGone(_ processID: pid_t) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if processIsGone(processID) {
                return true
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        // Swift Testing runs suites concurrently. If this task is suspended
        // past the deadline after its first poll, the child may already have
        // been reaped when execution resumes. Always sample the real process
        // state once more instead of converting scheduler delay into a false
        // lifecycle failure.
        return processIsGone(processID)
    }

    private func processIsGone(_ processID: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(processID, 0) < 0 && errno == ESRCH
    }
}
