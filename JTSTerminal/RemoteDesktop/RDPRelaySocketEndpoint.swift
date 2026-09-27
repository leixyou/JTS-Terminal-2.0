#if ENABLE_RDP_2
import Foundation
import Darwin

nonisolated enum RDPRelaySocketError: Error { case closed, busy, invalidSize, system(Int32) }

/// Blocking socket calls live on two dedicated queues, never the main actor or
/// Swift's cooperative executor. Shutdown wakes them before the fd is closed,
/// preventing a cancelled operation from using a recycled descriptor.
nonisolated final class RDPRelaySocketEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let input = DispatchQueue(label: "jts.rdp.relay.read", qos: .userInitiated)
    private let output = DispatchQueue(label: "jts.rdp.relay.write", qos: .userInitiated)
    private var descriptor: Int32
    private var closed = false
    private var reading = false
    private var writing = false

    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }

    func read(maximumBytes: Int = 65_536) async throws -> Data {
        guard (1...65_536).contains(maximumBytes) else { throw RDPRelaySocketError.invalidSize }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                input.async {
                    do {
                        let fd = try self.begin(write: false)
                        defer { self.end(write: false) }
                        var bytes = [UInt8](repeating: 0, count: maximumBytes)
                        var count: Int
                        repeat { count = recv(fd, &bytes, bytes.count, 0) } while count < 0 && errno == EINTR
                        guard count >= 0 else { throw RDPRelaySocketError.system(errno) }
                        continuation.resume(returning: Data(bytes.prefix(count)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.close() }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw RDPRelaySocketError.invalidSize }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                output.async {
                    do {
                        let fd = try self.begin(write: true)
                        defer { self.end(write: true) }
                        try data.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < bytes.count {
                                let sent = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                                if sent < 0 && errno == EINTR { continue }
                                guard sent > 0 else { throw RDPRelaySocketError.system(errno) }
                                offset += sent
                            }
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.close() }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = shutdown(descriptor, SHUT_RDWR)
        closeIfDrained()
    }

    private func begin(write: Bool) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw RDPRelaySocketError.closed }
        guard write ? !writing : !reading else { throw RDPRelaySocketError.busy }
        if write { writing = true } else { reading = true }
        return descriptor
    }

    private func end(write: Bool) {
        lock.lock(); defer { lock.unlock() }
        if write { writing = false } else { reading = false }
        closeIfDrained()
    }

    private func closeIfDrained() {
        if closed && !reading && !writing && descriptor >= 0 {
            Darwin.close(descriptor); descriptor = -1
        }
    }

    static func pair() throws -> (RDPRelaySocketEndpoint, FileHandle) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw RDPRelaySocketError.system(errno)
        }
        for fd in descriptors {
            var enabled: Int32 = 1
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                let error = errno
                descriptors.forEach { Darwin.close($0) }
                throw RDPRelaySocketError.system(error)
            }
        }
        return (RDPRelaySocketEndpoint(descriptor: descriptors[0]),
                FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
    }
}
#endif
