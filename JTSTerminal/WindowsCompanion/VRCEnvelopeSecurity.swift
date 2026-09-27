#if ENABLE_RDP_2
import CryptoKit
import Foundation

nonisolated struct VRCJobEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = "jts-vrc-job-envelope-v1"

    var schemaVersion: String
    var windowsDeviceId: UUID
    var clientDeviceId: UUID
    var clientFingerprintSha256: String
    var jobId: String
    var totalBytes: Int64
    var bundleSha256: String
    var issuedAtUnixMilliseconds: Int64
    var signatureBase64: String

    var foundationValue: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "windowsDeviceId": windowsDeviceId.uuidString.lowercased(),
            "clientDeviceId": clientDeviceId.uuidString.lowercased(),
            "clientFingerprintSha256": clientFingerprintSha256,
            "jobId": jobId,
            "totalBytes": totalBytes,
            "bundleSha256": bundleSha256,
            "issuedAtUnixMilliseconds": issuedAtUnixMilliseconds,
            "signatureBase64": signatureBase64,
        ]
    }
}

nonisolated struct VRCResultEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = "jts-vrc-result-envelope-v1"

    var schemaVersion: String
    var windowsDeviceId: UUID
    var windowsFingerprintSha256: String
    var clientDeviceId: UUID
    var clientFingerprintSha256: String
    var jobId: String
    var state: String
    var totalBytes: Int64
    var bundleSha256: String
    var issuedAtUnixMilliseconds: Int64
    var signatureBase64: String

    var foundationValue: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "windowsDeviceId": windowsDeviceId.uuidString.lowercased(),
            "windowsFingerprintSha256": windowsFingerprintSha256,
            "clientDeviceId": clientDeviceId.uuidString.lowercased(),
            "clientFingerprintSha256": clientFingerprintSha256,
            "jobId": jobId,
            "state": state,
            "totalBytes": totalBytes,
            "bundleSha256": bundleSha256,
            "issuedAtUnixMilliseconds": issuedAtUnixMilliseconds,
            "signatureBase64": signatureBase64,
        ]
    }
}

nonisolated enum VRCEnvelopeSecurityError: LocalizedError, Equatable {
    case invalidJobEnvelope
    case invalidResultEnvelope
    case invalidResultSignature

    var code: String {
        switch self {
        case .invalidJobEnvelope:
            return "WORKER_JOB_ENVELOPE_INVALID"
        case .invalidResultEnvelope:
            return "WORKER_RESULT_ENVELOPE_INVALID"
        case .invalidResultSignature:
            return "WORKER_RESULT_SIGNATURE_INVALID"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidJobEnvelope:
            return "\(code): The VRC worker job envelope could not be signed with the paired Mac identity."
        case .invalidResultEnvelope:
            return "\(code): The VRC worker result envelope is malformed, stale, or belongs to another job or device."
        case .invalidResultSignature:
            return "\(code): The VRC worker result envelope signature is invalid."
        }
    }
}

