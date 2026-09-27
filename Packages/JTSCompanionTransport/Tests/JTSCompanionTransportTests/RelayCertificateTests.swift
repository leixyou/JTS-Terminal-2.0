import Foundation
import Security
import XCTest
@testable import JTSCompanionTransport

final class RelayCertificateTests: XCTestCase {
    func testUntrustedOuterCertificateIsAcceptedWithoutChangingInnerPinning() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "relay-self-signed", withExtension: "der", subdirectory: "Fixtures"))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: url) as CFData))
        var optionalTrust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "relay.example" as CFString), &optionalTrust), errSecSuccess)
        let trust = try XCTUnwrap(optionalTrust)
        SecTrustSetNetworkFetchAllowed(trust, false)
        XCTAssertFalse(SecTrustEvaluateWithError(trust, nil))
        let challenge = URLAuthenticationChallenge(protectionSpace: TrustSpace(trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
        let delegate = RelaySessionDelegate()
        delegate.urlSession(.shared, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .useCredential)
            XCTAssertNotNil(credential)
        }
        delegate.urlSession(.shared, task: URLSession.shared.dataTask(with: URL(string: "https://relay.example")!),
                            didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .useCredential)
            XCTAssertNotNil(credential)
        }
    }

    func testMissingTrustIsRejectedAndOtherAuthenticationUsesDefaultHandling() {
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic] {
            let space = URLProtectionSpace(host: "relay.example", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
            RelaySessionDelegate().urlSession(.shared, didReceive: challenge) { disposition, credential in
                XCTAssertEqual(disposition, method == NSURLAuthenticationMethodServerTrust ? .cancelAuthenticationChallenge : .performDefaultHandling)
                XCTAssertNil(credential)
            }
        }
    }

    func testPlaintextRelayOriginRemainsRejected() {
        XCTAssertThrowsError(try RelayEndpoint(URL(string: "http://relay.example")!))
        XCTAssertThrowsError(try RelayEndpoint(URL(string: "http://127.0.0.1:8443")!))
    }

    func testOuterCertificatePolicyDoesNotEnableProofRedirects() {
        let url = URL(string: "https://relay.example")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        RelaySessionDelegate().urlSession(.shared, task: URLSession.shared.dataTask(with: url),
            willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://other.example")!)) {
            XCTAssertNil($0)
        }
    }
}

private final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust
    override var serverTrust: SecTrust? { trust }
    init(_ trust: SecTrust) {
        self.trust = trust
        super.init(host: "relay.example", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
