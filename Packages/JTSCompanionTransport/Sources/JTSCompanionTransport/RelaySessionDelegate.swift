import Foundation
import Security

/// The relay is an untrusted ciphertext carrier. Its outer HTTPS certificate is
/// accepted by default; endpoint authentication remains the pinned inner TLS.
/// This delegate is used only by the dedicated relay HTTP/WebSocket sessions.
final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    private func answer(_ challenge: URLAuthenticationChallenge,
                        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completion(.performDefaultHandling, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            completion(.cancelAuthenticationChallenge, nil); return
        }
        completion(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Accepting the carrier certificate does not allow proof/ticket redirects.
        completionHandler(nil)
    }
}
