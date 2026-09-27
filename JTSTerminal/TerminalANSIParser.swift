//
//  TerminalANSIParser.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/30.
//

import Foundation

enum TerminalANSIColor: Equatable {
    case basic(Int)
    case indexed(Int)
    case rgb(Int, Int, Int)
}

struct TerminalTextStyle: Equatable {
    var foreground: TerminalANSIColor?
    var background: TerminalANSIColor?
    var isBold = false
    var isDim = false
    var isInverse = false

    static let normal = TerminalTextStyle()
}

struct TerminalTextRun: Equatable {
    var text: String
    var style: TerminalTextStyle
}

struct TerminalDisplayLine: Equatable {
    var runs: [TerminalTextRun]

    var text: String {
        runs.map(\.text).joined()
    }
}

struct TerminalDisplayFrame: Equatable {
    var lines: [TerminalDisplayLine]
    var cursorRow: Int
    var cursorColumn: Int
    var maxColumnCount: Int

    var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

enum TerminalANSIParser {
    static func render(_ text: String, columns: Int = 120) -> TerminalDisplayFrame {
        var parser = Parser(columns: max(columns, 1))
        parser.consume(text)
        return parser.frame()
    }
}

enum TerminalTranscriptDelta: Equatable {
    case none
    case append(String)
    case reset(String)
}

struct TerminalTranscriptDeltaTracker {
    private(set) var lastTranscript = ""

    mutating func update(_ transcript: String) -> TerminalTranscriptDelta {
        defer {
            lastTranscript = transcript
        }

        guard transcript != lastTranscript else {
            return .none
        }

        guard transcript.hasPrefix(lastTranscript) else {
            return .reset(transcript)
        }

        return .append(String(transcript.dropFirst(lastTranscript.count)))
    }

    mutating func reset() {
        lastTranscript = ""
    }
}

private struct TerminalCell: Equatable {
    var character: Character
    var style: TerminalTextStyle
}

private struct Parser {
    let columns: Int
    private var rows: [[TerminalCell?]] = [[]]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var style = TerminalTextStyle.normal
    private var maxColumnCount = 0

    init(columns: Int) {
        self.columns = columns
    }

    mutating func consume(_ text: String) {
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            switch character {
            case "\u{001B}":
                index = handleEscape(in: text, from: index)
            case "\r":
                cursorColumn = 0
                index = text.index(after: index)
            case "\n":
                cursorRow += 1
                ensureRow(cursorRow)
                index = text.index(after: index)
            case "\u{0008}":
                cursorColumn = max(cursorColumn - 1, 0)
                index = text.index(after: index)
            case "\t":
                let nextStop = ((cursorColumn / 8) + 1) * 8
                cursorColumn = min(nextStop, columns - 1)
                index = text.index(after: index)
            case "\u{0007}":
                index = text.index(after: index)
            default:
                write(character)
                index = text.index(after: index)
            }
        }
    }

    mutating func frame() -> TerminalDisplayFrame {
        let displayRows = rows.isEmpty ? [[]] : rows
        let lines = displayRows.map { cells in
            line(from: cells)
        }

        return TerminalDisplayFrame(
            lines: lines.isEmpty ? [TerminalDisplayLine(runs: [])] : lines,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            maxColumnCount: max(maxColumnCount, columns)
        )
    }

    private mutating func write(_ character: Character) {
        if cursorColumn >= columns {
            cursorColumn = 0
            cursorRow += 1
        }

        ensureCell(row: cursorRow, column: cursorColumn)
        rows[cursorRow][cursorColumn] = TerminalCell(character: character, style: style)
        cursorColumn += 1
        maxColumnCount = max(maxColumnCount, cursorColumn)
    }

    private mutating func handleEscape(in text: String, from start: String.Index) -> String.Index {
        let index = text.index(after: start)
        guard index < text.endIndex else { return index }

        switch text[index] {
        case "[":
            return handleCSI(in: text, from: text.index(after: index))
        case "]":
            return skipOSC(in: text, from: text.index(after: index))
        case "7":
            savedCursorRow = cursorRow
            savedCursorColumn = cursorColumn
            return text.index(after: index)
        case "8":
            cursorRow = savedCursorRow
            cursorColumn = savedCursorColumn
            ensureRow(cursorRow)
            return text.index(after: index)
        case "c":
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
            style = .normal
            return text.index(after: index)
        case "(", ")", "*", "+", "-", ".", "/":
            return text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
        default:
            return text.index(after: index)
        }
    }

    private mutating func handleCSI(in text: String, from start: String.Index) -> String.Index {
        var index = start
        var sequence = ""

        while index < text.endIndex {
            let scalar = text[index].unicodeScalars.first?.value ?? 0
            if scalar >= 0x40, scalar <= 0x7e {
                let command = text[index]
                applyCSI(command: command, rawParameters: sequence)
                return text.index(after: index)
            }

            sequence.append(text[index])
            index = text.index(after: index)
        }

        return index
    }

    private mutating func skipOSC(in text: String, from start: String.Index) -> String.Index {
        var index = start

        while index < text.endIndex {
            if text[index] == "\u{0007}" {
                return text.index(after: index)
            }

            if text[index] == "\u{001B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\\" {
                    return text.index(after: next)
                }
            }

            index = text.index(after: index)
        }

