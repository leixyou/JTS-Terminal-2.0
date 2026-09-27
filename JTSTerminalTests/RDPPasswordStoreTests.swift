#if ENABLE_RDP_2
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct RDPPasswordStoreTests {
    @Test func passwordReadRunsOffMainThreadWithoutBlockingMainActor() async throws {
        let (started, startedContinuation) = AsyncStream<Bool>.makeStream()
        let releaseWorker = DispatchSemaphore(value: 0)
        let targetID = UUID()
        let fake = InMemoryRDPPasswordBackend()
        fake.onReadVault = {
            startedContinuation.yield(Thread.isMainThread)
            _ = releaseWorker.wait(timeout: .now() + 5)
        }
        fake.setVault("credential", account: RDPPasswordStore.account(targetID: targetID))
        let access = RDPPasswordAccess(
            queueLabel: "com.lljts.JTSTerminalTests.rdp-password-access",
            backend: fake.backend
        )

        let readTask = Task {
            try await access.readPassword(targetID: targetID)
        }
        var startedIterator = started.makeAsyncIterator()

        // Reaching this assertion while the worker is still waiting proves the
        // caller's main actor remained available during the blocking read.
        #expect(await startedIterator.next() == false)
        releaseWorker.signal()
        #expect(try await readTask.value == "credential")
    }

    @Test func directKeychainMigrationWritesCanonicalBeforeDeletingLegacyItems() throws {
        let targetID = UUID()
        let accounts = legacyAccounts()
        let scopedAccount = accounts[0].account
        let sharedAccount = accounts[1].account
        let canonicalAccount = RDPPasswordStore.account(targetID: targetID)
        let fake = InMemoryRDPPasswordBackend()
        fake.legacyKeychainPassword = "current-credential"
        fake.setVault("scoped-legacy", account: scopedAccount)
        fake.setVault("shared-legacy", account: sharedAccount)

        let password = try RDPPasswordStore.readOrMigratePassword(
            targetID: targetID,
            legacyVaultAccounts: accounts,
            backend: fake.backend
        )

        #expect(password == "current-credential")
        #expect(fake.vaultValue(account: canonicalAccount) == "current-credential")
        #expect(fake.vaultValue(account: scopedAccount) == nil)
        #expect(fake.vaultValue(account: sharedAccount) == "shared-legacy")
        #expect(fake.legacyKeychainPassword == nil)

        let events = fake.events
        let canonicalSave = try #require(events.firstIndex(of: "save:\(canonicalAccount)"))
        let keychainDelete = try #require(events.firstIndex(of: "delete-keychain"))
        let scopedDelete = try #require(events.firstIndex(of: "delete:\(scopedAccount)"))
        #expect(canonicalSave < keychainDelete)
        #expect(canonicalSave < scopedDelete)
    }

    @Test func canonicalVaultPasswordTakesPrecedenceOverAllLegacySources() throws {
        let targetID = UUID()
        let accounts = legacyAccounts()
        let canonicalAccount = RDPPasswordStore.account(targetID: targetID)
        let fake = InMemoryRDPPasswordBackend()
        fake.setVault("canonical-credential", account: canonicalAccount)
        fake.setVault("legacy-credential", account: accounts[0].account)
        fake.legacyKeychainPassword = "keychain-credential"

        let password = try RDPPasswordStore.readOrMigratePassword(
            targetID: targetID,
            legacyVaultAccounts: accounts,
            backend: fake.backend
        )

        #expect(password == "canonical-credential")
        #expect(fake.vaultValue(account: canonicalAccount) == "canonical-credential")
        #expect(!fake.events.contains("read-keychain"))
        #expect(fake.legacyKeychainPassword == nil)
    }

    @Test func genericLegacyVaultPasswordIsCopiedButPreservedForPossibleSSHOwner() throws {
        let targetID = UUID()
        let accounts = legacyAccounts()
        let sharedAccount = accounts[1].account
        let fake = InMemoryRDPPasswordBackend()
        fake.setVault("legacy-credential", account: sharedAccount)

        let password = try RDPPasswordStore.readOrMigratePassword(
            targetID: targetID,
            legacyVaultAccounts: accounts,
            backend: fake.backend
        )

        #expect(password == "legacy-credential")
        #expect(
            fake.vaultValue(account: RDPPasswordStore.account(targetID: targetID))
                == "legacy-credential"
        )
        #expect(fake.vaultValue(account: sharedAccount) == "legacy-credential")
    }

    @Test func passwordDeletionIsIdempotentAndPreservesPossiblySharedLegacyAccount() throws {
        let targetID = UUID()
        let accounts = legacyAccounts()
        let canonicalAccount = RDPPasswordStore.account(targetID: targetID)
        let scopedAccount = accounts[0].account
        let sharedAccount = accounts[1].account
        let fake = InMemoryRDPPasswordBackend()
        fake.setVault("canonical-credential", account: canonicalAccount)
        fake.setVault("scoped-legacy", account: scopedAccount)
        fake.setVault("shared-credential", account: sharedAccount)
        fake.legacyKeychainPassword = "keychain-credential"

        try RDPPasswordStore.deletePassword(
            targetID: targetID,
            legacyVaultAccounts: accounts,
            backend: fake.backend
        )
        try RDPPasswordStore.deletePassword(
            targetID: targetID,
            legacyVaultAccounts: accounts,
            backend: fake.backend
        )

        #expect(fake.vaultValue(account: canonicalAccount) == nil)
        #expect(fake.vaultValue(account: scopedAccount) == nil)
        #expect(fake.vaultValue(account: sharedAccount) == "shared-credential")
        #expect(fake.legacyKeychainPassword == nil)
    }

    @Test func targetSpecificAccountDoesNotChangeWithConnectionProperties() {
        let targetID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        #expect(
            RDPPasswordStore.account(targetID: targetID)
                == "rdp-target:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
    }

    private func legacyAccounts() -> [RDPLegacyVaultAccount] {
        RDPPasswordStore.legacyVaultAccounts(
            username: "user",
            host: "host",
            port: 3389,
            domain: ""
        )
    }
}

nonisolated private final class InMemoryRDPPasswordBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var storedVault: [String: String] = [:]
    private var storedLegacyKeychainPassword: String?
    private var storedEvents: [String] = []
    private var storedOnReadVault: (@Sendable () -> Void)?

    var legacyKeychainPassword: String? {
        get { withLock { storedLegacyKeychainPassword } }
        set { withLock { storedLegacyKeychainPassword = newValue } }
    }

    var events: [String] {
        withLock { storedEvents }
    }

    var onReadVault: (@Sendable () -> Void)? {
        get { withLock { storedOnReadVault } }
        set { withLock { storedOnReadVault = newValue } }
    }

    var backend: RDPPasswordStoreBackend {
        RDPPasswordStoreBackend(
            saveVault: { [weak self] secret, account in
                self?.withLock {
                    self?.storedEvents.append("save:\(account)")
                    self?.storedVault[account] = secret
                }
            },
            readVault: { [weak self] account in
                guard let self else { return nil }
                let callback = self.withLock { self.storedOnReadVault }
                callback?()
                return self.withLock {
                    self.storedEvents.append("read:\(account)")
                    return self.storedVault[account]
                }
            },
            deleteVault: { [weak self] account in
                self?.withLock {
                    self?.storedEvents.append("delete:\(account)")
                    self?.storedVault.removeValue(forKey: account)
                }
            },
            readLegacyKeychain: { [weak self] _ in
                self?.withLock {
                    self?.storedEvents.append("read-keychain")
                    return self?.storedLegacyKeychainPassword
                }
            },
            deleteLegacyKeychain: { [weak self] _ in
                self?.withLock {
                    self?.storedEvents.append("delete-keychain")
                    self?.storedLegacyKeychainPassword = nil
                }
            }
        )
    }

    func setVault(_ secret: String, account: String) {
        withLock { storedVault[account] = secret }
    }

    func vaultValue(account: String) -> String? {
        withLock { storedVault[account] }
    }

    @discardableResult
    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
#endif
