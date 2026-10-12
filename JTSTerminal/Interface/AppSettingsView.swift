//
//  AppSettingsView.swift
//  JTSTerminal
//

import SwiftUI

/// The app's Settings window (JTS Terminal > Settings…, ⌘,).
struct AppSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.defaultLanguage.rawValue

    private var language: AppLanguage {
        AppLanguage.resolved(from: languageRawValue)
    }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label(language.localized("General", "通用"), systemImage: "gearshape")
                }

            TerminalSettingsView()
                .tabItem {
                    Label(language.localized("Terminal", "终端"), systemImage: "terminal")
                }

            MCPSettingsView()
                .tabItem {
                    Label("MCP", systemImage: "point.3.connected.trianglepath.dotted")
                }

            #if ENABLE_RDP_2
            RelayStationsSettingsView()
                .tabItem {
                    Label(language.localized("Relay Stations", "中转站"), systemImage: "network")
                }
            #endif
        }
        .environment(\.appLanguage, language)
        .environment(\.locale, Locale(identifier: language.localeIdentifier))
    }
}

struct GeneralSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.defaultLanguage.rawValue
    @AppStorage(WelcomeGuidePolicy.storageKey) private var hasSeenWelcomeGuide = false

    private var language: AppLanguage {
        AppLanguage.resolved(from: languageRawValue)
    }

    var body: some View {
        Form {
            Section {
                Picker(language.localized("Language", "语言"), selection: $languageRawValue) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName)
                            .tag(option.rawValue)
                    }
                }
                .accessibilityIdentifier("settings-language-picker")
            }

            Section {
                LabeledContent(language.localized("Welcome guide", "欢迎指南")) {
                    Button(language.localized("Show Again at Next Launch", "下次启动时再次显示")) {
                        hasSeenWelcomeGuide = false
                    }
                    .disabled(!hasSeenWelcomeGuide)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
