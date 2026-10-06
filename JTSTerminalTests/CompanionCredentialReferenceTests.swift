#if ENABLE_RDP_2
import Foundation
import Testing
@testable import JTSTerminal

@Suite struct CompanionCredentialReferenceTests {
    @Test func credentialFillNeverAcceptsRawSecretsOrSelectorBypass() throws {
        let target = UUID(), session = UUID()
        let safe: [String: Any] = ["targetId": target.uuidString, "sessionId": session.uuidString,
            "action": "fillCredential", "expectedFrameId": UUID().uuidString, "expectedStateRevision": 4,
            "credentialRef": RDPPasswordStore.account(targetID: target), "purpose": "login"]
        try WindowsMCPCredentialFillRequest.validate(safe)
        for key in ["password", "secret", "text", "secretBase64", "selector"] {
            var bad = safe; bad[key] = "should-never-be-forwarded"
            #expect(throws: WindowsMCPToolError.self) { try WindowsMCPCredentialFillRequest.validate(bad) }
        }
        var fractional = safe; fractional["expectedStateRevision"] = 4.5
        #expect(throws: WindowsMCPToolError.self) { try WindowsMCPCredentialFillRequest.validate(fractional) }
        var wrongPurpose = safe; wrongPurpose["purpose"] = "execute"
        #expect(throws: WindowsMCPToolError.self) { try WindowsMCPCredentialFillRequest.validate(wrongPurpose) }
    }
}
#endif
