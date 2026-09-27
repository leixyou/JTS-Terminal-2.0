#if ENABLE_RDP_2
import Combine
import CryptoKit
import Darwin
import Foundation

nonisolated enum RemoteCapabilityAuditResult: String, Codable, Sendable {
    case succeeded
    case denied
    case failed
    case approved
    case revoked
}

/// Deliberately contains no free-form arguments or output. In particular, this
/// model cannot persist a screenshot, typed text, password, complete command,
/// clipboard value, file path, or file contents.
nonisolated struct RemoteCapabilityAuditRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var clientID: String
    var clientDisplayIdentity: String
    var targetID: UUID
    var targetAlias: String
    var actionType: String
    var capabilityNames: [String]
    var result: RemoteCapabilityAuditResult
    var resultCode: String
    var controlLeaseExpiresAt: Date?
    var startedAt: Date
    var finishedAt: Date

    var durationMilliseconds: Int {
        let milliseconds = max(0, finishedAt.timeIntervalSince(startedAt) * 1_000)
        return milliseconds >= Double(Int.max) ? Int.max : Int(milliseconds.rounded())
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case clientID
        case clientDisplayIdentity
        case targetID
        case targetAlias
        case actionType
        case capabilityNames
        case result
        case resultCode
        case controlLeaseExpiresAt
        case startedAt
        case finishedAt
    }

    init(
        id: UUID,
        clientID: String,
        clientDisplayIdentity: String? = nil,
        targetID: UUID,
        targetAlias: String,
        actionType: String,
        capabilityNames: [String],
        result: RemoteCapabilityAuditResult,
        resultCode: String,
        controlLeaseExpiresAt: Date?,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.id = id
        self.clientID = RemoteCapabilityAuditStore.sanitizedLabel(
            clientID,
            maximumLength: 160
        )
        self.clientDisplayIdentity = MCPClientDisplayIdentity.resolved(
            clientDisplayIdentity,
            authorizationID: self.clientID
        )
        self.targetID = targetID
        self.targetAlias = RemoteCapabilityAuditStore.sanitizedLabel(
            targetAlias,
            maximumLength: 120
        )
        self.actionType = RemoteCapabilityAuditStore.sanitizedActionType(actionType)
        self.capabilityNames = Array(Set(capabilityNames.compactMap {
            RemoteCapability(rawValue: $0)?.rawValue
        })).sorted()
        self.result = result
        self.resultCode = RemoteCapabilityAuditStore.sanitizedResultCode(resultCode)
        self.controlLeaseExpiresAt = controlLeaseExpiresAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let clientID = try container.decode(String.self, forKey: .clientID)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            clientID: clientID,
            clientDisplayIdentity: try container.decodeIfPresent(
                String.self,
                forKey: .clientDisplayIdentity
            ),
            targetID: try container.decode(UUID.self, forKey: .targetID),
            targetAlias: try container.decode(String.self, forKey: .targetAlias),
            actionType: try container.decode(String.self, forKey: .actionType),
            capabilityNames: try container.decode([String].self, forKey: .capabilityNames),
            result: try container.decode(RemoteCapabilityAuditResult.self, forKey: .result),
            resultCode: try container.decode(String.self, forKey: .resultCode),
            controlLeaseExpiresAt: try container.decodeIfPresent(
                Date.self,
                forKey: .controlLeaseExpiresAt
            ),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            finishedAt: try container.decode(Date.self, forKey: .finishedAt)
        )
    }
}

@MainActor
final class RemoteCapabilityAuditStore: ObservableObject {
    static let shared = RemoteCapabilityAuditStore()
    nonisolated static let defaultRetentionDays = 30
    private static let maximumRecordCount = 20_000
    private static let maximumPersistedStateBytes = 16 * 1_024 * 1_024
    private static let exclusiveLockTimeout: TimeInterval = 0.1
    private static let exclusiveLockRetryMicroseconds: useconds_t = 5_000

    @Published private(set) var records: [RemoteCapabilityAuditRecord]
    @Published private(set) var persistenceError: String?

    private struct PersistedState: Codable {
        var formatVersion = 2
        var records: [RemoteCapabilityAuditRecord]
    }

