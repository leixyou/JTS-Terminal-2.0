#if ENABLE_RDP_2
import Foundation
import Testing
@testable import JTSTerminal

struct WindowsCompanionPairingLifecycleTests {
    @Test func setupTargetContentDistinguishesProfilesWithTheSameName() {
        let firstKey = #"rdp://CORP\reviewer@192.0.2.198:3389"#
        let secondKey = #"rdp://LAB\reviewer@192.0.2.199:3389"#
        let firstTargetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondTargetID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let first = WindowsCompanionSetupContentPolicy.targetContent(
            profileName: "Windows Review",
            connectionKey: firstKey,
            targetID: firstTargetID,
            language: .english
        )
        let second = WindowsCompanionSetupContentPolicy.targetContent(
            profileName: "Windows Review",
            connectionKey: secondKey,
            targetID: secondTargetID,
            language: .english
        )

        #expect(first.profileName == second.profileName)
        #expect(first.connectionKey == firstKey)
        #expect(second.connectionKey == secondKey)
        #expect(first.targetID == firstTargetID)
        #expect(first.shortTargetID == "11111111")
        #expect(first.targetIDLabel == "Profile ID")
        #expect(first != second)
        #expect(first.accessibilityLabel == "Windows Companion pairing target")

        let chinese = WindowsCompanionSetupContentPolicy.targetContent(
            profileName: "  ",
            connectionKey: firstKey,
            targetID: firstTargetID,
            language: .simplifiedChinese
        )
        #expect(chinese.profileName == "未命名 RDP 配置")
        #expect(chinese.connectionKey == firstKey)
        #expect(chinese.targetIDLabel == "配置 ID")
        #expect(chinese.targetIDAccessibilityLabel == "稳定的 RDP 配置标识")
        #expect(chinese.accessibilityLabel == "Windows Companion 配对目标")
    }

    @Test func setupTargetContentDistinguishesCopiedProfilesAtTheSameEndpoint() {
        let connectionKey = #"rdp://CORP\reviewer@192.0.2.198:3389"#
        let first = WindowsCompanionSetupContentPolicy.targetContent(
            profileName: "Windows Review",
            connectionKey: connectionKey,
            targetID: UUID(uuidString: "aaaaaaaa-1111-1111-1111-111111111111")!,
            language: .english
        )
        let copied = WindowsCompanionSetupContentPolicy.targetContent(
            profileName: "Windows Review",
            connectionKey: connectionKey,
            targetID: UUID(uuidString: "bbbbbbbb-2222-2222-2222-222222222222")!,
            language: .english
        )

        #expect(first.profileName == copied.profileName)
        #expect(first.connectionKey == copied.connectionKey)
        #expect(first.shortTargetID == "aaaaaaaa")
        #expect(copied.shortTargetID == "bbbbbbbb")
        #expect(first != copied)
    }

    @Test func setupChineseCopyIsLocalizedAndUsesPlainTerminology() {
        let copy = WindowsCompanionSetupContentPolicy.localizedCopy(
            language: .simplifiedChinese
        )
        let renderedCopy = [
            copy.hostRequirementTitle,
            copy.directRDPDetail,
            copy.currentUserInstallationDetail,
            copy.connectAndPairDetail,
            copy.authorizedPeerDetail,
            copy.unauthorizedPeerTitle,
            copy.unauthorizedPeerDetail,
            copy.pairingRequiredDetail,
            copy.authorizedIdentityUnavailableDetail,
        ].joined(separator: "\n")

        #expect(copy.hostRequirementTitle == "Windows 10/11 专业版、企业版或教育版（x64）")
        #expect(copy.directRDPDetail.contains("SSH 别名"))
        #expect(copy.currentUserInstallationDetail.contains("UI 自动化"))
        #expect(copy.currentUserInstallationDetail.contains("托管组件"))
        #expect(copy.currentUserInstallationDetail.contains("会话 0"))
        #expect(copy.connectAndPairDetail.contains("桌面工作区"))
        #expect(copy.authorizedPeerDetail.contains("已授权的对端"))
        #expect(copy.unauthorizedPeerDetail.contains("为安全起见"))
        #expect(copy.authorizedIdentityUnavailableDetail.contains("已认证的对端身份"))

        for untranslatedTerm in [
            "SSH alias",
            "Managed",
            "peer",
            "fail-closed",
            "Desktop 工作区",
            "UI Automation",
            "Session 0",
        ] {
            #expect(!renderedCopy.contains(untranslatedTerm))
        }
    }

