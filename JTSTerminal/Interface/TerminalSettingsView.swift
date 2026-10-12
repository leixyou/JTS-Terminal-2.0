//
//  TerminalSettingsView.swift
//  JTSTerminal
//

import SwiftUI

/// Terminal colors: always dark (the previous look), always light, or
/// following the system appearance.
enum TerminalColorScheme: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .dark:
            return language.localized("Dark", "深色")
        case .light:
            return language.localized("Light", "浅色")
        case .system:
            return language.localized("Match System", "跟随系统")
        }
    }

    func usesDarkColors(systemScheme: ColorScheme) -> Bool {
        switch self {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            return systemScheme == .dark
        }
    }
}

enum TerminalAppearanceSettings {
    static let fontSizeKey = "terminal.fontSize.v1"
    static let colorSchemeKey = "terminal.colorScheme.v1"
    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 10...24

    static func clampedFontSize(_ value: Double) -> Double {
        min(max(value.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static func colorScheme(rawValue: String) -> TerminalColorScheme {
        TerminalColorScheme(rawValue: rawValue) ?? .dark
    }
}

struct TerminalSettingsView: View {
    @Environment(\.appLanguage) private var language
    @AppStorage(TerminalAppearanceSettings.fontSizeKey) private var fontSize = TerminalAppearanceSettings.defaultFontSize
    @AppStorage(TerminalAppearanceSettings.colorSchemeKey) private var colorSchemeRawValue = TerminalColorScheme.dark.rawValue

    var body: some View {
        Form {
            Section {
                Picker(language.localized("Colors", "颜色"), selection: $colorSchemeRawValue) {
                    ForEach(TerminalColorScheme.allCases) { scheme in
                        Text(scheme.title(language: language))
                            .tag(scheme.rawValue)
                    }
                }
                .accessibilityIdentifier("settings-terminal-color-scheme-picker")

                LabeledContent(language.localized("Font size", "字号")) {
                    Stepper(
                        value: Binding(
                            get: { TerminalAppearanceSettings.clampedFontSize(fontSize) },
                            set: { fontSize = TerminalAppearanceSettings.clampedFontSize($0) }
                        ),
                        in: TerminalAppearanceSettings.fontSizeRange,
                        step: 1
                    ) {
                        Text("\(Int(TerminalAppearanceSettings.clampedFontSize(fontSize))) pt")
                            .monospacedDigit()
                    }
                    .accessibilityIdentifier("settings-terminal-font-size-stepper")
                }
            } footer: {
                Text(language.localized(
                    "Applies to all open and new terminals.",
                    "适用于所有已打开和新打开的终端。"
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
