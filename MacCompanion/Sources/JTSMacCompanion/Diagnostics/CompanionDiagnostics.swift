import AppKit
import CryptoKit
import Darwin
import Foundation
import RemoteDesktopCore

/// A separate process path: it initializes neither host identity nor service
/// settings, never requests TCC authorization and never registers a login item.
@MainActor
enum CompanionDiagnostics {
    static func run(captureFrame: Bool) async -> Int32 {
        var report: [String: Any] = [
            "mode": captureFrame ? "capture-existing-permission" : "read-only",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "userID": getuid(),
            "consoleUserSession": CompanionPermissions.hasUserDesktopSession,
            "screenRecordingGranted": CompanionPermissions.canCapture,
            "accessibilityGranted": CompanionPermissions.canControl,
            "nativeRFBServiceAvailable": await NativeSharingServiceProbe.available(),
            "nativeEndpoint": "127.0.0.1:5900",
            "privacyPermissionRequested": false,
            "configurationModified": false,
            "globalInputSent": false
        ]
        var exitCode: Int32 = 0
        if captureFrame {
            guard CompanionPermissions.hasUserDesktopSession, CompanionPermissions.canCapture else {
                report["captureStatus"] = "permission_or_user_session_required"
                printReport(report)
                return 4
            }
            do {
                let frame = try await firstFrame()
                report["captureStatus"] = "real_frame_received"
                report["frameWidth"] = frame.width
                report["frameHeight"] = frame.height
                report["jpegBytes"] = frame.jpeg.count
                report["jpegSHA256"] = SHA256.hash(data: frame.jpeg).map { String(format: "%02x", $0) }.joined()
            } catch {
                report["captureStatus"] = "capture_failed"
                report["captureError"] = error.localizedDescription
                exitCode = 5
            }
        }
        printReport(report)
        return exitCode
    }

    private static func printReport(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }

    private static func firstFrame() async throws -> DesktopFrame {
        let capture = DesktopCapture()
        let latch = FirstFrameLatch()
        capture.onFrame = { latch.finish(.success($0)) }
        capture.onFailure = { latch.finish(.failure(DiagnosticError.failure($0))) }
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            latch.finish(.failure(DiagnosticError.failure("实际屏幕采集未在八秒内提供画面。")))
        }
        do {
            try await capture.start()
            let frame = try await latch.wait()
            deadline.cancel()
            await capture.stop()
            return frame
        } catch {
            deadline.cancel()
            await capture.stop()
            throw error
        }
    }

    private enum DiagnosticError: LocalizedError {
        case failure(String)
        var errorDescription: String? { if case .failure(let message) = self { return message }; return nil }
    }

    private final class FirstFrameLatch {
        private var result: Result<DesktopFrame, Error>?
        private var waiter: CheckedContinuation<DesktopFrame, Error>?
        func finish(_ value: Result<DesktopFrame, Error>) {
            guard result == nil else { return }
            result = value
            waiter?.resume(with: value)
            waiter = nil
        }
        func wait() async throws -> DesktopFrame {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
    }
}
