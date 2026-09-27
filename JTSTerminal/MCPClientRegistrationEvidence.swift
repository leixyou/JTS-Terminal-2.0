//
//  MCPClientRegistrationEvidence.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/29.
//

import CryptoKit
import Foundation

nonisolated enum MCPClientRegistrationVerification: String, Codable, Equatable {
    case configuration
    case completedInstall
    case observedRuntime
}

nonisolated enum MCPClientRegistrationEvidenceError: LocalizedError {
    case invalidCommandPath
    case invalidReceipt(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidCommandPath:
            return "The MCP registration evidence command path is invalid."
        case .invalidReceipt(let path):
            return "The private MCP registration evidence is invalid: \(path)"
        }
    }
}

/// Private, immutable-to-the-client evidence that registration completed.
///
/// The client configuration remains outside the App Sandbox and may not be
/// readable after relaunch without a Powerbox bookmark. A completed-install
/// receipt proves that JTS finished its validated atomic write. A runtime receipt
/// is stronger current evidence: a client supplied an issued registration ID to
/// this exact executable and completed MCP initialization.
///
/// Raw registry records are deliberately not evidence because the registrar
/// activates an identity before the external configuration write and may leave
/// a dormant record after a failed commit.
nonisolated struct MCPClientRegistrationEvidenceStore {
    private enum EvidenceKind: String, Codable {
        case completedInstall = "completion"
        case observedRuntime = "runtime"

        var verification: MCPClientRegistrationVerification {
            switch self {
            case .completedInstall:
                return .completedInstall
            case .observedRuntime:
                return .observedRuntime
            }
        }
    }

    private struct Receipt: Codable {
        let formatVersion: Int
        let kind: EvidenceKind
        let registrationID: String
        let configurationKey: String
        let clientLabel: String
        let commandPath: String
        let argumentsSHA256: String
        let installedConfigurationSHA256: String?
    }

    private static let formatVersion = 1

    private let rootURL: URL?
    private let fileManager: FileManager

    init(
        rootURL: URL?,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    static var disabled: MCPClientRegistrationEvidenceStore {
        MCPClientRegistrationEvidenceStore(rootURL: nil)
    }

    func recordCompletedInstall(
        registration: MCPClientRegistrationRecord,
        commandPath: String,
        installedConfiguration: Data
    ) throws {
        try record(
            kind: .completedInstall,
            registration: registration,
            commandPath: commandPath,
            installedConfigurationSHA256: Self.sha256(installedConfiguration)
        )
    }

    func recordObservedRuntime(
        registration: MCPClientRegistrationRecord,
        commandPath: String
    ) throws {
        try record(
            kind: .observedRuntime,
            registration: registration,
            commandPath: commandPath,
            installedConfigurationSHA256: nil
        )
    }

    func verification(
        for registration: MCPClientRegistrationRecord,
        commandPath: String
    ) throws -> MCPClientRegistrationVerification? {
        guard rootURL != nil else { return nil }
        let normalizedCommand = try normalizedCommandPath(commandPath)
        for kind in [EvidenceKind.observedRuntime, .completedInstall] {
            let url = try receiptURL(
                kind: kind,
                registration: registration,
                commandPath: normalizedCommand
            )
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            let receipt = try loadReceipt(at: url)
            guard receipt.formatVersion == Self.formatVersion,
                  receipt.kind == kind,
                  receipt.registrationID == registration.registrationID,
                  receipt.configurationKey == registration.configurationKey,
                  receipt.clientLabel == registration.clientLabel,
                  receipt.commandPath == normalizedCommand,
                  receipt.argumentsSHA256
                    == Self.argumentsSHA256(
                        registrationID: registration.registrationID
                    ),
                  kind != .completedInstall
                    || receipt.installedConfigurationSHA256?.count == 64 else {
                throw MCPClientRegistrationEvidenceError.invalidReceipt(
                    path: url.path
                )
            }
            return kind.verification
        }
        return nil
    }

    private func record(
        kind: EvidenceKind,
        registration: MCPClientRegistrationRecord,
        commandPath: String,
        installedConfigurationSHA256: String?
    ) throws {
        guard let rootURL else { return }
        let normalizedCommand = try normalizedCommandPath(commandPath)
        let receipt = Receipt(
            formatVersion: Self.formatVersion,
            kind: kind,
            registrationID: registration.registrationID,
            configurationKey: registration.configurationKey,
            clientLabel: registration.clientLabel,
            commandPath: normalizedCommand,
            argumentsSHA256: Self.argumentsSHA256(
                registrationID: registration.registrationID
            ),
            installedConfigurationSHA256: installedConfigurationSHA256
        )
        let destination = try receiptURL(
            kind: kind,
            registration: registration,
            commandPath: normalizedCommand
        )
        let directory = destination.deletingLastPathComponent()
        try PrivateFileSecurity.secureDirectory(
            at: rootURL,
            fileManager: fileManager
        )
        try PrivateFileSecurity.secureDirectory(
            at: directory,
            fileManager: fileManager
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let staged = try PrivateFileSecurity.createStagedFile(
            adjacentTo: destination,
            fileManager: fileManager
        )
        defer {
            PrivateFileSecurity.removeStaging(
                staged,
                fileManager: fileManager
            )
        }
        do {
            try staged.handle.write(contentsOf: data)
            try staged.handle.synchronize()
            try staged.handle.close()
        } catch {
            try? staged.handle.close()
            throw error
        }
        try PrivateFileSecurity.installReplacing(staged, at: destination)
    }

    private func loadReceipt(at url: URL) throws -> Receipt {
        guard let rootURL else {
            throw MCPClientRegistrationEvidenceError.invalidReceipt(
                path: url.path
            )
        }
        try PrivateFileSecurity.verifyPrivateDirectory(at: rootURL)
        try PrivateFileSecurity.verifyPrivateDirectory(
            at: url.deletingLastPathComponent()
        )
        try PrivateFileSecurity.verifyPrivateFile(at: url)
        let data = try Data(contentsOf: url)
        guard let receipt = try? JSONDecoder().decode(
            Receipt.self,
            from: data
        ) else {
            throw MCPClientRegistrationEvidenceError.invalidReceipt(
                path: url.path
            )
        }
        return receipt
    }

    private func receiptURL(
        kind: EvidenceKind,
        registration: MCPClientRegistrationRecord,
        commandPath: String
    ) throws -> URL {
        guard let rootURL else {
            throw MCPClientRegistrationEvidenceError.invalidCommandPath
        }
        let key = Data(
            "\(kind.rawValue)\u{0}\(registration.registrationID)\u{0}\(commandPath)"
                .utf8
        )
        let name = Self.sha256(key) + ".json"
        return rootURL
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(name)
    }

    private func normalizedCommandPath(_ commandPath: String) throws -> String {
        guard commandPath.hasPrefix("/") else {
            throw MCPClientRegistrationEvidenceError.invalidCommandPath
        }
        let normalized = URL(fileURLWithPath: commandPath)
            .standardizedFileURL
            .path
        guard normalized == commandPath else {
            throw MCPClientRegistrationEvidenceError.invalidCommandPath
        }
        return normalized
    }

    private static func argumentsSHA256(
        registrationID: String
    ) -> String {
        let arguments = MCPClientRegistrar.arguments(
            registrationID: registrationID
        )
        return sha256(
            Data(arguments.joined(separator: "\u{0}").utf8)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
