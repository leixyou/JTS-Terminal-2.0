import Testing
@testable import JTSTerminal

struct TerminalProcessDiagnosticsTests {
    @Test func normalExitCodesAreDecodedFromWaitStatus() {
        for code: Int32 in [0, 1, 42, 127, 255] {
            #expect(TerminalProcessExitStatus.exitCode(fromWaitStatus: code << 8) == code)
        }
    }

    @Test func signalExitsUseShellConventionIncludingCoreDumpBit() {
        #expect(TerminalProcessExitStatus.exitCode(fromWaitStatus: 9) == 137)
        #expect(TerminalProcessExitStatus.exitCode(fromWaitStatus: 15) == 143)
        #expect(TerminalProcessExitStatus.exitCode(fromWaitStatus: 11 | 0x80) == 139)
    }

    @Test func missingAndNonterminalStatusesRemainUnknown() {
        for status: Int32? in [nil, -1, (19 << 8) | 0x7f, 0xffff] {
            #expect(TerminalProcessExitStatus.exitCode(fromWaitStatus: status) == nil)
        }
    }

    @Test func diagnosticStartsAtColumnZeroForEveryPreviousLineEnding() {
        let cases = [
            ("", "[ready]\r\n"),
            ("remote", "\r\n[ready]\r\n"),
            ("remote\n", "\r[ready]\r\n"),
            ("remote\r", "\n[ready]\r\n"),
            ("remote\r\n", "[ready]\r\n"),
        ]
        for (prior, expectedSuffix) in cases {
            #expect(TerminalSessionDiagnosticFormatter.suffix(for: "ready", after: prior) == expectedSuffix)
        }
    }

    @Test func multilineDiagnosticNormalizesOnlyItsOwnLineEndings() {
        let message = "first\nsecond\r\nthird\rfourth"
        #expect(TerminalSessionDiagnosticFormatter.suffix(for: message, after: "")
            == "[first\r\nsecond\r\nthird\r\nfourth]\r\n")
    }

    @Test func consecutiveDiagnosticsDoNotAddBlankLinesOrCarriageReturns() {
        let first = TerminalSessionDiagnosticFormatter.suffix(for: "first", after: "")
        let second = TerminalSessionDiagnosticFormatter.suffix(for: "second", after: first)
        #expect(first + second == "[first]\r\n[second]\r\n")
    }

    @Test func appendingDiagnosticPreservesRemoteControlBytes() {
        let remote = "\u{1b}[31m远端\n  second\rprogress\u{1b}[0m"
        let combined = remote + TerminalSessionDiagnosticFormatter.suffix(for: "exit 255", after: remote)
        #expect(Array(combined.utf8.prefix(remote.utf8.count)) == Array(remote.utf8))
        #expect(combined.hasSuffix("\r\n[exit 255]\r\n"))
    }
}
