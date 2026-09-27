import CryptoKit
import Darwin
import Foundation
import XCTest
import JTSCompanionClient
@testable import JTSCompanionTransport

/// Opt-in public-carrier acceptance using the pre-admitted disposable test pair.
/// It does not change relay admission, enroll Windows, or perform an NLA login.
final class PublicRelayInteropTests: XCTestCase {
    func testPublicRelayCarriesPinnedControlFileAndRdpBusinessLanes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let origin = environment["JTS_PUBLIC_RELAY_ORIGIN"],
              let keys = environment["JTS_PUBLIC_RELAY_TEST_IDENTITIES"],
              let dotnet = environment["JTS_INTEROP_DOTNET"], let dll = environment["JTS_INTEROP_HOST_DLL"] else {
            throw XCTSkip("Public relay test fixture explicitly unconfigured; no live route claimed.")
        }
        let directory = URL(fileURLWithPath: keys)
        let identity = RelayIdentity(privateKey: try P256.Signing.PrivateKey(pemRepresentation:
            String(contentsOf: directory.appendingPathComponent("controller.key"), encoding: .utf8)))
        let pinnedPeerKey = try P256.Signing.PrivateKey(pemRepresentation:
            String(contentsOf: directory.appendingPathComponent("companion.key"), encoding: .utf8)).publicKey.derRepresentation
        let endpoint = try RelayEndpoint(XCTUnwrap(URL(string: origin)))
        let process = Process(); process.executableURL = URL(fileURLWithPath: dotnet)
        process.arguments = [dll, "--public-relay-fixture"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
            if !diagnostic.isEmpty, diagnostic.count < 4096,
               let text = String(data: diagnostic, encoding: .utf8) { print(text) }
        }
        let start = try JSONSerialization.data(withJSONObject: ["origin": origin,
            "companionKeyPath": directory.appendingPathComponent("companion.key").path,
            "controllerSPKI": identity.publicKeySPKI.base64EncodedString()]) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: start); try input.fileHandleForWriting.close()
        let info = try JSONDecoder().decode(HostInfo.self, from: readLine(output.fileHandleForReading))
        XCTAssertTrue(info.ready)
        XCTAssertEqual(Data(base64Encoded: info.publicKeySpkiBase64), pinnedPeerKey)
        let peer = try PairedCompanionDevice(publicKeySPKI: pinnedPeerKey, allowedLanes: Set(RelayLane.allCases), allowWindows10TLS12: true)
        XCTAssertEqual(info.companionDeviceId, peer.deviceID)
        let relay = RelayHTTPClient(endpoint: endpoint, identity: identity)
        try await relay.presence()
        let controlGrant = try XCTUnwrap(UUID(uuidString: info.controlGrantId))
        let fileGrant = try XCTUnwrap(UUID(uuidString: info.fileGrantId))
        let rdpGrant = try XCTUnwrap(UUID(uuidString: info.rdpGrantId))

        let control = await coordinator(identity, relay, peer)
        do {
            try await control.connect(deviceID: peer.deviceID, lane: .control)
            let client = try await control.controlClient(deviceID: peer.deviceID)
            let status = try await client.status(grantID: controlGrant)
            XCTAssertTrue(status.capabilities.contains("job.submit"))
            let job = UUID(), payload = Data("public relay authenticated job fixture".utf8)
            _ = try await client.submit(jobID: job, grantID: controlGrant, kind: "fixture.echo", deadline: Date().addingTimeInterval(30), payload: payload)
            var done = false
            for _ in 0..<50 {
                if try await client.job(jobID: job, grantID: controlGrant).state == .succeeded { done = true; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(done)
            let result = try await client.output(jobID: job, grantID: controlGrant)
            XCTAssertEqual(result.data, payload)
        } catch { await control.revoke(deviceID: peer.deviceID); throw error }
        await control.revoke(deviceID: peer.deviceID)
        print("PUBLIC_RELAY_CONTROL_OK pinned_mtls=true native_windows=false")

        let files = await coordinator(identity, relay, peer)
        do {
            try await files.connect(deviceID: peer.deviceID, lane: .file)
            try await files.authorizeLane(deviceID: peer.deviceID, lane: .file, grantID: fileGrant)
            let client = CompanionFileClient(lane: CoordinatorStream(coordinator: files, deviceID: peer.deviceID, lane: .file), grantID: fileGrant)
            _ = try await file(client, .roots, [:])
            let bytes = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0) })
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let transfer = UUID().uuidString.lowercased()
            _ = try await file(client, .beginWrite, ["transferId": transfer, "rootId": "shared", "path": "probe.bin",
                "totalBytes": bytes.count, "sha256": hash, "overwrite": false])
            for start in stride(from: 0, to: bytes.count, by: 32768) {
                let end = min(start + 32768, bytes.count)
                _ = try await file(client, .writeChunk, ["transferId": transfer, "offset": start,
                    "dataBase64": bytes.subdata(in: start..<end).base64EncodedString(), "final": end == bytes.count])
            }
            _ = try await file(client, .commitWrite, ["transferId": transfer])
            let stat = try await file(client, .stat, ["rootId": "shared", "path": "probe.bin", "includeSha256": true])
            XCTAssertEqual(stat["sha256"] as? String, hash)
            var received = Data()
            while received.count < bytes.count {
                let chunk = try await file(client, .read, ["rootId": "shared", "path": "probe.bin", "offset": received.count, "maximumBytes": 32768])
                let data = try XCTUnwrap((chunk["dataBase64"] as? String).flatMap { Data(base64Encoded: $0) })
                XCTAssertFalse(data.isEmpty); received.append(data)
            }
            XCTAssertEqual(received, bytes)
            await client.close()
        } catch { await files.revoke(deviceID: peer.deviceID); throw error }
        print("PUBLIC_RELAY_FILE_OK bytes=50000 chunk_sha256=true atomic_commit=true native_windows=false")

        let rdp = await coordinator(identity, relay, peer)
        do {
            try await rdp.connect(deviceID: peer.deviceID, lane: .rdp)
            print("PUBLIC_RELAY_RDP_CONNECTED pinned_mtls=true")
            try await rdp.authorizeLane(deviceID: peer.deviceID, lane: .rdp, grantID: rdpGrant)
            print("PUBLIC_RELAY_RDP_AUTHORIZED grant_checked=true")
            let payload = Data(repeating: 0xa5, count: 65536)
            async let incoming = readExactly(rdp, peer: peer.deviceID, count: payload.count)
            try await rdp.send(deviceID: peer.deviceID, lane: .rdp, plaintext: payload)
            let received = try await incoming; XCTAssertEqual(received, payload)
        } catch { await rdp.revoke(deviceID: peer.deviceID); throw error }
        await rdp.revoke(deviceID: peer.deviceID)
        print("PUBLIC_RELAY_RDP_STREAM_OK bytes=65536 pinned_mtls=true nla_login=false native_windows=false")
        let complete = try JSONSerialization.jsonObject(with: readLine(output.fileHandleForReading)) as? [String: Any]
        XCTAssertEqual(complete?["complete"] as? Bool, true)
        for _ in 0..<100 where process.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0) }
    }

    private func coordinator(_ identity: RelayIdentity, _ relay: RelayHTTPClient, _ peer: PairedCompanionDevice) async -> CompanionDeviceCoordinator {
        let result = CompanionDeviceCoordinator(identity: identity, relay: relay, secureFactory: PinnedTLSChannelFactory())
        await result.registerExplicitPairing(peer); return result
    }
    private func file(_ client: CompanionFileClient, _ operation: CompanionFileOperation, _ parameters: [String: Any]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: parameters, options: .withoutEscapingSlashes)
        let result = try await client.request(operation, parametersJSON: input)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
    }
    private func readExactly(_ coordinator: CompanionDeviceCoordinator, peer: String, count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            result.append(try await coordinator.receive(deviceID: peer, lane: .rdp, maximumBytes: count - result.count))
        }
        return result
    }
    private func readLine(_ handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < 4096 {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 30_000) > 0 else { throw CompanionTransportError.connectionClosed }
            var byte: UInt8 = 0
            guard Darwin.read(handle.fileDescriptor, &byte, 1) == 1 else { throw CompanionTransportError.connectionClosed }
            if byte == 10 { return result }; result.append(byte)
        }
        throw CompanionTransportError.responseTooLarge
    }
    private struct HostInfo: Decodable {
        let ready: Bool
        let companionDeviceId, publicKeySpkiBase64, controlGrantId, fileGrantId, rdpGrantId: String
    }
}

private struct CoordinatorStream: CompanionLaneByteStream {
    let coordinator: CompanionDeviceCoordinator
    let deviceID: String
    let lane: RelayLane
    func read(maximumBytes: Int) async throws -> Data { try await coordinator.receive(deviceID: deviceID, lane: lane, maximumBytes: maximumBytes) }
    func write(_ data: Data) async throws { try await coordinator.send(deviceID: deviceID, lane: lane, plaintext: data) }
    func close() async { await coordinator.revoke(deviceID: deviceID) }
}
