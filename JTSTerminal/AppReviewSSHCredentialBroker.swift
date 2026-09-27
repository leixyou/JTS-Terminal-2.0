import CryptoKit
import Darwin
import Foundation

#if JTS_UI_TEST_SUPPORT
/// Non-secret routing data for the one-shot formal App Review SSH credential
/// handoff. The password and pinned host-key bytes are deliberately absent
/// from the UI-test launch environment.
nonisolated struct AppReviewSSHCredentialBrokerRequest: Equatable, Sendable {
    let brokerHost: String
    let brokerPort: UInt16
    let challenge: String
    let nonce: String
    let expectedHost: String
    let expectedUsername: String
    let expectedCredentialAccount: String
    let expectedKnownHostsFilePath: String
    let expectedKnownHostsSHA256: String
    let expectedTemporaryDirectoryPath: String
}

fileprivate struct AppReviewSSHKnownHostsBoundary: Sendable {
    let directoryPath: String
    let directoryDevice: dev_t
    let directoryInode: ino_t
    let filePath: String
    let fileDevice: dev_t
    let fileInode: ino_t
}

nonisolated struct AppReviewSSHBrokerCredential: Sendable {
    let password: String
    let knownHostsFilePath: String
    fileprivate let knownHostsBoundary: AppReviewSSHKnownHostsBoundary

    /// Removes the owner-only file and directory created for this handoff,
    /// leaving replacements untouched. Success means both paths were confirmed
    /// absent, so the formal smoke cannot publish success with residual state.
    @discardableResult
    func cleanup() -> Bool {
        AppReviewSSHCredentialBrokerClient.cleanupKnownHosts(
            boundary: knownHostsBoundary
        )
    }
}

nonisolated enum AppReviewSSHCredentialBrokerError: LocalizedError, Equatable, Sendable {
    case incompleteConfiguration
    case insecureBoundary
    case connectionFailed
    case payloadTooLarge
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            return "The formal SSH smoke credential broker configuration is incomplete."
        case .insecureBoundary:
            return "The formal SSH smoke credential broker boundary is not owner-only."
        case .connectionFailed:
            return "The formal SSH smoke credential broker connection failed closed."
        case .payloadTooLarge:
            return "The formal SSH smoke credential broker payload exceeded its limit."
        case .invalidCredential:
            return "The formal SSH smoke credential did not match the frozen connection target."
        }
    }
}

