import Foundation
import JTSCompanionTransport
import Network

protocol NativeSharingByteStream: Sendable {
    func read(maximumBytes: Int) async throws -> Data
    func write(_ bytes: Data) async throws
    func close() async
}

enum NativeSharingError: LocalizedError {
    case unavailable, closed, unsupportedLane
    var errorDescription: String? {
        switch self {
        case .unavailable: return "此 Mac 的系统屏幕共享尚未开启。请前往系统设置 → 通用 → 共享，开启屏幕共享并允许你的账户。"
        case .closed: return "系统屏幕共享连接已关闭。"
        case .unsupportedLane: return "此连接不允许访问系统屏幕共享。"
        }
    }
}

/// This is a fixed-purpose bridge, never a configurable TCP proxy. The caller
/// must complete pinned mutual TLS and rdp.open grant authorization first.
actor NativeScreenSharingBridge {
    private let channel: any CompanionSecureChannel
    private let makeStream: @Sendable () async throws -> any NativeSharingByteStream
    private var stream: (any NativeSharingByteStream)?
    private var closed = false

    init(channel: any CompanionSecureChannel,
         makeStream: @escaping @Sendable () async throws -> any NativeSharingByteStream = {
             try await NativeSharingLoopbackStream.connect()
         }) throws {
        guard channel.binding.lane == .rdp else { throw NativeSharingError.unsupportedLane }
        self.channel = channel
        self.makeStream = makeStream
    }

    func run() async throws {
        guard !closed else { throw NativeSharingError.closed }
        try await withTaskCancellationHandler {
            do {
                let stream = try await makeStream()
                self.stream = stream
                guard !closed else { await stream.close(); throw NativeSharingError.closed }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while !Task.isCancelled {
                            let bytes = try await stream.read(maximumBytes: 16 * 1024)
                            if bytes.isEmpty { break }
                            try await self.channel.send(bytes)
                        }
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            let bytes = try await self.channel.receive(maximumBytes: 16 * 1024)
                            if bytes.isEmpty { break }
                            try await stream.write(bytes)
                        }
                    }
                    defer { group.cancelAll() }
                    do {
                        _ = try await group.next()
                        await close()
                    } catch {
                        await close()
                        throw error
                    }
                }
            } catch { await close(); throw error }
        } onCancel: { Task { await self.close() } }
    }

    func close() async {
        closed = true
        await channel.close()
        await stream?.close()
    }
}

/// The service endpoint is deliberately constant. No remote input can choose a
/// hostname, port or listener. macOS performs the user's Screen Sharing login.
actor NativeSharingLoopbackStream: NativeSharingByteStream {
    static let host = "127.0.0.1"
    static let port: UInt16 = 5900
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.jtstools.mac-companion.native-loopback")
    private var closed = false
    private var connectWaiter: CheckedContinuation<Void, Error>?

    private init() {
        connection = NWConnection(host: NWEndpoint.Host(Self.host), port: NWEndpoint.Port(rawValue: Self.port)!, using: .tcp)
    }

    static func connect() async throws -> NativeSharingLoopbackStream {
        let stream = NativeSharingLoopbackStream()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await stream.establish() }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    await stream.close()
                    throw NativeSharingError.unavailable
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            return stream
        } catch { await stream.close(); throw error }
    }

    private func establish() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                guard !closed else { waiter.resume(throwing: NativeSharingError.closed); return }
                connectWaiter = waiter
                connection.stateUpdateHandler = { [weak self] state in
                    Task { await self?.changed(state) }
                }
                connection.start(queue: queue)
            }
        } onCancel: { Task { await self.close() } }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready: connectWaiter?.resume(); connectWaiter = nil
        case .failed, .cancelled:
            connectWaiter?.resume(throwing: NativeSharingError.unavailable); connectWaiter = nil
        default: break
        }
    }

    func read(maximumBytes: Int) async throws -> Data {
        guard !closed, maximumBytes > 0, maximumBytes <= 64 * 1024 else { throw NativeSharingError.closed }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) { bytes, _, done, error in
                    if let error { waiter.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { waiter.resume(returning: bytes) }
                    else if done { waiter.resume(returning: Data()) }
                    else { waiter.resume(throwing: NativeSharingError.closed) }
                }
            }
        } onCancel: { Task { await self.close() } }
    }

    func write(_ bytes: Data) async throws {
        guard !closed, !bytes.isEmpty, bytes.count <= 64 * 1024 else { throw NativeSharingError.closed }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { waiter.resume(throwing: error) }
                    else { waiter.resume() }
                })
            }
        } onCancel: { Task { await self.close() } }
    }

    func close() {
        closed = true
        connection.cancel()
        connectWaiter?.resume(throwing: NativeSharingError.closed)
        connectWaiter = nil
    }
}
