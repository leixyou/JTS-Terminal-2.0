#if ENABLE_RDP_2
import Foundation
import Testing
@testable import JTSTerminal

struct WindowsCompanionInstallationTests {
    @Test func statusTapOffersMissingInstallationAndPreservesFailureDetails() {
        #expect(
            WindowsCompanionStatusTapPolicy.action(
                availability: .missing,
                installation: .idle
            ) == .confirmInstallation
        )
        #expect(
            WindowsCompanionStatusTapPolicy.action(
                availability: .missing,
                installation: WindowsCompanionInstallationState(
                    phase: .failed,
                    failureMessage: "retry"
                )
            ) == .showInstallationProgress
        )
        #expect(
            WindowsCompanionStatusTapPolicy.action(
                availability: .missing,
                installation: WindowsCompanionInstallationState(
                    phase: .transferring
                )
            ) == .showInstallationProgress
        )
        #expect(
            WindowsCompanionStatusTapPolicy.action(
                availability: .ready,
                installation: .idle
            ) == .showSetup
        )
    }

    @Test func installationProgressIsBoundedAndOnlyActiveDuringRuntimeWork() {
        let transferring = WindowsCompanionInstallationState(
            phase: .transferring,
            transferredBytes: 150,
            totalBytes: 100
        )
        #expect(transferring.isActive)
        #expect(transferring.progressFraction == 1)

        let failed = WindowsCompanionInstallationState(
            phase: .failed,
            transferredBytes: -10,
            totalBytes: 100,
            failureMessage: "failed"
        )
        #expect(!failed.isActive)
        #expect(failed.canOfferInstallation)
        #expect(failed.progressFraction == nil)

        let pairing = WindowsCompanionInstallationState(phase: .pairingRequired)
        #expect(pairing.isCompleted)
        #expect(!pairing.canOfferInstallation)
    }

    @Test func bootstrapPlanAcceptsOnlyTheFixedVerifiedInstallerContract() throws {
        let digest = String(repeating: "a", count: 64)
        let remoteFileName =
            "JTS-Companion-0123456789abcdef0123456789abcdef.exe"
        let plan = try RDPCompanionBootstrapInstaller.makePlan(
            fileName: remoteFileName,
            fileSize: 123_456,
            sha256: digest
        )

        #expect(plan.fileName == remoteFileName)
        #expect(plan.fileSize == 123_456)
        #expect(plan.sha256 == digest)
        #expect(plan.temporaryFolderAddress == "%TEMP%")
        #expect(plan.powerShellLaunchCommand == "powershell.exe -NoLogo -NoProfile")
        #expect(
            RDPCompanionBootstrapInstaller.desktopLaunchTransitionTimeout == .seconds(20)
        )
        #expect(
            RDPCompanionBootstrapInstaller.desktopLaunchMinimumReadinessDelay == .seconds(8)
        )
        #expect(plan.powerShellScript.contains(remoteFileName))
        #expect(plan.powerShellScript.contains("Get-FileHash -Algorithm SHA256"))
        #expect(!plan.powerShellScript.contains("Get-AuthenticodeSignature"))
        #expect(!plan.powerShellScript.contains("SignerCertificate"))
        #expect(plan.powerShellScript.contains("[IO.FileShare]::None"))
        #expect(plan.powerShellScript.contains("$l=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)"))
        #expect(plan.powerShellScript.contains("if($l.Length -ne 123456){throw 'size mismatch'}"))
        #expect(plan.powerShellScript.contains("$i.Length -eq 123456"))
        #expect(plan.powerShellScript.contains("AddSeconds(150)"))
        #expect(plan.powerShellScript.contains("throw 'hash mismatch'"))
        #expect(plan.powerShellScript.contains("}finally{if($null -ne $l){$l.Dispose()};Remove-Item -LiteralPath $p"))
        let lockStart = try #require(plan.powerShellScript.range(of: "$l=[IO.File]::Open"))
        let hashCheck = try #require(plan.powerShellScript.range(of: "Get-FileHash -Algorithm SHA256"))
        let launch = try #require(plan.powerShellScript.range(of: "$q=Start-Process"))
        let unlock = try #require(plan.powerShellScript.range(of: "$l.Dispose()"))
        #expect(lockStart.lowerBound < hashCheck.lowerBound)
        #expect(hashCheck.lowerBound < launch.lowerBound)
        #expect(launch.lowerBound < unlock.lowerBound)
        #expect(plan.powerShellScript.contains("--install','--quiet"))
        #expect(plan.powerShellScript.contains("WaitForExit(120000)"))
        #expect(plan.powerShellScript.contains("Kill()"))
        #expect(plan.powerShellScript.contains("WaitForExit(10000)"))
        #expect(plan.powerShellScript.contains("123456"))
        #expect(plan.powerShellScript.contains(digest))
        #expect(!plan.powerShellScript.contains("InvokeVerb"))
        #expect(!plan.powerShellScript.contains("Start-Process explorer.exe"))
        #expect(!plan.powerShellScript.contains("{;"))
        #expect(!plan.powerShellScript.contains(";}finally"))
        #expect(!plan.powerShellScript.contains("\n"))
        #expect(
            plan.powerShellLaunchCommand.utf8.count <=
                RDPCompanionBootstrapInstaller.maximumRunCommandBytes
        )
        #expect(
            plan.powerShellScript.utf8.count <=
                RDPCompanionBootstrapInstaller.maximumPowerShellScriptBytes
        )
        #expect(plan.powerShellScript.unicodeScalars.allSatisfy { (32...126).contains($0.value) })

        #expect(throws: RDPCompanionBootstrapInstaller.PlanError.invalidFileName) {
            try RDPCompanionBootstrapInstaller.makePlan(
                fileName: "JTS-Windows-Companion-Setup.exe",
                fileSize: 123_456,
                sha256: digest
            )
        }
        #expect(throws: RDPCompanionBootstrapInstaller.PlanError.invalidFileSize) {
            try RDPCompanionBootstrapInstaller.makePlan(
                fileName: remoteFileName,
                fileSize: 0,
                sha256: digest
            )
        }
        #expect(throws: RDPCompanionBootstrapInstaller.PlanError.invalidSHA256) {
            try RDPCompanionBootstrapInstaller.makePlan(
                fileName: remoteFileName,
                fileSize: 123_456,
                sha256: String(repeating: "A", count: 64)
            )
        }
    }

    @Test func installationCopyDescribesBundledVerificationAndRetainsUAC() {
        for language in [AppLanguage.english, .simplifiedChinese] {
            let confirmation = WindowsCompanionInstallationContentPolicy.confirmationMessage(
                profileName: "Windows Workstation",
                connectionKey: "user@192.0.2.1:3389",
                language: language
            )
            #expect(confirmation.contains("Windows Workstation"))
            #expect(confirmation.contains("user@192.0.2.1:3389"))
            #expect(confirmation.contains("UAC"))
            #expect(!confirmation.contains("signed Companion installer"))
            #expect(!confirmation.contains("已签名"))
            let preparing = WindowsCompanionInstallationContentPolicy.content(
                for: WindowsCompanionInstallationState(phase: .preparing),
                language: language
            )
            #expect(preparing.detail.contains("SHA-256"))
            #expect(!preparing.detail.contains("Authenticode"))
            #expect(
                WindowsCompanionSetupContentPolicy.localizedCopy(language: language)
                    .currentUserInstallationDetail.contains("UAC")
            )
        }
    }

    @Test func remoteInstallerBasenameIsStrictAndUniqueAttemptSafe() {
        #expect(
            RDPCompanionInstallerOffer.isValidRemoteFileName(
                "JTS-Companion-0123456789abcdef0123456789abcdef.exe"
            )
        )
        #expect(
            !RDPCompanionInstallerOffer.isValidRemoteFileName(
                "JTS-Windows-Companion-Setup.exe"
            )
        )
        #expect(
            !RDPCompanionInstallerOffer.isValidRemoteFileName(
                "JTS-Companion-0123456789ABCDEF0123456789ABCDEF.exe"
            )
        )
        #expect(
            !RDPCompanionInstallerOffer.isValidRemoteFileName(
                "JTS-Companion-../../Setup.exe"
            )
        )
    }

    @Test func completionStateIsReconciledAgainstTheCurrentDVCState() {
        let proposedReady = WindowsCompanionInstallationState(phase: .ready)
        #expect(
            WindowsCompanionInstallationReconciliationPolicy.reconcile(
                proposed: proposedReady,
                currentAvailability: .missing,
                incompatibleFailureMessage: "incompatible"
            ) == .idle
        )
        #expect(
            WindowsCompanionInstallationReconciliationPolicy.reconcile(
                proposed: .idle,
                currentAvailability: .pairingRequired,
                incompatibleFailureMessage: "incompatible"
            ).phase == .pairingRequired
        )
        let incompatible =
            WindowsCompanionInstallationReconciliationPolicy.reconcile(
                proposed: proposedReady,
                currentAvailability: .incompatible,
                incompatibleFailureMessage: "incompatible"
            )
        #expect(incompatible.phase == .failed)
        #expect(incompatible.failureMessage == "incompatible")

        let failed = WindowsCompanionInstallationState(
            phase: .failed,
            failureMessage: "retry"
        )
        #expect(
            WindowsCompanionInstallationReconciliationPolicy.reconcile(
                proposed: failed,
                currentAvailability: .unknown,
                incompatibleFailureMessage: "incompatible"
            ) == failed
        )
        #expect(
            WindowsCompanionInstallationContentPolicy.content(
                for: failed,
                language: .english
            ).detail == "retry"
        )
    }
}
#endif
