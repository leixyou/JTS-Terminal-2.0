import CryptoKit
import Foundation
import XCTest
@testable import JTSCompanionTransport

extension InteropTests {
    func testControlRPCUsesPinnedTLSAndDurableTasksWithoutDesktop() async throws {
        let tools = try interopTools()
        let identity = RelayIdentity(privateKey: P256.Signing.PrivateKey())
        let session = UUID().uuidString.lowercased()
        let host = try startHost(tools: tools, controllerID: identity.deviceID, sessionID: session, lane: .control, mode: "control")
        defer { if host.process.isRunning { host.process.terminate() } }
        let peer = try PairedCompanionDevice(publicKeySPKI: Data(base64Encoded: host.info.publicKeySpkiBase64)!,
            allowedLanes: [.control], allowWindows10TLS12: host.info.tlsPolicy == "tls12")
        let binding = try CompanionLaneBinding(sessionID: session, lane: .control,
            controllerDeviceID: identity.deviceID, companionDeviceID: peer.deviceID)
        let carrier = try await TestLoopbackTCPCarrier.connect(port: host.info.port)
        let channel = try await PinnedTLSChannelFactory().authenticate(carrier: carrier, identity: identity, peer: peer, binding: binding)
        let client = try CompanionControlClient(channel: channel)
        let grant = try XCTUnwrap(host.info.grantId.flatMap(UUID.init(uuidString:)))
        let status = try await client.status(grantID: grant)
        XCTAssertEqual(Set(status.capabilities), ControlLimits.operations)

        let id = UUID(), deadline = Date().addingTimeInterval(60)
        let payload = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0) })
        _ = try await client.submit(jobID: id, grantID: grant, kind: "fixture.echo", deadline: deadline, payload: payload)
        let result = try await awaitJob(client, job: id, grant: grant, state: .succeeded)
        XCTAssertEqual(result.outputBytes, payload.count)
        // Exact retry is the same durable receipt; changing immutable content is denied.
        let repeated = try await client.submit(jobID: id, grantID: grant, kind: "fixture.echo", deadline: deadline, payload: payload)
        XCTAssertEqual(repeated.state, .succeeded)
        do {
            _ = try await client.submit(jobID: id, grantID: grant, kind: "fixture.echo", deadline: deadline, payload: Data([9]))
            XCTFail("changed payload accepted for existing ID")
        } catch { XCTAssertEqual(error as? CompanionControlError, .remote("JOB_IDEMPOTENCY_CONFLICT")) }
        var collected = Data()
        while collected.count < payload.count {
            let chunk = try await client.output(jobID: id, grantID: grant, offset: collected.count)
            XCTAssertFalse(chunk.data.isEmpty); collected += chunk.data
        }
        XCTAssertEqual(collected, payload)

        do { _ = try await client.status(grantID: UUID()); XCTFail("unknown grant accepted") }
        catch { XCTAssertEqual(error as? CompanionControlError, .remote("CONTROL_GRANT_REJECTED")) }
        let running = UUID()
        _ = try await client.submit(jobID: running, grantID: grant, kind: "fixture.block", deadline: deadline,
            payload: Data([1]), allowDisconnected: true)
        _ = try await awaitJob(client, job: running, grant: grant, state: .running)
        _ = try await client.cancel(jobID: running, grantID: grant)
        _ = try await awaitJob(client, job: running, grant: grant, state: .cancelled)
        await client.close()
        host.process.waitUntilExit()
        XCTAssertEqual(host.process.terminationStatus, 0)
    }

    private func awaitJob(_ client: CompanionControlClient, job: UUID, grant: UUID, state: CompanionJobState) async throws -> CompanionJobReceipt {
        let stop = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < stop {
            let receipt = try await client.job(jobID: job, grantID: grant)
            if receipt.state == state { return receipt }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CompanionControlError.timedOut
    }
}