    @Test func setupEnglishCopyRetainsProductAndPlatformTerminology() {
        let copy = WindowsCompanionSetupContentPolicy.localizedCopy(
            language: .english
        )

        #expect(copy.hostRequirementTitle == "Windows 10/11 Pro, Enterprise, or Education x64")
        #expect(copy.directRDPDetail.contains("SSH alias"))
        #expect(copy.currentUserInstallationDetail.contains("Managed component"))
        #expect(copy.connectAndPairDetail.contains("Desktop workspace"))
        #expect(copy.unauthorizedPeerDetail.hasPrefix("Fail-closed:"))
    }

    @Test func unpairRequiresTheCurrentlyAuthorizedPeer() throws {
        let peer = makePeer()
        let accepted = try WindowsCompanionPairingLifecycle.requireAuthorizedPeer(
            availability: .ready,
            peerIdentity: peer
        )
        #expect(accepted == peer)

        for availability in [
            WindowsCompanionAvailability.unknown,
            .missing,
            .incompatible,
            .pairingRequired,
        ] {
            do {
                _ = try WindowsCompanionPairingLifecycle.requireAuthorizedPeer(
                    availability: availability,
                    peerIdentity: peer
                )
                Issue.record("Expected \(availability.rawValue) to reject unpair")
            } catch let failure as WindowsCompanionRequestFailure {
                #expect(failure.code == "PAIRING_REQUIRED")
                #expect(!failure.retryable)
            } catch {
                Issue.record("Expected WindowsCompanionRequestFailure, got \(error)")
            }
        }

        do {
            _ = try WindowsCompanionPairingLifecycle.requireAuthorizedPeer(
                availability: .ready,
                peerIdentity: nil
            )
            Issue.record("Expected a missing authenticated identity to reject unpair")
        } catch let failure as WindowsCompanionRequestFailure {
            #expect(failure.code == "PAIRING_REQUIRED")
        }
    }

    @Test func unpairResponseMustConfirmRevocationAndPositiveRevision() throws {
        #expect(try WindowsCompanionPairingLifecycle.validateUnpairResponse([
            "revoked": true,
            "stateRevision": UInt64(7),
        ]) == 7)
        #expect(try WindowsCompanionPairingLifecycle.validateUnpairResponse([
            "revoked": true,
            "stateRevision": Int64(8),
        ]) == 8)
        #expect(try WindowsCompanionPairingLifecycle.validateUnpairResponse([
            "revoked": true,
            "stateRevision": NSNumber(value: 9),
        ]) == 9)

        let invalidResults: [[String: Any]] = [
            [:],
            ["revoked": false, "stateRevision": UInt64(1)],
            ["revoked": true, "stateRevision": UInt64(0)],
            ["revoked": true, "stateRevision": Int64(-1)],
            ["revoked": true, "stateRevision": true],
        ]
        for result in invalidResults {
            do {
                _ = try WindowsCompanionPairingLifecycle.validateUnpairResponse(result)
                Issue.record("Expected malformed unpair response to fail closed")
            } catch let failure as WindowsCompanionRequestFailure {
                #expect(failure.code == "COMPANION_UNPAIR_RESPONSE_INVALID")
                #expect(!failure.retryable)
            } catch {
                Issue.record("Expected WindowsCompanionRequestFailure, got \(error)")
            }
        }
    }

    @Test func successfulUnpairTransitionsToBlockedPairingState() {
        let state = WindowsCompanionPairingLifecycle.blockedPairingState(
            companionVersion: "2.0.0"
        )
        #expect(state.availability == .pairingRequired)
        #expect(state.protocolVersion == WindowsCompanionDVC.protocolVersion)
        #expect(state.companionVersion == "2.0.0")
        #expect(state.reason?.contains("revoked") == true)
    }

    private func makePeer() -> WindowsCompanionPeerIdentity {
        WindowsCompanionPeerIdentity(
            deviceID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
            fingerprintSHA256: String(repeating: "A", count: 64),
            publicKeyDER: Data(repeating: 0xA5, count: 91),
            agentVersion: "2.0.0",
            capabilities: ["companion.unpair"],
            clientDeviceID: UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!,
            clientFingerprintSHA256: String(repeating: "B", count: 64),
            clientAuthorization: WindowsCompanionClientAuthorization(
                challenge: Data(repeating: 0x5A, count: 32),
                expiresAtUnixMilliseconds: 1_900_000_000_000,
                pairingRequired: false
            ),
            sessionBinding: Data(repeating: 0xC3, count: 32)
        )
    }
}

#endif
