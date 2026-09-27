//
//  SSHCredentialAskpass.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/30.
//

import Darwin
import Foundation

nonisolated enum SSHCredentialAskpass {
    private final class BundleToken: NSObject {}

    /// A live launch removes its marker after the signed helper acknowledges
    /// its complete stdout response, or when the owning operation tears down.
    /// This grace period only targets markers abandoned by a crash or forced
    /// test exit.
    static let staleConsumptionMarkerLifetime: TimeInterval = 24 * 60 * 60
    static let maximumSecretBytes = 4_096
    static let challengeByteCount = 32
    static let defaultBrokerLifetime: TimeInterval = 60

    struct LaunchContext: Sendable {
        let environment: [String: String]
        let consumptionMarkerURL: URL
        private let broker: OneShotCredentialBroker

        fileprivate init(
            environment: [String: String],
            consumptionMarkerURL: URL,
            broker: OneShotCredentialBroker
        ) {
            self.environment = environment
            self.consumptionMarkerURL = consumptionMarkerURL
            self.broker = broker
        }

        /// The broker proves one-shot use by unlinking the private marker only
        /// after the signed helper confirms that it wrote the complete response
        /// to its stdout for OpenSSH.
        /// Call this before `cleanup()`; cleanup intentionally makes an unused
        /// marker indistinguishable from an already-consumed one.
        var credentialConsumed: Bool {
            !FileManager.default.fileExists(atPath: consumptionMarkerURL.path)
        }

        func cleanup(fileManager: FileManager = .default) {
            broker.cancel()
            try? fileManager.removeItem(at: consumptionMarkerURL)
        }
    }

    fileprivate enum HelperError: LocalizedError {
        case unavailable(URL)
        case invalidCredential
        case cannotCreateConsumptionToken(URL, Int32)
        case cannotCreateBroker(String, Int32)
        case socketPathTooLong(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let url):
                return "The bundled SSH credential helper is unavailable at \(url.path)."
            case .invalidCredential:
                return "The saved SSH password cannot be handed to the credential helper securely."
            case .cannotCreateConsumptionToken(let url, let errorNumber):
                return "JTS Terminal could not create its one-time SSH credential authorization at \(url.path) (errno \(errorNumber))."
            case .cannotCreateBroker(let operation, let errorNumber):
                return "JTS Terminal could not create its one-time SSH credential broker during \(operation) (errno \(errorNumber))."
            case .socketPathTooLong(let path):
                return "JTS Terminal could not create its one-time SSH credential broker because the private socket path is too long: \(path)"
            }
        }
    }

    static let helperRelativePath = "Contents/MacOS/JTSSHAskpass"
    static let brokerSocketEnvironmentKey = "JTS_TERMINAL_ASKPASS_SOCKET"
    static let brokerChallengeEnvironmentKey = "JTS_TERMINAL_ASKPASS_CHALLENGE"
    static var applicationBundle: Bundle { Bundle(for: BundleToken.self) }

    static func launchContext(
        account: String,
        secret: String,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        challenge: [UInt8]? = nil,
        socketDirectoryToken: String? = nil,
        brokerLifetime: TimeInterval = defaultBrokerLifetime
    ) throws -> LaunchContext {
        // Resolve the signed helper before creating any private runtime state.
        let helperPath = try helperURL(fileManager: fileManager).path
        let secretBytes = Array(secret.utf8)
        guard !account.isEmpty,
              !secretBytes.isEmpty,
              secretBytes.count <= maximumSecretBytes,
              !secretBytes.contains(0),
              !secretBytes.contains(10),
              !secretBytes.contains(13),
              brokerLifetime.isFinite,
              brokerLifetime > 0,
              brokerLifetime <= 300 else {
            throw HelperError.invalidCredential
        }

        let challengeBytes = try challenge ?? secureRandomBytes(count: challengeByteCount)
        guard challengeBytes.count == challengeByteCount else {
            throw HelperError.invalidCredential
        }
        let challengeHex = hexEncoded(challengeBytes)
        let directoryToken = try socketDirectoryToken ?? hexEncoded(secureRandomBytes(count: 8))
        guard directoryToken.count == 16,
              directoryToken.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              }) else {
            throw HelperError.invalidCredential
        }

        let markerURL = try newConsumptionMarkerURL(fileManager: fileManager)
        do {
            let broker = try OneShotCredentialBroker(
                secret: secretBytes,
                challenge: challengeBytes,
                markerURL: markerURL,
                temporaryDirectory: temporaryDirectory ?? fileManager.temporaryDirectory,
                directoryToken: directoryToken,
                lifetime: brokerLifetime
            )
            let context = LaunchContext(
                environment: [
                    "SSH_ASKPASS": helperPath,
                    "SSH_ASKPASS_REQUIRE": "force",
                    "DISPLAY": "JTSTerminal",
                    brokerSocketEnvironmentKey: broker.socketURL.path,
                    brokerChallengeEnvironmentKey: challengeHex,
                ],
                consumptionMarkerURL: markerURL,
                broker: broker
            )
            broker.start()
            return context
        } catch {
            try? fileManager.removeItem(at: markerURL)
            throw error
        }
    }

    static func helperURL(
        in bundle: Bundle? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let bundle = bundle ?? applicationBundle
        let url = bundle.bundleURL.appendingPathComponent(helperRelativePath, isDirectory: false)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: url.path) else {
            throw HelperError.unavailable(url)
        }
        return url
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        guard count > 0 else { throw HelperError.invalidCredential }
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBytes { buffer in
            arc4random_buf(buffer.baseAddress, buffer.count)
        }
        return bytes
    }

    private static func hexEncoded(_ bytes: [UInt8]) -> String {
        let alphabet: [UInt8] = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func newConsumptionMarkerURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("JTSTerminalAskpass", isDirectory: true)
        try PrivateFileSecurity.secureDirectory(at: directoryURL, fileManager: fileManager)
        removeStaleConsumptionMarkers(in: directoryURL)

        // This empty 0600 file never contains credential material. It is only
        // the app-visible success bit used by UI and release verification.
        for _ in 0..<4 {
            let markerURL = directoryURL
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("consumed")
            let descriptor = markerURL.path.withCString { path in
                Darwin.open(
                    path,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            if descriptor >= 0 {
                _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
                _ = Darwin.close(descriptor)
                return markerURL
            }

            let errorNumber = errno
            if errorNumber != EEXIST {
                throw HelperError.cannotCreateConsumptionToken(markerURL, errorNumber)
            }
        }

        let markerURL = directoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("consumed")
        throw HelperError.cannotCreateConsumptionToken(markerURL, EEXIST)
    }

    /// Removes only old, empty status markers created by this app. Every
    /// structural check is fail-closed so a symlink, hard link, foreign owner,
    /// unexpected mode, payload-bearing file, or unrelated filename is left
    /// untouched.
    static func removeStaleConsumptionMarkers(
        in directoryURL: URL,
        now: Date = Date(),
        staleAfter lifetime: TimeInterval = staleConsumptionMarkerLifetime
    ) {
        guard lifetime >= 0 else { return }

        let directoryDescriptor = directoryURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else { return }
        defer { _ = Darwin.close(directoryDescriptor) }

        guard (try? PrivateFileSecurity.verifyPrivateDirectoryDescriptor(
            directoryDescriptor,
            path: directoryURL.path
        )) != nil else {
            return
        }

        let duplicate = Darwin.openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard duplicate >= 0 else { return }
        guard let directory = Darwin.fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            return
        }
        defer { _ = Darwin.closedir(directory) }

        let cutoff = now.timeIntervalSince1970 - lifetime
        while let entry = Darwin.readdir(directory) {
            let fileName = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) {
                    String(cString: $0)
                }
            }
            guard isConsumptionMarkerFileName(fileName) else { continue }

            var fileStatus = stat()
            let statusResult = fileName.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &fileStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard statusResult == 0,
                  fileStatus.st_uid == geteuid(),
                  fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  fileStatus.st_mode & mode_t(0o777) == mode_t(0o600),
                  fileStatus.st_nlink == 1,
                  fileStatus.st_size == 0 else {
                continue
            }

            let modifiedAt = TimeInterval(fileStatus.st_mtimespec.tv_sec)
                + TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000
            guard modifiedAt < cutoff else { continue }

            fileName.withCString {
                _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
        }
    }

    private static func isConsumptionMarkerFileName(_ fileName: String) -> Bool {
        let suffix = ".consumed"
        guard fileName.hasSuffix(suffix) else { return false }
        return UUID(uuidString: String(fileName.dropLast(suffix.count))) != nil
    }
}

