#if ENABLE_RDP_2
import Foundation
import Darwin
import Testing
@testable import JTSTerminal

@Suite struct RDPRelaySocketTests {
    @Test func fullDuplexStreamsPreserveChunkBytes() async throws {
        let (first, handle) = try RDPRelaySocketEndpoint.pair()
        let second = RDPRelaySocketEndpoint(descriptor: dup(handle.fileDescriptor))
        try handle.close()
        defer { first.close(); second.close() }
        let a = Data((0..<65_536).map { UInt8($0 % 251) })
        let b = Data((0..<65_536).map { UInt8($0 % 239) })
        async let leftWrite: Void = first.write(a)
        async let rightWrite: Void = second.write(b)
        async let leftRead = drain(first, count: b.count)
        async let rightRead = drain(second, count: a.count)
        let (left, right, _, _) = try await (leftRead, rightRead, leftWrite, rightWrite)
        #expect(left == b && right == a)
    }

    @Test func cancellationWakesAnIdleSocketAndPeerSeesEOF() async throws {
        let (first, handle) = try RDPRelaySocketEndpoint.pair()
        let second = RDPRelaySocketEndpoint(descriptor: dup(handle.fileDescriptor))
        try handle.close()
        defer { first.close(); second.close() }
        let pending = Task { try await first.read() }
        try await Task.sleep(for: .milliseconds(40))
        pending.cancel()
        do { #expect(try await pending.value.isEmpty) } catch { /* cancellation is also valid */ }
        #expect(try await second.read().isEmpty)
    }

    @Test(.enabled(if: Bundle.main.bundleURL.pathExtension == "app",
                   "Requires the signed application test host."))
    @MainActor func freeRDPEmitsItsHandshakeThroughThePrivateXPCSocket() async throws {
        let (endpoint, handle) = try RDPRelaySocketEndpoint.pair()
        let xpc = FreeRDPXPCSession()
        defer { endpoint.close(); try? handle.close(); xpc.invalidateImmediately() }
        try await xpc.connect(configuration: [
            "host": "relay-transport-test.invalid", "port": 3389,
            "username": "relay-test", "password": "disposable-protocol-fixture",
            "domain": "", "sessionId": UUID().uuidString.lowercased(),
            "connectionAttemptId": UUID().uuidString.lowercased(),
            "width": 640, "height": 480, "clipboardEnabled": false
        ], relaySocket: handle)
        try handle.close()
        let hello = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await endpoint.read() }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                endpoint.close()
                throw RDPRelaySocketError.closed
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        #expect(hello.count >= 11)
        #expect(hello.prefix(2) == Data([3, 0])) // Real TPKT/X.224 connection request.
        await xpc.disconnect()
    }

    private nonisolated func drain(_ endpoint: RDPRelaySocketEndpoint, count: Int) async throws -> Data {
        var output = Data()
        while output.count < count {
            let next = try await endpoint.read(maximumBytes: count - output.count)
            guard !next.isEmpty else { throw RDPRelaySocketError.closed }
            output.append(next)
        }
        return output
    }
}
#endif
