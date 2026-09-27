#if ENABLE_RDP_2
import Foundation
import JTSCompanionDevices

/// Uses the credential vault adapter's encrypted, atomic compare-and-swap document.
/// IDs are written before submission so an ambiguous delivery is recoverable without replay.
actor CompanionJobJournal {
    private struct Document: Codable { let version: Int; var jobs: [CompanionJobMetadata] }
    private let persistence: any CompanionDevicePersistence
    private var observed = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(persistence: any CompanionDevicePersistence) { self.persistence = persistence }

    func load() async throws -> [CompanionJobMetadata] {
        await acquire(); defer { release() }
        return try await read().document.jobs
    }
    func append(_ metadata: CompanionJobMetadata) async throws {
        try metadata.validate()
        await acquire(); defer { release() }
        var current = try await read()
        guard current.document.jobs.count < 256 else { throw CompanionJobError.journalFull }
        guard !current.document.jobs.contains(where: { $0.id == metadata.id }) else { throw CompanionJobError.invalidRequest }
        current.document.jobs.append(metadata)
        let encoded = try JSONEncoder().encode(current.document)
        guard let text = String(data: encoded, encoding: .utf8) else { throw CompanionJobError.journalUnavailable }
        if let previous = current.raw { try await persistence.replace(expected: previous, with: text) }
        else { try await persistence.create(text) }
        observed = true
    }
    func remove(_ id: UUID) async throws {
        await acquire(); defer { release() }
        var current = try await read()
        guard let raw = current.raw else { throw CompanionJobError.journalUnavailable }
        current.document.jobs.removeAll { $0.id == id }
        let encoded = try JSONEncoder().encode(current.document)
        guard let text = String(data: encoded, encoding: .utf8) else { throw CompanionJobError.journalUnavailable }
        try await persistence.replace(expected: raw, with: text)
    }
    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
    private func read() async throws -> (raw: String?, document: Document) {
        guard let raw = try await persistence.load() else {
            guard !observed else { throw CompanionJobError.journalUnavailable }
            return (nil, Document(version: 1, jobs: []))
        }
        guard raw.utf8.count <= 256 * 1024 else { throw CompanionJobError.journalUnavailable }
        let document = try JSONDecoder().decode(Document.self, from: Data(raw.utf8))
        guard document.version == 1, document.jobs.count <= 256,
              Set(document.jobs.map(\.id)).count == document.jobs.count else { throw CompanionJobError.journalUnavailable }
        for metadata in document.jobs { try metadata.validate() }
        observed = true
        return (raw, document)
    }
}
#endif
