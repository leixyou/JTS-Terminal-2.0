import Foundation
import JTSCompanionIPC
import XCTest

/// Hosted RDP2 tests: real signed sandbox helper, no relay traffic, keys, grants or Windows actions.
final class CompanionTransportXPCTests: XCTestCase {
    private let service = "com.lljts.JTSTerminal.CompanionTransportService"
    private let requirement = "anchor apple generic and identifier \"com.lljts.JTSTerminal.CompanionTransportService\" and certificate leaf[subject.OU] = \"YOURTEAMID\""

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(Bundle.main.bundleURL.pathExtension != "app",
                      "This integration suite requires the signed application host; run it with xcodebuild test.")
    }

    func testRealEmbeddedHelperRepliesFromDisconnectedState() async throws {
        try await assertHelperReady()
    }

    private func assertHelperReady() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/JTCompanionTransportService.xpc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path), "The actual test host must embed the new helper")
        let request = CompanionIPCRequest(id: UUID(), connectionID: UUID(), operation: .state,
            payload: try CompanionIPCCodec.encodePayload(CompanionIPCEmpty()))
        let bytes = try await exchange(try CompanionIPCCodec.encodeRequest(request), requirement: requirement)
        let response = try CompanionIPCCodec.decodeReply(bytes)
        XCTAssertTrue(response.ok); XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.connectionID, request.connectionID)
        let state = try CompanionIPCCodec.decodePayload(XCTUnwrap(response.payload), as: CompanionIPCState.self)
        XCTAssertEqual(state.phase, "disconnected"); XCTAssertNil(state.sessionID)
    }

    func testIncorrectHelperIdentityRequirementIsRejected() async throws {
        // A launch crash must not masquerade as a successful identity-rejection test.
        try await assertHelperReady()
        let request = CompanionIPCRequest(id: UUID(), connectionID: UUID(), operation: .state,
            payload: try CompanionIPCCodec.encodePayload(CompanionIPCEmpty()))
        do {
            _ = try await exchange(CompanionIPCCodec.encodeRequest(request),
                requirement: "anchor apple generic and identifier \"com.lljts.NOT-THE-COMPANION-HELPER\"")
            XCTFail("Wrong helper signing identity accepted")
        } catch { XCTAssertEqual(error as? ProbeError, .connectionRejected) }
    }

    func testMalformedEnvelopeClosesActualConnection() async throws {
        try await assertHelperReady()
        do {
            _ = try await exchange(Data("{}".utf8), requirement: requirement)
            XCTFail("Malformed request returned a fabricated successful reply")
        } catch { XCTAssertEqual(error as? ProbeError, .connectionRejected) }
    }

    private func exchange(_ data: Data, requirement: String) async throws -> Data {
        let connection = NSXPCConnection(serviceName: service)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = CompanionIPCInterface.make()
        defer { connection.invalidate() }
        let probe = Probe()
        connection.invalidationHandler = { probe.finish(.failure(ProbeError.connectionRejected)) }
        connection.interruptionHandler = { probe.finish(.failure(ProbeError.connectionRejected)) }
        connection.resume()
        return try await withCheckedThrowingContinuation { continuation in
            probe.install(continuation)
            let deadline = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled { probe.finish(.failure(ProbeError.timedOut)); connection.invalidate() }
            }
            probe.deadline(deadline)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                probe.finish(.failure(ProbeError.connectionRejected))
            }) as? CompanionTransportServiceProtocol else {
                probe.finish(.failure(ProbeError.connectionRejected)); return
            }
            proxy.perform(data) { reply in probe.finish(.success(reply)) }
        }
    }

    private enum ProbeError: Error, Equatable { case connectionRejected, timedOut }
    private nonisolated final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var result: Result<Data, Error>?
        private var timer: Task<Void, Never>?

        func install(_ value: CheckedContinuation<Data, Error>) {
            lock.lock()
            if let result { lock.unlock(); value.resume(with: result) }
            else { continuation = value; lock.unlock() }
        }
        func deadline(_ value: Task<Void, Never>) {
            lock.lock()
            if result != nil { lock.unlock(); value.cancel() }
            else { timer = value; lock.unlock() }
        }
        func finish(_ value: Result<Data, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let pending = continuation; continuation = nil
            let timeout = timer; timer = nil
            lock.unlock()
            timeout?.cancel(); pending?.resume(with: value)
        }
    }
}
