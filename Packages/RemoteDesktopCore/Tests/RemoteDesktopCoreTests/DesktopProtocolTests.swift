import XCTest
@testable import RemoteDesktopCore

final class DesktopProtocolTests: XCTestCase {
    private var secret: String { Data(repeating: 7, count: 32).desktopBase64URL }

    func testPacketFragmentationAndConcatenation() throws {
        let original: [RemoteDesktopMessage] = [.ping(12), .input(.releaseAll), .goodbye("closed")]
        var bytes = Data()
        for message in original { bytes.append(try DesktopPacketCodec.encode(message)) }
        var decoder = DesktopPacketDecoder()
        var received: [RemoteDesktopMessage] = []
        for byte in bytes { received += try decoder.append(Data([byte])) }
        try decoder.finish()
        XCTAssertEqual(received, original)
    }

    func testOversizedAndTruncatedPacketsAreRejected() throws {
        XCTAssertThrowsError(try DesktopPacketCodec.payloadLength(header: Data([0xff, 0xff, 0xff, 0xff])))
        XCTAssertThrowsError(try DesktopPacketCodec.payloadLength(header: Data([0, 0, 0, 0])))
        var decoder = DesktopPacketDecoder()
        _ = try decoder.append(Data([0, 0, 0, 9, 123]))
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertThrowsError(try DesktopPacketCodec.decodePayload(Data("{}".utf8)))
    }

    func testRemoteInputsCannotEscapeBounds() throws {
        let valid: [DesktopInput] = [
            .pointer(x: 0, y: 1), .pointer(x: 0.5, y: 0.5, button: .left, isDown: true),
            .scroll(x: 0.5, y: 0.5, deltaX: -12, deltaY: 2),
            .key(keyCode: 127, isDown: true, modifiers: 0x00100000), .releaseAll
        ]
        for input in valid { try input.validate() }
        let invalid: [DesktopInput] = [
            .pointer(x: -0.01, y: 0), .pointer(x: 1.01, y: 0), .pointer(x: .nan, y: 0),
            .pointer(x: 0, y: 0, button: .left), .pointer(x: 0, y: 0, isDown: true),
            .scroll(x: 0, y: 0, deltaX: .infinity, deltaY: 0),
            .scroll(x: 0, y: 0, deltaX: 10_001, deltaY: 0),
            .key(keyCode: 128, isDown: true, modifiers: 0),
            .key(keyCode: 1, isDown: true, modifiers: .max)
        ]
        for input in invalid { XCTAssertThrowsError(try input.validate()) }
    }

    func testFrameAndProtocolValidation() throws {
        try DesktopFrame(width: 1_920, height: 1_080, jpeg: Data([255, 216, 255, 217])).validate()
        XCTAssertThrowsError(try DesktopFrame(width: 0, height: 100, jpeg: Data([255, 216, 255, 217])).validate())
        XCTAssertThrowsError(try DesktopFrame(width: 100, height: 100, jpeg: Data([1, 2, 3, 4])).validate())
        var oversized = Data(repeating: 0, count: DesktopProtocol.maximumJPEGBytes + 1)
        oversized.replaceSubrange(0..<2, with: [255, 216])
        oversized.replaceSubrange((oversized.count - 2)..<oversized.count, with: [255, 217])
        XCTAssertThrowsError(try DesktopFrame(width: 100, height: 100, jpeg: oversized).validate())
        XCTAssertThrowsError(try RemoteDesktopMessage.hello(.init(protocolVersion: 99, hostName: "Mac")).validate())
        XCTAssertThrowsError(try RemoteDesktopMessage.error("credential\nleak").validate())
    }

