#if ENABLE_RDP_2
import AppKit
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
private final class TestRDPTextPasteboard: RDPTextPasteboardAccess {
    private(set) var changeCount = 1
    private var text: String?

    init(text: String?) {
        self.text = text
    }

    func readText() -> String? {
        text
    }

    func replaceText(_ text: String) {
        self.text = text
        changeCount += 1
    }

    func setLocalText(_ text: String?) {
        self.text = text
        changeCount += 1
    }
}

@MainActor
private final class TestClipboardSendGate {
    private var continuation: CheckedContinuation<Void, Error>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class TestClipboardIsolationRecorder {
    let pauseGate = TestClipboardSendGate()
    let resumeGate = TestClipboardSendGate()
    var blocksResume = false
    private(set) var calls: [(isolated: Bool, text: Data?)] = []

    func execute(
        session: FreeRDPXPCSession,
        isolated: Bool,
        text: Data?
    ) async throws {
        _ = session
        calls.append((isolated, text))
        if isolated {
            try await pauseGate.wait()
        } else if blocksResume {
            try await resumeGate.wait()
        }
    }
}

struct RDPTextClipboardSynchronizerTests {
    @Test func codecAcceptsBoundedUnicodeTextAndRejectsUnsafePayloads() throws {
        let text = "Mac → Windows 中文 clipboard"
        let maybeEncoded = try RDPTextClipboardCodec.encode(text)
        let encoded = try #require(maybeEncoded)
        #expect(try RDPTextClipboardCodec.decode(encoded) == text)
        #expect(try RDPTextClipboardCodec.encode(nil) == nil)
        #expect(try RDPTextClipboardCodec.decode(Data()).isEmpty)

        #expect(throws: RDPTextClipboardError.embeddedNull) {
            try RDPTextClipboardCodec.encode("a\0b")
        }
        #expect(throws: RDPTextClipboardError.invalidUTF8) {
            try RDPTextClipboardCodec.decode(Data([0xC3, 0x28]))
        }
        #expect(throws: RDPTextClipboardError.payloadTooLarge) {
            try RDPTextClipboardCodec.decode(
                Data(
                    repeating: 0x61,
                    count: RDPTextClipboardCodec.maximumUTF8Bytes + 1
                )
            )
        }
    }

    @Test @MainActor
    func synchronizerPublishesLocalTextAndSuppressesRemoteEcho() async throws {
        let pasteboard = TestRDPTextPasteboard(text: "local")
        let synchronizer = RDPTextClipboardSynchronizer(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        var sentPayloads: [Data?] = []
        synchronizer.start { payload in
            sentPayloads.append(payload)
        }
        defer { synchronizer.stop() }

        for _ in 0..<10 where sentPayloads.isEmpty {
            await Task.yield()
        }
        #expect(sentPayloads == [Data("local".utf8)])

        let remotePayload = Data("Windows → Mac".utf8)
        try synchronizer.receiveRemote(remotePayload)
        #expect(pasteboard.readText() == "Windows → Mac")

        try await synchronizer.publishCurrent()
        #expect(sentPayloads == [Data("local".utf8)])

        pasteboard.setLocalText("next local value")
        try await synchronizer.publishCurrent()
        #expect(sentPayloads == [
            Data("local".utf8),
            Data("next local value".utf8),
        ])
    }

    @Test @MainActor
    func manualPasteRejectsOversizedLocalTextWithoutSendingAStaleValue() async throws {
        let pasteboard = TestRDPTextPasteboard(
            text: String(
                repeating: "x",
                count: RDPTextClipboardCodec.maximumUTF8Bytes + 1
            )
        )
        let synchronizer = RDPTextClipboardSynchronizer(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        var sentPayloads: [Data?] = []
        synchronizer.start { payload in
            sentPayloads.append(payload)
        }
        defer { synchronizer.stop() }

        await Task.yield()
        #expect(sentPayloads.isEmpty)
        await #expect(throws: RDPTextClipboardError.payloadTooLarge) {
            try await synchronizer.publishCurrent(force: true)
        }
        #expect(sentPayloads.isEmpty)
    }

    @Test @MainActor
    func xpcClientRejectsMalformedClipboardBeforeOpeningAConnection() async {
        let session = FreeRDPXPCSession()
        do {
            try await session.updateClipboardText(Data([0xC3, 0x28]))
            Issue.record("Malformed UTF-8 must fail before opening XPC")
        } catch let failure as FreeRDPXPCFailure {
            #expect(failure.code == "RDP_CLIPBOARD_TEXT_INVALID")
        } catch {
            Issue.record("Unexpected malformed UTF-8 failure: \(error)")
        }
        do {
            try await session.updateClipboardText(Data("a\0b".utf8))
            Issue.record("Embedded null text must fail before opening XPC")
        } catch let failure as FreeRDPXPCFailure {
            #expect(failure.code == "RDP_CLIPBOARD_TEXT_INVALID")
        } catch {
            Issue.record("Unexpected embedded-null failure: \(error)")
        }
    }

    @Test @MainActor
    func staleLocalSendCannotOverwriteANewerRemoteClipboardGeneration() async throws {
        let pasteboard = TestRDPTextPasteboard(text: "A")
        let gate = TestClipboardSendGate()
        let synchronizer = RDPTextClipboardSynchronizer(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        var payloads: [Data?] = []
        synchronizer.start { payload in
            payloads.append(payload)
            if payloads.count == 1 {
                try await gate.wait()
            }
        }
        defer { synchronizer.stop() }

        for _ in 0..<100 where !gate.isWaiting {
            await Task.yield()
        }
        #expect(gate.isWaiting)
        try synchronizer.receiveRemote(Data("B".utf8))
        gate.succeed()
        await Task.yield()

        pasteboard.setLocalText("A")
        try await synchronizer.publishCurrent()
        #expect(payloads == [Data("A".utf8), Data("A".utf8)])
    }

    @Test @MainActor
    func manualPasteReusesMatchingPollingPublicationInsteadOfSendingALateDuplicate() async throws {
        let pasteboard = TestRDPTextPasteboard(text: "round trip command")
        let gate = TestClipboardSendGate()
        let synchronizer = RDPTextClipboardSynchronizer(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        var payloads: [Data?] = []
        synchronizer.start { payload in
            payloads.append(payload)
            try await gate.wait()
        }
        defer { synchronizer.stop() }

        for _ in 0..<100 where !gate.isWaiting {
            await Task.yield()
        }
        #expect(gate.isWaiting)
        #expect(payloads == [Data("round trip command".utf8)])

        let manualPaste = Task { @MainActor in
            try await synchronizer.publishCurrent(force: true)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(payloads == [Data("round trip command".utf8)])

        gate.succeed()
        try await manualPaste.value
        #expect(payloads == [Data("round trip command".utf8)])
    }

    @Test @MainActor
    func changedManualPasteSerializesBehindAnOlderPollingPublication() async throws {
        let pasteboard = TestRDPTextPasteboard(text: "old")
        let gate = TestClipboardSendGate()
        let synchronizer = RDPTextClipboardSynchronizer(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        var payloads: [Data?] = []
        synchronizer.start { payload in
            payloads.append(payload)
            if payloads.count == 1 {
                try await gate.wait()
            }
        }
        defer { synchronizer.stop() }

        for _ in 0..<100 where !gate.isWaiting {
            await Task.yield()
        }
        #expect(gate.isWaiting)
        pasteboard.setLocalText("new")

        let manualPaste = Task { @MainActor in
            try await synchronizer.publishCurrent(force: true)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(payloads == [Data("old".utf8)])

        gate.succeed()
        try await manualPaste.value
        #expect(payloads == [
            Data("old".utf8),
            Data("new".utf8),
        ])
    }

    @Test @MainActor
    func cancelledManualPasteStopsAfterJoiningSharedPublication() async throws {
        let pasteboard = TestRDPTextPasteboard(text: "shared")
        let gate = TestClipboardSendGate()
        let synchronizer = RDPTextClipboardSynchronizer(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        var payloads: [Data?] = []
        synchronizer.start { payload in
            payloads.append(payload)
            try await gate.wait()
        }
        defer { synchronizer.stop() }

        for _ in 0..<100 where !gate.isWaiting {
            await Task.yield()
        }
        #expect(gate.isWaiting)

        let manualPaste = Task { @MainActor in
            try await synchronizer.publishCurrent(force: true)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        manualPaste.cancel()
        gate.succeed()

        await #expect(throws: CancellationError.self) {
            try await manualPaste.value
        }
        #expect(payloads == [Data("shared".utf8)])
    }

    @Test @MainActor
    func completedSendFromAStoppedRunCannotPolluteTheRestartedRun() async throws {
        let pasteboard = TestRDPTextPasteboard(text: "old")
        let gate = TestClipboardSendGate()
        let synchronizer = RDPTextClipboardSynchronizer(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        var oldRunPayloads: [Data?] = []
        synchronizer.start { payload in
            oldRunPayloads.append(payload)
            try await gate.wait()
        }
        for _ in 0..<100 where !gate.isWaiting {
            await Task.yield()
        }
        #expect(gate.isWaiting)

        synchronizer.stop()
        pasteboard.setLocalText("new")
        var newRunPayloads: [Data?] = []
        synchronizer.start { payload in
            newRunPayloads.append(payload)
        }
        gate.succeed()
        for _ in 0..<20 where newRunPayloads.isEmpty {
            await Task.yield()
        }
        defer { synchronizer.stop() }

        #expect(oldRunPayloads == [Data("old".utf8)])
        #expect(newRunPayloads == [Data("new".utf8)])
    }

    @Test @MainActor
    func appKitKeyEquivalentRoutesCommandPasteAndSuppressesItsPhysicalKeyUp() throws {
        let view = RDPDesktopNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        #expect(window.makeFirstResponder(view))
        var captured: [RDPManualDesktopInput] = []
        view.onInput = { captured.append($0) }

        let keyDown = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))
        #expect(view.performKeyEquivalent(with: keyDown))
        let keyUp = try #require(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))
        view.keyUp(with: keyUp)

        #expect(captured.count == 1)
        guard case let .key(name, isDown, modifiers) = captured.first else {
            Issue.record("Command-V must route as one remote control chord")
            return
        }
        #expect(name == "v")
        #expect(isDown)
        #expect(modifiers == ["control"])
    }

    @Test @MainActor
    func aiControlWaitsForOneSharedClipboardBarrierAndResumesAfterFinalToken() async throws {
        let recorder = TestClipboardIsolationRecorder()
        let target = RemoteSession(
            name: "Clipboard Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                RDPDesktopSessionState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected,
                    runtimeAvailability: .available,
                    companion: .unknown,
                    stateRevision: 1,
                    latestFrameID: nil,
                    remotePixelWidth: nil,
                    remotePixelHeight: nil,
                    connectedAt: Date(),
                    reconnectAttempt: nil,
                    reconnectMaximumAttempts: nil,
                    reconnectScheduledAt: nil,
                    lastErrorCode: nil,
                    lastErrorMessage: nil
                )
            },
            clipboardIsolationBarrierForTesting: { session, isolated, text in
                try await recorder.execute(
                    session: session,
                    isolated: isolated,
                    text: text
                )
            }
        )
        defer { store.stopAllImmediately() }
        _ = store.installActiveDesktopForTesting(target: target)
        let first = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: "clipboard-test-client",
            displayIdentity: "Clipboard Test Client",
            capabilities: [.desktopControl]
        )
        let second = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: "clipboard-test-client",
            displayIdentity: "Clipboard Test Client",
            capabilities: [.commandExecution]
        )
        #expect(store.isClipboardSuspendedForAIForTesting(targetID: target.targetID))

        var firstPrepared = false
        var secondPrepared = false
        let firstTask = Task { @MainActor in
            try await store.prepareAuthorizedOperation(first)
            firstPrepared = true
        }
        let secondTask = Task { @MainActor in
            try await store.prepareAuthorizedOperation(second)
            secondPrepared = true
        }
        for _ in 0..<100 where !recorder.pauseGate.isWaiting {
            await Task.yield()
        }
        #expect(recorder.calls.map(\.isolated) == [true])
        #expect(!firstPrepared)
        #expect(!secondPrepared)

        recorder.pauseGate.succeed()
        try await firstTask.value
        try await secondTask.value
        #expect(firstPrepared)
        #expect(secondPrepared)

        store.finishAuthorizedOperation(first)
        #expect(store.isClipboardSuspendedForAIForTesting(targetID: target.targetID))
        store.finishAuthorizedOperation(second)
        for _ in 0..<100 where store.isClipboardSuspendedForAIForTesting(
            targetID: target.targetID
        ) {
            await Task.yield()
        }
        #expect(recorder.calls.map(\.isolated) == [true, false])
        #expect(!store.isClipboardSuspendedForAIForTesting(targetID: target.targetID))
    }

    @Test @MainActor
    func newAIControlWaitsForAnInFlightResumeThenEstablishesANewPauseBarrier() async throws {
        let recorder = TestClipboardIsolationRecorder()
        let target = RemoteSession(
            name: "Clipboard Resume Race",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                RDPDesktopSessionState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected,
                    runtimeAvailability: .available,
                    companion: .unknown,
                    stateRevision: 1,
                    latestFrameID: nil,
                    remotePixelWidth: nil,
                    remotePixelHeight: nil,
                    connectedAt: Date(),
                    reconnectAttempt: nil,
                    reconnectMaximumAttempts: nil,
                    reconnectScheduledAt: nil,
                    lastErrorCode: nil,
                    lastErrorMessage: nil
                )
            },
            clipboardIsolationBarrierForTesting: { session, isolated, text in
                try await recorder.execute(
                    session: session,
                    isolated: isolated,
                    text: text
                )
            }
        )
        defer { store.stopAllImmediately() }
        _ = store.installActiveDesktopForTesting(target: target)

        let first = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: "resume-race-client",
            displayIdentity: "Resume Race Client",
            capabilities: [.desktopControl]
        )
        let firstPrepare = Task { @MainActor in
            try await store.prepareAuthorizedOperation(first)
        }
        for _ in 0..<100 where !recorder.pauseGate.isWaiting {
            await Task.yield()
        }
        recorder.pauseGate.succeed()
        try await firstPrepare.value

        recorder.blocksResume = true
        store.finishAuthorizedOperation(first)
        for _ in 0..<100 where !recorder.resumeGate.isWaiting {
            await Task.yield()
        }
        #expect(recorder.calls.map(\.isolated) == [true, false])

        let second = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: "resume-race-client",
            displayIdentity: "Resume Race Client",
            capabilities: [.desktopControl]
        )
        var secondPrepared = false
        let secondPrepare = Task { @MainActor in
            try await store.prepareAuthorizedOperation(second)
            secondPrepared = true
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(!secondPrepared)
        #expect(recorder.calls.map(\.isolated) == [true, false])

        recorder.resumeGate.succeed()
        for _ in 0..<100 where !recorder.pauseGate.isWaiting {
            await Task.yield()
        }
        #expect(recorder.calls.map(\.isolated) == [true, false, true])
        #expect(!secondPrepared)
        recorder.pauseGate.succeed()
        try await secondPrepare.value
        #expect(secondPrepared)
        recorder.blocksResume = false
        store.finishAuthorizedOperation(second)
    }

    @Test @MainActor
    func observeOnlyAuthorizationDoesNotPauseHumanClipboard() throws {
        let target = RemoteSession(
            name: "Observe Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            RDPDesktopSessionState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connected,
                runtimeAvailability: .available,
                companion: .unknown,
                stateRevision: 1,
                latestFrameID: nil,
                remotePixelWidth: nil,
                remotePixelHeight: nil,
                connectedAt: Date(),
                reconnectAttempt: nil,
                reconnectMaximumAttempts: nil,
                reconnectScheduledAt: nil,
                lastErrorCode: nil,
                lastErrorMessage: nil
            )
        }
        defer { store.stopAllImmediately() }
        _ = store.installActiveDesktopForTesting(target: target)
        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: "observe-test-client",
            displayIdentity: "Observe Test Client",
            capabilities: [.desktopObserve]
        )
        #expect(!store.isClipboardSuspendedForAIForTesting(targetID: target.targetID))
        store.finishAuthorizedOperation(token)
    }

    @Test @MainActor
    func disabledClipboardDoesNotBlockAIControlOrInvokeIsolation() async throws {
        let recorder = TestClipboardIsolationRecorder()
        let target = RemoteSession(
            name: "Clipboard Disabled Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        try target.setRDPProfile(
            RDPConnectionProfile(clipboardEnabled: false)
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                RDPDesktopSessionState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected,
                    runtimeAvailability: .available,
                    companion: .unknown,
                    stateRevision: 1,
                    latestFrameID: nil,
                    remotePixelWidth: nil,
                    remotePixelHeight: nil,
                    connectedAt: Date(),
                    reconnectAttempt: nil,
                    reconnectMaximumAttempts: nil,
                    reconnectScheduledAt: nil,
                    lastErrorCode: nil,
                    lastErrorMessage: nil
                )
            },
            clipboardIsolationBarrierForTesting: { session, isolated, text in
                try await recorder.execute(
                    session: session,
                    isolated: isolated,
                    text: text
                )
            }
        )
        defer { store.stopAllImmediately() }
        _ = store.installActiveDesktopForTesting(target: target)

        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: "disabled-clipboard-client",
            displayIdentity: "Disabled Clipboard Client",
            capabilities: [.desktopControl]
        )
        #expect(!store.isClipboardSuspendedForAIForTesting(
            targetID: target.targetID
        ))
        try await store.prepareAuthorizedOperation(token)
        #expect(recorder.calls.isEmpty)
        store.finishAuthorizedOperation(token)
        #expect(recorder.calls.isEmpty)
        #expect(!store.isClipboardSuspendedForAIForTesting(
            targetID: target.targetID
        ))
    }

    @Test(arguments: [true, false]) @MainActor
    func closeRequiresAuthorizationButNotClipboardIsolation(authorized: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-close-clipboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = RemoteSession(
            name: "Closing Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        target.mcpEnabled = authorized
        try target.setRDPProfile(RDPConnectionProfile(
            clipboardEnabled: true,
            permissionPolicy: RemoteTargetPermissionPolicy(
                maximumCapabilities: [.desktopControl],
                controlLeaseCapabilities: [],
                requireExternalDataConsent: false
            )
        ))
        let grants = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        var isolationCalls = 0
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { _, _, _ in
                throw WindowsMCPToolError(
                    code: .runtimeFailure, message: "No connection expected."
                )
            },
            grantStoreForTesting: grants,
            clipboardIsolationBarrierForTesting: { _, _, _ in
                isolationCalls += 1
                throw FreeRDPXPCFailure(
                    code: "XPC_NOT_CONNECTED",
                    message: "The FreeRDP XPC helper is not connected."
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let arguments: [String: Any] = [
            "targetId": target.targetID.uuidString,
            "sessionId": sessionID.uuidString,
            "_jtsClientID": "mcp-registration:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        ]

        if authorized {
            let response = try await store.handleMCP(
                tool: .closeDesktop, target: target, arguments: arguments
            )
            #expect(response.structuredContent["closed"] as? Bool == true)
            #expect(store.sessionID(for: target.targetID) == nil)
            #expect(store.state(for: target.targetID)?.phase == .closed)
        } else {
            do {
                _ = try await store.handleMCP(
                    tool: .closeDesktop, target: target, arguments: arguments
                )
                Issue.record("Closing a desktop must still require desktopControl authorization.")
            } catch let failure as WindowsMCPToolError {
                #expect(failure.code == .permissionDenied)
            }
            #expect(store.sessionID(for: target.targetID) == sessionID)
            #expect(store.state(for: target.targetID)?.phase == .connected)
        }
        #expect(isolationCalls == 0)
    }

    @Test @MainActor
    func remoteMutationFailsClosedUntilClipboardIsolationIsAcknowledged() async throws {
        let target = RemoteSession(
            name: "Unprepared Clipboard Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        var dispatchedInputs: [[String: Any]] = []
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                RDPDesktopSessionState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected,
                    runtimeAvailability: .available,
                    companion: .unknown,
                    stateRevision: 1,
                    latestFrameID: nil,
                    remotePixelWidth: nil,
                    remotePixelHeight: nil,
                    connectedAt: Date(),
                    reconnectAttempt: nil,
                    reconnectMaximumAttempts: nil,
                    reconnectScheduledAt: nil,
                    lastErrorCode: nil,
                    lastErrorMessage: nil
                )
            },
            inputExecutorForTesting: { input, _ in
                dispatchedInputs.append(input)
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let frame = try #require(
            store.installDesktopFrameForTesting(
                sessionID: sessionID,
                runtimeStateRevision: 7
            )
        )
        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: "unprepared-clipboard-client",
            displayIdentity: "Unprepared Clipboard Client",
            capabilities: [.desktopControl]
        )
        defer { store.finishAuthorizedOperation(token) }
        let request = DesktopActionRequest(
            action: .typeText,
            expectedStateRevision: frame.stateRevision,
            expectedFrameID: frame.frameID,
            text: "must-not-dispatch"
        )

        do {
            _ = try await store.performDesktopAction(
                sessionID: sessionID,
                request: request
            )
            Issue.record(
                "AI input must not dispatch before clipboard isolation is acknowledged"
            )
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
            #expect(
                failure.details["machineCode"] as? String
                    == "RDP_CLIPBOARD_ISOLATION_PENDING"
            )
        }
        #expect(dispatchedInputs.isEmpty)
    }
}
#endif
