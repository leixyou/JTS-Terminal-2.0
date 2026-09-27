//
//  RemoteFileEntry.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import Foundation

enum RemoteFileKind: String, Codable, Equatable {
    case directory
    case file
    case symlink
    case other
}

struct RemoteFileEntry: Identifiable, Equatable {
    let id: String
    let kind: RemoteFileKind
    let permissions: String
    let owner: String
    let group: String
    let size: String
    let byteSize: Int64?
    let modified: String
    let name: String
    let linkTarget: String?

    var isDirectory: Bool {
        kind == .directory || permissions.first == "d"
    }

    var isRegularFile: Bool {
        kind == .file || permissions.first == "-"
    }

    var isSymbolicLink: Bool {
        kind == .symlink || permissions.first == "l"
    }

    var typeLabel: String {
        switch kind {
        case .directory:
            return "Folder"
        case .file:
            return "File"
        case .symlink:
            return "Link"
        case .other:
            return "Other"
        }
    }

    var formattedSize: String {
        guard let byteSize else { return size }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var displayName: String {
        linkTarget == nil ? name : "\(name) -> \(linkTarget!)"
    }
}

enum RemoteStructuredFileListParser {
    static func parse(_ output: String) -> [RemoteFileEntry] {
        guard let data = jsonPayload(from: output).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([StructuredEntry].self, from: data) else {
            return []
        }

        return decoded
            .filter { $0.name != "." }
            .map { entry in
                RemoteFileEntry(
                    id: entry.name,
                    kind: RemoteFileKind(rawValue: entry.kind) ?? .other,
                    permissions: entry.permissions,
                    owner: entry.owner,
                    group: entry.group,
                    size: String(entry.size),
                    byteSize: entry.size,
                    modified: entry.modified,
                    name: entry.name,
                    linkTarget: entry.linkTarget
                )
            }
    }

    private static func jsonPayload(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return trimmed
        }

        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start <= end else {
            return trimmed
        }

        return String(trimmed[start...end])
    }

    private struct StructuredEntry: Decodable {
        let name: String
        let kind: String
        let permissions: String
        let owner: String
        let group: String
        let size: Int64
        let modified: String
        let linkTarget: String?
    }
}

enum RemoteFileListParser {
    static func parse(_ output: String) -> [RemoteFileEntry] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0)) }
            .filter { $0.name != "." }
    }

    static func parseLine(_ line: String) -> RemoteFileEntry? {
        guard !line.hasPrefix("total ") else { return nil }

        let pattern = #"^(\S+)\s+\d+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+\s+\S+\s+\S+)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 7 else {
            return nil
        }

        func value(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: line) else { return "" }
            return String(line[range])
        }

        let rawName = value(6)
        let linkParts = rawName.components(separatedBy: " -> ")
        let name = linkParts.first ?? rawName
        let linkTarget = linkParts.count > 1 ? linkParts.dropFirst().joined(separator: " -> ") : nil

        return RemoteFileEntry(
            id: rawName,
            kind: kind(from: value(1)),
            permissions: value(1),
            owner: value(2),
            group: value(3),
            size: value(4),
            byteSize: Int64(value(4)),
            modified: value(5),
            name: name,
            linkTarget: linkTarget
        )
    }

    private static func kind(from permissions: String) -> RemoteFileKind {
        switch permissions.first {
        case "d":
            return .directory
        case "l":
            return .symlink
        case "-":
            return .file
        default:
            return .other
        }
    }
}
