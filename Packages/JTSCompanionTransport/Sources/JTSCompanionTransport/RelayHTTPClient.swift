import Foundation

private struct ChallengeRequest: Encodable { let deviceId: String; let operation: RelayOperation }
private struct RelayFailure: Decodable { let code: String }

public struct RelayHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol RelayHTTPTransport: Sendable {
    func perform(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayHTTPResponse
}

public final class URLSessionRelayHTTPTransport: RelayHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: RelaySessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func perform(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url == request.url else { throw CompanionTransportError.invalidResponse }
        guard response.expectedContentLength <= maximumResponseBytes else {
            throw CompanionTransportError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw CompanionTransportError.responseTooLarge }
            data.append(byte)
        }
        return RelayHTTPResponse(status: response.statusCode, body: data)
    }
}

public actor RelayHTTPClient {
    public let endpoint: RelayEndpoint
    public let deviceID: String
    private let identity: RelayIdentity
    private let transport: any RelayHTTPTransport

    public init(endpoint: RelayEndpoint, identity: RelayIdentity,
                transport: any RelayHTTPTransport = URLSessionRelayHTTPTransport()) {
        self.endpoint = endpoint
        self.identity = identity
        deviceID = identity.deviceID
        self.transport = transport
    }

    public func info() async throws -> RelayInfo {
        let value: RelayInfo = try await request(path: "/v1/info", body: nil)
        guard value.protocolVersion == 1 else { throw CompanionTransportError.unsupportedVersion }
        return value
    }

    /// Presence is not node admission. Operators admit keys outside this client API.
    public func presence() async throws {
        struct Response: Decodable { let deviceId: String }
        let value: Response = try await authenticated(.presence, payload: Data("{}".utf8))
        guard value.deviceId == deviceID else { throw CompanionTransportError.invalidResponse }
    }

    public func devices() async throws -> [RelayDevice] {
        struct Response: Decodable { let devices: [RelayDevice] }
        let value: Response = try await authenticated(.devices, payload: Data("{}".utf8))
        guard value.devices.allSatisfy({ RelayIdentity.validateDeviceID($0.deviceId) }),
              Set(value.devices.map(\.deviceId)).count == value.devices.count else {
            throw CompanionTransportError.invalidResponse
        }
        return value.devices
    }

    public func createSession(peerDeviceID: String, lane: RelayLane) async throws -> RelaySessionTicket {
        guard RelayIdentity.validateDeviceID(peerDeviceID), peerDeviceID != deviceID else {
            throw CompanionTransportError.invalidIdentity
        }
        struct Payload: Encodable { let peerDeviceId: String; let lane: RelayLane }
        let ticket: RelaySessionTicket = try await authenticated(.sessions,
            payload: RelayJSON.encode(Payload(peerDeviceId: peerDeviceID, lane: lane)))
        try ticket.validate()
        try ticket.bindIssuer(endpoint)
        return ticket
    }

    public func poll() async throws -> [RelaySessionOffer] {
        struct Response: Decodable { let offers: [RelaySessionOffer] }
        let response: Response = try await authenticated(.poll, payload: Data("{}".utf8))
        var offers = response.offers
        for index in offers.indices {
            let offer = offers[index]
            guard RelayIdentity.validateDeviceID(offer.controllerDeviceId) else {
                throw CompanionTransportError.invalidResponse
            }
            try offer.sessionTicket.validate()
            try offers[index].bindIssuer(endpoint)
        }
        return offers
    }

    private func authenticated<T: Decodable>(_ operation: RelayOperation, payload: Data) async throws -> T {
        let challenge: RelayChallenge = try await request(path: "/v1/challenges",
            body: RelayJSON.encode(ChallengeRequest(deviceId: deviceID, operation: operation)))
        let proof = try identity.proof(operation: operation, challenge: challenge, payload: payload)
        return try await request(path: "/v1/\(operation.rawValue)", body: RelayJSON.encode(proof))
    }

    private func request<T: Decodable>(path: String, body: Data?) async throws -> T {
        var request = URLRequest(url: try endpoint.httpURL(path: path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response = try await transport.perform(request, maximumResponseBytes: RelayLimits.responseBytes)
        guard response.body.count <= RelayLimits.responseBytes else { throw CompanionTransportError.responseTooLarge }
        guard response.status == 200 else {
            let code = (try? JSONDecoder().decode(RelayFailure.self, from: response.body).code) ?? "request_failed"
            // Error strings are bounded and reduced to protocol-safe characters, never arbitrary server text.
            let safe = code.utf8.count <= 64 && code.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }
            throw CompanionTransportError.remote(safe ? code : "request_failed")
        }
        do {
            try StrictRelayJSON.validate(response.body)
            return try JSONDecoder().decode(T.self, from: response.body)
        }
        catch { throw CompanionTransportError.invalidResponse }
    }
}
