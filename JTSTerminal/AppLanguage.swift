//
//  AppLanguage.swift
//  JTSTerminal
//
//  Created by Codex on 2026/5/20.
//

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let storageKey = "appLanguage.v1"
    static let defaultLanguage = AppLanguage.english

    var id: String { rawValue }

    var localeIdentifier: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .english:
            return "EN"
        case .simplifiedChinese:
            return "中"
        }
    }

    static func resolved(from rawValue: String) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? defaultLanguage
    }

    static var stored: AppLanguage {
        resolved(from: UserDefaults.standard.string(forKey: storageKey) ?? defaultLanguage.rawValue)
    }

    func localized(_ english: String, _ simplifiedChinese: String) -> String {
        switch self {
        case .english:
            return english
        case .simplifiedChinese:
            return simplifiedChinese
        }
    }
}

#if JTS_UI_TEST_SUPPORT
enum UITestAppLanguageBootstrap {
    static let initialLanguageEnvironmentKey =
        "JTS_TERMINAL_UI_TEST_INITIAL_LANGUAGE"
    nonisolated static let isolatedApplicationBundleIdentifier =
        "com.lljts.JTSTerminal.UITesting"

    @discardableResult
    static func apply(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard environment["JTS_TERMINAL_UI_TESTING"] == "1",
              bundleIdentifier == isolatedApplicationBundleIdentifier,
              let rawValue = environment[initialLanguageEnvironmentKey],
              let language = AppLanguage(rawValue: rawValue) else {
            return false
        }
        defaults.set(language.rawValue, forKey: AppLanguage.storageKey)
        return true
    }
}
#endif

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.defaultLanguage
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

extension RemoteConnectionType {
    func displayName(language: AppLanguage) -> String {
        switch self {
        case .ssh:
            return "SSH"
        case .localShell:
            return language.localized("Local Shell", "本地 Shell")
        case .macDesktop:
            return AppReleasePolicy.includesNativeRDP ? language.localized("Mac Desktop", "Mac 桌面") : language.localized("Unsupported", "不支持")
        case .rdp:
            #if ENABLE_RDP_2
            return "RDP"
            #else
            return language.localized("Unsupported", "不支持")
            #endif
        }
    }
}

extension RemoteSession {
    func localizedAddress(language: AppLanguage) -> String {
        switch connectionType {
        case .ssh:
            guard !host.isEmpty else { return language.localized("Host not configured", "未配置主机") }
            return "\(username)@\(host):\(port)"
        case .localShell:
            return language.localized("Local shell", "本地 Shell")
        case .rdp, .macDesktop:
            guard !host.isEmpty else { return language.localized("Host not configured", "未配置主机") }
            return "\(host):\(port)"
        }
    }

    func localizedFolderDisplayName(language: AppLanguage) -> String {
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFolder.isEmpty ? language.localized("Ungrouped", "未分组") : trimmedFolder
    }
}
