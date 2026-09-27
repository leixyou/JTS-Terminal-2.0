import CryptoKit
import Foundation
import Security

public protocol EnrollmentHTTPTransport: Sendable {
    func post(_ url: URL, body: Data) async throws -> (Int, Data)
}

/// Dedicated enrollment transport: HTTPS only, no redirects/cookies/cache or body logging.
public final class EnrollmentURLTransport: EnrollmentHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: EnrollmentTLSDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func post(_ url: URL, body: Data) async throws -> (Int, Data) {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url,
              response.expectedContentLength <= 32768 else { throw EnrollmentError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32768 else { throw EnrollmentError.invalidResponse }; data.append(byte)
        }
        return (response.statusCode, data)
    }
}

private final class EnrollmentTLSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completion(.performDefaultHandling, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust else { completion(.cancelAuthenticationChallenge, nil); return }
        // The independent invitation secret authenticates both encrypted enrollment messages.
        completion(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor EnrollmentClient {
    public let controllerDeviceId: String
    public let relayOrigin: String
    private let key: P256.Signing.PrivateKey
    private let transport: any EnrollmentHTTPTransport

    public init(privateKey: Data, relayOrigin: String, transport: any EnrollmentHTTPTransport = EnrollmentURLTransport()) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
        controllerDeviceId = EnrollmentWire.hash(key.publicKey.derRepresentation)
        self.relayOrigin = try EnrollmentWire.origin(relayOrigin); self.transport = transport
    }

    public func create(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt {
        try attempt.validate(controllerDeviceId: controllerDeviceId)
        let code = try EnrollmentCode(attempt.code)
        guard code.relayOrigin == relayOrigin else { throw EnrollmentError.changed }
        let data = try await call(["action": "create", "invitationId": attempt.id,
            "claimTokenHash": code.claimTokenHash, "offerBase64": attempt.offer.base64EncodedString(),
            "expiresAtUnixSeconds": attempt.expiresAtUnixSeconds])
        let receipt = try EnrollmentReceipt.decode(data); try attempt.check(receipt); return receipt
    }
    public func status(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt {
        try await receipt(action: "status", attempt: attempt)
    }
    public func cancel(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt {
        try await receipt(action: "cancel", attempt: attempt)
    }
    public func confirm(_ attempt: EnrollmentAttempt) async throws -> EnrollmentReceipt {
        guard let claim = attempt.verifiedClaim else { throw EnrollmentError.invalidMessage }
        _ = try attempt.bundle(for: claim)
        return try await receipt(action: "confirm", attempt: attempt, claimHash: claim.claimHash)
    }
    public func revoke(peerDeviceId: String) async throws {
        guard peerDeviceId.count == 64, peerDeviceId.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EnrollmentError.invalidIdentity
        }
        let data = try await call(["action": "revoke", "peerDeviceId": peerDeviceId])
        let object = try EnrollmentWire.object(data, required: ["peerDeviceId", "state"])
        guard object["peerDeviceId"] as? String == peerDeviceId, object["state"] as? String == "revoked" else {
            throw EnrollmentError.invalidResponse
        }
    }
    private func receipt(action: String, attempt: EnrollmentAttempt, claimHash: String? = nil) async throws -> EnrollmentReceipt {
        try attempt.validate(controllerDeviceId: controllerDeviceId)
        guard try EnrollmentCode(attempt.code).relayOrigin == relayOrigin else { throw EnrollmentError.changed }
        var payload = ["action": action, "invitationId": attempt.id]
        if let claimHash { payload["claimHash"] = claimHash }
        let value = try EnrollmentReceipt.decode(await call(payload)); try attempt.check(value); return value
    }
    private func call(_ payload: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 16384 else { throw EnrollmentError.invalidMessage }
        let challengeData = try await post("/v1/challenges", data: JSONSerialization.data(withJSONObject:
            ["deviceId": controllerDeviceId, "operation": "enrollment"]))
        let object = try EnrollmentWire.object(challengeData, required: ["challengeId", "nonceBase64", "expiresAtUnixSeconds"])
        struct Challenge: Decodable { let challengeId, nonceBase64: String; let expiresAtUnixSeconds: Int64 }
        let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
        _ = object
        let now = Int64(Date().timeIntervalSince1970)
        guard UUID(uuidString: challenge.challengeId) != nil,
              try EnrollmentWire.base64(challenge.nonceBase64, maximum: 32).count == 32,
              challenge.expiresAtUnixSeconds > now, challenge.expiresAtUnixSeconds <= now + 65 else {
            throw EnrollmentError.invalidResponse
        }
        let transcript = Data(["JTS-RELAY-AUTH-V1", controllerDeviceId, "enrollment", challenge.challengeId,
                               challenge.nonceBase64, EnrollmentWire.hash(data)].joined(separator: "\n").utf8)
        return try await post("/v1/enrollment", data: JSONSerialization.data(withJSONObject:
            ["deviceId": controllerDeviceId, "challengeId": challenge.challengeId, "payloadBase64": data.base64EncodedString(),
             "signatureBase64": try key.signature(for: transcript).rawRepresentation.base64EncodedString()]))
    }
    private func post(_ path: String, data: Data) async throws -> Data {
        let (status, body) = try await transport.post(URL(string: relayOrigin + path)!, body: data)
        guard body.count <= 32768 else { throw EnrollmentError.invalidResponse }
        if status != 200 {
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let code = object?["code"] as? String ?? "request_failed"
            let safe = !code.isEmpty && code.count <= 64 && code.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
            throw EnrollmentError.remote(safe ? code : "request_failed")
        }
        return body
    }
}
