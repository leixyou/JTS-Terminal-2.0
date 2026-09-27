#if ENABLE_RDP_2
import AppKit
import Foundation

nonisolated enum RDPTextClipboardError: LocalizedError, Equatable, Sendable {
    case payloadTooLarge
    case invalidUTF8
    case embeddedNull

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            return "Clipboard text exceeds the 4 MiB synchronization limit."
        case .invalidUTF8:
            return "Clipboard text is not valid UTF-8."
        case .embeddedNull:
            return "Clipboard text contains an embedded null character."
        }
    }
}

nonisolated enum RDPTextClipboardCodec {
    static let maximumUTF8Bytes = 4 * 1024 * 1024

    static func encode(_ text: String?) throws -> Data? {
        guard let text else { return nil }
        guard !text.contains("\0") else {
            throw RDPTextClipboardError.embeddedNull
        }
        let payload = Data(text.utf8)
        guard payload.count <= maximumUTF8Bytes else {
            throw RDPTextClipboardError.payloadTooLarge
        }
        return payload
    }

    static func decode(_ payload: Data) throws -> String {
        guard payload.count <= maximumUTF8Bytes else {
            throw RDPTextClipboardError.payloadTooLarge
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            throw RDPTextClipboardError.invalidUTF8
        }
        guard !text.contains("\0") else {
            throw RDPTextClipboardError.embeddedNull
        }
        return text
    }
}

@MainActor
protocol RDPTextPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func readText() -> String?
    func replaceText(_ text: String)
}

@MainActor
final class SystemRDPTextPasteboard: RDPTextPasteboardAccess {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func readText() -> String? {
        pasteboard.string(forType: .string)
    }

    func replaceText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Synchronizes only human-operated plain text. Clipboard values never enter
/// the MCP capability model, audit store, logs, or persistent profile data.
@MainActor
final class RDPTextClipboardSynchronizer {
    typealias Sender = @MainActor @Sendable (Data?) async throws -> Void

    private struct InFlightPublication {
        let identifier: UInt64
        let payload: Data?
        let changeCount: Int
        let lifecycleGeneration: UInt64
        let task: Task<Void, Error>
    }

    private let pasteboard: RDPTextPasteboardAccess
    private let pollingInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var sender: Sender?
    private var lastObservedChangeCount: Int
    private var hasPublishedPayload = false
    private var lastPublishedPayload: Data?
    private var lifecycleGeneration: UInt64 = 0
    private var publicationGeneration: UInt64 = 0
    private var inFlightPublication: InFlightPublication?

    init(
        pasteboard: RDPTextPasteboardAccess,
        pollingInterval: Duration = .milliseconds(200)
    ) {
        self.pasteboard = pasteboard
        self.pollingInterval = pollingInterval
        lastObservedChangeCount = pasteboard.changeCount
    }

    convenience init(pollingInterval: Duration = .milliseconds(200)) {
        self.init(
            pasteboard: SystemRDPTextPasteboard(),
            pollingInterval: pollingInterval
        )
    }

    deinit {
        pollingTask?.cancel()
    }

    func start(sender: @escaping Sender) {
        stop()
        lifecycleGeneration = Self.nextGeneration(lifecycleGeneration)
        self.sender = sender
        lastObservedChangeCount = pasteboard.changeCount
        let interval = pollingInterval
        pollingTask = Task { [weak self] in
            try? await self?.publishCurrent(force: true)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard self != nil else { return }
                await self?.publishIfChanged()
            }
        }
    }

    func stop() {
        lifecycleGeneration = Self.nextGeneration(lifecycleGeneration)
        pollingTask?.cancel()
        pollingTask = nil
        inFlightPublication?.task.cancel()
        inFlightPublication = nil
        sender = nil
        hasPublishedPayload = false
        lastPublishedPayload = nil
    }

    func publishCurrent(force: Bool = false) async throws {
        let invocationGeneration = lifecycleGeneration
        while true {
            try Task.checkCancellation()
            guard lifecycleGeneration == invocationGeneration else {
                throw CancellationError()
            }
            let changeCount = pasteboard.changeCount
            let generation = lifecycleGeneration
            let payload: Data?
            do {
                payload = try currentPayload()
            } catch {
                // Oversized or malformed local content is left local and is not
                // converted into a remote clipboard-clear operation.
                lastObservedChangeCount = changeCount
                // A manual Command-V must fail visibly instead of pasting an older
                // Windows clipboard value after the current Mac value was rejected.
                if force {
                    throw error
                }
                return
            }

            if let publication = inFlightPublication {
                do {
                    try await publication.task.value
                } catch {
                    if inFlightPublication?.identifier == publication.identifier {
                        inFlightPublication = nil
                    }
                    throw error
                }
                complete(publication)
                try Task.checkCancellation()
                guard lifecycleGeneration == invocationGeneration else {
                    throw CancellationError()
                }

                // A polling send and a manual Command-V commonly observe the
                // same pasteboard generation. Reuse the one Windows ACK instead
                // of announcing the same local owner twice; a late duplicate
                // format list could otherwise reclaim the Windows clipboard
                // after the pasted application has already changed it.
                if lifecycleGeneration == generation,
                   pasteboard.changeCount == changeCount,
                   publication.lifecycleGeneration == generation,
                   publication.changeCount == changeCount,
                   publication.payload == payload {
                    return
                }
                continue
            }

            guard force || !hasPublishedPayload || payload != lastPublishedPayload,
                  let sender else {
                lastObservedChangeCount = changeCount
                return
            }

            publicationGeneration = Self.nextGeneration(publicationGeneration)
            let identifier = publicationGeneration
            let task = Task { @MainActor in
                try await sender(payload)
            }
            let publication = InFlightPublication(
                identifier: identifier,
                payload: payload,
                changeCount: changeCount,
                lifecycleGeneration: generation,
                task: task
            )
            inFlightPublication = publication

            do {
                try await task.value
            } catch {
                if inFlightPublication?.identifier == identifier {
                    inFlightPublication = nil
                }
                throw error
            }
            complete(publication)
            try Task.checkCancellation()
            guard lifecycleGeneration == invocationGeneration else {
                throw CancellationError()
            }
            return
        }
    }

    func currentPayload() throws -> Data? {
        try RDPTextClipboardCodec.encode(pasteboard.readText())
    }

    func receiveRemote(_ payload: Data) throws {
        let text = try RDPTextClipboardCodec.decode(payload)
        lifecycleGeneration = Self.nextGeneration(lifecycleGeneration)
        if pasteboard.readText() != text {
            pasteboard.replaceText(text)
        }
        lastObservedChangeCount = pasteboard.changeCount
        hasPublishedPayload = true
        lastPublishedPayload = payload
    }

    private func publishIfChanged() async {
        guard pasteboard.changeCount != lastObservedChangeCount else { return }
        try? await publishCurrent()
    }

    private func complete(_ publication: InFlightPublication) {
        guard inFlightPublication?.identifier == publication.identifier else {
            return
        }
        inFlightPublication = nil
        guard lifecycleGeneration == publication.lifecycleGeneration,
              pasteboard.changeCount == publication.changeCount else {
            return
        }
        lastObservedChangeCount = publication.changeCount
        hasPublishedPayload = true
        lastPublishedPayload = publication.payload
    }

    private static func nextGeneration(_ current: UInt64) -> UInt64 {
        current == .max ? 1 : current + 1
    }
}
#endif
