#if ENABLE_RDP_2
import CryptoKit
import Foundation

/// The only variable script material is validated public enrollment JSON,
/// encoded as Base64, its digest, and an internally generated temporary name.
/// No caller command, profile address, credential, or executable path is used.
nonisolated enum RDPCompanionDelegatedBootstrap {
    struct Plan: Equatable, Sendable {
        let grantID: UUID
        let requestSHA256: String
        let temporaryFileName: String
        let powerShellLaunchCommand: String
        let powerShellScript: String
    }

    enum Failure: LocalizedError, Equatable, Sendable {
        case invalidRequest
        case expiredRequest
        case deadlineExceeded
        case desktopNotReady

        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The device enrollment request is invalid or does not match its delegation."
            case .expiredRequest: "The device enrollment request expired. Prepare a new request before retrying."
            case .deadlineExceeded: "The device enrollment bootstrap deadline expired before a safe desktop handoff."
            case .desktopNotReady: "The Windows desktop did not become ready for the fixed enrollment command."
            }
        }
    }

    struct Deadline: Sendable {
        let startedAtUptime: TimeInterval
        let expiresAtUptime: TimeInterval

        init(milliseconds: Int, nowUptime: TimeInterval) throws {
            guard (minimumBudgetMilliseconds...120_000).contains(milliseconds), nowUptime.isFinite else {
                throw Failure.deadlineExceeded
            }
            startedAtUptime = nowUptime
            expiresAtUptime = nowUptime + Double(milliseconds) / 1_000
        }

        func remainingMilliseconds(nowUptime: TimeInterval) throws -> Int {
            let remaining = (expiresAtUptime - nowUptime) * 1_000
            guard nowUptime.isFinite, nowUptime >= startedAtUptime,
                  remaining.isFinite, remaining >= 1, remaining <= 120_000 else {
                throw Failure.deadlineExceeded
            }
            return Int(remaining)
        }
    }

    static let minimumBudgetMilliseconds = 8_500
    static let minimumReadinessSeconds: TimeInterval = 8
    static let transitionTimeoutSeconds: TimeInterval = 20
    static let maximumRequestBytes = 4_096
    static let maximumScriptBytes = 8_191
    static let powerShellLaunchCommand = "powershell.exe -NoLogo -NoProfile"
    static let installedSetupRelativePath = #"Programs\JTS Terminal\Windows Companion\JTS.WindowsCompanion.Setup.exe"#

    static func makePlan(
        exported: CompanionPairingDelegationExport,
        now: Date = Date(),
        temporaryID: UUID = UUID()
    ) throws -> Plan {
        try validate(exported, now: now)
        let digest = SHA256.hash(data: exported.requestJSON).map { String(format: "%02x", $0) }.joined()
        let fileName = "JTS-Companion-Delegation-\(temporaryID.uuidString.lowercased()).json"
        let script = [
            "$ErrorActionPreference='Stop';",
            "$e=[IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'),'\(installedSetupRelativePath)');",
            "$p=[IO.Path]::Combine([IO.Path]::GetTempPath(),'\(fileName)');",
            "$created=$false;$keep=$false;",
            "try{",
            "if(!(Test-Path -LiteralPath $e -PathType Leaf)){throw 'installed Companion Setup missing'};",
            "$b=[Convert]::FromBase64String('\(exported.requestBase64)');",
            "$f=[IO.File]::Open($p,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);",
            "$created=$true;try{$f.Write($b,0,$b.Length)}finally{$f.Dispose()};",
            "if((Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash -ne '\(digest)'){throw 'enrollment hash mismatch'};",
            "$a='--install --quiet --delegated-enrollment \"'+$p+'\" --delegated-enrollment-sha256 \(digest)';",
            "$q=Start-Process -FilePath $e -ArgumentList $a -PassThru;$keep=$true;",
            "if(!$q.WaitForExit(120000)){throw 'enrollment still running; check Companion connection'};",
            // Installed Setup returns 4 after starting its detached replacement.
            // That child still needs the request; do not unlink it prematurely.
            "if($q.ExitCode -eq 4){Write-Output 'Enrollment started; waiting for Companion connection'}",
            "else{$keep=$false;if($q.ExitCode -ne 0){throw ('enrollment setup failed: '+$q.ExitCode)};",
            "Write-Output 'Enrollment installed; waiting for authenticated Companion'}",
            "}finally{if($created -and !$keep){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}}",
        ].joined()
        guard powerShellLaunchCommand.utf8.count <= 259,
              script.utf8.count <= maximumScriptBytes,
              script.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
            throw Failure.invalidRequest
        }
        return Plan(grantID: exported.grant.grantID, requestSHA256: digest, temporaryFileName: fileName,
            powerShellLaunchCommand: powerShellLaunchCommand, powerShellScript: script)
    }

    private static func validate(_ exported: CompanionPairingDelegationExport, now: Date) throws {
        let grant = exported.grant
        try grant.validate()
        guard !grant.isRevoked, !exported.requestJSON.isEmpty,
              exported.requestJSON.count <= maximumRequestBytes,
              let root = try JSONSerialization.jsonObject(with: exported.requestJSON) as? [String: Any],
              Set(root.keys) == Set(["schemaVersion", "grantId", "authorizationSource", "targetId", "targetBinding",
                "macIdentity", "expectedWindows", "issuedAtUtc", "expiresAtUtc", "authorizationReference"]),
              let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "1",
              root["authorizationSource"] as? String == "ownerDelegated",
              root["authorizationReference"] as? String == "device-ai-control-enabled",
              (root["grantId"] as? String).flatMap(UUID.init(uuidString:)) == grant.grantID,
              (root["targetId"] as? String).flatMap(UUID.init(uuidString:)) == grant.targetID,
              root["targetBinding"] as? String == grant.targetBinding,
              let mac = root["macIdentity"] as? [String: Any],
              Set(mac.keys) == Set(["deviceId", "publicKeyBase64", "fingerprintSha256"]),
              (mac["deviceId"] as? String).flatMap(UUID.init(uuidString:)) == grant.macDeviceID,
              mac["fingerprintSha256"] as? String == grant.macFingerprintSHA256,
              let base64 = mac["publicKeyBase64"] as? String,
              let publicKey = Data(base64Encoded: base64), publicKey.base64EncodedString() == base64,
              WindowsCompanionAuthorizationProof.fingerprint(publicKeyDER: publicKey) == grant.macFingerprintSHA256,
              let windows = root["expectedWindows"] as? [String: Any],
              Set(windows.keys) == Set(["deviceId", "fingerprintSha256"]),
              (windows["deviceId"] as? String).flatMap(UUID.init(uuidString:)) == grant.windowsDeviceID,
              windows["fingerprintSha256"] as? String == grant.windowsFingerprintSHA256 else {
            throw Failure.invalidRequest
        }
        _ = try P256.Signing.PublicKey(derRepresentation: publicKey)
        guard let issued = utcDate(root["issuedAtUtc"]), let expires = utcDate(root["expiresAtUtc"]),
              now.timeIntervalSince1970.isFinite, issued <= now,
              expires.timeIntervalSince(now) > Double(minimumBudgetMilliseconds) / 1_000,
              expires.timeIntervalSince(issued) > 0, expires.timeIntervalSince(issued) <= 1_800 else {
            throw Failure.expiredRequest
        }
    }

    private static func utcDate(_ value: Any?) -> Date? {
        guard let value = value as? String, value.hasSuffix("Z") else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
#endif
