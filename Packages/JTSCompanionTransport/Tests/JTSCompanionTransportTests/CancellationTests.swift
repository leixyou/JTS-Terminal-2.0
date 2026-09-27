import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionTransport

private actor BlockingCarrier: RelayByteCarrier {
    private var readContinuation: CheckedContinuation<Data, Error>?
    private var readObservers: [CheckedContinuation<Void, Never>] = []
    private var didRead = false
    private(set) var closed = false

    func read(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw CompanionTransportError.connectionClosed }
        didRead = true
        readObservers.forEach { $0.resume() }
        readObservers.removeAll()
        return try await withCheckedThrowingContinuation { readContinuation = $0 }
    }
    func write(_ bytes: Data) throws {
        if closed { throw CompanionTransportError.connectionClosed }
    }
    func close() {
        closed = true
        readContinuation?.resume(throwing: CompanionTransportError.connectionClosed)
        readContinuation = nil
    }
    func waitUntilReading() async {
        if didRead { return }
        await withCheckedContinuation { readObservers.append($0) }
    }
}

final class CancellationTests: XCTestCase {
    func testCancellationClosesCarrierThatDoesNotObserveTaskCancellation() async throws {
        let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let peer = try PairedCompanionDevice(publicKeySPKI: P256.Signing.PrivateKey().publicKey.derRepresentation,
                                             allowedLanes: [.control])
        let binding = try CompanionLaneBinding(sessionID: UUID().uuidString.lowercased(), lane: .control,
            controllerDeviceID: identity.deviceID, companionDeviceID: peer.deviceID)
        let carrier = BlockingCarrier()
        let task = Task {
            try await PinnedTLSChannelFactory().authenticate(carrier: carrier, identity: identity, peer: peer, binding: binding)
        }
        await carrier.waitUntilReading()
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled handshake returned a channel") }
        catch { /* The carrier must close, whether its error or CancellationError wins. */ }
        let closed = await carrier.closed
        XCTAssertTrue(closed)
    }
}
