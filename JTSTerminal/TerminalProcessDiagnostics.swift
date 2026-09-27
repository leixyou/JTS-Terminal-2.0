import Foundation

/// Converts the Darwin waitpid status word at the process-backend boundary.
/// Signal exits use the shell convention (128 + signal); missing, stopped, or
/// continued statuses do not describe a completed process.
enum TerminalProcessExitStatus {
    nonisolated static func exitCode(fromWaitStatus status: Int32?) -> Int32? {
        guard let status, status >= 0 else { return nil }
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        guard signal != 0x7f else { return nil }
        return 128 + signal
    }
}

/// Formats only JTS-generated diagnostics. Remote PTY output must not pass
/// through this formatter: its CR, LF, and terminal control bytes are data.
enum TerminalSessionDiagnosticFormatter {
    nonisolated static func suffix(for message: String, after transcript: String) -> String {
        let prefix: String
        switch transcript.unicodeScalars.last?.value {
        case nil:
            prefix = ""
        case 10:
            // LF alone advances a raw terminal without resetting its column.
            prefix = transcript.hasSuffix("\r\n") ? "" : "\r"
        case 13:
            prefix = "\n"
        default:
            prefix = "\r\n"
        }

        let terminalMessage = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        return "\(prefix)[\(terminalMessage)]\r\n"
    }
}
