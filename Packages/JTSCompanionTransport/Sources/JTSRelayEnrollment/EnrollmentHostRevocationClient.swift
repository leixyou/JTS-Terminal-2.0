import CryptoKit
import Foundation

/// Companion-side signed revocation mailbox. Relay-supplied public keys never create trust.
/// Callers must persist a deny record and drain live bridges before preparing a receipt;
/// persist that exact signed receipt before submitting it so lost acknowledgements are retryable.
public actor EnrollmentHostRevocationClient {
    public let deviceID: String
    public let relayOrigin: String
    private let key: P256.Signing.PrivateKey
    private let transport: any EnrollmentHTTPTransport

    public init(privateKey: Data, relayOrigin: String,
                transport: any EnrollmentHTTPTransport = EnrollmentURLTransport()) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
        deviceID = EnrollmentWire.hash(key.publicKey.derRepresentation)
        self.relayOrigin = try EnrollmentWire.origin(relayOrigin); self.transport = transport
    }

    public func poll(authorizations: [EnrollmentHostAuthorization]) async throws -> [EnrollmentRevocation] {
        let object = try EnrollmentWire.object(await call(["action": "poll"]), required: ["revocations"])
        guard let items = object["revocations"] as? [[String: Any]], items.count <= 32 else { throw EnrollmentError.invalidResponse }
        var seen = Set<String>(), output: [EnrollmentRevocation] = []
        for item in items {
            _ = try EnrollmentWire.object(JSONSerialization.data(withJSONObject: item), required:
                ["revocationId", "requestHash", "state", "revocation", "controllerSPKIBase64"])
            let request = try EnrollmentRevocation.decode(JSONSerialization.data(withJSONObject: item["revocation"]!))
            guard item["revocationId"] as? String == request.revocationId, item["state"] as? String == "pending",
                  item["requestHash"] as? String == (try request.requestHash), seen.insert(request.revocationId).inserted,
                  request.relayOrigin == relayOrigin else { throw EnrollmentError.invalidResponse }
            try request.verifyPeer(key.publicKey.derRepresentation)
            // A stale pairing epoch is not a request to revoke the current grant, and is never acknowledged.
            guard let authorization = authorizations.first(where: {
                $0.controllerDeviceID == request.controllerDeviceId && $0.relayOrigin == relayOrigin &&
                $0.pairingID.uuidString.lowercased() == request.pairingId &&
                $0.controlGrantID.uuidString.lowercased() == request.grantId &&
                $0.fileGrantID.uuidString.lowercased() == request.fileGrantId &&
                $0.rdpGrantID.uuidString.lowercased() == request.rdpGrantId
            }) else { continue }
            guard item["controllerSPKIBase64"] as? String == authorization.controllerSPKI.base64EncodedString() else {
                throw EnrollmentError.invalidIdentity
            }
            try validate(request, authorization: authorization)
            output.append(request)
        }
        return output
    }

    public func prepareReceipt(for request: EnrollmentRevocation, authorization: EnrollmentHostAuthorization,
                               now: Date = Date()) throws -> EnrollmentRevocationReceipt {
        try validate(request, authorization: authorization)
        let instant = now.timeIntervalSince1970
        guard instant.isFinite, instant >= 1, instant < Double(Int64.max) else { throw EnrollmentError.invalidMessage }
        let at = Int64(instant), hash = try request.requestHash
        let transcript = Data(["JTS-PAIR-REVOKED-2", request.revocationId, hash, request.controllerDeviceId,
            request.peerDeviceId, String(at)].joined(separator: "\n").utf8)
        return EnrollmentRevocationReceipt(version: 2, revocationId: request.revocationId, requestHash: hash,
            controllerDeviceId: request.controllerDeviceId, peerDeviceId: deviceID, revokedAtUnixSeconds: at,
            signatureBase64: try key.signature(for: transcript).rawRepresentation.base64EncodedString())
    }

    public func complete(_ receipt: EnrollmentRevocationReceipt, revocation: EnrollmentRevocation,
                         authorization: EnrollmentHostAuthorization) async throws -> EnrollmentRevocationStatus {
        try validate(revocation, authorization: authorization)
        try receipt.verify(revocation: revocation, peerSPKI: key.publicKey.derRepresentation)
        let result = try EnrollmentRevocationStatus.decode(await call(["action": "complete",
            "receipt": try JSONSerialization.jsonObject(with: EnrollmentWire.encode(receipt))]), expected: revocation,
            controllerSPKI: authorization.controllerSPKI, peerSPKI: key.publicKey.derRepresentation)
        guard result.state == .complete, result.receipt == receipt else { throw EnrollmentError.invalidResponse }
        return result
    }

    private func validate(_ request: EnrollmentRevocation, authorization: EnrollmentHostAuthorization) throws {
        try authorization.validate()
        guard authorization.relayOrigin == relayOrigin, request.relayOrigin == relayOrigin,
              authorization.controllerDeviceID == request.controllerDeviceId,
              authorization.pairingID.uuidString.lowercased() == request.pairingId,
              authorization.controlGrantID.uuidString.lowercased() == request.grantId,
              authorization.fileGrantID.uuidString.lowercased() == request.fileGrantId,
              authorization.rdpGrantID.uuidString.lowercased() == request.rdpGrantId else { throw EnrollmentError.changed }
        try request.verify(controllerSPKI: authorization.controllerSPKI)
        try request.verifyPeer(key.publicKey.derRepresentation)
    }

    private func call(_ payload: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 16384 else { throw EnrollmentError.invalidMessage }
        let challengeData = try await post("/v1/challenges", body: JSONSerialization.data(withJSONObject:
            ["deviceId": deviceID, "operation": "revocations"]))
        _ = try EnrollmentWire.object(challengeData, required: ["challengeId", "nonceBase64", "expiresAtUnixSeconds"])
        struct Challenge: Decodable { let challengeId, nonceBase64: String; let expiresAtUnixSeconds: Int64 }
        let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
        let now = Int64(Date().timeIntervalSince1970)
        guard EnrollmentWire.validID(challenge.challengeId),
              try EnrollmentWire.base64(challenge.nonceBase64, maximum: 32).count == 32,
              challenge.expiresAtUnixSeconds > now, challenge.expiresAtUnixSeconds <= now + 65 else {
            throw EnrollmentError.invalidResponse
        }
        let transcript = Data(["JTS-RELAY-AUTH-V2", relayOrigin, deviceID, "revocations", challenge.challengeId,
            challenge.nonceBase64, EnrollmentWire.hash(data)].joined(separator: "\n").utf8)
        return try await post("/v1/revocations", body: JSONSerialization.data(withJSONObject:
            ["deviceId": deviceID, "challengeId": challenge.challengeId, "payloadBase64": data.base64EncodedString(),
             "signatureBase64": try key.signature(for: transcript).rawRepresentation.base64EncodedString()]))
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        let (status, response) = try await transport.post(URL(string: relayOrigin + path)!, body: body)
        guard response.count <= 32768 else { throw EnrollmentError.invalidResponse }
        guard status == 200 else {
            let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
            let value = object?["code"] as? String ?? "request_failed"
            let safe = (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }
            throw EnrollmentError.remote(safe ? value : "request_failed")
        }
        return response
    }
}
