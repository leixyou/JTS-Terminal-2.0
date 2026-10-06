//
//  SessionProfileCodec.swift
//  JTSTerminal
//
//  Created by Codex on 2026/4/29.
//

import Foundation
import SwiftData

nonisolated struct RemoteSessionProfileDocument: Codable, Equatable {
    var version = 2
    var exportedAt = Date()
    var sessions: [RemoteSessionProfile]
}

nonisolated struct RemoteSessionProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var username: String
    var port: Int
    var connectionType: RemoteConnectionType
    var identityFile: String
    var jumpHost: String
    var folder: String
    var enableX11Forwarding: Bool
    var remotePath: String
    var rdpProfile: RDPConnectionProfile?
    var mcpEnabled: Bool
    var mcpAlwaysAllowTerminalControl: Bool
    var mcpAlias: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case username
        case port
        case rdpPort
        case connectionType
        case identityFile
        case jumpHost
        case folder
        case enableX11Forwarding
        case remotePath
        case rdpProfile
        case mcpEnabled
        case mcpAlwaysAllowTerminalControl
        case mcpAlias
    }

    init(session: RemoteSession) {
        self.id = session.targetID
        self.name = session.name
        self.host = session.host
        self.username = session.username
        self.port = session.port
        self.connectionType = session.connectionType
        self.identityFile = session.identityFile
        self.jumpHost = session.jumpHost
        self.folder = session.folder
        self.enableX11Forwarding = session.enableX11Forwarding
        self.remotePath = session.remotePath
        self.rdpProfile = session.connectionType == .rdp ? session.rdpProfile : nil
        self.mcpEnabled = session.mcpEnabled
        self.mcpAlwaysAllowTerminalControl = session.mcpAlwaysAllowTerminalControl
        self.mcpAlias = session.mcpAlias
    }

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        username: String,
        port: Int? = nil,
        connectionType: RemoteConnectionType = .ssh,
        identityFile: String = "",
        jumpHost: String = "",
        folder: String = "",
        enableX11Forwarding: Bool = false,
        remotePath: String = "~",
        rdpProfile: RDPConnectionProfile? = nil,
        mcpEnabled: Bool = false,
        mcpAlwaysAllowTerminalControl: Bool = false,
        mcpAlias: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.port = port ?? connectionType.defaultPort
        self.connectionType = connectionType
        self.identityFile = identityFile
        self.jumpHost = jumpHost
        self.folder = folder
        self.enableX11Forwarding = enableX11Forwarding
        self.remotePath = remotePath
        self.rdpProfile = connectionType == .rdp ? (rdpProfile ?? RDPConnectionProfile()) : nil
        self.mcpEnabled = mcpEnabled
        self.mcpAlwaysAllowTerminalControl = mcpAlwaysAllowTerminalControl
        self.mcpAlias = mcpAlias
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? NSUserName()
        let rawConnectionType = try container.decodeIfPresent(String.self, forKey: .connectionType)
        let resolvedConnectionType = RemoteConnectionType.resolved(rawValue: rawConnectionType)
        connectionType = resolvedConnectionType.type
        let decodedPort = try container.decodeIfPresent(Int.self, forKey: .port)
        let legacyRDPPort = try container.decodeIfPresent(Int.self, forKey: .rdpPort)
        port = connectionType == .rdp
            ? (legacyRDPPort ?? decodedPort ?? connectionType.defaultPort)
            : (decodedPort ?? connectionType.defaultPort)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        jumpHost = try container.decodeIfPresent(String.self, forKey: .jumpHost) ?? ""
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        enableX11Forwarding = try container.decodeIfPresent(Bool.self, forKey: .enableX11Forwarding) ?? false
        remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? "~"
        rdpProfile = connectionType == .rdp
            ? (try container.decodeIfPresent(RDPConnectionProfile.self, forKey: .rdpProfile) ?? RDPConnectionProfile())
            : nil
        let decodedMCPEnabled = try container.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? false
        let decodedPersistentMCPControl = try container.decodeIfPresent(Bool.self, forKey: .mcpAlwaysAllowTerminalControl) ?? false
        mcpEnabled = resolvedConnectionType.isSupported && connectionType != .macDesktop && decodedMCPEnabled
        mcpAlwaysAllowTerminalControl = mcpEnabled &&
            connectionType != .rdp &&
            decodedPersistentMCPControl
        mcpAlias = try container.decodeIfPresent(String.self, forKey: .mcpAlias) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(username, forKey: .username)
        try container.encode(port, forKey: .port)
        try container.encode(connectionType, forKey: .connectionType)
        try container.encode(identityFile, forKey: .identityFile)
        try container.encode(jumpHost, forKey: .jumpHost)
        try container.encode(folder, forKey: .folder)
        try container.encode(enableX11Forwarding, forKey: .enableX11Forwarding)
        try container.encode(remotePath, forKey: .remotePath)
        try container.encodeIfPresent(rdpProfile, forKey: .rdpProfile)
        try container.encode(mcpEnabled, forKey: .mcpEnabled)
        try container.encode(mcpAlwaysAllowTerminalControl, forKey: .mcpAlwaysAllowTerminalControl)
        try container.encode(mcpAlias, forKey: .mcpAlias)
    }

    @MainActor
    func makeSession() -> RemoteSession {
        let session = RemoteSession(
            targetID: id,
            name: name,
            host: host,
            username: username,
            port: port,
            connectionType: connectionType,
            identityFile: identityFile,
            jumpHost: jumpHost,
            folder: folder,
            enableX11Forwarding: enableX11Forwarding,
            remotePath: remotePath
        )
        session.mcpEnabled = connectionType == .macDesktop ? false : mcpEnabled
        session.mcpAlwaysAllowTerminalControl = session.mcpEnabled &&
            connectionType != .rdp &&
            mcpAlwaysAllowTerminalControl
        session.mcpAlias = mcpAlias
        if let rdpProfile {
            try? session.setRDPProfile(rdpProfile)
        }
        return session
    }
}

nonisolated enum SessionProfileCodec {
    static let fileExtension = "jts-terminal-mac-sessions.json"

    @MainActor
    static func encode(sessions: [RemoteSession]) throws -> Data {
        let document = RemoteSessionProfileDocument(sessions: sessions.map(RemoteSessionProfile.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> [RemoteSessionProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RemoteSessionProfileDocument.self, from: data).sessions
    }
}

@MainActor
enum SessionProfileImporter {
    @discardableResult
    static func insert(
        _ profiles: [RemoteSessionProfile],
        into modelContext: ModelContext
    ) -> [RemoteSession] {
        profiles.map { profile in
            let session = profile.makeSession()
            modelContext.insert(session)
            return session
        }
    }
}
