#if ENABLE_RDP_2
import CryptoKit
import Foundation
import Testing
@testable import JTSTerminal

struct RDPCompanionDelegatedBootstrapTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func planUsesInstalledSetupFixedArgumentsAndVerifiedPublicRequest() throws {
        let exported = try makeExport()
        let temporaryID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let plan = try RDPCompanionDelegatedBootstrap.makePlan(exported: exported, now: date, temporaryID: temporaryID)
        #expect(plan.grantID == exported.grant.grantID)
        #expect(plan.temporaryFileName == "JTS-Companion-Delegation-01234567-89ab-cdef-0123-456789abcdef.json")
        #expect(plan.powerShellLaunchCommand == "powershell.exe -NoLogo -NoProfile")
        #expect(plan.powerShellLaunchCommand.utf8.count <= 259)
        #expect(plan.powerShellScript.utf8.count <= RDPCompanionDelegatedBootstrap.maximumScriptBytes)
        #expect(plan.powerShellScript.unicodeScalars.allSatisfy { (32...126).contains($0.value) })
        #expect(plan.requestSHA256 == SHA256.hash(data: exported.requestJSON).map { String(format: "%02x", $0) }.joined())
        #expect(plan.powerShellScript.contains(RDPCompanionDelegatedBootstrap.installedSetupRelativePath))
        #expect(plan.powerShellScript.contains("[Environment]::GetFolderPath('LocalApplicationData')"))
        #expect(plan.powerShellScript.contains("[IO.Path]::GetTempPath()"))
        #expect(plan.powerShellScript.contains("[IO.FileMode]::CreateNew"))
        #expect(plan.powerShellScript.contains("[Convert]::FromBase64String('\(exported.requestBase64)')"))
        #expect(plan.powerShellScript.contains("--install --quiet --delegated-enrollment \""))
        #expect(plan.powerShellScript.contains("--delegated-enrollment-sha256 \(plan.requestSHA256)"))
        #expect(plan.powerShellScript.contains("WaitForExit(120000)"))
        #expect(!plan.powerShellScript.contains("-Verb"))
        #expect(!plan.powerShellScript.contains("Set-ExecutionPolicy"))
        #expect(!plan.powerShellScript.contains("Kill()"))
        #expect(!plan.powerShellScript.contains("http"))
        let hashCheck = try #require(plan.powerShellScript.range(of: "Get-FileHash"))
        let launch = try #require(plan.powerShellScript.range(of: "Start-Process"))
        #expect(hashCheck.lowerBound < launch.lowerBound)
    }

    @Test func deferredSetupKeepsRequestForChildAndDoesNotClaimReady() throws {
        let plan = try RDPCompanionDelegatedBootstrap.makePlan(exported: makeExport(), now: date)
        #expect(plan.powerShellScript.contains("$q=Start-Process -FilePath $e -ArgumentList $a -PassThru;$keep=$true;"))
        #expect(plan.powerShellScript.contains("if($q.ExitCode -eq 4){Write-Output 'Enrollment started; waiting for Companion connection'}"))
        #expect(plan.powerShellScript.contains("else{$keep=$false;if($q.ExitCode -ne 0){throw"))
        #expect(plan.powerShellScript.contains("finally{if($created -and !$keep){Remove-Item -LiteralPath $p"))
        #expect(!plan.powerShellScript.contains("Pairing ready"))
    }

    @Test func profileShellPunctuationStaysInsideBase64Data() throws {
        let attack = "rdp://reviewer@192.0.2.198';Start-Process calc;#$(whoami)"
        let exported = try makeExport(binding: attack)
        let plan = try RDPCompanionDelegatedBootstrap.makePlan(exported: exported, now: date)
        #expect(!plan.powerShellScript.contains(attack))
        #expect(!plan.powerShellScript.contains("Start-Process calc"))
        #expect(!plan.powerShellScript.contains("$(whoami)"))
        #expect(plan.powerShellScript.contains(exported.requestBase64))
        let decoded = try #require(Data(base64Encoded: exported.requestBase64))
        let request = try #require(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        #expect(request["targetBinding"] as? String == attack)
    }

    @Test func requestCannotSelectACommandPathOrDifferentDevice() throws {
        let exported = try makeExport()
        let original = try #require(JSONSerialization.jsonObject(with: exported.requestJSON) as? [String: Any])
        let mutations: [(String, Any)] = [
            ("command", "Start-Process calc"), ("setupPath", "other.exe"),
            ("grantId", UUID().uuidString), ("targetId", UUID().uuidString),
            ("targetBinding", "other"), ("schemaVersion", true),
            ("authorizationReference", "owner-authorized-device-delegation"),
            ("authorizationSource", "interactive"),
            ("macIdentity", ["deviceId": UUID().uuidString, "publicKeyBase64": "AA==", "fingerprintSha256": exported.grant.macFingerprintSHA256]),
            ("expectedWindows", ["deviceId": UUID().uuidString, "fingerprintSha256": exported.grant.windowsFingerprintSHA256]),
        ]
        for (key, value) in mutations {
            var request = original
            request[key] = value
            let changed = CompanionPairingDelegationExport(grant: exported.grant, requestJSON: try JSONSerialization.data(withJSONObject: request))
            #expect(throws: (any Error).self) { try RDPCompanionDelegatedBootstrap.makePlan(exported: changed, now: date) }
        }
        var revoked = exported
        revoked.grant.revokedAt = date
        #expect(throws: (any Error).self) { try RDPCompanionDelegatedBootstrap.makePlan(exported: revoked, now: date) }
        let oversized = CompanionPairingDelegationExport(grant: exported.grant,
            requestJSON: Data(repeating: 0x20, count: RDPCompanionDelegatedBootstrap.maximumRequestBytes + 1))
        #expect(throws: (any Error).self) { try RDPCompanionDelegatedBootstrap.makePlan(exported: oversized, now: date) }
    }

    @Test func expiredAndNearlyExpiredRequestsAreRejectedBeforeInput() throws {
        let exported = try makeExport()
        for now in [date.addingTimeInterval(-1), date.addingTimeInterval(1_795), date.addingTimeInterval(1_800)] {
            #expect(throws: RDPCompanionDelegatedBootstrap.Failure.expiredRequest) {
                try RDPCompanionDelegatedBootstrap.makePlan(exported: exported, now: now)
            }
        }
    }

    @Test func deadlineRequiresReadinessBudgetAndMonotonicUnexpiredTime() throws {
        typealias Deadline = RDPCompanionDelegatedBootstrap.Deadline
        for milliseconds in [-1, 0, 8_499, 120_001] {
            #expect(throws: RDPCompanionDelegatedBootstrap.Failure.deadlineExceeded) {
                try Deadline(milliseconds: milliseconds, nowUptime: 10)
            }
        }
        let deadline = try Deadline(milliseconds: 30_000, nowUptime: 10)
        #expect(try deadline.remainingMilliseconds(nowUptime: 10) == 30_000)
        #expect(try deadline.remainingMilliseconds(nowUptime: 18) == 22_000)
        for time in [9.0, 40.0, 41.0, Double.nan, Double.infinity] {
            #expect(throws: RDPCompanionDelegatedBootstrap.Failure.deadlineExceeded) {
                try deadline.remainingMilliseconds(nowUptime: time)
            }
        }
    }

    private func makeExport(binding: String = "rdp://reviewer@192.0.2.198:3389") throws -> CompanionPairingDelegationExport {
        let identity = RDPCompanionLocalIdentity(signingKey: P256.Signing.PrivateKey(), clientDeviceID: UUID())
        let grant = CompanionPairingDelegationGrant(
            grantID: UUID(), targetID: UUID(), targetBinding: binding,
            macDeviceID: identity.clientDeviceID,
            macFingerprintSHA256: WindowsCompanionAuthorizationProof.fingerprint(publicKeyDER: identity.signingKey.publicKey.derRepresentation),
            windowsDeviceID: UUID(), windowsFingerprintSHA256: String(repeating: "A", count: 64), createdAt: date
        )
        let request = try CompanionPairingDelegationEnrollmentRequest(grant: grant, localIdentity: identity, issuedAt: date, validFor: 1_800)
        return CompanionPairingDelegationExport(grant: grant, requestJSON: try request.encoded())
    }
}
#endif
