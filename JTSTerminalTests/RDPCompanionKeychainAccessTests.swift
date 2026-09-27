#if ENABLE_RDP_2
import CryptoKit
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct RDPCompanionKeychainAccessTests {
    @Test func companionIdentityLoadDoesNotBlockMainActor() async throws {
        let (started, startedContinuation) = AsyncStream<Bool>.makeStream()
        let releaseWorker = DispatchSemaphore(value: 0)
        let signingKey = P256.Signing.PrivateKey()
        let clientDeviceID = UUID()
        let backend = backend(
            signingKey: { _ in
                startedContinuation.yield(Thread.isMainThread)
                _ = releaseWorker.wait(timeout: .now() + 5)
                return signingKey
            },
            clientDeviceID: { _ in clientDeviceID }
        )
        let access = RDPCompanionKeychainAccess(
            queueLabel: "com.lljts.JTSTerminalTests.rdp-companion-keychain-access.identity",
            backend: backend
        )

        let identityTask = Task {
            try await access.localIdentity(targetID: UUID())
        }
        var startedIterator = started.makeAsyncIterator()

        // This resumes on the main actor while the simulated Keychain read is
        // still blocked, proving the Companion handshake cannot stall AppKit.
        #expect(await startedIterator.next() == false)
        releaseWorker.signal()

        let identity = try await identityTask.value
        #expect(identity.clientDeviceID == clientDeviceID)
        #expect(
            identity.signingKey.publicKey.derRepresentation
                == signingKey.publicKey.derRepresentation
        )
    }

    @Test func companionPeerPinWriteDoesNotBlockMainActor() async throws {
        let (started, startedContinuation) = AsyncStream<Bool>.makeStream()
        let releaseWorker = DispatchSemaphore(value: 0)
        let targetID = UUID()
        let access = RDPCompanionKeychainAccess(
            queueLabel: "com.lljts.JTSTerminalTests.rdp-companion-keychain-access.peer-pin",
            backend: backend(savePeerFingerprint: { _, receivedTargetID in
                #expect(receivedTargetID == targetID)
                startedContinuation.yield(Thread.isMainThread)
                _ = releaseWorker.wait(timeout: .now() + 5)
            })
        )

        let saveTask = Task {
            try await access.savePeerFingerprint(String(repeating: "A", count: 64), targetID: targetID)
        }
        var startedIterator = started.makeAsyncIterator()

        #expect(await startedIterator.next() == false)
        releaseWorker.signal()
        try await saveTask.value
    }

    @Test func companionIdentityIsReadOnlyOncePerTargetDuringProcessLifetime() async throws {
        let signingKey = P256.Signing.PrivateKey()
        let clientDeviceID = UUID()
        let signingKeyReads = LockedInvocationCounter()
        let clientDeviceReads = LockedInvocationCounter()
        let access = RDPCompanionKeychainAccess(
            queueLabel: "com.lljts.JTSTerminalTests.rdp-companion-keychain-access.cache",
            backend: backend(
                signingKey: { _ in
                    signingKeyReads.increment()
                    return signingKey
                },
                clientDeviceID: { _ in
                    clientDeviceReads.increment()
                    return clientDeviceID
                }
            )
        )
        let targetID = UUID()

        _ = try await access.localIdentity(targetID: targetID)
        _ = try await access.localIdentity(targetID: targetID)
        _ = try await access.signingKey(targetID: targetID)

        #expect(signingKeyReads.value == 1)
        #expect(clientDeviceReads.value == 1)
    }

    private func backend(
        signingKey: @escaping @Sendable (UUID) throws -> P256.Signing.PrivateKey = { _ in
            P256.Signing.PrivateKey()
        },
        clientDeviceID: @escaping @Sendable (UUID) throws -> UUID = { _ in UUID() },
        savePeerFingerprint: @escaping @Sendable (String, UUID) throws -> Void = { _, _ in }
    ) -> RDPCompanionKeychainBackend {
        RDPCompanionKeychainBackend(
            signingKey: signingKey,
            clientDeviceID: clientDeviceID,
            deletePairing: { _ in },
            savePeerFingerprint: savePeerFingerprint,
            readPeerFingerprint: { _ in nil },
            deletePeer: { _ in }
        )
    }
}

nonisolated private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
#endif
