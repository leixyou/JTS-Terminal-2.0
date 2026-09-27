//
//  MobileModels.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct MobileServerProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var username: String
    var port: Int
    var remotePath: String
    var identityFile: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "New Server",
        host: String = "",
        username: String = "",
        port: Int = 22,
        remotePath: String = "~",
        identityFile: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.port = port
        self.remotePath = remotePath
        self.identityFile = identityFile
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var account: String {
        "\(username.trimmingCharacters(in: .whitespacesAndNewlines))@\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name
    }

    var address: String {
        guard isConnectable else { return "Host not configured" }
        return "\(username)@\(host):\(port)"
    }

    var isConnectable: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        port > 0 &&
        port <= 65_535
    }

    mutating func touch() {
        updatedAt = Date()
    }
}

struct MobileSSHCredentials: Equatable, Sendable {
    var password: String?
    var privateKey: String?
    var privateKeyPassphrase: String?

    var hasPassword: Bool {
        !(password ?? "").isEmpty
    }

    var hasPrivateKey: Bool {
        !(privateKey ?? "").isEmpty
    }
}

enum MobileServerProfileCodec {
    static let exportedType = UTType.json
    static let defaultFileName = "JTS-Terminal-iOS-sessions.json"

    private struct Document: Codable {
        var version: Int
        var exportedAt: Date
        var sessions: [Profile]
    }

    private struct Profile: Codable {
        var id: UUID?
        var name: String
        var host: String?
        var username: String?
        var port: Int?
        var connectionType: String?
        var identityFile: String?
        var jumpHost: String?
        var folder: String?
        var enableX11Forwarding: Bool?
        var remotePath: String?
        var mcpEnabled: Bool?
        var mcpAlwaysAllowTerminalControl: Bool?
        var mcpAlias: String?

        init(_ profile: MobileServerProfile) {
            id = profile.id
            name = profile.name
            host = profile.host
            username = profile.username
            port = profile.port
            connectionType = "SSH"
            identityFile = profile.identityFile
            jumpHost = ""
            folder = ""
            enableX11Forwarding = false
            remotePath = profile.remotePath
            mcpEnabled = false
            mcpAlwaysAllowTerminalControl = false
            mcpAlias = ""
        }

        func mobileProfile() -> MobileServerProfile? {
            let resolvedType = (connectionType ?? "SSH")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard resolvedType.isEmpty || resolvedType == "ssh" else {
                return nil
            }

            return MobileServerProfile(
                id: id ?? UUID(),
                name: name,
                host: host ?? "",
                username: username ?? "",
                port: port ?? 22,
                remotePath: remotePath ?? "~",
                identityFile: identityFile ?? ""
            )
        }
    }

    static func encode(_ profiles: [MobileServerProfile]) throws -> Data {
        let document = Document(
            version: 1,
            exportedAt: Date(),
            sessions: profiles.map(Profile.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> [MobileServerProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        return document.sessions.compactMap { $0.mobileProfile() }
    }
}

struct MobileProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct MobileDownloadedFileDocument: FileDocument, Equatable {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum MobileRemoteFileKind: String, Codable, CaseIterable, Sendable {
    case directory
    case regular
    case symlink
    case other

    var systemImage: String {
        switch self {
        case .directory:
            return "folder"
        case .regular:
            return "doc"
        case .symlink:
            return "link"
        case .other:
            return "questionmark.square"
        }
    }
}

struct MobileRemoteFileEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var kind: MobileRemoteFileKind
    var byteSize: UInt64?
    var permissions: UInt32?
    var modifiedAt: Date?

    var isDirectory: Bool {
        kind == .directory
    }

    var formattedSize: String {
        guard let byteSize else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    var permissionsText: String {
        guard let permissions else { return "-" }
        return String(format: "%04o", permissions & 0o7777)
    }
}

enum MobileRemotePath {
    static func child(_ name: String, in directory: String) -> String {
        if directory == "/" {
            return "/" + name
        }

        if directory.hasSuffix("/") {
            return directory + name
        }

        return directory + "/" + name
    }

    static func parent(of path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/", trimmed != "~" else {
            return "~"
        }

        let url = URL(fileURLWithPath: trimmed)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
}

enum MobileConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .failed:
            return "Failed"
        }
    }
}

extension String {
    var mobileNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
