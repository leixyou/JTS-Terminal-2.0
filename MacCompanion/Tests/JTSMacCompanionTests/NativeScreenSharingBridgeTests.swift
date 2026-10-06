import CryptoKit
import Foundation
import JTSCompanionTransport
import Testing
@testable import JTSMacCompanion

private actor TestNativeChannel: CompanionSecureChannel {
    nonisolated let binding: CompanionLaneBinding
    var incoming = [Data("controller-rfb-bytes".utf8)]
    var sent: [Data] = []
    var waiter: CheckedContinuation<Data, Error>?
    var closed = false
    init(lane: RelayLane = .rdp) throws {
        binding = try CompanionLaneBinding(sessionID: UUID().uuidString, lane: lane,
            controllerDeviceID: String(repeating: "a", count: 64), companionDeviceID: String(repeating: "b", count: 64))
    }
    func send(_ plaintext: Data) { sent.append(plaintext) }
    func receive(maximumBytes: Int) async throws -> Data {
        guard !closed else { return Data() }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() { closed = true; waiter?.resume(returning: Data()); waiter = nil }
}

private actor TestNativeStream: NativeSharingByteStream {
    var incoming = [Data("RFB 003.889\n".utf8)]
    var written: [Data] = []
    var waiter: CheckedContinuation<Data, Error>?
    var closed = false
    func read(maximumBytes: Int) async throws -> Data {
        guard !closed else { return Data() }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func write(_ bytes: Data) { written.append(bytes) }
    func close() { closed = true; waiter?.resume(returning: Data()); waiter = nil }
}

struct NativeScreenSharingBridgeTests {
    @Test func forwardsBothDirectionsAndClosingWakesPendingReads() async throws {
        let channel = try TestNativeChannel()
        let stream = TestNativeStream()
        let bridge = try NativeScreenSharingBridge(channel: channel, makeStream: { stream })
        let running = Task { try await bridge.run() }
        for _ in 0..<100 {
            if await channel.sent.count == 1, await stream.written.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await channel.sent == [Data("RFB 003.889\n".utf8)])
        #expect(await stream.written == [Data("controller-rfb-bytes".utf8)])
        await bridge.close()
        try await running.value
        #expect(await channel.closed)
        #expect(await stream.closed)
    }

    @Test func nonRdpLaneIsRejectedBeforeCreatingLocalConnection() async throws {
        let channel = try TestNativeChannel(lane: .control)
        #expect(throws: (any Error).self) {
            try NativeScreenSharingBridge(channel: channel)
        }
        #expect(NativeSharingLoopbackStream.host == "127.0.0.1")
        #expect(NativeSharingLoopbackStream.port == 5900)
    }

    @Test func localServiceFailureClosesTheAuthenticatedChannel() async throws {
        let channel = try TestNativeChannel()
        let bridge = try NativeScreenSharingBridge(channel: channel, makeStream: { throw NativeSharingError.unavailable })
        await #expect(throws: (any Error).self) { try await bridge.run() }
        #expect(await channel.closed)
        #expect(await channel.sent.isEmpty)
    }
}
