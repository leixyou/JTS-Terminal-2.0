import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionTransport

final class HostChannelTests: XCTestCase {
    func testPublicFactoryAcceptPinsBothPeersBindsLaneAndRequiresGrantBeforeBytes() async throws {
        let pair = try await channels()
        let grant = UUID()
        async let accepted = CompanionHostLaneAuthorization.accept(channel: pair.host, approvedGrantIDs: [grant])
        try await CompanionLaneAuthorization.authorize(channel: pair.client, grantID: grant)
        let granted = try await accepted
        XCTAssertEqual(granted, grant)
        let payload = Data("RFB 003.008\n".utf8) + Data(repeating: 0xa5, count: 32_000)
        async let received = readExactly(pair.host, count: payload.count)
        try await pair.client.send(payload)
        let bytes = try await received
        XCTAssertEqual(bytes, payload)
        let leaked = await pair.pipe.containsPlaintext(payload)
        XCTAssertFalse(leaked)
        try await pair.host.send(Data([7, 8, 9]))
        let response = try await pair.client.receive(maximumBytes: 3)
        XCTAssertEqual(response, Data([7, 8, 9]))
        await pair.host.close(); await pair.client.close()
    }

    func testWrongGrantClosesAuthenticatedChannel() async throws {
        let pair = try await channels()
        let host = Task { try await CompanionHostLaneAuthorization.accept(channel: pair.host, approvedGrantIDs: [UUID()]) }
        do { try await CompanionLaneAuthorization.authorize(channel: pair.client, grantID: UUID()); XCTFail("Wrong grant accepted") }
        catch { }
        do { _ = try await host.value; XCTFail("Host authorized wrong grant") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unauthorizedDevice) }
        do { try await pair.client.send(Data([1])); XCTFail("Application data sent after rejection") }
        catch { }
    }

    func testServerRoleAndLaneMismatchRejectedBeforeTLS() async throws {
        let controller = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let host = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let peer = try PairedCompanionDevice(publicKeySPKI: controller.publicKeySPKI, allowedLanes: [.rdp])
        let binding = try CompanionLaneBinding(sessionID: UUID().uuidString, lane: .rdp,
            controllerDeviceID: controller.deviceID, companionDeviceID: host.deviceID)
        let carrier = RecordingCarrier()
        do { _ = try await PinnedTLSChannelFactory().accept(carrier: carrier, identity: controller, peer: peer, binding: binding); XCTFail("Wrong server role") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unauthorizedDevice) }
        let closed = await carrier.closed
        XCTAssertTrue(closed)
        let disabled = try PairedCompanionDevice(publicKeySPKI: controller.publicKeySPKI, allowedLanes: [.file])
        do { _ = try await PinnedTLSChannelFactory().accept(carrier: carrier, identity: host, peer: disabled, binding: binding); XCTFail("Unapproved lane") }
        catch { XCTAssertEqual(error as? CompanionTransportError, .unauthorizedDevice) }
    }

    func testGrantRejectsWrongOperationCaseExtraParametersAndOversizedFrame() async throws {
        let pair = try await channels()
        let grant = UUID()
        await pair.host.close(); await pair.client.close()
        for mutation in ["case", "lane", "parameters", "extra", "length"] {
            let pair = try await channels()
            var object: [String: Any] = ["version": 1, "id": UUID().uuidString.lowercased(), "operation": "rdp.open",
                "grantId": grant.uuidString.lowercased(), "parameters": [:]]
            if mutation == "case" { object["operation"] = "RDP.OPEN" }
            if mutation == "lane" { object["operation"] = "file.open" }
            if mutation == "parameters" { object["parameters"] = ["host": "untrusted.example"] }
            if mutation == "extra" { object["ignore"] = true }
            let body = try JSONSerialization.data(withJSONObject: object)
            var length = UInt32(mutation == "length" ? 16_385 : body.count).bigEndian
            var bytes = withUnsafeBytes(of: &length) { Data($0) }; if mutation != "length" { bytes.append(body) }
            try await pair.client.send(bytes)
            do { _ = try await CompanionHostLaneAuthorization.accept(channel: pair.host, approvedGrantIDs: [grant]); XCTFail(mutation) }
            catch { }
            await pair.client.close()
        }
    }

    private func channels() async throws -> (client: any CompanionSecureChannel, host: any CompanionSecureChannel, pipe: TestByteInbox) {
        let controller = RelayIdentity(privateKey: P256.Signing.PrivateKey()), host = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let a = TestByteInbox(), b = TestByteInbox()
        let clientCarrier = TestDuplexCarrier(inbound: a, outbound: b), hostCarrier = TestDuplexCarrier(inbound: b, outbound: a)
        let hostPeer = try PairedCompanionDevice(publicKeySPKI: controller.publicKeySPKI, allowedLanes: [.rdp])
        let controllerPeer = try PairedCompanionDevice(publicKeySPKI: host.publicKeySPKI, allowedLanes: [.rdp])
        let binding = try CompanionLaneBinding(sessionID: UUID().uuidString.lowercased(), lane: .rdp,
            controllerDeviceID: controller.deviceID, companionDeviceID: host.deviceID)
        async let accepted = PinnedTLSChannelFactory().accept(carrier: hostCarrier, identity: host, peer: hostPeer, binding: binding)
        let client = try await PinnedTLSChannelFactory().authenticate(carrier: clientCarrier, identity: controller, peer: controllerPeer, binding: binding)
        return (client, try await accepted, b)
    }

    private func readExactly(_ channel: any CompanionSecureChannel, count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count { bytes.append(try await channel.receive(maximumBytes: min(16_384, count - bytes.count))) }
        return bytes
    }
}

private struct TestDuplexCarrier: RelayByteCarrier {
    let inbound, outbound: TestByteInbox
    func read(maximumBytes: Int) async throws -> Data { try await inbound.read(maximumBytes) }
    func write(_ bytes: Data) async throws { try await outbound.write(bytes) }
    func close() async { await inbound.close(); await outbound.close() }
}

private actor TestByteInbox {
    var pending = Data(), transcript = Data()
    var waiter: (Int, CheckedContinuation<Data, Error>)?
    var closed = false
    func read(_ maximum: Int) async throws -> Data {
        guard !closed else { throw CompanionTransportError.connectionClosed }
        if !pending.isEmpty { return take(maximum) }
        return try await withCheckedThrowingContinuation { waiter = (maximum, $0) }
    }
    func write(_ bytes: Data) throws {
        guard !closed, pending.count + bytes.count <= 1_048_576 else { throw CompanionTransportError.connectionClosed }
        pending.append(bytes); transcript.append(bytes)
        if let (maximum, continuation) = waiter { waiter = nil; continuation.resume(returning: take(maximum)) }
    }
    func containsPlaintext(_ bytes: Data) -> Bool { transcript.range(of: bytes) != nil }
    func close() {
        closed = true; pending.removeAll()
        if let (_, continuation) = waiter { waiter = nil; continuation.resume(throwing: CompanionTransportError.connectionClosed) }
    }
    private func take(_ maximum: Int) -> Data {
        let count = min(maximum, pending.count), result = Data(pending.prefix(count)); pending.removeFirst(count); return result
    }
}