    func testInvitationRoundTripAndStrictValidation() throws {
        let invite = DesktopPairingInvitation(serverID: UUID(), host: "mac-mini.local", port: 49_321,
                                             psk: Data(repeating: 9, count: 32), invitationToken: secret,
                                             expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        let decoded = try DesktopPairingInvitation(code: invite.encodedCode())
        XCTAssertTrue(decoded == invite)
        XCTAssertThrowsError(try decoded.validate(now: Date(timeIntervalSince1970: 2_000_000_001)))
        XCTAssertThrowsError(try DesktopPairingInvitation(code: "jtsmac://pair/../unexpected"))
        var bad = invite
        bad.host = "host;open /tmp"
        XCTAssertThrowsError(try bad.encodedCode())
        bad = invite
        bad.psk = Data(repeating: 0, count: 31)
        XCTAssertThrowsError(try bad.encodedCode())
        bad = invite
        bad.version = DesktopProtocol.version + 1
        XCTAssertThrowsError(try bad.encodedCode())
    }

    func testPairingIsLocallyApprovedOneTimeAndCanBeRevoked() throws {
        let clientID = UUID()
        let now = Date(timeIntervalSince1970: 100)
        let request = DesktopAuthentication(clientID: clientID, clientName: "MacBook", invitationToken: secret)
        var authority = DesktopPairingAuthority(invitationToken: secret, expiresAt: now.addingTimeInterval(60))
        XCTAssertEqual(authority.evaluate(request, now: now), .approvalRequired)
        let credential = Data(repeating: 11, count: 32).desktopBase64URL
        try authority.approve(request, token: credential, now: now)
        XCTAssertEqual(authority.evaluate(request, now: now), .rejected)
        XCTAssertThrowsError(try authority.approve(request, token: credential, now: now))
        let reconnect = DesktopAuthentication(clientID: clientID, clientName: "MacBook", token: credential)
        XCTAssertEqual(authority.evaluate(reconnect, now: now), .authorized)
        let impostor = DesktopAuthentication(clientID: UUID(), clientName: "Other", token: credential)
        XCTAssertEqual(authority.evaluate(impostor, now: now), .rejected)
        authority.revoke(clientID: clientID)
        XCTAssertEqual(authority.evaluate(reconnect, now: now), .rejected)
    }

    func testExpiredInvitationAndAmbiguousAuthenticationAreRejected() throws {
        let id = UUID()
        let request = DesktopAuthentication(clientID: id, clientName: "Mac", invitationToken: secret)
        let authority = DesktopPairingAuthority(invitationToken: secret, expiresAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(authority.evaluate(request, now: Date(timeIntervalSince1970: 100)), .rejected)
        XCTAssertThrowsError(try DesktopAuthentication(clientID: id, clientName: "Mac").validate())
        XCTAssertThrowsError(try DesktopAuthentication(clientID: id, clientName: "Mac", invitationToken: secret, token: secret).validate())
        XCTAssertThrowsError(try DesktopAuthentication(clientID: id, clientName: "Mac", token: "short").validate())
        XCTAssertThrowsError(try DesktopSecret.validate(String(repeating: "=", count: 43)))
    }

    func testSessionEndPreservesConsentAndOutageSemanticsOverTheWire() throws {
        let permanent: Set<DesktopSessionEndCode> = [.hostStopped, .revoked, .rejected, .invalidCredentials, .protocolViolation]
        for code in DesktopSessionEndCode.allCases {
            let original = RemoteDesktopMessage.sessionEnded(.init(code: code, message: "Session ended"))
            var decoder = DesktopPacketDecoder()
            XCTAssertEqual(try decoder.append(DesktopPacketCodec.encode(original)), [original])
            XCTAssertEqual(code.allowsReconnect, !permanent.contains(code))
        }
        XCTAssertThrowsError(try RemoteDesktopMessage.sessionEnded(.init(code: .hostStopped, message: "")).validate())
        XCTAssertThrowsError(try RemoteDesktopMessage.sessionEnded(.init(code: .shutdown, message: String(repeating: "x", count: 2_049))).validate())
        XCTAssertThrowsError(try RemoteDesktopMessage.hello(.init(protocolVersion: 1, hostName: "Old host")).validate())
    }
}
