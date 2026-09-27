#if ENABLE_RDP_2
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct RDPXPCInboundValidationTests {
    @Test func stateCallbacksRequireAnExactBoundedSchema() {
        let valid: NSDictionary = [
            "sessionId": UUID().uuidString,
            "connectionAttemptId": UUID().uuidString,
            "phase": "connected",
            "stateRevision": NSNumber(value: UInt64(7)),
            "runtime": "FreeRDP",
            "runtimeVersion": "3.31.1",
            "companionDVCConnected": true,
            "companionDVCGeneration": NSNumber(value: UInt64(3)),
            "companionInstallerClipboardReady": true,
        ]
        #expect(FreeRDPXPCInboundValidation.state(valid) != nil)

        let obsoleteRuntime = valid.mutableCopy() as! NSMutableDictionary
        obsoleteRuntime["runtimeVersion"] = "3.28.0"
        #expect(FreeRDPXPCInboundValidation.state(obsoleteRuntime) == nil)

        let extra = valid.mutableCopy() as! NSMutableDictionary
        extra["password"] = "must-not-cross-xpc"
        #expect(FreeRDPXPCInboundValidation.state(extra) == nil)

        let oversized = valid.mutableCopy() as! NSMutableDictionary
        oversized["message"] = String(repeating: "x", count: 2_049)
        #expect(FreeRDPXPCInboundValidation.state(oversized) == nil)

        let missingAttempt = valid.mutableCopy() as! NSMutableDictionary
        missingAttempt.removeObject(forKey: "connectionAttemptId")
        #expect(FreeRDPXPCInboundValidation.state(missingAttempt) == nil)

        let malformedAttempt = valid.mutableCopy() as! NSMutableDictionary
        malformedAttempt["connectionAttemptId"] = "not-an-attempt"
        #expect(FreeRDPXPCInboundValidation.state(malformedAttempt) == nil)

        let reconnecting = valid.mutableCopy() as! NSMutableDictionary
        reconnecting["phase"] = "reconnecting"
        #expect(FreeRDPXPCInboundValidation.state(reconnecting) == nil)

        let malformedClipboardCapability = valid.mutableCopy() as! NSMutableDictionary
        malformedClipboardCapability["companionInstallerClipboardReady"] = "true"
        #expect(FreeRDPXPCInboundValidation.state(malformedClipboardCapability) == nil)
    }

    @Test func certificateChallengeCanTravelAtomicallyWithAwaitingState() throws {
        let sessionID = UUID().uuidString
        let connectionAttemptID = UUID().uuidString
        let certificate: NSDictionary = [
            "sessionId": sessionID,
            "connectionAttemptId": connectionAttemptID,
            "host": "rdp.example.test",
            "port": 3_389,
            "commonName": "rdp.example.test",
            "subject": "CN=rdp.example.test",
            "issuer": "CN=Test CA",
            "sha256": String(repeating: "A", count: 64),
            "oldSha256": "",
            "changed": false,
            "hostMismatch": false,
            "pinnedMismatch": false,
        ]
        let awaiting: NSDictionary = [
            "sessionId": sessionID,
            "connectionAttemptId": connectionAttemptID,
            "phase": "awaitingCertificateTrust",
            "stateRevision": NSNumber(value: UInt64(3)),
            "runtime": "FreeRDP",
            "runtimeVersion": "3.31.1",
            "companionDVCConnected": false,
            "companionDVCGeneration": NSNumber(value: UInt64(4)),
            "companionInstallerClipboardReady": false,
            "code": "RDP_CERTIFICATE_UNTRUSTED",
            "message": "Certificate approval required.",
            "certificate": certificate,
        ]
        let validatedAwaiting = try #require(FreeRDPXPCInboundValidation.state(awaiting))
        var stateWithoutCertificate = validatedAwaiting
        stateWithoutCertificate.removeValue(forKey: "certificate")
        #expect(
            FreeRDPXPCInboundValidation.estimatedByteCost(of: validatedAwaiting)
                > FreeRDPXPCInboundValidation.estimatedByteCost(of: stateWithoutCertificate)
                    + 64
        )

        let wrongPhase = awaiting.mutableCopy() as! NSMutableDictionary
        wrongPhase["phase"] = "connected"
        #expect(FreeRDPXPCInboundValidation.state(wrongPhase) == nil)

        let wrongSession = certificate.mutableCopy() as! NSMutableDictionary
        wrongSession["sessionId"] = UUID().uuidString
        let mismatched = awaiting.mutableCopy() as! NSMutableDictionary
        mismatched["certificate"] = wrongSession
        #expect(FreeRDPXPCInboundValidation.state(mismatched) == nil)

        let malformed = certificate.mutableCopy() as! NSMutableDictionary
        malformed["sha256"] = "invalid"
        let invalidCertificate = awaiting.mutableCopy() as! NSMutableDictionary
        invalidCertificate["certificate"] = malformed
        #expect(FreeRDPXPCInboundValidation.state(invalidCertificate) == nil)

        let wrongAttempt = certificate.mutableCopy() as! NSMutableDictionary
        wrongAttempt["connectionAttemptId"] = UUID().uuidString
        let mismatchedAttempt = awaiting.mutableCopy() as! NSMutableDictionary
        mismatchedAttempt["certificate"] = wrongAttempt
        #expect(FreeRDPXPCInboundValidation.state(mismatchedAttempt) == nil)
    }

    @Test func certificateAndFrameCopiesRejectMalformedHelperOutput() {
        let certificate: NSDictionary = [
            "sessionId": UUID().uuidString,
            "connectionAttemptId": UUID().uuidString,
            "host": "rdp.example.test",
            "port": 3_389,
            "commonName": "rdp.example.test",
            "subject": "CN=rdp.example.test",
            "issuer": "CN=Test CA",
            "sha256": String(repeating: "A", count: 64),
            "oldSha256": "",
            "changed": false,
            "hostMismatch": false,
            "pinnedMismatch": false,
        ]
        #expect(FreeRDPXPCInboundValidation.certificate(certificate) != nil)

        let malformedCertificate = certificate.mutableCopy() as! NSMutableDictionary
        malformedCertificate["sha256"] = "not-a-fingerprint"
        #expect(FreeRDPXPCInboundValidation.certificate(malformedCertificate) == nil)

        let inconsistentPinMismatch = certificate.mutableCopy() as! NSMutableDictionary
        inconsistentPinMismatch["pinnedMismatch"] = true
        inconsistentPinMismatch["changed"] = false
        #expect(FreeRDPXPCInboundValidation.certificate(inconsistentPinMismatch) == nil)

        inconsistentPinMismatch["changed"] = true
        #expect(FreeRDPXPCInboundValidation.certificate(inconsistentPinMismatch) != nil)

        let bytesPerRow = 640 * 4
        let height = 480
        let metadata: NSDictionary = [
            "sessionId": UUID().uuidString,
            "connectionAttemptId": UUID().uuidString,
            "frameId": UUID().uuidString,
            "stateRevision": NSNumber(value: UInt64(9)),
            "width": 640,
            "height": height,
            "bytesPerRow": bytesPerRow,
            "pixelFormat": "BGRA32",
            "dirtyX": 0,
            "dirtyY": 0,
            "dirtyWidth": 640,
            "dirtyHeight": height,
            "capturedAt": 1_700_000_000.0,
            "surfaceSeed": NSNumber(value: UInt32(17)),
        ]
        let pixels = NSMutableData(length: bytesPerRow * height)!
        let validated = FreeRDPXPCInboundValidation.frameCopy(
            pixels: pixels,
            metadata: metadata
        )
        #expect(validated != nil)
        #expect(
            validated.flatMap {
                FreeRDPXPCInboundValidation.surfaceSeed(in: $0)
            } == 17
        )

        let shortPixels = NSMutableData(length: bytesPerRow * height - 1)!
        #expect(FreeRDPXPCInboundValidation.frameCopy(pixels: shortPixels, metadata: metadata) == nil)

        let missingAttempt = metadata.mutableCopy() as! NSMutableDictionary
        missingAttempt.removeObject(forKey: "connectionAttemptId")
        #expect(FreeRDPXPCInboundValidation.frameCopy(pixels: pixels, metadata: missingAttempt) == nil)

        let missingSeed = metadata.mutableCopy() as! NSMutableDictionary
        missingSeed.removeObject(forKey: "surfaceSeed")
        #expect(FreeRDPXPCInboundValidation.frameCopy(pixels: pixels, metadata: missingSeed) == nil)

        let oversizedSeed = metadata.mutableCopy() as! NSMutableDictionary
        oversizedSeed["surfaceSeed"] = NSNumber(value: UInt64(UInt32.max) + 1)
        #expect(FreeRDPXPCInboundValidation.frameCopy(pixels: pixels, metadata: oversizedSeed) == nil)
    }

    @Test func dvcAndCallbackQueueLimitsFailClosed() {
        let attemptID = UUID()
        let metadata: NSDictionary = [
            "sessionId": UUID().uuidString,
            "connectionAttemptId": attemptID.uuidString,
            "companionDVCGeneration": NSNumber(value: UInt64(7)),
        ]
        #expect(
            FreeRDPXPCInboundValidation.dvcMessage(
                Data([1]) as NSData,
                metadata: metadata
            )?.connectionAttemptID == attemptID
        )
        #expect(
            FreeRDPXPCInboundValidation.dvcMessage(
                NSData(),
                metadata: metadata
            ) == nil
        )
        let oversized = NSMutableData(
            length: FreeRDPXPCInboundValidation.maximumDVCBytes + 1
        )!
        #expect(
            FreeRDPXPCInboundValidation.dvcMessage(
                oversized,
                metadata: metadata
            ) == nil
        )
        let staleMetadata = metadata.mutableCopy() as! NSMutableDictionary
        staleMetadata["companionDVCGeneration"] = 0
        #expect(
            FreeRDPXPCInboundValidation.dvcMessage(
                Data([1]) as NSData,
                metadata: staleMetadata
            ) == nil
        )
        let extraMetadata = metadata.mutableCopy() as! NSMutableDictionary
        extraMetadata["password"] = "must-not-cross-xpc"
        #expect(
            FreeRDPXPCInboundValidation.dvcMessage(
                Data([1]) as NSData,
                metadata: extraMetadata
            ) == nil
        )

        let limiter = FreeRDPXPCInboundLimiter(
            maximumPendingCallbacks: 2,
            maximumPendingBytes: 10
        )
        #expect(limiter.admit(byteCost: 4) == .accepted)
        #expect(limiter.admit(byteCost: 6) == .accepted)
        #expect(limiter.pendingCount == 2)
        #expect(limiter.pendingByteCount == 10)
        #expect(limiter.admit(byteCost: 1) == .firstRejection)
        #expect(limiter.hasRejectedInput)
        limiter.complete(byteCost: 4)
        limiter.complete(byteCost: 6)
        #expect(limiter.pendingCount == 0)
        #expect(limiter.pendingByteCount == 0)
        #expect(limiter.admit(byteCost: 1) == .rejected)
    }

    @Test func latestCallbackSlotAccountsForInFlightAndQueuedFrames() {
        let limiter = FreeRDPXPCInboundLimiter(
            maximumPendingCallbacks: 2,
            maximumPendingBytes: 12
        )
        let slot = FreeRDPXPCLatestCallbackSlot<String>(
            limiter: limiter,
            reservedByteCost: 6
        )

        #expect(slot.submit("frame-1") == .scheduleDrain)
        #expect(slot.submit("frame-2") == .coalesced)
        #expect(slot.submit("frame-3") == .coalesced)
        #expect(limiter.pendingCount == 1)
        #expect(limiter.pendingByteCount == 6)
        #expect(slot.takeLatestForDelivery() == "frame-3")

        #expect(slot.submit("frame-4") == .coalesced)
        #expect(slot.submit("frame-5") == .coalesced)
        #expect(limiter.pendingCount == 2)
        #expect(limiter.pendingByteCount == 12)
        #expect(slot.finishDelivery())
        #expect(limiter.pendingCount == 1)
        #expect(limiter.pendingByteCount == 6)
        #expect(slot.takeLatestForDelivery() == "frame-5")
        #expect(!slot.finishDelivery())
        #expect(limiter.pendingCount == 0)
        #expect(limiter.pendingByteCount == 0)
    }

    @Test func latestCallbackSlotRejectsASecondRetainedPayloadBeyondItsBudget() {
        let limiter = FreeRDPXPCInboundLimiter(
            maximumPendingCallbacks: 1,
            maximumPendingBytes: 6
        )
        let slot = FreeRDPXPCLatestCallbackSlot<String>(
            limiter: limiter,
            reservedByteCost: 6
        )

        #expect(slot.submit("frame-1") == .scheduleDrain)
        #expect(slot.takeLatestForDelivery() == "frame-1")
        #expect(slot.submit("frame-2") == .firstRejection)
        #expect(limiter.pendingCount == 1)
        #expect(limiter.pendingByteCount == 6)
        #expect(!slot.finishDelivery())
        #expect(limiter.pendingCount == 0)
        #expect(limiter.pendingByteCount == 0)
    }

    @Test func latestCallbackSlotHonorsPermanentLimiterRejection() {
        let limiter = FreeRDPXPCInboundLimiter(
            maximumPendingCallbacks: 1,
            maximumPendingBytes: 5
        )
        let slot = FreeRDPXPCLatestCallbackSlot<String>(
            limiter: limiter,
            reservedByteCost: 5
        )

        #expect(slot.submit("frame-1") == .scheduleDrain)
        #expect(limiter.reject() == .firstRejection)
        #expect(slot.submit("frame-2") == .rejected)
        #expect(slot.takeLatestForDelivery() == "frame-1")
        #expect(!slot.finishDelivery())
        #expect(limiter.pendingCount == 0)
    }

    @Test func cancellationAcknowledgementHasABoundedWait() {
        #expect(FreeRDPXPCRequestDeadlines.remoteCancellation == 0.25)
    }
}
#endif
