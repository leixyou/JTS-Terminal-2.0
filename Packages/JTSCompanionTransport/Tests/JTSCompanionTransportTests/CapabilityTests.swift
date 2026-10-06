import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionTransport

final class CapabilityTests: XCTestCase {
    func testDesktopUsesExtensionEndpointAndLegacyLaneUsesFrozenInfo() async throws {
        for lane in [RelayLane.desktop, .rdp] {
            let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
            let peer = try PairedCompanionDevice(publicKeySPKI: P256.Signing.PrivateKey().publicKey.derRepresentation, allowedLanes: [lane])
            let http = CapabilitiesTransport(identity: identity)
            let relay = RelayHTTPClient(endpoint: try RelayEndpoint(URL(string: "https://relay.example")!), identity: identity, transport: http)
            let coordinator = CompanionDeviceCoordinator(identity: identity, relay: relay,
                carrierFactory: StubCarrierFactory(carrier: RecordingCarrier()), secureFactory: TestAuthenticatedFactory())
            await coordinator.registerExplicitPairing(peer)
            try await coordinator.connect(deviceID: peer.deviceID, lane: lane)
            let paths = await http.paths
            XCTAssertEqual(paths.first, lane == .desktop ? "/v1/capabilities" : "/v1/info")
            XCTAssertFalse(paths.contains(lane == .desktop ? "/v1/info" : "/v1/capabilities"))
            await coordinator.revoke(deviceID: peer.deviceID)
        }
    }

    func testMalformedCapabilityDoesNotRequestSession() async throws {
        let original = try JSONSerialization.jsonObject(with: CapabilitiesTransport.valid) as! [String: Any]
        let mutations: [String: Any] = ["protocolVersion": 2, "extensions": ["desktop-v1", "desktop-v1"],
            "lanes": ["control", "file", "rdp"], "desktopMaximumBufferedBytes": 65537, "desktopBytesPerSecond": 0]
        for (field, value) in mutations {
            let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
            let peer = try PairedCompanionDevice(publicKeySPKI: P256.Signing.PrivateKey().publicKey.derRepresentation, allowedLanes: [.desktop])
            var object = original; object[field] = value
            let http = CapabilitiesTransport(identity: identity, capabilities: try JSONSerialization.data(withJSONObject: object))
            let relay = RelayHTTPClient(endpoint: try RelayEndpoint(URL(string: "https://relay.example")!), identity: identity, transport: http)
            let coordinator = CompanionDeviceCoordinator(identity: identity, relay: relay, secureFactory: TestAuthenticatedFactory())
            await coordinator.registerExplicitPairing(peer)
            do { try await coordinator.connect(deviceID: peer.deviceID, lane: .desktop); XCTFail(field) }
            catch { }
            let paths = await http.paths
            XCTAssertEqual(paths, ["/v1/capabilities"])
        }
    }
}

private actor CapabilitiesTransport: RelayHTTPTransport {
    static let valid = Data("{\"protocolVersion\":1,\"extensions\":[\"desktop-v1\"],\"lanes\":[\"control\",\"file\",\"rdp\",\"desktop\"],\"desktopMaximumBufferedBytes\":16384,\"desktopBytesPerSecond\":1048576}".utf8)
    let base: ProtocolHTTPStub
    let capabilities: Data
    var paths: [String] = []
    init(identity: RelayIdentity, capabilities: Data = valid) { base = ProtocolHTTPStub(identity: identity); self.capabilities = capabilities }
    func perform(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayHTTPResponse {
        paths.append(request.url!.path)
        if request.url!.path == "/v1/capabilities" { return RelayHTTPResponse(status: 200, body: capabilities) }
        return try await base.perform(request, maximumResponseBytes: maximumResponseBytes)
    }
}
