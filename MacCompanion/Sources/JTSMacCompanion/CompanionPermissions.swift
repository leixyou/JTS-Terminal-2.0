import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import ServiceManagement

enum CompanionLoginStatus: Equatable {
    case enabled, requiresApproval, notRegistered, unavailable

    var detail: String {
        switch self {
        case .enabled: return "下次登录此 Mac 时自动打开程序。"
        case .requiresApproval: return "请在系统设置的“登录项”中允许 JTS Mac Companion。"
        case .notRegistered: return "尚未启用登录时打开。"
        case .unavailable: return "当前程序位置不支持登录项。请安装到“应用程序”后重试。"
        }
    }
}

enum CompanionPermissions {
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }
    static var canControl: Bool { AXIsProcessTrusted() }

    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    static func openSharingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openPrivacy(_ pane: String) {
        guard ["Privacy_ScreenCapture", "Privacy_Accessibility"].contains(pane),
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // Capture and input always belong to a logged-in desktop user, never root.
    static var hasUserDesktopSession: Bool {
        guard getuid() != 0, let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
    }

    static var loginStatus: CompanionLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    static var startsAtLogin: Bool { loginStatus == .enabled }
    static func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    static func setStartsAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}
