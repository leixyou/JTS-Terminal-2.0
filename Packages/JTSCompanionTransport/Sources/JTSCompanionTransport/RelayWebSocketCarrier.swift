import Foundation

/// An UNAUTHENTICATED carrier for inner TLS records, never application commands or files.
/// Closing must promptly wake pending reads/writes with an error, including on task cancellation.
public protocol RelayByteCarrier: Sendable {
    func read(maximumBytes: Int) async throws -> Data
    func write(_ bytes: Data) async throws
    func close() async
}

public enum RelayWebSocketMessage: Sendable { case text(String), binary(Data) }

public protocol RelayWebSocketConnection: Sendable {
    func receive() async throws -> RelayWebSocketMessage
    func sendBinary(_ bytes: Data) async throws
    func close() async
}

public struct RelayReady: Codable, Sendable {
    public let ready: Bool
    public let sessionId: String
    public let lane: RelayLane

    public static func validate(_ message: RelayWebSocketMessage, sessionID: String,
                                lane: RelayLane) throws {
        guard case let .text(text) = message, text.utf8.count <= RelayLimits.bindingBytes,
              (try? StrictRelayJSON.validate(Data(text.utf8), requiredKeys: ["ready", "sessionId", "lane"])) != nil,
              let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              value.ready, value.sessionId == sessionID, value.lane == lane else {
            throw CompanionTransportError.invalidReady
        }
    }
}

/// Strict readiness and bounded ordered-byte adaptation; this is not an authenticated channel.
public actor RelayWebSocketCarrier: RelayByteCarrier {
    private let connection: any RelayWebSocketConnection
    private var pending = Data()
    private var closed = false
    private var reading = false
    private var writing = false

    private init(connection: any RelayWebSocketConnection) { self.connection = connection }

    public static func acceptReady(connection: any RelayWebSocketConnection, sessionID: String,
                                   lane: RelayLane) async throws -> RelayWebSocketCarrier {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let message = try await connection.receive()
                try Task.checkCancellation()
                try RelayReady.validate(message, sessionID: sessionID, lane: lane)
                return RelayWebSocketCarrier(connection: connection)
            } catch {
                await connection.close()
                throw error
            }
        } onCancel: {
            // Until readiness returns, no coordinator owns this socket. URLSession's
            // async receive does not itself cancel the socket when its Swift task is cancelled.
            Task { await connection.close() }
        }
    }

    public static func connect(endpoint: RelayEndpoint, ticket: RelaySessionTicket,
                               lane: RelayLane) async throws -> RelayWebSocketCarrier {
        try Task.checkCancellation()
        try ticket.claim(endpoint: endpoint)
        var request = URLRequest(url: try endpoint.channelURL())
        request.setValue("Bearer \(ticket.ticket)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let socket = URLSessionRelayWebSocket(request: request)
        return try await acceptReady(connection: socket, sessionID: ticket.sessionId, lane: lane)
    }

    public func read(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw CompanionTransportError.connectionClosed }
        guard maximumBytes > 0, maximumBytes <= RelayLimits.webSocketMessageBytes else {
            throw CompanionTransportError.frameTooLarge
        }
        guard !reading else { throw CompanionTransportError.operationInProgress }
        reading = true
        defer { reading = false }
        do {
            if pending.isEmpty {
                guard case let .binary(bytes) = try await connection.receive() else {
                    throw CompanionTransportError.unexpectedText
                }
                guard !bytes.isEmpty, bytes.count <= RelayLimits.webSocketMessageBytes else {
                    throw CompanionTransportError.frameTooLarge
                }
                pending = bytes
            }
            guard !closed else { throw CompanionTransportError.connectionClosed }
            let count = min(maximumBytes, pending.count)
            let result = Data(pending.prefix(count))
            pending.removeFirst(count)
            return result
        } catch {
            await close()
            throw error
        }
    }

    public func write(_ bytes: Data) async throws {
        guard !closed else { throw CompanionTransportError.connectionClosed }
        guard !bytes.isEmpty, bytes.count <= RelayLimits.webSocketMessageBytes else {
            throw CompanionTransportError.frameTooLarge
        }
        guard !writing else { throw CompanionTransportError.operationInProgress }
        writing = true
        defer { writing = false }
        do { try await connection.sendBinary(bytes) }
        catch { await close(); throw error }
    }

    public func close() async {
        closed = true
        pending.removeAll(keepingCapacity: false)
        await connection.close()
    }
}

private final class URLSessionRelayWebSocket: RelayWebSocketConnection, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: config, delegate: RelaySessionDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = RelayLimits.webSocketMessageBytes
        task.resume()
    }

    deinit { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }

    func receive() async throws -> RelayWebSocketMessage {
        switch try await task.receive() {
        case let .string(value): return .text(value)
        case let .data(value): return .binary(value)
        @unknown default: throw CompanionTransportError.invalidResponse
        }
    }

    func sendBinary(_ bytes: Data) async throws { try await task.send(.data(bytes)) }
    func close() async { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}
