#if ENABLE_RDP_2
import Foundation
import JTSCompanionIPC
import Security

nonisolated protocol RelayStationProbing: Sendable {
    func check(origin: String) async throws -> RelayStationProbeResult
}

nonisolated struct RelayStationProbeResult: Equatable, Sendable {
    let checkedAt: Date
    let latencyMilliseconds: Int
}

/// Only these bounded categories may reach settings; server text and URL errors do not.
nonisolated enum RelayStationProbeError: String, Error, Equatable, Sendable {
    case invalidOrigin, redirectRejected, responseTooLarge, invalidResponse
    case unsupportedVersion, serviceUnavailable, timedOut, connectionFailed
}

nonisolated struct RelayStationProbeResponse: Sendable {
    let url: URL
    let status: Int
    let body: Data
}

nonisolated protocol RelayStationProbeTransport: Sendable {
    func perform(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayStationProbeResponse
}

/// Checks the public relay protocol only. It does not pair, authenticate, or contact a device.
nonisolated struct RelayStationProbe: RelayStationProbing {
    static let maximumResponseBytes = 16 * 1024
    private let transport: any RelayStationProbeTransport

    init(transport: any RelayStationProbeTransport = RelayStationProbeURLTransport()) {
        self.transport = transport
    }

    func check(origin: String) async throws -> RelayStationProbeResult {
        try Task.checkCancellation()
        let url = try Self.infoURL(origin: origin)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await transport.perform(request, maximumResponseBytes: Self.maximumResponseBytes)
            try Task.checkCancellation()
            guard response.url == url, !(300...399).contains(response.status) else {
                throw RelayStationProbeError.redirectRejected
            }
            guard response.body.count <= Self.maximumResponseBytes else { throw RelayStationProbeError.responseTooLarge }
            guard response.status == 200 else { throw RelayStationProbeError.serviceUnavailable }
            let info: Info
            do {
                try StrictCompanionJSON.validate(response.body, requiredKeys: ["protocolVersion", "lanes"],
                                                 maximumBytes: Self.maximumResponseBytes)
                info = try JSONDecoder().decode(Info.self, from: response.body)
            } catch { throw RelayStationProbeError.invalidResponse }
            guard info.protocolVersion == 1 else { throw RelayStationProbeError.unsupportedVersion }
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
            return RelayStationProbeResult(checkedAt: Date(), latencyMilliseconds: Int(elapsed * 1000))
        } catch is CancellationError { throw CancellationError() }
        catch let error as RelayStationProbeError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? RelayStationProbeError.timedOut : RelayStationProbeError.connectionFailed
        } catch { throw RelayStationProbeError.connectionFailed }
    }

    private static func infoURL(origin: String) throws -> URL {
        guard (1...2048).contains(origin.utf8.count),
              !origin.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\\" }),
              var parts = URLComponents(string: origin), parts.scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!) else { throw RelayStationProbeError.invalidOrigin }
        parts.path = "/v1/info"
        guard let url = parts.url else { throw RelayStationProbeError.invalidOrigin }
        return url
    }

    // Data-only /v1/info shape from the pinned relay protocol snapshot. No transport product is linked.
    nonisolated private struct Info: Decodable {
        let protocolVersion: Int
        let lanes: [Lane]
    }
    nonisolated private enum Lane: String, Decodable { case control, file, rdp }
}

nonisolated struct RelayStationProbeURLTransport: RelayStationProbeTransport {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }

    func perform(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayStationProbeResponse {
        let session = URLSession(configuration: Self.configuration(), delegate: RelayStationProbeSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw RelayStationProbeError.invalidResponse
        }
        guard url == request.url, !(300...399).contains(response.statusCode) else {
            throw RelayStationProbeError.redirectRejected
        }
        guard response.expectedContentLength <= maximumResponseBytes else { throw RelayStationProbeError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw RelayStationProbeError.responseTooLarge }
            data.append(byte)
        }
        return RelayStationProbeResponse(url: url, status: response.statusCode, body: data)
    }
}

/// Matches relay carrier certificate policy; a successful probe makes no endpoint identity claim.
nonisolated final class RelayStationProbeSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    private func answer(_ challenge: URLAuthenticationChallenge,
                        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completion(.cancelAuthenticationChallenge, nil)
            return
        }
        completion(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
