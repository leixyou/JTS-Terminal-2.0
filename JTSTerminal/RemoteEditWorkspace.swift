//
//  RemoteEditWorkspace.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/30.
//

import Foundation

struct RemoteEditDraft: Identifiable, Equatable {
    let id: UUID
    let sessionKey: String
    let remotePath: String
    let localURL: URL
    let createdAt: Date

    var remoteName: String {
        (remotePath as NSString).lastPathComponent.nilIfEmpty ?? remotePath
    }

    var summary: String {
        "\(remotePath) <-> \(localURL.path)"
    }
}

enum RemoteEditWorkspace {
    static let folderName = "JTSTerminalRemoteEdits"

    static func makeDraft(
        sessionKey: String,
        remotePath: String,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        date: Date = Date(),
        id: UUID = UUID()
    ) throws -> RemoteEditDraft {
        let root = rootDirectory ?? defaultRootDirectory(fileManager: fileManager)
        let directory = root
            .appendingPathComponent(safeDirectoryName(forSessionKey: sessionKey), isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let localURL = directory.appendingPathComponent(
            safeFilename(forRemotePath: remotePath),
            isDirectory: false
        )

        return RemoteEditDraft(
            id: id,
            sessionKey: sessionKey,
            remotePath: remotePath,
            localURL: localURL,
            createdAt: date
        )
    }

    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    static func safeFilename(forRemotePath remotePath: String) -> String {
        let lastComponent = (remotePath as NSString).lastPathComponent
        let trimmed = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else {
            return "remote-file"
        }

        let sanitized = trimmed
            .map { character in
                character.isAllowedRemoteEditPathCharacter ? character : "_"
            }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized.nilIfEmpty ?? "remote-file"
    }

    static func safeDirectoryName(forSessionKey sessionKey: String) -> String {
        let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "session"
        }

        let sanitized = trimmed
            .map { character in
                character.isAllowedRemoteEditPathCharacter ? character : "_"
            }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized.nilIfEmpty ?? "session"
    }
}

private extension Character {
    var isAllowedRemoteEditPathCharacter: Bool {
        isLetter || isNumber || self == "." || self == "-" || self == "_" || self == " "
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
