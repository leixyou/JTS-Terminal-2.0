#if ENABLE_RDP_2
import Darwin
import Foundation

/// Private metadata, descriptor-relative I/O, and an interprocess lock keep a
/// stale reader from overwriting a durable revocation tombstone.
nonisolated struct CompanionPairingDelegationPersistence {
    var directoryURL: URL
    private static let fileName = "device-pairing-delegations-v1.json"
    private static let maximumBytes = 4 * 1_024 * 1_024

    private struct State: Codable {
        var schemaVersion = 1
        var grants: [CompanionPairingDelegationGrant]
    }

    func transaction<T>(
        _ body: (inout [CompanionPairingDelegationGrant]) throws -> T
    ) throws -> (T, [CompanionPairingDelegationGrant]) {
        try PrivateFileSecurity.secureDirectory(at: directoryURL)
        let directory = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw CompanionPairingDelegationFailure.storageUnavailable }
        defer { Darwin.close(directory) }
        try PrivateFileSecurity.verifyPrivateDirectoryDescriptor(directory)
        let lock = openat(directory, ".delegations.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw CompanionPairingDelegationFailure.storageUnavailable }
        defer { Darwin.close(lock) }
        try PrivateFileSecurity.securePrivateFileDescriptor(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw CompanionPairingDelegationFailure.storageUnavailable
        }
        defer { flock(lock, LOCK_UN) }

        var grants = try read(directory: directory)
        let previous = grants
        let value = try body(&grants)
        if grants != previous {
            try validate(grants)
            try write(grants, directory: directory)
        }
        return (value, grants)
    }

    private func read(directory: Int32) throws -> [CompanionPairingDelegationGrant] {
        let descriptor = openat(directory, Self.fileName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return [] }
            throw CompanionPairingDelegationFailure.storageUnavailable
        }
        defer { Darwin.close(descriptor) }
        try PrivateFileSecurity.verifyPrivateFileDescriptor(descriptor)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size > 0, status.st_size <= Self.maximumBytes else {
            throw CompanionPairingDelegationFailure.storageUnavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else {
            throw CompanionPairingDelegationFailure.storageUnavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(State.self, from: data)
        guard state.schemaVersion == 1 else { throw CompanionPairingDelegationFailure.invalidRecord }
        try validate(state.grants)
        return state.grants
    }

    private func validate(_ grants: [CompanionPairingDelegationGrant]) throws {
        guard grants.count <= 10_000,
              Set(grants.map(\.grantID)).count == grants.count else {
            throw CompanionPairingDelegationFailure.invalidRecord
        }
        var activeTargets: Set<UUID> = []
        for grant in grants {
            try grant.validate()
            if !grant.isRevoked, !activeTargets.insert(grant.targetID).inserted {
                throw CompanionPairingDelegationFailure.invalidRecord
            }
        }
    }

    private func write(_ grants: [CompanionPairingDelegationGrant], directory: Int32) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(State(grants: grants))
        guard data.count <= Self.maximumBytes else { throw CompanionPairingDelegationFailure.storageUnavailable }
        let temporary = ".delegations.\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CompanionPairingDelegationFailure.storageUnavailable }
        defer {
            Darwin.close(descriptor)
            unlinkat(directory, temporary, 0)
        }
        try PrivateFileSecurity.securePrivateFileDescriptor(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard renameat(directory, temporary, directory, Self.fileName) == 0 else {
            throw CompanionPairingDelegationFailure.storageUnavailable
        }
        // A successful rename has committed. Do not report a rollback if this
        // filesystem cannot synchronize directory entries.
        _ = fsync(directory)
    }
}
#endif
