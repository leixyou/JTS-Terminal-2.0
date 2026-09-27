#if ENABLE_RDP_2
import Foundation

/// Builds the fixed, user-initiated Windows bootstrap command used after the
/// XPC helper has exposed the hash-verified bundled Companion setup as one uniquely named
/// virtual clipboard file. No profile value, credential, or caller-provided
/// path enters the command line. The expected SHA-256 comes from the installer
/// resources sealed inside the Apple-signed app, not from the Windows host.
nonisolated enum RDPCompanionBootstrapInstaller {
    struct Plan: Equatable, Sendable {
        let fileName: String
        let fileSize: UInt64
        let sha256: String
        let temporaryFolderAddress: String
        let powerShellLaunchCommand: String
        let powerShellScript: String
    }

    enum PlanError: LocalizedError, Equatable, Sendable {
        case invalidFileName
        case invalidFileSize
        case invalidSHA256
        case invalidCommand

        var errorDescription: String? {
            switch self {
            case .invalidFileName:
                return "The bundled Companion installer has an unexpected file name."
            case .invalidFileSize:
                return "The bundled Companion installer has an invalid file size."
            case .invalidSHA256:
                return "The bundled Companion installer has an invalid SHA-256 digest."
            case .invalidCommand:
                return "The Companion installer bootstrap command could not be constructed safely."
            }
        }
    }

    static let maximumFileSize: UInt64 = 2 * 1_024 * 1_024 * 1_024 - 1
    // The classic Windows Run dialog is MAX_PATH-bound. Keep every command
    // sent to Win+R within its practical 259-character input limit; the long
    // verifier script is typed into an already opened PowerShell console.
    static let maximumRunCommandBytes = 259
    static let maximumPowerShellScriptBytes = 2_048
    static let temporaryFolderAddress = "%TEMP%"
    static let powerShellLaunchCommand = "powershell.exe -NoLogo -NoProfile"
    static let remoteTransferTimeoutSeconds = 150
    static let remoteSetupTimeoutMilliseconds = 120_000
    // Run-dialog paints and caret animation can produce new frame identifiers
    // before Explorer or PowerShell owns the foreground. Require both an
    // observed transition and a conservative cold-start window before typing
    // into the newly launched application.
    static let desktopLaunchTransitionTimeout: Duration = .seconds(20)
    static let desktopLaunchMinimumReadinessDelay: Duration = .seconds(8)
    // The Windows-side transfer may legitimately consume the full 150-second
    // budget. Leave another 150 seconds for hash verification,
    // transactional installation, Agent startup, and DVC negotiation.
    static let companionJoinTimeout: Duration = .seconds(300)

    static func makePlan(
        fileName: String,
        fileSize: UInt64,
        sha256: String
    ) throws -> Plan {
        guard RDPCompanionInstallerOffer.isValidRemoteFileName(fileName) else {
            throw PlanError.invalidFileName
        }
        guard (1...maximumFileSize).contains(fileSize) else {
            throw PlanError.invalidFileSize
        }
        guard isLowercaseSHA256(sha256) else {
            throw PlanError.invalidSHA256
        }

        let script = [
            "$ErrorActionPreference='Stop';",
            "$p=[IO.Path]::Combine($env:TEMP,'\(fileName)');",
            "$l=$null;",
            "try{",
            "$d=[DateTime]::UtcNow.AddSeconds(\(remoteTransferTimeoutSeconds));",
            "$r=$false;",
            "while(!$r){",
            "if(Test-Path -LiteralPath $p){",
            "$i=Get-Item -LiteralPath $p;",
            "if($i.Length -eq \(fileSize)){",
            "try{",
            "$h=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);",
            "$h.Dispose();",
            "$r=$true;",
            "}catch{};",
            "};",
            "};",
            "if(!$r){",
            "if([DateTime]::UtcNow -ge $d){throw 'transfer timeout'};",
            "Start-Sleep -Milliseconds 200;",
            "};",
            "};",
            // Keep a deny-write/delete handle across verification and launch. A correct hash
            // must not become a check-then-replace window when Authenticode is optional.
            "$l=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);",
            "if($l.Length -ne \(fileSize)){throw 'size mismatch'};",
            "if((Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash -ne '\(sha256)'){throw 'hash mismatch'};",
            "$q=Start-Process -FilePath $p -ArgumentList '--install','--quiet' -PassThru;",
            "if(!$q.WaitForExit(\(remoteSetupTimeoutMilliseconds))){",
            "try{$q.Kill()}catch{if(!$q.HasExited){throw 'setup termination failed'}};",
            "if(!$q.WaitForExit(10000)){throw 'setup termination timeout'};",
            "throw 'setup timeout';",
            "};",
            "if($q.ExitCode -ne 0){throw 'setup failed'}",
            "}finally{",
            "if($null -ne $l){$l.Dispose()};",
            "Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue;",
            "}",
        ].joined()
        guard temporaryFolderAddress.utf8.count <= maximumRunCommandBytes,
              temporaryFolderAddress.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
              powerShellLaunchCommand.utf8.count <= maximumRunCommandBytes,
              powerShellLaunchCommand.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
              script.utf8.count <= maximumPowerShellScriptBytes,
              script.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
            throw PlanError.invalidCommand
        }

        return Plan(
            fileName: fileName,
            fileSize: fileSize,
            sha256: sha256,
            temporaryFolderAddress: temporaryFolderAddress,
            powerShellLaunchCommand: powerShellLaunchCommand,
            powerShellScript: script
        )
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
#endif
