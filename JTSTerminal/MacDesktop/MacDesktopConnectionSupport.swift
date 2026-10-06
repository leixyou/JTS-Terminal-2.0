#if ENABLE_RDP_2
import Foundation
import Network
import RemoteDesktopCore

nonisolated struct MacDesktopStoredPairing: Codable, Equatable {
    var serverID: UUID
    var psk: Data
    var clientID: UUID
    var clientName: String
    var token: String
    var autoReconnect: Bool = true

    private enum CodingKeys: String, CodingKey {
        case serverID, psk, clientID, clientName, token, autoReconnect
    }

    init(serverID: UUID, psk: Data, clientID: UUID, clientName: String, token: String, autoReconnect: Bool = true) {
        self.serverID = serverID
        self.psk = psk
        self.clientID = clientID
        self.clientName = clientName
        self.token = token
        self.autoReconnect = autoReconnect
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try values.decode(UUID.self, forKey: .serverID)
        psk = try values.decode(Data.self, forKey: .psk)
        clientID = try values.decode(UUID.self, forKey: .clientID)
        clientName = try values.decode(String.self, forKey: .clientName)
        token = try values.decode(String.self, forKey: .token)
        autoReconnect = try values.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
    }
}

nonisolated enum MacDesktopPairingStore {
    static func account(host: String, port: Int) -> String {
        "mac-desktop:\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
    }

    static func read(host: String, port: Int) throws -> MacDesktopStoredPairing? {
        guard let secret = try CredentialStore.read(account: account(host: host, port: port)),
              let data = secret.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(MacDesktopStoredPairing.self, from: data)
    }

    static func save(_ pairing: MacDesktopStoredPairing, host: String, port: Int) throws {
        let data = try JSONEncoder().encode(pairing)
        try CredentialStore.save(secret: String(decoding: data, as: UTF8.self), account: account(host: host, port: port))
    }

    static func delete(host: String, port: Int) throws {
        try CredentialStore.delete(account: account(host: host, port: port))
    }
}

@MainActor
protocol MacDesktopTransport: AnyObject {
    var onStateChange: ((NWConnection.State) -> Void)? { get set }
    var onMessage: ((RemoteDesktopMessage) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
    func send(_ message: RemoteDesktopMessage, completion: ((Error?) -> Void)?)
}

extension DesktopChannel: MacDesktopTransport {}

@MainActor
struct MacDesktopClientDependencies {
    var readPairing: (String, Int) throws -> MacDesktopStoredPairing? = { try MacDesktopPairingStore.read(host: $0, port: $1) }
    var savePairing: (MacDesktopStoredPairing, String, Int) throws -> Void = { try MacDesktopPairingStore.save($0, host: $1, port: $2) }
    var deletePairing: (String, Int) throws -> Void = { try MacDesktopPairingStore.delete(host: $0, port: $1) }
    var makeTransport: (String, UInt16, Data, String) throws -> any MacDesktopTransport = {
        try DesktopChannel(host: $0, port: $1, psk: $2, identity: $3)
    }
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var now: () -> Date = Date.init
}

/// A successful session resets the backoff. Busy/capture failures get a finite grace period;
/// network outages keep retrying until the user cancels, with a 30 second maximum delay.
nonisolated struct MacDesktopReconnectPolicy {
    enum Cause: Equatable { case network, temporarilyUnavailable }
    private(set) var attempt = 0
    private var unavailableSince: Date?

    mutating func reset() { attempt = 0; unavailableSince = nil }

    mutating func nextDelay(cause: Cause, now: Date) -> TimeInterval? {
        if cause == .network { unavailableSince = nil }
        else if unavailableSince == nil { unavailableSince = now }
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        let delay = delays[min(attempt, delays.count - 1)]
        if let unavailableSince, now.timeIntervalSince(unavailableSince) + delay > 120 { return nil }
        attempt += 1
        return delay
    }

    static func cause(for error: Error) -> Cause? {
        if let protocolError = error as? DesktopProtocolError {
            switch protocolError {
            case .connectionTimeout, .truncatedPacket: return .network
            case .outboundQueueFull: return .temporarilyUnavailable
            default: return nil
            }
        }
        if let networkError = error as? NWError {
            switch networkError {
            case .tls: return nil // Do not retry a rejected per-device key.
            case .wifiAware: return nil
            case .posix, .dns: return .network
            @unknown default: return nil
            }
        }
        return nil
    }
}

#endif
