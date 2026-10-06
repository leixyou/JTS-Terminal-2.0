import CryptoKit
import Foundation
import XCTest
import JTSCompanionIPC
@testable import JTSCompanionTransport

final class DesktopGrantVectorTests: XCTestCase {
    func testImmutableCrossLanguageGrantAndAcknowledgementVectors() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("Protocols/JTSRelay/3.0.0-desktop.3/desktop-v1/fixtures/desktop-grant.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let request = try XCTUnwrap(fixture["request"] as? [String: Any])
        let proof = try JSONDecoder().decode(DesktopGrantProof.self, from: JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(proof.canonical.base64EncodedString(), fixture["requestTranscriptBase64"] as? String)
        let hash = SHA256.hash(data: proof.canonical).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, fixture["requestHash"] as? String)
        let controller = try P256.Signing.PublicKey(derRepresentation: XCTUnwrap(Data(base64Encoded: proof.controllerSpkiBase64)))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Data(base64Encoded: proof.signatureBase64)))
        XCTAssertTrue(controller.isValidSignature(signature, for: proof.canonical))
        XCTAssertFalse(controller.isValidSignature(signature, for: proof.canonical + Data([10])))
        let ackData = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["acknowledgement"]))
        let ack = try CompanionIPCCodec.decodePayload(ackData, as: CompanionDesktopAcknowledgement.self)
        let transcript = Data(["jts-desktop-grant-ack-v1", "1", ack.desktopGrantId, ack.pairingId, ack.targetBinding,
            ack.companionDeviceId, ack.controllerDeviceId, ack.proofSha256, String(ack.committedAtUnixSeconds)].joined(separator: "\n").utf8)
        XCTAssertEqual(transcript.base64EncodedString(), fixture["ackTranscriptBase64"] as? String)
        let peerSPKI = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fixture["companionSpkiBase64"] as? String)))
        let companion = try P256.Signing.PublicKey(derRepresentation: peerSPKI)
        XCTAssertEqual(RelayIdentity.deviceID(publicKeySPKI: peerSPKI), ack.companionDeviceId)
        let ackSignature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Data(base64Encoded: ack.signatureBase64)))
        XCTAssertTrue(companion.isValidSignature(ackSignature, for: transcript))
    }
}
