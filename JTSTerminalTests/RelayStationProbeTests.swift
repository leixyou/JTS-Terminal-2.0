#if ENABLE_RDP_2
import Foundation
import Security
import Testing
@testable import JTSTerminal

@MainActor
struct RelayStationProbeTests {
    private let origin = "https://relay.example:8443"
    private let validInfo = #"{"protocolVersion":1,"lanes":["control","file","rdp"]}"#

    @Test func publicProbeSendsOnlyAnonymousInfoRequest() async throws {
        let transport = ProbeTransport(body: Data(validInfo.utf8))
        let before = Date()
        let result = try await RelayStationProbe(transport: transport).check(origin: origin + "/")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == origin + "/v1/info")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.allHTTPHeaderFields == ["Accept": "application/json"])
        #expect(!request.httpShouldHandleCookies)
        #expect(request.timeoutInterval == 10)
        #expect(await transport.limits == [16 * 1024])
        #expect(result.checkedAt >= before && result.checkedAt <= Date())
        #expect(result.latencyMilliseconds >= 0)
    }

    @Test(arguments: [
        "http://relay.example", "https://user:secret@relay.example", "https://relay.example/path",
        "https://relay.example?token=secret", "https://relay.example#fragment", "https://relay.example:0",
        "https://relay.example:65536", "https://relay.example\\other", "https://relay.example\n"
    ])
    func invalidOriginsNeverReachTransport(_ origin: String) async {
        let transport = ProbeTransport(body: Data(validInfo.utf8))
        await #expect(throws: RelayStationProbeError.invalidOrigin) {
            try await RelayStationProbe(transport: transport).check(origin: origin)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: [
        "<html>Proxy sign-in required</html>",
        #"{"protocolVersion":1}"#,
        #"{"protocolVersion":true,"lanes":["control"]}"#,
        #"{"protocolVersion":1,"lanes":["shell"]}"#,
        #"{"protocolVersion":1,"lanes":"control"}"#,
        #"{"protocolVersion":1,"protocolVersion":2,"lanes":["control"]}"#
    ])
    func unrelatedOrAmbiguousResponsesAreRejected(_ body: String) async {
        let transport = ProbeTransport(body: Data(body.utf8))
        await #expect(throws: RelayStationProbeError.invalidResponse) {
            try await RelayStationProbe(transport: transport).check(origin: origin)
        }
    }

    @Test func unsupportedProtocolHasItsOwnCategory() async {
        let transport = ProbeTransport(body: Data(#"{"protocolVersion":2,"lanes":["control","file","rdp"]}"#.utf8))
        await #expect(throws: RelayStationProbeError.unsupportedVersion) {
            try await RelayStationProbe(transport: transport).check(origin: origin)
        }
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func redirectStatusesAreRejected(_ status: Int) async {
        let transport = ProbeTransport(status: status, body: Data(validInfo.utf8))
        await #expect(throws: RelayStationProbeError.redirectRejected) {
            try await RelayStationProbe(transport: transport).check(origin: origin)
        }
    }

    @Test func successfulResponseFromAnotherURLIsStillRejected() async {
        let transport = ProbeTransport(body: Data(validInfo.utf8), responseURL: URL(string: "https://elsewhere.example/v1/info"))
        await #expect(throws: RelayStationProbeError.redirectRejected) {
            try await RelayStationProbe(transport: transport).check(origin: origin)
        }
    }

    @Test func boundedResponsesAcceptTheLimitAndRejectExcessBytes() async throws {
        let padded = validInfo + String(repeating: " ", count: 16 * 1024 - validInfo.utf8.count)
        let atLimit = ProbeTransport(body: Data(padded.utf8))
        _ = try await RelayStationProbe(transport: atLimit).check(origin: origin)
        let overLimit = ProbeTransport(body: Data((padded + " ").utf8))
        await #expect(throws: RelayStationProbeError.responseTooLarge) {
            try await RelayStationProbe(transport: overLimit).check(origin: origin)
        }
    }

    @Test func serverErrorsAreNotShownAsProtocolSuccess() async {
        let transport = ProbeTransport(status: 503, body: Data(validInfo.utf8))
        await #expect(throws: RelayStationProbeError.serviceUnavailable) {
            try await RelayStationProbe(transport: transport).check(origin: origin)
        }
    }

    @Test func underlyingNetworkMessagesNeverBecomeUserErrors() async {
        for (code, expected) in [(URLError.timedOut, RelayStationProbeError.timedOut),
                                 (.cannotConnectToHost, .connectionFailed)] {
            let transport = FailingProbeTransport(error: URLError(code, userInfo: [NSLocalizedDescriptionKey: "private network detail"]))
            await #expect(throws: expected) {
                try await RelayStationProbe(transport: transport).check(origin: origin)
            }
        }
        let cancelled = FailingProbeTransport(error: URLError(.cancelled))
        await #expect(throws: CancellationError.self) {
            try await RelayStationProbe(transport: cancelled).check(origin: origin)
        }
    }

    @Test func cancelledProbeDoesNotStartANetworkRequest() async {
        let transport = ProbeTransport(body: Data(validInfo.utf8))
        let probe = RelayStationProbe(transport: transport)
        let task = Task { try await probe.check(origin: origin) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.isEmpty)
    }

    @Test func isolatedSessionCannotReuseCookiesCredentialsOrCache() {
        let configuration = RelayStationProbeURLTransport.configuration()
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 10)
    }

    @Test func delegateRefusesRedirectsAndLoginChallenges() throws {
        let delegate = RelayStationProbeSessionDelegate()
        let url = try #require(URL(string: origin + "/v1/info"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://elsewhere.example")!)) {
            #expect($0 == nil)
        }
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodClientCertificate,
                       NSURLAuthenticationMethodServerTrust] {
            let space = URLProtectionSpace(host: "relay.example", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: ProbeChallengeSender())
            delegate.urlSession(session, didReceive: challenge) { disposition, credential in
                #expect(disposition == .cancelAuthenticationChallenge)
                #expect(credential == nil)
            }
        }
    }

    @Test func outerCertificateUsesExistingRelayCarrierPolicy() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/JTSCompanionTransport/Tests/JTSCompanionTransportTests/Fixtures/relay-self-signed.der")
        let certificate = try #require(SecCertificateCreateWithData(nil, Data(contentsOf: fixture) as CFData))
        var optionalTrust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "relay.example" as CFString), &optionalTrust) == errSecSuccess)
        let trust = try #require(optionalTrust)
        SecTrustSetNetworkFetchAllowed(trust, false)
        #expect(!SecTrustEvaluateWithError(trust, nil))
        let challenge = URLAuthenticationChallenge(protectionSpace: ProbeTrustSpace(trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: ProbeChallengeSender())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        RelayStationProbeSessionDelegate().urlSession(session, didReceive: challenge) { disposition, credential in
            #expect(disposition == .useCredential)
            #expect(credential != nil)
        }
    }
}

private actor ProbeTransport: RelayStationProbeTransport {
    let status: Int
    let body: Data
    let responseURL: URL?
    var requests: [URLRequest] = []
    var limits: [Int] = []

    init(status: Int = 200, body: Data, responseURL: URL? = nil) {
        self.status = status; self.body = body; self.responseURL = responseURL
    }

    func perform(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayStationProbeResponse {
        requests.append(request); limits.append(maximumResponseBytes)
        return RelayStationProbeResponse(url: responseURL ?? request.url!, status: status, body: body)
    }
}

nonisolated private struct FailingProbeTransport: RelayStationProbeTransport {
    let error: URLError
    func perform(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayStationProbeResponse { throw error }
}

nonisolated private final class ProbeTrustSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust
    override var serverTrust: SecTrust? { trust }
    init(_ trust: SecTrust) {
        self.trust = trust
        super.init(host: "relay.example", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
}

nonisolated private final class ProbeChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
#endif