/// Durable VRC job/result authentication. Unlike DVC frame authentication,
/// this deliberately binds device identities and artifact metadata without a
/// transient session binding so a persisted worker result remains verifiable
/// after an RDP reconnect.
nonisolated enum VRCEnvelopeSecurity {
    static let maximumEnvelopeAgeMilliseconds: Int64 = 10 * 60 * 1_000
    static let maximumFutureSkewMilliseconds: Int64 = 60 * 1_000

    static func signJob(
        peer: WindowsCompanionPeerIdentity,
        jobID: String,
        totalBytes: Int64,
        bundleSHA256: String,
        signingKey: P256.Signing.PrivateKey,
        issuedAt: Date = Date()
    ) throws -> VRCJobEnvelope {
        let clientFingerprint = WindowsCompanionAuthorizationProof.fingerprint(
            publicKeyDER: signingKey.publicKey.derRepresentation
        )
        guard isValidJobID(jobID),
              totalBytes > 0,
              let normalizedBundleSHA256 = normalizedSHA256(bundleSHA256),
              peer.deviceID != zeroUUID,
              peer.clientDeviceID != zeroUUID,
              constantTimeHexEqual(clientFingerprint, peer.clientFingerprintSHA256),
              let issuedAtUnixMilliseconds = unixMilliseconds(issuedAt) else {
            throw VRCEnvelopeSecurityError.invalidJobEnvelope
        }

        var envelope = VRCJobEnvelope(
            schemaVersion: VRCJobEnvelope.schemaVersion,
            windowsDeviceId: peer.deviceID,
            clientDeviceId: peer.clientDeviceID,
            clientFingerprintSha256: clientFingerprint,
            jobId: jobID,
            totalBytes: totalBytes,
            bundleSha256: normalizedBundleSHA256,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            signatureBase64: ""
        )
        let signature = try signingKey.signature(
            for: VRCEnvelopeCanonicalizer.job(envelope)
        ).rawRepresentation
        guard signature.count == 64 else {
            throw VRCEnvelopeSecurityError.invalidJobEnvelope
        }
        envelope.signatureBase64 = signature.base64EncodedString()
        return envelope
    }

    static func verifyResult(
        _ value: Any,
        peer: WindowsCompanionPeerIdentity,
        expectedJobID: String,
        expectedTotalBytes: Int64,
        expectedBundleSHA256: String,
        now: Date = Date()
    ) throws -> VRCResultEnvelope {
        guard let dictionary = value as? [String: Any],
              Set(dictionary.keys) == resultPropertyNames,
              let envelope = resultEnvelope(dictionary),
              envelope.schemaVersion == VRCResultEnvelope.schemaVersion,
              envelope.windowsDeviceId == peer.deviceID,
              envelope.clientDeviceId == peer.clientDeviceID,
              envelope.jobId == expectedJobID,
              envelope.state == "collected",
              envelope.totalBytes == expectedTotalBytes,
              envelope.totalBytes > 0,
              constantTimeHexEqual(envelope.bundleSha256, expectedBundleSHA256),
              constantTimeHexEqual(envelope.windowsFingerprintSha256, peer.fingerprintSHA256),
              constantTimeHexEqual(envelope.clientFingerprintSha256, peer.clientFingerprintSHA256),
              constantTimeHexEqual(
                  peer.fingerprintSHA256,
                  WindowsCompanionAuthorizationProof.fingerprint(publicKeyDER: peer.publicKeyDER)
              ),
              isFresh(envelope.issuedAtUnixMilliseconds, now: now),
              let signature = Data(base64Encoded: envelope.signatureBase64),
              signature.count == 64 else {
            throw VRCEnvelopeSecurityError.invalidResultEnvelope
        }

        do {
            let publicKey = try P256.Signing.PublicKey(derRepresentation: peer.publicKeyDER)
            let parsedSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard publicKey.isValidSignature(
                parsedSignature,
                for: try VRCEnvelopeCanonicalizer.result(envelope)
            ) else {
                throw VRCEnvelopeSecurityError.invalidResultSignature
            }
        } catch let error as VRCEnvelopeSecurityError {
            throw error
        } catch {
            throw VRCEnvelopeSecurityError.invalidResultSignature
        }

        return envelope
    }

    private static let resultPropertyNames: Set<String> = [
        "schemaVersion",
        "windowsDeviceId",
        "windowsFingerprintSha256",
        "clientDeviceId",
        "clientFingerprintSha256",
        "jobId",
        "state",
        "totalBytes",
        "bundleSha256",
        "issuedAtUnixMilliseconds",
        "signatureBase64",
    ]

    private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private static func resultEnvelope(_ value: [String: Any]) -> VRCResultEnvelope? {
        guard let schemaVersion = value["schemaVersion"] as? String,
              let windowsDeviceIDValue = value["windowsDeviceId"] as? String,
              let windowsDeviceID = UUID(uuidString: windowsDeviceIDValue),
              windowsDeviceID != zeroUUID,
              let windowsFingerprint = value["windowsFingerprintSha256"] as? String,
              normalizedSHA256(windowsFingerprint) != nil,
              let clientDeviceIDValue = value["clientDeviceId"] as? String,
              let clientDeviceID = UUID(uuidString: clientDeviceIDValue),
              clientDeviceID != zeroUUID,
              let clientFingerprint = value["clientFingerprintSha256"] as? String,
              normalizedSHA256(clientFingerprint) != nil,
              let jobID = value["jobId"] as? String,
              isValidJobID(jobID),
              let state = value["state"] as? String,
              let totalBytes = exactInt64(value["totalBytes"]),
              let bundleSHA256 = value["bundleSha256"] as? String,
              normalizedSHA256(bundleSHA256) != nil,
              let issuedAt = exactInt64(value["issuedAtUnixMilliseconds"]),
              let signatureBase64 = value["signatureBase64"] as? String else {
            return nil
        }
        return VRCResultEnvelope(
            schemaVersion: schemaVersion,
            windowsDeviceId: windowsDeviceID,
            windowsFingerprintSha256: windowsFingerprint,
            clientDeviceId: clientDeviceID,
            clientFingerprintSha256: clientFingerprint,
            jobId: jobID,
            state: state,
            totalBytes: totalBytes,
            bundleSha256: bundleSHA256,
            issuedAtUnixMilliseconds: issuedAt,
            signatureBase64: signatureBase64
        )
    }

    private static func exactInt64(_ value: Any?) -> Int64? {
        if value is Bool { return nil }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? UInt64, value <= UInt64(Int64.max) { return Int64(value) }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return nil
        }
        return number.int64Value
    }

    private static func isValidJobID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (2...96).contains(bytes.count),
              isLowercaseASCIIAlphaNumeric(bytes[0]) else {
            return false
        }
        return bytes.allSatisfy { byte in
            isLowercaseASCIIAlphaNumeric(byte) || byte == 45 || byte == 95
        }
    }

    private static func isLowercaseASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private static func unixMilliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= Double(Int64.min),
              value <= Double(Int64.max) else {
            return nil
        }
        return Int64(value.rounded(.towardZero))
    }

    private static func isFresh(_ issuedAt: Int64, now: Date) -> Bool {
        guard let nowMilliseconds = unixMilliseconds(now) else { return false }
        let (oldest, underflow) = nowMilliseconds.subtractingReportingOverflow(
            maximumEnvelopeAgeMilliseconds
        )
        let (latest, overflow) = nowMilliseconds.addingReportingOverflow(
            maximumFutureSkewMilliseconds
        )
        return !underflow && !overflow && issuedAt >= oldest && issuedAt <= latest
    }

    private static func normalizedSHA256(_ value: String) -> String? {
        let bytes = value.utf8
        guard bytes.count == 64, bytes.allSatisfy({ byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }) else {
            return nil
        }
        return value.lowercased()
    }

    private static func constantTimeHexEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = hexadecimalData(lhs),
              let right = hexadecimalData(rhs),
              left.count == right.count else {
            return false
        }
        return zip(left, right).reduce(UInt8.zero) { result, bytes in
            result | (bytes.0 ^ bytes.1)
        } == 0
    }

    private static func hexadecimalData(_ value: String) -> Data? {
        guard value.utf8.count == 64 else { return nil }
        var result = Data(capacity: 32)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

nonisolated enum VRCEnvelopeCanonicalizer {
    static func job(_ envelope: VRCJobEnvelope) throws -> Data {
        var data = Data("JTS-VRC-JOB-ENVELOPE-V1\0".utf8)
        try appendString(envelope.windowsDeviceId.uuidString.lowercased(), to: &data)
        try appendString(envelope.clientDeviceId.uuidString.lowercased(), to: &data)
        try appendDigest(envelope.clientFingerprintSha256, to: &data)
        try appendString(envelope.jobId, to: &data)
        appendInt64(envelope.totalBytes, to: &data)
        try appendDigest(envelope.bundleSha256, to: &data)
        appendInt64(envelope.issuedAtUnixMilliseconds, to: &data)
        return data
    }

    static func result(_ envelope: VRCResultEnvelope) throws -> Data {
        var data = Data("JTS-VRC-RESULT-ENVELOPE-V1\0".utf8)
        try appendString(envelope.windowsDeviceId.uuidString.lowercased(), to: &data)
        try appendDigest(envelope.windowsFingerprintSha256, to: &data)
        try appendString(envelope.clientDeviceId.uuidString.lowercased(), to: &data)
        try appendDigest(envelope.clientFingerprintSha256, to: &data)
        try appendString(envelope.jobId, to: &data)
        try appendString(envelope.state, to: &data)
        appendInt64(envelope.totalBytes, to: &data)
        try appendDigest(envelope.bundleSha256, to: &data)
        appendInt64(envelope.issuedAtUnixMilliseconds, to: &data)
        return data
    }

    private static func appendString(_ value: String, to data: inout Data) throws {
        let encoded = Data(value.utf8)
        guard encoded.count <= Int(UInt16.max) else {
            throw VRCEnvelopeSecurityError.invalidResultEnvelope
        }
        appendUInt16(UInt16(encoded.count), to: &data)
        data.append(encoded)
    }

    private static func appendDigest(_ value: String, to data: inout Data) throws {
        guard value.utf8.count == 64 else {
            throw VRCEnvelopeSecurityError.invalidResultEnvelope
        }
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw VRCEnvelopeSecurityError.invalidResultEnvelope
            }
            data.append(byte)
            index = next
        }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func appendInt64(_ value: Int64, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}
#endif
