//
//  ServerProfileTransfer.swift
//  JTSTerminal
//

import AppKit
import SwiftData
import UniformTypeIdentifiers

/// File > Import Servers… and File > Export Servers…. Profiles move as JSON;
/// saved passwords, keys and device credentials never leave the vault.
@MainActor
enum ServerProfileTransfer {
    static func export(_ sessions: [RemoteSession], language: AppLanguage) {
        guard !sessions.isEmpty else { return }
        let data: Data
        do {
            data = try SessionProfileCodec.encode(sessions: sessions)
        } catch {
            showFailure(
                title: language.localized("Could Not Export Servers", "无法导出服务器"),
                error: error,
                language: language
            )
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName(for: sessions)).json"
        panel.allowedContentTypes = [.json]
        panel.message = language.localized(
            "Exported servers never include saved passwords or keys.",
            "导出的服务器不包含已保存的密码或密钥。"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showFailure(
                title: language.localized("Could Not Export Servers", "无法导出服务器"),
                error: error,
                language: language
            )
        }
    }

    /// Returns the imported sessions so the caller can select the first one.
    @discardableResult
    static func importServers(into modelContext: ModelContext, language: AppLanguage) -> [RemoteSession] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = language.localized("Import", "导入")
        panel.message = language.localized(
            "Choose a JTS Terminal server export. Passwords are never imported.",
            "选择 JTS Terminal 导出的服务器文件。密码不会被导入。"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return [] }

        let imported: [RemoteSession]
        do {
            let profiles = try SessionProfileCodec.decode(Data(contentsOf: url))
            imported = SessionProfileImporter.insert(profiles, into: modelContext)
            try modelContext.save()
        } catch {
            showFailure(
                title: language.localized("Could Not Import Servers", "无法导入服务器"),
                error: error,
                language: language
            )
            return []
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = language.localized(
            "Imported \(imported.count) server(s)",
            "已导入 \(imported.count) 台服务器"
        )
        alert.informativeText = language.localized(
            "Passwords are never imported. JTS Terminal asks before the first password-based connection.",
            "密码不会被导入。首次使用密码连接前，JTS Terminal 会询问。"
        )
        alert.addButton(withTitle: language.localized("OK", "好"))
        alert.runModal()
        return imported
    }

    static func suggestedName(for sessions: [RemoteSession]) -> String {
        guard sessions.count == 1, let session = sessions.first else {
            return "jts-terminal-mac-sessions"
        }
        let name = [session.name, session.host]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "session"
        return name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func showFailure(title: String, error: Error, language: AppLanguage) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: language.localized("OK", "好"))
        alert.runModal()
    }
}