        return index
    }

    private mutating func applyCSI(command: Character, rawParameters: String) {
        let cleanParameters = rawParameters
            .trimmingCharacters(in: CharacterSet(charactersIn: "?<>= "))
            .replacingOccurrences(of: ":", with: ";")
        let values = cleanParameters
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }
        let params = values.isEmpty ? [nil] : values

        func value(_ index: Int, default defaultValue: Int) -> Int {
            guard index < params.count, let value = params[index], value > 0 else {
                return defaultValue
            }
            return value
        }

        switch command {
        case "m":
            applySGR(params.compactMap { $0 })
        case "A":
            cursorRow = max(cursorRow - value(0, default: 1), 0)
        case "B":
            cursorRow += value(0, default: 1)
            ensureRow(cursorRow)
        case "C":
            cursorColumn = min(cursorColumn + value(0, default: 1), columns - 1)
        case "D":
            cursorColumn = max(cursorColumn - value(0, default: 1), 0)
        case "E":
            cursorRow += value(0, default: 1)
            cursorColumn = 0
            ensureRow(cursorRow)
        case "F":
            cursorRow = max(cursorRow - value(0, default: 1), 0)
            cursorColumn = 0
        case "G":
            cursorColumn = min(value(0, default: 1) - 1, columns - 1)
        case "H", "f":
            cursorRow = max(value(0, default: 1) - 1, 0)
            cursorColumn = min(max(value(1, default: 1) - 1, 0), columns - 1)
            ensureRow(cursorRow)
        case "J":
            clearScreen(mode: params.first ?? 0)
        case "K":
            clearLine(mode: params.first ?? 0)
        case "s":
            savedCursorRow = cursorRow
            savedCursorColumn = cursorColumn
        case "u":
            cursorRow = savedCursorRow
            cursorColumn = savedCursorColumn
            ensureRow(cursorRow)
        default:
            break
        }
    }

    private mutating func applySGR(_ params: [Int]) {
        let params = params.isEmpty ? [0] : params
        var index = 0

        while index < params.count {
            let parameter = params[index]

            switch parameter {
            case 0:
                style = .normal
            case 1:
                style.isBold = true
            case 2:
                style.isDim = true
            case 22:
                style.isBold = false
                style.isDim = false
            case 7:
                style.isInverse = true
            case 27:
                style.isInverse = false
            case 30...37:
                style.foreground = .basic(parameter - 30)
            case 39:
                style.foreground = nil
            case 40...47:
                style.background = .basic(parameter - 40)
            case 49:
                style.background = nil
            case 90...97:
                style.foreground = .basic(parameter - 90 + 8)
            case 100...107:
                style.background = .basic(parameter - 100 + 8)
            case 38, 48:
                let isForeground = parameter == 38
                if let color = extendedColor(from: params, startIndex: index + 1) {
                    if isForeground {
                        style.foreground = color.value
                    } else {
                        style.background = color.value
                    }
                    index = color.nextIndex - 1
                }
            default:
                break
            }

            index += 1
        }
    }

    private func extendedColor(from params: [Int], startIndex: Int) -> (value: TerminalANSIColor, nextIndex: Int)? {
        guard startIndex < params.count else { return nil }

        switch params[startIndex] {
        case 5:
            guard startIndex + 1 < params.count else { return nil }
            return (.indexed(params[startIndex + 1]), startIndex + 2)
        case 2:
            guard startIndex + 3 < params.count else { return nil }
            return (
                .rgb(params[startIndex + 1], params[startIndex + 2], params[startIndex + 3]),
                startIndex + 4
            )
        default:
            return nil
        }
    }

    private mutating func clearScreen(mode: Int?) {
        switch mode ?? 0 {
        case 0:
            clearLine(mode: 0)
            if cursorRow + 1 < rows.count {
                for row in (cursorRow + 1)..<rows.count {
                    rows[row] = []
                }
            }
        case 1:
            if cursorRow > 0 {
                for row in 0..<cursorRow {
                    rows[row] = []
                }
            }
            clearLine(mode: 1)
        case 2, 3:
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
        default:
            break
        }
    }

    private mutating func clearLine(mode: Int?) {
        ensureRow(cursorRow)

        switch mode ?? 0 {
        case 0:
            guard cursorColumn < rows[cursorRow].count else { return }
            rows[cursorRow].removeSubrange(cursorColumn..<rows[cursorRow].count)
        case 1:
            ensureCell(row: cursorRow, column: cursorColumn)
            for column in 0...cursorColumn {
                rows[cursorRow][column] = nil
            }
        case 2:
            rows[cursorRow] = []
        default:
            break
        }
    }

    private mutating func ensureRow(_ row: Int) {
        while rows.count <= row {
            rows.append([])
        }
    }

    private mutating func ensureCell(row: Int, column: Int) {
        ensureRow(row)
        while rows[row].count <= column {
            rows[row].append(nil)
        }
    }

    private func line(from cells: [TerminalCell?]) -> TerminalDisplayLine {
        let trimmedCells = cells.trimmingTrailingEmptyCells()
        guard !trimmedCells.isEmpty else {
            return TerminalDisplayLine(runs: [])
        }

        var runs: [TerminalTextRun] = []
        var currentText = ""
        var currentStyle = trimmedCells.first??.style ?? .normal

        func flush() {
            guard !currentText.isEmpty else { return }
            runs.append(TerminalTextRun(text: currentText, style: currentStyle))
            currentText = ""
        }

        for cell in trimmedCells {
            let character = cell?.character ?? " "
            let cellStyle = cell?.style ?? .normal

            if cellStyle != currentStyle {
                flush()
                currentStyle = cellStyle
            }

            currentText.append(character)
        }

        flush()
        return TerminalDisplayLine(runs: runs)
    }
}

private extension Array where Element == TerminalCell? {
    func trimmingTrailingEmptyCells() -> [TerminalCell?] {
        var result = self
        while let last = result.last, last == nil {
            result.removeLast()
        }
        return result
    }
}