/// Sandboxed IPv4-loopback client used only by Debug/UI-test builds. The
/// 128-bit challenge authenticates the one-shot endpoint, and both request and
/// response are bound to the exact port, nonce, SSH target, credential account,
/// destination path, and pinned host-key digest.
nonisolated enum AppReviewSSHCredentialBrokerClient {
    private static let loopbackHost = "127.0.0.1"
    private static let maximumPayloadBytes = 128 * 1_024
    private static let maximumKnownHostsBytes = 64 * 1_024
    private static let maximumChallengeBytes = 256
    private static let timeoutSeconds: Int = 5
    private static let knownHostsDirectoryPrefix = "k."
    private static let knownHostsFilename = "known_hosts"

    private struct WireRequest: Encodable {
        let version: Int
        let brokerHost: String
        let brokerPort: UInt16
        let challenge: String
        let nonce: String
        let host: String
        let username: String
        let credentialAccount: String
        let knownHostsFilePath: String
        let knownHostsSHA256: String
    }

    private struct WireCredential: Decodable {
        let version: Int
        let brokerHost: String
        let brokerPort: UInt16
        let challenge: String
        let nonce: String
        let host: String
        let username: String
        let credentialAccount: String
        let password: String
        let knownHostsFilePath: String
        let knownHostsSHA256: String
        let knownHostsBase64: String
    }

    static func configuredRequest(
        forHost host: String,
        username: String,
        credentialAccount: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> AppReviewSSHCredentialBrokerRequest? {
        guard environment[UITestSSHSessionEnvironment.isUITestingKey] == "1" else {
            return nil
        }

        let keys = [
            UITestSSHSessionEnvironment.smokeBrokerPortKey,
            UITestSSHSessionEnvironment.smokeBrokerChallengeKey,
            UITestSSHSessionEnvironment.smokeNonceKey,
            UITestSSHSessionEnvironment.smokeHostKey,
            UITestSSHSessionEnvironment.smokeUserKey,
            UITestSSHSessionEnvironment.smokeCredentialAccountKey,
            UITestSSHSessionEnvironment.smokeKnownHostsFileKey,
            UITestSSHSessionEnvironment.smokeKnownHostsSHA256Key,
        ]
        let hasAnyBrokerConfiguration = keys.contains { environment[$0] != nil }
        guard hasAnyBrokerConfiguration else { return nil }

        guard let rawPort = exactNonempty(
            environment[UITestSSHSessionEnvironment.smokeBrokerPortKey]
        ),
        let brokerPort = UInt16(rawPort),
        brokerPort > 0,
        String(brokerPort) == rawPort,
        let challenge = exactNonempty(
            environment[UITestSSHSessionEnvironment.smokeBrokerChallengeKey]
        ),
        let nonce = exactNonempty(environment[UITestSSHSessionEnvironment.smokeNonceKey]),
        let expectedHost = exactNonempty(environment[UITestSSHSessionEnvironment.smokeHostKey]),
        let expectedUsername = exactNonempty(environment[UITestSSHSessionEnvironment.smokeUserKey]),
        let expectedCredentialAccount = exactNonempty(
            environment[UITestSSHSessionEnvironment.smokeCredentialAccountKey]
        ),
        let knownHostsFilePath = exactNonempty(
            environment[UITestSSHSessionEnvironment.smokeKnownHostsFileKey]
        ),
        let knownHostsSHA256 = exactSHA256(
            environment[UITestSSHSessionEnvironment.smokeKnownHostsSHA256Key]
        ),
        expectedHost == host,
        expectedUsername == username,
        expectedUsername == "appreview",
        expectedCredentialAccount == credentialAccount,
        challenge.utf8.count >= 32,
        challenge.utf8.count <= maximumChallengeBytes,
        nonce.utf8.count >= 32,
        nonce.utf8.count <= maximumChallengeBytes,
        isSafeProtocolValue(challenge),
        isSafeProtocolValue(nonce),
        isPermittedKnownHostsPath(
            knownHostsFilePath,
            temporaryDirectory: temporaryDirectory
        ) else {
            throw AppReviewSSHCredentialBrokerError.incompleteConfiguration
        }

        return AppReviewSSHCredentialBrokerRequest(
            brokerHost: loopbackHost,
            brokerPort: brokerPort,
            challenge: challenge,
            nonce: nonce,
            expectedHost: expectedHost,
            expectedUsername: expectedUsername,
            expectedCredentialAccount: expectedCredentialAccount,
            expectedKnownHostsFilePath: knownHostsFilePath,
            expectedKnownHostsSHA256: knownHostsSHA256,
            expectedTemporaryDirectoryPath: temporaryDirectory.standardizedFileURL.path
        )
    }

    static func receiveCredential(
        for request: AppReviewSSHCredentialBrokerRequest
    ) throws -> AppReviewSSHBrokerCredential {
        guard request.brokerHost == loopbackHost,
              request.brokerPort > 0 else {
            throw AppReviewSSHCredentialBrokerError.incompleteConfiguration
        }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw AppReviewSSHCredentialBrokerError.connectionFailed
        }
        defer { Darwin.close(descriptor) }

        try configureTimeouts(for: descriptor)
        try connect(
            descriptor: descriptor,
            host: request.brokerHost,
            port: request.brokerPort
        )
        try verifyConnectedEndpoint(
            descriptor: descriptor,
            host: request.brokerHost,
            port: request.brokerPort
        )

        let wireRequest = WireRequest(
            version: 1,
            brokerHost: request.brokerHost,
            brokerPort: request.brokerPort,
            challenge: request.challenge,
            nonce: request.nonce,
            host: request.expectedHost,
            username: request.expectedUsername,
            credentialAccount: request.expectedCredentialAccount,
            knownHostsFilePath: request.expectedKnownHostsFilePath,
            knownHostsSHA256: request.expectedKnownHostsSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var requestData: Data
        do {
            requestData = try encoder.encode(wireRequest)
        } catch {
            throw AppReviewSSHCredentialBrokerError.connectionFailed
        }
        requestData.append(0x0A)
        try sendAll(requestData, to: descriptor)
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
            throw AppReviewSSHCredentialBrokerError.connectionFailed
        }

        let payload = try receivePayload(from: descriptor)
        return try decode(payload: payload, matching: request)
    }

    private static func configureTimeouts(for descriptor: Int32) throws {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        var noSignal = Int32(1)
        let receiveTimeout = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        let sendTimeout = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        let noPipeSignal = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard receiveTimeout == 0, sendTimeout == 0, noPipeSignal == 0 else {
            throw AppReviewSSHCredentialBrokerError.connectionFailed
        }
    }

    private static func connect(
        descriptor: Int32,
        host: String,
        port: UInt16
    ) throws {
        guard host == loopbackHost else {
            throw AppReviewSSHCredentialBrokerError.connectionFailed
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard Darwin.inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw AppReviewSSHCredentialBrokerError.connectionFailed
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard status == 0 else {
            throw AppReviewSSHCredentialBrokerError.connectionFailed
        }
    }

    private static func verifyConnectedEndpoint(
        descriptor: Int32,
        host: String,
        port: UInt16
    ) throws {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getpeername(descriptor, $0, &length)
            }
        }
        var expectedAddress = in_addr()
        guard status == 0,
              length == MemoryLayout<sockaddr_in>.size,
              address.sin_family == sa_family_t(AF_INET),
              address.sin_port == port.bigEndian,
              Darwin.inet_pton(AF_INET, host, &expectedAddress) == 1,
              address.sin_addr.s_addr == expectedAddress.s_addr else {
            throw AppReviewSSHCredentialBrokerError.connectionFailed
        }
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) throws {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.send(
                    descriptor,
                    bytes.baseAddress?.advanced(by: sent),
                    bytes.count - sent,
                    0
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw AppReviewSSHCredentialBrokerError.connectionFailed
            }
            sent += count
        }
    }

    private static func receivePayload(from descriptor: Int32) throws -> Data {
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AppReviewSSHCredentialBrokerError.connectionFailed
            }
            guard payload.count + count <= maximumPayloadBytes else {
                throw AppReviewSSHCredentialBrokerError.payloadTooLarge
            }
            payload.append(contentsOf: buffer.prefix(count))
        }
        guard !payload.isEmpty else {
            throw AppReviewSSHCredentialBrokerError.invalidCredential
        }
        return payload
    }

    private static func decode(
        payload: Data,
        matching request: AppReviewSSHCredentialBrokerRequest
    ) throws -> AppReviewSSHBrokerCredential {
        let expectedKeys: Set<String> = [
            "version",
            "brokerHost",
            "brokerPort",
            "challenge",
            "nonce",
            "host",
            "username",
            "credentialAccount",
            "password",
            "knownHostsFilePath",
            "knownHostsSHA256",
            "knownHostsBase64",
        ]
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == expectedKeys else {
            throw AppReviewSSHCredentialBrokerError.invalidCredential
        }

        let wireCredential: WireCredential
        do {
            wireCredential = try JSONDecoder().decode(WireCredential.self, from: payload)
        } catch {
            throw AppReviewSSHCredentialBrokerError.invalidCredential
        }

        guard wireCredential.version == 1,
              wireCredential.brokerHost == request.brokerHost,
              wireCredential.brokerPort == request.brokerPort,
              wireCredential.challenge == request.challenge,
              wireCredential.nonce == request.nonce,
              wireCredential.host == request.expectedHost,
              wireCredential.username == request.expectedUsername,
              wireCredential.credentialAccount == request.expectedCredentialAccount,
              wireCredential.knownHostsFilePath == request.expectedKnownHostsFilePath,
              wireCredential.knownHostsSHA256 == request.expectedKnownHostsSHA256,
              !wireCredential.password.isEmpty,
              !wireCredential.password.contains("\0"),
              let knownHostsData = Data(base64Encoded: wireCredential.knownHostsBase64),
              !knownHostsData.isEmpty,
              knownHostsData.count <= maximumKnownHostsBytes,
              !knownHostsData.contains(0),
              SHA256.hash(data: knownHostsData)
                  .map({ String(format: "%02x", $0) })
                  .joined() == request.expectedKnownHostsSHA256 else {
            throw AppReviewSSHCredentialBrokerError.invalidCredential
        }

        let boundary = try materializeKnownHosts(
            knownHostsData,
            at: request.expectedKnownHostsFilePath,
            temporaryDirectoryPath: request.expectedTemporaryDirectoryPath
        )
        return AppReviewSSHBrokerCredential(
            password: wireCredential.password,
            knownHostsFilePath: request.expectedKnownHostsFilePath,
            knownHostsBoundary: boundary
        )
    }

    /// The runner cannot write into a protected App Data container on current
    /// macOS. The sandboxed app creates this public pinned-host-key file itself
    /// after authenticating and validating the broker response.
    private static func materializeKnownHosts(
        _ data: Data,
        at filePath: String,
        temporaryDirectoryPath: String
    ) throws -> AppReviewSSHKnownHostsBoundary {
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        guard isPermittedKnownHostsPath(
            filePath,
            temporaryDirectory: URL(
                fileURLWithPath: temporaryDirectoryPath,
                isDirectory: true
            )
        ) else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }

        guard Darwin.mkdir(directoryURL.path, 0o700) == 0 else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }
        var shouldRemoveDirectory = true
        var shouldRemoveFile = false
        defer {
            if shouldRemoveFile {
                _ = Darwin.unlink(filePath)
            }
            if shouldRemoveDirectory {
                _ = Darwin.rmdir(directoryURL.path)
            }
        }

        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fchmod(directoryDescriptor, 0o700) == 0 else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }

        var directoryMetadata = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryMetadata.st_uid == getuid(),
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_mode & 0o777 == 0o700 else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }

        let fileDescriptor = Darwin.openat(
            directoryDescriptor,
            knownHostsFilename,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fileDescriptor >= 0 else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }
        shouldRemoveFile = true
        defer { Darwin.close(fileDescriptor) }

        guard Darwin.fchmod(fileDescriptor, 0o600) == 0 else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }
        try writeAll(data, to: fileDescriptor)
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }

        var fileMetadata = stat()
        var pathMetadata = stat()
        guard Darwin.fstat(fileDescriptor, &fileMetadata) == 0,
              Darwin.lstat(filePath, &pathMetadata) == 0,
              fileMetadata.st_uid == getuid(),
              fileMetadata.st_mode & S_IFMT == S_IFREG,
              fileMetadata.st_mode & 0o777 == 0o600,
              fileMetadata.st_nlink == 1,
              sameNode(fileMetadata, pathMetadata) else {
            throw AppReviewSSHCredentialBrokerError.insecureBoundary
        }

        shouldRemoveFile = false
        shouldRemoveDirectory = false
        return AppReviewSSHKnownHostsBoundary(
            directoryPath: directoryURL.path,
            directoryDevice: directoryMetadata.st_dev,
            directoryInode: directoryMetadata.st_ino,
            filePath: filePath,
            fileDevice: fileMetadata.st_dev,
            fileInode: fileMetadata.st_ino
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw AppReviewSSHCredentialBrokerError.insecureBoundary
            }
            written += count
        }
    }

    fileprivate static func cleanupKnownHosts(
        boundary: AppReviewSSHKnownHostsBoundary
    ) -> Bool {
        var cleanupSucceeded = true
        var fileMetadata = stat()
        let fileStatus = Darwin.lstat(boundary.filePath, &fileMetadata)
        if fileStatus == 0 {
            let identityMatches = fileMetadata.st_uid == getuid()
                && fileMetadata.st_mode & S_IFMT == S_IFREG
                && fileMetadata.st_nlink == 1
                && fileMetadata.st_dev == boundary.fileDevice
                && fileMetadata.st_ino == boundary.fileInode
            if !identityMatches || Darwin.unlink(boundary.filePath) != 0 {
                cleanupSucceeded = false
            }
        } else if errno != ENOENT {
            cleanupSucceeded = false
        }

        var directoryMetadata = stat()
        let directoryStatus = Darwin.lstat(
            boundary.directoryPath,
            &directoryMetadata
        )
        if directoryStatus == 0 {
            let identityMatches = directoryMetadata.st_uid == getuid()
                && directoryMetadata.st_mode & S_IFMT == S_IFDIR
                && directoryMetadata.st_dev == boundary.directoryDevice
                && directoryMetadata.st_ino == boundary.directoryInode
            if !identityMatches || Darwin.rmdir(boundary.directoryPath) != 0 {
                cleanupSucceeded = false
            }
        } else if errno != ENOENT {
            cleanupSucceeded = false
        }

        return cleanupSucceeded
            && pathIsAbsent(boundary.filePath)
            && pathIsAbsent(boundary.directoryPath)
    }

    private static func pathIsAbsent(_ path: String) -> Bool {
        var metadata = stat()
        if Darwin.lstat(path, &metadata) == 0 {
            return false
        }
        return errno == ENOENT
    }

    private static func sameNode(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_mode == right.st_mode
            && left.st_uid == right.st_uid
            && left.st_nlink == right.st_nlink
            && left.st_size == right.st_size
    }

    private static func isPermittedKnownHostsPath(
        _ path: String,
        temporaryDirectory: URL
    ) -> Bool {
        guard isSafeProtocolValue(path) else { return false }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        let expectedTemporaryDirectory = temporaryDirectory.standardizedFileURL
        let directoryName = directoryURL.lastPathComponent
        let randomSuffix = directoryName.dropFirst(knownHostsDirectoryPrefix.count)
        return fileURL.path == path
            && fileURL.lastPathComponent == knownHostsFilename
            && directoryName.hasPrefix(knownHostsDirectoryPrefix)
            && randomSuffix.count == 8
            && randomSuffix.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
            && directoryURL.deletingLastPathComponent() == expectedTemporaryDirectory
    }

    private static func exactNonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              isSafeProtocolValue(value) else {
            return nil
        }
        return value
    }

    private static func exactSHA256(_ value: String?) -> String? {
        guard let value = exactNonempty(value),
              value.count == 64,
              value.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            return nil
        }
        return value
    }

    private static func isSafeProtocolValue(_ value: String) -> Bool {
        !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }
}
#endif
