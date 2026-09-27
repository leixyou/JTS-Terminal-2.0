import CryptoKit
import Darwin
import Foundation
import Testing
@testable import JTSTerminal

@Suite(.serialized)
struct AppReviewSSHCredentialBrokerTests {
    @Test func realLoopbackHandoffIsChallengeSnapshotAndHostKeyBound() async throws {
        let paths = TestPaths.make()
        defer { paths.cleanup() }

        let listener = try Self.makeListeningSocket()
        defer { Darwin.close(listener.descriptor) }

        let challenge = String(repeating: "c", count: 32)
        let nonce = String(repeating: "n", count: 32)
        let account = "appreview@8.8.8.8:22"
        let secret = "synthetic-one-shot-secret"
        let knownHostsData = Data("example ssh-ed25519 AAAATEST\n".utf8)
        let knownHostsSHA256 = Self.sha256(knownHostsData)
        let payload = try Self.payload(
            port: listener.port,
            challenge: challenge,
            nonce: nonce,
            account: account,
            password: secret,
            knownHostsPath: paths.knownHosts.path,
            knownHostsSHA256: knownHostsSHA256,
            knownHostsData: knownHostsData
        )

        let server = Task.detached { () throws -> [String: Any] in
            let client = Darwin.accept(listener.descriptor, nil, nil)
            guard client >= 0 else { throw TestSocketError.operationFailed }
            defer { Darwin.close(client) }

            let requestData = try Self.readAll(from: client)
            try Self.sendAll(payload, to: client)
            guard Darwin.shutdown(client, SHUT_WR) == 0,
                  let object = try JSONSerialization.jsonObject(with: requestData)
                    as? [String: Any] else {
                throw TestSocketError.operationFailed
            }
            return object
        }

        let environment = Self.environment(
            paths: paths,
            port: listener.port,
            challenge: challenge,
            nonce: nonce,
            account: account,
            knownHostsSHA256: knownHostsSHA256
        )
        let configuredRequest = try AppReviewSSHCredentialBrokerClient.configuredRequest(
            forHost: "8.8.8.8",
            username: "appreview",
            credentialAccount: account,
            environment: environment
        )
        let request = try #require(configuredRequest)
        let credential = try await Task.detached {
            try AppReviewSSHCredentialBrokerClient.receiveCredential(for: request)
        }.value

        #expect(credential.password == secret)
        #expect(credential.knownHostsFilePath == paths.knownHosts.path)
        #expect(try Data(contentsOf: paths.knownHosts) == knownHostsData)
        let requestObject = try await server.value
        #expect(requestObject["version"] as? Int == 1)
        #expect(requestObject["brokerHost"] as? String == "127.0.0.1")
        #expect(requestObject["brokerPort"] as? Int == Int(listener.port))
        #expect(requestObject["challenge"] as? String == challenge)
        #expect(requestObject["nonce"] as? String == nonce)
        #expect(requestObject["host"] as? String == "8.8.8.8")
        #expect(requestObject["credentialAccount"] as? String == account)
        #expect(requestObject["knownHostsFilePath"] as? String == paths.knownHosts.path)
        #expect(requestObject["knownHostsSHA256"] as? String == knownHostsSHA256)

        #expect(credential.cleanup())
        #expect(!FileManager.default.fileExists(atPath: paths.knownHosts.path))
        #expect(!FileManager.default.fileExists(atPath: paths.directory.path))
        #expect(credential.cleanup(), "Cleanup must be idempotent once both paths are absent.")

        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("replacement\n".utf8).write(to: paths.knownHosts)
        #expect(
            !credential.cleanup(),
            "A replacement inode must prevent a successful cleanup proof."
        )
        #expect(
            FileManager.default.fileExists(atPath: paths.knownHosts.path),
            "Cleanup must leave a replacement path untouched."
        )
        #expect(throws: AppReviewSSHCredentialBrokerError.connectionFailed) {
            try AppReviewSSHCredentialBrokerClient.receiveCredential(for: request)
        }
    }

    @Test func wirePayloadRejectsKnownHostsDigestMismatchWithoutCreatingFile() async throws {
        let paths = TestPaths.make()
        defer { paths.cleanup() }

        let listener = try Self.makeListeningSocket()
        defer { Darwin.close(listener.descriptor) }

        let challenge = String(repeating: "c", count: 32)
        let nonce = String(repeating: "n", count: 32)
        let account = "appreview@8.8.8.8:22"
        let knownHostsData = Data("example ssh-ed25519 AAAATEST\n".utf8)
        let expectedSHA256 = Self.sha256(knownHostsData)
        let payload = try Self.payload(
            port: listener.port,
            challenge: challenge,
            nonce: nonce,
            account: account,
            password: "synthetic-one-shot-secret",
            knownHostsPath: paths.knownHosts.path,
            knownHostsSHA256: String(repeating: "0", count: 64),
            knownHostsData: knownHostsData
        )

        let server = Task.detached {
            let client = Darwin.accept(listener.descriptor, nil, nil)
            guard client >= 0 else { throw TestSocketError.operationFailed }
            defer { Darwin.close(client) }
            _ = try Self.readAll(from: client)
            try Self.sendAll(payload, to: client)
            guard Darwin.shutdown(client, SHUT_WR) == 0 else {
                throw TestSocketError.operationFailed
            }
        }

        let request = try #require(
            try AppReviewSSHCredentialBrokerClient.configuredRequest(
                forHost: "8.8.8.8",
                username: "appreview",
                credentialAccount: account,
                environment: Self.environment(
                    paths: paths,
                    port: listener.port,
                    challenge: challenge,
                    nonce: nonce,
                    account: account,
                    knownHostsSHA256: expectedSHA256
                )
            )
        )

        do {
            _ = try await Task.detached {
                try AppReviewSSHCredentialBrokerClient.receiveCredential(for: request)
            }.value
            Issue.record("A mismatched known_hosts digest must fail closed.")
        } catch let error as AppReviewSSHCredentialBrokerError {
            #expect(error == .invalidCredential)
        }
        try await server.value
        #expect(!FileManager.default.fileExists(atPath: paths.knownHosts.path))
        #expect(!FileManager.default.fileExists(atPath: paths.directory.path))
    }

    @Test func requestRejectsTargetPortOrDigestMismatchBeforeConnecting() throws {
        let paths = TestPaths.make()
        defer { paths.cleanup() }
        let base = [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.smokeHostKey: "8.8.8.8",
            UITestSSHSessionEnvironment.smokeUserKey: "appreview",
            UITestSSHSessionEnvironment.smokeCredentialAccountKey:
                "appreview@8.8.8.8:22",
            UITestSSHSessionEnvironment.smokeNonceKey: String(repeating: "n", count: 32),
            UITestSSHSessionEnvironment.smokeKnownHostsFileKey: paths.knownHosts.path,
            UITestSSHSessionEnvironment.smokeKnownHostsSHA256Key:
                String(repeating: "a", count: 64),
            UITestSSHSessionEnvironment.smokeBrokerPortKey: "1",
            UITestSSHSessionEnvironment.smokeBrokerChallengeKey:
                String(repeating: "c", count: 32),
        ]

        #expect(throws: AppReviewSSHCredentialBrokerError.incompleteConfiguration) {
            try AppReviewSSHCredentialBrokerClient.configuredRequest(
                forHost: "other.example",
                username: "appreview",
                credentialAccount: "appreview@other.example:22",
                environment: base
            )
        }
        var invalidPort = base
        invalidPort[UITestSSHSessionEnvironment.smokeBrokerPortKey] = "0"
        #expect(throws: AppReviewSSHCredentialBrokerError.incompleteConfiguration) {
            try AppReviewSSHCredentialBrokerClient.configuredRequest(
                forHost: "8.8.8.8",
                username: "appreview",
                credentialAccount: "appreview@8.8.8.8:22",
                environment: invalidPort
            )
        }
        var invalidDigest = base
        invalidDigest[UITestSSHSessionEnvironment.smokeKnownHostsSHA256Key] = "ABC"
        #expect(throws: AppReviewSSHCredentialBrokerError.incompleteConfiguration) {
            try AppReviewSSHCredentialBrokerClient.configuredRequest(
                forHost: "8.8.8.8",
                username: "appreview",
                credentialAccount: "appreview@8.8.8.8:22",
                environment: invalidDigest
            )
        }
    }

    private enum TestSocketError: Error {
        case operationFailed
    }

    private struct TestPaths: @unchecked Sendable {
        let directory: URL
        let knownHosts: URL

        static func make() -> Self {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "k.\(randomSuffix())",
                isDirectory: true
            )
            return Self(
                directory: directory,
                knownHosts: directory.appendingPathComponent("known_hosts")
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        private static func randomSuffix() -> String {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        }
    }

    private struct Listener: Sendable {
        let descriptor: Int32
        let port: UInt16
    }

    private static func makeListeningSocket() throws -> Listener {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw TestSocketError.operationFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard Darwin.inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(descriptor)
            throw TestSocketError.operationFailed
        }
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw TestSocketError.operationFailed
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameStatus == 0, bound.sin_port != 0 else {
            Darwin.close(descriptor)
            throw TestSocketError.operationFailed
        }
        return Listener(descriptor: descriptor, port: UInt16(bigEndian: bound.sin_port))
    }

    private static func environment(
        paths: TestPaths,
        port: UInt16,
        challenge: String,
        nonce: String,
        account: String,
        knownHostsSHA256: String
    ) -> [String: String] {
        [
            UITestSSHSessionEnvironment.isUITestingKey: "1",
            UITestSSHSessionEnvironment.smokeHostKey: "8.8.8.8",
            UITestSSHSessionEnvironment.smokeUserKey: "appreview",
            UITestSSHSessionEnvironment.smokeCredentialAccountKey: account,
            UITestSSHSessionEnvironment.smokeNonceKey: nonce,
            UITestSSHSessionEnvironment.smokeKnownHostsFileKey: paths.knownHosts.path,
            UITestSSHSessionEnvironment.smokeKnownHostsSHA256Key: knownHostsSHA256,
            UITestSSHSessionEnvironment.smokeBrokerPortKey: String(port),
            UITestSSHSessionEnvironment.smokeBrokerChallengeKey: challenge,
        ]
    }

    private static func payload(
        port: UInt16,
        challenge: String,
        nonce: String,
        account: String,
        password: String,
        knownHostsPath: String,
        knownHostsSHA256: String,
        knownHostsData: Data
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "brokerHost": "127.0.0.1",
            "brokerPort": Int(port),
            "challenge": challenge,
            "nonce": nonce,
            "host": "8.8.8.8",
            "username": "appreview",
            "credentialAccount": account,
            "password": password,
            "knownHostsFilePath": knownHostsPath,
            "knownHostsSHA256": knownHostsSHA256,
            "knownHostsBase64": knownHostsData.base64EncodedString(),
        ])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if count == 0 { break }
            guard count > 0 else { throw TestSocketError.operationFailed }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    nonisolated private static func sendAll(_ data: Data, to descriptor: Int32) throws {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes {
                Darwin.send(
                    descriptor,
                    $0.baseAddress?.advanced(by: sent),
                    $0.count - sent,
                    0
                )
            }
            guard count > 0 else { throw TestSocketError.operationFailed }
            sent += count
        }
    }
}