    private struct RedactedExportRecord: Encodable {
        struct Client: Encodable {
            var reference: String
            var displayIdentity: String
        }

        struct Target: Encodable {
            var id: UUID
            var alias: String
        }

        struct Action: Encodable {
            var category: String
            var capabilityScopes: [String]
        }

        struct Result: Encodable {
            var status: RemoteCapabilityAuditResult
            var code: String
        }

        struct Lease: Encodable {
            var expiresAt: Date?

            private enum CodingKeys: String, CodingKey {
                case expiresAt
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let expiresAt {
                    try container.encode(expiresAt, forKey: .expiresAt)
                } else {
                    try container.encodeNil(forKey: .expiresAt)
                }
            }
        }

        struct TimeRange: Encodable {
            var startedAt: Date
            var finishedAt: Date
        }

        var client: Client
        var target: Target
        var action: Action
        var result: Result
        var lease: Lease
        var durationMilliseconds: Int
        var time: TimeRange

        init(record: RemoteCapabilityAuditRecord) {
            client = Client(
                reference: RemoteCapabilityAuditStore.redactedClientReference(record.clientID),
                displayIdentity: record.clientDisplayIdentity
            )
            target = Target(id: record.targetID, alias: record.targetAlias)
            action = Action(
                category: record.actionType,
                capabilityScopes: record.capabilityNames
            )
            result = Result(status: record.result, code: record.resultCode)
            lease = Lease(expiresAt: record.controlLeaseExpiresAt)
            durationMilliseconds = record.durationMilliseconds
            time = TimeRange(
                startedAt: record.startedAt,
                finishedAt: record.finishedAt
            )
        }
    }

    private let storageURL: URL
    private let lockURL: URL
    private let retentionDays: Int
    private var lastLoadedStorageStamp: String?
    private var requiresReload: Bool
    private var nextRetentionPruneAt: Date?

    init(
        storageURL: URL? = nil,
        retentionDays: Int = RemoteCapabilityAuditStore.defaultRetentionDays,
        now: Date = Date()
    ) {
        let resolvedStorageURL = storageURL ?? Self.defaultStorageURL()
        self.storageURL = resolvedStorageURL
        // The data file is atomically replaced on every persist, so its inode
        // cannot be used as a cross-process lock. This stable sibling survives
        // those replacements and coordinates the GUI and MCP processes.
        self.lockURL = resolvedStorageURL.appendingPathExtension("lock")
        self.retentionDays = max(1, retentionDays)
        self.records = []
        self.persistenceError = nil
        self.lastLoadedStorageStamp = nil
        self.requiresReload = true
        self.nextRetentionPruneAt = nil

        do {
            applySnapshot(try loadLatestAndPrune(now: now))
        } catch {
            // Do not expose an unverified snapshot when the initial locked read
            // or retention persist fails.
            invalidateSnapshot(for: error)
        }
    }

    func records(targetID: UUID) -> [RemoteCapabilityAuditRecord] {
        records
            .filter { $0.targetID == targetID }
            .sorted { $0.finishedAt > $1.finishedAt }
    }

