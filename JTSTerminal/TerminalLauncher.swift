//
//  TerminalLauncher.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import AppKit
import Foundation

enum TerminalLauncher {
    static func openSSHSession(_ session: RemoteSession) throws {
        let command = SSHCommandBuilder.terminalSSHCommand(for: session)
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
