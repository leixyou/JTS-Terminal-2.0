#if ENABLE_RDP_2
import AppKit
import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import JTSTerminal

private func remoteDesktopDescendant(
    of root: NSView,
    identifier: String
) -> NSView? {
    if root.identifier?.rawValue == identifier {
        return root
    }
    for child in root.subviews {
        if let match = remoteDesktopDescendant(of: child, identifier: identifier) {
            return match
        }
    }
    return nil
}

private func remoteDesktopTestMCPRegistration() -> MCPClientRegistrationRecord {
    MCPClientRegistrationRecord(
        registrationID: "22222222-2222-4222-8222-222222222222",
        configurationKey: "/tmp/jts-remote-desktop-tests-mcp.json",
        clientLabel: "RDP Tests",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func installExtendedACL(
    at url: URL,
    inheritable: Bool = false
) throws {
    let flags = inheritable
        ? "allow,file_inherit,directory_inherit"
        : "allow"
    let permissions = inheritable
        ? "read,execute,readattr,readextattr,readsecurity"
        : "read,readattr,readextattr,readsecurity"
    let text = """
    !#acl 1
    group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(flags):\(permissions)

    """
    guard let acl = text.withCString({ acl_from_text($0) }) else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno == 0 ? EINVAL : errno)
        )
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            errno = EINVAL
            return -1
        }
        return acl_set_link_np(path, ACL_TYPE_EXTENDED, acl)
    }
    guard result == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno == 0 ? EIO : errno)
        )
    }
}

private func secureTestFile(at url: URL) throws {
    let descriptor = url.path.withCString {
        Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { _ = Darwin.close(descriptor) }
    try PrivateFileSecurity.securePrivateFileDescriptor(
        descriptor,
        path: url.path
    )
}

@MainActor
private func approvedGrantStore(
    storageURL: URL,
    clientID: String,
    targetID: UUID,
    capabilities: Set<RemoteCapability>,
    policy: RemoteTargetPermissionPolicy,
    at date: Date,
    targetBinding: String? = nil,
    controlRevocationFailureForTesting: (() -> Error?)? = nil
) throws -> (store: RemoteClientGrantStore, grant: RemoteClientGrant) {
    let store = RemoteClientGrantStore(
        storageURL: storageURL,
        controlRevocationFailureForTesting: controlRevocationFailureForTesting
    )
    do {
        _ = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            targetBinding: targetBinding,
            capabilities: capabilities,
            policy: policy,
            at: date
        )
        Issue.record("A new client must not receive authority before visible approval")
    } catch let failure as RemoteGrantGateFailure {
        #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
    }
    let request = try #require(store.pendingRequests(
        targetID: targetID,
        targetBinding: targetBinding
    ).first(where: {
        $0.clientID == clientID
    }))
    let grant = try store.approve(
        requestID: request.id,
        policy: policy,
        consentToExternalData: false,
        currentTargetBinding: targetBinding,
        at: date
    )
    return (store, grant)
}

@MainActor
private func requireGrantRequest(
    store: RemoteClientGrantStore,
    clientID: String,
    targetID: UUID,
    capabilities: Set<RemoteCapability>,
    externalDataTypes: Set<RemoteExternalDataType>,
    policy: RemoteTargetPermissionPolicy,
    at date: Date,
    expectedDenialCode: String,
    targetBinding: String? = nil
) throws -> RemoteGrantRequest {
    do {
        _ = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            targetBinding: targetBinding,
            capabilities: capabilities,
            policy: policy,
            externalDataTypes: externalDataTypes,
            at: date
        )
        Issue.record("Authorization must wait for visible approval.")
    } catch let failure as RemoteGrantGateFailure {
        #expect(failure.denialCode == expectedDenialCode)
        #expect(failure.pendingRequestID != nil)
    }
    return try #require(store.pendingRequests(
        targetID: targetID,
        targetBinding: targetBinding
    ).first(where: {
        $0.clientID == clientID
    }))
}

@MainActor
private final class BinaryTransferManagerBox {
    var value: WindowsCompanionBinaryTransferManager?
}

nonisolated private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

@MainActor
private final class ControlledResizeInputExecutor {
    private(set) var invocationCount = 0
    private var secondAttemptStarted = false
    private var secondAttemptStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondAttemptResume: CheckedContinuation<Void, Never>?

    func execute(_ input: [String: Any], deadlineMilliseconds: Int?) async throws {
        invocationCount += 1
        #expect(input["type"] as? String == "resize")
        #expect(deadlineMilliseconds == nil)

        switch invocationCount {
        case 1:
            throw resizeFailure("Initial resize failed.", code: 1)
        case 2:
            secondAttemptStarted = true
            let waiters = secondAttemptStartWaiters
            secondAttemptStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                secondAttemptResume = continuation
            }
        case 3:
            throw resizeFailure("Newer resize failed.", code: 2)
        default:
            return
        }
    }

    func waitUntilSecondAttemptStarts() async {
        guard !secondAttemptStarted else { return }
        await withCheckedContinuation { continuation in
            secondAttemptStartWaiters.append(continuation)
        }
    }

    func resumeSecondAttempt() {
        secondAttemptResume?.resume()
        secondAttemptResume = nil
    }

    private func resizeFailure(_ message: String, code: Int) -> NSError {
        NSError(
            domain: "RDPDesktopRuntimeStoreResizeTests",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@MainActor
private final class AttemptTransitionInputExecutor {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resume: CheckedContinuation<Void, Never>?

    func execute(_ input: [String: Any], deadlineMilliseconds: Int?) async throws {
        #expect(input["type"] as? String == "resize")
        #expect(deadlineMilliseconds == nil)
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            resume = continuation
        }
        throw NSError(
            domain: "RDPDesktopAttemptTransitionTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The old resize completed after reconnect."]
        )
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func failOldAttempt() {
        resume?.resume()
        resume = nil
    }
}

@MainActor
private final class ControlledTrustedReopenConnector {
    private(set) var configuration: [String: Any]?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var replyContinuation: CheckedContinuation<Void, Never>?

    func connect(configuration: [String: Any]) async throws {
        self.configuration = configuration
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            replyContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard configuration == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func replySuccessfully() {
        replyContinuation?.resume()
        replyContinuation = nil
    }
}

@Suite(.serialized)
@MainActor
struct RemoteDesktopCoreTests {
    @Test func rdpWorkspaceIdleCopyReportsReadyInsteadOfRuntimeFailure() {
        #expect(RDPDesktopWorkspaceIdleContent.statusTitle(language: .english) == "Ready to connect")
        #expect(RDPDesktopWorkspaceIdleContent.surfaceTitle(language: .english) == "Ready to Connect")
        #expect(RDPDesktopWorkspaceIdleContent.detail(language: .english).contains("has not connected yet"))

        #expect(RDPDesktopWorkspaceIdleContent.statusTitle(language: .simplifiedChinese) == "准备连接")
        #expect(RDPDesktopWorkspaceIdleContent.surfaceTitle(language: .simplifiedChinese) == "准备连接")
        #expect(RDPDesktopWorkspaceIdleContent.detail(language: .simplifiedChinese).contains("尚未连接"))
    }

    @Test func rdpWorkspaceConnectionPolicySelectsTheCertificateRecoveryAction() {
        #expect(
            RDPDesktopWorkspaceConnectionPolicy.action(
                phase: .awaitingCertificateTrust,
                hasCertificateChallenge: true
            ) == .none
        )
        #expect(
            RDPDesktopWorkspaceConnectionPolicy.action(
                phase: .awaitingCertificateTrust,
                hasCertificateChallenge: false
            ) == .reloadCertificateDetails
        )
        #expect(
            RDPDesktopWorkspaceConnectionPolicy.action(
                phase: .failed,
                hasCertificateChallenge: false
            ) == .connect
        )
        #expect(
            RDPDesktopWorkspaceConnectionPolicy.action(
                phase: nil,
                hasCertificateChallenge: false
            ) == .connect
        )
        #expect(
            RDPDesktopWorkspaceConnectionPolicy.action(
                phase: .closed,
                hasCertificateChallenge: false
            ) == .connect
        )
        for inProgressPhase in [
            RDPConnectionPhase.connecting,
            .authenticating,
            .reconnecting,
            .connected,
        ] {
            #expect(
                RDPDesktopWorkspaceConnectionPolicy.action(
                    phase: inProgressPhase,
                    hasCertificateChallenge: false
                ) == .none
            )
        }
    }

    @Test func rdpCertificateHostMismatchWarningNamesTheDecisionRisk() {
        let english = RDPDesktopCertificateWarningContent.hostMismatchDetail(
            host: "rdp.example.test",
            language: .english
        )
        #expect(english.contains("does not match rdp.example.test"))
        #expect(english.contains("before trusting"))

        let chinese = RDPDesktopCertificateWarningContent.hostMismatchDetail(
            host: "rdp.example.test",
            language: .simplifiedChinese
        )
        #expect(chinese.contains("与 rdp.example.test 不匹配"))
        #expect(chinese.contains("信任前"))
    }

    @Test func rdpCertificatePreviousFingerprintCopyDistinguishesPinFromTrustOnce() {
        let fingerprint = String(repeating: "A", count: 64)
        let pinned = RDPDesktopCertificateWarningContent.previousFingerprintDetail(
            fingerprint: fingerprint,
            isPinned: true,
            language: .english
        )
        let trustOnce = RDPDesktopCertificateWarningContent.previousFingerprintDetail(
            fingerprint: fingerprint,
            isPinned: false,
            language: .english
        )

        #expect(pinned.hasPrefix("Pinned fingerprint:"))
        #expect(trustOnce.hasPrefix("Previously trusted fingerprint:"))
        #expect(!trustOnce.contains("Pinned fingerprint:"))
    }

    @Test func changedCertificateWithoutPreviousFingerprintBlocksTrustActions() {
        let disposition = RDPDesktopCertificateDecisionPolicy.disposition(
            changed: true,
            oldSHA256: nil
        )

        #expect(
            disposition == .blockedChangedCertificate(previousSHA256: nil)
        )
        #expect(
            RDPDesktopCertificateWarningContent
                .changedCertificateBlockingDetail(language: .english)
                .contains("Trust Once and Verify and Pin are disabled")
        )
    }

    @Test func pinnedMismatchBlocksTrustActionsEvenIfChangedFlagIsFalse() {
        let fingerprint = String(repeating: "A", count: 64)

        #expect(
            RDPDesktopCertificateDecisionPolicy.disposition(
                changed: false,
                pinnedMismatch: true,
                oldSHA256: fingerprint
            ) == .blockedChangedCertificate(previousSHA256: fingerprint)
        )
    }

    @Test func runtimeCanonicalizesPinnedMismatchAndRejectsTheTrustDecision() async {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        store.receiveDesktopCertificateForTesting(
            sessionID: sessionID,
            certificate: [
                "host": target.host,
                "port": target.port,
                "commonName": target.host,
                "subject": "CN=windows.test",
                "issuer": "CN=Test CA",
                "sha256": String(repeating: "B", count: 64),
                "oldSha256": String(repeating: "A", count: 64),
                "changed": false,
                "hostMismatch": false,
                "pinnedMismatch": true,
            ]
        )

        #expect(store.presentation(for: target).certificateChallenge?.changed == true)
        await #expect(throws: WindowsMCPToolError.self) {
            try await store.trustCertificate(targetID: target.targetID, persistPin: false)
        }
        #expect(store.sessionID(for: target.targetID) == sessionID)
        #expect(store.state(for: target.targetID)?.phase == .awaitingCertificateTrust)
    }

    @Test func trustedReopenFailureCleansUpAndPublishesARetryableSurface() async {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connecting
                )
            },
            connectionPasswordProviderForTesting: { _, _ in "test-password" },
            trustedReopenConnectorForTesting: { _ in
                throw FreeRDPXPCFailure(
                    code: "RDP_XPC_START_FAILED",
                    message: "The RDP helper could not start."
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        store.receiveDesktopCertificateForTesting(
            sessionID: sessionID,
            certificate: [
                "host": target.host,
                "port": target.port,
                "commonName": target.host,
                "subject": "CN=windows.test",
                "issuer": "CN=Test CA",
                "sha256": String(repeating: "C", count: 64),
                "oldSha256": "",
                "changed": false,
                "hostMismatch": false,
                "pinnedMismatch": false,
            ]
        )

        await #expect(throws: WindowsMCPToolError.self) {
            try await store.trustCertificate(targetID: target.targetID, persistPin: false)
        }

        #expect(store.sessionID(for: target.targetID) == nil)
        #expect(store.presentation(for: target).certificateChallenge == nil)
        #expect(store.state(for: target.targetID)?.phase == .failed)
        #expect(store.state(for: target.targetID)?.lastErrorCode == "RDP_XPC_START_FAILED")
        #expect(store.presentation(for: target).connect != nil)
    }

    @Test func trustedReopenLateReplyCannotDestroyTheReconnectAttemptCreatedByInvalidation() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let connector = ControlledTrustedReopenConnector()
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connecting
                )
            },
            connectionPasswordProviderForTesting: { _, _ in "test-password" },
            trustedReopenConnectorForTesting: { configuration in
                try await connector.connect(configuration: configuration)
            }
        )
        defer { store.stopAllImmediately() }
        let certificateSessionID = store.installActiveDesktopForTesting(target: target)
        store.receiveDesktopCertificateForTesting(
            sessionID: certificateSessionID,
            certificate: [
                "host": target.host,
                "port": target.port,
                "commonName": target.host,
                "subject": "CN=windows.test",
                "issuer": "CN=Test CA",
                "sha256": String(repeating: "D", count: 64),
                "oldSha256": "",
                "changed": false,
                "hostMismatch": false,
                "pinnedMismatch": false,
            ]
        )

        let trustTask = Task { @MainActor in
            try await store.trustCertificate(
                targetID: target.targetID,
                persistPin: false
            )
        }
        defer {
            connector.replySuccessfully()
            trustTask.cancel()
        }
        await connector.waitUntilStarted()

        let trustedSessionID = try #require(store.sessionID(for: target.targetID))
        #expect(trustedSessionID != certificateSessionID)
        let trustedAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: trustedSessionID)
        )
        #expect(
            connector.configuration?["connectionAttemptId"] as? String
                == trustedAttemptID.uuidString.lowercased()
        )
        #expect(connector.configuration?["clipboardEnabled"] as? Bool == true)

        // The XPC loss wins the race: it retires trusted attempt A and owns
        // the pending B reconnect before A's connector reply is delivered.
        store.invalidateDesktopConnectionForTesting(
            sessionID: trustedSessionID,
            connectionAttemptID: trustedAttemptID
        )
        let reconnectAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: trustedSessionID)
        )
        let scheduledState = try #require(store.state(for: target.targetID))
        #expect(reconnectAttemptID != trustedAttemptID)
        #expect(scheduledState.phase == .reconnecting)
        #expect(scheduledState.reconnectScheduledAt != nil)

        connector.replySuccessfully()
        try await trustTask.value

        #expect(store.sessionID(for: target.targetID) == trustedSessionID)
        #expect(store.connectionAttemptIDForTesting(sessionID: trustedSessionID) == reconnectAttemptID)
        #expect(store.state(for: target.targetID) == scheduledState)
    }

    @Test func unchangedCertificateOffersTrustActionsWithOrWithoutPreviousFingerprint() {
        #expect(
            RDPDesktopCertificateDecisionPolicy.disposition(
                changed: false,
                oldSHA256: nil
            ) == .actionsAvailable
        )
        #expect(
            RDPDesktopCertificateDecisionPolicy.disposition(
                changed: false,
                oldSHA256: String(repeating: "A", count: 64)
            ) == .actionsAvailable
        )
    }

    @Test func certificateDecisionFailureCopyNeverHidesAnEmptyError() {
        let detail = RDPDesktopCertificateWarningContent.decisionFailureDetail(
            errorDescription: "  \n",
            language: .english
        )

        #expect(detail.contains("could not be applied"))
        #expect(detail.contains("remains blocked"))
    }

    @Test func atomicAwaitingStatePublishesCompleteCertificateRecoveryPresentation() {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let certificate = Self.certificateStateFixture(sessionID: sessionID)

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .awaitingCertificateTrust,
            code: "RDP_CERTIFICATE_UNTRUSTED",
            message: "Review the server certificate.",
            certificate: certificate
        )

        let presentation = store.presentation(for: target)
        #expect(presentation.state?.phase == .awaitingCertificateTrust)
        #expect(
            presentation.certificateChallenge == RDPCertificateChallenge(
                host: "rdp.example.test",
                port: 3_389,
                commonName: "rdp.example.test",
                subject: "CN=rdp.example.test",
                issuer: "CN=Test CA",
                sha256: String(repeating: "A", count: 64),
                oldSHA256: nil,
                changed: false,
                hostMismatch: false,
                pinnedMismatch: false
            )
        )
        #expect(presentation.trustCertificateOnce != nil)
        #expect(presentation.pinCertificate != nil)
    }

    @Test func awaitingCertificateTrustDiscardsTheStaleFrameAndNeverDispatchesXPCInput() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        var dispatchedInputs: [[String: Any]] = []
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
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
        let action = DesktopActionRequest(
            action: .typeText,
            expectedStateRevision: frame.stateRevision,
            expectedFrameID: frame.frameID,
            text: "safe-before-certificate-transition"
        )

        _ = try await store.performDesktopAction(sessionID: sessionID, request: action)
        #expect(dispatchedInputs.count == 1)

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .awaitingCertificateTrust,
            code: "RDP_CERTIFICATE_UNTRUSTED",
            message: "Review the server certificate.",
            certificate: Self.certificateStateFixture(sessionID: sessionID),
            stateRevision: frame.stateRevision + 1
        )

        let awaitingState = try #require(store.state(for: target.targetID))
        #expect(awaitingState.phase == .awaitingCertificateTrust)
        #expect(awaitingState.latestFrameID == nil)
        #expect(awaitingState.remotePixelWidth == nil)
        #expect(awaitingState.remotePixelHeight == nil)
        do {
            _ = try await store.performDesktopAction(sessionID: sessionID, request: action)
            Issue.record("Certificate review must block stale-frame desktop input")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
        }
        do {
            _ = try await store.observeDesktop(sessionID: sessionID)
            Issue.record("Certificate review must block stale XPC frame copies")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
        }
        #expect(dispatchedInputs.count == 1)
    }

    @Test func reconnectTransitionDiscardsTheStaleFrameAndNeverDispatchesXPCInput() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        var dispatchedInputCount = 0
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            inputExecutorForTesting: { _, _ in
                dispatchedInputCount += 1
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let frame = try #require(
            store.installDesktopFrameForTesting(sessionID: sessionID)
        )
        let action = DesktopActionRequest(
            action: .keyDown,
            expectedStateRevision: frame.stateRevision,
            expectedFrameID: frame.frameID,
            key: "TAB"
        )

        let retiredAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
        )
        store.invalidateDesktopConnectionForTesting(
            sessionID: sessionID,
            connectionAttemptID: retiredAttemptID
        )

        let reconnectingState = try #require(store.state(for: target.targetID))
        #expect(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
                != retiredAttemptID
        )
        #expect(reconnectingState.phase == .reconnecting)
        #expect(reconnectingState.latestFrameID == nil)
        #expect(reconnectingState.remotePixelWidth == nil)
        #expect(reconnectingState.remotePixelHeight == nil)
        do {
            _ = try await store.performDesktopAction(sessionID: sessionID, request: action)
            Issue.record("Reconnect must block stale-frame desktop input")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
        }
        #expect(dispatchedInputCount == 0)

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            stateRevision: frame.stateRevision + 2
        )
        let reconnectedFrame = try #require(
            store.installDesktopFrameForTesting(
                sessionID: sessionID,
                runtimeStateRevision: frame.stateRevision + 3
            )
        )
        let reconnectedAction = DesktopActionRequest(
            action: .keyDown,
            expectedStateRevision: reconnectedFrame.stateRevision,
            expectedFrameID: reconnectedFrame.frameID,
            key: "TAB"
        )
        _ = try await store.performDesktopAction(
            sessionID: sessionID,
            request: reconnectedAction
        )
        #expect(dispatchedInputCount == 1)
    }

    @Test func injectedHelperReconnectStateCannotRetireTheCurrentAttemptOrFrame() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let frame = try #require(
            store.installDesktopFrameForTesting(sessionID: sessionID)
        )
        let attemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
        )
        let stateBeforeInjection = try #require(store.state(for: target.targetID))

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .reconnecting,
            code: "RDP_CONNECTION_LOST",
            message: "An injected helper transition must be ignored.",
            stateRevision: frame.stateRevision + 1,
            connectionAttemptID: attemptID
        )

        #expect(store.connectionAttemptIDForTesting(sessionID: sessionID) == attemptID)
        #expect(store.state(for: target.targetID) == stateBeforeInjection)
        #expect(store.state(for: target.targetID)?.latestFrameID == frame.frameID)
    }

    @Test func reusedRuntimeRevisionCannotCarryOldAttemptActionsIntoTheReconnectedDesktop() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        var dispatchedInputs: [[String: Any]] = []
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            inputExecutorForTesting: { input, _ in
                dispatchedInputs.append(input)
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let oldFrame = try #require(
            store.installDesktopFrameForTesting(
                sessionID: sessionID,
                runtimeStateRevision: 4
            )
        )
        let oldKey = DesktopActionRequest(
            action: .keyDown,
            expectedStateRevision: oldFrame.stateRevision,
            expectedFrameID: oldFrame.frameID,
            key: "TAB"
        )
        let oldText = DesktopActionRequest(
            action: .typeText,
            expectedStateRevision: oldFrame.stateRevision,
            expectedFrameID: oldFrame.frameID,
            text: "must-not-cross-attempts"
        )
        let oldSemantic = DesktopActionRequest(
            action: .semanticInvoke,
            expectedStateRevision: oldFrame.stateRevision,
            selector: #"{"processId":42,"automationId":"confirm"}"#
        )

        let retiredAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
        )
        store.invalidateDesktopConnectionForTesting(
            sessionID: sessionID,
            connectionAttemptID: retiredAttemptID
        )
        #expect(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
                != retiredAttemptID
        )
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            stateRevision: 3
        )
        let newFrame = try #require(
            store.installDesktopFrameForTesting(
                sessionID: sessionID,
                runtimeStateRevision: 4
            )
        )

        #expect(oldFrame.stateRevision == 4)
        #expect(newFrame.stateRevision != oldFrame.stateRevision)
        for request in [oldKey, oldText, oldSemantic] {
            do {
                _ = try await store.performDesktopAction(
                    sessionID: sessionID,
                    request: request
                )
                Issue.record("An old-attempt desktop action must remain rejected after reconnect")
            } catch let failure as WindowsMCPToolError {
                #expect(failure.code == .stateConflict)
            }
        }
        do {
            _ = try await store.performManualDesktopActionForTesting(
                sessionID: sessionID,
                request: oldKey
            )
            Issue.record("An old manual key event must remain rejected after reconnect")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
        }
        #expect(dispatchedInputs.isEmpty)

        let currentKey = DesktopActionRequest(
            action: .keyDown,
            expectedStateRevision: newFrame.stateRevision,
            expectedFrameID: newFrame.frameID,
            key: "TAB"
        )
        _ = try await store.performDesktopAction(
            sessionID: sessionID,
            request: currentKey
        )
        #expect(dispatchedInputs.count == 1)
        #expect(dispatchedInputs.first?["expectedStateRevision"] as? UInt64 == 4)
    }

    @Test func cachedFramebufferRemainsTheActionTokenAfterNonFrameStateAdvances() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        var dispatchedInputs: [[String: Any]] = []
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            inputExecutorForTesting: { input, _ in
                dispatchedInputs.append(input)
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)

        // Companion/DVC state can arrive before the first framebuffer. The
        // older runtime frame is still valid, but receives a fresh public token
        // so the published session revision never collides or moves backward.
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            stateRevision: 5
        )
        let frame = try #require(
            store.installDesktopFrameForTesting(
                sessionID: sessionID,
                runtimeStateRevision: 4
            )
        )
        #expect(frame.stateRevision > 5)
        #expect(store.state(for: target.targetID)?.stateRevision == frame.stateRevision)
        #expect(store.state(for: target.targetID)?.latestFrameID == frame.frameID)

        // A later connected-state notification reports Companion availability,
        // not a new coordinate space. Status must keep the frame ID/revision
        // pair that both local and MCP input can actually use.
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            stateRevision: 6
        )
        let status = try #require(store.state(for: target.targetID))
        #expect(status.stateRevision == frame.stateRevision)
        #expect(status.latestFrameID == frame.frameID)

        let manualKey = DesktopActionRequest(
            action: .keyDown,
            expectedStateRevision: status.stateRevision,
            expectedFrameID: status.latestFrameID,
            key: "TAB"
        )
        _ = try await store.performManualDesktopActionForTesting(
            sessionID: sessionID,
            request: manualKey
        )
        let mcpKey = DesktopActionRequest(
            action: .keyDown,
            expectedStateRevision: frame.stateRevision,
            expectedFrameID: frame.frameID,
            key: "TAB"
        )
        _ = try await store.performDesktopAction(
            sessionID: sessionID,
            request: mcpKey
        )

        #expect(dispatchedInputs.count == 2)
        #expect(dispatchedInputs.allSatisfy {
            $0["expectedStateRevision"] as? UInt64 == 4
        })
    }

    @Test func frameRevisionMappingsStayBoundedAndRejectOlderDisplayedFrames() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)

        for revision in UInt64(1)...UInt64(2_000) {
            #expect(store.installDesktopFrameForTesting(
                sessionID: sessionID,
                runtimeStateRevision: revision
            ) != nil)
        }
        let retained = try #require(
            store.retainedFrameRevisionMappingCountForTesting(sessionID: sessionID)
        )
        #expect(retained <= 1_536)
        #expect(retained >= 1_024)
        #expect(store.installDesktopFrameForTesting(
            sessionID: sessionID,
            runtimeStateRevision: 1_999
        ) == nil)
    }

    @Test func aStateCallbackTrailingANewerFrameStillUpdatesCompanionDVCState() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            companionMissingGracePeriodForTesting: .milliseconds(20)
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let frame = try #require(store.installDesktopFrameForTesting(
            sessionID: sessionID,
            runtimeStateRevision: 6
        ))
        store.setCompanionAvailabilityForTesting(
            sessionID: sessionID,
            availability: .ready
        )

        // Helper callbacks can be delivered out of order across the paint and
        // DVC threads. A frame does not supersede the DVC lifecycle state.
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            companionDVCConnected: false,
            companionDVCGeneration: 2,
            stateRevision: 5
        )
        let closedDVCState = try #require(store.state(for: target.targetID))
        #expect(closedDVCState.companion.availability == .unknown)
        #expect(store.hasCompanionMissingTaskForTesting(sessionID: sessionID))
        #expect(closedDVCState.latestFrameID == frame.frameID)
        #expect(closedDVCState.stateRevision == frame.stateRevision)

        // Await the exact delayed transition instead of polling a wall-clock
        // timeout. The full Swift Testing bundle runs many MainActor tests in
        // parallel, but scheduler contention must not make this state-machine
        // assertion flaky.
        let missingTask = try #require(
            store.companionMissingTaskForTesting(sessionID: sessionID)
        )
        await missingTask.value
        #expect(store.state(for: target.targetID)?.companion.availability == .missing)
        #expect(!store.hasCompanionMissingTaskForTesting(sessionID: sessionID))

        // State callbacks still remain monotonic relative to other state
        // callbacks even when frames have advanced farther ahead.
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            companionDVCConnected: true,
            companionDVCGeneration: 3,
            stateRevision: 4
        )
        #expect(store.state(for: target.targetID)?.companion.availability == .missing)
        #expect(!store.hasCompanionHandshakeTaskForTesting(sessionID: sessionID))
    }

    @Test func anOutOfOrderSurfaceFrameIsSilentlyDiscarded() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let currentFrame = try #require(store.installDesktopFrameForTesting(
            sessionID: sessionID,
            runtimeStateRevision: 6
        ))

        store.receiveDesktopFramePixelsForTesting(
            sessionID: sessionID,
            runtimeStateRevision: 5
        )

        let state = try #require(store.state(for: target.targetID))
        #expect(state.latestFrameID == currentFrame.frameID)
        #expect(state.stateRevision == currentFrame.stateRevision)
        #expect(state.lastErrorCode == nil)
        #expect(state.lastErrorMessage == nil)
    }

    @Test func queuedSurfaceFromTheRetiredAttemptCannotBecomeAReconnectedFrame() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let retiredAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
        )

        store.invalidateDesktopConnectionForTesting(
            sessionID: sessionID,
            connectionAttemptID: retiredAttemptID
        )
        let currentAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
        )
        #expect(currentAttemptID != retiredAttemptID)
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            stateRevision: 1,
            connectionAttemptID: currentAttemptID
        )

        store.receiveDesktopFramePixelsForTesting(
            sessionID: sessionID,
            runtimeStateRevision: 1,
            connectionAttemptID: retiredAttemptID
        )
        #expect(store.state(for: target.targetID)?.latestFrameID == nil)

        let currentFrameID = UUID()
        store.receiveDesktopFramePixelsForTesting(
            sessionID: sessionID,
            runtimeStateRevision: 1,
            frameID: currentFrameID,
            connectionAttemptID: currentAttemptID
        )
        #expect(store.state(for: target.targetID)?.latestFrameID == currentFrameID)
    }

    @Test func initialConnectCompletionCannotOverrideTheReconnectAttemptCreatedByInvalidation() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false
        )
        let initialAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
        )

        // The XPC invalidation callback retires A, publishes a pending
        // reconnect, and installs B before A's awaited connect returns.
        store.invalidateDesktopConnectionForTesting(
            sessionID: sessionID,
            connectionAttemptID: initialAttemptID
        )
        let reconnectAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
        )
        let scheduledState = try #require(store.state(for: target.targetID))
        #expect(reconnectAttemptID != initialAttemptID)
        #expect(scheduledState.phase == .reconnecting)
        #expect(scheduledState.reconnectAttempt == 1)
        #expect(scheduledState.reconnectScheduledAt != nil)

        // Both a late success reply and the failure used to resume A's await
        // resolve to B's already-published state. Neither completion owns B.
        let lateInitialCompletion = try #require(
            store.stateForSupersededOpenAttemptForTesting(
                sessionID: sessionID,
                expectedConnectionAttemptID: initialAttemptID
            )
        )
        #expect(lateInitialCompletion == scheduledState)
        #expect(store.connectionAttemptIDForTesting(sessionID: sessionID) == reconnectAttemptID)
        #expect(store.state(for: target.targetID) == scheduledState)
    }

    @Test func companionDVCCloseRevokesReadyStateAndAReopenStartsAHandshake() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            companionMissingGracePeriodForTesting: .milliseconds(50)
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        store.setCompanionAvailabilityForTesting(
            sessionID: sessionID,
            availability: .ready
        )

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            companionDVCConnected: false,
            companionDVCGeneration: 2,
            stateRevision: 1
        )
        #expect(store.state(for: target.targetID)?.companion.availability == .unknown)
        #expect(store.hasCompanionMissingTaskForTesting(sessionID: sessionID))
        #expect(!store.hasCompanionHandshakeTaskForTesting(sessionID: sessionID))

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            companionDVCConnected: true,
            companionDVCGeneration: 3,
            stateRevision: 2
        )
        #expect(!store.hasCompanionMissingTaskForTesting(sessionID: sessionID))
        #expect(store.hasCompanionHandshakeTaskForTesting(sessionID: sessionID))

        // A transient DVC close that recovers inside the grace period must not
        // flash the install prompt before the replacement channel handshakes.
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.state(for: target.targetID)?.companion.availability != .missing)
    }

    @Test func companionDVCGenerationRolloverReplacesTheLocalChannelLifecycle() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            companionDVCConnected: true,
            companionDVCGeneration: 7,
            stateRevision: 1
        )
        let firstChannelID = try #require(
            store.companionChannelIDForTesting(sessionID: sessionID)
        )
        #expect(store.companionDVCGenerationForTesting(sessionID: sessionID) == 7)

        store.setCompanionAvailabilityForTesting(
            sessionID: sessionID,
            availability: .ready
        )
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            companionDVCConnected: true,
            companionDVCGeneration: 9,
            stateRevision: 2
        )

        let replacementChannelID = try #require(
            store.companionChannelIDForTesting(sessionID: sessionID)
        )
        #expect(replacementChannelID != firstChannelID)
        #expect(store.companionDVCGenerationForTesting(sessionID: sessionID) == 9)
        #expect(store.state(for: target.targetID)?.companion.availability == .unknown)
        #expect(store.hasCompanionHandshakeTaskForTesting(sessionID: sessionID))
    }

    @Test func reconnectTransitionTearsDownCompanionStateAndHandshake() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            companionDVCConnected: true,
            companionDVCGeneration: 1,
            stateRevision: 1
        )
        #expect(store.hasCompanionHandshakeTaskForTesting(sessionID: sessionID))
        store.setCompanionAvailabilityForTesting(
            sessionID: sessionID,
            availability: .ready
        )

        store.invalidateDesktopConnectionForTesting(sessionID: sessionID)

        #expect(store.state(for: target.targetID)?.phase == .reconnecting)
        #expect(store.state(for: target.targetID)?.companion.availability == .unknown)
        #expect(!store.hasCompanionHandshakeTaskForTesting(sessionID: sessionID))
    }

    @Test func staleResizeFailureCannotPolluteAReconnectedDesktop() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let executor = AttemptTransitionInputExecutor()
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            inputExecutorForTesting: { input, deadlineMilliseconds in
                try await executor.execute(
                    input,
                    deadlineMilliseconds: deadlineMilliseconds
                )
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        _ = try #require(store.installDesktopFrameForTesting(
            sessionID: sessionID,
            runtimeStateRevision: 1
        ))

        let resizeTask = Task { @MainActor in
            await store.resizeDesktop(targetID: target.targetID, width: 1_600, height: 900)
        }
        await executor.waitUntilStarted()
        store.invalidateDesktopConnectionForTesting(sessionID: sessionID)
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            stateRevision: 1
        )
        let newFrame = try #require(store.installDesktopFrameForTesting(
            sessionID: sessionID,
            runtimeStateRevision: 2
        ))
        executor.failOldAttempt()
        await resizeTask.value

        let current = try #require(store.state(for: target.targetID))
        #expect(current.phase == .connected)
        #expect(current.latestFrameID == newFrame.frameID)
        #expect(current.lastErrorCode == nil)
        #expect(current.lastErrorMessage == nil)
    }

    @Test func failedStateCannotReplaceAnAtomicCertificateChallenge() {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let certificate = Self.certificateStateFixture(sessionID: sessionID)

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .awaitingCertificateTrust,
            code: "RDP_CERTIFICATE_UNTRUSTED",
            message: "Review the server certificate.",
            certificate: certificate
        )
        let awaitingPresentation = store.presentation(for: target)

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .failed,
            code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
            message: "A later helper failure arrived."
        )

        let failedPresentation = store.presentation(for: target)
        #expect(failedPresentation.state?.phase == .awaitingCertificateTrust)
        #expect(failedPresentation.state?.lastErrorCode == "RDP_CERTIFICATE_UNTRUSTED")
        #expect(
            failedPresentation.state?.lastErrorMessage
                == "Review the server certificate."
        )
        #expect(failedPresentation.certificateChallenge == awaitingPresentation.certificateChallenge)
        #expect(failedPresentation.trustCertificateOnce != nil)
        #expect(failedPresentation.pinCertificate != nil)
    }

    @Test func duplicateLegacyCertificateCallbackPreservesAtomicStateMessage() {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let certificate = Self.certificateStateFixture(sessionID: sessionID)
        let preciseMessage = "Verify the presented certificate for this exact connection attempt."

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .awaitingCertificateTrust,
            code: "RDP_CERTIFICATE_UNTRUSTED",
            message: preciseMessage,
            certificate: certificate
        )
        let atomicPresentation = store.presentation(for: target)

        store.receiveDesktopCertificateForTesting(
            sessionID: sessionID,
            certificate: certificate
        )

        let duplicatePresentation = store.presentation(for: target)
        #expect(duplicatePresentation.state?.phase == .awaitingCertificateTrust)
        #expect(duplicatePresentation.state?.lastErrorCode == "RDP_CERTIFICATE_UNTRUSTED")
        #expect(duplicatePresentation.state?.lastErrorMessage == preciseMessage)
        #expect(duplicatePresentation.certificateChallenge == atomicPresentation.certificateChallenge)
    }

    @Test func rdpFailureSurfaceAcceptsOnlySanitizedMachineErrorCodes() {
        #expect(
            RDPDesktopWorkspaceFailureContent.sanitizedMachineErrorCode(
                "ERRCONNECT_CONNECT_TRANSPORT_FAILED"
            ) == "ERRCONNECT_CONNECT_TRANSPORT_FAILED"
        )
        #expect(
            RDPDesktopWorkspaceFailureContent.sanitizedMachineErrorCode(
                "  RDP_XPC_REQUEST_TIMEOUT\n"
            ) == "RDP_XPC_REQUEST_TIMEOUT"
        )
        #expect(RDPDesktopWorkspaceFailureContent.sanitizedMachineErrorCode("rodster") == nil)
        #expect(RDPDesktopWorkspaceFailureContent.sanitizedMachineErrorCode("198.51.100.24") == nil)
        #expect(
            RDPDesktopWorkspaceFailureContent.sanitizedMachineErrorCode(
                "ERRCONNECT_CONNECT_FAILED: reviewer@198.51.100.24"
            ) == nil
        )
        #expect(
            RDPDesktopWorkspaceFailureContent.sanitizedMachineErrorCode(
                "ERRCONNECT_CONNECT_FAILED\npassword=secret"
            ) == nil
        )
        #expect(
            RDPDesktopWorkspaceFailureContent.sanitizedMachineErrorCode(
                "SOME_ARBITRARY_DETAIL"
            ) == nil
        )
        #expect(
            RDPDesktopWorkspaceFailureContent.sanitizedMachineErrorCode(
                "RDP_" + String(repeating: "A", count: 100)
            ) == nil
        )
    }

    @Test func rdpFailureSurfaceMachineCodeIsLocalizedAndFailureScoped() {
        var state = RDPDesktopSessionState(
            sessionID: UUID(),
            targetID: UUID(),
            phase: .failed,
            runtimeAvailability: .available,
            companion: .unknown,
            stateRevision: 1,
            latestFrameID: nil,
            remotePixelWidth: nil,
            remotePixelHeight: nil,
            connectedAt: nil,
            reconnectAttempt: nil,
            reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil,
            lastErrorCode: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
            lastErrorMessage: "The connection failed."
        )

        #expect(
            RDPDesktopWorkspaceFailureContent.machineErrorCode(for: state)
                == "ERRCONNECT_CONNECT_TRANSPORT_FAILED"
        )
        #expect(
            RDPDesktopWorkspaceFailureContent.errorCodeTitle(language: .english)
                == "Technical error code"
        )
        #expect(
            RDPDesktopWorkspaceFailureContent.errorCodeTitle(language: .simplifiedChinese)
                == "技术错误码"
        )
        #expect(
            RDPDesktopWorkspaceFailureContent.errorCodeAccessibilityLabel(language: .english)
                == "RDP connection error code"
        )
        #expect(
            RDPDesktopWorkspaceFailureContent.errorCodeAccessibilityLabel(language: .simplifiedChinese)
                == "RDP 连接错误码"
        )

        state.phase = .reconnecting
        #expect(RDPDesktopWorkspaceFailureContent.machineErrorCode(for: state) == nil)
    }

    @Test func rdpWorkspacePresentationNamesViewingAndControllingAIClients() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let grantStore = RemoteClientGrantStore(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("grants.json")
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connecting
                )
            },
            grantStoreForTesting: grantStore
        )
        defer { store.stopAllImmediately() }
        let codex = remoteDesktopTestMCPRegistration()
        let claude = MCPClientRegistrationRecord(
            registrationID: "33333333-3333-4333-8333-333333333333",
            configurationKey: "/tmp/jts-remote-desktop-tests-claude.json",
            clientLabel: "Claude Desktop",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        store.markAIViewing(
            targetID: target.targetID,
            clientID: codex.authorizationClientID,
            displayIdentity: codex.displayIdentity
        )
        store.markAIViewing(
            targetID: target.targetID,
            clientID: claude.authorizationClientID,
            displayIdentity: claude.displayIdentity
        )
        store.markAIViewing(
            targetID: target.targetID,
            clientID: codex.authorizationClientID,
            displayIdentity: codex.displayIdentity
        )

        var presentation = store.presentation(for: target)
        #expect(presentation.isAIViewing)
        #expect(!presentation.isAIControlActive)
        #expect(presentation.activeAIClientIdentities.map(\.displayIdentity) == [
            "Claude Desktop · …33333333",
            "RDP Tests · …22222222",
        ])
        #expect(presentation.activeAIClientIdentities.map(\.authorizationID) == [
            claude.authorizationClientID,
            codex.authorizationClientID,
        ])
        #expect(presentation.activeAIClientIdentities.allSatisfy { !$0.isControlling })

        let controlOperation = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: codex.authorizationClientID,
            displayIdentity: codex.displayIdentity,
            capabilities: [.desktopControl]
        )
        presentation = store.presentation(for: target)
        #expect(presentation.isAIControlActive)
        #expect(presentation.activeAIClientIdentities.map(\.displayIdentity) == [
            "RDP Tests · …22222222",
            "Claude Desktop · …33333333",
        ])
        #expect(presentation.activeAIClientIdentities.map(\.authorizationID) == [
            codex.authorizationClientID,
            claude.authorizationClientID,
        ])
        #expect(presentation.activeAIClientIdentities.map(\.isControlling) == [true, false])

        store.takeManualControl(targetID: target.targetID)
        presentation = store.presentation(for: target)
        #expect(!presentation.isAIViewing)
        #expect(!presentation.isAIControlActive)
        #expect(presentation.isAIControlStopping)
        #expect(presentation.activeAIClientIdentities.map(\.authorizationID) == [
            codex.authorizationClientID
        ])
        #expect(throws: WindowsMCPToolError.self) {
            try store.requireAuthorizedOperation(controlOperation)
        }
        store.finishAuthorizedOperation(controlOperation)
        #expect(store.presentation(for: target).activeAIClientIdentities.isEmpty)
    }

    @Test func successfulResizeClearsOnlyThePublishedTransientInputFailure() async {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        var resizeAttempts = 0
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            inputExecutorForTesting: { input, deadlineMilliseconds in
                resizeAttempts += 1
                #expect(input["type"] as? String == "resize")
                #expect(input["width"] as? Int == 1_920)
                #expect(input["height"] as? Int == 1_080)
                #expect(deadlineMilliseconds == nil)
                if resizeAttempts == 1 {
                    throw NSError(
                        domain: "RDPDesktopRuntimeStoreResizeTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Display Control rejected resize."]
                    )
                }
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)

        await store.resizeDesktop(targetID: target.targetID, width: 1_920, height: 1_080)
        #expect(store.state(for: target.targetID)?.lastErrorCode == "RDP_INPUT_FAILED")

        await store.resizeDesktop(targetID: target.targetID, width: 1_920, height: 1_080)
        #expect(store.state(for: target.targetID)?.lastErrorCode == nil)
        #expect(store.state(for: target.targetID)?.lastErrorMessage == nil)

        store.setPublishedDesktopErrorForTesting(
            sessionID: sessionID,
            code: "RDP_CONNECTION_LOST",
            message: "The RDP transport closed unexpectedly."
        )
        await store.resizeDesktop(targetID: target.targetID, width: 1_920, height: 1_080)
        #expect(store.state(for: target.targetID)?.lastErrorCode == "RDP_CONNECTION_LOST")
        #expect(
            store.state(for: target.targetID)?.lastErrorMessage
                == "The RDP transport closed unexpectedly."
        )
    }

    @Test func displayControlResizeFailureKeepsItsMachineCodeAndDisablesAdaptiveResolution() async {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        var shouldFail = true
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            inputExecutorForTesting: { _, _ in
                if shouldFail {
                    shouldFail = false
                    throw FreeRDPXPCFailure(
                        code: "DISPLAY_CONTROL_UNAVAILABLE",
                        message: "The server does not expose the Display Control channel."
                    )
                }
            }
        )
        defer { store.stopAllImmediately() }
        _ = store.installActiveDesktopForTesting(target: target)

        await store.resizeDesktop(targetID: target.targetID, width: 1_920, height: 1_080)
        let failedState = store.state(for: target.targetID)
        #expect(failedState?.lastErrorCode == "RDP_DISPLAY_CONTROL_UNAVAILABLE")
        let visibleFailure = RDPDesktopWorkspaceInputFailurePolicy.visibleFailure(
            phase: failedState?.phase,
            code: failedState?.lastErrorCode,
            message: failedState?.lastErrorMessage
        )
        #expect(visibleFailure?.disablesAdaptiveResolution == true)
        #expect(visibleFailure?.message.contains("Display Control") == true)

        await store.resizeDesktop(targetID: target.targetID, width: 1_920, height: 1_080)
        #expect(store.state(for: target.targetID)?.lastErrorCode == nil)
        #expect(store.state(for: target.targetID)?.lastErrorMessage == nil)
    }

    @Test func earlierResizeSuccessCannotClearANewerPublishedInputFailure() async {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let executor = ControlledResizeInputExecutor()
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            inputExecutorForTesting: { input, deadlineMilliseconds in
                try await executor.execute(
                    input,
                    deadlineMilliseconds: deadlineMilliseconds
                )
            }
        )
        defer {
            executor.resumeSecondAttempt()
            store.stopAllImmediately()
        }
        _ = store.installActiveDesktopForTesting(target: target)

        await store.resizeDesktop(targetID: target.targetID, width: 1_920, height: 1_080)
        #expect(store.state(for: target.targetID)?.lastErrorCode == "RDP_INPUT_FAILED")

        let earlierSuccess = Task { @MainActor in
            await store.resizeDesktop(
                targetID: target.targetID,
                width: 1_920,
                height: 1_080
            )
        }
        await executor.waitUntilSecondAttemptStarts()

        await store.resizeDesktop(targetID: target.targetID, width: 1_920, height: 1_080)
        #expect(
            store.state(for: target.targetID)?.lastErrorMessage?.contains("Newer resize failed.")
                == true
        )

        executor.resumeSecondAttempt()
        await earlierSuccess.value
        #expect(store.state(for: target.targetID)?.lastErrorCode == "RDP_INPUT_FAILED")
        #expect(
            store.state(for: target.targetID)?.lastErrorMessage?.contains("Newer resize failed.")
                == true
        )

        await store.resizeDesktop(targetID: target.targetID, width: 1_920, height: 1_080)
        #expect(store.state(for: target.targetID)?.lastErrorCode == nil)
        #expect(executor.invocationCount == 4)
    }

    @Test func aiViewingActivityExpiresAndARefreshSupersedesTheOldTask() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        let client = remoteDesktopTestMCPRegistration()

        let referenceDate = Date()
        store.markAIViewing(
            targetID: target.targetID,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            observedAt: referenceDate,
            activityWindow: 0.05
        )
        try await Task.sleep(for: .milliseconds(10))
        store.markAIViewing(
            targetID: target.targetID,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            observedAt: referenceDate.addingTimeInterval(3_600),
            activityWindow: 0
        )

        // Wait beyond the first expiry. The refreshed activity remains valid
        // without depending on a narrow wall-clock scheduling window.
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.presentation(for: target).isAIViewing)

        store.markAIViewing(
            targetID: target.targetID,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            observedAt: .distantPast,
            activityWindow: 0
        )
        await Task.yield()
        let expiredPresentation = store.presentation(for: target)
        #expect(!expiredPresentation.isAIViewing)
        #expect(expiredPresentation.activeAIClientIdentities.isEmpty)
    }

    @Test func persistentControlOperationsUseAPerTargetClientMutex() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        store.register(target: target)
        let firstClient = remoteDesktopTestMCPRegistration()
        let secondClient = MCPClientRegistrationRecord(
            registrationID: "33333333-3333-4333-8333-333333333333",
            configurationKey: "/tmp/jts-remote-desktop-tests-second-client.json",
            clientLabel: "Second RDP Client",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let firstOperation = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: firstClient.authorizationClientID,
            displayIdentity: firstClient.displayIdentity,
            capabilities: [.desktopControl]
        )
        let sameClientOperation = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: firstClient.authorizationClientID,
            displayIdentity: firstClient.displayIdentity,
            capabilities: [.commandExecution]
        )
        var presentation = store.presentation(for: target)
        #expect(presentation.isAIControlActive)
        #expect(presentation.activeAIClientIdentities.map(\.authorizationID) == [
            firstClient.authorizationClientID
        ])
        #expect(presentation.activeAIClientIdentities.map(\.isControlling) == [true])

        do {
            _ = try store.beginAuthorizedOperation(
                targetID: target.targetID,
                targetBinding: target.mcpGrantTargetBinding,
                clientID: secondClient.authorizationClientID,
                displayIdentity: secondClient.displayIdentity,
                capabilities: [.structuredTasks]
            )
            Issue.record("A second client must not control the target concurrently")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
            #expect(
                failure.details["authorizationCode"] as? String
                    == "AI_CONTROL_OPERATION_CONFLICT"
            )
        }

        store.finishAuthorizedOperation(firstOperation)
        store.finishAuthorizedOperation(sameClientOperation)
        let secondOperation = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: secondClient.authorizationClientID,
            displayIdentity: secondClient.displayIdentity,
            capabilities: [.structuredTasks]
        )
        presentation = store.presentation(for: target)
        #expect(presentation.isAIControlActive)
        #expect(presentation.activeAIClientIdentities.map(\.authorizationID) == [
            secondClient.authorizationClientID
        ])
        store.finishAuthorizedOperation(secondOperation)
        #expect(!store.presentation(for: target).isAIControlActive)
    }

    @Test func stoppingControlOperationBlocksAllClientsUntilDrainCompletes() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        store.register(target: target)
        let firstClient = remoteDesktopTestMCPRegistration()
        let secondClient = MCPClientRegistrationRecord(
            registrationID: "33333333-3333-4333-8333-333333333333",
            configurationKey: "/tmp/jts-remote-desktop-tests-second-client.json",
            clientLabel: "Second RDP Client",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let retainedOperation = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: firstClient.authorizationClientID,
            displayIdentity: firstClient.displayIdentity,
            capabilities: [.desktopControl]
        )
        store.revokeAuthorizedOperations(targetID: target.targetID)
        #expect(store.presentation(for: target).isAIControlStopping)

        for client in [firstClient, secondClient] {
            do {
                _ = try store.beginAuthorizedOperation(
                    targetID: target.targetID,
                    targetBinding: target.mcpGrantTargetBinding,
                    clientID: client.authorizationClientID,
                    displayIdentity: client.displayIdentity,
                    capabilities: [.commandExecution]
                )
                Issue.record("A stopping operation must drain before any client can resume control")
            } catch let failure as WindowsMCPToolError {
                #expect(failure.code == .permissionDenied)
                #expect(
                    failure.details["authorizationCode"] as? String
                        == "AI_CONTROL_OPERATION_CONFLICT"
                )
            }
        }

        store.finishAuthorizedOperation(retainedOperation)
        let resumedOperation = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: firstClient.authorizationClientID,
            displayIdentity: firstClient.displayIdentity,
            capabilities: [.commandExecution]
        )
        try store.requireAuthorizedOperation(resumedOperation)
        store.finishAuthorizedOperation(resumedOperation)
    }

    @Test func authorizedOperationGenerationRejectsDispatchAfterManualRevocation() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        store.register(target: target)
        let client = remoteDesktopTestMCPRegistration()
        var cancellationCount = 0
        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.commandExecution]
        )
        store.attachAuthorizedOperationCancellation(token) {
            cancellationCount += 1
        }

        try store.requireAuthorizedOperation(token)
        store.revokeAuthorizedOperations(targetID: target.targetID)

        #expect(cancellationCount == 1)
        do {
            try store.requireAuthorizedOperation(token)
            Issue.record("A revoked operation token must fail before remote dispatch")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
            #expect(
                failure.details["authorizationCode"] as? String
                    == "AUTHORITY_REVOKED_DURING_OPERATION"
            )
        }
        store.finishAuthorizedOperation(token)
    }

    @Test func connectionTransitionCancelsSessionWorkButPreservesManagementCalls() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        store.register(target: target)
        let client = remoteDesktopTestMCPRegistration()
        var managementCancellationCount = 0
        var sessionCancellationCount = 0
        let management = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.discovery],
            survivesConnectionTransition: true
        )
        let sessionBound = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.desktopObserve]
        )
        store.attachAuthorizedOperationCancellation(management) {
            managementCancellationCount += 1
        }
        store.attachAuthorizedOperationCancellation(sessionBound) {
            sessionCancellationCount += 1
        }

        store.revokeConnectionBoundAuthorizedOperations(targetID: target.targetID)

        #expect(managementCancellationCount == 0)
        #expect(sessionCancellationCount == 1)
        try store.requireAuthorizedOperation(management)
        #expect(throws: WindowsMCPToolError.self) {
            try store.requireAuthorizedOperation(sessionBound)
        }

        store.revokeAuthorizedOperations(targetID: target.targetID)
        #expect(managementCancellationCount == 1)
        #expect(throws: WindowsMCPToolError.self) {
            try store.requireAuthorizedOperation(management)
        }
        store.finishAuthorizedOperation(management)
        store.finishAuthorizedOperation(sessionBound)
    }

    @Test func inFlightPersistentControlKeepsInterruptionControlsVisible() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        store.register(target: target)
        let client = remoteDesktopTestMCPRegistration()

        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.structuredTasks]
        )

        var presentation = store.presentation(for: target)
        #expect(presentation.isAIControlActive)
        #expect(presentation.activeAIClientIdentities.map(\.authorizationID) == [
            client.authorizationClientID
        ])
        #expect(presentation.activeAIClientIdentities.map(\.isControlling) == [true])
        #expect(RDPDesktopWorkspaceControlPolicy.showsAIInterruptionControls(
            isAIViewing: presentation.isAIViewing,
            isAIControlActive: presentation.isAIControlActive
        ))

        store.finishAuthorizedOperation(token)
        presentation = store.presentation(for: target)
        #expect(!presentation.isAIControlActive)
        #expect(presentation.activeAIClientIdentities.isEmpty)
    }

    @Test func manualStopCancelsRuntimeWorkButPreservesPersistentGrant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-manual-stop-persistent-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let client = remoteDesktopTestMCPRegistration()
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.commandExecution],
            controlLeaseCapabilities: [],
            requireExternalDataConsent: false
        )
        let approvedAt = Date(timeIntervalSince1970: 60_000)
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.commandExecution],
            policy: policy,
            at: approvedAt,
            targetBinding: target.mcpGrantTargetBinding
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connecting
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }
        store.register(target: target)

        var cancellationCount = 0
        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.commandExecution]
        )
        store.attachAuthorizedOperationCancellation(token) {
            cancellationCount += 1
        }

        store.takeManualControl(targetID: target.targetID)

        #expect(cancellationCount == 1)
        #expect(!store.presentation(for: target).isAIControlActive)
        #expect(store.presentation(for: target).isAIControlStopping)
        do {
            try store.requireAuthorizedOperation(token)
            Issue.record("Manual takeover must invalidate the in-flight generation immediately")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
        }
        store.finishAuthorizedOperation(token)
        #expect(!store.presentation(for: target).isAIControlStopping)

        let authorization = try approved.store.authorize(
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            capabilities: [.commandExecution],
            policy: policy,
            at: approvedAt.addingTimeInterval(365 * 24 * 60 * 60)
        )
        #expect(authorization.controlLeaseExpiresAt == nil)
        #expect(approved.store.pendingRequests(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding
        ).isEmpty)

        let nextOperation = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.commandExecution]
        )
        try store.requireAuthorizedOperation(nextOperation)
        store.finishAuthorizedOperation(nextOperation)
    }

    @Test func nonRetryableDisconnectCancelsRuntimeControlButPreservesPersistentGrant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-disconnect-control-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let client = remoteDesktopTestMCPRegistration()
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopControl],
            controlLeaseCapabilities: [],
            requireExternalDataConsent: false
        )
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let approved = try approvedGrantStore(
            storageURL: directory.appendingPathComponent("grants.json"),
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(),
            targetBinding: target.mcpGrantTargetBinding
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)

        var cancellationCount = 0
        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.desktopControl]
        )
        store.attachAuthorizedOperationCancellation(token) {
            cancellationCount += 1
        }

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .failed,
            code: "ERRCONNECT_LOGON_FAILURE",
            message: "The Windows session rejected the logon."
        )

        #expect(cancellationCount == 1)
        #expect(!store.presentation(for: target).isAIControlActive)
        #expect(store.presentation(for: target).isAIControlStopping)
        #expect(store.state(for: target.targetID)?.phase == .failed)
        do {
            try store.requireAuthorizedOperation(token)
            Issue.record("A non-retryable disconnect must cancel in-flight AI authority")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
        }
        let authorization = try approved.store.authorize(
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date().addingTimeInterval(365 * 24 * 60 * 60)
        )
        #expect(authorization.controlLeaseExpiresAt == nil)
        #expect(approved.store.pendingRequests(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding
        ).isEmpty)
        store.finishAuthorizedOperation(token)
        #expect(!store.presentation(for: target).isAIControlStopping)
    }

    @Test func closedAndCancelledOpenPathsCancelWorkWithoutRevokingPersistentGrant() throws {
        let terminalCases: [(phase: RDPConnectionPhase, code: String)] = [
            (.closed, "RDP_LOGOFF_BY_USER"),
            (.connecting, "RDP_OPEN_CANCELLED"),
        ]

        for terminalCase in terminalCases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("jts-terminal-control-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = RemoteSession(
                name: "Windows",
                host: "windows.test",
                username: "operator",
                connectionType: .rdp
            )
            let client = remoteDesktopTestMCPRegistration()
            let policy = RemoteTargetPermissionPolicy(
                maximumCapabilities: [.desktopControl],
                controlLeaseCapabilities: [],
                requireExternalDataConsent: false
            )
            try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
            let approved = try approvedGrantStore(
                storageURL: directory.appendingPathComponent("grants.json"),
                clientID: client.authorizationClientID,
                targetID: target.targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(),
                targetBinding: target.mcpGrantTargetBinding
            )
            let store = RDPDesktopRuntimeStore(
                openOperationExecutorForTesting: { target, _, _ in
                    Self.desktopState(
                        sessionID: UUID(),
                        targetID: target.targetID,
                        phase: terminalCase.phase
                    )
                },
                grantStoreForTesting: approved.store
            )
            let sessionID = store.installActiveDesktopForTesting(
                target: target,
                phase: terminalCase.phase,
                hasConnectedOnce: terminalCase.phase == .closed
            )
            var cancellationCount = 0
            let token = try store.beginAuthorizedOperation(
                targetID: target.targetID,
                targetBinding: target.mcpGrantTargetBinding,
                clientID: client.authorizationClientID,
                displayIdentity: client.displayIdentity,
                capabilities: [.desktopControl]
            )
            store.attachAuthorizedOperationCancellation(token) {
                cancellationCount += 1
            }

            if terminalCase.phase == .closed {
                store.receiveDesktopStateForTesting(
                    sessionID: sessionID,
                    phase: .closed,
                    code: terminalCase.code,
                    message: "The Windows user logged off."
                )
            } else {
                store.invalidateOpenDesktopForTesting(sessionID: sessionID)
            }

            #expect(cancellationCount == 1)
            #expect(!store.presentation(for: target).isAIControlActive)
            #expect(throws: WindowsMCPToolError.self) {
                try store.requireAuthorizedOperation(token)
            }
            #expect(
                try approved.store.authorize(
                    clientID: client.authorizationClientID,
                    targetID: target.targetID,
                    targetBinding: target.mcpGrantTargetBinding,
                    capabilities: [.desktopControl],
                    policy: policy,
                    at: Date().addingTimeInterval(365 * 24 * 60 * 60)
                ).controlLeaseExpiresAt == nil
            )
            #expect(approved.store.pendingRequests(
                targetID: target.targetID,
                targetBinding: target.mcpGrantTargetBinding
            ).isEmpty)
            store.finishAuthorizedOperation(token)
            store.stopAllImmediately()
        }
    }

    @Test func duplicateConnectionLossCallbacksCancelRuntimeWorkOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-duplicate-loss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let client = remoteDesktopTestMCPRegistration()
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopControl],
            controlLeaseCapabilities: [],
            requireExternalDataConsent: false
        )
        let revocationCounter = LockedInvocationCounter()
        let approved = try approvedGrantStore(
            storageURL: directory.appendingPathComponent("grants.json"),
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(),
            targetBinding: target.mcpGrantTargetBinding,
            controlRevocationFailureForTesting: {
                revocationCounter.increment()
                return nil
            }
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let cancellationCounter = LockedInvocationCounter()
        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.desktopControl]
        )
        store.attachAuthorizedOperationCancellation(token) {
            cancellationCounter.increment()
        }

        let failedAttemptID = try #require(
            store.connectionAttemptIDForTesting(sessionID: sessionID)
        )
        store.invalidateDesktopConnectionForTesting(
            sessionID: sessionID,
            connectionAttemptID: failedAttemptID
        )
        store.invalidateDesktopConnectionForTesting(
            sessionID: sessionID,
            connectionAttemptID: failedAttemptID
        )
        store.revokeAuthorizedOperations(targetID: target.targetID)

        #expect(revocationCounter.value == 0)
        #expect(cancellationCounter.value == 1)
        #expect(
            try approved.store.authorize(
                clientID: client.authorizationClientID,
                targetID: target.targetID,
                targetBinding: target.mcpGrantTargetBinding,
                capabilities: [.desktopControl],
                policy: policy
            ).controlLeaseExpiresAt == nil
        )
    }

    @Test func nonMonotonicConnectedStateCannotReopenAFailedSession() {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore { target, _, _ in
            Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connected
            )
        }
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)

        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .failed,
            code: "ERRCONNECT_LOGON_FAILURE",
            message: "The Windows session rejected the logon.",
            stateRevision: 2
        )
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            stateRevision: 2
        )
        store.receiveDesktopStateForTesting(
            sessionID: sessionID,
            phase: .connected,
            stateRevision: 1
        )

        #expect(store.state(for: target.targetID)?.phase == .failed)
        #expect(store.state(for: target.targetID)?.stateRevision == 2)
    }

    @Test func staleDesktopLossCannotCancelAReopenedSessionsFreshControl() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-stale-desktop-loss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let client = remoteDesktopTestMCPRegistration()
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopControl],
            controlLeaseCapabilities: [],
            requireExternalDataConsent: false
        )
        let approved = try approvedGrantStore(
            storageURL: directory.appendingPathComponent("grants.json"),
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(),
            targetBinding: target.mcpGrantTargetBinding
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }
        let staleSessionID = store.installActiveDesktopForTesting(target: target)
        var staleCancellationCount = 0
        let staleToken = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.desktopControl]
        )
        store.attachAuthorizedOperationCancellation(staleToken) {
            staleCancellationCount += 1
        }
        store.receiveDesktopStateForTesting(
            sessionID: staleSessionID,
            phase: .failed,
            code: "ERRCONNECT_LOGON_FAILURE",
            message: "The old Windows session ended."
        )
        #expect(staleCancellationCount == 1)
        #expect(throws: WindowsMCPToolError.self) {
            try store.requireAuthorizedOperation(staleToken)
        }
        store.finishAuthorizedOperation(staleToken)
        #expect(
            try approved.store.authorize(
                clientID: client.authorizationClientID,
                targetID: target.targetID,
                targetBinding: target.mcpGrantTargetBinding,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date().addingTimeInterval(365 * 24 * 60 * 60)
            ).controlLeaseExpiresAt == nil
        )
        #expect(approved.store.pendingRequests(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding
        ).isEmpty)

        let currentSessionID = store.installActiveDesktopForTesting(target: target)
        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.desktopControl]
        )

        store.receiveDesktopStateForTesting(
            sessionID: staleSessionID,
            phase: .closed,
            code: "RDP_SESSION_CLOSED",
            message: "A late callback arrived from the replaced desktop."
        )

        #expect(store.sessionID(for: target.targetID) == currentSessionID)
        #expect(store.presentation(for: target).isAIControlActive)
        try store.requireAuthorizedOperation(token)
        store.finishAuthorizedOperation(token)
    }

    @Test func emergencyStopCancelsRuntimeWithoutRevokingPersistentGrant() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-emergency-stop-once-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let client = remoteDesktopTestMCPRegistration()
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopControl],
            controlLeaseCapabilities: [],
            requireExternalDataConsent: false
        )
        let revocationCounter = LockedInvocationCounter()
        let approved = try approvedGrantStore(
            storageURL: directory.appendingPathComponent("grants.json"),
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(),
            targetBinding: target.mcpGrantTargetBinding,
            controlRevocationFailureForTesting: {
                revocationCounter.increment()
                return nil
            }
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }
        _ = store.installActiveDesktopForTesting(target: target)
        var cancellationCount = 0
        let token = try store.beginAuthorizedOperation(
            targetID: target.targetID,
            targetBinding: target.mcpGrantTargetBinding,
            clientID: client.authorizationClientID,
            displayIdentity: client.displayIdentity,
            capabilities: [.desktopControl]
        )
        store.attachAuthorizedOperationCancellation(token) {
            cancellationCount += 1
        }

        await store.emergencyStop(targetID: target.targetID)

        #expect(revocationCounter.value == 0)
        #expect(cancellationCount == 1)
        #expect(!store.presentation(for: target).isAIControlActive)
        #expect(store.sessionID(for: target.targetID) == nil)
        #expect(
            try approved.store.authorize(
                clientID: client.authorizationClientID,
                targetID: target.targetID,
                targetBinding: target.mcpGrantTargetBinding,
                capabilities: [.desktopControl],
                policy: policy
            ).controlLeaseExpiresAt == nil
        )
        store.finishAuthorizedOperation(token)
    }

    @Test func mcpReopenPreservesItsAuthorityWhileCleaningAStaleDesktop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-mcp-stale-reopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let client = remoteDesktopTestMCPRegistration()
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.discovery])
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let approved = try approvedGrantStore(
            storageURL: directory.appendingPathComponent("grants.json"),
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.discovery],
            policy: policy,
            at: Date(),
            targetBinding: target.mcpGrantTargetBinding
        )
        let expectedSessionID = UUID()
        var executionCount = 0
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                executionCount += 1
                return Self.desktopState(
                    sessionID: expectedSessionID,
                    targetID: target.targetID,
                    phase: .awaitingCertificateTrust
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }
        _ = store.installActiveDesktopForTesting(
            target: target,
            phase: .failed,
            hasConnectedOnce: false
        )

        let response = try await store.handleMCP(
            tool: .openDesktop,
            target: target,
            arguments: [
                "_jtsClientID": client.authorizationClientID,
                "_jtsClientDisplayIdentity": client.displayIdentity,
                "deadlineMs": 10_000,
                "idempotencyKey": "reopen-after-stale-desktop",
            ]
        )

        #expect(response.structuredContent["ok"] as? Bool == true)
        #expect(
            response.structuredContent["phase"] as? String
                == RDPConnectionPhase.awaitingCertificateTrust.rawValue
        )
        #expect(
            response.structuredContent["sessionId"] as? String
                == expectedSessionID.uuidString.lowercased()
        )
        #expect(executionCount == 1)
    }

    @Test func companionToolsNeverOpenAnRDPDesktopImplicitly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-companion-requires-open-rdp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let capabilities: Set<RemoteCapability> = [
            .commandExecution,
            .fileAccess,
            .structuredTasks,
        ]
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: capabilities,
            controlLeaseCapabilities: [],
            requireExternalDataConsent: false
        )
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let client = remoteDesktopTestMCPRegistration()
        let approved = try approvedGrantStore(
            storageURL: directory.appendingPathComponent("grants.json"),
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: capabilities,
            policy: policy,
            at: Date(),
            targetBinding: target.mcpGrantTargetBinding
        )
        let openCounter = LockedInvocationCounter()
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                openCounter.increment()
                return Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connecting
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }

        let cases: [(WindowsMCPToolName, [String: Any])] = [
            (.windowsExec, ["command": "Get-Date"]),
            (.windowsFiles, ["operation": "list", "path": "."]),
            (
                .windowsTask,
                [
                    "action": "submit",
                    "jobId": "job-1",
                    "bundleBase64": "not-base64",
                ]
            ),
        ]
        for (tool, toolArguments) in cases {
            var arguments = toolArguments
            arguments["_jtsClientID"] = client.authorizationClientID
            arguments["_jtsClientDisplayIdentity"] = client.displayIdentity
            arguments["sessionId"] = UUID().uuidString.lowercased()
            do {
                _ = try await store.handleMCP(
                    tool: tool,
                    target: target,
                    arguments: arguments
                )
                Issue.record("\(tool.rawValue) must require an already-open RDP desktop")
            } catch let failure as WindowsMCPToolError {
                #expect(failure.code == .stateConflict)
                #expect(
                    failure.details["machineCode"] as? String
                        == "RDP_DESKTOP_NOT_OPEN"
                )
                #expect(failure.details["retryable"] as? Bool == true)
            }
        }

        do {
            _ = try await store.handleMCP(
                tool: .windowsTask,
                target: target,
                arguments: [
                    "_jtsClientID": client.authorizationClientID,
                    "_jtsClientDisplayIdentity": client.displayIdentity,
                    "sessionId": UUID().uuidString.lowercased(),
                    "action": "status",
                    "jobId": " job-1 ",
                ]
            )
            Issue.record("Windows worker job IDs must have an unambiguous canonical form")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .invalidArgument)
            #expect(failure.message.contains("leading or trailing whitespace"))
        }

        #expect(openCounter.value == 0)
        #expect(store.sessionID(for: target) == nil)
    }

    @Test func companionToolsRequireTheVisibleRDPDesktopToBeConnected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-companion-requires-connected-rdp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.commandExecution],
            controlLeaseCapabilities: [],
            requireExternalDataConsent: false
        )
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let client = remoteDesktopTestMCPRegistration()
        let approved = try approvedGrantStore(
            storageURL: directory.appendingPathComponent("grants.json"),
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.commandExecution],
            policy: policy,
            at: Date(),
            targetBinding: target.mcpGrantTargetBinding
        )
        let openCounter = LockedInvocationCounter()
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                openCounter.increment()
                return Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(
            target: target,
            phase: .connecting,
            hasConnectedOnce: false
        )

        do {
            _ = try await store.handleMCP(
                tool: .windowsExec,
                target: target,
                arguments: [
                    "_jtsClientID": client.authorizationClientID,
                    "_jtsClientDisplayIdentity": client.displayIdentity,
                    "sessionId": sessionID.uuidString.lowercased(),
                    "command": "Get-Date",
                ]
            )
            Issue.record("Companion tools must wait for the visible RDP desktop to connect")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
            #expect(
                failure.details["machineCode"] as? String
                    == "RDP_DESKTOP_NOT_CONNECTED"
            )
            #expect(failure.details["phase"] as? String == "connecting")
            #expect(failure.details["retryable"] as? Bool == true)
        }

        #expect(openCounter.value == 0)
        #expect(store.sessionID(for: target) == sessionID)
    }

    @Test func companionToolRejectsInvalidRequestsBeforeClipboardIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-companion-preflight-before-clipboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let capabilities: Set<RemoteCapability> = [
            .commandExecution,
            .structuredTasks,
        ]
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: capabilities,
            controlLeaseCapabilities: [],
            requireExternalDataConsent: false
        )
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let client = remoteDesktopTestMCPRegistration()
        let approved = try approvedGrantStore(
            storageURL: directory.appendingPathComponent("grants.json"),
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: capabilities,
            policy: policy,
            at: Date(),
            targetBinding: target.mcpGrantTargetBinding
        )
        let openCounter = LockedInvocationCounter()
        let clipboardIsolationCounter = LockedInvocationCounter()
        let clipboardResumeCounter = LockedInvocationCounter()
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                openCounter.increment()
                return Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: approved.store,
            clipboardIsolationBarrierForTesting: { _, isolated, _ in
                if isolated {
                    clipboardIsolationCounter.increment()
                } else {
                    clipboardResumeCounter.increment()
                }
            }
        )
        defer { store.stopAllImmediately() }
        let sessionID = store.installActiveDesktopForTesting(target: target)
        let commonArguments: [String: Any] = [
            "_jtsClientID": client.authorizationClientID,
            "_jtsClientDisplayIdentity": client.displayIdentity,
        ]

        do {
            _ = try await store.handleMCP(
                tool: .windowsExec,
                target: target,
                arguments: commonArguments.merging([
                    "sessionId": UUID().uuidString.lowercased(),
                    "command": "Get-Date",
                ]) { _, new in new }
            )
            Issue.record("A stale sessionId must be rejected before clipboard isolation")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
            #expect(
                failure.details["machineCode"] as? String
                    == "RDP_DESKTOP_SESSION_MISMATCH"
            )
        }

        do {
            _ = try await store.handleMCP(
                tool: .windowsExec,
                target: target,
                arguments: commonArguments.merging([
                    "sessionId": sessionID.uuidString.lowercased(),
                    "command": "",
                ]) { _, new in new }
            )
            Issue.record("An invalid command must be rejected before clipboard isolation")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .invalidArgument)
        }

        do {
            _ = try await store.handleMCP(
                tool: .windowsTask,
                target: target,
                arguments: commonArguments.merging([
                    "sessionId": sessionID.uuidString.lowercased(),
                    "action": "submit",
                    "jobId": "job-1",
                    "bundleBase64": "not-base64",
                ]) { _, new in new }
            )
            Issue.record("An invalid task bundle must be rejected before clipboard isolation")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .invalidArgument)
        }

        await Task.yield()
        #expect(clipboardIsolationCounter.value == 0)
        #expect(clipboardResumeCounter.value == 0)
        #expect(openCounter.value == 0)
        #expect(store.sessionID(for: target) == sessionID)

        do {
            _ = try await store.handleMCP(
                tool: .windowsExec,
                target: target,
                arguments: commonArguments.merging([
                    "sessionId": sessionID.uuidString.lowercased(),
                    "command": "Get-Date",
                ]) { _, new in new }
            )
            Issue.record("A connected desktop without Companion must fail explicitly")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .companionRequired)
        }
        #expect(clipboardIsolationCounter.value == 1)
        #expect(await Self.waitUntil(timeout: .seconds(1)) {
            clipboardResumeCounter.value == 1
        })
        #expect(openCounter.value == 0)
    }

    @Test func revokedMCPAwaitReturnsTheStableAuthorityErrorInsteadOfCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-revoked-mcp-await-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let client = remoteDesktopTestMCPRegistration()
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.discovery])
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: client.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.discovery],
            policy: policy,
            at: Date(timeIntervalSince1970: 61_000),
            targetBinding: target.mcpGrantTargetBinding
        )
        var executionStarted = false
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                executionStarted = true
                try await Task.sleep(for: .seconds(30))
                return Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connecting
                )
            },
            grantStoreForTesting: approved.store
        )
        defer { store.stopAllImmediately() }

        let operation = Task { @MainActor in
            try await store.handleMCP(
                tool: .openDesktop,
                target: target,
                arguments: [
                    "_jtsClientID": client.authorizationClientID,
                    "_jtsClientDisplayIdentity": client.displayIdentity,
                    "deadlineMs": 60_000,
                    "idempotencyKey": "revoked-open",
                ]
            )
        }
        while !executionStarted {
            await Task.yield()
        }

        store.takeManualControl(targetID: target.targetID)

        do {
            _ = try await operation.value
            Issue.record("A revoked MCP wait must not report success")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
            #expect(
                failure.details["authorizationCode"] as? String
                    == "AUTHORITY_REVOKED_DURING_OPERATION"
            )
        } catch is CancellationError {
            Issue.record("Revocation must normalize child cancellation into the authority error")
        }
    }

    @Test func aiInterruptionControlsRemainVisibleOutsideConnectedPhase() {
        #expect(RDPDesktopWorkspaceControlPolicy.showsAIInterruptionControls(
            isAIViewing: true,
            isAIControlActive: false
        ))
        #expect(RDPDesktopWorkspaceControlPolicy.showsAIInterruptionControls(
            isAIViewing: false,
            isAIControlActive: true
        ))
        #expect(!RDPDesktopWorkspaceControlPolicy.showsAIInterruptionControls(
            isAIViewing: false,
            isAIControlActive: false
        ))
        #expect(RDPDesktopWorkspaceControlPolicy.showsAIInterruptionControls(
            isAIViewing: false,
            isAIControlActive: false,
            isAIControlStopping: true
        ))
    }

    @Test func desktopControlBarMovesSecondaryActionsWithoutHidingCriticalControls() {
        let wide = RDPDesktopControlBarPolicy.plan(
            layout: .wide,
            isConnected: true,
            shouldOfferConnect: false,
            showsAIInterruptionControls: true,
            showsPendingAIAccessRequest: false
        )
        let narrow = RDPDesktopControlBarPolicy.plan(
            layout: .narrow,
            isConnected: true,
            shouldOfferConnect: false,
            showsAIInterruptionControls: true,
            showsPendingAIAccessRequest: false
        )

        #expect(wide.secondaryPlacement == .inline)
        #expect(narrow.secondaryPlacement == .overflowMenu)
        #expect(wide.secondaryActions == [.companion, .desktopScale, .fullScreen])
        #expect(narrow.secondaryActions == wide.secondaryActions)
        #expect(wide.criticalActions == [
            .takeControl,
            .emergencyStop,
            .disconnect,
        ])
        #expect(narrow.criticalActions == wide.criticalActions)
        #expect(!wide.usesIconOnlyCriticalLabels)
        #expect(!narrow.usesIconOnlyCriticalLabels)
    }

    @Test func desktopControlBarShowsAIAccessOnlyForPendingRequests() {
        let disconnected = RDPDesktopControlBarPolicy.plan(
            layout: .narrow,
            isConnected: false,
            shouldOfferConnect: true,
            showsAIInterruptionControls: false,
            showsPendingAIAccessRequest: false
        )
        #expect(disconnected.secondaryActions == [.companion])
        #expect(disconnected.criticalActions == [.connect])

        let certificateDecisionPending = RDPDesktopControlBarPolicy.plan(
            layout: .narrow,
            isConnected: false,
            shouldOfferConnect: false,
            showsAIInterruptionControls: false,
            showsPendingAIAccessRequest: false
        )
        #expect(certificateDecisionPending.criticalActions.isEmpty)

        let aiAccessPending = RDPDesktopControlBarPolicy.plan(
            layout: .wide,
            isConnected: true,
            shouldOfferConnect: false,
            showsAIInterruptionControls: false,
            showsPendingAIAccessRequest: true
        )
        #expect(aiAccessPending.criticalActions == [.aiAccess, .disconnect])
    }

    @Test func narrowAIClientIdentityBoundsVisibleCopyAndPreservesCompleteAccessibilityData() {
        let exactBoundaryIdentity = String(repeating: "界", count: 128)
        let single = RDPDesktopAIClientIdentityContentPolicy.content(
            identities: [
                RDPActiveAIClientIdentity(
                    authorizationID: "authorization-boundary",
                    displayIdentity: exactBoundaryIdentity
                ),
            ],
            layout: .narrow,
            language: .english
        )

        #expect(single.visibleSummary == exactBoundaryIdentity)
        #expect(single.visibleSummary.count == 128)
        #expect(single.lineLimit == 2)
        #expect(single.accessibilityValue.contains(exactBoundaryIdentity))
        #expect(single.accessibilityValue.contains("authorization-boundary"))

        let longController = String(repeating: "Controller", count: 20)
        let multiple = RDPDesktopAIClientIdentityContentPolicy.content(
            identities: [
                RDPActiveAIClientIdentity(
                    authorizationID: "viewer-one-id",
                    displayIdentity: "Viewer One"
                ),
                RDPActiveAIClientIdentity(
                    authorizationID: "controller-full-id",
                    displayIdentity: longController,
                    isControlling: true
                ),
                RDPActiveAIClientIdentity(
                    authorizationID: "viewer-two-id",
                    displayIdentity: "Viewer Two"
                ),
            ],
            layout: .narrow,
            language: .english
        )

        #expect(multiple.visibleSummary.count <= 128)
        #expect(multiple.visibleSummary.hasPrefix("Control: "))
        #expect(multiple.visibleSummary.hasSuffix(" · +2 more"))
        #expect(multiple.visibleSummary.contains("…"))
        #expect(multiple.lineLimit == 2)
        #expect(multiple.accessibilityValue.contains(longController))
        #expect(multiple.accessibilityValue.contains("controller-full-id"))
        #expect(multiple.accessibilityValue.contains("viewer-one-id"))
        #expect(multiple.accessibilityValue.contains("viewer-two-id"))
        #expect(multiple.help.contains(longController))

        let wide = RDPDesktopAIClientIdentityContentPolicy.content(
            identities: [
                RDPActiveAIClientIdentity(
                    authorizationID: "wide-client-id",
                    displayIdentity: longController,
                    isControlling: true
                ),
            ],
            layout: .wide,
            language: .english
        )
        #expect(wide.visibleSummary.count <= 128)
        #expect(wide.visibleSummary.hasPrefix("Control: "))
        #expect(wide.lineLimit == 1)
        #expect(wide.accessibilityValue.contains(longController))

        let chinese = RDPDesktopAIClientIdentityContentPolicy.content(
            identities: [
                RDPActiveAIClientIdentity(
                    authorizationID: "chinese-controller-id",
                    displayIdentity: String(repeating: "控制端", count: 64),
                    isControlling: true
                ),
            ],
            layout: .narrow,
            language: .simplifiedChinese
        )
        #expect(chinese.visibleSummary.count <= 128)
        #expect(chinese.visibleSummary.hasPrefix("控制："))
        #expect(chinese.accessibilityValue.hasPrefix("控制："))
    }

    @Test func aiActivityAnnouncementsAreStateDrivenAndDeduplicated() {
        #expect(
            RDPDesktopAIActivityState.resolved(
                isViewing: true,
                isControlActive: true,
                isControlStopping: true
            ) == .stopping
        )
        #expect(
            RDPDesktopAIActivityAnnouncementPolicy.announcement(
                previous: nil,
                current: .inactive,
                language: .english
            ) == nil
        )
        #expect(
            RDPDesktopAIActivityAnnouncementPolicy.announcement(
                previous: .inactive,
                current: .viewing,
                language: .english
            ) == "AI started viewing the remote desktop."
        )
        #expect(
            RDPDesktopAIActivityAnnouncementPolicy.announcement(
                previous: .viewing,
                current: .controlling,
                language: .english
            ) == "AI started controlling the remote desktop."
        )
        #expect(
            RDPDesktopAIActivityAnnouncementPolicy.announcement(
                previous: .controlling,
                current: .controlling,
                language: .english
            ) == nil
        )
        #expect(
            RDPDesktopAIActivityAnnouncementPolicy.announcement(
                previous: .controlling,
                current: .stopping,
                language: .simplifiedChinese
            ) == "AI 控制正在停止。"
        )
        #expect(
            RDPDesktopAIActivityAnnouncementPolicy.announcement(
                previous: .stopping,
                current: .inactive,
                language: .simplifiedChinese
            ) == "AI 活动已停止，远程输入现由你控制。"
        )
    }

    @Test func aiAccessButtonContentReportsEnabledStateAndGrantCounts() {
        let english = RemoteGrantManagementButtonContentPolicy.content(
            isMCPEnabled: false,
            activeGrantCount: 2,
            pendingRequestCount: 1,
            language: .english
        )
        #expect(english.title == "AI Access · 1 pending")
        #expect(
            english.accessibilityValue
                == "MCP off. 2 authorized clients. 1 request needing review."
        )
        #expect(english.systemImage == "person.crop.circle.badge.exclamationmark")

        let chinese = RemoteGrantManagementButtonContentPolicy.content(
            isMCPEnabled: true,
            activeGrantCount: 1,
            pendingRequestCount: 0,
            language: .simplifiedChinese
        )
        #expect(chinese.title == "AI 访问 · 已授权 1")
        #expect(chinese.accessibilityValue == "MCP 已开启。已授权客户端 1 个。待确认请求 0 个。")
        #expect(chinese.systemImage == "person.badge.key")

        let off = RemoteGrantManagementButtonContentPolicy.content(
            isMCPEnabled: false,
            activeGrantCount: 0,
            pendingRequestCount: 0,
            language: .english
        )
        #expect(off.title == "AI Access · Off")

        let paused = RemoteGrantManagementButtonContentPolicy.content(
            isMCPEnabled: false,
            activeGrantCount: 2,
            pendingRequestCount: 0,
            language: .simplifiedChinese
        )
        #expect(paused.title == "AI 访问 · 已暂停")
        #expect(paused.accessibilityValue == "MCP 已关闭。已授权客户端 2 个。待确认请求 0 个。")

        let idle = RemoteGrantManagementButtonContentPolicy.content(
            isMCPEnabled: true,
            activeGrantCount: 0,
            pendingRequestCount: 0,
            language: .english
        )
        #expect(idle.title == "AI Access")
    }

    @Test func aiAccessRowsAndActionsExposeStableHostedUIIdentifiers() {
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.managementButton
                == "rdp-ai-access-button"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.pendingEntryButton
                == "rdp-ai-pending-access-button"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.panePicker
                == "rdp-ai-management-pane-picker"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.pendingRequestRow
                == "rdp-ai-pending-request-row"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.alwaysAllowButton
                == "rdp-ai-always-allow-button"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.denyButton
                == "rdp-ai-deny-button"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.activeGrantRow
                == "rdp-ai-active-grant-row"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.emptyAccessState
                == "rdp-ai-empty-access-state"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.grantStoreError
                == "rdp-ai-grant-store-error"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.auditStoreError
                == "rdp-ai-audit-store-error"
        )
        #expect(
            RemoteGrantManagementAccessibilityIdentifier.revokeButton
                == "rdp-ai-revoke-button"
        )
    }

    @Test func aiAccessEmptyStateCentersOnlyWhenAccessHasNoActionableContent() {
        #expect(RemoteGrantManagementLayoutPolicy.centersEmptyAccess(
            pane: .access,
            hasPersistenceError: false,
            pendingRequestCount: 0,
            activeGrantCount: 0
        ))
        #expect(!RemoteGrantManagementLayoutPolicy.centersEmptyAccess(
            pane: .audit,
            hasPersistenceError: false,
            pendingRequestCount: 0,
            activeGrantCount: 0
        ))
        #expect(!RemoteGrantManagementLayoutPolicy.centersEmptyAccess(
            pane: .access,
            hasPersistenceError: true,
            pendingRequestCount: 0,
            activeGrantCount: 0
        ))
        #expect(!RemoteGrantManagementLayoutPolicy.centersEmptyAccess(
            pane: .access,
            hasPersistenceError: false,
            pendingRequestCount: 1,
            activeGrantCount: 0
        ))
        #expect(!RemoteGrantManagementLayoutPolicy.centersEmptyAccess(
            pane: .access,
            hasPersistenceError: false,
            pendingRequestCount: 0,
            activeGrantCount: 1
        ))
    }

    @Test func aiAccessEmptyStateExplainsEnabledMCPCanBeUsedDirectly() {
        let enabled = RemoteGrantManagementContentPolicy.emptyAccessSummary(
            isMCPEnabled: true,
            language: .english
        )
        #expect(enabled.contains("enable MCP"))
        #expect(enabled.contains("directly"))
        #expect(enabled.contains("Audit"))
        #expect(enabled.contains("revoke"))
        #expect(!enabled.localizedCaseInsensitiveContains("lease"))

        let enabledChinese =
            RemoteGrantManagementContentPolicy.emptyAccessSummary(
                isMCPEnabled: true,
                language: .simplifiedChinese
            )
        #expect(enabledChinese.contains("启用 MCP"))
        #expect(enabledChinese.contains("直接使用"))
        #expect(enabledChinese.contains("审计"))
        #expect(enabledChinese.contains("撤销"))

        let disabled = RemoteGrantManagementContentPolicy.emptyAccessSummary(
            isMCPEnabled: false,
            language: .english
        )
        #expect(disabled.contains("MCP is disabled"))
        #expect(disabled.contains("Server Properties"))
    }

    @Test func aiAccessManagementPanesAndTimestampsFollowTheAppLanguage() {
        #expect(
            RemoteGrantManagementPane.access.title(language: .english)
                == "Access"
        )
        #expect(
            RemoteGrantManagementPane.access.title(
                language: .simplifiedChinese
            ) == "访问"
        )
        #expect(
            RemoteGrantManagementPane.audit.title(language: .english)
                == "Audit"
        )
        #expect(
            RemoteGrantManagementPane.audit.title(
                language: .simplifiedChinese
            ) == "审计"
        )

        let reference = Date(timeIntervalSinceReferenceDate: 50_000)
        let earlier = reference.addingTimeInterval(-7_200)
        let english = RemoteGrantTimestampTextPolicy.relative(
            earlier,
            to: reference,
            language: .english
        )
        let chinese = RemoteGrantTimestampTextPolicy.relative(
            earlier,
            to: reference,
            language: .simplifiedChinese
        )
        #expect(english.localizedCaseInsensitiveContains("hour"))
        #expect(chinese.contains("小时"))
        #expect(english != chinese)
        #expect(RemoteGrantAuditTimelinePolicy.refreshInterval > 0)
        #expect(RemoteGrantAuditTimelinePolicy.refreshInterval <= 60)
        #expect(
            RemoteGrantTimestampTextPolicy.relative(
                earlier,
                to: reference.addingTimeInterval(3_600),
                language: .simplifiedChinese
            ) != chinese
        )

        let absoluteDate = Date(timeIntervalSinceReferenceDate: 0)
        let englishAbsolute = RemoteGrantTimestampTextPolicy.dateAndTime(
            absoluteDate,
            language: .english
        )
        let chineseAbsolute = RemoteGrantTimestampTextPolicy.dateAndTime(
            absoluteDate,
            language: .simplifiedChinese
        )
        #expect(englishAbsolute.localizedCaseInsensitiveContains("jan"))
        #expect(chineseAbsolute.contains("年"))
        #expect(!chineseAbsolute.localizedCaseInsensitiveContains("jan"))
    }

    @Test func narrowWindowFixtureRequiresTheCompleteHostedRDPEnvironment() {
        let fixtureID = UUID()
        let targetID = UUID()
        var environment = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestRDPFixtureEnvironment.fixtureIDKey: fixtureID.uuidString,
            UITestRDPFixtureEnvironment.fixtureTargetIDKey: targetID.uuidString,
            UITestRDPFixtureEnvironment.fixtureModeKey:
                UITestRDPFixtureMode.connectedControl.rawValue,
            UITestRDPFixtureEnvironment.narrowWindowKey: "1",
            UITestSSHSessionEnvironment.importedProfileFixtureKey: "fixture",
        ]

        #expect(UITestRDPFixtureEnvironment.requestsNarrowWindow(environment: environment))

        environment[UITestRDPFixtureEnvironment.fixtureTargetIDKey] = nil
        #expect(!UITestRDPFixtureEnvironment.requestsNarrowWindow(environment: environment))

        environment[UITestRDPFixtureEnvironment.fixtureTargetIDKey] = targetID.uuidString
        environment[UITestRDPFixtureEnvironment.narrowWindowKey] = "0"
        #expect(!UITestRDPFixtureEnvironment.requestsNarrowWindow(environment: environment))
    }

    @Test func grantApprovalScopeIsPersistentForSSHAndRDP() {
        let request = RemoteGrantRequest(
            id: UUID(),
            clientID: "registered-client",
            targetID: UUID(),
            requestedCapabilities: [.discovery],
            externalDataTypes: [.targetMetadata],
            reason: .newGrant,
            firstRequestedAt: .distantPast,
            lastRequestedAt: .distantPast
        )

        let ssh = RemoteGrantApprovalScope.resolved(
            request: request,
            connectionType: .ssh,
            policy: .sshDefault
        )
        #expect(ssh.grantsPersistentTargetAccess)
        #expect(ssh.capabilities == RemoteTargetPermissionPolicy.sshDefault.maximumCapabilities)
        #expect(ssh.externalDataTypes == [
            .targetMetadata,
            .commandOutput,
            .terminalOutput,
            .fileMetadata,
            .fileContent,
        ])

        let rdp = RemoteGrantApprovalScope.resolved(
            request: request,
            connectionType: .rdp,
            policy: .rdpDefault
        )
        #expect(rdp.grantsPersistentTargetAccess)
        #expect(rdp.capabilities == RemoteTargetPermissionPolicy.rdpDefault.maximumCapabilities)
        #expect(rdp.externalDataTypes == [
            .targetMetadata,
            .commandOutput,
            .terminalOutput,
            .fileMetadata,
            .fileContent,
            .desktopImage,
            .desktopStructure,
        ])
    }

    @Test func persistentRDPCopyReframesLegacyLeaseRenewalAsServerAccess() {
        let request = RemoteGrantRequest(
            id: UUID(),
            clientID: "registered-rdp-client",
            targetID: UUID(),
            requestedCapabilities: [.desktopControl],
            reason: .controlLeaseRenewal,
            firstRequestedAt: .distantPast,
            lastRequestedAt: .distantPast
        )
        let scope = RemoteGrantApprovalScope.resolved(
            request: request,
            connectionType: .rdp,
            policy: .rdpDefault
        )

        let english = RemoteGrantManagementContentPolicy.requestContent(
            reason: request.reason,
            scope: scope,
            language: .english
        )
        #expect(
            english.reasonSummary
                == "Persistent server access approval required"
        )
        #expect(
            english.persistentAccessSummary
                == "Access to the server account shown above remains until you revoke it."
        )
        #expect(
            english.elevationSummary
                == "Each elevated action still requires separate confirmation on Windows."
        )
        #expect(!english.reasonSummary.localizedCaseInsensitiveContains("temporary"))
        #expect(!english.reasonSummary.localizedCaseInsensitiveContains("renewal"))

        let chinese = RemoteGrantManagementContentPolicy.requestContent(
            reason: request.reason,
            scope: scope,
            language: .simplifiedChinese
        )
        #expect(chinese.reasonSummary == "需要批准长期服务器访问")
        #expect(chinese.persistentAccessSummary == "对上方服务器账号的访问会持续有效，直到你主动撤销。")
        #expect(
            chinese.elevationSummary
                == "每次提权仍需在 Windows 上单独确认。"
        )

        let englishFooter = RemoteGrantManagementContentPolicy.pendingSectionFooter(
            connectionType: .rdp,
            capabilities: scope.capabilities,
            policy: .rdpDefault,
            language: .english
        )
        #expect(
            englishFooter
                == "Access for this registered AI client to the Windows account shown above remains until you revoke it."
        )
        let chineseFooter = RemoteGrantManagementContentPolicy.pendingSectionFooter(
            connectionType: .rdp,
            capabilities: scope.capabilities,
            policy: .rdpDefault,
            language: .simplifiedChinese
        )
        #expect(
            chineseFooter
                == "此已注册 AI 客户端对上方 Windows 账号的访问会持续有效，直到你主动撤销。"
        )
        #expect(
            RemoteGrantManagementContentPolicy.approvalButtonTitle(
                scope: scope,
                language: .english
            ) == "Always Allow & Consent"
        )
        #expect(
            RemoteGrantManagementContentPolicy.approvalButtonTitle(
                scope: scope,
                language: .simplifiedChinese
            ) == "始终允许并同意共享"
        )
        #expect(!englishFooter.localizedCaseInsensitiveContains("elevat"))
        #expect(!chineseFooter.contains("提权"))
    }

    @Test func legacyTemporaryControlCopyRetainsItsRealLeaseState() {
        let leasePolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopControl],
            controlLeaseCapabilities: [.desktopControl],
            controlIdleTimeoutSeconds: 60
        )
        let request = RemoteGrantRequest(
            id: UUID(),
            clientID: "legacy-control-client",
            targetID: UUID(),
            requestedCapabilities: [.desktopControl],
            reason: .controlLeaseRenewal,
            firstRequestedAt: .distantPast,
            lastRequestedAt: .distantPast
        )
        let scope = RemoteGrantApprovalScope.resolved(
            request: request,
            connectionType: .rdp,
            policy: leasePolicy
        )
        let requestContent = RemoteGrantManagementContentPolicy.requestContent(
            reason: request.reason,
            scope: scope,
            language: .english
        )
        #expect(!scope.grantsPersistentTargetAccess)
        #expect(requestContent.reasonSummary == "Temporary control renewal required")
        #expect(requestContent.persistentAccessSummary == nil)
        #expect(requestContent.elevationSummary == nil)
        #expect(
            RemoteGrantManagementContentPolicy.pendingSectionFooter(
                connectionType: .rdp,
                capabilities: scope.capabilities,
                policy: leasePolicy,
                language: .english
            )
                == "Approval applies only to this registered AI client and the server account shown above. Temporary control expires after inactivity."
        )
        #expect(
            RemoteGrantManagementContentPolicy.pendingSectionFooter(
                connectionType: .rdp,
                capabilities: scope.capabilities,
                policy: leasePolicy,
                language: .simplifiedChinese
            )
                == "审批仅适用于此已注册 AI 客户端和上方显示的服务器账号。临时控制会在空闲后到期。"
        )

        let lastUsedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let active = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: [.desktopControl],
            lastUsedAt: lastUsedAt,
            policy: leasePolicy,
            now: lastUsedAt.addingTimeInterval(30),
            language: .english
        )
        #expect(
            active.status
                == .temporaryControl(
                    expiresAt: lastUsedAt.addingTimeInterval(60)
                )
        )
        #expect(active.summary.hasPrefix("Temporary control until "))
        #expect(active.elevationSummary == nil)

        let expired = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: [.desktopControl],
            lastUsedAt: lastUsedAt,
            policy: leasePolicy,
            now: lastUsedAt.addingTimeInterval(61),
            language: .simplifiedChinese
        )
        #expect(expired.status == .expiredTemporaryControl)
        #expect(expired.summary == "临时控制已到期")
        #expect(expired.isExpired)
    }

    @Test func persistentRDPGrantStatusKeepsElevationTaskBound() {
        let content = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: RemoteTargetPermissionPolicy.rdpDefault.maximumCapabilities,
            lastUsedAt: .distantPast,
            policy: .rdpDefault,
            now: .distantFuture,
            language: .english
        )

        #expect(content.status == .persistentExactTarget)
        #expect(content.summary == "Access remains until revoked")
        #expect(
            content.elevationSummary
                == "Each elevated action still requires separate confirmation on Windows."
        )
        #expect(content.systemImage == "infinity")
        #expect(!content.isExpired)
    }

    @Test func disabledMCPShowsSavedGrantAsPausedAndRevocable() {
        let content = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: RemoteTargetPermissionPolicy.rdpDefault
                .maximumCapabilities,
            lastUsedAt: .distantPast,
            policy: .rdpDefault,
            isMCPEnabled: false,
            now: .distantFuture,
            language: .simplifiedChinese
        )

        #expect(content.status == .persistentPaused)
        #expect(content.summary == "授权已保存；MCP 关闭期间访问已暂停")
        #expect(content.systemImage == "pause.circle")
        #expect(content.elevationSummary == nil)
        #expect(!content.isExpired)
    }

    @Test func disabledMCPDoesNotConvertLegacyTemporaryControlToPersistentAccess() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopControl],
            controlLeaseCapabilities: [.desktopControl],
            controlIdleTimeoutSeconds: 900,
            requireExternalDataConsent: false
        )
        let paused = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: [.desktopControl],
            lastUsedAt: now,
            policy: policy,
            isMCPEnabled: false,
            now: now,
            language: .english
        )
        #expect(
            paused.status
                == .temporaryPaused(
                    expiresAt: now.addingTimeInterval(900)
                )
        )
        #expect(paused.summary.contains("Temporary control paused"))

        let expired = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: [.desktopControl],
            lastUsedAt: now.addingTimeInterval(-901),
            policy: policy,
            isMCPEnabled: false,
            now: now,
            language: .english
        )
        #expect(expired.status == .expiredTemporaryControl)
    }

    @Test func disabledRDPElevationDoesNotAppearInPendingOrActiveCopy() {
        let narrowedPolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .desktopObserve, .fileAccess],
            controlLeaseCapabilities: []
        )
        let request = RemoteGrantRequest(
            id: UUID(),
            clientID: "registered-rdp-client",
            targetID: UUID(),
            requestedCapabilities: [.desktopObserve],
            reason: .newGrant,
            firstRequestedAt: .distantPast,
            lastRequestedAt: .distantPast
        )
        let scope = RemoteGrantApprovalScope.resolved(
            request: request,
            connectionType: .rdp,
            policy: narrowedPolicy
        )

        let englishRequest = RemoteGrantManagementContentPolicy.requestContent(
            reason: request.reason,
            scope: scope,
            language: .english
        )
        let chineseRequest = RemoteGrantManagementContentPolicy.requestContent(
            reason: request.reason,
            scope: scope,
            language: .simplifiedChinese
        )
        #expect(englishRequest.elevationSummary == nil)
        #expect(chineseRequest.elevationSummary == nil)

        let previouslyGrantedCapabilities =
            RemoteTargetPermissionPolicy.rdpDefault.maximumCapabilities
        let englishActive = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: previouslyGrantedCapabilities,
            lastUsedAt: .distantPast,
            policy: narrowedPolicy,
            now: .distantFuture,
            language: .english
        )
        let chineseActive = RemoteGrantManagementContentPolicy.activeGrantContent(
            capabilities: previouslyGrantedCapabilities,
            lastUsedAt: .distantPast,
            policy: narrowedPolicy,
            now: .distantFuture,
            language: .simplifiedChinese
        )
        #expect(englishActive.elevationSummary == nil)
        #expect(chineseActive.elevationSummary == nil)

        let englishFooter = RemoteGrantManagementContentPolicy.pendingSectionFooter(
            connectionType: .rdp,
            capabilities: narrowedPolicy.maximumCapabilities,
            policy: narrowedPolicy,
            language: .english
        )
        let chineseFooter = RemoteGrantManagementContentPolicy.pendingSectionFooter(
            connectionType: .rdp,
            capabilities: narrowedPolicy.maximumCapabilities,
            policy: narrowedPolicy,
            language: .simplifiedChinese
        )
        #expect(
            englishFooter
                == "Access for this registered AI client to the Windows account shown above remains until you revoke it."
        )
        #expect(
            chineseFooter
                == "此已注册 AI 客户端对上方 Windows 账号的访问会持续有效，直到你主动撤销。"
        )
        #expect(!englishFooter.localizedCaseInsensitiveContains("elevat"))
        #expect(!chineseFooter.contains("提权"))
    }

    @Test func desktopOpenRequestPlanNormalizesIdentityDimensionsAndAbsoluteDeadline() throws {
        let plan = try DesktopOpenRequestPolicy.plan(
            request: DesktopOpenRequest(
                deadlineMilliseconds: nil,
                deadlineUptimeMilliseconds: 101_500,
                clientID: "  test-client  ",
                idempotencyKey: "  retry-1  ",
                requestedPixelWidth: 20_000,
                requestedPixelHeight: 100
            ),
            profile: RDPConnectionProfile(desktopWidth: 1_920, desktopHeight: 1_080),
            nowUptime: 100
        )
        let expectedDigest = SHA256.hash(data: Data("retry-1".utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(plan.deadlineMilliseconds == 10_000)
        #expect(plan.deadlineUptime == 101.5)
        #expect(plan.remainingMilliseconds(at: 100.75) == 750)
        #expect(plan.remainingMilliseconds(at: 101.5) == 0)
        #expect(plan.idempotencyClientID == "test-client")
        #expect(plan.idempotencyKeyDigest == expectedDigest)
        #expect(plan.signature == DesktopOpenRequestSignature(pixelWidth: 7_680, pixelHeight: 480))
    }

    @Test func desktopOpenRequestPlanRejectsInvalidDeadlineAndIdempotencyKeys() {
        let profile = RDPConnectionProfile()
        #expect(throws: DesktopOpenRequestValidationFailure.invalidDeadline) {
            try DesktopOpenRequestPolicy.plan(
                request: DesktopOpenRequest(deadlineMilliseconds: 99),
                profile: profile,
                nowUptime: 1
            )
        }
        #expect(throws: DesktopOpenRequestValidationFailure.invalidDeadline) {
            try DesktopOpenRequestPolicy.plan(
                request: DesktopOpenRequest(deadlineMilliseconds: 60_001),
                profile: profile,
                nowUptime: 1
            )
        }
        for invalidKey in ["   ", "key\0tail", String(repeating: "x", count: 129)] {
            #expect(throws: DesktopOpenRequestValidationFailure.invalidIdempotencyKey) {
                try DesktopOpenRequestPolicy.plan(
                    request: DesktopOpenRequest(idempotencyKey: invalidKey),
                    profile: profile,
                    nowUptime: 1
                )
            }
        }
    }

    @Test func desktopOpenIdempotencyLedgerReplaysOneOperationAndRejectsPayloadReuse() throws {
        let targetID = UUID()
        let operationID = UUID()
        let scope = DesktopOpenIdempotencyScope(
            targetID: targetID,
            clientID: "client-a",
            keyDigest: "digest-a"
        )
        let signature = DesktopOpenRequestSignature(pixelWidth: 1_920, pixelHeight: 1_080)
        var ledger = DesktopOpenIdempotencyLedger(retentionSeconds: 60, maximumRecords: 8)

        #expect(try ledger.reserve(
            scope: scope,
            signature: signature,
            operationID: operationID,
            nowUptime: 10
        ) == nil)
        #expect(try ledger.lookup(
            scope: scope,
            signature: signature,
            nowUptime: 11
        ) == .pending(operationID: operationID))
        #expect(throws: DesktopOpenIdempotencyConflict(scope: scope)) {
            try ledger.lookup(
                scope: scope,
                signature: DesktopOpenRequestSignature(pixelWidth: 1_280, pixelHeight: 720),
                nowUptime: 11
            )
        }

        var state = Self.desktopState(
            sessionID: UUID(),
            targetID: targetID,
            phase: .connecting
        )
        ledger.complete(operationID: operationID, outcome: .success(state))
        #expect(try ledger.lookup(scope: scope, signature: signature, nowUptime: 12) == .success(state))

        state.phase = .connected
        state.stateRevision = 4
        ledger.updateSuccessState(state)
        #expect(try ledger.lookup(scope: scope, signature: signature, nowUptime: 13) == .success(state))

        let otherClientScope = DesktopOpenIdempotencyScope(
            targetID: targetID,
            clientID: "client-b",
            keyDigest: scope.keyDigest
        )
        #expect(try ledger.lookup(scope: otherClientScope, signature: signature, nowUptime: 13) == nil)
    }

    @Test func desktopOpenIdempotencyLedgerBoundsCompletedTombstones() throws {
        let targetID = UUID()
        let signature = DesktopOpenRequestSignature(pixelWidth: 1_920, pixelHeight: 1_080)
        var ledger = DesktopOpenIdempotencyLedger(retentionSeconds: 5, maximumRecords: 2)
        var scopes: [DesktopOpenIdempotencyScope] = []

        for index in 0..<3 {
            let scope = DesktopOpenIdempotencyScope(
                targetID: targetID,
                clientID: "client",
                keyDigest: "digest-\(index)"
            )
            let operationID = UUID()
            scopes.append(scope)
            _ = try ledger.reserve(
                scope: scope,
                signature: signature,
                operationID: operationID,
                nowUptime: TimeInterval(index)
            )
            ledger.complete(
                operationID: operationID,
                outcome: .failure(DesktopOpenStoredFailure(
                    code: WindowsMCPToolError.Code.runtimeFailure.rawValue,
                    message: "failed",
                    machineCode: "RDP_TEST_FAILURE",
                    retryable: false
                ))
            )
        }

        #expect(ledger.recordCount == 2)
        #expect(try ledger.lookup(scope: scopes[0], signature: signature, nowUptime: 3) == nil)
        #expect(try ledger.lookup(scope: scopes[2], signature: signature, nowUptime: 8) == nil)
        #expect(ledger.recordCount == 0)
    }

    @Test func desktopOpenIdempotencyLedgerBoundsPendingAliases() throws {
        let targetID = UUID()
        let signature = DesktopOpenRequestSignature(pixelWidth: 1_920, pixelHeight: 1_080)
        let operationID = UUID()
        var ledger = DesktopOpenIdempotencyLedger(
            retentionSeconds: 60,
            maximumRecords: 4,
            maximumPendingAliasesPerOperation: 2
        )

        for index in 0..<2 {
            _ = try ledger.reserve(
                scope: DesktopOpenIdempotencyScope(
                    targetID: targetID,
                    clientID: "client-\(index)",
                    keyDigest: "digest-\(index)"
                ),
                signature: signature,
                operationID: operationID,
                nowUptime: TimeInterval(index)
            )
        }

        #expect(throws: DesktopOpenIdempotencyCapacityExceeded()) {
            _ = try ledger.reserve(
                scope: DesktopOpenIdempotencyScope(
                    targetID: targetID,
                    clientID: "client-overflow",
                    keyDigest: "digest-overflow"
                ),
                signature: signature,
                operationID: operationID,
                nowUptime: 3
            )
        }
        #expect(ledger.recordCount == 2)

        var saturatedLedger = DesktopOpenIdempotencyLedger(
            retentionSeconds: 60,
            maximumRecords: 2,
            maximumPendingAliasesPerOperation: 1
        )
        for index in 0..<2 {
            _ = try saturatedLedger.reserve(
                scope: DesktopOpenIdempotencyScope(
                    targetID: targetID,
                    clientID: "saturated-client-\(index)",
                    keyDigest: "saturated-digest-\(index)"
                ),
                signature: signature,
                operationID: UUID(),
                nowUptime: TimeInterval(index)
            )
        }
        let immediateScope = DesktopOpenIdempotencyScope(
            targetID: targetID,
            clientID: "immediate-client",
            keyDigest: "immediate-digest"
        )
        #expect(throws: DesktopOpenIdempotencyCapacityExceeded()) {
            try saturatedLedger.storeImmediateSuccess(
                scope: immediateScope,
                signature: signature,
                state: Self.desktopState(
                    sessionID: UUID(),
                    targetID: targetID,
                    phase: .connected
                ),
                nowUptime: 3
            )
        }
        #expect(saturatedLedger.recordCount == 2)
        #expect(try saturatedLedger.lookup(
            scope: immediateScope,
            signature: signature,
            nowUptime: 3
        ) == nil)
    }

    @Test func desktopOpenIdempotencyCannotReplayAcrossTargetBindings() throws {
        let targetID = UUID()
        let scope = DesktopOpenIdempotencyScope(
            targetID: targetID,
            clientID: "client-a",
            keyDigest: "same-key"
        )
        let endpointA = DesktopOpenRequestSignature(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            targetBinding: String(repeating: "a", count: 64)
        )
        let endpointB = DesktopOpenRequestSignature(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            targetBinding: String(repeating: "b", count: 64)
        )
        var ledger = DesktopOpenIdempotencyLedger(
            retentionSeconds: 60,
            maximumRecords: 8
        )
        try ledger.storeImmediateSuccess(
            scope: scope,
            signature: endpointA,
            state: Self.desktopState(
                sessionID: UUID(),
                targetID: targetID,
                phase: .connected
            ),
            nowUptime: 1
        )

        #expect(throws: DesktopOpenIdempotencyConflict.self) {
            try ledger.lookup(
                scope: scope,
                signature: endpointB,
                nowUptime: 2
            )
        }
    }

    @Test func endpointChangeRejectsThePreviousLiveDesktopSessionID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-live-session-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grantStore = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let target = RemoteSession(
            name: "Windows",
            host: "endpoint-a.test",
            username: "operator",
            connectionType: .rdp
        )
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connecting
                )
            },
            grantStoreForTesting: grantStore
        )
        defer { store.stopAllImmediately() }
        let oldSessionID = store.installActiveDesktopForTesting(target: target)
        let bindingA = target.mcpGrantTargetBinding

        target.host = "endpoint-b.test"
        let bindingB = target.mcpGrantTargetBinding
        store.register(target: target)
        #expect(bindingB != bindingA)
        #expect(store.sessionID(for: target) == nil)
        #expect(!store.sessionMatchesTarget(sessionID: oldSessionID, target: target))

        let client = remoteDesktopTestMCPRegistration()
        do {
            _ = try grantStore.authorize(
                clientID: client.authorizationClientID,
                clientDisplayIdentity: client.displayIdentity,
                targetID: target.targetID,
                targetBinding: bindingB,
                capabilities: [.discovery],
                policy: target.mcpPermissionPolicy,
                externalDataTypes: []
            )
            Issue.record("The changed endpoint must require a new exact-target grant")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
        let request = try #require(grantStore.pendingRequests(
            targetID: target.targetID,
            targetBinding: bindingB
        ).first)
        _ = try grantStore.approve(
            requestID: request.id,
            policy: target.mcpPermissionPolicy,
            consentToExternalData: false,
            currentTargetBinding: bindingB
        )

        do {
            _ = try await store.handleMCP(
                tool: .desktopStatus,
                target: target,
                arguments: [
                    "sessionId": oldSessionID.uuidString.lowercased(),
                    "_jtsClientID": client.authorizationClientID,
                    "_jtsClientDisplayIdentity": client.displayIdentity,
                ]
            )
            Issue.record("Endpoint B must not reuse endpoint A's live desktop session")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
            #expect(failure.message.contains("current endpoint"))
        }
    }

    @Test func desktopRuntimeSingleFlightJoinsConcurrentAndIdempotentOpenRequests() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "win.test",
            username: "operator",
            connectionType: .rdp
        )
        var executionCount = 0
        var issuedSessionIDs: [UUID] = []
        let store = RDPDesktopRuntimeStore { target, _, _ in
            executionCount += 1
            let sessionID = UUID()
            issuedSessionIDs.append(sessionID)
            try await Task.sleep(for: .milliseconds(50))
            return Self.desktopState(
                sessionID: sessionID,
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }

        let request = DesktopOpenRequest(
            // This test exercises single-flight/idempotency, not deadline
            // behavior. Leave enough budget for heavily parallel full-suite
            // runs where the MainActor may be busy with unrelated tests.
            deadlineMilliseconds: 30_000,
            deadlineUptimeMilliseconds: nil,
            clientID: "client-a",
            idempotencyKey: "open-once",
            requestedPixelWidth: 1_920,
            requestedPixelHeight: 1_080
        )
        let calls = (0..<50).map { _ in
            Task { @MainActor in
                try await store.open(target: target, request: request)
            }
        }
        var states: [RDPDesktopSessionState] = []
        for call in calls {
            states.append(try await call.value)
        }

        #expect(executionCount == 1)
        #expect(Set(states.map(\.sessionID)) == Set(issuedSessionIDs))
        #expect(store.activeOpenOperationCountForTesting == 0)

        let replay = try await store.open(target: target, request: request)
        #expect(replay.sessionID == issuedSessionIDs[0])
        #expect(executionCount == 1)

        do {
            _ = try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: 30_000,
                    deadlineUptimeMilliseconds: nil,
                    clientID: "client-a",
                    idempotencyKey: "open-once",
                    requestedPixelWidth: 1_280,
                    requestedPixelHeight: 720
                )
            )
            Issue.record("Expected conflicting idempotency-key reuse to fail")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .idempotencyConflict)
            #expect(failure.details["retryable"] as? Bool == false)
        }
        #expect(executionCount == 1)

        let otherClient = try await store.open(
            target: target,
            request: DesktopOpenRequest(
                deadlineMilliseconds: 30_000,
                deadlineUptimeMilliseconds: nil,
                clientID: "client-b",
                idempotencyKey: "open-once",
                requestedPixelWidth: 1_920,
                requestedPixelHeight: 1_080
            )
        )
        #expect(executionCount == 2)
        #expect(otherClient.sessionID == issuedSessionIDs[1])
    }

    @Test func desktopRuntimeDeadlineCancelsLateWorkAndReplaysTheTombstone() async throws {
        let target = RemoteSession(
            name: "Slow Windows",
            host: "slow.test",
            username: "operator",
            connectionType: .rdp
        )
        var executionCount = 0
        let cancellationCount = LockedInvocationCounter()
        let store = RDPDesktopRuntimeStore { target, _, _ in
            executionCount += 1
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(30))
            } onCancel: {
                cancellationCount.increment()
            }
            return Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }
        let request = DesktopOpenRequest(
            deadlineMilliseconds: 100,
            deadlineUptimeMilliseconds: nil,
            clientID: "deadline-client",
            idempotencyKey: "slow-open",
            requestedPixelWidth: nil,
            requestedPixelHeight: nil
        )

        do {
            _ = try await store.open(target: target, request: request)
            Issue.record("Expected the open deadline to win")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .deadlineExceeded)
            #expect(failure.details["machineCode"] as? String == "RDP_OPEN_DEADLINE_EXCEEDED")
        }
        // The injected operation cannot produce a successful state until its
        // 30-second sleep completes. Receiving the canonical deadline failure,
        // draining the active operation, and replaying its tombstone below are
        // the deterministic contract. A wall-clock assertion here only
        // measures MainActor contention from unrelated parallel test suites.
        let executionCountAfterDeadline = executionCount
        #expect(executionCountAfterDeadline <= 1)
        #expect(cancellationCount.value == executionCountAfterDeadline)
        #expect(store.activeOpenOperationCountForTesting == 0)

        do {
            _ = try await store.open(target: target, request: request)
            Issue.record("Expected the idempotent deadline tombstone to replay")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .deadlineExceeded)
            #expect(failure.details["idempotentReplay"] as? Bool == true)
        }
        #expect(executionCount == executionCountAfterDeadline)
        #expect(cancellationCount.value == executionCountAfterDeadline)
    }

    @Test func desktopRuntimeJoinersKeepIndependentDeadlineCancellationAndDimensions() async throws {
        let target = RemoteSession(
            name: "Shared Windows",
            host: "shared.test",
            username: "operator",
            connectionType: .rdp
        )
        var executionCount = 0
        let sessionID = UUID()
        let (releaseExecution, releaseExecutionContinuation) =
            AsyncStream<Void>.makeStream()
        let store = RDPDesktopRuntimeStore { target, _, _ in
            executionCount += 1
            for await _ in releaseExecution {
                break
            }
            try Task.checkCancellation()
            return Self.desktopState(
                sessionID: sessionID,
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer {
            releaseExecutionContinuation.finish()
            store.stopAllImmediately()
        }

        let longDeadlineMilliseconds = 60_000
        let owner = Task { @MainActor in
            try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: longDeadlineMilliseconds,
                    clientID: "owner",
                    idempotencyKey: "owner-open",
                    requestedPixelWidth: 1_920,
                    requestedPixelHeight: 1_080
                )
            )
        }
        let fullSuiteRegistrationTimeout = Duration.seconds(30)
        guard await Self.waitUntil(timeout: fullSuiteRegistrationTimeout, {
            executionCount == 1
        }) else {
            Issue.record("The shared desktop executor did not start in time.")
            releaseExecutionContinuation.finish()
            owner.cancel()
            _ = try? await owner.value
            return
        }

        let survivingJoiner = Task { @MainActor in
            try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: longDeadlineMilliseconds,
                    clientID: "survivor",
                    idempotencyKey: "survivor-open",
                    requestedPixelWidth: 1_920,
                    requestedPixelHeight: 1_080
                )
            )
        }
        guard await Self.waitUntil(timeout: fullSuiteRegistrationTimeout, {
            store.activeOpenWaiterCountForTesting >= 2
        }) else {
            Issue.record("The surviving joiner did not register in time.")
            releaseExecutionContinuation.finish()
            owner.cancel()
            survivingJoiner.cancel()
            _ = try? await owner.value
            _ = try? await survivingJoiner.value
            return
        }
        owner.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await owner.value
        }

        let cancelledJoiner = Task { @MainActor in
            try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: longDeadlineMilliseconds,
                    clientID: "cancelled",
                    idempotencyKey: "cancelled-open",
                    requestedPixelWidth: 1_920,
                    requestedPixelHeight: 1_080
                )
            )
        }
        guard await Self.waitUntil(timeout: fullSuiteRegistrationTimeout, {
            store.activeOpenWaiterCountForTesting >= 2
        }) else {
            Issue.record("The cancelled joiner did not register in time.")
            releaseExecutionContinuation.finish()
            survivingJoiner.cancel()
            cancelledJoiner.cancel()
            _ = try? await survivingJoiner.value
            _ = try? await cancelledJoiner.value
            return
        }
        cancelledJoiner.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledJoiner.value
        }

        do {
            _ = try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: 100,
                    clientID: "short-waiter",
                    idempotencyKey: "short-open",
                    requestedPixelWidth: 1_920,
                    requestedPixelHeight: 1_080
                )
            )
            Issue.record("Expected the joiner's own deadline to win")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .deadlineExceeded)
        }

        do {
            _ = try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: longDeadlineMilliseconds,
                    clientID: "dimension-conflict",
                    idempotencyKey: nil,
                    requestedPixelWidth: 1_280,
                    requestedPixelHeight: 720
                )
            )
            Issue.record("Expected an unkeyed dimension conflict")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .stateConflict)
            #expect(failure.details["retryable"] as? Bool == true)
        }

        releaseExecutionContinuation.yield()
        let survivingState = try await survivingJoiner.value
        #expect(survivingState.sessionID == sessionID)
        #expect(executionCount == 1)

        let replay = try await store.open(
            target: target,
            request: DesktopOpenRequest(
                deadlineMilliseconds: longDeadlineMilliseconds,
                clientID: "short-waiter",
                idempotencyKey: "short-open",
                requestedPixelWidth: 1_920,
                requestedPixelHeight: 1_080
            )
        )
        #expect(replay.sessionID == sessionID)
        #expect(executionCount == 1)
    }

    @Test func desktopRuntimeCancelsTheUnderlyingOpenWhenItsLastWaiterLeaves() async throws {
        let target = RemoteSession(
            name: "Cancelled Windows",
            host: "cancelled.test",
            username: "operator",
            connectionType: .rdp
        )
        var executionStarted = false
        var executionCancelled = false
        let store = RDPDesktopRuntimeStore { target, _, _ in
            executionStarted = true
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                executionCancelled = true
                throw CancellationError()
            }
            return Self.desktopState(
                sessionID: UUID(),
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }

        let request = Task { @MainActor in
            try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: 60_000,
                    clientID: "cancelled-owner",
                    idempotencyKey: "cancelled-owner-open"
                )
            )
        }
        while !executionStarted || store.activeOpenWaiterCountForTesting == 0 {
            await Task.yield()
        }

        request.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await request.value
        }
        while store.activeOpenOperationCountForTesting != 0 {
            await Task.yield()
        }

        #expect(executionCancelled)
        #expect(store.sessionID(for: target.targetID) == nil)
    }

    @Test func desktopRuntimeNormalizesAndReplaysOpenFailuresExactly() async throws {
        let target = RemoteSession(
            name: "No Credential",
            host: "missing.test",
            username: "operator",
            connectionType: .rdp
        )
        var executionCount = 0
        let store = RDPDesktopRuntimeStore { _, _, _ in
            executionCount += 1
            throw FreeRDPXPCFailure(
                code: "RDP_CREDENTIAL_MISSING",
                message: "Save the RDP password before connecting."
            )
        }
        defer { store.stopAllImmediately() }
        let request = DesktopOpenRequest(
            // This test verifies failure normalization and idempotent replay,
            // not deadline behavior. Full-suite MainActor contention must not
            // turn the injected XPC failure into a synthetic timeout.
            deadlineMilliseconds: 60_000,
            clientID: "failure-client",
            idempotencyKey: "missing-secret"
        )

        var firstFailure: WindowsMCPToolError?
        do {
            _ = try await store.open(target: target, request: request)
            Issue.record("Expected the first open to fail")
        } catch let failure as WindowsMCPToolError {
            firstFailure = failure
            #expect(failure.code == .runtimeFailure)
            #expect(failure.details["machineCode"] as? String == "RDP_CREDENTIAL_MISSING")
            #expect(failure.details["retryable"] as? Bool == false)
        }

        do {
            _ = try await store.open(target: target, request: request)
            Issue.record("Expected the idempotent failure replay")
        } catch let replay as WindowsMCPToolError {
            #expect(replay.code == firstFailure?.code)
            #expect(replay.message == firstFailure?.message)
            #expect(replay.details["machineCode"] as? String == "RDP_CREDENTIAL_MISSING")
            #expect(replay.details["retryable"] as? Bool == false)
            #expect(replay.details["idempotentReplay"] as? Bool == true)
        }
        #expect(executionCount == 1)
    }

    @Test func desktopRuntimeCloseDetachesCancelledFlightBeforeReopen() async throws {
        let target = RemoteSession(
            name: "Reopen Windows",
            host: "reopen.test",
            username: "operator",
            connectionType: .rdp
        )
        var executionCount = 0
        let reopenedSessionID = UUID()
        let store = RDPDesktopRuntimeStore { target, _, _ in
            executionCount += 1
            if executionCount == 1 {
                try await Task.sleep(for: .seconds(30))
            }
            return Self.desktopState(
                sessionID: reopenedSessionID,
                targetID: target.targetID,
                phase: .connecting
            )
        }
        defer { store.stopAllImmediately() }

        let first = Task { @MainActor in
            try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: 60_000,
                    clientID: "first",
                    idempotencyKey: "first-open"
                )
            )
        }
        while executionCount == 0 {
            await Task.yield()
        }

        await store.close(targetID: target.targetID)
        do {
            _ = try await first.value
            Issue.record("Expected the cancelled open to return its canonical failure")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .runtimeFailure)
            #expect(failure.details["machineCode"] as? String == "RDP_OPEN_CANCELLED")
            #expect(failure.details["retryable"] as? Bool == true)
        }
        #expect(store.activeOpenOperationCountForTesting == 0)

        do {
            _ = try await store.open(
                target: target,
                request: DesktopOpenRequest(
                    deadlineMilliseconds: 60_000,
                    clientID: "first",
                    idempotencyKey: "first-open"
                )
            )
            Issue.record("Expected the cancelled-open tombstone to replay")
        } catch let replay as WindowsMCPToolError {
            #expect(replay.code == .runtimeFailure)
            #expect(replay.details["machineCode"] as? String == "RDP_OPEN_CANCELLED")
            #expect(replay.details["retryable"] as? Bool == true)
            #expect(replay.details["idempotentReplay"] as? Bool == true)
        }

        let reopened = try await store.open(
            target: target,
            request: DesktopOpenRequest(
                deadlineMilliseconds: 10_000,
                clientID: "second",
                idempotencyKey: "second-open"
            )
        )
        #expect(reopened.sessionID == reopenedSessionID)
        #expect(executionCount == 2)
    }

    @Test func xpcRequestCoordinatorAcceptsOnlyTheFirstTerminalCallback() async throws {
        let scheduler = ManualXPCRequestDeadlineScheduler()
        let coordinator = XPCRequestCoordinator(deadlineScheduler: scheduler)
        let result: Int = try await coordinator.perform(deadlineSeconds: 3) { completion in
            completion(.success(42))
            completion(.failure(XPCRequestCoordinatorTestError.lateReply))
        }

        #expect(result == 42)
        #expect(coordinator.pendingCount == 0)
        #expect(scheduler.scheduledDelays == [3])
        #expect(scheduler.cancelledTokenCount == 1)
        scheduler.fireNext()
        #expect(coordinator.pendingCount == 0)
    }

    @Test func xpcRequestCoordinatorFailsPendingWorkWhenHelperInvalidates() async {
        let scheduler = ManualXPCRequestDeadlineScheduler()
        let coordinator = XPCRequestCoordinator(deadlineScheduler: scheduler)
        let completion = XPCRequestCompletionCapture<Int>()
        let request = Task<Int, Error> {
            try await coordinator.perform(deadlineSeconds: 4) { reply in
                completion.store(reply)
            }
        }

        while coordinator.pendingCount == 0 || !completion.isStored {
            await Task.yield()
        }
        coordinator.failAll(XPCRequestCoordinatorTestError.helperInvalidated)
        completion.complete(.success(99))
        scheduler.fireNext()

        await #expect(throws: XPCRequestCoordinatorTestError.helperInvalidated) {
            try await request.value
        }
        #expect(coordinator.pendingCount == 0)
        #expect(scheduler.cancelledTokenCount == 1)
    }

    @Test func xpcRequestCoordinatorCancellationDrainsPendingWork() async {
        let scheduler = ManualXPCRequestDeadlineScheduler()
        let coordinator = XPCRequestCoordinator(deadlineScheduler: scheduler)
        let completion = XPCRequestCompletionCapture<Int>()
        let request = Task<Int, Error> {
            try await coordinator.perform(deadlineSeconds: 5) { reply in
                completion.store(reply)
            }
        }

        while coordinator.pendingCount == 0 || !completion.isStored {
            await Task.yield()
        }
        request.cancel()

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        completion.complete(.success(99))
        scheduler.fireNext()
        #expect(coordinator.pendingCount == 0)
        #expect(scheduler.cancelledTokenCount == 1)
    }

    @Test func xpcRequestCoordinatorDeadlineWinsOverLateReplyAndTeardown() async {
        let scheduler = ManualXPCRequestDeadlineScheduler()
        let coordinator = XPCRequestCoordinator(deadlineScheduler: scheduler)
        let completion = XPCRequestCompletionCapture<Int>()
        let request = Task<Int, Error> {
            try await coordinator.perform(deadlineSeconds: 7) { reply in
                completion.store(reply)
            }
        }

        while coordinator.pendingCount == 0 || !completion.isStored {
            await Task.yield()
        }
        #expect(scheduler.scheduledDelays == [7])
        scheduler.fireNext()
        completion.complete(.success(99))
        coordinator.failAll(XPCRequestCoordinatorTestError.helperInvalidated)

        await #expect(throws: XPCRequestTimeoutFailure(deadlineSeconds: 7)) {
            try await request.value
        }
        #expect(coordinator.pendingCount == 0)
    }

    @Test func freeRDPXPCOperationsUseBoundedRequestDeadlines() {
        #expect(FreeRDPXPCRequestDeadlines.connect == 10)
        #expect(FreeRDPXPCRequestDeadlines.ping == 2)
        #expect(FreeRDPXPCRequestDeadlines.disconnect == 2)
        #expect(FreeRDPXPCRequestDeadlines.input == 2)
        #expect(FreeRDPXPCRequestDeadlines.dvc == 2)
        #expect(FreeRDPXPCRequestDeadlines.companionInstaller == 10)
        #expect(FreeRDPXPCRequestDeadlines.copyFrame == 5)
        #expect(FreeRDPXPCSession.connectDeadlineSeconds(requestedMilliseconds: nil) == 10)
        #expect(FreeRDPXPCSession.connectDeadlineSeconds(requestedMilliseconds: 250) == 0.25)
        #expect(FreeRDPXPCSession.connectDeadlineSeconds(requestedMilliseconds: 1) == 0.1)
        #expect(FreeRDPXPCSession.connectDeadlineSeconds(requestedMilliseconds: 60_000) == 10)
        #expect(XPCRequestTimeoutFailure.errorCode == "RDP_XPC_REQUEST_TIMEOUT")
    }

    @Test func frameSurfaceLayoutRequiresExactMetadataAndBoundedAllocation() {
        let valid = RDPFrameSurfaceLayout.validated(
            metadataWidth: 1_920,
            metadataHeight: 1_080,
            metadataBytesPerRow: 7_680,
            surfaceWidth: 1_920,
            surfaceHeight: 1_080,
            surfaceBytesPerRow: 7_680,
            surfaceAllocationBytes: 8_294_400
        )

        #expect(valid == RDPFrameSurfaceLayout(
            width: 1_920,
            height: 1_080,
            bytesPerRow: 7_680,
            requiredBytes: 8_294_400
        ))
        #expect(RDPFrameSurfaceLayout.validated(
            metadataWidth: 1_920,
            metadataHeight: 1_081,
            metadataBytesPerRow: 7_680,
            surfaceWidth: 1_920,
            surfaceHeight: 1_080,
            surfaceBytesPerRow: 7_680,
            surfaceAllocationBytes: 8_294_400
        ) == nil)
        #expect(RDPFrameSurfaceLayout.validated(
            metadataWidth: 1_920,
            metadataHeight: 1_080,
            metadataBytesPerRow: 7_680,
            surfaceWidth: 1_920,
            surfaceHeight: 1_080,
            surfaceBytesPerRow: 7_680,
            surfaceAllocationBytes: 8_294_399
        ) == nil)
    }

    @Test func frameSurfaceLayoutRejectsOverflowAndOversizedStrides() {
        #expect(RDPFrameSurfaceLayout.validated(
            metadataWidth: 7_680,
            metadataHeight: 4_320,
            metadataBytesPerRow: Int.max,
            surfaceWidth: 7_680,
            surfaceHeight: 4_320,
            surfaceBytesPerRow: Int.max,
            surfaceAllocationBytes: Int.max
        ) == nil)
        #expect(RDPFrameSurfaceLayout.validated(
            metadataWidth: 7_680,
            metadataHeight: 4_320,
            metadataBytesPerRow: 65_000,
            surfaceWidth: 7_680,
            surfaceHeight: 4_320,
            surfaceBytesPerRow: 65_000,
            surfaceAllocationBytes: 280_800_000
        ) == nil)
    }

    @Test func sensitiveHumanPromptsBlockAIInputButNotVisualOnlyFallback() {
        #expect(RDPCompanionSensitiveInteractionPolicy.aiInputDenialReason(
            companionAvailability: .pairingRequired,
            pairingAuthorizationInProgress: false,
            elevationPromptInProgress: false
        )?.contains("pairing") == true)
        #expect(RDPCompanionSensitiveInteractionPolicy.aiInputDenialReason(
            companionAvailability: .ready,
            pairingAuthorizationInProgress: false,
            elevationPromptInProgress: true
        )?.contains("elevation") == true)
        #expect(RDPCompanionSensitiveInteractionPolicy.aiInputDenialReason(
            companionAvailability: .missing,
            pairingAuthorizationInProgress: false,
            elevationPromptInProgress: false
        ) == nil)
        #expect(RDPCompanionSensitiveInteractionPolicy.aiInputDenialReason(
            companionAvailability: .incompatible,
            pairingAuthorizationInProgress: false,
            elevationPromptInProgress: false
        ) == nil)
    }

    @Test func reconnectSupervisorUsesBoundedExponentialBackoffAndExhaustsItsBudget() throws {
        let policy = RDPReconnectPolicy(
            maximumAttempts: 6,
            initialDelaySeconds: 2,
            maximumDelaySeconds: 5
        )
        var supervisor = RDPReconnectSupervisor(policy: policy)
        let failure = RDPReconnectFailure(
            phase: .failed,
            code: "RDP_CONNECTION_LOST",
            message: "Transport closed."
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var delays: [TimeInterval] = []

        for expectedAttempt in 1...6 {
            let plan = supervisor.plan(after: failure, now: now)
            guard case .scheduled(let schedule) = plan else {
                Issue.record("Expected reconnect attempt \(expectedAttempt) to be scheduled")
                return
            }
            delays.append(schedule.delaySeconds)
            #expect(schedule.attempt == expectedAttempt)
            #expect(schedule.maximumAttempts == 6)
            #expect(schedule.scheduledAt == now.addingTimeInterval(schedule.delaySeconds))
            let didBegin = supervisor.begin(schedule)
            #expect(didBegin)
        }

        #expect(delays == [2, 4, 5, 5, 5, 5])
        #expect(supervisor.plan(after: failure, now: now) == .exhausted)
        #expect(supervisor.status == .exhausted(attempts: 6))
    }

    @Test func reconnectSupervisorUserStopInvalidatesScheduledWork() throws {
        var supervisor = RDPReconnectSupervisor(policy: .standard)
        let failure = RDPReconnectFailure(
            phase: .connected,
            code: "RDP_XPC_INTERRUPTED",
            message: "Helper interrupted."
        )
        let plan = supervisor.plan(after: failure, now: Date(timeIntervalSince1970: 0))
        let schedule: RDPReconnectSchedule
        guard case .scheduled(let value) = plan else {
            Issue.record("Expected the helper interruption to schedule a reconnect")
            return
        }
        schedule = value

        supervisor.stop()

        #expect(supervisor.status == .stopped)
        #expect(supervisor.attemptCount == 0)
        let didBeginAfterStop = supervisor.begin(schedule)
        #expect(!didBeginAfterStop)
        #expect(supervisor.plan(after: failure, now: .distantFuture) == .stopped)
    }

    @Test func reconnectSupervisorNeverRetriesCertificateAuthenticationOrPolicyFailures() {
        let failures: [RDPReconnectFailure] = [
            RDPReconnectFailure(
                phase: .awaitingCertificateTrust,
                code: "RDP_XPC_INVALIDATED",
                message: "Certificate approval is pending."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "RDP_CERTIFICATE_CHANGED",
                message: "Certificate pin changed."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_LOGON_FAILURE",
                message: "Logon failed."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_AUTHENTICATION_FAILED",
                message: "Authentication failed."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "RDP_LOGOFF_BY_USER",
                message: "Windows ended the RDP session."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "RDP_REDIRECTION_BLOCKED",
                message: "Redirection is forbidden by policy."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "RDP_SETTINGS_REJECTED",
                message: "Secure settings were rejected."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_INSUFFICIENT_PRIVILEGES",
                message: "The account is not permitted to sign in remotely."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "ERRCONNECT_CLIENT_REVOKED",
                message: "The client was revoked by policy."
            ),
            RDPReconnectFailure(
                phase: .failed,
                code: "RDP_CREDENTIAL_ACCESS_FAILED",
                message: "Keychain access was denied."
            ),
        ]

        for failure in failures {
            var supervisor = RDPReconnectSupervisor(policy: .standard)
            #expect(supervisor.plan(after: failure, now: .distantPast) == .blocked)
            #expect(supervisor.status == .blocked(code: failure.code))
            #expect(supervisor.attemptCount == 0)

            let laterHelperInvalidation = RDPReconnectFailure(
                phase: .failed,
                code: "RDP_XPC_INVALIDATED",
                message: "The helper invalidated after reporting the terminal failure."
            )
            let planAfterTerminalFailure = supervisor.plan(
                after: laterHelperInvalidation,
                now: .distantFuture
            )
            #expect(planAfterTerminalFailure == .alreadyBlocked)
            #expect(supervisor.status == .blocked(code: failure.code))
            #expect(supervisor.attemptCount == 0)
        }
    }

    @Test func reconnectSupervisorDoesNotRestartAfterConnectedSessionEndsWithWindowsLogoff() {
        var supervisor = RDPReconnectSupervisor(policy: .standard)
        supervisor.markConnected()

        let logoff = RDPReconnectFailure(
            phase: .failed,
            code: "RDP_LOGOFF_BY_USER",
            message: "Windows ended the RDP session."
        )

        #expect(supervisor.plan(after: logoff, now: .distantPast) == .blocked)
        #expect(supervisor.status == .blocked(code: "RDP_LOGOFF_BY_USER"))
        #expect(supervisor.attemptCount == 0)
        #expect(!supervisor.hasPendingAttempt)
    }

    @Test func reconnectSupervisorRetriesOnlyOnePendingTransientFailureAndResetsAfterConnection() throws {
        let failure = RDPReconnectFailure(
            phase: .failed,
            code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
            message: "Transport unavailable."
        )
        var supervisor = RDPReconnectSupervisor(policy: .standard)
        let firstPlan = supervisor.plan(after: failure, now: .distantPast)
        guard case .scheduled(let firstSchedule) = firstPlan else {
            Issue.record("Expected a transient transport failure to schedule a reconnect")
            return
        }

        #expect(supervisor.plan(after: failure, now: .distantFuture) == .alreadyScheduled)
        #expect(supervisor.attemptCount == 1)
        #expect(supervisor.hasPendingAttempt)
        let didBegin = supervisor.begin(firstSchedule)
        #expect(didBegin)
        #expect(supervisor.hasPendingAttempt)
        supervisor.markConnected()
        #expect(supervisor.status == .idle)
        #expect(supervisor.attemptCount == 0)
        #expect(!supervisor.hasPendingAttempt)

        guard case .scheduled(let resetSchedule) = supervisor.plan(after: failure, now: .distantPast) else {
            Issue.record("Expected the retry budget to reset after a successful connection")
            return
        }
        #expect(resetSchedule.attempt == 1)
    }

    @Test func reconnectVisibilityFieldsRoundTripThroughSessionState() throws {
        let scheduledAt = Date(timeIntervalSince1970: 1_700_000_005)
        let state = RDPDesktopSessionState(
            sessionID: UUID(),
            targetID: UUID(),
            phase: .reconnecting,
            runtimeAvailability: .starting,
            companion: .unknown,
            stateRevision: 0,
            latestFrameID: nil,
            remotePixelWidth: nil,
            remotePixelHeight: nil,
            connectedAt: nil,
            reconnectAttempt: 2,
            reconnectMaximumAttempts: 5,
            reconnectScheduledAt: scheduledAt,
            lastErrorCode: "RDP_CONNECTION_LOST",
            lastErrorMessage: "Reconnect attempt 2/5 starts in 2s."
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RDPDesktopSessionState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.phase == .reconnecting)
        #expect(decoded.reconnectAttempt == 2)
        #expect(decoded.reconnectMaximumAttempts == 5)
        #expect(decoded.reconnectScheduledAt == scheduledAt)
    }

    @MainActor
    @Test func rdpProfileRoundTripPreservesStableTargetAndSecurityDefaults() throws {
        let targetID = UUID()
        let session = RemoteSession(
            targetID: targetID,
            name: "Windows Workstation",
            host: "192.168.1.42",
            username: "builder",
            connectionType: .rdp
        )
        try session.setRDPProfile(RDPConnectionProfile(
            domain: "LAB",
            desktopWidth: 2_560,
            desktopHeight: 1_440,
            pinnedCertificateSHA256: String(repeating: "ab", count: 32),
            clipboardEnabled: false,
            companionPolicy: .required
        ))
        session.mcpEnabled = true

        #expect(session.port == 3_389)
        #expect(session.targetID == targetID)
        #expect(session.connectionType == .rdp)
        #expect(session.rdpProfile.domain == "LAB")
        #expect(session.rdpProfile.clipboardEnabled == false)
        #expect(session.rdpProfile.pinnedCertificateSHA256 == String(repeating: "AB", count: 32))

        let encoded = try SessionProfileCodec.encode(sessions: [session])
        let decoded = try #require(SessionProfileCodec.decode(encoded).first)
        let restored = decoded.makeSession()

        #expect(decoded.id == targetID)
        #expect(restored.targetID == targetID)
        #expect(restored.connectionType == .rdp)
        #expect(restored.port == 3_389)
        #expect(restored.rdpProfile == session.rdpProfile)
        #expect(restored.rdpProfile.persistentMCPControlEnabled)
        #expect(restored.mcpEnabled)
        #expect(!restored.mcpAlwaysAllowTerminalControl)
    }

    @Test func rdpProfileMigratesLegacyClipboardPreferenceOnceWithoutGrantingMCPClipboard() throws {
        #expect(RDPConnectionProfile().clipboardEnabled)

        let legacyPolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .clipboard]
        )
        let profile = RDPConnectionProfile(
            clipboardEnabled: false,
            permissionPolicy: legacyPolicy
        )
        #expect(profile.clipboardEnabled == false)
        #expect(profile.permissionPolicy.maximumCapabilities == [.discovery])
        #expect(!RemoteTargetPermissionPolicy.rdpDefault.maximumCapabilities.contains(.clipboard))

        let importedLegacyProfile = RDPConnectionProfileCodec.decode(
            Data(
                #"{"clipboardEnabled":false,"permissionPolicy":{"maximumCapabilities":["discovery","clipboard"],"controlIdleTimeoutSeconds":900,"requireExternalDataConsent":true}}"#.utf8
            )
        )
        #expect(importedLegacyProfile.clipboardEnabled)
        #expect(importedLegacyProfile.permissionPolicy.maximumCapabilities == [.discovery])
        #expect(importedLegacyProfile.persistentMCPControlEnabled)

        let migratedData = try RDPConnectionProfileCodec.encode(importedLegacyProfile)
        let migratedJSON = try #require(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        #expect(
            migratedJSON["clipboardPreferenceSchemaVersion"] as? Int
                == RDPConnectionProfile.currentClipboardPreferenceSchemaVersion
        )
        #expect(migratedJSON["clipboardEnabled"] as? Bool == true)

        let explicitlyDisabled = RDPConnectionProfile(clipboardEnabled: false)
        let explicitlyDisabledData = try RDPConnectionProfileCodec.encode(explicitlyDisabled)
        let restoredDisabled = RDPConnectionProfileCodec.decode(explicitlyDisabledData)
        #expect(!restoredDisabled.clipboardEnabled)
        #expect(restoredDisabled == explicitlyDisabled)
    }

    @Test func rdpProfileRemovesImportedControlLeasesForPersistentAuthorization() {
        #expect(RemoteTargetPermissionPolicy.rdpDefault.controlLeaseCapabilities.isEmpty)
        #expect(RDPConnectionProfile().persistentMCPControlEnabled)

        let imported = RDPConnectionProfileCodec.decode(
            Data(
                #"{"permissionPolicy":{"maximumCapabilities":["discovery","desktopControl","commandExecution","fileAccess","destructiveOperations","elevation","structuredTasks"],"controlLeaseCapabilities":["fileAccess"],"controlIdleTimeoutSeconds":900,"requireExternalDataConsent":true}}"#.utf8
            )
        )
        #expect(imported.permissionPolicy.controlLeaseCapabilities.isEmpty)
        #expect(imported.persistentMCPControlEnabled)

        let issuedAt = Date(timeIntervalSince1970: 10_000)
        let grant = RemoteClientGrant(
            clientID: "imported-rdp-client",
            targetID: UUID(),
            capabilities: imported.permissionPolicy.maximumCapabilities,
            issuedAt: issuedAt
        )
        let grantPolicy = RemoteCapabilityGrantPolicy(
            permissionPolicy: imported.permissionPolicy
        )
        for capability in imported.permissionPolicy.maximumCapabilities {
            #expect(grantPolicy.authorize(
                grant: grant,
                capability: capability,
                at: issuedAt.addingTimeInterval(365 * 24 * 60 * 60)
            ).isAllowed)
        }

        let unsupportedExtraLeaseProfile = RDPConnectionProfile(
            permissionPolicy: RemoteTargetPermissionPolicy(
                maximumCapabilities: [.fileAccess],
                controlLeaseCapabilities: [.fileAccess]
            )
        )
        #expect(unsupportedExtraLeaseProfile.permissionPolicy.maximumCapabilities == [.fileAccess])
        #expect(unsupportedExtraLeaseProfile.permissionPolicy.controlLeaseCapabilities.isEmpty)

        let mixedProfile = RDPConnectionProfile(
            permissionPolicy: RemoteTargetPermissionPolicy(
                maximumCapabilities: [.desktopControl, .fileAccess],
                controlLeaseCapabilities: [.fileAccess]
            )
        )
        #expect(mixedProfile.permissionPolicy.controlLeaseCapabilities.isEmpty)

        let explicitlyDisabled = RDPConnectionProfileCodec.decode(
            Data(
                #"{"persistentMCPControlEnabled":false,"permissionPolicy":{"maximumCapabilities":["desktopControl"],"controlLeaseCapabilities":["desktopControl"]}}"#.utf8
            )
        )
        #expect(!explicitlyDisabled.persistentMCPControlEnabled)
        #expect(explicitlyDisabled.permissionPolicy.controlLeaseCapabilities.isEmpty)
    }

    @Test func rdpPersistentControlOptionNarrowsTheEffectiveSessionPolicyWhenDisabled() throws {
        let session = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        #expect(session.mcpPermissionPolicy == .rdpDefault)

        try session.setRDPProfile(RDPConnectionProfile(
            persistentMCPControlEnabled: false
        ))
        let narrowed = session.mcpPermissionPolicy
        #expect(narrowed.controlLeaseCapabilities.isEmpty)
        #expect(narrowed.maximumCapabilities.contains(.discovery))
        #expect(narrowed.maximumCapabilities.contains(.desktopObserve))
        #expect(narrowed.maximumCapabilities.contains(.fileAccess))
        #expect(
            narrowed.maximumCapabilities.isDisjoint(
                with: RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities
            )
        )
    }

    @Test func durableGrantBindingTracksEndpointIdentityAndCertificateTrust() throws {
        let targetID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        func makeTarget(
            host: String = "windows.test",
            port: Int = 3_389,
            username: String = "operator",
            domain: String = "LAB",
            trustMode: RDPCertificateTrustMode = .systemOrPinned,
            pin: String? = nil,
            created: Date = createdAt
        ) throws -> RemoteSession {
            let target = RemoteSession(
                targetID: targetID,
                name: "Windows",
                host: host,
                username: username,
                port: port,
                connectionType: .rdp
            )
            target.createdAt = created
            try target.setRDPProfile(RDPConnectionProfile(
                domain: domain,
                certificateTrustMode: trustMode,
                pinnedCertificateSHA256: pin
            ))
            return target
        }

        let baseline = try makeTarget()
        let baselineBinding = baseline.mcpGrantTargetBinding
        #expect(baselineBinding.count == 64)
        #expect(baselineBinding.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        baseline.name = "Renamed Windows"
        baseline.mcpAlias = "renamed-alias"
        #expect(baseline.mcpGrantTargetBinding == baselineBinding)

        #expect(try makeTarget(host: "windows-2.test").mcpGrantTargetBinding != baselineBinding)
        #expect(try makeTarget(port: 3_390).mcpGrantTargetBinding != baselineBinding)
        #expect(try makeTarget(username: "administrator").mcpGrantTargetBinding != baselineBinding)
        #expect(try makeTarget(domain: "OTHER").mcpGrantTargetBinding != baselineBinding)
        #expect(
            try makeTarget(
                trustMode: .pinnedOnly,
                pin: String(repeating: "ab", count: 32)
            ).mcpGrantTargetBinding != baselineBinding
        )
        #expect(
            try makeTarget(
                created: createdAt.addingTimeInterval(1)
            ).mcpGrantTargetBinding != baselineBinding
        )
    }

    @Test func rdpClipboardCapabilityCannotCreateAnApprovalRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-clipboard-denial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteClientGrantStore(storageURL: directory.appendingPathComponent("grants.json"))
        let targetID = UUID()

        do {
            _ = try store.authorize(
                clientID: "clipboard-probe",
                targetID: targetID,
                capabilities: [.clipboard],
                policy: .rdpDefault
            )
            Issue.record("RDP 2.0 must reject clipboard before creating an approval request")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.capabilityNotAllowed.rawValue)
        }

        #expect(store.pendingRequests(targetID: targetID).isEmpty)
    }

    @Test func legacyRDPImportIsRestoredInsteadOfDowngradedToSSH() throws {
        let json = #"{"version":1,"exportedAt":"2026-07-14T00:00:00Z","sessions":[{"name":"Legacy Windows","host":"win.lab","username":"builder","connectionType":"RDP","mcpEnabled":true}]}"#
        let profile = try #require(SessionProfileCodec.decode(Data(json.utf8)).first)

        #expect(profile.connectionType == .rdp)
        #expect(profile.port == 3_389)
        #expect(profile.rdpProfile == RDPConnectionProfile())
        #expect(profile.mcpEnabled)
    }

    @MainActor
    @Test func mcpKeepsLegacyToolsAndPublishesNineWindowsTools() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let server = MCPStdioServer(modelContext: ModelContext(container))
        let line = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#
        ))
        let result = try #require(Self.jsonObject(line)["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        let legacyNames: Set<String> = [
            "jts_list_servers", "jts_exec", "jts_list_dir", "jts_read_file",
            "jts_write_file", "jts_upload_file", "jts_download_file", "jts_stat",
            "jts_mkdir", "jts_rename", "jts_remove", "jts_list_open_terminals",
            "jts_open_terminal", "jts_terminal_exec", "jts_terminal_read",
        ]
        #expect(legacyNames.isSubset(of: names))
        #expect(Set(WindowsMCPToolName.allCases.map(\.rawValue)).isSubset(of: names))

        let openTool = try #require(tools.first { $0["name"] as? String == WindowsMCPToolName.openDesktop.rawValue })
        let inputSchema = try #require(openTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let deadline = try #require(properties["deadlineMs"] as? [String: Any])
        let idempotencyKey = try #require(properties["idempotencyKey"] as? [String: Any])
        #expect(deadline["minimum"] as? Int == 100)
        #expect(deadline["maximum"] as? Int == 60_000)
        #expect(idempotencyKey["minLength"] as? Int == 1)
        #expect(idempotencyKey["maxLength"] as? Int == 128)

        let actionTool = try #require(tools.first {
            $0["name"] as? String == WindowsMCPToolName.desktopAction.rawValue
        })
        let actionSchema = try #require(actionTool["inputSchema"] as? [String: Any])
        let actionProperties = try #require(actionSchema["properties"] as? [String: Any])
        #expect(actionSchema["additionalProperties"] as? Bool == false)
        #expect(actionProperties["selector"] != nil)
        #expect(actionProperties["expectedFrameId"] != nil)
        #expect(actionProperties["scrollDeltaY"] != nil)
        #expect(actionProperties["scrollDeltaX"] == nil)

        for toolName in [
            WindowsMCPToolName.windowsExec,
            .windowsFiles,
            .windowsTask,
        ] {
            let companionTool = try #require(tools.first {
                $0["name"] as? String == toolName.rawValue
            })
            let companionSchema = try #require(
                companionTool["inputSchema"] as? [String: Any]
            )
            let required = Set(
                try #require(companionSchema["required"] as? [String])
            )
            #expect(required.contains("targetId"))
            #expect(required.contains("sessionId"))
            let description = try #require(
                companionTool["description"] as? String
            )
            #expect(description.contains("directly through Companion"))
            #expect(description.contains("Companion"))
            #expect(description.contains("current user of an open desktop"))
            if toolName == .windowsExec {
                #expect(description.contains("separate API channel from video; RDP uses DVC"))
                #expect(description.contains("never converted to terminal keystrokes"))
            }
            if toolName == .windowsTask {
                let properties = try #require(
                    companionSchema["properties"] as? [String: Any]
                )
                let jobIDSchema = try #require(
                    properties["jobId"] as? [String: Any]
                )
                let jobIDDescription = try #require(
                    jobIDSchema["description"] as? String
                )
                for action in ["submit", "status", "cancel", "collect"] {
                    #expect(jobIDDescription.contains(action))
                }
            }
        }

        let routedMinimumDeadline = MCPStdioServer.routedDesktopOpenArguments(
            ["deadlineMs": 100, "targetId": "target"],
            deadlineUptimeMilliseconds: 12_345
        )
        #expect(routedMinimumDeadline["deadlineMs"] as? Int == 100)
        #expect(routedMinimumDeadline["_jtsDeadlineUptimeMilliseconds"] as? Int == 12_345)
    }

    @MainActor
    @Test func unavailableDesktopAndCompanionFailExplicitlyWithoutFakeSuccess() async throws {
        let grantDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-unavailable-runtime-grants-\(UUID().uuidString)", isDirectory: true)
        let grantStore = RemoteClientGrantStore(storageURL: grantDirectory.appendingPathComponent("grants.json"))
        defer { try? FileManager.default.removeItem(at: grantDirectory) }
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let target = RemoteSession(
            name: "Windows",
            host: "192.168.1.50",
            username: "operator",
            connectionType: .rdp
        )
        target.mcpEnabled = true
        context.insert(target)
        try context.save()

        let server = MCPStdioServer(
            modelContext: context,
            windowsDispatcher: .unavailable,
            remoteGrantStore: grantStore,
            clientRegistration: remoteDesktopTestMCPRegistration()
        )
        let targetID = target.targetID.uuidString

        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test-client","version":"1"}}}"#
        ))

        let listLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jts_list_targets","arguments":{}}}"#
        ))
        #expect(grantStore.pendingRequests(targetID: target.targetID).isEmpty)
        let listResult = try Self.toolStructuredContent(listLine)
        let targets = try #require(listResult["targets"] as? [[String: Any]])
        let listed = try #require(targets.first)
        let runtime = try #require(listed["runtime"] as? [String: Any])
        #expect(listed["targetId"] as? String == targetID.lowercased())
        #expect(runtime["desktopRuntimeAvailable"] as? Bool == false)
        #expect(runtime["companionAvailable"] as? Bool == false)

        let openLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"jts_open_desktop","arguments":{"targetId":"\#(targetID)"}}}"#
        ))
        let openResult = try Self.toolResult(openLine)
        let openStructured = try #require(openResult["structuredContent"] as? [String: Any])
        #expect(openResult["isError"] as? Bool == true)
        #expect(openStructured["ok"] as? Bool == false)
        #expect(openStructured["code"] as? String == "DESKTOP_RUNTIME_UNAVAILABLE")

        let unavailableSessionID = UUID().uuidString
        let doctorLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jts_windows_task","arguments":{"targetId":"\#(targetID)","sessionId":"\#(unavailableSessionID)","action":"doctor"}}}"#
        ))
        let doctorResult = try Self.toolResult(doctorLine)
        let doctorStructured = try #require(doctorResult["structuredContent"] as? [String: Any])
        #expect(doctorResult["isError"] as? Bool == true)
        #expect(doctorStructured["ok"] as? Bool == false)
        #expect(doctorStructured["code"] as? String == "COMPANION_REQUIRED")
    }

    @MainActor
    @Test func listTargetsListsMCPEnabledSessionsWithoutCreatingApprovalRequests() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-list-targets-mixed-consent-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let grantStore = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let rdpTarget = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let sshTarget = RemoteSession(
            name: "SSH",
            host: "ssh.test",
            username: "operator",
            connectionType: .ssh
        )
        let localTarget = RemoteSession(
            name: "Local",
            connectionType: .localShell
        )
        let targets = [rdpTarget, sshTarget, localTarget]
        for target in targets {
            target.mcpEnabled = true
            context.insert(target)
        }
        try context.save()

        let server = MCPStdioServer(
            modelContext: context,
            windowsDispatcher: .unavailable,
            remoteGrantStore: grantStore,
            clientRegistration: remoteDesktopTestMCPRegistration()
        )
        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test-client","version":"1"}}}"#
        ))

        let listedLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jts_list_targets","arguments":{}}}"#
        ))
        let listedResult = try Self.toolStructuredContent(listedLine)
        let visibleTargets = try #require(
            listedResult["targets"] as? [[String: Any]]
        )
        #expect(
            Set(visibleTargets.compactMap { $0["targetId"] as? String })
                == Set(targets.map { $0.targetID.uuidString.lowercased() })
        )
        let listedAuthorization = try #require(
            listedResult["authorization"] as? [String: Any]
        )
        #expect(listedAuthorization["status"] as? String == "complete")
        #expect(grantStore.pendingRequests.isEmpty)
        #expect(grantStore.activeGrants.isEmpty)
        for target in targets {
            let authorization = try #require(
                visibleTargets.first {
                    $0["targetId"] as? String == target.targetID.uuidString.lowercased()
                }?["authorization"] as? [String: Any]
            )
            #expect(authorization["status"] as? String == "not_granted")
        }
    }

    @MainActor
    @Test func listTargetsReportsExistingCapabilityApprovalStateWithoutCreatingNewRequests() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-list-targets-capability-state-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let grantStore = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        target.mcpEnabled = true
        context.insert(target)
        try context.save()

        let registration = remoteDesktopTestMCPRegistration()
        let clientID = registration.authorizationClientID

        func request(
            _ capabilities: Set<RemoteCapability>,
            externalDataTypes: Set<RemoteExternalDataType>
        ) throws -> RemoteGrantRequest {
            do {
                _ = try grantStore.authorize(
                    clientID: clientID,
                    clientDisplayIdentity: registration.displayIdentity,
                    targetID: target.targetID,
                    targetBinding: target.mcpGrantTargetBinding,
                    capabilities: capabilities,
                    policy: target.mcpPermissionPolicy,
                    externalDataTypes: externalDataTypes
                )
                Issue.record("Expected a visible approval request")
                throw NSError(
                    domain: "JTSTerminalTests.ExpectedApprovalRequest",
                    code: 1
                )
            } catch let failure as RemoteGrantGateFailure {
                let requestID = try #require(failure.pendingRequestID)
                return try #require(
                    grantStore.pendingRequests(
                        targetID: target.targetID,
                        targetBinding: target.mcpGrantTargetBinding
                    ).first {
                        $0.id == requestID
                    }
                )
            }
        }

        let discoveryRequest = try request(
            [.discovery],
            externalDataTypes: [.targetMetadata]
        )
        _ = try grantStore.approve(
            requestID: discoveryRequest.id,
            policy: target.mcpPermissionPolicy,
            consentToExternalData: true,
            currentTargetBinding: target.mcpGrantTargetBinding
        )
        let observeRequest = try request(
            [.desktopObserve],
            externalDataTypes: [.desktopImage]
        )
        _ = try grantStore.approve(
            requestID: observeRequest.id,
            policy: target.mcpPermissionPolicy,
            consentToExternalData: true,
            currentTargetBinding: target.mcpGrantTargetBinding
        )
        let controlRequest = try request(
            [.desktopControl],
            externalDataTypes: []
        )

        let server = MCPStdioServer(
            modelContext: context,
            windowsDispatcher: .unavailable,
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )
        let listLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jts_list_targets","arguments":{}}}"#
        ))
        let payload = try Self.toolStructuredContent(listLine)
        let listedTarget = try #require((payload["targets"] as? [[String: Any]])?.first)
        let authorization = try #require(listedTarget["authorization"] as? [String: Any])
        #expect(authorization["status"] as? String == "approval_required")
        #expect(
            Set(try #require(authorization["grantedCapabilities"] as? [String]))
                == [RemoteCapability.discovery.rawValue, RemoteCapability.desktopObserve.rawValue]
        )
        #expect(
            Set(try #require(authorization["pendingCapabilities"] as? [String]))
                == [RemoteCapability.desktopControl.rawValue]
        )
        let unresolved = Set(try #require(authorization["unresolvedCapabilities"] as? [String]))
        #expect(unresolved.contains(RemoteCapability.commandExecution.rawValue))
        #expect(unresolved.contains(RemoteCapability.fileAccess.rawValue))
        #expect(
            authorization["pendingRequestIds"] as? [String]
                == [controlRequest.id.uuidString.lowercased()]
        )

        let aggregateAuthorization = try #require(
            payload["authorization"] as? [String: Any]
        )
        #expect(aggregateAuthorization["status"] as? String == "approval_required")
        #expect(
            aggregateAuthorization["pendingRequestIds"] as? [String]
                == [controlRequest.id.uuidString.lowercased()]
        )
        #expect(grantStore.pendingRequests(targetID: target.targetID) == [controlRequest])
    }

    @Test func listTargetsReportsOnlyCapabilitiesEnabledByTheCurrentRDPSetting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-effective-rdp-grant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grantStore = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        target.mcpEnabled = true
        context.insert(target)
        try context.save()

        let registration = remoteDesktopTestMCPRegistration()
        let binding = target.mcpGrantTargetBinding
        let request = try requireGrantRequest(
            store: grantStore,
            clientID: registration.authorizationClientID,
            targetID: target.targetID,
            capabilities: [.discovery],
            externalDataTypes: [.targetMetadata],
            policy: target.mcpPermissionPolicy,
            at: Date(timeIntervalSince1970: 1_700_000_000),
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED",
            targetBinding: binding
        )
        let storedGrant = try grantStore.approve(
            requestID: request.id,
            policy: target.mcpPermissionPolicy,
            consentToExternalData: true,
            grantPersistentTargetAccess: true,
            currentTargetBinding: binding
        )
        #expect(
            !storedGrant.capabilities.isDisjoint(
                with: RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities
            )
        )

        var profile = target.rdpProfile
        profile.persistentMCPControlEnabled = false
        try target.setRDPProfile(profile)
        try context.save()
        let effectiveCapabilities = target.mcpPermissionPolicy.maximumCapabilities
        #expect(
            effectiveCapabilities.isDisjoint(
                with: RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities
            )
        )

        let server = MCPStdioServer(
            modelContext: context,
            windowsDispatcher: .unavailable,
            remoteGrantStore: grantStore,
            clientRegistration: registration
        )
        let listLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jts_list_targets","arguments":{}}}"#
        ))
        let payload = try Self.toolStructuredContent(listLine)
        let listedTarget = try #require((payload["targets"] as? [[String: Any]])?.first)
        let authorization = try #require(
            listedTarget["authorization"] as? [String: Any]
        )
        #expect(authorization["status"] as? String == "complete")
        #expect(
            Set(try #require(authorization["grantedCapabilities"] as? [String]))
                == Set(effectiveCapabilities.map(\.rawValue))
        )
        #expect(
            Set(try #require(listedTarget["configuredCapabilities"] as? [String]))
                == Set(effectiveCapabilities.map(\.rawValue))
        )
        #expect(
            grantStore.activeGrants(
                targetID: target.targetID,
                targetBinding: binding
            ).first?.capabilities == RemoteTargetPermissionPolicy.rdpDefault.maximumCapabilities
        )
    }

    @Test func coordinateActionsRejectStaleFramesAndUseRemotePixelBounds() throws {
        let sessionID = UUID()
        let currentFrameID = UUID()
        let frame = DesktopFrameMetadata(
            frameID: currentFrameID,
            sessionID: sessionID,
            stateRevision: 7,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let staleAction = DesktopActionRequest(
            action: .click,
            expectedStateRevision: 7,
            expectedFrameID: UUID(),
            point: DesktopPoint(x: 960, y: 540)
        )

        do {
            try staleAction.validate(against: frame)
            Issue.record("Expected stale desktop frame validation failure")
        } catch let error as DesktopActionValidationError {
            guard case .staleFrame = error else {
                Issue.record("Expected staleFrame, got \(error)")
                return
            }
        }

        let validAction = DesktopActionRequest(
            action: .click,
            expectedStateRevision: 7,
            expectedFrameID: currentFrameID,
            point: DesktopPoint(x: 1_919, y: 1_079)
        )
        try validAction.validate(against: frame)
    }

    @Test func localManualPointerInputRebindsAcrossPaintsWithoutWeakeningStaleValidation() throws {
        let sessionID = UUID()
        let observedFrame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: sessionID,
            stateRevision: 40,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let latestFrame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: sessionID,
            stateRevision: 44,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let localRequest = DesktopActionRequest(
            action: .click,
            expectedStateRevision: observedFrame.stateRevision,
            expectedFrameID: observedFrame.frameID,
            point: DesktopPoint(x: 960, y: 540)
        )

        let rebound = try RDPManualDesktopActionResolver.rebind(
            localRequest,
            observedFrame: observedFrame,
            latestFrame: latestFrame
        )
        #expect(rebound.expectedFrameID == latestFrame.frameID)
        #expect(rebound.expectedStateRevision == latestFrame.stateRevision)
        #expect(rebound.point == localRequest.point)
        try rebound.validate(against: latestFrame)

        do {
            try localRequest.validate(against: latestFrame)
            Issue.record("Expected the unchanged MCP/AI stale-frame validation to reject the old frame")
        } catch let error as DesktopActionValidationError {
            guard case .staleState = error else {
                Issue.record("Expected staleState, got \(error)")
                return
            }
        }
    }

    @Test func localManualPointerInputDoesNotRebindAcrossResolutionChanges() throws {
        let sessionID = UUID()
        let observedFrame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: sessionID,
            stateRevision: 8,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let resizedFrame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: sessionID,
            stateRevision: 9,
            pixelWidth: 1_280,
            pixelHeight: 720
        )
        let request = DesktopActionRequest(
            action: .click,
            expectedStateRevision: observedFrame.stateRevision,
            expectedFrameID: observedFrame.frameID,
            point: DesktopPoint(x: 900, y: 500)
        )

        do {
            _ = try RDPManualDesktopActionResolver.rebind(
                request,
                observedFrame: observedFrame,
                latestFrame: resizedFrame
            )
            Issue.record("Expected a changed coordinate space to remain a real conflict")
        } catch let error as DesktopActionValidationError {
            guard case .coordinateSpaceChanged = error else {
                Issue.record("Expected coordinateSpaceChanged, got \(error)")
                return
            }
        }
    }

    @Test func localManualPointerInputRequiresTheActuallyObservedFrame() throws {
        let latestFrame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: UUID(),
            stateRevision: 3,
            pixelWidth: 1_024,
            pixelHeight: 768
        )
        let request = DesktopActionRequest(
            action: .scroll,
            expectedStateRevision: 2,
            expectedFrameID: UUID(),
            point: DesktopPoint(x: 100, y: 100),
            scrollDeltaY: -120
        )

        do {
            _ = try RDPManualDesktopActionResolver.rebind(
                request,
                observedFrame: nil,
                latestFrame: latestFrame
            )
            Issue.record("Expected an evicted or unknown visible frame to stay rejected")
        } catch let error as DesktopActionValidationError {
            guard case .unobservedCoordinateFrame = error else {
                Issue.record("Expected unobservedCoordinateFrame, got \(error)")
                return
            }
        }
    }

    @Test func localManualKeyboardInputUsesTheLatestRevisionWithoutCoordinateMetadata() throws {
        let sessionID = UUID()
        let observedFrame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: sessionID,
            stateRevision: 11,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let latestFrame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: sessionID,
            stateRevision: 18,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let tabRequest = DesktopActionRequest(
            action: .keyDown,
            expectedStateRevision: observedFrame.stateRevision,
            expectedFrameID: observedFrame.frameID,
            key: "TAB"
        )

        let rebound = try RDPManualDesktopActionResolver.rebind(
            tabRequest,
            observedFrame: observedFrame,
            latestFrame: latestFrame
        )
        #expect(rebound.expectedStateRevision == latestFrame.stateRevision)
        #expect(rebound.expectedFrameID == latestFrame.frameID)
        try rebound.validate(against: latestFrame)
    }

    @Test func localManualKeyboardInputRejectsAnEvictedObservedFrame() throws {
        let latestFrame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: UUID(),
            stateRevision: 18,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let tabRequest = DesktopActionRequest(
            action: .keyDown,
            expectedStateRevision: 11,
            expectedFrameID: UUID(),
            key: "TAB"
        )

        do {
            _ = try RDPManualDesktopActionResolver.rebind(
                tabRequest,
                observedFrame: nil,
                latestFrame: latestFrame
            )
            Issue.record("Expected an old manual key event to stay bound to its observed frame")
        } catch let error as DesktopActionValidationError {
            guard case .unobservedManualFrame = error else {
                Issue.record("Expected unobservedManualFrame, got \(error)")
                return
            }
        }
    }

    @Test func desktopTypeTextPreservesShiftedPunctuationForManualAndMCPInput() async throws {
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        var dispatchedInputs: [[String: Any]] = []
        let store = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
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
        let exactText = "A:B_C$D|E{F}G-123"
        let request = DesktopActionRequest(
            action: .typeText,
            expectedStateRevision: frame.stateRevision,
            expectedFrameID: frame.frameID,
            text: exactText
        )

        _ = try await store.performManualDesktopActionForTesting(
            sessionID: sessionID,
            request: request
        )
        _ = try await store.performDesktopAction(
            sessionID: sessionID,
            request: request
        )

        #expect(dispatchedInputs.count == 2)
        #expect(dispatchedInputs.allSatisfy { $0["type"] as? String == "text" })
        #expect(dispatchedInputs.allSatisfy { $0["text"] as? String == exactText })
        #expect(dispatchedInputs.allSatisfy {
            $0["expectedStateRevision"] as? UInt64 == 7
        })
        #expect(dispatchedInputs[0]["inputOrigin"] as? String == "localManual")
        #expect(dispatchedInputs[1]["inputOrigin"] == nil)
    }

    @Test func desktopViewportUsesTheProposedSizeInsteadOfRemotePixelDimensions() {
        #expect(
            RDPDesktopViewportSizing.representableSize(width: 1_180, height: 640)
                == CGSize(width: 1_180, height: 640)
        )
        #expect(
            RDPDesktopViewportSizing.representableSize(width: nil, height: CGFloat.infinity)
                == .zero
        )
        #expect(
            RDPDesktopViewportSizing.representableSize(width: -20, height: 480)
                == CGSize(width: 0, height: 480)
        )
        #expect(
            RDPDesktopViewportSizing.viewportSize(
                CGSize(width: CGFloat.infinity, height: -100)
            ) == .zero
        )
    }

    @Test func desktopFitLetterboxesInsideFiniteViewportWithoutRequestingNativeSize() {
        let fitted = RDPDesktopViewportSizing.fittedContentSize(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            available: CGSize(width: 1_000, height: 800)
        )
        #expect(abs(fitted.width - 1_000) < 0.001)
        #expect(abs(fitted.height - 562.5) < 0.001)

        let centered = RDPDesktopViewportSizing.fittedContentRect(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            available: CGSize(width: 1_000, height: 800)
        )
        #expect(abs(centered.minX) < 0.001)
        #expect(abs(centered.minY - 118.75) < 0.001)
        #expect(abs(centered.width - 1_000) < 0.001)
        #expect(abs(centered.height - 562.5) < 0.001)
        #expect(abs((800 - centered.maxY) - 118.75) < 0.001)
        #expect(
            RDPDesktopViewportSizing.fittedContentSize(
                pixelWidth: 1_920,
                pixelHeight: 1_080,
                available: CGSize(width: CGFloat.infinity, height: 800)
            ) == .zero
        )
        #expect(
            RDPDesktopViewportSizing.fittedContentRect(
                pixelWidth: 1_920,
                pixelHeight: 1_080,
                available: CGSize(width: CGFloat.infinity, height: 800)
            ) == .zero
        )
    }

    @Test func desktopFeatureContainerFillsTheParentProposal() throws {
        let root = RDPDesktopFeatureContainer {
            Color.clear
                .frame(width: 400, height: 300)
        }
        .frame(width: 800, height: 700)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        for _ in 0..<20 {
            hostingView.layoutSubtreeIfNeeded()
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.002)
            )
        }

        let featureContainer = try #require(remoteDesktopDescendant(
            of: hostingView,
            identifier: RDPDesktopLayoutIdentifiers.featureContainer
        ))
        let featureContainerRect = featureContainer.convert(
            featureContainer.bounds,
            to: hostingView
        )

        #expect(abs(featureContainerRect.midX - hostingView.bounds.midX) <= 1)
        #expect(abs(featureContainerRect.midY - hostingView.bounds.midY) <= 1)
        #expect(abs(featureContainerRect.width - hostingView.bounds.width) <= 1)
        #expect(abs(featureContainerRect.height - hostingView.bounds.height) <= 1)
    }

    @Test func desktopProductionFeatureContainerCentersTheFramebufferAcrossResizes() throws {
        let target = RemoteSession(
            name: "Windows",
            host: "rdp.example.test",
            username: "operator",
            connectionType: .rdp
        )
        let image = NSImage(size: NSSize(width: 1_920, height: 1_080))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let state = RDPDesktopSessionState(
            sessionID: UUID(),
            targetID: target.targetID,
            phase: .connected,
            runtimeAvailability: .available,
            companion: WindowsCompanionState(
                availability: .ready,
                protocolVersion: 1,
                companionVersion: "layout-test",
                reason: nil
            ),
            stateRevision: 1,
            latestFrameID: UUID(),
            remotePixelWidth: 1_920,
            remotePixelHeight: 1_080,
            connectedAt: Date(),
            reconnectAttempt: nil,
            reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil,
            lastErrorCode: nil,
            lastErrorMessage: nil
        )
        var manualActions: [DesktopActionRequest] = []
        let presentation = RDPDesktopWorkspacePresentation(
            state: state,
            frameImage: image,
            performManualAction: { manualActions.append($0) }
        )
        let root = VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                RDPDesktopFeatureContainer {
                    RDPDesktopWorkspace(
                        session: target,
                        presentation: presentation,
                        openServerProperties: {}
                    )
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.appLanguage, .english)

        let hostingView = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.orderOut(nil)
            window.close()
        }

        func settleLayout() {
            for _ in 0..<20 {
                window.contentView?.layoutSubtreeIfNeeded()
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date(timeIntervalSinceNow: 0.002)
                )
            }
        }

        func verifyCentered(
            size: CGSize,
            minimumGap: CGFloat
        ) throws {
            window.setContentSize(size)
            settleLayout()

            let viewport = try #require(remoteDesktopDescendant(
                of: hostingView,
                identifier: RDPDesktopLayoutIdentifiers.viewportHost
            ))
            let featureContainer = try #require(remoteDesktopDescendant(
                of: hostingView,
                identifier: RDPDesktopLayoutIdentifiers.featureContainer
            ))
            let framebuffer = try #require(remoteDesktopDescendant(
                of: hostingView,
                identifier: RDPDesktopLayoutIdentifiers.framebuffer
            ))
            let featureContainerRect = featureContainer.convert(
                featureContainer.bounds,
                to: hostingView
            )
            let viewportRect = viewport.convert(viewport.bounds, to: hostingView)
            let framebufferRect = framebuffer.convert(framebuffer.bounds, to: hostingView)
            let availableRect = hostingView.bounds.insetBy(dx: 8, dy: 8)
            let leadingGap = framebufferRect.minY - viewportRect.minY
            let trailingGap = viewportRect.maxY - framebufferRect.maxY

            #expect(abs(featureContainerRect.midY - availableRect.midY) <= 1)
            #expect(abs(featureContainerRect.height - availableRect.height) <= 1)
            #expect(viewportRect.minY >= featureContainerRect.minY)
            #expect(viewportRect.maxY <= featureContainerRect.maxY)
            #expect(abs(framebufferRect.midY - viewportRect.midY) <= 1)
            #expect(abs(leadingGap - trailingGap) <= 1)
            #expect(leadingGap >= minimumGap)
            #expect(trailingGap >= minimumGap)
            #expect(framebufferRect.minY >= viewportRect.minY)
            #expect(framebufferRect.maxY <= viewportRect.maxY)
        }

        try verifyCentered(
            size: CGSize(width: 1_200, height: 900),
            minimumGap: 40
        )
        try verifyCentered(
            size: CGSize(width: 1_200, height: 820),
            minimumGap: 20
        )

        let framebuffer = try #require(remoteDesktopDescendant(
            of: hostingView,
            identifier: RDPDesktopLayoutIdentifiers.framebuffer
        ))
        #expect(window.makeFirstResponder(framebuffer))
        let leftArrowDown = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{F702}",
            charactersIgnoringModifiers: "\u{F702}",
            isARepeat: false,
            keyCode: 123
        ))
        framebuffer.keyDown(with: leftArrowDown)
        #expect(manualActions.last?.action == .keyDown)
        #expect(manualActions.last?.key == "left")

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        settleLayout()

        #expect(window.firstResponder !== framebuffer)
        #expect(manualActions.suffix(2).map(\.action) == [.keyDown, .keyUp])
        #expect(manualActions.last?.key == "left")
    }

    @Test func desktopViewportCentersSmallContentAndKeepsOversizedContentScrollableFromTopLeading() {
        let horizontallyCentered = RDPDesktopViewportSizing.centeredContentRect(
            contentSize: CGSize(width: 600, height: 800),
            available: CGSize(width: 1_000, height: 800)
        )
        #expect(horizontallyCentered == CGRect(x: 200, y: 0, width: 600, height: 800))

        let centeredOnBothAxes = RDPDesktopViewportSizing.centeredContentRect(
            contentSize: CGSize(width: 600, height: 400),
            available: CGSize(width: 1_000, height: 800)
        )
        #expect(centeredOnBothAxes == CGRect(x: 200, y: 200, width: 600, height: 400))

        let oversized = RDPDesktopViewportSizing.centeredContentRect(
            contentSize: CGSize(width: 1_920, height: 1_080),
            available: CGSize(width: 1_000, height: 700)
        )
        #expect(oversized == CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

        #expect(
            RDPDesktopViewportSizing.centeredContentRect(
                contentSize: CGSize(width: 600, height: CGFloat.infinity),
                available: CGSize(width: 1_000, height: 800)
            ) == .zero
        )
    }

    @Test func desktopKeyboardRoutesPrintableCandidatesThroughAppKitTextInput() {
        let printableCases: [(String, NSEvent.ModifierFlags)] = [
            (":", [.shift]),
            ("$", [.shift]),
            ("\"", [.shift]),
            ("'", []),
            ("_", [.shift]),
            (" ", []),
            ("中文", []),
            ("👩‍💻", []),
            ("A", [.capsLock]),
        ]

        for (characters, flags) in printableCases {
            #expect(
                RDPDesktopKeyboardInputRouting.shouldInterpretTextInput(
                    characters: characters,
                    modifierFlags: flags,
                    hasMarkedText: false
                )
            )

            var routing = RDPDesktopKeyboardInputRouting()
            let keyDownRoute = routing.keyDownRoute(
                keyCode: 41,
                characters: characters,
                modifierFlags: flags,
                hasPhysicalKey: true,
                hasMarkedText: false
            )
            let sendsPhysicalKeyUp = routing.shouldSendPhysicalKeyUp(
                keyCode: 41,
                hasPhysicalKey: true
            )
            #expect(keyDownRoute == .textInput)
            #expect(!sendsPhysicalKeyUp)
        }
    }

    @Test func desktopTextInputKeepsMarkedTextLocalAndEmitsOneCommit() {
        var textInput = RDPDesktopTextInputState()
        var effects: [RDPDesktopTextInputEffect] = []

        effects.append(textInput.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0)
        ))
        #expect(textInput.hasMarkedText)
        #expect(textInput.markedText == "ni")
        #expect(textInput.markedRange == NSRange(location: 0, length: 2))
        #expect(textInput.selectedRange == NSRange(location: 2, length: 0))
        #expect(effects == [.none])

        effects.append(textInput.setMarkedText(
            "你",
            selectedRange: NSRange(location: 1, length: 0)
        ))
        effects.append(textInput.insertText("你"))

        #expect(effects == [.none, .none, .commit("你")])
        #expect(!textInput.hasMarkedText)
        #expect(textInput.markedRange == NSRange(location: NSNotFound, length: 0))
        #expect(textInput.selectedRange == NSRange(location: 0, length: 0))

        effects.append(textInput.setMarkedText(
            "定稿",
            selectedRange: NSRange(location: 2, length: 0)
        ))
        effects.append(textInput.unmarkText())
        effects.append(textInput.unmarkText())
        #expect(effects.filter { effect in
            if case .commit = effect { return true }
            return false
        } == [.commit("你"), .commit("定稿")])
        #expect(!textInput.hasMarkedText)
    }

    @Test func desktopTextInputCommitsShiftedPunctuationWithoutNormalization() {
        var textInput = RDPDesktopTextInputState()
        let exactText = "A:B_C$D|E{F}G-123"

        #expect(textInput.insertText(exactText) == .commit(exactText))
        #expect(!textInput.hasMarkedText)
        #expect(textInput.markedRange == NSRange(location: NSNotFound, length: 0))
    }

    @Test func desktopKeyboardReservesAVisibleLocalReleaseShortcutWithoutConsumingTabOrEscape() {
        var releaseRouting = RDPDesktopKeyboardInputRouting()
        let releaseRoute = releaseRouting.keyDownRoute(
            keyCode: RDPDesktopKeyboardInputRouting.localReleaseKeyCode,
            characters: "\u{1B}",
            modifierFlags: RDPDesktopKeyboardInputRouting.localReleaseModifiers,
            hasPhysicalKey: true,
            hasMarkedText: true
        )
        #expect(releaseRoute == .releaseLocalFocus)
        let sendsReleaseKeyUp = releaseRouting.shouldSendPhysicalKeyUp(
            keyCode: RDPDesktopKeyboardInputRouting.localReleaseKeyCode,
            hasPhysicalKey: true
        )
        #expect(!sendsReleaseKeyUp)

        for (keyCode, characters) in [(48, "\t"), (53, "\u{1B}")] {
            var routing = RDPDesktopKeyboardInputRouting()
            let route = routing.keyDownRoute(
                keyCode: UInt16(keyCode),
                characters: characters,
                modifierFlags: [],
                hasPhysicalKey: true,
                hasMarkedText: false
            )
            #expect(route == .physicalKey)
            let sendsPhysicalKeyUp = routing.shouldSendPhysicalKeyUp(
                keyCode: UInt16(keyCode),
                hasPhysicalKey: true
            )
            #expect(sendsPhysicalKeyUp)
        }

        #expect(!RDPDesktopKeyboardInputRouting.shouldReleaseLocalFocus(
            keyCode: 48,
            modifierFlags: [.control, .command]
        ))
        #expect(!RDPDesktopKeyboardInputRouting.shouldReleaseLocalFocus(
            keyCode: 53,
            modifierFlags: [.command]
        ))
        #expect(!RDPDesktopKeyboardInputRouting.shouldReleaseLocalFocus(
            keyCode: 53,
            modifierFlags: [.control, .command, .option]
        ))
        #expect(RDPDesktopKeyboardInputRouting.shouldReleaseLocalFocus(
            keyCode: 53,
            modifierFlags: [.capsLock, .control, .command]
        ))

        var markedText = RDPDesktopTextInputState()
        _ = markedText.setMarkedText(
            "unfinished",
            selectedRange: NSRange(location: 10, length: 0)
        )
        markedText.cancelMarkedText()
        #expect(!markedText.hasMarkedText)
        #expect(markedText.unmarkText() == .none)
    }

    @Test func desktopKeyboardClearsAStaleReleaseMarkerOnTheNextEscapeKeyDown() {
        var routing = RDPDesktopKeyboardInputRouting()
        #expect(
            routing.keyDownRoute(
                keyCode: RDPDesktopKeyboardInputRouting.localReleaseKeyCode,
                characters: "\u{1B}",
                modifierFlags: RDPDesktopKeyboardInputRouting.localReleaseModifiers,
                hasPhysicalKey: true,
                hasMarkedText: false
            ) == .releaseLocalFocus
        )

        // Resigning first responder can prevent AppKit from delivering the
        // shortcut's key-up. A later ordinary Escape sequence must not inherit
        // that stale local marker or leave Escape held down on Windows.
        #expect(
            routing.keyDownRoute(
                keyCode: RDPDesktopKeyboardInputRouting.localReleaseKeyCode,
                characters: "\u{1B}",
                modifierFlags: [],
                hasPhysicalKey: true,
                hasMarkedText: false
            ) == .physicalKey
        )
        let sendsLaterEscapeKeyUp = routing.shouldSendPhysicalKeyUp(
            keyCode: RDPDesktopKeyboardInputRouting.localReleaseKeyCode,
            hasPhysicalKey: true
        )
        #expect(sendsLaterEscapeKeyUp)
    }

    @Test func desktopInputFocusUsesOneLatestCommandAcrossViewRecreation() {
        let focused = RDPDesktopInputFocusCommand.initial.advanced(to: .remote)
        let released = focused.advanced(to: .local)
        let refocused = released.advanced(to: .remote)

        #expect(focused.destination == .remote)
        #expect(released.destination == .local)
        #expect(refocused.destination == .remote)
        #expect(focused.generation < released.generation)
        #expect(released.generation < refocused.generation)

        // A newly created framebuffer receives only this latest value. It
        // cannot replay an earlier release after applying a later focus.
        let recreatedViewCommand = refocused
        #expect(recreatedViewCommand == refocused)
        #expect(recreatedViewCommand.destination == .remote)

        let wrapped = RDPDesktopInputFocusCommand(
            generation: .max,
            destination: .local
        ).advanced(to: .remote)
        #expect(wrapped.generation == 1)
        #expect(wrapped.destination == .remote)
    }

    @Test func desktopInputFocusHandshakeAcknowledgesOnlyTheStableLatestRemoteCommand() {
        var handshake = RDPDesktopInputFocusHandshake()
        let remote = RDPDesktopInputFocusCommand.initial.advanced(to: .remote)

        guard case let .requestRemote(command, token) = handshake.receive(remote) else {
            Issue.record("The latest remote command should start a verified handshake.")
            return
        }
        #expect(command == remote)
        #expect(handshake.hasPendingRemoteCommand)
        #expect(handshake.acceptsRemoteAttempt(command: command, token: token))
        let rejectedAcknowledgement = handshake.acknowledgeRemoteAttempt(
            command: command,
            token: token &+ 1
        )
        #expect(!rejectedAcknowledgement)
        #expect(handshake.hasPendingRemoteCommand)
        let acceptedAcknowledgement = handshake.acknowledgeRemoteAttempt(
            command: command,
            token: token
        )
        #expect(acceptedAcknowledgement)
        #expect(!handshake.hasPendingRemoteCommand)
        #expect(!handshake.acceptsRemoteAttempt(command: command, token: token))
    }

    @Test func desktopInputFocusHandshakeCancelsQueuedRetryForANewerLocalCommand() {
        var handshake = RDPDesktopInputFocusHandshake()
        let remote = RDPDesktopInputFocusCommand.initial.advanced(to: .remote)
        guard case let .requestRemote(command, token) = handshake.receive(remote) else {
            Issue.record("The remote command should start a handshake.")
            return
        }

        let local = remote.advanced(to: .local)
        let localDisposition = handshake.receive(local)
        #expect(localDisposition == .releaseLocal)
        #expect(!handshake.hasPendingRemoteCommand)
        #expect(!handshake.acceptsRemoteAttempt(command: command, token: token))
        #expect(handshake.latestCommand == local)
    }

    @Test func desktopInputFocusHandshakeCancellationCannotReplayOnViewAttachment() {
        var handshake = RDPDesktopInputFocusHandshake()
        let remote = RDPDesktopInputFocusCommand.initial.advanced(to: .remote)
        guard case let .requestRemote(command, token) = handshake.receive(remote) else {
            Issue.record("The remote command should start a handshake.")
            return
        }

        let cancelledRemoteRequest = handshake.cancelRemoteRequest()
        #expect(cancelledRemoteRequest)
        #expect(!handshake.hasPendingRemoteCommand)
        let restartedRequest = handshake.restartPendingRemoteRequest()
        #expect(restartedRequest == nil)
        #expect(!handshake.acceptsRemoteAttempt(command: command, token: token))
        let repeatedDisposition = handshake.receive(remote)
        #expect(repeatedDisposition == .ignored)

        let retriedRemote = remote.advanced(to: .remote)
        guard case let .requestRemote(retryCommand, retryToken) =
            handshake.receive(retriedRemote) else {
            Issue.record("A new user command should be able to retry remote focus.")
            return
        }
        #expect(retryCommand == retriedRemote)
        #expect(retryToken != token)
    }

    @Test func desktopInputFocusHandshakeRebindsTheLatestRemoteIntentAfterViewMove() {
        var handshake = RDPDesktopInputFocusHandshake()
        let remote = RDPDesktopInputFocusCommand.initial.advanced(to: .remote)
        guard case let .requestRemote(command, token) = handshake.receive(remote) else {
            Issue.record("The remote command should start a handshake.")
            return
        }
        let acknowledged = handshake.acknowledgeRemoteAttempt(
            command: command,
            token: token
        )
        #expect(acknowledged)
        #expect(!handshake.hasPendingRemoteCommand)

        handshake.suspendForViewReattachment()
        #expect(handshake.hasPendingRemoteCommand)
        #expect(!handshake.acceptsRemoteAttempt(command: command, token: token))
        let acknowledgedLocalDuringReattachment =
            handshake.cancelRemoteRequest(preservingRemoteIntent: true)
        #expect(!acknowledgedLocalDuringReattachment)
        #expect(handshake.hasPendingRemoteCommand)
        guard let restarted = handshake.restartPendingRemoteRequest() else {
            Issue.record("A moved representable should resume the latest remote intent.")
            return
        }
        #expect(restarted.command == remote)
        #expect(restarted.token != token)
    }

    @Test func desktopInputFocusReleaseSynthesizesEveryOutstandingPhysicalKeyUp() {
        var keys = RDPDesktopPhysicalKeyState()
        keys.recordKeyDown(keyCode: 123, name: "left")
        keys.recordKeyDown(keyCode: 51, name: "backspace")
        #expect(!keys.isEmpty)

        #expect(keys.releaseAllKeyNames() == ["backspace", "left"])
        #expect(keys.isEmpty)
        #expect(keys.releaseAllKeyNames().isEmpty)

        keys.recordKeyDown(keyCode: 53, name: "escape")
        #expect(
            keys.keyUpName(
                keyCode: 53,
                fallbackName: "escape"
            ) == "escape"
        )
        #expect(keys.isEmpty)
    }

    @Test func desktopInputReleaseDrainsPointerButtonsPhysicalKeysAndMarkedTextOnce() {
        var pointers = RDPDesktopPressedPointerState()
        pointers.recordMouseDown(
            button: .left,
            point: DesktopPoint(x: 10, y: 20)
        )
        pointers.recordPointerMove(
            button: .left,
            point: DesktopPoint(x: 30, y: 40)
        )
        pointers.recordMouseDown(
            button: .right,
            point: DesktopPoint(x: 50, y: 60)
        )

        var keys = RDPDesktopPhysicalKeyState()
        keys.recordKeyDown(keyCode: 123, name: "left")
        keys.recordKeyDown(keyCode: 51, name: "backspace")

        var text = RDPDesktopTextInputState()
        _ = text.setMarkedText(
            "unfinished",
            selectedRange: NSRange(location: 10, length: 0)
        )

        let release = RDPDesktopInputReleasePlan.drain(
            pointerState: &pointers,
            physicalKeyState: &keys,
            textInputState: &text
        )
        #expect(release.pointerReleases == [
            RDPDesktopPointerRelease(
                button: .left,
                point: DesktopPoint(x: 30, y: 40)
            ),
            RDPDesktopPointerRelease(
                button: .right,
                point: DesktopPoint(x: 50, y: 60)
            ),
        ])
        #expect(release.physicalKeyNames == ["backspace", "left"])
        #expect(release.discardedMarkedText)
        #expect(pointers.isEmpty)
        #expect(keys.isEmpty)
        #expect(!text.hasMarkedText)

        let repeatedRelease = RDPDesktopInputReleasePlan.drain(
            pointerState: &pointers,
            physicalKeyState: &keys,
            textInputState: &text
        )
        #expect(repeatedRelease.pointerReleases.isEmpty)
        #expect(repeatedRelease.physicalKeyNames.isEmpty)
        #expect(!repeatedRelease.discardedMarkedText)
    }

    @Test func desktopPointerMouseUpPreventsDuplicateSyntheticRelease() {
        var pointers = RDPDesktopPressedPointerState()
        pointers.recordMouseDown(
            button: .middle,
            point: DesktopPoint(x: 70, y: 80)
        )
        #expect(
            pointers.lastPoint(for: .middle) == DesktopPoint(x: 70, y: 80)
        )
        let recordedMouseUp = pointers.recordMouseUp(button: .middle)
        #expect(recordedMouseUp)
        #expect(pointers.lastPoint(for: .middle) == nil)
        let releasesAfterPhysicalMouseUp = pointers.releaseAll()
        #expect(releasesAfterPhysicalMouseUp.isEmpty)
    }

    @Test func syntheticPointerReleaseSuppressesTheLatePhysicalMouseUp() {
        var pointers = RDPDesktopPressedPointerState()
        pointers.recordMouseDown(
            button: .left,
            point: DesktopPoint(x: 70, y: 80)
        )

        let syntheticReleases = pointers.releaseAll()
        #expect(syntheticReleases == [
            RDPDesktopPointerRelease(
                button: .left,
                point: DesktopPoint(x: 70, y: 80)
            ),
        ])
        let ignoredLateMouseUp = pointers.recordMouseUp(button: .left)
        #expect(!ignoredLateMouseUp)

        pointers.recordMouseDown(
            button: .left,
            point: DesktopPoint(x: 90, y: 100)
        )
        let recordedNewMouseUp = pointers.recordMouseUp(button: .left)
        #expect(recordedNewMouseUp)
    }

    @Test func syntheticPointerReleaseClampsToTheCurrentFramebuffer() {
        let oldFramebufferRelease = RDPDesktopPointerRelease(
            button: .right,
            point: DesktopPoint(x: 1_919, y: 1_079)
        )

        #expect(
            oldFramebufferRelease.clamped(
                pixelWidth: 800,
                pixelHeight: 600
            ) == RDPDesktopPointerRelease(
                button: .right,
                point: DesktopPoint(x: 799, y: 599)
            )
        )
        #expect(
            RDPDesktopPointerRelease(
                button: .left,
                point: DesktopPoint(x: -50, y: -10)
            ).clamped(
                pixelWidth: 800,
                pixelHeight: 600
            ) == RDPDesktopPointerRelease(
                button: .left,
                point: DesktopPoint(x: 0, y: 0)
            )
        )
        #expect(
            oldFramebufferRelease.clamped(
                pixelWidth: 0,
                pixelHeight: 600
            ) == nil
        )
    }

    @Test func narrowControlBarUsesStableTwoColumnCriticalActionRows() {
        let actions: [RDPDesktopControlBarCriticalAction] = [
            .aiAccess,
            .takeControl,
            .emergencyStop,
            .disconnect,
        ]
        #expect(
            RDPDesktopControlBarPolicy.narrowCriticalActionRows(actions) == [
                [.aiAccess, .takeControl],
                [.emergencyStop, .disconnect],
            ]
        )
        #expect(
            RDPDesktopControlBarPolicy.narrowCriticalActionRows(
                [.aiAccess, .connect]
            ) == [[.aiAccess, .connect]]
        )
        #expect(
            RDPDesktopControlBarPolicy.narrowCriticalActionRows(
                [.aiAccess, .takeControl, .emergencyStop]
            ) == [
                [.aiAccess, .takeControl],
                [.emergencyStop],
            ]
        )
        #expect(
            RDPDesktopControlBarPolicy.narrowCriticalActionRows(
                [.takeControl, .emergencyStop, .disconnect]
            ) == [
                [.takeControl, .emergencyStop],
                [.disconnect],
            ]
        )
        #expect(
            RDPDesktopControlBarPolicy.narrowCriticalActionRows(
                [.connect]
            ) == [[.connect]]
        )
        #expect(
            RDPDesktopControlBarPolicy.narrowCriticalActionRows([]).isEmpty
        )
    }

    @Test func desktopKeyboardKeepsChordsAndUncomposedCommandsPhysical() {
        let chordFlags: [NSEvent.ModifierFlags] = [
            [.control],
            [.option],
            [.command],
            [.control, .shift],
            [.option, .command],
        ]
        for flags in chordFlags {
            #expect(
                !RDPDesktopKeyboardInputRouting.shouldInterpretTextInput(
                    characters: "c",
                    modifierFlags: flags,
                    hasMarkedText: true
                )
            )
        }

        for characters in ["", "\r", "\t", "\u{7F}", "\u{F700}"] {
            #expect(
                !RDPDesktopKeyboardInputRouting.shouldInterpretTextInput(
                    characters: characters,
                    modifierFlags: [],
                    hasMarkedText: false
                )
            )
        }
        #expect(
            !RDPDesktopKeyboardInputRouting.shouldInterpretTextInput(
                characters: nil,
                modifierFlags: [],
                hasMarkedText: false
            )
        )

        for (keyCode, characters) in [(36, "\r"), (48, "\t"), (51, "\u{7F}")] {
            var routing = RDPDesktopKeyboardInputRouting()
            let keyDownRoute = routing.keyDownRoute(
                keyCode: UInt16(keyCode),
                characters: characters,
                modifierFlags: [],
                hasPhysicalKey: true,
                hasMarkedText: false
            )
            let sendsPhysicalKeyUp = routing.shouldSendPhysicalKeyUp(
                keyCode: UInt16(keyCode),
                hasPhysicalKey: true
            )
            #expect(keyDownRoute == .physicalKey)
            #expect(sendsPhysicalKeyUp)
        }
    }

    @Test func desktopKeyboardMapsMacClipboardShortcutsToOneWindowsControlChord() {
        let shortcuts: [(UInt16, String)] = [
            (8, "c"),
            (9, "v"),
            (7, "x"),
        ]

        for (keyCode, character) in shortcuts {
            var routing = RDPDesktopKeyboardInputRouting()
            let route = routing.keyDownRoute(
                keyCode: keyCode,
                characters: character,
                charactersIgnoringModifiers: character,
                modifierFlags: [.command],
                hasPhysicalKey: true,
                hasMarkedText: false
            )
            #expect(route == .remoteChord(modifiers: ["control"]))
            let sendsPhysicalKeyUp = routing.shouldSendPhysicalKeyUp(
                keyCode: keyCode,
                hasPhysicalKey: true
            )
            #expect(!sendsPhysicalKeyUp)
        }

        for flags in [
            NSEvent.ModifierFlags.command.union(.shift),
            NSEvent.ModifierFlags.control,
            NSEvent.ModifierFlags.option.union(.command),
        ] {
            #expect(!RDPDesktopKeyboardInputRouting.shouldMapMacClipboardShortcut(
                characters: "c",
                modifierFlags: flags
            ))
        }
        #expect(!RDPDesktopKeyboardInputRouting.shouldMapMacClipboardShortcut(
            characters: "a",
            modifierFlags: [.command]
        ))
    }

    @Test func desktopKeyboardLetsActiveCompositionConsumeCommandsAndKeyUp() {
        var routing = RDPDesktopKeyboardInputRouting()

        let textKeyDown = routing.keyDownRoute(
            keyCode: 36,
            characters: "\r",
            modifierFlags: [],
            hasPhysicalKey: true,
            hasMarkedText: true
        )
        #expect(textKeyDown == .textInput)
        let textKeyUpIsPhysical = routing.shouldSendPhysicalKeyUp(
            keyCode: 36,
            hasPhysicalKey: true
        )
        #expect(!textKeyUpIsPhysical)

        let chordKeyDown = routing.keyDownRoute(
            keyCode: 8,
            characters: "c",
            modifierFlags: [.control],
            hasPhysicalKey: true,
            hasMarkedText: true
        )
        #expect(chordKeyDown == .physicalKey)
        let chordKeyUpIsPhysical = routing.shouldSendPhysicalKeyUp(
            keyCode: 8,
            hasPhysicalKey: true
        )
        #expect(chordKeyUpIsPhysical)

        let arrowKeyDown = routing.keyDownRoute(
            keyCode: 126,
            characters: "\u{F700}",
            modifierFlags: [],
            hasPhysicalKey: true,
            hasMarkedText: false
        )
        #expect(arrowKeyDown == .physicalKey)
        let arrowKeyUpIsPhysical = routing.shouldSendPhysicalKeyUp(
            keyCode: 126,
            hasPhysicalKey: true
        )
        #expect(arrowKeyUpIsPhysical)
    }

    @Test func controlGrantExpiresAfterFifteenMinutesOfInactivity() {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        var grant = RemoteClientGrant(
            clientID: "codex",
            targetID: UUID(),
            capabilities: [.desktopControl],
            issuedAt: issuedAt,
            externalDataConsentAt: issuedAt
        )
        let policy = RemoteCapabilityGrantPolicy(
            permissionPolicy: RemoteTargetPermissionPolicy(
                maximumCapabilities: [.desktopControl]
            )
        )

        #expect(policy.authorizeAndTouch(
            grant: &grant,
            capability: .desktopControl,
            at: issuedAt.addingTimeInterval(899)
        ).isAllowed)

        let expired = policy.authorize(
            grant: grant,
            capability: .desktopControl,
            at: grant.lastUsedAt.addingTimeInterval(900)
        )
        #expect(expired == .denied(
            code: .leaseExpired,
            message: "The AI control lease expired after 900 seconds of inactivity."
        ))
    }

    @Test func persistentClientGrantRequiresExplicitExternalDataConsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-test-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let displayIdentity = "Codex · …22222222"
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .desktopObserve, .desktopControl]
        )

        do {
            _ = try store.authorize(
                clientID: "codex@2.0",
                clientDisplayIdentity: displayIdentity,
                targetID: targetID,
                capabilities: [.desktopObserve],
                policy: policy
            )
            Issue.record("A first-time external observation request must wait for approval")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
            #expect(failure.pendingRequestID != nil)
        }

        let request = try #require(store.pendingRequests(targetID: targetID).first)
        #expect(request.requiresExternalDataConsent)
        #expect(request.clientDisplayIdentity == displayIdentity)
        do {
            _ = try store.approve(
                requestID: request.id,
                policy: policy,
                consentToExternalData: false
            )
            Issue.record("External data access must not be approved without explicit consent")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue)
        }

        let approved = try store.approve(
            requestID: request.id,
            policy: policy,
            consentToExternalData: true
        )
        #expect(approved.externalDataConsentAt != nil)
        #expect(approved.consentedExternalDataTypes == [.desktopImage])
        #expect(approved.clientDisplayIdentity == displayIdentity)
        let authorization = try store.authorize(
            clientID: "codex@2.0",
            clientDisplayIdentity: displayIdentity,
            targetID: targetID,
            capabilities: [.desktopObserve],
            policy: policy
        )
        #expect(authorization.capabilities == [.desktopObserve])
        #expect(authorization.clientDisplayIdentity == displayIdentity)

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        #expect(reloaded.activeGrants(targetID: targetID).count == 1)
        #expect(reloaded.activeGrants(targetID: targetID).first?.clientID == "codex@2.0")
        #expect(reloaded.activeGrants(targetID: targetID).first?.clientDisplayIdentity == displayIdentity)
        #expect(reloaded.activeGrants(targetID: targetID).first?.consentedExternalDataTypes == [.desktopImage])
    }

    @Test func grantStoreClearsInheritedACLsAndRejectsACLExposedState() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-acl-\(UUID().uuidString)", isDirectory: true)
        let securityDirectory = parent.appendingPathComponent("Security", isDirectory: true)
        let storageURL = securityDirectory.appendingPathComponent("grants.json")
        let lockURL = storageURL.appendingPathExtension("lock")
        let revocationDirectory = securityDirectory
            .appendingPathComponent("ControlRevocations", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try installExtendedACL(at: parent, inheritable: true)

        let targetID = UUID()
        let clientID = "acl-control-client"
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .desktopControl]
        )
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery, .desktopControl],
            policy: policy,
            at: Date(timeIntervalSince1970: 120_000)
        )
        try approved.store.invalidateControlAuthority(targetID: targetID)
        let markerURL = revocationDirectory.appendingPathComponent(
            "\(targetID.uuidString.lowercased()).revoked"
        )

        try PrivateFileSecurity.verifyPrivateDirectory(at: securityDirectory)
        try PrivateFileSecurity.verifyPrivateFile(at: storageURL)
        try PrivateFileSecurity.verifyPrivateFile(at: lockURL)
        try PrivateFileSecurity.verifyPrivateDirectory(at: revocationDirectory)
        try PrivateFileSecurity.verifyPrivateFile(at: markerURL)

        try installExtendedACL(at: storageURL)
        let exposedStore = RemoteClientGrantStore(storageURL: storageURL)
        #expect(exposedStore.grants.isEmpty)
        #expect(exposedStore.pendingRequests.isEmpty)
        #expect(exposedStore.persistenceError?.contains("ACL") == true)

        try secureTestFile(at: storageURL)
        try installExtendedACL(at: lockURL)
        let repairedLockStore = RemoteClientGrantStore(storageURL: storageURL)
        #expect(repairedLockStore.persistenceError == nil)
        try PrivateFileSecurity.verifyPrivateFile(at: lockURL)

        try installExtendedACL(at: markerURL)
        do {
            _ = try repairedLockStore.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(timeIntervalSince1970: 120_001)
            )
            Issue.record("An ACL-exposed revocation marker must fail closed.")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_STORE_UNAVAILABLE")
        }
    }

    @Test func fileContentRequiresAdditionalConsentAfterFileMetadataConsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-file-data-consent-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let clientID = "codex-file-client"
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.fileAccess])
        let startedAt = Date(timeIntervalSince1970: 80_000)

        let metadataRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileMetadata],
            policy: policy,
            at: startedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        #expect(metadataRequest.externalDataTypes == [.fileMetadata])
        let metadataGrant = try store.approve(
            requestID: metadataRequest.id,
            policy: policy,
            consentToExternalData: true,
            at: startedAt
        )
        #expect(metadataGrant.consentedExternalDataTypes == [.fileMetadata])

        let contentRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileContent],
            policy: policy,
            at: startedAt.addingTimeInterval(1),
            expectedDenialCode: RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue
        )
        #expect(contentRequest.reason == .externalDataConsent)
        #expect(contentRequest.externalDataTypes == [.fileContent])
        let expandedGrant = try store.approve(
            requestID: contentRequest.id,
            policy: policy,
            consentToExternalData: true,
            at: startedAt.addingTimeInterval(1)
        )
        #expect(expandedGrant.consentedExternalDataTypes == [.fileMetadata, .fileContent])

        let authorization = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: [.fileAccess],
            policy: policy,
            externalDataTypes: [.fileContent],
            at: startedAt.addingTimeInterval(2)
        )
        #expect(authorization.grantID == expandedGrant.grantID)
        #expect(store.pendingRequests(targetID: targetID).isEmpty)
    }

    @Test func terminalOutputRequiresAdditionalConsentAfterCommandOutputConsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-command-data-consent-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let clientID = "claude-command-client"
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.commandExecution])
        let startedAt = Date(timeIntervalSince1970: 90_000)

        let commandRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.commandExecution],
            externalDataTypes: [.commandOutput],
            policy: policy,
            at: startedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        let commandGrant = try store.approve(
            requestID: commandRequest.id,
            policy: policy,
            consentToExternalData: true,
            at: startedAt
        )
        #expect(commandGrant.consentedExternalDataTypes == [.commandOutput])

        let terminalRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.commandExecution],
            externalDataTypes: [.terminalOutput],
            policy: policy,
            at: startedAt.addingTimeInterval(1),
            expectedDenialCode: RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue
        )
        #expect(terminalRequest.reason == .externalDataConsent)
        #expect(terminalRequest.externalDataTypes == [.terminalOutput])
        let expandedGrant = try store.approve(
            requestID: terminalRequest.id,
            policy: policy,
            consentToExternalData: true,
            at: startedAt.addingTimeInterval(1)
        )
        #expect(expandedGrant.consentedExternalDataTypes == [.commandOutput, .terminalOutput])

        _ = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: [.commandExecution],
            policy: policy,
            externalDataTypes: [.terminalOutput],
            at: startedAt.addingTimeInterval(2)
        )
        #expect(store.pendingRequests(targetID: targetID).isEmpty)
    }

    @Test func externalDataConsentIsIsolatedByClientAndTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-data-consent-isolation-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let firstTargetID = UUID()
        let secondTargetID = UUID()
        let firstClientID = "codex-isolated-client"
        let secondClientID = "claude-isolated-client"
        let noConsentPolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.fileAccess],
            requireExternalDataConsent: false
        )
        let consentPolicy = RemoteTargetPermissionPolicy(maximumCapabilities: [.fileAccess])
        let startedAt = Date(timeIntervalSince1970: 100_000)

        for (offset, identity) in [
            (firstClientID, firstTargetID),
            (secondClientID, firstTargetID),
            (firstClientID, secondTargetID),
        ].enumerated() {
            let request = try requireGrantRequest(
                store: store,
                clientID: identity.0,
                targetID: identity.1,
                capabilities: [.fileAccess],
                externalDataTypes: [],
                policy: noConsentPolicy,
                at: startedAt.addingTimeInterval(Double(offset)),
                expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
            )
            let grant = try store.approve(
                requestID: request.id,
                policy: noConsentPolicy,
                consentToExternalData: false,
                at: startedAt.addingTimeInterval(Double(offset))
            )
            #expect(grant.consentedExternalDataTypes.isEmpty)
        }

        let approvedRequest = try requireGrantRequest(
            store: store,
            clientID: firstClientID,
            targetID: firstTargetID,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileMetadata],
            policy: consentPolicy,
            at: startedAt.addingTimeInterval(10),
            expectedDenialCode: RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue
        )
        let approvedGrant = try store.approve(
            requestID: approvedRequest.id,
            policy: consentPolicy,
            consentToExternalData: true,
            at: startedAt.addingTimeInterval(10)
        )
        #expect(approvedGrant.consentedExternalDataTypes == [.fileMetadata])

        for (offset, identity) in [
            (secondClientID, firstTargetID),
            (firstClientID, secondTargetID),
        ].enumerated() {
            let isolatedRequest = try requireGrantRequest(
                store: store,
                clientID: identity.0,
                targetID: identity.1,
                capabilities: [.fileAccess],
                externalDataTypes: [.fileMetadata],
                policy: consentPolicy,
                at: startedAt.addingTimeInterval(20 + Double(offset)),
                expectedDenialCode: RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue
            )
            #expect(isolatedRequest.reason == .externalDataConsent)
            #expect(isolatedRequest.externalDataTypes == [.fileMetadata])
        }

        _ = try store.authorize(
            clientID: firstClientID,
            targetID: firstTargetID,
            capabilities: [.fileAccess],
            policy: consentPolicy,
            externalDataTypes: [.fileMetadata],
            at: startedAt.addingTimeInterval(30)
        )
    }

    @Test func legacyTimestampOnlyExternalDataConsentFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-data-consent-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetID = UUID()
        let grantID = UUID()
        let clientID = "legacy-file-client"
        let legacyJSON = """
        {
          "formatVersion": 1,
          "grants": [{
            "grantID": "\(grantID.uuidString)",
            "clientID": "\(clientID)",
            "targetID": "\(targetID.uuidString)",
            "capabilities": ["fileAccess"],
            "issuedAt": 0,
            "lastUsedAt": 0,
            "absoluteExpiration": null,
            "revokedAt": null,
            "externalDataConsentAt": 123
          }],
          "pendingRequests": []
        }
        """
        try legacyJSON.write(to: storageURL, atomically: true, encoding: .utf8)
        try secureTestFile(at: storageURL)

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let legacyGrant = try #require(store.activeGrants(targetID: targetID).first)
        #expect(legacyGrant.externalDataConsentAt == nil)
        #expect(legacyGrant.consentedExternalDataTypes.isEmpty)

        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.fileAccess])
        let request = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileMetadata],
            policy: policy,
            at: Date(timeIntervalSince1970: 110_000),
            expectedDenialCode: RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue
        )
        #expect(request.reason == .externalDataConsent)
        #expect(request.externalDataTypes == [.fileMetadata])
        let migratedGrant = try store.approve(
            requestID: request.id,
            policy: policy,
            consentToExternalData: true,
            at: Date(timeIntervalSince1970: 110_001)
        )
        #expect(migratedGrant.consentedExternalDataTypes == [.fileMetadata])

        let persistedRoot = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
        )
        let persistedGrants = try #require(persistedRoot["grants"] as? [[String: Any]])
        let persistedGrant = try #require(persistedGrants.first)
        #expect(
            Set(persistedGrant["consentedExternalDataTypes"] as? [String] ?? [])
                == [RemoteExternalDataType.fileMetadata.rawValue]
        )

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        _ = try reloaded.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: [.fileAccess],
            policy: policy,
            externalDataTypes: [.fileMetadata],
            at: Date(timeIntervalSince1970: 110_002)
        )
        let contentRequest = try requireGrantRequest(
            store: reloaded,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileContent],
            policy: policy,
            at: Date(timeIntervalSince1970: 110_003),
            expectedDenialCode: RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue
        )
        #expect(contentRequest.externalDataTypes == [.fileContent])
    }

    @Test func legacyGrantFilesGainASafeClientDisplayIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-grant-identity-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targetID = UUID()
        let grantID = UUID()
        let registrationID = "22222222-2222-4222-8222-222222222222"
        let clientID = "mcp-registration:\(registrationID)"
        let legacyJSON = """
        {
          "formatVersion": 1,
          "grants": [{
            "grantID": "\(grantID.uuidString)",
            "clientID": "\(clientID)",
            "targetID": "\(targetID.uuidString)",
            "capabilities": ["discovery"],
            "issuedAt": 0,
            "lastUsedAt": 0,
            "absoluteExpiration": null,
            "revokedAt": null,
            "externalDataConsentAt": null
          }],
          "pendingRequests": []
        }
        """
        try legacyJSON.write(to: storageURL, atomically: true, encoding: .utf8)
        try secureTestFile(at: storageURL)

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let grant = try #require(store.activeGrants(targetID: targetID).first)
        #expect(grant.clientID == clientID)
        #expect(grant.clientDisplayIdentity == "Registered MCP client · …22222222")
        #expect(grant.consentedExternalDataTypes.isEmpty)
    }

    @Test func observationDoesNotKeepControlLeaseAlive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-lease-test-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopObserve, .desktopControl]
        )
        let issuedAt = Date(timeIntervalSince1970: 1_000)

        do {
            _ = try store.authorize(
                clientID: "claude@1",
                targetID: targetID,
                capabilities: [.desktopObserve, .desktopControl],
                policy: policy,
                at: issuedAt
            )
        } catch { }
        let request = try #require(store.pendingRequests(targetID: targetID).first)
        _ = try store.approve(
            requestID: request.id,
            policy: policy,
            consentToExternalData: true,
            at: issuedAt
        )

        _ = try store.authorize(
            clientID: "claude@1",
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: issuedAt.addingTimeInterval(800)
        )
        _ = try store.authorize(
            clientID: "claude@1",
            targetID: targetID,
            capabilities: [.desktopObserve],
            policy: policy,
            at: issuedAt.addingTimeInterval(1_699)
        )

        do {
            _ = try store.authorize(
                clientID: "claude@1",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: issuedAt.addingTimeInterval(1_701)
            )
            Issue.record("Observation must not extend the 15-minute Control lease")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
            #expect(store.pendingRequests(targetID: targetID).first?.reason == .controlLeaseRenewal)
        }
    }

    @Test func persistentSSHTargetApprovalGrantsConfiguredAccessOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-persistent-ssh-grant-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let clientID = "registered-ssh-client"
        let approvedAt = Date(timeIntervalSince1970: 120_000)
        let request = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery],
            externalDataTypes: [.targetMetadata],
            policy: .sshDefault,
            at: approvedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )

        let grant = try store.approve(
            requestID: request.id,
            policy: .sshDefault,
            consentToExternalData: true,
            grantPersistentTargetAccess: true,
            at: approvedAt
        )
        #expect(grant.capabilities == RemoteTargetPermissionPolicy.sshDefault.maximumCapabilities)
        #expect(grant.consentedExternalDataTypes == [
            .targetMetadata,
            .commandOutput,
            .terminalOutput,
            .fileMetadata,
            .fileContent,
        ])

        let authorization = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: RemoteTargetPermissionPolicy.sshDefault.maximumCapabilities,
            policy: .sshDefault,
            externalDataTypes: grant.consentedExternalDataTypes,
            at: approvedAt.addingTimeInterval(365 * 24 * 60 * 60)
        )
        #expect(authorization.controlLeaseExpiresAt == nil)
        #expect(store.pendingRequests.isEmpty)
    }

    @Test func persistentRDPTargetApprovalSurvivesYearReloadAndExplicitRevocation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-persistent-rdp-grant-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let targetID = target.targetID
        let targetBinding = target.mcpGrantTargetBinding
        let clientID = "registered-rdp-client"
        let approvedAt = Date(timeIntervalSince1970: 123_000)
        let policy = RemoteTargetPermissionPolicy.rdpDefault
        let request = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.desktopControl],
            externalDataTypes: [],
            policy: policy,
            at: approvedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED",
            targetBinding: targetBinding
        )
        let grant = try store.approve(
            requestID: request.id,
            policy: policy,
            consentToExternalData: true,
            grantPersistentTargetAccess: true,
            currentTargetBinding: targetBinding,
            at: approvedAt
        )
        let allExternalData = RemoteExternalDataPolicy.completeTypes(
            for: policy.maximumCapabilities
        )
        #expect(grant.capabilities == policy.maximumCapabilities)
        #expect(grant.consentedExternalDataTypes == allExternalData)
        #expect(grant.controlRevocationToken == nil)

        let oneYearLater = approvedAt.addingTimeInterval(365 * 24 * 60 * 60)
        let authorization = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            targetBinding: targetBinding,
            capabilities: policy.maximumCapabilities,
            policy: policy,
            externalDataTypes: allExternalData,
            at: oneYearLater
        )
        #expect(authorization.controlLeaseExpiresAt == nil)
        #expect(store.pendingRequests(
            targetID: targetID,
            targetBinding: targetBinding
        ).isEmpty)

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        let reloadedAuthorization = try reloaded.authorize(
            clientID: clientID,
            targetID: targetID,
            targetBinding: targetBinding,
            capabilities: policy.maximumCapabilities,
            policy: policy,
            externalDataTypes: allExternalData,
            at: oneYearLater.addingTimeInterval(1)
        )
        #expect(reloadedAuthorization.grantID == grant.grantID)
        #expect(reloadedAuthorization.controlLeaseExpiresAt == nil)
        #expect(reloaded.pendingRequests(
            targetID: targetID,
            targetBinding: targetBinding
        ).isEmpty)

        try reloaded.revoke(
            grantID: grant.grantID,
            at: oneYearLater.addingTimeInterval(2)
        )
        do {
            _ = try reloaded.authorize(
                clientID: clientID,
                targetID: targetID,
                targetBinding: targetBinding,
                capabilities: [.desktopControl],
                policy: policy,
                externalDataTypes: [],
                at: oneYearLater.addingTimeInterval(3)
            )
            Issue.record("Explicit revoke must invalidate persistent RDP authority")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
        #expect(reloaded.activeGrants(
            targetID: targetID,
            targetBinding: targetBinding
        ).isEmpty)
        #expect(reloaded.pendingRequests(
            targetID: targetID,
            targetBinding: targetBinding
        ).count == 1)
    }

    @Test func endpointChangeCreatesANewGrantWithoutTransferringOldControl() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-target-bound-grant-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let target = RemoteSession(
            name: "Windows",
            host: "endpoint-a.test",
            username: "operator",
            connectionType: .rdp
        )
        let clientID = "registered-target-bound-client"
        let approvedAt = Date(timeIntervalSince1970: 124_000)
        let bindingA = target.mcpGrantTargetBinding
        let requestA = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: target.targetID,
            capabilities: [.desktopControl],
            externalDataTypes: [],
            policy: .rdpDefault,
            at: approvedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED",
            targetBinding: bindingA
        )
        let grantA = try store.approve(
            requestID: requestA.id,
            policy: .rdpDefault,
            consentToExternalData: true,
            grantPersistentTargetAccess: true,
            currentTargetBinding: bindingA,
            at: approvedAt
        )

        target.host = "endpoint-b.test"
        var narrowedProfile = target.rdpProfile
        narrowedProfile.persistentMCPControlEnabled = false
        try target.setRDPProfile(narrowedProfile)
        let bindingB = target.mcpGrantTargetBinding
        let narrowedPolicy = target.mcpPermissionPolicy
        #expect(bindingB != bindingA)
        #expect(
            narrowedPolicy.maximumCapabilities.isDisjoint(
                with: RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities
            )
        )

        let requestB = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: target.targetID,
            capabilities: [.discovery],
            externalDataTypes: [.targetMetadata],
            policy: narrowedPolicy,
            at: approvedAt.addingTimeInterval(1),
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED",
            targetBinding: bindingB
        )
        #expect(requestB.reason == .newGrant)
        let grantB = try store.approve(
            requestID: requestB.id,
            policy: narrowedPolicy,
            consentToExternalData: true,
            grantPersistentTargetAccess: true,
            currentTargetBinding: bindingB,
            at: approvedAt.addingTimeInterval(1)
        )

        #expect(grantB.grantID != grantA.grantID)
        #expect(grantB.targetBinding == bindingB)
        #expect(grantB.capabilities == narrowedPolicy.maximumCapabilities)
        #expect(
            grantB.capabilities.isDisjoint(
                with: RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities
            )
        )
        #expect(store.activeGrants(
            targetID: target.targetID,
            targetBinding: bindingA
        ).first?.grantID == grantA.grantID)
        #expect(store.activeGrants(
            targetID: target.targetID,
            targetBinding: bindingA
        ).first?.capabilities == RemoteTargetPermissionPolicy.rdpDefault.maximumCapabilities)

        narrowedProfile.persistentMCPControlEnabled = true
        try target.setRDPProfile(narrowedProfile)
        do {
            _ = try store.authorize(
                clientID: clientID,
                targetID: target.targetID,
                targetBinding: bindingB,
                capabilities: [.desktopControl],
                policy: target.mcpPermissionPolicy,
                externalDataTypes: [],
                at: approvedAt.addingTimeInterval(2)
            )
            Issue.record("Endpoint B must not inherit endpoint A's control authority")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
        #expect(store.pendingRequests(
            targetID: target.targetID,
            targetBinding: bindingB
        ).first?.reason == .capabilityExpansion)
    }

    @Test func approvalRejectsARequestWhenTheTargetBindingChanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-binding-toctou-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let targetID = UUID()
        let bindingA = String(repeating: "a", count: 64)
        let bindingB = String(repeating: "b", count: 64)
        let request = try requireGrantRequest(
            store: store,
            clientID: "registered-binding-client",
            targetID: targetID,
            capabilities: [.discovery],
            externalDataTypes: [.targetMetadata],
            policy: .rdpDefault,
            at: Date(timeIntervalSince1970: 124_500),
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED",
            targetBinding: bindingA
        )

        do {
            _ = try store.approve(
                requestID: request.id,
                policy: .rdpDefault,
                consentToExternalData: true,
                grantPersistentTargetAccess: true,
                currentTargetBinding: bindingB
            )
            Issue.record("A stale approval request must not authorize a changed endpoint")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "TARGET_BINDING_CHANGED")
        }
        #expect(store.pendingRequests(
            targetID: targetID,
            targetBinding: bindingA
        ).isEmpty)
        #expect(store.activeGrants(
            targetID: targetID,
            targetBinding: bindingA
        ).isEmpty)
        #expect(store.activeGrants(
            targetID: targetID,
            targetBinding: bindingB
        ).isEmpty)
    }

    @Test func legacySSHControlLeasePendingIsRemovedByCurrentPersistentPolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-ssh-lease-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let clientID = "registered-legacy-ssh-client"
        let issuedAt = Date(timeIntervalSince1970: 125_000)
        let legacyPolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: RemoteTargetPermissionPolicy.sshDefault.maximumCapabilities,
            controlLeaseCapabilities: [.commandExecution, .destructiveOperations]
        )
        let allExternalData = RemoteExternalDataPolicy.completeTypes(
            for: legacyPolicy.maximumCapabilities
        )
        let initialRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: legacyPolicy.maximumCapabilities,
            externalDataTypes: allExternalData,
            policy: legacyPolicy,
            at: issuedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        let grant = try store.approve(
            requestID: initialRequest.id,
            policy: legacyPolicy,
            consentToExternalData: true,
            at: issuedAt
        )
        #expect(grant.capabilities == legacyPolicy.maximumCapabilities)
        #expect(grant.consentedExternalDataTypes == allExternalData)

        do {
            _ = try store.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.commandExecution, .destructiveOperations],
                policy: legacyPolicy,
                externalDataTypes: [],
                at: issuedAt.addingTimeInterval(901)
            )
            Issue.record("The legacy SSH control lease must expire before migration.")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        let staleRequest = try #require(store.pendingRequests(targetID: targetID).first)
        #expect(staleRequest.reason == .controlLeaseRenewal)
        #expect(staleRequest.requestedCapabilities == [.commandExecution, .destructiveOperations])

        #expect(try store.reconcileResolvedPendingRequests(
            targetID: targetID,
            policy: .sshDefault,
            at: issuedAt.addingTimeInterval(902)
        ))
        #expect(store.pendingRequests(targetID: targetID).isEmpty)

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        #expect(reloaded.pendingRequests(targetID: targetID).isEmpty)
        #expect(reloaded.activeGrants(targetID: targetID).first?.grantID == grant.grantID)
        let authorization = try reloaded.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery],
            policy: .sshDefault,
            externalDataTypes: [.targetMetadata],
            at: issuedAt.addingTimeInterval(903)
        )
        #expect(authorization.controlLeaseExpiresAt == nil)

        do {
            _ = try reloaded.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.commandExecution, .destructiveOperations],
                policy: legacyPolicy,
                externalDataTypes: [],
                at: issuedAt.addingTimeInterval(1_804)
            )
            Issue.record("The recreated legacy SSH control lease must be expired.")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        #expect(reloaded.pendingRequests(targetID: targetID).count == 1)
        _ = try reloaded.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery],
            policy: .sshDefault,
            externalDataTypes: [.targetMetadata],
            at: issuedAt.addingTimeInterval(1_805)
        )
        #expect(reloaded.pendingRequests(targetID: targetID).isEmpty)
        #expect(RemoteClientGrantStore(storageURL: storageURL).pendingRequests(targetID: targetID).isEmpty)
    }

    @Test func legacyUnboundRDPLeaseRequiresFreshExactTargetAlwaysAllow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-rdp-lease-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let targetID = target.targetID
        let currentBinding = target.mcpGrantTargetBinding
        let clientID = "registered-legacy-rdp-client"
        let issuedAt = Date(timeIntervalSince1970: 125_250)
        let persistentPolicy = RemoteTargetPermissionPolicy.rdpDefault
        let legacyPolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: persistentPolicy.maximumCapabilities,
            controlLeaseCapabilities:
                RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities
        )
        let allExternalData = RemoteExternalDataPolicy.completeTypes(
            for: legacyPolicy.maximumCapabilities
        )
        let initialRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: legacyPolicy.maximumCapabilities,
            externalDataTypes: allExternalData,
            policy: legacyPolicy,
            at: issuedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        let legacyGrant = try store.approve(
            requestID: initialRequest.id,
            policy: legacyPolicy,
            consentToExternalData: true,
            at: issuedAt
        )
        let legacyControlRevocationToken = legacyGrant.controlRevocationToken
        #expect(legacyGrant.targetBinding == nil)
        #expect(legacyGrant.capabilities == legacyPolicy.maximumCapabilities)

        do {
            _ = try store.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities:
                    RemoteTargetPermissionPolicy.rdp2PersistentControlCapabilities,
                policy: legacyPolicy,
                externalDataTypes: [],
                at: issuedAt.addingTimeInterval(901)
            )
            Issue.record("The legacy RDP control lease must expire before migration")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        #expect(
            store.pendingRequests(targetID: targetID).first?.reason
                == .controlLeaseRenewal
        )

        #expect(try store.reconcileResolvedPendingRequests(
            targetID: targetID,
            policy: persistentPolicy,
            targetBinding: currentBinding,
            at: issuedAt.addingTimeInterval(902)
        ))
        #expect(store.pendingRequests(
            targetID: targetID,
            targetBinding: currentBinding
        ).isEmpty)
        #expect(store.activeGrants(
            targetID: targetID,
            targetBinding: currentBinding
        ).isEmpty)
        #expect(
            store.activeGrants(targetID: targetID).first?.controlRevocationToken
                == legacyControlRevocationToken
        )

        do {
            _ = try store.authorize(
                clientID: clientID,
                targetID: targetID,
                targetBinding: currentBinding,
                capabilities: persistentPolicy.maximumCapabilities,
                policy: persistentPolicy,
                externalDataTypes: allExternalData,
                at: issuedAt.addingTimeInterval(903)
            )
            Issue.record("A legacy unbound grant must not become persistent exact-target access")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
        let replacementRequest = try #require(store.pendingRequests(
            targetID: targetID,
            targetBinding: currentBinding
        ).first)
        #expect(replacementRequest.reason == .newGrant)
        let exactTargetGrant = try store.approve(
            requestID: replacementRequest.id,
            policy: persistentPolicy,
            consentToExternalData: true,
            grantPersistentTargetAccess: true,
            currentTargetBinding: currentBinding,
            at: issuedAt.addingTimeInterval(904)
        )
        #expect(exactTargetGrant.grantID != legacyGrant.grantID)
        #expect(exactTargetGrant.targetBinding == currentBinding)
        #expect(exactTargetGrant.controlRevocationToken == nil)

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        let authorization = try reloaded.authorize(
            clientID: clientID,
            targetID: targetID,
            targetBinding: currentBinding,
            capabilities: persistentPolicy.maximumCapabilities,
            policy: persistentPolicy,
            externalDataTypes: allExternalData,
            at: issuedAt.addingTimeInterval(365 * 24 * 60 * 60)
        )
        #expect(authorization.grantID == exactTargetGrant.grantID)
        #expect(authorization.controlLeaseExpiresAt == nil)
        #expect(reloaded.pendingRequests(
            targetID: targetID,
            targetBinding: currentBinding
        ).isEmpty)
    }

    @Test func registeredLegacyPersistentGrantMigratesOnceToExactTargetBinding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-persistent-binding-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        let targetID = target.targetID
        let bindingA = target.mcpGrantTargetBinding
        let bindingB = String(repeating: "b", count: 64)
        let clientID = "mcp-registration:\(UUID().uuidString.lowercased())"
        let policy = RemoteTargetPermissionPolicy.rdpDefault
        let capabilities = policy.maximumCapabilities
        let externalDataTypes = RemoteExternalDataPolicy.completeTypes(for: capabilities)
        let issuedAt = Date(timeIntervalSince1970: 125_400)

        let legacyRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: capabilities,
            externalDataTypes: externalDataTypes,
            policy: policy,
            at: issuedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        let legacyGrant = try store.approve(
            requestID: legacyRequest.id,
            policy: policy,
            consentToExternalData: true,
            grantPersistentTargetAccess: true,
            at: issuedAt.addingTimeInterval(1)
        )
        #expect(legacyGrant.targetBinding == nil)
        #expect(legacyGrant.absoluteExpiration == nil)
        #expect(legacyGrant.controlRevocationToken == nil)

        _ = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            targetBinding: bindingA,
            capabilities: [.discovery],
            policy: policy,
            externalDataTypes: [.targetMetadata],
            at: issuedAt.addingTimeInterval(2)
        )
        let migratedGrant = try #require(store.activeGrants(
            targetID: targetID,
            targetBinding: bindingA,
            at: issuedAt.addingTimeInterval(2)
        ).first)
        #expect(migratedGrant.grantID == legacyGrant.grantID)
        #expect(store.pendingRequests(
            targetID: targetID,
            targetBinding: bindingA
        ).isEmpty)

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        let authorization = try reloaded.authorize(
            clientID: clientID,
            targetID: targetID,
            targetBinding: bindingA,
            capabilities: capabilities,
            policy: policy,
            externalDataTypes: externalDataTypes,
            at: issuedAt.addingTimeInterval(365 * 24 * 60 * 60)
        )
        #expect(authorization.grantID == legacyGrant.grantID)

        do {
            _ = try reloaded.authorize(
                clientID: clientID,
                targetID: targetID,
                targetBinding: bindingB,
                capabilities: [.discovery],
                policy: policy,
                externalDataTypes: [.targetMetadata],
                at: issuedAt.addingTimeInterval(365 * 24 * 60 * 60 + 1)
            )
            Issue.record("Changing an already migrated endpoint must require a new approval")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
    }

    @Test func policyObsoletePendingRequestIsRemovedWithoutAnActiveGrant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-obsolete-pending-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let broadPolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .fileAccess],
            controlLeaseCapabilities: []
        )
        let request = try requireGrantRequest(
            store: store,
            clientID: "registered-obsolete-client",
            targetID: targetID,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileMetadata],
            policy: broadPolicy,
            at: Date(timeIntervalSince1970: 125_500),
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        #expect(store.pendingRequests(targetID: targetID) == [request])

        let narrowedPolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery],
            controlLeaseCapabilities: []
        )
        #expect(try store.reconcileResolvedPendingRequests(
            targetID: targetID,
            policy: narrowedPolicy,
            at: Date(timeIntervalSince1970: 125_501)
        ))
        #expect(store.pendingRequests(targetID: targetID).isEmpty)
        #expect(RemoteClientGrantStore(storageURL: storageURL).pendingRequests(targetID: targetID).isEmpty)
    }

    @Test func reconciliationPreservesUnconsentedExternalDataRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-unconsented-pending-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let clientID = "registered-external-data-client"
        let issuedAt = Date(timeIntervalSince1970: 125_750)
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.fileAccess],
            controlLeaseCapabilities: []
        )
        let initialRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.fileAccess],
            externalDataTypes: [.fileMetadata],
            policy: policy,
            at: issuedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        _ = try store.approve(
            requestID: initialRequest.id,
            policy: policy,
            consentToExternalData: true,
            at: issuedAt
        )

        do {
            _ = try store.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.fileAccess],
                policy: policy,
                externalDataTypes: [.fileContent],
                at: issuedAt.addingTimeInterval(1)
            )
            Issue.record("New external data must require explicit consent.")
        } catch let failure as RemoteGrantGateFailure {
            #expect(
                failure.denialCode
                    == RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue
            )
        }
        let pending = try #require(store.pendingRequests(targetID: targetID).first)
        #expect(pending.reason == .externalDataConsent)
        #expect(pending.externalDataTypes == [.fileContent])

        #expect(try store.reconcileResolvedPendingRequests(
            targetID: targetID,
            policy: policy,
            at: issuedAt.addingTimeInterval(2)
        ) == false)
        #expect(store.pendingRequests(targetID: targetID) == [pending])
        #expect(RemoteClientGrantStore(storageURL: storageURL).pendingRequests(targetID: targetID) == [pending])
    }

    @Test func expiredLegacyControlLeaseRemainsPendingDuringReconciliation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-lease-reconcile-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let clientID = "registered-legacy-lease-client"
        let issuedAt = Date(timeIntervalSince1970: 126_000)
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .desktopControl]
        )
        let initialRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: policy.maximumCapabilities,
            externalDataTypes: [.targetMetadata],
            policy: policy,
            at: issuedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        _ = try store.approve(
            requestID: initialRequest.id,
            policy: policy,
            consentToExternalData: true,
            at: issuedAt
        )

        do {
            _ = try store.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                externalDataTypes: [],
                at: issuedAt.addingTimeInterval(901)
            )
            Issue.record("An expired legacy control lease must require visible renewal.")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        let renewal = try #require(store.pendingRequests(targetID: targetID).first)
        #expect(renewal.reason == .controlLeaseRenewal)
        #expect(renewal.requestedCapabilities == [.desktopControl])

        _ = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery],
            policy: policy,
            externalDataTypes: [.targetMetadata],
            at: issuedAt.addingTimeInterval(902)
        )
        #expect(try store.reconcileResolvedPendingRequests(
            targetID: targetID,
            policy: policy,
            at: issuedAt.addingTimeInterval(902)
        ) == false)
        #expect(store.pendingRequests(targetID: targetID) == [renewal])

        _ = try store.approve(
            requestID: renewal.id,
            policy: policy,
            consentToExternalData: false,
            at: issuedAt.addingTimeInterval(903)
        )
        let authorization = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            externalDataTypes: [],
            at: issuedAt.addingTimeInterval(904)
        )
        #expect(authorization.controlLeaseExpiresAt != nil)
        #expect(store.pendingRequests(targetID: targetID).isEmpty)
    }

    @Test func newLegacyControlScopeAfterInvalidationIsExpansionNotRenewal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-legacy-scope-expansion-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let clientID = "registered-legacy-expansion-client"
        let issuedAt = Date(timeIntervalSince1970: 127_000)
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .desktopObserve, .desktopControl]
        )
        let discoveryRequest = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery],
            externalDataTypes: [.targetMetadata],
            policy: policy,
            at: issuedAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        _ = try store.approve(
            requestID: discoveryRequest.id,
            policy: policy,
            consentToExternalData: true,
            at: issuedAt
        )
        try store.invalidateControlAuthority(targetID: targetID)

        let expansion = try requireGrantRequest(
            store: store,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.desktopObserve, .desktopControl],
            externalDataTypes: [.desktopImage],
            policy: policy,
            at: issuedAt.addingTimeInterval(1),
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        #expect(expansion.reason == .capabilityExpansion)
        #expect(expansion.requestedCapabilities == [.desktopObserve, .desktopControl])
        #expect(expansion.externalDataTypes == [.desktopImage])
    }

    @Test func identicalPendingRequestRetryDoesNotRewriteOrRenotify() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-pending-request-dedupe-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let firstAt = Date(timeIntervalSince1970: 130_000)
        let notificationCount = LockedInvocationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .jtsRDPGrantApprovalRequested,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let first = try requireGrantRequest(
            store: store,
            clientID: "stable-client",
            targetID: targetID,
            capabilities: [.discovery],
            externalDataTypes: [.targetMetadata],
            policy: .sshDefault,
            at: firstAt,
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )
        let persisted = try Data(contentsOf: storageURL)

        let second = try requireGrantRequest(
            store: store,
            clientID: "stable-client",
            targetID: targetID,
            capabilities: [.discovery],
            externalDataTypes: [.targetMetadata],
            policy: .sshDefault,
            at: firstAt.addingTimeInterval(600),
            expectedDenialCode: "GRANT_APPROVAL_REQUIRED"
        )

        #expect(second.id == first.id)
        #expect(second.lastRequestedAt == firstAt)
        #expect(try Data(contentsOf: storageURL) == persisted)
        #expect(notificationCount.value == 1)
    }

    @Test func implicitProfileAccessAuthorizesWithoutPendingRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-implicit-profile-access-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let targetID = UUID()
        let clientID = "mcp-registration:44444444-4444-4444-8444-444444444444"
        let notificationCount = LockedInvocationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .jtsRDPGrantApprovalRequested,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let authorization = try store.authorize(
            clientID: clientID,
            clientDisplayIdentity: "Codex · …44444444",
            targetID: targetID,
            capabilities: [.commandExecution],
            policy: .sshDefault,
            externalDataTypes: [.commandOutput],
            implicitProfileAccess: true
        )

        #expect(authorization.clientID == clientID)
        #expect(authorization.capabilities == [.commandExecution])
        #expect(store.pendingRequests(targetID: targetID).isEmpty)
        #expect(notificationCount.value == 0)
        let grant = try #require(store.activeGrants(targetID: targetID).first)
        #expect(grant.capabilities == RemoteTargetPermissionPolicy.sshDefault.maximumCapabilities)
        #expect(grant.consentedExternalDataTypes.contains(.commandOutput))
        #expect(grant.consentedExternalDataTypes.contains(.targetMetadata))
    }

    @Test func implicitProfileAccessDoesNotReviveARevokedGrant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-implicit-profile-revoke-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let targetID = UUID()
        let clientID = "mcp-registration:55555555-5555-4555-8555-555555555555"
        let authorization = try store.authorize(
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery],
            policy: .sshDefault,
            implicitProfileAccess: true
        )
        try store.revoke(grantID: authorization.grantID)

        do {
            _ = try store.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.commandExecution],
                policy: .sshDefault,
                externalDataTypes: [.commandOutput],
                implicitProfileAccess: true
            )
            Issue.record("A revoked client must not regain access from implicit profile enablement")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
            #expect(failure.pendingRequestID != nil)
        }
        #expect(store.activeGrants(targetID: targetID).isEmpty)
        #expect(store.pendingRequests(targetID: targetID).count == 1)
    }

    @Test func grantsAreIndependentPerClientAndRevocable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-independent-grants-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.discovery])

        for clientID in ["codex@2", "claude@1"] {
            do {
                _ = try store.authorize(
                    clientID: clientID,
                    targetID: targetID,
                    capabilities: [.discovery],
                    policy: policy
                )
            } catch { }
            let request = try #require(store.pendingRequests(targetID: targetID).first(where: {
                $0.clientID == clientID
            }))
            _ = try store.approve(
                requestID: request.id,
                policy: policy,
                consentToExternalData: false
            )
        }

        let codex = try #require(store.activeGrants(targetID: targetID).first(where: {
            $0.clientID == "codex@2"
        }))
        try store.revoke(grantID: codex.grantID)

        #expect(try store.authorize(
            clientID: "claude@1",
            targetID: targetID,
            capabilities: [.discovery],
            policy: policy
        ).clientID == "claude@1")
        do {
            _ = try store.authorize(
                clientID: "codex@2",
                targetID: targetID,
                capabilities: [.discovery],
                policy: policy
            )
            Issue.record("Revoking Codex must invalidate only the Codex grant")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
        #expect(store.activeGrants(targetID: targetID).map(\.clientID) == ["claude@1"])
    }

    @Test func approvingNonControlExpansionDoesNotRenewExpiredControlLease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-noncontrol-expansion-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.discovery, .desktopControl])
        do {
            _ = try store.authorize(
                clientID: "codex@2",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy
            )
        } catch { }
        let initial = try #require(store.pendingRequests(targetID: targetID).first)
        _ = try store.approve(requestID: initial.id, policy: policy, consentToExternalData: false)
        try store.invalidateControlAuthority(targetID: targetID)

        do {
            _ = try store.authorize(
                clientID: "codex@2",
                targetID: targetID,
                capabilities: [.discovery],
                policy: policy
            )
        } catch { }
        let expansion = try #require(store.pendingRequests(targetID: targetID).first)
        _ = try store.approve(requestID: expansion.id, policy: policy, consentToExternalData: false)

        do {
            _ = try store.authorize(
                clientID: "codex@2",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy
            )
            Issue.record("Approving Discovery must not renew an expired Control lease")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
    }

    @Test func grantFileSynchronizesMCPAndVisibleGUIProcesses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-cross-process-grants-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Separate instances model the MCP stdio executable and the already
        // running visible GUI process.
        let mcpProcessStore = RemoteClientGrantStore(storageURL: storageURL)
        let guiProcessStore = RemoteClientGrantStore(storageURL: storageURL)
        let targetID = UUID()
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.discovery])

        do {
            _ = try mcpProcessStore.authorize(
                clientID: "codex@2",
                targetID: targetID,
                capabilities: [.discovery],
                policy: policy
            )
        } catch { }

        guiProcessStore.reloadFromDiskIfChanged()
        let request = try #require(guiProcessStore.pendingRequests(targetID: targetID).first)
        _ = try guiProcessStore.approve(
            requestID: request.id,
            policy: policy,
            consentToExternalData: false
        )

        #expect(try mcpProcessStore.authorize(
            clientID: "codex@2",
            targetID: targetID,
            capabilities: [.discovery],
            policy: policy
        ).clientID == "codex@2")

        try FileManager.default.removeItem(at: storageURL)
        do {
            _ = try mcpProcessStore.authorize(
                clientID: "codex@2",
                targetID: targetID,
                capabilities: [.discovery],
                policy: policy
            )
            Issue.record("Deleting the persisted grant file must fail closed")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
    }

    @Test func revokedGrantCannotBeRestoredByAStaleControlAuthorization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-revoke-wins-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let issuedAt = Date(timeIntervalSince1970: 10_000)
        let revokedAt = issuedAt.addingTimeInterval(10)
        let targetID = UUID()
        let clientID = "codex-control@2"
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl])
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: issuedAt
        )
        let staleAuthorizer = RemoteClientGrantStore(storageURL: storageURL)
        let revoker = RemoteClientGrantStore(storageURL: storageURL)

        try revoker.revoke(grantID: approved.grant.grantID, at: revokedAt)

        do {
            _ = try staleAuthorizer.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: issuedAt.addingTimeInterval(20)
            )
            Issue.record("A stale authorizer must not revive a revoked control grant")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        let tombstone = try #require(reloaded.grants.first(where: {
            $0.grantID == approved.grant.grantID
        }))
        #expect(tombstone.revokedAt == revokedAt)
        #expect(tombstone.lastUsedAt == issuedAt)
        #expect(reloaded.activeGrants(targetID: targetID).isEmpty)
        #expect(reloaded.pendingRequests(targetID: targetID).count == 1)
    }

    @Test func staleApprovalCannotRecreateARevokedGrant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-stale-approval-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let issuedAt = Date(timeIntervalSince1970: 20_000)
        let targetID = UUID()
        let clientID = "codex-expansion@2"
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.discovery, .desktopControl]
        )
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery],
            policy: policy,
            at: issuedAt
        )
        let staleGUI = RemoteClientGrantStore(storageURL: storageURL)
        do {
            _ = try staleGUI.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: issuedAt.addingTimeInterval(1)
            )
            Issue.record("Capability expansion must wait for approval")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
        }
        let staleRequest = try #require(staleGUI.pendingRequests(targetID: targetID).first)

        let revoker = RemoteClientGrantStore(storageURL: storageURL)
        try revoker.revoke(
            grantID: approved.grant.grantID,
            at: issuedAt.addingTimeInterval(2)
        )

        do {
            _ = try staleGUI.approve(
                requestID: staleRequest.id,
                policy: policy,
                consentToExternalData: false,
                at: issuedAt.addingTimeInterval(3)
            )
            Issue.record("A removed stale request must not recreate a revoked grant")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_REQUEST_NOT_FOUND")
        }

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        #expect(reloaded.activeGrants(targetID: targetID).isEmpty)
        #expect(reloaded.pendingRequests(targetID: targetID).isEmpty)
        #expect(reloaded.grants.first(where: {
            $0.grantID == approved.grant.grantID
        })?.revokedAt != nil)
    }

    @Test func invalidatedControlLeaseCannotBeRetouchedByAStaleAuthorizer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-invalidate-wins-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let issuedAt = Date(timeIntervalSince1970: 30_000)
        let targetID = UUID()
        let clientID = "claude-control@1"
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl])
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: issuedAt
        )
        let staleAuthorizer = RemoteClientGrantStore(storageURL: storageURL)
        let invalidator = RemoteClientGrantStore(storageURL: storageURL)

        try invalidator.invalidateControlAuthority(targetID: targetID)

        do {
            _ = try staleAuthorizer.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: issuedAt.addingTimeInterval(1)
            )
            Issue.record("A stale authorizer must not retouch an invalidated control lease")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }

        let reloaded = RemoteClientGrantStore(storageURL: storageURL)
        #expect(reloaded.grants.first(where: {
            $0.grantID == approved.grant.grantID
        })?.lastUsedAt == .distantPast)
        #expect(reloaded.pendingRequests(targetID: targetID).first?.reason == .controlLeaseRenewal)
    }

    @Test func malformedGrantFileCannotBeOverwrittenFromAStaleAuthorizedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-malformed-grants-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetID = UUID()
        let clientID = "codex-discovery@2"
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.discovery])
        _ = try approvedGrantStore(
            storageURL: storageURL,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.discovery],
            policy: policy,
            at: Date(timeIntervalSince1970: 40_000)
        )
        let staleAuthorizer = RemoteClientGrantStore(storageURL: storageURL)
        try "{not-json".write(to: storageURL, atomically: true, encoding: .utf8)
        try secureTestFile(at: storageURL)

        do {
            _ = try staleAuthorizer.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.discovery],
                policy: policy
            )
            Issue.record("Malformed durable state must invalidate every stale grant")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_STORE_UNAVAILABLE")
        }

        #expect(staleAuthorizer.grants.isEmpty)
        #expect(staleAuthorizer.pendingRequests.isEmpty)
        #expect(staleAuthorizer.persistenceError != nil)
        #expect(try String(contentsOf: storageURL, encoding: .utf8) == "{not-json")
    }

    @Test func removedGrantFileWarningCanBeAcknowledgedByForcedReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-removed-grants-\(UUID().uuidString)",
                isDirectory: true
            )
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetID = UUID()
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: "codex-removal@2",
            targetID: targetID,
            capabilities: [.discovery],
            policy: RemoteTargetPermissionPolicy(
                maximumCapabilities: [.discovery]
            ),
            at: Date(timeIntervalSince1970: 45_000)
        )

        try FileManager.default.removeItem(at: storageURL)
        approved.store.reloadFromDiskIfChanged()

        #expect(approved.store.grants.isEmpty)
        #expect(approved.store.pendingRequests.isEmpty)
        #expect(
            approved.store.persistenceError?.contains(
                "AI authority was invalidated"
            ) == true
        )

        approved.store.reloadFromDiskIfChanged(force: true)

        #expect(approved.store.persistenceError == nil)
        #expect(approved.store.grants.isEmpty)
        #expect(approved.store.pendingRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storageURL.path))
    }

    @Test func symbolicGrantLockPathFailsClosedWithoutTouchingItsTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-lock-symlink-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        let sentinelURL = directory.appendingPathComponent("sentinel.txt")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "sentinel".write(to: sentinelURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: storageURL.appendingPathExtension("lock").path,
            withDestinationPath: sentinelURL.path
        )

        let store = RemoteClientGrantStore(storageURL: storageURL)
        do {
            _ = try store.authorize(
                clientID: "codex@2",
                targetID: UUID(),
                capabilities: [.discovery],
                policy: RemoteTargetPermissionPolicy(maximumCapabilities: [.discovery])
            )
            Issue.record("A symbolic lock path must never permit grant authorization")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_STORE_UNAVAILABLE")
        }

        #expect(store.grants.isEmpty)
        #expect(store.pendingRequests.isEmpty)
        #expect(store.persistenceError != nil)
        #expect(!FileManager.default.fileExists(atPath: storageURL.path))
        #expect(try String(contentsOf: sentinelURL, encoding: .utf8) == "sentinel")

        try FileManager.default.removeItem(
            at: storageURL.appendingPathExtension("lock")
        )
        store.reloadFromDiskIfChanged()
        #expect(store.persistenceError == nil)
        #expect(store.grants.isEmpty)
        #expect(store.pendingRequests.isEmpty)
    }

    @Test func controlInvalidationFailureIsVisibleAndReloadRecoversAfterLockRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-lock-repair-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        let lockURL = storageURL.appendingPathExtension("lock")
        let sentinelURL = directory.appendingPathComponent("sentinel.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetID = UUID()
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl])
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: "codex-control@2",
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(timeIntervalSince1970: 50_000)
        )
        try "sentinel".write(to: sentinelURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(
            atPath: lockURL.path,
            withDestinationPath: sentinelURL.path
        )

        do {
            try approved.store.invalidateControlAuthority(targetID: targetID)
            Issue.record("Manual takeover must report a durable invalidation failure")
        } catch {
            #expect(approved.store.persistenceError != nil)
            #expect(approved.store.grants.isEmpty)
        }

        try FileManager.default.removeItem(at: lockURL)
        approved.store.reloadFromDiskIfChanged()
        #expect(approved.store.persistenceError == nil)
        #expect(approved.store.activeGrants(targetID: targetID).count == 1)

        do {
            _ = try approved.store.authorize(
                clientID: "codex-control@2",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(timeIntervalSince1970: 50_001)
            )
            Issue.record("The durable revocation marker must block the old control lease")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        let renewal = try #require(
            approved.store.pendingRequests(targetID: targetID).first
        )
        _ = try approved.store.approve(
            requestID: renewal.id,
            policy: policy,
            consentToExternalData: false,
            at: Date(timeIntervalSince1970: 50_002)
        )
        #expect(try approved.store.authorize(
            clientID: "codex-control@2",
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(timeIntervalSince1970: 50_003)
        ).controlLeaseExpiresAt != nil)

        try approved.store.invalidateControlAuthority(targetID: targetID)
        #expect(
            approved.store.grants.first(where: {
                $0.grantID == approved.grant.grantID
            })?.lastUsedAt == .distantPast
        )
        #expect(try String(contentsOf: sentinelURL, encoding: .utf8) == "sentinel")
    }

    @Test func symbolicGrantDataPathFailsClosedWithoutFollowingItsTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-data-symlink-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        let sentinelURL = directory.appendingPathComponent("sentinel.txt")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "sentinel".write(to: sentinelURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: storageURL.path,
            withDestinationPath: sentinelURL.path
        )

        let store = RemoteClientGrantStore(storageURL: storageURL)
        do {
            _ = try store.authorize(
                clientID: "codex@2",
                targetID: UUID(),
                capabilities: [.discovery],
                policy: RemoteTargetPermissionPolicy(maximumCapabilities: [.discovery])
            )
            Issue.record("A symbolic data path must never be followed for authorization")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_STORE_UNAVAILABLE")
        }

        #expect(store.persistenceError != nil)
        #expect(store.grants.isEmpty)
        #expect(store.pendingRequests.isEmpty)
        #expect(try String(contentsOf: sentinelURL, encoding: .utf8) == "sentinel")
    }

    @Test func approvingOneClientCannotReviveAnotherClientsPreTakeoverLease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-multiclient-revocation-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        let lockURL = storageURL.appendingPathExtension("lock")
        let sentinelURL = directory.appendingPathComponent("sentinel.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetID = UUID()
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl])
        let store = RemoteClientGrantStore(storageURL: storageURL)
        for (offset, clientID) in ["client-a", "client-b"].enumerated() {
            do {
                _ = try store.authorize(
                    clientID: clientID,
                    targetID: targetID,
                    capabilities: [.desktopControl],
                    policy: policy,
                    at: Date(timeIntervalSince1970: 70_000 + Double(offset))
                )
                Issue.record("Each new control client must require visible approval")
            } catch let failure as RemoteGrantGateFailure {
                #expect(failure.denialCode == "GRANT_APPROVAL_REQUIRED")
            }
            let request = try #require(
                store.pendingRequests(targetID: targetID).first(where: {
                    $0.clientID == clientID
                })
            )
            _ = try store.approve(
                requestID: request.id,
                policy: policy,
                consentToExternalData: false,
                at: Date(timeIntervalSince1970: 70_010 + Double(offset))
            )
        }

        try "sentinel".write(to: sentinelURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(
            atPath: lockURL.path,
            withDestinationPath: sentinelURL.path
        )
        #expect(throws: (any Error).self) {
            try store.invalidateControlAuthority(targetID: targetID)
        }

        try FileManager.default.removeItem(at: lockURL)
        store.reloadFromDiskIfChanged()
        do {
            _ = try store.authorize(
                clientID: "client-a",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(timeIntervalSince1970: 70_020)
            )
            Issue.record("Client A must renew after target-wide takeover")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        let clientARequest = try #require(
            store.pendingRequests(targetID: targetID).first(where: {
                $0.clientID == "client-a"
            })
        )
        _ = try store.approve(
            requestID: clientARequest.id,
            policy: policy,
            consentToExternalData: false,
            at: Date(timeIntervalSince1970: 70_021)
        )
        #expect(try store.authorize(
            clientID: "client-a",
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(timeIntervalSince1970: 70_022)
        ).controlLeaseExpiresAt != nil)

        do {
            _ = try store.authorize(
                clientID: "client-b",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(timeIntervalSince1970: 70_023)
            )
            Issue.record("Approving client A must not revive client B's old control lease")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        #expect(store.pendingRequests(targetID: targetID).contains(where: {
            $0.clientID == "client-b" && $0.reason == .controlLeaseRenewal
        }))
    }

    @Test func failedRevocationEpochCommitCannotFallBackToAnOlderDurableEpoch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-pending-revocation-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        let lockURL = storageURL.appendingPathExtension("lock")
        let sentinelURL = directory.appendingPathComponent("sentinel.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetID = UUID()
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl])
        var failRevocationMarker = false
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: "pending-revocation-client",
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(timeIntervalSince1970: 71_000),
            controlRevocationFailureForTesting: {
                failRevocationMarker
                    ? CocoaError(.fileWriteNoPermission)
                    : nil
            }
        )

        try approved.store.invalidateControlAuthority(targetID: targetID)
        do {
            _ = try approved.store.authorize(
                clientID: "pending-revocation-client",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(timeIntervalSince1970: 71_001)
            )
            Issue.record("The first takeover must require a renewed control lease")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        let renewal = try #require(
            approved.store.pendingRequests(targetID: targetID).first
        )
        let renewedGrant = try approved.store.approve(
            requestID: renewal.id,
            policy: policy,
            consentToExternalData: false,
            at: Date(timeIntervalSince1970: 71_002)
        )
        let firstEpoch = try #require(renewedGrant.controlRevocationToken)
        #expect(try approved.store.authorize(
            clientID: "pending-revocation-client",
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(timeIntervalSince1970: 71_003)
        ).controlLeaseExpiresAt != nil)

        try "sentinel".write(to: sentinelURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(
            atPath: lockURL.path,
            withDestinationPath: sentinelURL.path
        )
        failRevocationMarker = true

        #expect(throws: (any Error).self) {
            try approved.store.invalidateControlAuthority(targetID: targetID)
        }
        try FileManager.default.removeItem(at: lockURL)

        do {
            _ = try approved.store.authorize(
                clientID: "pending-revocation-client",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(timeIntervalSince1970: 71_004)
            )
            Issue.record("A pending local epoch must not fall back to the older durable epoch")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == "GRANT_STORE_UNAVAILABLE")
        }

        failRevocationMarker = false
        do {
            _ = try approved.store.authorize(
                clientID: "pending-revocation-client",
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(timeIntervalSince1970: 71_005)
            )
            Issue.record("Repairing the marker must still require visible lease renewal")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
        let repairedRequest = try #require(
            approved.store.pendingRequests(targetID: targetID).first
        )
        let repairedGrant = try approved.store.approve(
            requestID: repairedRequest.id,
            policy: policy,
            consentToExternalData: false,
            at: Date(timeIntervalSince1970: 71_006)
        )
        #expect(repairedGrant.controlRevocationToken != firstEpoch)
        #expect(try String(contentsOf: sentinelURL, encoding: .utf8) == "sentinel")
    }

    @Test func markerFailureStillPersistsPrimaryGrantInvalidationForOtherProcesses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-marker-only-failure-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetID = UUID()
        let clientID = "marker-only-client"
        let policy = RemoteTargetPermissionPolicy(maximumCapabilities: [.desktopControl])
        var failRevocationMarker = false
        let approved = try approvedGrantStore(
            storageURL: storageURL,
            clientID: clientID,
            targetID: targetID,
            capabilities: [.desktopControl],
            policy: policy,
            at: Date(timeIntervalSince1970: 72_000),
            controlRevocationFailureForTesting: {
                failRevocationMarker
                    ? CocoaError(.fileWriteNoPermission)
                    : nil
            }
        )
        failRevocationMarker = true

        #expect(throws: (any Error).self) {
            try approved.store.invalidateControlAuthority(targetID: targetID)
        }

        let freshStore = RemoteClientGrantStore(storageURL: storageURL)
        let persistedGrant = try #require(
            freshStore.grants.first(where: {
                $0.grantID == approved.grant.grantID
            })
        )
        #expect(persistedGrant.lastUsedAt == .distantPast)
        do {
            _ = try freshStore.authorize(
                clientID: clientID,
                targetID: targetID,
                capabilities: [.desktopControl],
                policy: policy,
                at: Date(timeIntervalSince1970: 72_001)
            )
            Issue.record("A separate process must observe the primary grant invalidation")
        } catch let failure as RemoteGrantGateFailure {
            #expect(failure.denialCode == RemoteAuthorizationDenialCode.leaseExpired.rawValue)
        }
    }

    @Test func grantDataFIFOIsRejectedWithoutBlockingTheMainActor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-data-fifo-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(storageURL.path.withCString {
            Darwin.mkfifo($0, mode_t(0o600))
        } == 0)

        let started = ContinuousClock.now
        let store = RemoteClientGrantStore(storageURL: storageURL)

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(store.persistenceError?.contains("not a regular file") == true)
        #expect(store.grants.isEmpty)
        #expect(store.pendingRequests.isEmpty)
    }

    @Test func grantLockContentionTimesOutAndRecoversFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-grant-lock-timeout-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("grants.json")
        let lockURL = storageURL.appendingPathExtension("lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        let heldDescriptor = try #require(descriptor >= 0 ? descriptor : nil)
        defer { _ = Darwin.close(heldDescriptor) }
        #expect(flock(heldDescriptor, LOCK_EX) == 0)

        let started = ContinuousClock.now
        let store = RemoteClientGrantStore(storageURL: storageURL)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(store.persistenceError?.contains("timed out") == true)
        #expect(store.grants.isEmpty)

        #expect(flock(heldDescriptor, LOCK_UN) == 0)
        store.reloadFromDiskIfChanged()
        #expect(store.persistenceError == nil)
    }

    @Test func rdpAuditStoreClearsInheritedACLsAndRejectsACLExposedData() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-acl-\(UUID().uuidString)", isDirectory: true)
        let auditDirectory = parent.appendingPathComponent("Audit", isDirectory: true)
        let storageURL = auditDirectory.appendingPathComponent("audit.json")
        let lockURL = storageURL.appendingPathExtension("lock")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try installExtendedACL(at: parent, inheritable: true)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let targetID = UUID()
        let store = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        store.record(
            clientID: "acl-audit-client",
            targetID: targetID,
            targetAlias: "windows-acl",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now,
            finishedAt: now
        )
        #expect(store.persistenceError == nil)
        try PrivateFileSecurity.verifyPrivateDirectory(at: auditDirectory)
        try PrivateFileSecurity.verifyPrivateFile(at: storageURL)
        try PrivateFileSecurity.verifyPrivateFile(at: lockURL)

        try installExtendedACL(at: storageURL)
        let exposedStore = RemoteCapabilityAuditStore(
            storageURL: storageURL,
            now: now
        )
        #expect(exposedStore.records.isEmpty)
        #expect(exposedStore.persistenceError?.contains("ACL") == true)

        try secureTestFile(at: storageURL)
        try installExtendedACL(at: lockURL)
        let repairedLockStore = RemoteCapabilityAuditStore(
            storageURL: storageURL,
            now: now
        )
        #expect(repairedLockStore.records.count == 1)
        #expect(repairedLockStore.persistenceError == nil)
        try PrivateFileSecurity.verifyPrivateFile(at: lockURL)
    }

    @Test func rdpAuditDataFIFOIsRejectedWithoutBlockingTheMainActor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-data-fifo-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(storageURL.path.withCString {
            Darwin.mkfifo($0, mode_t(0o600))
        } == 0)

        let started = ContinuousClock.now
        let store = RemoteCapabilityAuditStore(storageURL: storageURL)

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(store.persistenceError?.contains("not a regular file") == true)
        #expect(store.records.isEmpty)
    }

    @Test func rdpAuditLockContentionTimesOutAndRecoversFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-lock-timeout-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        let lockURL = storageURL.appendingPathExtension("lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        let heldDescriptor = try #require(descriptor >= 0 ? descriptor : nil)
        defer { _ = Darwin.close(heldDescriptor) }
        #expect(flock(heldDescriptor, LOCK_EX) == 0)

        let started = ContinuousClock.now
        let store = RemoteCapabilityAuditStore(storageURL: storageURL)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(store.persistenceError?.contains("timed out") == true)
        #expect(store.records.isEmpty)

        #expect(flock(heldDescriptor, LOCK_UN) == 0)
        store.reloadFromDiskIfChanged()
        #expect(store.persistenceError == nil)
    }

    @Test func rdpAuditUnchangedReloadSkipsTheLockedDataPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-stamp-skip-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        let lockURL = storageURL.appendingPathExtension("lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        store.record(
            clientID: "stamp-client",
            targetID: UUID(),
            targetAlias: "windows-build",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now,
            finishedAt: now
        )
        #expect(store.records.count == 1)
        #expect(store.persistenceError == nil)

        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        let heldDescriptor = try #require(descriptor >= 0 ? descriptor : nil)
        defer { _ = Darwin.close(heldDescriptor) }
        #expect(flock(heldDescriptor, LOCK_EX) == 0)

        store.reloadFromDiskIfChanged(now: now)
        #expect(store.records.count == 1)
        #expect(store.persistenceError == nil)
        #expect(flock(heldDescriptor, LOCK_UN) == 0)
    }

    @Test func rdpAuditOversizedDataFileIsRejectedBeforeReading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-oversized-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = storageURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        let oversizedDescriptor = try #require(descriptor >= 0 ? descriptor : nil)
        defer { _ = Darwin.close(oversizedDescriptor) }
        #expect(Darwin.ftruncate(
            oversizedDescriptor,
            off_t(16 * 1_024 * 1_024 + 1)
        ) == 0)

        let started = ContinuousClock.now
        let store = RemoteCapabilityAuditStore(storageURL: storageURL)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(store.persistenceError?.contains("exceeds the safe size limit") == true)
        #expect(store.records.isEmpty)
    }

    @Test func rdpAuditSymlinkReplacementFailsClosedAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-symlink-replacement-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        let replacementURL = directory.appendingPathComponent("replacement.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        store.record(
            clientID: "replacement-client",
            targetID: UUID(),
            targetAlias: "windows-build",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now,
            finishedAt: now
        )
        #expect(store.records.count == 1)
        #expect(store.persistenceError == nil)

        try FileManager.default.copyItem(at: storageURL, to: replacementURL)
        try FileManager.default.removeItem(at: storageURL)
        try FileManager.default.createSymbolicLink(
            atPath: storageURL.path,
            withDestinationPath: replacementURL.path
        )

        store.reloadFromDiskIfChanged(now: now)
        #expect(store.records.isEmpty)
        #expect(store.persistenceError?.contains("could not be opened") == true)

        try FileManager.default.removeItem(at: storageURL)
        try FileManager.default.moveItem(at: replacementURL, to: storageURL)
        store.reloadFromDiskIfChanged(now: now)
        #expect(store.records.count == 1)
        #expect(store.persistenceError == nil)
    }

    @Test func rdpAuditHardLinkedDataFileIsRejectedAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-hard-link-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        let linkedURL = directory.appendingPathComponent("audit-copy.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        store.record(
            clientID: "hard-link-client",
            targetID: UUID(),
            targetAlias: "windows-build",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now,
            finishedAt: now
        )
        #expect(store.records.count == 1)
        try FileManager.default.linkItem(at: storageURL, to: linkedURL)

        store.reloadFromDiskIfChanged(now: now)
        #expect(store.records.isEmpty)
        #expect(store.persistenceError?.contains("link count is unsafe") == true)

        try FileManager.default.removeItem(at: linkedURL)
        store.reloadFromDiskIfChanged(now: now)
        #expect(store.records.count == 1)
        #expect(store.persistenceError == nil)
    }

    @Test func rdpAuditRetentionAndSchemaDoNotPersistSensitivePayloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-test-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let targetID = UUID()
        let bearerClientID = "mcp-registration:22222222-2222-4222-8222-222222222222"
        let store = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        store.record(
            clientID: bearerClientID,
            clientDisplayIdentity: "Codex · …22222222",
            targetID: targetID,
            targetAlias: "windows-build",
            actionType: "powershell Get-SecretValue C:\\private\\asset.zip",
            capabilities: [.commandExecution],
            result: .failed,
            resultCode: "FAILED: C:\\private\\asset.zip",
            controlLeaseExpiresAt: nil,
            startedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            finishedAt: now.addingTimeInterval(-31 * 24 * 60 * 60)
        )
        store.record(
            clientID: bearerClientID,
            clientDisplayIdentity: "Codex · …22222222",
            targetID: targetID,
            targetAlias: "windows-build",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now,
            finishedAt: now
        )
        store.record(
            clientID: bearerClientID,
            clientDisplayIdentity: "Codex · …22222222",
            targetID: targetID,
            targetAlias: "windows-build",
            actionType: "powershell Get-SecretValue C:\\private\\asset.zip",
            capabilities: [.commandExecution],
            result: .failed,
            resultCode: "FAILED: C:\\private\\asset.zip",
            controlLeaseExpiresAt: nil,
            startedAt: now.addingTimeInterval(1),
            finishedAt: now.addingTimeInterval(1)
        )

        let reloaded = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        #expect(reloaded.records.count == 2)
        let exported = String(decoding: try reloaded.exportData(), as: UTF8.self)
        #expect(exported.contains(WindowsMCPToolName.windowsExec.rawValue))
        #expect(exported.contains("Codex"))
        #expect(exported.contains("unknown"))
        #expect(exported.contains("UNKNOWN"))
        #expect(!exported.contains("Get-SecretValue"))
        #expect(!exported.contains("private"))
        #expect(!exported.contains("asset.zip"))
        #expect(!exported.contains("screenshot"))
        #expect(!exported.contains("password"))
        #expect(!exported.contains(bearerClientID))
        let exportedRecords = try #require(
            JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [[String: Any]]
        )
        let firstExport = try #require(exportedRecords.first)
        #expect(Set(firstExport.keys) == Set([
            "client",
            "target",
            "action",
            "result",
            "lease",
            "durationMilliseconds",
            "time",
        ]))
        #expect(
            Set(try #require(firstExport["client"] as? [String: Any]).keys)
                == Set(["reference", "displayIdentity"])
        )
        let exportedClient = try #require(firstExport["client"] as? [String: Any])
        #expect((exportedClient["reference"] as? String)?.hasPrefix("sha256:") == true)
        #expect(
            Set(try #require(firstExport["target"] as? [String: Any]).keys)
                == Set(["id", "alias"])
        )
        #expect(
            Set(try #require(firstExport["action"] as? [String: Any]).keys)
                == Set(["category", "capabilityScopes"])
        )
        #expect(
            Set(try #require(firstExport["result"] as? [String: Any]).keys)
                == Set(["status", "code"])
        )
        #expect(
            Set(try #require(firstExport["lease"] as? [String: Any]).keys)
                == Set(["expiresAt"])
        )
        #expect(
            Set(try #require(firstExport["time"] as? [String: Any]).keys)
                == Set(["startedAt", "finishedAt"])
        )

        let afterRetentionWindow = now.addingTimeInterval(31 * 24 * 60 * 60)
        reloaded.reloadFromDiskIfChanged(now: afterRetentionWindow)
        #expect(reloaded.records.isEmpty)
        let diskReload = RemoteCapabilityAuditStore(
            storageURL: storageURL,
            now: afterRetentionWindow
        )
        #expect(diskReload.records.isEmpty)
    }

    @Test func rdpAuditInterleavedStoresPreserveWritesAndTargetedClear() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-interleaved-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let firstTargetID = UUID()
        let secondTargetID = UUID()
        // All three instances begin with the same empty snapshot, matching
        // separately launched GUI and MCP processes.
        let firstStore = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        let secondStore = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        let staleClearStore = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)

        firstStore.record(
            clientID: "client-first",
            targetID: firstTargetID,
            targetAlias: "windows-first",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now,
            finishedAt: now
        )
        secondStore.record(
            clientID: "client-second",
            targetID: secondTargetID,
            targetAlias: "windows-second",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now.addingTimeInterval(1),
            finishedAt: now.addingTimeInterval(1)
        )
        firstStore.record(
            clientID: "client-third",
            targetID: firstTargetID,
            targetAlias: "windows-first",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now.addingTimeInterval(2),
            finishedAt: now.addingTimeInterval(2)
        )

        let afterWrites = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        #expect(afterWrites.records.count == 3)
        #expect(Set(afterWrites.records.map(\.clientID)) == Set([
            "client-first",
            "client-second",
            "client-third",
        ]))
        #expect(firstStore.persistenceError == nil)
        #expect(secondStore.persistenceError == nil)

        // A stale process clearing one target must re-read the other process's
        // latest record and preserve it.
        try staleClearStore.clear(targetID: firstTargetID, at: now)
        let afterClear = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        #expect(afterClear.records.map(\.clientID) == ["client-second"])
        #expect(staleClearStore.persistenceError == nil)

        try staleClearStore.clear(at: now)
        let afterGlobalClear = RemoteCapabilityAuditStore(
            storageURL: storageURL,
            now: now
        )
        #expect(afterGlobalClear.records.isEmpty)
        #expect(
            try #require(
                JSONSerialization.jsonObject(
                    with: afterGlobalClear.exportData()
                ) as? [[String: Any]]
            ).isEmpty
        )
    }

    @Test func rdpAuditV1DecodeReappliesRedactionAndRejectsInvalidTimeRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-v1-redaction-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let targetID = UUID()
        func rawRecord(
            id: UUID = UUID(),
            startedAt: Date,
            finishedAt: Date
        ) -> [String: Any] {
            [
                "id": id.uuidString,
                "clientID": "registered-client",
                "clientDisplayIdentity": "Registered Client",
                "targetID": targetID.uuidString,
                "targetAlias": "windows-build",
                "actionType": "powershell PRIVATE_TOKEN C:\\secret.txt",
                "capabilityNames": ["desktopObserve", "PRIVATE_SCOPE"],
                "result": "failed",
                "resultCode": "FAILED: PRIVATE_TOKEN",
                "controlLeaseExpiresAt": NSNull(),
                "startedAt": startedAt.timeIntervalSinceReferenceDate,
                "finishedAt": finishedAt.timeIntervalSinceReferenceDate,
            ]
        }
        let state: [String: Any] = [
            "formatVersion": 1,
            "records": [
                rawRecord(
                    startedAt: now.addingTimeInterval(-1),
                    finishedAt: now
                ),
                rawRecord(
                    startedAt: now,
                    finishedAt: now.addingTimeInterval(-1)
                ),
                rawRecord(
                    startedAt: now.addingTimeInterval(365 * 24 * 60 * 60),
                    finishedAt: now.addingTimeInterval(365 * 24 * 60 * 60 + 1)
                ),
            ],
        ]
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            .write(to: storageURL, options: .atomic)
        try secureTestFile(at: storageURL)

        let store = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        let record = try #require(store.records.first)
        #expect(store.records.count == 1)
        #expect(record.actionType == "unknown")
        #expect(record.resultCode == "UNKNOWN")
        #expect(record.capabilityNames == ["desktopObserve"])
        let exported = String(decoding: try store.exportData(), as: UTF8.self)
        #expect(!exported.contains("PRIVATE_TOKEN"))
        #expect(!exported.contains("secret.txt"))
        #expect(!exported.contains("PRIVATE_SCOPE"))

        let migrated = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
        )
        #expect((migrated["formatVersion"] as? NSNumber)?.intValue == 2)
    }

    @Test func rdpAuditTimePrunePreservesRecordsWrittenByAnotherStore() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-audit-prune-interleaved-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("audit.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let historicalDate = now.addingTimeInterval(-29 * 24 * 60 * 60)
        let targetID = UUID()
        let seedStore = RemoteCapabilityAuditStore(
            storageURL: storageURL,
            now: historicalDate
        )
        seedStore.record(
            clientID: "client-expiring",
            targetID: targetID,
            targetAlias: "windows-build",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: historicalDate,
            finishedAt: historicalDate
        )

        // Both instances hold the historical record. The writer then adds a
        // current record before the other instance performs time-driven prune.
        let pruningStore = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        let writerStore = RemoteCapabilityAuditStore(storageURL: storageURL, now: now)
        writerStore.record(
            clientID: "client-current",
            targetID: targetID,
            targetAlias: "windows-build",
            actionType: WindowsMCPToolName.windowsExec.rawValue,
            capabilities: [.commandExecution],
            result: .succeeded,
            resultCode: "OK",
            controlLeaseExpiresAt: nil,
            startedAt: now,
            finishedAt: now
        )

        let pruneDate = now.addingTimeInterval(2 * 24 * 60 * 60)
        pruningStore.reloadFromDiskIfChanged(now: pruneDate)

        #expect(pruningStore.records.map(\.clientID) == ["client-current"])
        #expect(pruningStore.persistenceError == nil)
        let diskReload = RemoteCapabilityAuditStore(
            storageURL: storageURL,
            now: pruneDate
        )
        #expect(diskReload.records.map(\.clientID) == ["client-current"])
        #expect(diskReload.persistenceError == nil)
    }

    @Test func dvcWireCodecHandlesPartialFramesAndValidatesControlPayload() throws {
        let control = DVCControlFrame(
            sequence: 1,
            payloadJSON: Data(#"{"protocolVersion":1,"requestId":"00112233-4455-6677-8899-aabbccddeeff","method":"companion.hello","parameters":{}}"#.utf8)
        )
        let encoded = try DVCWireCodec.encode(.control(control))
        let split = encoded.count / 2
        var decoder = DVCIncrementalDecoder()

        #expect(try decoder.append(Data(encoded.prefix(split))).isEmpty)
        let frames = try decoder.append(Data(encoded.suffix(from: split)))
        #expect(frames == [.control(control)])
        #expect(decoder.bufferedData.isEmpty)
    }

    @Test func dvcSequenceReplayGuardRejectsDuplicateAndOutOfOrderFrames() throws {
        var guardState = DVCSequenceReplayGuard()

        try guardState.accept(4)
        try guardState.accept(9)
        #expect(guardState.lastAccepted == 9)

        #expect(throws: DVCProtocolError.replayRejected(sequence: 9, lastAccepted: 9)) {
            try guardState.accept(9)
        }
        #expect(throws: DVCProtocolError.replayRejected(sequence: 3, lastAccepted: 9)) {
            try guardState.accept(3)
        }
        #expect(guardState.lastAccepted == 9)
    }

    @Test func remoteControlIdleLeaseCannotExceedFifteenMinutes() throws {
        let direct = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopControl],
            controlIdleTimeoutSeconds: 24 * 60 * 60
        )
        #expect(direct.controlIdleTimeoutSeconds == 15 * 60)

        let encoded = Data(
            #"{"maximumCapabilities":["desktopControl"],"controlIdleTimeoutSeconds":7200,"requireExternalDataConsent":true}"#.utf8
        )
        let decoded = try JSONDecoder().decode(RemoteTargetPermissionPolicy.self, from: encoded)
        #expect(decoded.controlIdleTimeoutSeconds == 15 * 60)
    }

    @Test func swiftControlFixtureIsDecodedByDotNetCompanion() throws {
        let requestJSON = #"{"protocolVersion":1,"requestId":"00112233-4455-6677-8899-aabbccddeeff","method":"companion.hello","deadlineUnixMilliseconds":1700000000000,"idempotencyKey":"fixture-1","expectedStateRevision":7,"parameters":{"clientName":"JTS Terminal"}}"#
        let control = DVCControlFrame(
            sequence: 0x0102_0304_0506_0708,
            payloadJSON: Data(requestJSON.utf8)
        )

        let encoded = try DVCWireCodec.encode(.control(control))
        #expect(Self.hexadecimal(encoded) == Self.swiftRequestFixtureHex)

        let request = try control.decodeRequest()
        #expect(request.protocolVersion == 1)
        #expect(request.requestID == UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        #expect(request.method == DVCOperation.companionHello.rawValue)
        #expect(request.deadlineUnixMilliseconds == 1_700_000_000_000)
        #expect(request.idempotencyKey == "fixture-1")
        #expect(request.expectedStateRevision == 7)
        #expect(request.parameters == .object(["clientName": .string("JTS Terminal")]))
    }

    @Test func swiftDecodesDotNetResponseFixture() throws {
        let encoded = try Self.data(hexadecimal: Self.dotNetResponseFixtureHex)
        let decoded = try DVCWireCodec.decodeAvailable(from: encoded)
        #expect(decoded.remainder.isEmpty)
        let control = try #require(decoded.frames.first?.controlFrame)
        let response = try control.decodeResponse()

        #expect(response.protocolVersion == 1)
        #expect(response.requestID == UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        #expect(response.success)
        #expect(response.result == .object(["ready": .bool(true)]))
        #expect(response.error == nil)
        #expect(try DVCWireCodec.encode(.control(control)) == encoded)
    }

    @Test func binaryChunkFixtureMatchesDotNetGuidAndDigestLayout() throws {
        let frame = DVCBinaryFrame(
            transferID: try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")),
            sequence: 10,
            offset: 4_096,
            data: Data("binary-data".utf8),
            isFinal: true
        )
        let encoded = try DVCWireCodec.encode(.binary(frame))
        #expect(Self.hexadecimal(encoded) == Self.binaryFixtureHex)

        let decoded = try DVCWireCodec.decodeAvailable(from: encoded)
        #expect(decoded.frames == [.binary(frame)])
        #expect(decoded.remainder.isEmpty)
    }

    @Test func desktopObserveResponsePublishesValidatedPNGAndMetadata() throws {
        let targetID = UUID()
        let sessionID = UUID()
        let frameID = UUID()
        let pngData = try #require(Data(base64Encoded: Self.onePixelPNGBase64))
        let arguments: [String: Any] = [
            "targetId": targetID.uuidString.lowercased(),
            "sessionId": sessionID.uuidString.lowercased(),
        ]
        let response = WindowsMCPToolResponse(
            structuredContent: [
                "ok": true,
                "targetId": targetID.uuidString.lowercased(),
                "sessionId": sessionID.uuidString.lowercased(),
                "frameId": frameID.uuidString.lowercased(),
                "stateRevision": 7,
                "pixelWidth": 1,
                "pixelHeight": 1,
                "capturedAt": "2026-07-16T08:00:00Z",
                "mimeType": "image/png",
            ],
            pngData: pngData
        )

        let result = try response.validated(
            for: .desktopObserve,
            arguments: arguments
        ).mcpResult()
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 2)
        let renderedText = try #require(content[0]["text"] as? String)
        let rendered = try #require(
            JSONSerialization.jsonObject(with: Data(renderedText.utf8)) as? [String: Any]
        )
        #expect(rendered["frameId"] as? String == frameID.uuidString.lowercased())
        #expect(content[1]["type"] as? String == "image")
        #expect(content[1]["mimeType"] as? String == "image/png")
        #expect(Data(base64Encoded: try #require(content[1]["data"] as? String)) == pngData)

        var mismatched = response
        mismatched.structuredContent["pixelWidth"] = 2
        #expect(throws: WindowsMCPToolError.self) {
            _ = try mismatched.validated(for: .desktopObserve, arguments: arguments)
        }

        var invalidPNG = response
        invalidPNG.pngData = Data("not-png".utf8)
        #expect(throws: WindowsMCPToolError.self) {
            _ = try invalidPNG.validated(for: .desktopObserve, arguments: arguments)
        }

        var truncatedPNG = response
        truncatedPNG.pngData = Data(pngData.prefix(33))
        #expect(throws: WindowsMCPToolError.self) {
            _ = try truncatedPNG.validated(for: .desktopObserve, arguments: arguments)
        }

        var missingEndPNG = response
        missingEndPNG.pngData = Data(pngData.dropLast(12))
        #expect(throws: WindowsMCPToolError.self) {
            _ = try missingEndPNG.validated(for: .desktopObserve, arguments: arguments)
        }

        var corruptCRCData = pngData
        corruptCRCData[45] ^= 0x01
        var corruptCRCPNG = response
        corruptCRCPNG.pngData = corruptCRCData
        #expect(throws: WindowsMCPToolError.self) {
            _ = try corruptCRCPNG.validated(for: .desktopObserve, arguments: arguments)
        }
    }

    @Test func desktopObserveTraversesProductionJSONRPCWithImageContent() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        target.mcpEnabled = true
        context.insert(target)
        try context.save()

        let sessionID = UUID()
        let frameID = UUID()
        let pngData = try #require(Data(base64Encoded: Self.onePixelPNGBase64))
        var invocationCount = 0
        let dispatcher = WindowsMCPToolDispatcher(
            availability: WindowsMCPRuntimeAvailability(
                desktopRuntimeAvailable: true,
                companionAvailable: false,
                reason: nil
            )
        ) { tool, routedTarget, arguments in
            invocationCount += 1
            #expect(tool == .desktopObserve)
            #expect(routedTarget.targetID == target.targetID)
            #expect(arguments["_jtsClientID"] as? String == remoteDesktopTestMCPRegistration().authorizationClientID)
            return WindowsMCPToolResponse(
                structuredContent: [
                    "ok": true,
                    "targetId": target.targetID.uuidString.lowercased(),
                    "sessionId": sessionID.uuidString.lowercased(),
                    "frameId": frameID.uuidString.lowercased(),
                    "stateRevision": 11,
                    "pixelWidth": 1,
                    "pixelHeight": 1,
                    "capturedAt": "2026-07-16T08:00:00Z",
                    "mimeType": "image/png",
                ],
                pngData: pngData
            )
        }
        let server = MCPStdioServer(
            modelContext: context,
            windowsDispatcher: dispatcher,
            clientRegistration: remoteDesktopTestMCPRegistration()
        )
        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test-client","version":"1"}}}"#
        ))
        let responseLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"jts_desktop_observe","arguments":{"targetId":"\#(target.targetID.uuidString)","sessionId":"\#(sessionID.uuidString)"}}}"#
        ))
        let result = try Self.toolResult(responseLine)
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        let image = try #require(content.first(where: { $0["type"] as? String == "image" }))
        #expect(image["mimeType"] as? String == "image/png")
        #expect(Data(base64Encoded: try #require(image["data"] as? String)) == pngData)
        #expect(invocationCount == 1)
    }

    @Test func terminalBridgeClearsInheritedACLsAndRejectsExposedArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-bridge-acl-\(UUID().uuidString)", isDirectory: true)
        defer {
            TerminalMCPBridgeImageHandoff.removeAll(runtimeRoot: root)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try installExtendedACL(at: root, inheritable: true)

        let descriptor = TerminalMCPBridgeDescriptor(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            token: "private-bridge-token",
            appPID: getpid(),
            createdAt: Date()
        )
        try TerminalMCPBridgeRuntime.writeDescriptor(descriptor, runtimeRoot: root)
        let descriptorURL = try TerminalMCPBridgeRuntime.descriptorURL(runtimeRoot: root)
        try PrivateFileSecurity.verifyPrivateDirectory(at: root)
        try PrivateFileSecurity.verifyPrivateFile(at: descriptorURL)

        let socketURL = try TerminalMCPBridgeRuntime.socketURL(runtimeRoot: root)
        let listenFD = try TerminalMCPBridgeSocket.listen(path: socketURL.path)
        defer {
            _ = Darwin.close(listenFD)
            _ = socketURL.path.withCString { Darwin.unlink($0) }
        }
        try PrivateFileSecurity.verifyPrivateSocket(at: socketURL)

        let payload = Data(repeating: 0xa5, count: 4_097)
        let handoff = try TerminalMCPBridgeImageHandoff.create(
            pngData: payload,
            runtimeRoot: root
        )
        let handoffDirectory = try TerminalMCPBridgeRuntime.imageHandoffDirectoryURL(
            runtimeRoot: root
        )
        let handoffURL = handoffDirectory.appendingPathComponent(handoff.fileName)
        try PrivateFileSecurity.verifyPrivateDirectory(at: handoffDirectory)
        try PrivateFileSecurity.verifyPrivateFile(at: handoffURL)
        try PrivateFileSecurity.verifyPrivateFile(
            at: handoffDirectory.appendingPathComponent(".handoff-quota.lock")
        )

        try installExtendedACL(at: descriptorURL)
        #expect(throws: TerminalMCPBridgeError.self) {
            _ = try TerminalMCPBridgeRuntime.readDescriptor(runtimeRoot: root)
        }
        try secureTestFile(at: descriptorURL)

        try installExtendedACL(at: socketURL)
        #expect(throws: TerminalMCPBridgeError.self) {
            _ = try TerminalMCPBridgeSocket.connect(
                path: socketURL.path,
                timeoutMilliseconds: 100
            )
        }
        try PrivateFileSecurity.securePrivateSocket(at: socketURL)

        try installExtendedACL(at: handoffURL)
        #expect(throws: TerminalMCPBridgeError.self) {
            _ = try TerminalMCPBridgeImageHandoff.consume(
                handoff,
                runtimeRoot: root
            )
        }
        #expect(!FileManager.default.fileExists(atPath: handoffURL.path))

        let replacement = try TerminalMCPBridgeImageHandoff.create(
            pngData: payload,
            runtimeRoot: root
        )
        #expect(
            try TerminalMCPBridgeImageHandoff.consume(
                replacement,
                runtimeRoot: root
            ) == payload
        )

        let longRuntimeRoot = root.appendingPathComponent(
            String(repeating: "long-runtime-segment-", count: 8),
            isDirectory: true
        )
        let fallbackSocketURL = try TerminalMCPBridgeRuntime.socketURL(
            runtimeRoot: longRuntimeRoot
        )
        let fallbackDirectory = fallbackSocketURL.deletingLastPathComponent()
        #expect(
            fallbackDirectory.standardizedFileURL
                != longRuntimeRoot.standardizedFileURL
        )
        #expect(fallbackSocketURL.lastPathComponent.contains("\(getpid())"))
        try PrivateFileSecurity.verifyPrivateDirectory(at: longRuntimeRoot)
        try PrivateFileSecurity.verifyPrivateDirectory(at: fallbackDirectory)

        let fallbackListener = try TerminalMCPBridgeSocket.listen(
            path: fallbackSocketURL.path
        )
        defer {
            _ = Darwin.close(fallbackListener)
            _ = fallbackSocketURL.path.withCString { Darwin.unlink($0) }
        }
        try PrivateFileSecurity.verifyPrivateSocket(at: fallbackSocketURL)
    }

    @Test func terminalBridgeDerivesSandboxContainerTemporaryDirectory() throws {
        let supportDirectory = URL(
            fileURLWithPath: "/fixture/home/Library/Containers/com.example.JTSTerminal/Data/Library/Application Support",
            isDirectory: true
        )
        let temporaryDirectory = try #require(
            TerminalMCPBridgeRuntime.sandboxContainerTemporaryDirectory(
                applicationSupportDirectory: supportDirectory
            )
        )
        #expect(
            temporaryDirectory.path
                == "/fixture/home/Library/Containers/com.example.JTSTerminal/Data/tmp"
        )
        #expect(
            TerminalMCPBridgeRuntime.sandboxContainerTemporaryDirectory(
                applicationSupportDirectory: URL(
                    fileURLWithPath: "/fixture/home/Library/Application Support",
                    isDirectory: true
                )
            ) == nil
        )
    }

    @Test func imageHandoffQuotaBoundsUnconsumedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-image-handoff-quota-\(UUID().uuidString)", isDirectory: true)
        defer {
            TerminalMCPBridgeImageHandoff.removeAll(runtimeRoot: root)
            try? FileManager.default.removeItem(at: root)
        }
        let payload = Data([0x89])
        var handoffs: [TerminalMCPBridgeImageHandoffDescriptor] = []
        for _ in 0..<TerminalMCPBridgeImageHandoff.maximumOutstandingFiles {
            handoffs.append(try TerminalMCPBridgeImageHandoff.create(
                pngData: payload,
                runtimeRoot: root
            ))
        }
        #expect(throws: TerminalMCPBridgeError.self) {
            _ = try TerminalMCPBridgeImageHandoff.create(
                pngData: payload,
                runtimeRoot: root
            )
        }

        TerminalMCPBridgeImageHandoff.remove(handoffs.removeFirst(), runtimeRoot: root)
        let replacement = try TerminalMCPBridgeImageHandoff.create(
            pngData: payload,
            runtimeRoot: root
        )
        handoffs.append(replacement)
        #expect(handoffs.count == TerminalMCPBridgeImageHandoff.maximumOutstandingFiles)
    }

    @Test func imageHandoffCarriesPayloadsBeyondBridgeJSONLimitExactlyOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-image-handoff-\(UUID().uuidString)", isDirectory: true)
        defer {
            TerminalMCPBridgeRuntime.removeRuntimeFiles(
                descriptor: try? TerminalMCPBridgeRuntime.readDescriptor(runtimeRoot: root),
                runtimeRoot: root
            )
            try? FileManager.default.removeItem(at: root)
        }
        let payload = Data(repeating: 0xa5, count: 17 * 1_024 * 1_024 + 137)

        let handoff = try TerminalMCPBridgeImageHandoff.create(
            pngData: payload,
            runtimeRoot: root
        )
        #expect(handoff.byteCount == payload.count)
        #expect(handoff.dictionary.description.utf8.count < 1_024)

        let socketURL = try TerminalMCPBridgeRuntime.socketURL(runtimeRoot: root)
        let listenFD = try TerminalMCPBridgeSocket.listen(path: socketURL.path)
        defer { _ = Darwin.close(listenFD) }
        let bridge = TerminalMCPBridgeDescriptor(
            socketPath: socketURL.path,
            token: "image-handoff-token",
            appPID: getpid(),
            createdAt: Date()
        )
        try TerminalMCPBridgeRuntime.writeDescriptor(bridge, runtimeRoot: root)
        let serverFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { serverFinished.signal() }
            let clientFD = Darwin.accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { _ = Darwin.close(clientFD) }
            guard (try? TerminalMCPBridgeSocket.readJSONLine(from: clientFD)) != nil else {
                return
            }
            try? TerminalMCPBridgeSocket.writeJSONLine([
                "ok": true,
                "result": [
                    "structuredContent": ["ok": true],
                    "pngHandoff": handoff.dictionary,
                ],
            ], to: clientFD)
        }

        let result = try TerminalMCPBridgeClient(runtimeRoot: root).invokeWindowsTool(
            WindowsMCPToolName.desktopObserve.rawValue,
            targetID: UUID().uuidString,
            arguments: [:]
        )
        let restored = try #require(result["_jtsPNGData"] as? Data)
        #expect(restored == payload)
        #expect(serverFinished.wait(timeout: .now() + 5) == .success)
        #expect(throws: TerminalMCPBridgeError.self) {
            _ = try TerminalMCPBridgeImageHandoff.consume(
                handoff,
                runtimeRoot: root
            )
        }
    }

    @Test func imageHandoffAllowsOnlyOneConcurrentConsumer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-image-handoff-race-\(UUID().uuidString)", isDirectory: true)
        defer {
            TerminalMCPBridgeImageHandoff.removeAll(runtimeRoot: root)
            try? FileManager.default.removeItem(at: root)
        }
        let payload = Data(repeating: 0x5a, count: 1_024 * 1_024 + 17)
        let handoff = try TerminalMCPBridgeImageHandoff.create(
            pngData: payload,
            runtimeRoot: root
        )

        let outcomes = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        let consumed = try TerminalMCPBridgeImageHandoff.consume(
                            handoff,
                            runtimeRoot: root
                        )
                        return consumed == payload ? 1 : -1
                    } catch {
                        return 0
                    }
                }
            }
            var values: [Int] = []
            for await value in group {
                values.append(value)
            }
            return values.sorted()
        }
        #expect(outcomes == [0, 1])
    }

    @Test func desktopActionParserRejectsAmbiguousAndLossyInputs() throws {
        let frameID = UUID().uuidString.lowercased()
        let invalidArguments: [[String: Any]] = [
            ["action": "click", "expectedStateRevision": true, "expectedFrameId": frameID, "x": 1, "y": 1],
            ["action": "click", "expectedStateRevision": 7.5, "expectedFrameId": frameID, "x": 1, "y": 1],
            ["action": "click", "expectedStateRevision": 7, "expectedFrameId": frameID, "x": true, "y": 1],
            ["action": "click", "expectedStateRevision": 7, "expectedFrameId": frameID, "x": 1.5, "y": 1],
            ["action": "click", "expectedStateRevision": 7, "expectedFrameId": "not-a-uuid", "x": 1, "y": 1],
            ["action": "click", "expectedStateRevision": 7, "expectedFrameId": frameID, "x": 1, "y": 1, "button": "bogus"],
            ["action": "click", "expectedStateRevision": 7, "expectedFrameId": frameID, "x": 1, "y": 1, "selector": "save"],
            ["action": "semanticInvoke", "expectedStateRevision": 7, "selector": "save", "x": 1, "y": 1],
            ["action": "semanticInvoke", "expectedStateRevision": 7, "selector": #"{"automationId":"save"}"#],
            ["action": "semanticInvoke", "expectedStateRevision": 7, "selector": #"{"processId":123,"controlType":"button"}"#],
            ["action": "semanticInvoke", "expectedStateRevision": 7, "selector": #"{"processId":2147483648,"automationId":"save"}"#],
            ["action": "semanticInvoke", "expectedStateRevision": 7, "selector": #"{"processId":123,"automationId":"save","name":7}"#],
            ["action": "semanticInvoke", "expectedStateRevision": 7, "selector": #"{"processId":123,"automationId":"save","controlType":"bogus"}"#],
            ["action": "semanticSetValue", "expectedStateRevision": 7, "selector": "editor"],
            ["action": "keyChord", "expectedStateRevision": 7, "keys": []],
            ["action": "keyDown", "expectedStateRevision": 7, "key": "A", "selector": #"{"processId":123,"automationId":"editor"}"#],
            ["action": "keyChord", "expectedStateRevision": 7, "keys": ["command", "v"], "x": 1, "y": 1],
            ["action": "typeText", "expectedStateRevision": 7, "text": "secret", "selector": #"{"processId":123,"automationId":"editor"}"#],
            ["action": "typeText", "expectedStateRevision": 7, "text": "secret", "expectedFrameId": frameID, "x": 1, "y": 1],
            ["action": "click", "expectedStateRevision": 7, "expectedFrameId": frameID, "x": 1, "y": 1, "key": "A"],
            ["action": "click", "expectedStateRevision": 7, "expectedFrameId": frameID, "x": 1, "y": 1, "idempotencyKey": "not-deduplicated"],
            ["action": "scroll", "expectedStateRevision": 7, "expectedFrameId": frameID, "x": 1, "y": 1, "scrollDeltaX": 1, "scrollDeltaY": -120],
            ["action": "scroll", "expectedStateRevision": 7, "expectedFrameId": frameID, "x": 1, "y": 1, "scrollDeltaY": 32_768],
            ["action": "typeText", "expectedStateRevision": 7, "text": String(repeating: "x", count: 32_769)],
        ]
        for arguments in invalidArguments {
            #expect(throws: WindowsMCPToolError.self) {
                _ = try WindowsMCPDesktopActionRequestParser.parse(arguments)
            }
        }

        let coordinate = try WindowsMCPDesktopActionRequestParser.parse([
            "action": "click",
            "expectedStateRevision": 7,
            "expectedFrameId": frameID,
            "x": 10,
            "y": 20,
            "button": "left",
        ])
        #expect(coordinate.action == .click)
        #expect(coordinate.point == DesktopPoint(x: 10, y: 20))

        let semantic = try WindowsMCPDesktopActionRequestParser.parse([
            "action": "semanticSetValue",
            "expectedStateRevision": 7,
            "selector": #"{"processId":123,"automationId":"editor"}"#,
            "text": "",
        ])
        #expect(semantic.action == .semanticSetValue)
        #expect(semantic.text == "")
        #expect(semantic.point == nil)
    }

    @Test func desktopActionJSONRPCRejectsMalformedInputAndClosesStaleFrames() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        target.mcpEnabled = true
        context.insert(target)
        try context.save()

        let sessionID = UUID()
        let frame = DesktopFrameMetadata(
            frameID: UUID(),
            sessionID: sessionID,
            stateRevision: 19,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        var invocationCount = 0
        let dispatcher = WindowsMCPToolDispatcher(
            availability: WindowsMCPRuntimeAvailability(
                desktopRuntimeAvailable: true,
                companionAvailable: true,
                reason: nil
            )
        ) { tool, _, arguments in
            invocationCount += 1
            #expect(tool == .desktopAction)
            let request = try WindowsMCPDesktopActionRequestParser.parse(arguments)
            do {
                try request.validate(against: frame)
            } catch {
                throw WindowsMCPToolError(
                    code: .stateConflict,
                    message: error.localizedDescription
                )
            }
            return WindowsMCPToolResponse(structuredContent: [
                "ok": true,
                "accepted": true,
                "targetId": target.targetID.uuidString.lowercased(),
                "sessionId": sessionID.uuidString.lowercased(),
            ])
        }
        let server = MCPStdioServer(
            modelContext: context,
            windowsDispatcher: dispatcher,
            clientRegistration: remoteDesktopTestMCPRegistration()
        )
        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test-client","version":"1"}}}"#
        ))

        let malformedLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"jts_desktop_action","arguments":{"targetId":"\#(target.targetID.uuidString)","sessionId":"\#(sessionID.uuidString)","action":"click","expectedStateRevision":19,"expectedFrameId":"\#(frame.frameID.uuidString)","x":10.5,"y":20}}}"#
        ))
        let malformed = try #require(
            Self.toolResult(malformedLine)["structuredContent"] as? [String: Any]
        )
        #expect(malformed["code"] as? String == "INVALID_ARGUMENT")
        #expect(invocationCount == 0)

        let staleLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jts_desktop_action","arguments":{"targetId":"\#(target.targetID.uuidString)","sessionId":"\#(sessionID.uuidString)","action":"click","expectedStateRevision":19,"expectedFrameId":"\#(UUID().uuidString)","x":10,"y":20}}}"#
        ))
        let stale = try #require(
            Self.toolResult(staleLine)["structuredContent"] as? [String: Any]
        )
        #expect(stale["code"] as? String == "STATE_CONFLICT")
        #expect(invocationCount == 1)

        let acceptedLine = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"jts_desktop_action","arguments":{"targetId":"\#(target.targetID.uuidString)","sessionId":"\#(sessionID.uuidString)","action":"click","expectedStateRevision":19,"expectedFrameId":"\#(frame.frameID.uuidString)","x":10,"y":20}}}"#
        ))
        let accepted = try #require(
            Self.toolResult(acceptedLine)["structuredContent"] as? [String: Any]
        )
        #expect(accepted["accepted"] as? Bool == true)
        #expect(invocationCount == 2)
    }

    @Test func companionToolJSONRPCRequiresAnExplicitDesktopSession() async throws {
        let container = try ModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        target.mcpEnabled = true
        context.insert(target)
        try context.save()

        var invocationCount = 0
        let dispatcher = WindowsMCPToolDispatcher(
            availability: WindowsMCPRuntimeAvailability(
                desktopRuntimeAvailable: true,
                companionAvailable: true,
                reason: nil
            )
        ) { _, _, _ in
            invocationCount += 1
            return WindowsMCPToolResponse(structuredContent: ["ok": true])
        }
        let server = MCPStdioServer(
            modelContext: context,
            windowsDispatcher: dispatcher,
            clientRegistration: remoteDesktopTestMCPRegistration()
        )
        _ = try #require(await server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test-client","version":"1"}}}"#
        ))

        let requests = [
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"jts_windows_exec","arguments":{"targetId":"\#(target.targetID.uuidString)","command":"Get-Date"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jts_windows_files","arguments":{"targetId":"\#(target.targetID.uuidString)","operation":"list","path":"."}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"jts_windows_task","arguments":{"targetId":"\#(target.targetID.uuidString)","action":"doctor"}}}"#,
        ]
        for request in requests {
            let line = try #require(await server.handleLine(request))
            let structured = try #require(
                Self.toolResult(line)["structuredContent"] as? [String: Any]
            )
            #expect(structured["code"] as? String == "INVALID_ARGUMENT")
            #expect(
                (structured["message"] as? String)?
                    .contains("sessionId must be a desktop session UUID") == true
            )
        }
        #expect(invocationCount == 0)
    }

    @Test func desktopActionRequestsOnlyControlWithoutImageConsent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-action-control-grant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.desktopControl]
        )
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let grantStore = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let runtime = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: grantStore
        )
        defer { runtime.stopAllImmediately() }
        let sessionID = runtime.installActiveDesktopForTesting(target: target)
        let client = remoteDesktopTestMCPRegistration()

        do {
            _ = try await runtime.handleMCP(
                tool: .desktopAction,
                target: target,
                arguments: [
                    "_jtsClientID": client.authorizationClientID,
                    "_jtsClientDisplayIdentity": client.displayIdentity,
                    "sessionId": sessionID.uuidString.lowercased(),
                    "action": "click",
                    "expectedStateRevision": 1,
                    "expectedFrameId": UUID().uuidString.lowercased(),
                    "x": 10,
                    "y": 20,
                ]
            )
            Issue.record("Desktop control must wait for explicit client approval")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
        }

        let request = try #require(grantStore.pendingRequests(targetID: target.targetID).first)
        #expect(request.requestedCapabilities == [.desktopControl])
        #expect(request.externalDataTypes.isEmpty)
        _ = try grantStore.approve(
            requestID: request.id,
            policy: policy,
            consentToExternalData: false,
            currentTargetBinding: target.mcpGrantTargetBinding
        )
    }

    @Test func rdpMCPAuthorizationRequestsOnlyExternalDataReturnedByEachTool() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-rdp-external-data-map-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = RemoteTargetPermissionPolicy.rdpDefault
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let grantStore = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let runtime = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: grantStore
        )
        defer { runtime.stopAllImmediately() }

        let cases: [(
            name: String,
            tool: WindowsMCPToolName,
            arguments: [String: Any],
            capabilities: Set<RemoteCapability>,
            externalDataTypes: Set<RemoteExternalDataType>
        )] = [
            ("list-targets", .listTargets, [:], [.discovery], [.targetMetadata]),
            ("desktop-observe", .desktopObserve, [:], [.desktopObserve], [.desktopImage]),
            ("desktop-uia", .desktopUIA, ["operation": "snapshot"], [.desktopObserve], [.desktopStructure]),
            ("windows-exec", .windowsExec, [:], [.commandExecution], [.commandOutput]),
            ("files-list", .windowsFiles, ["operation": "list"], [.fileAccess], [.fileMetadata]),
            ("files-stat", .windowsFiles, ["operation": "stat"], [.fileAccess], [.fileMetadata]),
            ("files-read", .windowsFiles, ["operation": "read"], [.fileAccess], [.fileContent]),
            ("files-download", .windowsFiles, ["operation": "download"], [.fileAccess], [.fileContent]),
            (
                "files-write",
                .windowsFiles,
                ["operation": "write"],
                [.fileAccess, .destructiveOperations],
                []
            ),
            (
                "files-upload",
                .windowsFiles,
                ["operation": "upload"],
                [.fileAccess, .destructiveOperations],
                []
            ),
            ("task-collect", .windowsTask, ["action": "collect"], [.structuredTasks], [.fileContent]),
            ("task-status", .windowsTask, ["action": "status"], [.structuredTasks], []),
        ]

        for testCase in cases {
            let clientID = "external-data-\(testCase.name)"
            var arguments = testCase.arguments
            arguments["_jtsClientID"] = clientID
            arguments["_jtsClientDisplayIdentity"] = "External Data \(testCase.name)"

            do {
                _ = try await runtime.handleMCP(
                    tool: testCase.tool,
                    target: target,
                    arguments: arguments
                )
                Issue.record("\(testCase.name) must wait for explicit client approval")
            } catch let failure as WindowsMCPToolError {
                #expect(failure.code == .permissionDenied)
                #expect(
                    failure.details["authorizationCode"] as? String
                        == "GRANT_APPROVAL_REQUIRED"
                )
            }

            let request = try #require(
                grantStore.pendingRequests(targetID: target.targetID).first(where: {
                    $0.clientID == clientID
                })
            )
            #expect(request.requestedCapabilities == testCase.capabilities)
            #expect(request.externalDataTypes == testCase.externalDataTypes)
            #expect(
                request.requiresExternalDataConsent
                    == !testCase.externalDataTypes.isEmpty
            )
        }
    }

    @Test func rdpMCPBearerIdentityUsesRedactedDisplayFallbackAndAuditExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-rdp-bearer-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        try target.setRDPProfile(RDPConnectionProfile(
            permissionPolicy: RemoteTargetPermissionPolicy(
                maximumCapabilities: [.discovery]
            )
        ))
        let grantStore = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let auditStore = RemoteCapabilityAuditStore(
            storageURL: directory.appendingPathComponent("audit.json")
        )
        let runtime = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: grantStore,
            auditStoreForTesting: auditStore
        )
        defer { runtime.stopAllImmediately() }

        let registrationID = "33333333-3333-4333-8333-333333333333"
        let bearerClientID = "mcp-registration:\(registrationID)"
        let fallbackDisplayIdentity = "Registered MCP client · …33333333"
        let arguments: [String: Any] = [
            "_jtsClientID": bearerClientID,
            "idempotencyKey": "bearer-audit-open",
        ]

        do {
            _ = try await runtime.handleMCP(
                tool: .openDesktop,
                target: target,
                arguments: arguments
            )
            Issue.record("A bearer client must wait for visible approval.")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
        }
        let request = try #require(
            grantStore.pendingRequests(targetID: target.targetID).first
        )
        #expect(request.clientDisplayIdentity == fallbackDisplayIdentity)
        let grant = try grantStore.approve(
            requestID: request.id,
            policy: target.rdpProfile.permissionPolicy,
            consentToExternalData: true,
            currentTargetBinding: target.mcpGrantTargetBinding
        )
        #expect(grant.clientDisplayIdentity == fallbackDisplayIdentity)

        _ = try await runtime.handleMCP(
            tool: .openDesktop,
            target: target,
            arguments: arguments
        )
        let auditRecords = auditStore.records(targetID: target.targetID)
        #expect(!auditRecords.isEmpty)
        #expect(auditRecords.allSatisfy {
            $0.clientDisplayIdentity == fallbackDisplayIdentity
        })
        let exported = String(
            decoding: try auditStore.exportData(targetID: target.targetID),
            as: UTF8.self
        )
        #expect(exported.contains(fallbackDisplayIdentity))
        #expect(!exported.contains(bearerClientID))
        #expect(!exported.contains(registrationID))
    }

    @Test func rdpMCPAuthorizationExpandsFileConsentFromMetadataToContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jts-rdp-file-consent-expansion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = RemoteTargetPermissionPolicy(
            maximumCapabilities: [.fileAccess]
        )
        let target = RemoteSession(
            name: "Windows",
            host: "windows.test",
            username: "operator",
            connectionType: .rdp
        )
        try target.setRDPProfile(RDPConnectionProfile(permissionPolicy: policy))
        let grantStore = RemoteClientGrantStore(
            storageURL: directory.appendingPathComponent("grants.json")
        )
        let runtime = RDPDesktopRuntimeStore(
            openOperationExecutorForTesting: { target, _, _ in
                Self.desktopState(
                    sessionID: UUID(),
                    targetID: target.targetID,
                    phase: .connected
                )
            },
            grantStoreForTesting: grantStore
        )
        defer { runtime.stopAllImmediately() }
        let clientID = "scoped-file-client"
        let baseArguments: [String: Any] = [
            "_jtsClientID": clientID,
            "_jtsClientDisplayIdentity": "Scoped File Client",
        ]

        do {
            _ = try await runtime.handleMCP(
                tool: .windowsFiles,
                target: target,
                arguments: baseArguments.merging(["operation": "list"]) { _, new in new }
            )
            Issue.record("File metadata access must wait for explicit approval")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
        }
        let metadataRequest = try #require(
            grantStore.pendingRequests(targetID: target.targetID).first
        )
        #expect(metadataRequest.externalDataTypes == [.fileMetadata])
        let metadataGrant = try grantStore.approve(
            requestID: metadataRequest.id,
            policy: policy,
            consentToExternalData: true,
            currentTargetBinding: target.mcpGrantTargetBinding
        )
        #expect(metadataGrant.consentedExternalDataTypes == [.fileMetadata])

        do {
            _ = try await runtime.handleMCP(
                tool: .windowsFiles,
                target: target,
                arguments: baseArguments.merging(["operation": "read"]) { _, new in new }
            )
            Issue.record("File content access must require a scoped consent expansion")
        } catch let failure as WindowsMCPToolError {
            #expect(failure.code == .permissionDenied)
            #expect(
                failure.details["authorizationCode"] as? String
                    == RemoteAuthorizationDenialCode.externalDataConsentRequired.rawValue
            )
        }
        let contentRequest = try #require(
            grantStore.pendingRequests(targetID: target.targetID).first
        )
        #expect(contentRequest.reason == .externalDataConsent)
        #expect(contentRequest.requestedCapabilities == [.fileAccess])
        #expect(contentRequest.externalDataTypes == [.fileContent])
    }

    @Test func windowsTaskResponseRequiresCompanionDVCProofAndCollectBundle() throws {
        let targetID = UUID()
        let sessionID = UUID()
        let bundle = Data("result".utf8)
        let bundleSHA256 = SHA256.hash(data: bundle)
            .map { String(format: "%02x", $0) }
            .joined()
        let response = WindowsMCPToolResponse(structuredContent: [
            "ok": true,
            "targetId": targetID.uuidString.lowercased(),
            "sessionId": sessionID.uuidString.lowercased(),
            "jobId": "avatar-pilot-001",
            "state": "collected",
            "bundleBase64": bundle.base64EncodedString(),
            "bundleSha256": bundleSHA256,
            "transportProof": ["channel": "companion-dvc"],
        ])

        let validated = try response.validated(
            for: .windowsTask,
            arguments: [
                "targetId": targetID.uuidString.lowercased(),
                "sessionId": sessionID.uuidString.lowercased(),
                "action": "collect",
                "jobId": "avatar-pilot-001",
            ]
        )
        #expect(validated.structuredContent["jobId"] as? String == "avatar-pilot-001")
    }

    @Test func windowsTaskResponsesRequireTheExactRequestedJobIdentity() throws {
        let targetID = UUID().uuidString.lowercased()
        let sessionID = UUID().uuidString.lowercased()
        let requestedJobID = "avatar-pilot-001"
        let bundle = Data("result".utf8)
        let bundleSHA256 = SHA256.hash(data: bundle)
            .map { String(format: "%02x", $0) }
            .joined()
        let actions: [(action: String, state: String)] = [
            ("submit", "queued"),
            ("status", "running"),
            ("cancel", "cancelled"),
            ("collect", "collected"),
        ]

        for entry in actions {
            let arguments: [String: Any] = [
                "targetId": targetID,
                "sessionId": sessionID,
                "action": entry.action,
                "jobId": requestedJobID,
            ]
            var response: [String: Any] = [
                "ok": true,
                "targetId": targetID,
                "sessionId": sessionID,
                "jobId": requestedJobID,
                "state": entry.state,
                "transportProof": ["channel": "companion-dvc"],
            ]
            if entry.action == "collect" {
                response["bundleBase64"] = bundle.base64EncodedString()
                response["bundleSha256"] = bundleSHA256
            }

            _ = try WindowsMCPToolResponse(
                structuredContent: response
            ).validated(
                for: .windowsTask,
                arguments: arguments
            )

            var missingJobID = response
            missingJobID.removeValue(forKey: "jobId")
            var mismatchedJobID = response
            mismatchedJobID["jobId"] = "different-job"
            var legacyTaskIDOnly = missingJobID
            legacyTaskIDOnly["taskId"] = requestedJobID

            for invalidResponse in [
                missingJobID,
                mismatchedJobID,
                legacyTaskIDOnly,
            ] {
                do {
                    _ = try WindowsMCPToolResponse(
                        structuredContent: invalidResponse
                    ).validated(
                        for: .windowsTask,
                        arguments: arguments
                    )
                    Issue.record(
                        "Windows task \(entry.action) accepted a response without the exact requested jobId"
                    )
                } catch let failure as WindowsMCPToolError {
                    #expect(failure.code == .runtimeFailure)
                    #expect(
                        failure.details["machineCode"] as? String
                            == "COMPANION_JOB_ID_MISMATCH"
                    )
                } catch {
                    Issue.record(
                        "Windows task \(entry.action) returned an unexpected job identity error: \(error)"
                    )
                }
            }
        }
    }

    @Test func companionResponsesRequireMatchingTargetSessionAndDVCProof() throws {
        let targetID = UUID()
        let sessionID = UUID()
        let requestedTargetID = targetID.uuidString.lowercased()
        let requestedSessionID = sessionID.uuidString.lowercased()
        let validProvenance: [String: Any] = [
            "targetId": requestedTargetID,
            "sessionId": requestedSessionID,
            "transportProof": ["channel": "companion-dvc"],
        ]
        let cases: [(tool: WindowsMCPToolName, arguments: [String: Any], response: [String: Any])] = [
            (
                .windowsExec,
                [
                    "targetId": requestedTargetID,
                    "sessionId": requestedSessionID,
                    "command": "Get-Date",
                ],
                validProvenance.merging(["ok": true]) { _, new in new }
            ),
            (
                .windowsFiles,
                [
                    "targetId": requestedTargetID,
                    "sessionId": requestedSessionID,
                    "operation": "list",
                    "path": ".",
                ],
                validProvenance.merging(["ok": true, "operation": "list"]) { _, new in new }
            ),
            (
                .windowsTask,
                [
                    "targetId": requestedTargetID,
                    "sessionId": requestedSessionID,
                    "action": "doctor",
                ],
                validProvenance.merging(["ok": false, "state": "notReady"]) { _, new in new }
            ),
        ]

        for testCase in cases {
            _ = try WindowsMCPToolResponse(
                structuredContent: testCase.response
            ).validated(
                for: testCase.tool,
                arguments: testCase.arguments
            )

            if testCase.tool != .windowsTask {
                for invalidOK: Any? in [nil, false, "true"] {
                    var nonSuccess = testCase.response
                    nonSuccess["ok"] = invalidOK
                    do {
                        _ = try WindowsMCPToolResponse(
                            structuredContent: nonSuccess
                        ).validated(
                            for: testCase.tool,
                            arguments: testCase.arguments
                        )
                        Issue.record(
                            "\(testCase.tool.rawValue) accepted a non-success Companion result"
                        )
                    } catch let failure as WindowsMCPToolError {
                        #expect(failure.code == .runtimeFailure)
                    } catch {
                        Issue.record(
                            "\(testCase.tool.rawValue) returned an unexpected error for a non-success result: \(error)"
                        )
                    }
                }
            }

            var missingTarget = testCase.response
            missingTarget.removeValue(forKey: "targetId")
            var mismatchedTarget = testCase.response
            mismatchedTarget["targetId"] = UUID().uuidString.lowercased()
            var missingSession = testCase.response
            missingSession.removeValue(forKey: "sessionId")
            var mismatchedSession = testCase.response
            mismatchedSession["sessionId"] = UUID().uuidString.lowercased()
            var missingProof = testCase.response
            missingProof.removeValue(forKey: "transportProof")
            var mismatchedProof = testCase.response
            mismatchedProof["transportProof"] = ["channel": "desktop-input"]

            let invalidResponses: [(name: String, response: [String: Any])] = [
                ("missing targetId", missingTarget),
                ("mismatched targetId", mismatchedTarget),
                ("missing sessionId", missingSession),
                ("mismatched sessionId", mismatchedSession),
                ("missing transport proof", missingProof),
                ("mismatched transport proof", mismatchedProof),
            ]
            for invalid in invalidResponses {
                do {
                    _ = try WindowsMCPToolResponse(
                        structuredContent: invalid.response
                    ).validated(
                        for: testCase.tool,
                        arguments: testCase.arguments
                    )
                    Issue.record(
                        "\(testCase.tool.rawValue) accepted \(invalid.name)"
                    )
                } catch let failure as WindowsMCPToolError {
                    #expect(failure.code == .runtimeFailure)
                } catch {
                    Issue.record(
                        "\(testCase.tool.rawValue) returned an unexpected error for \(invalid.name): \(error)"
                    )
                }
            }
        }
    }

    @Test func windowsFileTransferPlanUsesDestinationAndBoundedDownloadRange() throws {
        let uploadData = Data("binary-file-content".utf8)
        let upload = try WindowsMCPFileTransferPlan(
            operation: .upload,
            rootID: "workspace",
            path: "local-source.bin",
            arguments: [
                "destinationPath": "remote/output.bin",
                "contentBase64": uploadData.base64EncodedString(),
                "overwrite": true,
            ]
        )
        #expect(upload.sourcePath == "local-source.bin")
        #expect(upload.destinationPath == "remote/output.bin")
        #expect(upload.content == uploadData)
        #expect(upload.length == Int64(uploadData.count))
        #expect(upload.overwrite)

        let download = try WindowsMCPFileTransferPlan(
            operation: .download,
            rootID: "workspace",
            path: "remote/source.bin",
            arguments: [
                "destinationPath": "client/result.bin",
                "offset": 4_096,
                "length": 8_192,
            ]
        )
        #expect(download.sourcePath == "remote/source.bin")
        #expect(download.destinationPath == "client/result.bin")
        #expect(download.offset == 4_096)
        #expect(download.length == 8_192)

        #expect(throws: WindowsMCPToolError.self) {
            try WindowsMCPFileTransferPlan(
                operation: .upload,
                rootID: "workspace",
                path: "source.bin",
                arguments: [
                    "contentBase64": uploadData.base64EncodedString(),
                    "offset": 1,
                ]
            )
        }
        #expect(throws: WindowsMCPToolError.self) {
            try WindowsMCPFileTransferPlan(
                operation: .download,
                rootID: "workspace",
                path: "source.bin",
                arguments: ["length": WindowsMCPFileTransferPlan.maximumBytes + 1]
            )
        }
    }

    @Test func binaryReassemblerAcceptsContiguousFramesAndIdenticalRetransmission() throws {
        let payload = Data("abcdefgh".utf8)
        let transferID = UUID()
        let descriptor = DVCBinaryTransferDescriptor(
            transferID: transferID,
            purpose: "test",
            totalBytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        )
        var reassembler = try DVCBinaryReassembler(
            descriptor: descriptor,
            maximumBytes: 1_024,
            maximumChunkBytes: 4
        )
        let first = DVCBinaryFrame(
            transferID: transferID,
            sequence: 1,
            offset: 0,
            data: payload.subdata(in: 0..<4),
            isFinal: false
        )
        let second = DVCBinaryFrame(
            transferID: transferID,
            sequence: 2,
            offset: 4,
            data: payload.subdata(in: 4..<8),
            isFinal: true
        )

        try reassembler.accept(first)
        try reassembler.accept(first)
        try reassembler.accept(second)
        try reassembler.accept(second)

        #expect(reassembler.receivedByteCount == payload.count)
        #expect(reassembler.sawFinal)
        #expect(try reassembler.verifiedData() == payload)
    }

    @Test func binaryReassemblerRejectsGapOverlapConflictWrongTransferAndFinality() throws {
        let payload = Data("abcdefgh".utf8)
        let transferID = UUID()
        let descriptor = DVCBinaryTransferDescriptor(
            transferID: transferID,
            purpose: "test",
            totalBytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        )
        var reassembler = try DVCBinaryReassembler(
            descriptor: descriptor,
            maximumBytes: 1_024,
            maximumChunkBytes: 4
        )
        try reassembler.accept(DVCBinaryFrame(
            transferID: transferID,
            sequence: 1,
            offset: 0,
            data: Data("abcd".utf8),
            isFinal: false
        ))

        let invalidFrames = [
            DVCBinaryFrame(
                transferID: UUID(),
                sequence: 2,
                offset: 4,
                data: Data("efgh".utf8),
                isFinal: true
            ),
            DVCBinaryFrame(
                transferID: transferID,
                sequence: 3,
                offset: 5,
                data: Data("fgh".utf8),
                isFinal: true
            ),
            DVCBinaryFrame(
                transferID: transferID,
                sequence: 4,
                offset: 2,
                data: Data("cdef".utf8),
                isFinal: false
            ),
            DVCBinaryFrame(
                transferID: transferID,
                sequence: 5,
                offset: 0,
                data: Data("abce".utf8),
                isFinal: false
            ),
            DVCBinaryFrame(
                transferID: transferID,
                sequence: 6,
                offset: 0,
                data: Data("abcd".utf8),
                isFinal: true
            ),
            DVCBinaryFrame(
                transferID: transferID,
                sequence: 7,
                offset: 4,
                data: Data("ef".utf8),
                isFinal: true
            ),
            DVCBinaryFrame(
                transferID: transferID,
                sequence: 8,
                offset: Int64.max,
                data: Data([0x00]),
                isFinal: false
            ),
        ]

        for frame in invalidFrames {
            #expect(throws: DVCBinaryReassemblyError.invalidChunk) {
                try reassembler.accept(frame)
            }
        }
        #expect(reassembler.receivedByteCount == 4)
        #expect(!reassembler.sawFinal)
    }

    @Test func binaryReassemblerRequiresBoundedDescriptorFinalFrameAndExactHash() throws {
        let transferID = UUID()
        let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()

        #expect(throws: DVCBinaryReassemblyError.invalidDescriptor) {
            _ = try DVCBinaryReassembler(
                descriptor: DVCBinaryTransferDescriptor(
                    transferID: transferID,
                    purpose: "test",
                    totalBytes: -1,
                    sha256: emptyHash
                ),
                maximumBytes: 1_024,
                maximumChunkBytes: 4
            )
        }
        #expect(throws: DVCBinaryReassemblyError.invalidDescriptor) {
            _ = try DVCBinaryReassembler(
                descriptor: DVCBinaryTransferDescriptor(
                    transferID: transferID,
                    purpose: "test",
                    totalBytes: 1_025,
                    sha256: emptyHash
                ),
                maximumBytes: 1_024,
                maximumChunkBytes: 4
            )
        }
        #expect(throws: DVCBinaryReassemblyError.invalidDescriptor) {
            _ = try DVCBinaryReassembler(
                descriptor: DVCBinaryTransferDescriptor(
                    transferID: transferID,
                    purpose: "test",
                    totalBytes: 0,
                    sha256: "not-a-digest"
                ),
                maximumBytes: 1_024,
                maximumChunkBytes: 4
            )
        }

        let payload = Data("abcd".utf8)
        var incomplete = try DVCBinaryReassembler(
            descriptor: DVCBinaryTransferDescriptor(
                transferID: transferID,
                purpose: "test",
                totalBytes: 8,
                sha256: String(repeating: "0", count: 64)
            ),
            maximumBytes: 1_024,
            maximumChunkBytes: 4
        )
        try incomplete.accept(DVCBinaryFrame(
            transferID: transferID,
            sequence: 1,
            offset: 0,
            data: payload,
            isFinal: false
        ))
        #expect(throws: DVCBinaryReassemblyError.incomplete) {
            _ = try incomplete.verifiedData()
        }
        #expect(throws: DVCBinaryReassemblyError.invalidChunk) {
            try incomplete.accept(DVCBinaryFrame(
                transferID: transferID,
                sequence: 2,
                offset: 4,
                data: Data("efgh".utf8),
                isFinal: false
            ))
        }

        var wrongHash = try DVCBinaryReassembler(
            descriptor: DVCBinaryTransferDescriptor(
                transferID: transferID,
                purpose: "test",
                totalBytes: Int64(payload.count),
                sha256: String(repeating: "0", count: 64)
            ),
            maximumBytes: 1_024,
            maximumChunkBytes: 4
        )
        try wrongHash.accept(DVCBinaryFrame(
            transferID: transferID,
            sequence: 1,
            offset: 0,
            data: payload,
            isFinal: true
        ))
        #expect(throws: DVCBinaryReassemblyError.hashMismatch) {
            _ = try wrongHash.verifiedData()
        }

        var empty = try DVCBinaryReassembler(
            descriptor: DVCBinaryTransferDescriptor(
                transferID: transferID,
                purpose: "test",
                totalBytes: 0,
                sha256: emptyHash
            ),
            maximumBytes: 1_024,
            maximumChunkBytes: 4
        )
        let emptyFinal = DVCBinaryFrame(
            transferID: transferID,
            sequence: 1,
            offset: 0,
            data: Data(),
            isFinal: true
        )
        try empty.accept(emptyFinal)
        try empty.accept(emptyFinal)
        #expect(try empty.verifiedData().isEmpty)
    }

    @Test func companionBinaryUploadChunksLargePayloadAndFinalizesHashBoundTransfer() async throws {
        let data = Data((0..<(5 * 1_024 * 1_024 + 17)).map { UInt8(truncatingIfNeeded: $0) })
        var sent = Data()
        var chunkCount = 0
        let manager = WindowsCompanionBinaryTransferManager(
            request: { method, parameters, _ in
                let transferID = try #require(parameters["transferId"] as? String)
                switch method {
                case "transfer.begin":
                    let totalBytes = try #require(parameters["totalBytes"] as? Int64)
                    let sha256 = try #require(parameters["sha256"] as? String)
                    return [
                        "transferId": transferID,
                        "totalBytes": totalBytes,
                        "sha256": sha256,
                        "nextOffset": 0,
                        "completed": false,
                    ]
                case "transfer.finalize":
                    return [
                        "transferId": transferID,
                        "totalBytes": data.count,
                        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        "completed": true,
                    ]
                case "transfer.release":
                    return ["transferId": transferID, "released": true]
                default:
                    Issue.record("Unexpected transfer method: \(method)")
                    return [:]
                }
            },
            sendChunk: { _, offset, chunk, isFinal in
                #expect(offset == Int64(sent.count))
                sent.append(chunk)
                chunkCount += 1
                #expect(isFinal == (sent.count == data.count))
            }
        )

        let descriptor = try await manager.upload(
            data,
            purpose: "vrc-worker-submit",
            deadlineMilliseconds: 30_000
        )

        #expect(sent == data)
        #expect(chunkCount == 2)
        #expect(descriptor.totalBytes == Int64(data.count))
        #expect(descriptor.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    @Test func companionBinaryTransferSupportsEmptyFilesAndCallerSpecificDownloadLimit() async throws {
        var sentFrames: [(offset: Int64, data: Data, final: Bool)] = []
        let emptySHA256 = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let manager = WindowsCompanionBinaryTransferManager(
            request: { method, parameters, _ in
                let transferID = try #require(parameters["transferId"] as? String)
                switch method {
                case "transfer.begin":
                    return [
                        "transferId": transferID,
                        "totalBytes": 0,
                        "sha256": emptySHA256,
                        "nextOffset": 0,
                        "completed": false,
                    ]
                case "transfer.finalize":
                    return [
                        "transferId": transferID,
                        "totalBytes": 0,
                        "sha256": emptySHA256,
                        "completed": true,
                    ]
                case "transfer.release":
                    return ["transferId": transferID, "released": true]
                default:
                    Issue.record("Unexpected transfer method: \(method)")
                    return [:]
                }
            },
            sendChunk: { _, offset, data, final in
                sentFrames.append((offset, data, final))
            }
        )

        let uploaded = try await manager.upload(
            Data(),
            purpose: "file-upload",
            deadlineMilliseconds: 30_000,
            maximumBytes: WindowsMCPFileTransferPlan.maximumBytes
        )

        #expect(uploaded.totalBytes == 0)
        #expect(uploaded.sha256 == emptySHA256)
        #expect(sentFrames.count == 1)
        #expect(sentFrames[0].offset == 0)
        #expect(sentFrames[0].data.isEmpty)
        #expect(sentFrames[0].final)

        let oversized = DVCBinaryTransferDescriptor(
            transferID: UUID(),
            purpose: "file-download",
            totalBytes: WindowsMCPFileTransferPlan.maximumBytes + 1,
            sha256: emptySHA256
        )
        await #expect(throws: WindowsCompanionRequestFailure.self) {
            try await manager.download(
                oversized,
                deadlineMilliseconds: 30_000,
                maximumBytes: WindowsMCPFileTransferPlan.maximumBytes
            )
        }
    }

    @Test func companionBinaryDownloadResumesAfterRetryableInterruption() async throws {
        let data = Data((0..<(6 * 1_024 * 1_024 + 29)).map { UInt8(truncatingIfNeeded: $0) })
        let transferID = UUID()
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let descriptor = DVCBinaryTransferDescriptor(
            transferID: transferID,
            purpose: "vrc-worker-result",
            totalBytes: Int64(data.count),
            sha256: sha256
        )
        var downloadCalls = 0
        let managerBox = BinaryTransferManagerBox()
        let manager = WindowsCompanionBinaryTransferManager(
            request: { method, parameters, _ in
                if method == "transfer.release" {
                    return ["transferId": transferID.uuidString.lowercased(), "released": true]
                }
                #expect(method == "transfer.download")
                let offset = (parameters["offset"] as? NSNumber)?.intValue
                    ?? parameters["offset"] as? Int
                    ?? -1
                downloadCalls += 1
                if downloadCalls == 1 {
                    #expect(offset == 0)
                    let activeManager = try #require(managerBox.value)
                    try activeManager.receive(DVCBinaryFrame(
                        transferID: transferID,
                        sequence: 1,
                        offset: 0,
                        data: data.subdata(in: 0..<(4 * 1_024 * 1_024)),
                        isFinal: false
                    ))
                    throw WindowsCompanionRequestFailure(
                        code: "INTERNAL_ERROR",
                        message: "Simulated interrupted DVC send.",
                        retryable: true
                    )
                }
                #expect(offset == 4 * 1_024 * 1_024)
                let activeManager = try #require(managerBox.value)
                try activeManager.receive(DVCBinaryFrame(
                    transferID: transferID,
                    sequence: 2,
                    offset: Int64(offset),
                    data: data.subdata(in: offset..<data.count),
                    isFinal: true
                ))
                return [
                    "transferId": transferID.uuidString.lowercased(),
                    "totalBytes": data.count,
                    "sha256": sha256,
                    "completed": true,
                ]
            },
            sendChunk: { _, _, _, _ in }
        )
        managerBox.value = manager

        let downloaded = try await manager.download(descriptor, deadlineMilliseconds: 30_000)

        #expect(downloadCalls == 2)
        #expect(downloaded == data)
    }

    @Test func companionBinaryDownloadRejectsCompletePayloadWithWrongDigest() async throws {
        let data = Data("result-zip".utf8)
        let transferID = UUID()
        let descriptor = DVCBinaryTransferDescriptor(
            transferID: transferID,
            purpose: "vrc-worker-result",
            totalBytes: Int64(data.count),
            sha256: String(repeating: "0", count: 64)
        )
        var manager: WindowsCompanionBinaryTransferManager!
        manager = WindowsCompanionBinaryTransferManager(
            request: { method, _, _ in
                if method == "transfer.release" {
                    return ["transferId": transferID.uuidString.lowercased(), "released": true]
                }
                try manager.receive(DVCBinaryFrame(
                    transferID: transferID,
                    sequence: 1,
                    offset: 0,
                    data: data,
                    isFinal: true
                ))
                return [
                    "transferId": transferID.uuidString.lowercased(),
                    "totalBytes": data.count,
                    "sha256": descriptor.sha256,
                    "completed": true,
                ]
            },
            sendChunk: { _, _, _, _ in }
        )

        await #expect(throws: WindowsCompanionRequestFailure.self) {
            try await manager.download(descriptor, deadlineMilliseconds: 30_000)
        }
    }

    private static func jsonObject(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private static func waitUntil(
        timeout: Duration,
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    private static func desktopState(
        sessionID: UUID,
        targetID: UUID,
        phase: RDPConnectionPhase
    ) -> RDPDesktopSessionState {
        RDPDesktopSessionState(
            sessionID: sessionID,
            targetID: targetID,
            phase: phase,
            runtimeAvailability: phase == .connected ? .available : .starting,
            companion: .unknown,
            stateRevision: 0,
            latestFrameID: nil,
            remotePixelWidth: nil,
            remotePixelHeight: nil,
            connectedAt: nil,
            reconnectAttempt: nil,
            reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil,
            lastErrorCode: nil,
            lastErrorMessage: nil
        )
    }

    private static func certificateStateFixture(sessionID: UUID) -> [String: Any] {
        [
            "sessionId": sessionID.uuidString.lowercased(),
            "host": "rdp.example.test",
            "port": NSNumber(value: 3_389),
            "commonName": "rdp.example.test",
            "subject": "CN=rdp.example.test",
            "issuer": "CN=Test CA",
            "sha256": String(repeating: "A", count: 64),
            "oldSha256": "",
            "changed": false,
            "hostMismatch": false,
            "pinnedMismatch": false,
        ]
    }

    private static func toolResult(_ line: String) throws -> [String: Any] {
        let object = try jsonObject(line)
        return try #require(object["result"] as? [String: Any])
    }

    private static func toolStructuredContent(_ line: String) throws -> [String: Any] {
        let result = try toolResult(line)
        return try #require(result["structuredContent"] as? [String: Any])
    }

    private static let swiftRequestFixtureHex = "4A545344000101010102030405060708000000EE639F36787B2270726F746F636F6C56657273696F6E223A312C22726571756573744964223A2230303131323233332D343435352D363637372D383839392D616162626363646465656666222C226D6574686F64223A22636F6D70616E696F6E2E68656C6C6F222C22646561646C696E65556E69784D696C6C697365636F6E6473223A313730303030303030303030302C226964656D706F74656E63794B6579223A22666978747572652D31222C22657870656374656453746174655265766973696F6E223A372C22706172616D6574657273223A7B22636C69656E744E616D65223A224A5453205465726D696E616C227D7D"

    private static let dotNetResponseFixtureHex = "4A5453440001010100000000000000090000006FCB33D9AE7B2270726F746F636F6C56657273696F6E223A312C22726571756573744964223A2230303131323233332D343435352D363637372D383839392D616162626363646465656666222C2273756363657373223A747275652C22726573756C74223A7B227265616479223A747275657D7D"

    private static let binaryFixtureHex = "4A54534400010201000000000000000A00000048F3F67DED33221100554477668899AABBCCDDEEFF0000000000001000010000000B2DA5FCCB1C91B935DBEC5F8061B905162C9D33B0FF6E71B01A9A06BF66AEF55262696E6172792D64617461"
    private static let onePixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    private static func hexadecimal(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private static func data(hexadecimal value: String) throws -> Data {
        #expect(value.count.isMultiple(of: 2))
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            data.append(try #require(UInt8(value[index..<next], radix: 16)))
            index = next
        }
        return data
    }
}

private enum XPCRequestCoordinatorTestError: Error, Equatable {
    case helperInvalidated
    case lateReply
}

nonisolated private final class ManualXPCRequestDeadlineToken: XPCRequestDeadlineToken, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var fired = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        if !fired {
            cancelled = true
        }
        lock.unlock()
    }

    func fire(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !cancelled, !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        action()
    }
}

nonisolated private final class ManualXPCRequestDeadlineScheduler: XPCRequestDeadlineScheduling, @unchecked Sendable {
    private struct ScheduledAction {
        let delaySeconds: TimeInterval
        let token: ManualXPCRequestDeadlineToken
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var scheduled: [ScheduledAction] = []
    private var tokens: [ManualXPCRequestDeadlineToken] = []

    var scheduledDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return scheduled.map(\.delaySeconds)
    }

    var cancelledTokenCount: Int {
        lock.lock()
        let tokens = self.tokens
        lock.unlock()
        return tokens.filter(\.isCancelled).count
    }

    func schedule(
        after delaySeconds: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any XPCRequestDeadlineToken {
        let token = ManualXPCRequestDeadlineToken()
        lock.lock()
        scheduled.append(ScheduledAction(
            delaySeconds: delaySeconds,
            token: token,
            action: action
        ))
        tokens.append(token)
        lock.unlock()
        return token
    }

    func fireNext() {
        lock.lock()
        guard !scheduled.isEmpty else {
            lock.unlock()
            return
        }
        let scheduledAction = scheduled.removeFirst()
        lock.unlock()
        scheduledAction.token.fire(scheduledAction.action)
    }
}

nonisolated private final class XPCRequestCompletionCapture<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<Value, Error>) -> Void)?

    var isStored: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    func store(_ completion: @escaping (Result<Value, Error>) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        let completion = self.completion
        lock.unlock()
        completion?(result)
    }
}

private extension DVCFrame {
    var controlFrame: DVCControlFrame? {
        guard case .control(let frame) = self else { return nil }
        return frame
    }
}
#endif