nonisolated private final class OneShotCredentialBroker: @unchecked Sendable {
    private static let requestMagic = Array("JTSA1REQ".utf8)
    private static let responseMagic = Array("JTSA1RES".utf8)
    private static let acknowledgementMagic = Array("JTSA1ACK".utf8)
    private static let pollIntervalMilliseconds: Int32 = 50
    private static let clientTimeoutSeconds: Int = 5

    let socketURL: URL

    private let socketDirectoryURL: URL
    private let markerURL: URL
    private let challenge: [UInt8]
    private let lifetime: TimeInterval
    private let lock = NSLock()
    private var listenDescriptor: Int32
    private var activeClientDescriptor: Int32 = -1
    private var secret: [UInt8]
    private var cancelled = false

    init(
        secret: [UInt8],
        challenge: [UInt8],
        markerURL: URL,
        temporaryDirectory: URL,
        directoryToken: String,
        lifetime: TimeInterval
    ) throws {
        self.secret = secret
        self.challenge = challenge
        self.markerURL = markerURL
        self.lifetime = lifetime
        socketDirectoryURL = temporaryDirectory
            .appendingPathComponent("ja.\(directoryToken)", isDirectory: true)
        socketURL = socketDirectoryURL.appendingPathComponent("s", isDirectory: false)
        listenDescriptor = -1

        guard socketURL.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw SSHCredentialAskpass.HelperError.socketPathTooLong(socketURL.path)
        }

        let mkdirResult = socketDirectoryURL.path.withCString {
            Darwin.mkdir($0, S_IRWXU)
        }
        guard mkdirResult == 0 else {
            throw SSHCredentialAskpass.HelperError.cannotCreateBroker("mkdir", errno)
        }

        do {
            try PrivateFileSecurity.verifyPrivateDirectory(at: socketDirectoryURL)
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw SSHCredentialAskpass.HelperError.cannotCreateBroker("socket", errno)
            }
            listenDescriptor = descriptor
            try Self.configureNoSignal(on: descriptor)
            try Self.bind(descriptor: descriptor, to: socketURL.path)
            try PrivateFileSecurity.securePrivateSocket(at: socketURL)
            guard Darwin.listen(descriptor, 1) == 0 else {
                throw SSHCredentialAskpass.HelperError.cannotCreateBroker("listen", errno)
            }
        } catch {
            cleanupSocketArtifacts()
            zeroSecret()
            throw error
        }
    }

    deinit {
        cleanupSocketArtifacts()
        zeroSecret()
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            serve()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let clientDescriptor = activeClientDescriptor
        lock.unlock()
        if clientDescriptor >= 0 {
            _ = Darwin.shutdown(clientDescriptor, SHUT_RDWR)
        }
        socketURL.path.withCString { _ = Darwin.unlink($0) }
        socketDirectoryURL.path.withCString { _ = Darwin.rmdir($0) }
    }

    private func serve() {
        defer {
            cleanupSocketArtifacts()
            zeroSecret()
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let lifetimeNanoseconds = UInt64(lifetime * 1_000_000_000)
        while !isCancelled,
              markerStillExists,
              DispatchTime.now().uptimeNanoseconds - startedAt < lifetimeNanoseconds {
            var descriptor = pollfd(
                fd: listenDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Self.pollIntervalMilliseconds
            )
            if pollResult < 0 {
                if errno == EINTR { continue }
                return
            }
            guard pollResult > 0 else { continue }
            guard descriptor.revents & Int16(POLLIN) != 0 else { return }

            let clientDescriptor = Darwin.accept(listenDescriptor, nil, nil)
            guard clientDescriptor >= 0 else {
                if errno == EINTR { continue }
                return
            }

            // Closing the listener makes the first connection authoritative.
            // Keep the socket inode in place briefly so the helper can verify
            // that it did not change between connect(2) and the handshake.
            setActiveClient(clientDescriptor)
            closeListener()
            defer {
                clearActiveClient(clientDescriptor)
                _ = Darwin.close(clientDescriptor)
            }
            authorizeAndSendSecret(to: clientDescriptor)
            return
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private var markerStillExists: Bool {
        var status = stat()
        return markerURL.path.withCString { path in
            Darwin.lstat(path, &status) == 0
                && status.st_uid == geteuid()
                && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                && status.st_mode & mode_t(0o777) == mode_t(0o600)
                && status.st_nlink == 1
                && status.st_size == 0
        }
    }

    private func authorizeAndSendSecret(to descriptor: Int32) {
        guard !isCancelled,
              markerStillExists,
              Self.configureClientTimeouts(on: descriptor),
              Self.peerIsCurrentUser(descriptor) else {
            return
        }

        let requestLength = Self.requestMagic.count + challenge.count
        var request = [UInt8](repeating: 0, count: requestLength)
        guard Self.readExactly(into: &request, from: descriptor),
              Self.peerHasNoPendingRequestBytes(on: descriptor),
              Array(request.prefix(Self.requestMagic.count)) == Self.requestMagic,
              Self.constantTimeEqual(
                  Array(request.dropFirst(Self.requestMagic.count)),
                  challenge
              ),
              !isCancelled,
              markerStillExists else {
            return
        }

        var length = UInt32(secret.count).bigEndian
        guard Self.writeAll(Self.responseMagic, to: descriptor),
              withUnsafeBytes(of: &length, { bytes in
                  Self.writeAll(bytes, to: descriptor)
              }),
              Self.writeAll(secret, to: descriptor) else {
            return
        }
        _ = Darwin.shutdown(descriptor, SHUT_WR)

        var acknowledgement = [UInt8](
            repeating: 0,
            count: Self.acknowledgementMagic.count
        )
        guard Self.readExactly(into: &acknowledgement, from: descriptor),
              Self.constantTimeEqual(
                  acknowledgement,
                  Self.acknowledgementMagic
              ) else {
            return
        }

        // The listener was closed when this authenticated helper connected,
        // so deferring the marker transition until this acknowledgement does
        // not permit a second credential request.
        _ = markerURL.path.withCString { Darwin.unlink($0) }
    }

    private func closeListener() {
        lock.lock()
        let descriptor = listenDescriptor
        listenDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    private func setActiveClient(_ descriptor: Int32) {
        lock.lock()
        activeClientDescriptor = descriptor
        let shouldInterrupt = cancelled
        lock.unlock()
        if shouldInterrupt {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    private func clearActiveClient(_ descriptor: Int32) {
        lock.lock()
        if activeClientDescriptor == descriptor {
            activeClientDescriptor = -1
        }
        lock.unlock()
    }

    private func cleanupListeningSocket() {
        closeListener()
        socketURL.path.withCString { _ = Darwin.unlink($0) }
        socketDirectoryURL.path.withCString { _ = Darwin.rmdir($0) }
    }

    private func cleanupSocketArtifacts() {
        cleanupListeningSocket()
    }

    private func zeroSecret() {
        secret.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress, bytes.count > 0 else { return }
            _ = Darwin.memset_s(baseAddress, bytes.count, 0, bytes.count)
        }
        secret.removeAll(keepingCapacity: false)
    }

    private static func bind(descriptor: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                Darwin.strlcpy(destination, source, capacity) < capacity
            }
        }
        guard copied else {
            throw SSHCredentialAskpass.HelperError.socketPathTooLong(path)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw SSHCredentialAskpass.HelperError.cannotCreateBroker("bind", errno)
        }
    }

    private static func configureNoSignal(on descriptor: Int32) throws {
        var enabled: Int32 = 1
        let result = Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard result == 0 else {
            throw SSHCredentialAskpass.HelperError.cannotCreateBroker("setsockopt", errno)
        }
    }

    private static func configureClientTimeouts(on descriptor: Int32) -> Bool {
        var timeout = timeval(tv_sec: clientTimeoutSeconds, tv_usec: 0)
        var enabled: Int32 = 1
        return Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0
            && Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0
            && Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
    }

    private static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        return Darwin.getpeereid(descriptor, &peerUID, &peerGID) == 0
            && peerUID == geteuid()
    }

    /// The helper keeps its write side open for the post-stdout acknowledgement.
    /// Reject any bytes queued before the broker starts its response so a client
    /// cannot pre-send that acknowledgement.
    private static func peerHasNoPendingRequestBytes(on descriptor: Int32) -> Bool {
        var extra: UInt8 = 0
        while true {
            let count = Darwin.recv(
                descriptor,
                &extra,
                1,
                MSG_PEEK | MSG_DONTWAIT
            )
            if count > 0 || count == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
            return errno == EAGAIN || errno == EWOULDBLOCK
        }
    }

    private static func readExactly(into buffer: inout [UInt8], from descriptor: Int32) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { writeAll($0, to: descriptor) }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.send(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset,
                0
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