    func record(
        clientID: String,
        clientDisplayIdentity: String? = nil,
        targetID: UUID,
        targetAlias: String,
        actionType: String,
        capabilities: Set<RemoteCapability>,
        result: RemoteCapabilityAuditResult,
        resultCode: String,
        controlLeaseExpiresAt: Date?,
        startedAt: Date,
        finishedAt: Date = Date()
    ) {
        let newRecord = RemoteCapabilityAuditRecord(
            id: UUID(),
            clientID: Self.sanitizedLabel(clientID, maximumLength: 160),
            clientDisplayIdentity: clientDisplayIdentity,
            targetID: targetID,
            targetAlias: Self.sanitizedLabel(targetAlias, maximumLength: 120),
            actionType: Self.sanitizedActionType(actionType),
            capabilityNames: capabilities.map(\.rawValue).sorted(),
            result: result,
            resultCode: Self.sanitizedResultCode(resultCode),
            controlLeaseExpiresAt: controlLeaseExpiresAt,
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        do {
            let snapshot = try withExclusiveLock { directoryDescriptor in
                var state = try readLatestLocked(
                    directoryDescriptor: directoryDescriptor
                )
                _ = normalize(&state.records, now: finishedAt)
                state.records.append(newRecord)
                _ = enforceRecordCap(&state.records)
                try persistLocked(
                    state.records,
                    directoryDescriptor: directoryDescriptor
                )
                return PersistedSnapshot(
                    records: state.records,
                    storageStamp: try storageStampLocked(
                        directoryDescriptor: directoryDescriptor
                    )
                )
            }
            applySnapshot(snapshot)
        } catch {
            // A failed writer cannot expose an unverified or non-durable
            // snapshot as current audit state.
            invalidateSnapshot(for: error)
        }
    }

    func clear(targetID: UUID? = nil, at date: Date = Date()) throws {
        do {
            let snapshot = try withExclusiveLock { directoryDescriptor in
                var state = try readLatestLocked(
                    directoryDescriptor: directoryDescriptor
                )
                _ = normalize(&state.records, now: date)
                if let targetID {
                    state.records.removeAll { $0.targetID == targetID }
                } else {
                    state.records.removeAll()
                }
                try persistLocked(
                    state.records,
                    directoryDescriptor: directoryDescriptor
                )
                return PersistedSnapshot(
                    records: state.records,
                    storageStamp: try storageStampLocked(
                        directoryDescriptor: directoryDescriptor
                    )
                )
            }
            applySnapshot(snapshot)
        } catch {
            invalidateSnapshot(for: error)
            throw error
        }
    }

    func exportData(targetID: UUID? = nil) throws -> Data {
        do {
            let snapshot = try loadLatestAndPrune(now: Date())
            applySnapshot(snapshot)
            let selected = targetID.map {
                id in snapshot.records.filter { $0.targetID == id }
            } ?? snapshot.records
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(
                selected
                    .sorted { $0.finishedAt < $1.finishedAt }
                    .map(RedactedExportRecord.init(record:))
            )
        } catch {
            invalidateSnapshot(for: error)
            throw error
        }
    }

    func export(to url: URL, targetID: UUID? = nil) throws {
        try exportData(targetID: targetID).write(to: url, options: [.atomic])
    }

    func reloadFromDiskIfChanged(now: Date = Date()) {
        let currentStamp = Self.storageStamp(for: storageURL)
        let retentionPruneIsDue = nextRetentionPruneAt.map {
            now > $0
        } ?? false
        guard requiresReload
                || retentionPruneIsDue
                || currentStamp != lastLoadedStorageStamp else {
            return
        }
        do {
            applySnapshot(try loadLatestAndPrune(now: now))
        } catch {
            // A failed lock/read/write cannot safely refresh this snapshot.
            // Clearing it prevents callers from treating stale audit data as
            // the current durable state.
            invalidateSnapshot(for: error)
        }
    }

    private struct LoadedState {
        var records: [RemoteCapabilityAuditRecord]
        var fileExists: Bool
        var storageStamp: String?
        var requiresMigration: Bool
    }

    private struct PersistedSnapshot {
        var records: [RemoteCapabilityAuditRecord]
        var storageStamp: String?
    }

    private struct AuditPersistenceFailure: LocalizedError {
        var message: String
        var underlyingError: Error?

        var errorDescription: String? {
            guard let underlyingError else { return message }
            return "\(message) \(underlyingError.localizedDescription)"
        }
    }

    private func applySnapshot(_ snapshot: PersistedSnapshot) {
        records = snapshot.records
        lastLoadedStorageStamp = snapshot.storageStamp
        requiresReload = false
        let retentionInterval = TimeInterval(retentionDays * 24 * 60 * 60)
        nextRetentionPruneAt = snapshot.records
            .map { $0.finishedAt.addingTimeInterval(retentionInterval) }
            .min()
        persistenceError = nil
    }

    private func invalidateSnapshot(for error: Error) {
        records = []
        requiresReload = true
        nextRetentionPruneAt = nil
        persistenceError = error.localizedDescription
    }

    private func loadLatestAndPrune(now: Date) throws -> PersistedSnapshot {
        try withExclusiveLock { directoryDescriptor in
            var state = try readLatestLocked(
                directoryDescriptor: directoryDescriptor
            )
            let didNormalize = normalize(&state.records, now: now)
            if state.fileExists, didNormalize || state.requiresMigration {
                try persistLocked(
                    state.records,
                    directoryDescriptor: directoryDescriptor
                )
                state.storageStamp = try storageStampLocked(
                    directoryDescriptor: directoryDescriptor
                )
            } else {
                let currentStamp = try storageStampLocked(
                    directoryDescriptor: directoryDescriptor
                )
                guard currentStamp == state.storageStamp else {
                    throw AuditPersistenceFailure(
                        message: "The persisted RDP audit file changed while it was being read.",
                        underlyingError: nil
                    )
                }
            }
            return PersistedSnapshot(
                records: state.records,
                storageStamp: state.storageStamp
            )
        }
    }

    private func readLatestLocked(
        directoryDescriptor: Int32
    ) throws -> LoadedState {
        let descriptor = storageURL.lastPathComponent.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0 {
            let openError = errno
            if openError == ENOENT {
                return LoadedState(
                    records: [],
                    fileExists: false,
                    storageStamp: nil,
                    requiresMigration: false
                )
            }
            throw Self.posixFailure(
                message: "The persisted RDP audit file could not be opened.",
                errorNumber: openError
            )
        }
        defer { _ = Darwin.close(descriptor) }

        try validatePrivateRegularFile(
            descriptor,
            context: "persisted RDP audit file"
        )
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw Self.posixFailure(
                message: "The persisted RDP audit file could not be inspected.",
                errorNumber: errno
            )
        }
        guard fileStatus.st_size >= 0,
              fileStatus.st_size <= off_t(Self.maximumPersistedStateBytes) else {
            throw AuditPersistenceFailure(
                message: "The persisted RDP audit file exceeds the safe size limit.",
                underlyingError: nil
            )
        }

        let data: Data
        do {
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false
            )
            data = try handle.read(
                upToCount: Self.maximumPersistedStateBytes + 1
            ) ?? Data()
        } catch {
            throw AuditPersistenceFailure(
                message: "The persisted RDP audit file could not be read.",
                underlyingError: error
            )
        }
        guard data.count <= Self.maximumPersistedStateBytes else {
            throw AuditPersistenceFailure(
                message: "The persisted RDP audit file exceeds the safe size limit.",
                underlyingError: nil
            )
        }

        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            guard (1...2).contains(state.formatVersion) else {
                throw AuditPersistenceFailure(
                    message: "The persisted RDP audit file uses an unsupported format.",
                    underlyingError: nil
                )
            }
            return LoadedState(
                records: state.records,
                fileExists: true,
                storageStamp: Self.storageStamp(fileStatus: fileStatus),
                requiresMigration: state.formatVersion < 2
            )
        } catch let failure as AuditPersistenceFailure {
            throw failure
        } catch {
            throw AuditPersistenceFailure(
                message: "The persisted RDP audit file could not be decoded.",
                underlyingError: error
            )
        }
    }

    @discardableResult
    private func normalize(
        _ records: inout [RemoteCapabilityAuditRecord],
        now: Date
    ) -> Bool {
        let cutoff = Self.cutoff(now: now, retentionDays: retentionDays)
        let latestAcceptedTime = now.addingTimeInterval(5 * 60)
        let previousCount = records.count
        records.removeAll {
            !$0.startedAt.timeIntervalSinceReferenceDate.isFinite
                || !$0.finishedAt.timeIntervalSinceReferenceDate.isFinite
                || $0.startedAt > $0.finishedAt
                || $0.startedAt > latestAcceptedTime
                || $0.finishedAt > latestAcceptedTime
                || $0.finishedAt < cutoff
        }
        let didPrune = records.count != previousCount
        return enforceRecordCap(&records) || didPrune
    }

    @discardableResult
    private func enforceRecordCap(
        _ records: inout [RemoteCapabilityAuditRecord]
    ) -> Bool {
        guard records.count > Self.maximumRecordCount else { return false }
        records.removeFirst(records.count - Self.maximumRecordCount)
        return true
    }

    private func withExclusiveLock<T>(
        _ operation: (Int32) throws -> T
    ) throws -> T {
        let directory = storageURL.deletingLastPathComponent()
        let directoryDescriptor = try openPrivateDirectory(directory)
        defer { _ = Darwin.close(directoryDescriptor) }

        let descriptor = lockURL.lastPathComponent.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw Self.posixFailure(
                message: "The RDP audit lock file could not be opened.",
                errorNumber: errno
            )
        }
        defer { _ = Darwin.close(descriptor) }

        do {
            try PrivateFileSecurity.securePrivateFileDescriptor(
                descriptor,
                path: lockURL.path
            )
        } catch {
            throw AuditPersistenceFailure(
                message: "The RDP audit lock file could not be secured.",
                underlyingError: error
            )
        }

        let deadline = ProcessInfo.processInfo.systemUptime
            + Self.exclusiveLockTimeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            if lockError == EINTR { continue }
            if (lockError == EWOULDBLOCK || lockError == EAGAIN),
               ProcessInfo.processInfo.systemUptime < deadline {
                usleep(Self.exclusiveLockRetryMicroseconds)
                continue
            }
            throw Self.posixFailure(
                message: lockError == EWOULDBLOCK || lockError == EAGAIN
                    ? "The RDP audit lock timed out."
                    : "The RDP audit lock could not be acquired.",
                errorNumber: lockError
            )
        }

        let operationResult: Result<T, Error> = Result {
            try operation(directoryDescriptor)
        }
        // Closing the descriptor below releases the lock even if an explicit
        // unlock reports an interruption. Do not turn an already committed
        // audit transaction into an apparent failure.
        _ = flock(descriptor, LOCK_UN)
        return try operationResult.get()
    }

    private func persistLocked(
        _ records: [RemoteCapabilityAuditRecord],
        directoryDescriptor: Int32
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(PersistedState(records: records))
            guard data.count <= Self.maximumPersistedStateBytes else {
                throw AuditPersistenceFailure(
                    message: "The RDP audit state exceeds the safe size limit.",
                    underlyingError: nil
                )
            }
            try persistDataAtomically(
                data,
                destinationName: storageURL.lastPathComponent,
                directoryDescriptor: directoryDescriptor
            )
        } catch let failure as AuditPersistenceFailure {
            throw failure
        } catch {
            throw AuditPersistenceFailure(
                message: "The RDP audit state could not be persisted.",
                underlyingError: error
            )
        }
    }

    private func openPrivateDirectory(_ directory: URL) throws -> Int32 {
        do {
            try PrivateFileSecurity.secureDirectory(at: directory)
        } catch {
            throw AuditPersistenceFailure(
                message: "The RDP audit storage directory could not be secured.",
                underlyingError: error
            )
        }

        let descriptor = directory.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw Self.posixFailure(
                message: "The RDP audit storage directory could not be opened.",
                errorNumber: errno
            )
        }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFDIR,
              fileStatus.st_uid == geteuid() else {
            _ = Darwin.close(descriptor)
            throw AuditPersistenceFailure(
                message: "The RDP audit storage directory ownership or type is unsafe.",
                underlyingError: nil
            )
        }
        do {
            try PrivateFileSecurity.verifyPrivateDirectoryDescriptor(
                descriptor,
                path: directory.path
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw AuditPersistenceFailure(
                message: "The RDP audit storage directory is not private.",
                underlyingError: error
            )
        }
        return descriptor
    }

    private func validatePrivateRegularFile(
        _ descriptor: Int32,
        context: String
    ) throws {
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw Self.posixFailure(
                message: "The \(context) could not be inspected.",
                errorNumber: errno
            )
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            throw AuditPersistenceFailure(
                message: "The \(context) path is not a regular file.",
                underlyingError: nil
            )
        }
        guard fileStatus.st_uid == geteuid(), fileStatus.st_nlink == 1 else {
            throw AuditPersistenceFailure(
                message: "The \(context) ownership or link count is unsafe.",
                underlyingError: nil
            )
        }
        do {
            try PrivateFileSecurity.verifyPrivateFileDescriptor(
                descriptor,
                path: context
            )
        } catch {
            throw AuditPersistenceFailure(
                message: "The \(context) permissions or ACL are unsafe.",
                underlyingError: error
            )
        }
    }

    private func storageStampLocked(
        directoryDescriptor: Int32
    ) throws -> String? {
        let descriptor = storageURL.lastPathComponent.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0 {
            let openError = errno
            if openError == ENOENT {
                return nil
            }
            throw Self.posixFailure(
                message: "The persisted RDP audit path could not be opened for inspection.",
                errorNumber: openError
            )
        }
        defer { _ = Darwin.close(descriptor) }
        try validatePrivateRegularFile(
            descriptor,
            context: "persisted RDP audit file"
        )

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw Self.posixFailure(
                message: "The persisted RDP audit path could not be inspected.",
                errorNumber: errno
            )
        }
        guard fileStatus.st_size >= 0,
              fileStatus.st_size <= off_t(Self.maximumPersistedStateBytes) else {
            throw AuditPersistenceFailure(
                message: "The persisted RDP audit file exceeds the safe size limit.",
                underlyingError: nil
            )
        }
        return Self.storageStamp(fileStatus: fileStatus)
    }

    private func persistDataAtomically(
        _ data: Data,
        destinationName: String,
        directoryDescriptor: Int32
    ) throws {
        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw Self.posixFailure(
                message: "The RDP audit temporary file could not be created.",
                errorNumber: errno
            )
        }

        var descriptorNeedsClose = true
        var temporaryNeedsRemoval = true
        defer {
            if descriptorNeedsClose {
                _ = Darwin.close(descriptor)
            }
            if temporaryNeedsRemoval {
                temporaryName.withCString {
                    _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }

        do {
            try PrivateFileSecurity.securePrivateFileDescriptor(
                descriptor,
                path: "RDP audit temporary file"
            )
        } catch {
            throw AuditPersistenceFailure(
                message: "The RDP audit temporary file could not be secured.",
                underlyingError: error
            )
        }
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw Self.posixFailure(
                message: "The RDP audit temporary file could not be synchronized.",
                errorNumber: errno
            )
        }

        let closeResult = Darwin.close(descriptor)
        descriptorNeedsClose = false
        guard closeResult == 0 else {
            throw Self.posixFailure(
                message: "The RDP audit temporary file could not be closed.",
                errorNumber: errno
            )
        }

        let renameResult = temporaryName.withCString { temporaryPath in
            destinationName.withCString { destinationPath in
                Darwin.renameat(
                    directoryDescriptor,
                    temporaryPath,
                    directoryDescriptor,
                    destinationPath
                )
            }
        }
        guard renameResult == 0 else {
            throw Self.posixFailure(
                message: "The RDP audit state could not be committed.",
                errorNumber: errno
            )
        }
        temporaryNeedsRemoval = false

        // The rename is the authoritative namespace commit. Synchronize the
        // directory without letting a post-commit fsync error misreport the
        // durable transaction as rolled back.
        _ = Darwin.fsync(directoryDescriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            throw Self.posixFailure(
                message: "The RDP audit temporary file could not be written.",
                errorNumber: written < 0 ? errno : EIO
            )
        }
    }

    private static func posixFailure(
        message: String,
        errorNumber: Int32
    ) -> AuditPersistenceFailure {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorNumber),
            userInfo: nil
        )
        return AuditPersistenceFailure(
            message: message,
            underlyingError: underlying
        )
    }

    private static func storageStamp(for url: URL) -> String? {
        var fileStatus = stat()
        guard url.path.withCString({
            Darwin.lstat($0, &fileStatus)
        }) == 0 else {
            return nil
        }
        return storageStamp(fileStatus: fileStatus)
    }

    private static func storageStamp(fileStatus: stat) -> String {
        [
            "\(fileStatus.st_dev)",
            "\(fileStatus.st_ino)",
            "\(fileStatus.st_mode & S_IFMT)",
            "\(fileStatus.st_uid)",
            "\(fileStatus.st_nlink)",
            "\(fileStatus.st_size)",
            "\(fileStatus.st_mtimespec.tv_sec)",
            "\(fileStatus.st_mtimespec.tv_nsec)",
            "\(fileStatus.st_ctimespec.tv_sec)",
            "\(fileStatus.st_ctimespec.tv_nsec)",
        ].joined(separator: "-")
    }

    private static func cutoff(now: Date, retentionDays: Int) -> Date {
        now.addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
    }

    nonisolated fileprivate static func sanitizedActionType(_ value: String) -> String {
        var allowlist = Set(WindowsMCPToolName.activeCases.map(\.rawValue) + [
            "pairing.delegate.bootstrap",
            "pairing.delegate.confirm",
            "pairing.delegate.revoke",
            "pairing.delegate.restore",
            "jts_device_status",
            "jts_device_exec",
            "jts_device_task",
            "jts_device_files",
            "jts_companion_pairing.status",
            "jts_companion_pairing.confirm",
            "jts_companion_pairing.revoke",
            "grant.approve",
            "grant.revoke",
            "grant.deny",
            "control.invalidate",
            "legacy.discovery",
            "legacy.command",
            "legacy.file",
            "legacy.destructive",
            "legacy.terminal",
        ])
        if AppReleasePolicy.includesNativeRDP {
            allowlist.formUnion(DesktopActionKind.allCases.map {
                "\(WindowsMCPToolName.desktopAction.rawValue).\($0.rawValue)"
            })
            allowlist.formUnion(RemoteFileOperation.allCases.map {
                "\(WindowsMCPToolName.windowsFiles.rawValue).\($0.rawValue)"
            })
            allowlist.formUnion(RemoteTaskAction.allCases.map {
                "\(WindowsMCPToolName.windowsTask.rawValue).\($0.rawValue)"
            })
        }
        return allowlist.contains(value) ? value : "unknown"
    }

    nonisolated fileprivate static func sanitizedResultCode(_ value: String) -> String {
        let normalized = value.uppercased()
        let allowlist: Set<String> = [
            "OK",
            "INVALID_ARGUMENT",
            "TARGET_NOT_FOUND",
            "DESKTOP_RUNTIME_UNAVAILABLE",
            "COMPANION_REQUIRED",
            "STATE_CONFLICT",
            "IDEMPOTENCY_CONFLICT",
            "DEADLINE_EXCEEDED",
            "SENSITIVE_INTERACTION_ACTIVE",
            "PERMISSION_DENIED",
            "RUNTIME_FAILURE",
            "GRANT_REVOKED",
            "GRANT_EXPIRED",
            "CONTROL_LEASE_EXPIRED",
            "CAPABILITY_NOT_GRANTED",
            "CAPABILITY_NOT_ALLOWED",
            "EXTERNAL_DATA_CONSENT_REQUIRED",
            "GRANT_APPROVAL_REQUIRED",
            "EMPTY_CAPABILITY_REQUEST",
            "CLIENT_IDENTITY_REQUIRED",
            "CLIENT_REGISTRATION_REQUIRED",
            "GRANT_REQUEST_NOT_FOUND",
            "APPROVED",
            "APPROVED_WITH_EXTERNAL_DATA_CONSENT",
            "USER_DENIED",
            "USER_REVOKED",
        ]
        return allowlist.contains(normalized) ? normalized : "UNKNOWN"
    }

    nonisolated fileprivate static func sanitizedLabel(
        _ value: String,
        maximumLength: Int
    ) -> String {
        let sanitized = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(maximumLength)
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    private nonisolated static func redactedClientReference(_ clientID: String) -> String {
        let digest = SHA256.hash(data: Data(clientID.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    private static func defaultStorageURL() -> URL {
        #if JTS_UI_TEST_SUPPORT
        if let isolatedURL = UITestRDPFixtureEnvironment.isolatedAuditStorageURL() {
            return isolatedURL
        }
        #endif

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("JTS Terminal", isDirectory: true)
            .appendingPathComponent("Security", isDirectory: true)
            .appendingPathComponent("rdp-capability-audit-v1.json")
    }

}

#endif
