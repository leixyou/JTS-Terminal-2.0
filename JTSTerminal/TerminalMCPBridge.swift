//
//  TerminalMCPBridge.swift
//  JTSTerminal
//
//  Created by Codex on 2026/6/1.
//

import Darwin
import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftData

nonisolated enum TerminalMCPBridgeError: LocalizedError {
    case descriptorMissing(String)
    case guiNotRunning
    case socketPathTooLong(String)
    case socketFailure(String)
    case deadlineExceeded
    case invalidResponse
    case unauthorized
    case bridgeError(String)

    var errorDescription: String? {
        switch self {
        case .descriptorMissing(let path):
            return "JTS Terminal GUI bridge is not available. Start JTS Terminal, open a terminal, and enable MCP Control for that pane. Missing descriptor: \(path)"
        case .guiNotRunning:
            return "JTS Terminal GUI is not running or the MCP terminal bridge is stale."
        case .socketPathTooLong(let path):
            return "MCP terminal bridge socket path is too long for a Unix socket: \(path)"
        case .socketFailure(let message):
            return "MCP terminal bridge socket failed: \(message)"
        case .deadlineExceeded:
            return "MCP terminal bridge request exceeded its deadline."
        case .invalidResponse:
            return "MCP terminal bridge returned an invalid response."
        case .unauthorized:
            return "MCP terminal bridge rejected the request token."
        case .bridgeError(let message):
            return message
        }
    }
}

nonisolated enum TerminalMCPCommandError: LocalizedError {
    case notRunning
    case rejected(String)
    case executionInterrupted(reason: String, didWriteCommandBytes: Bool)
    case couldNotParseResult

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "The authorized terminal session is not running."
        case .rejected(let reason):
            return reason
        case .executionInterrupted(let reason, _):
            return reason
        case .couldNotParseResult:
            return "Could not parse terminal command result from the PTY transcript."
        }
    }
}

nonisolated struct TerminalMCPCommandRequest {
    static let maximumCommandCharacters = 16_384

    let command: String
    let timeoutSeconds: TimeInterval
    let maxOutputBytes: Int

    init(command: String, timeoutSeconds: TimeInterval, maxOutputBytes: Int) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalMCPCommandError.rejected("Terminal command cannot be empty.")
        }
        guard command.count <= Self.maximumCommandCharacters else {
            throw TerminalMCPCommandError.rejected("Terminal command exceeds \(Self.maximumCommandCharacters) characters.")
        }
        guard Self.containsOnlyAllowedControlCharacters(command) else {
            throw TerminalMCPCommandError.rejected("Terminal command contains unsupported control characters.")
        }

        self.command = command
        self.timeoutSeconds = min(max(timeoutSeconds, 1), 1_800)
        self.maxOutputBytes = min(max(maxOutputBytes, 1), 16 * 1_024 * 1_024)
    }

    private static func containsOnlyAllowedControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 9, 10:
                return true
            case 0..<32, 127:
                return false
            default:
                return true
            }
        }
    }
}

nonisolated struct TerminalMCPCommandResult: Equatable {
    let exitCode: Int
    let stdout: String
    let truncated: Bool
    let durationMs: Int
    let timedOut: Bool
    let didWriteCommandBytes: Bool
}

nonisolated enum TerminalMCPCommandEnvelope {
    private static let encodedCommandChunkCharacters = 384
    private static let inputChunkBytes = 512

    static func wrappedCommand(
        command: String,
        startSentinel: String,
        endSentinel: String,
        restoreEcho: Bool = false
    ) -> String {
        let encodedStart = octalEncoded(startSentinel)
        let encodedEnd = octalEncoded(endSentinel)
        var lines = [
            "{",
            "__jts_mcp_cmd=$("
        ]
        lines += octalEncodedChunks(command).map { "printf '\($0)'" }
        lines += [
            ")",
            "__jts_mcp_start=$(printf '\(encodedStart)')",
            "__jts_mcp_end=$(printf '\(encodedEnd)')",
            "printf '\\n%s\\n' \"$__jts_mcp_start\"",
            "eval \"$__jts_mcp_cmd\"",
            "__jts_mcp_status=$?",
        ]
        if restoreEcho {
            lines.append("stty echo 2>/dev/null || true")
        }
        lines += [
            "printf '\\n%s:%s\\n' \"$__jts_mcp_end\" \"$__jts_mcp_status\"",
            "unset __jts_mcp_cmd __jts_mcp_start __jts_mcp_end __jts_mcp_status",
            "}"
        ]
        return lines.joined(separator: "\n") + "\r"
    }

    static func inputChunks(for text: String) -> [String] {
        lineSegments(in: text).flatMap(byteBoundedChunks)
    }

    static func parse(
        transcript: String,
        baselineCharacterCount: Int,
        startSentinel: String,
        endSentinel: String
    ) -> (stdout: String, exitCode: Int)? {
        guard transcript.count >= baselineCharacterCount else { return nil }
        let baselineIndex = transcript.index(
            transcript.startIndex,
            offsetBy: baselineCharacterCount,
            limitedBy: transcript.endIndex
        ) ?? transcript.endIndex
        let tail = String(transcript[baselineIndex...])
        let endMarker = "\(endSentinel):"
        guard let endRange = lastRange(of: endMarker, in: tail) else { return nil }

        let beforeEnd = String(tail[..<endRange.lowerBound])
        guard let startRange = lastRange(of: startSentinel, in: beforeEnd) else { return nil }

        let statusStart = endRange.upperBound
        let statusText = tail[statusStart...].prefix { character in
            character == "-" || character.isNumber
        }
        guard let exitCode = Int(statusText) else { return nil }

        var output = String(beforeEnd[startRange.upperBound...])
        output = trimOneLeadingLineBreak(from: output)
        output = trimOneTrailingLineBreak(from: output)
        return (output, exitCode)
    }

    static func truncate(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return (text, false) }
        return (String(decoding: data.prefix(maxBytes), as: UTF8.self), true)
    }

    static func displayTranscript(from rawTail: String, startSentinel: String, endSentinel: String) -> String {
        var output = ""
        var isInsideCommandOutput = false
        var didSeeEnd = false

        for segment in lineSegments(in: rawTail) {
            let line = withoutLineTerminators(segment)

            if isWrapperEcho(line) {
                continue
            }
            if line == startSentinel {
                isInsideCommandOutput = true
                continue
            }
            if line.hasPrefix("\(endSentinel):") {
                isInsideCommandOutput = false
                didSeeEnd = true
                continue
            }

            if isInsideCommandOutput || didSeeEnd {
                output += segment
            }
        }

        return output
    }

    private static func lastRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        var searchStart = haystack.startIndex
        var found: Range<String.Index>?
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            found = range
            searchStart = range.upperBound
        }
        return found
    }

    private static func octalEncoded(_ value: String) -> String {
        value.utf8
            .map { String(format: "\\%03o", $0) }
            .joined()
    }

    private static func octalEncodedChunks(_ value: String) -> [String] {
        let encoded = octalEncoded(value)
        guard !encoded.isEmpty else { return [""] }

        var chunks: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(
                index,
                offsetBy: encodedCommandChunkCharacters,
                limitedBy: encoded.endIndex
            ) ?? encoded.endIndex
            chunks.append(String(encoded[index..<next]))
            index = next
        }
        return chunks
    }

    private static func trimOneLeadingLineBreak(from value: String) -> String {
        if value.hasPrefix("\r\n") {
            return String(value.dropFirst())
        }
        if value.hasPrefix("\n") || value.hasPrefix("\r") {
            return String(value.dropFirst())
        }
        return value
    }

    private static func trimOneTrailingLineBreak(from value: String) -> String {
        if value.hasSuffix("\r\n") {
            return String(value.dropLast())
        }
        if value.hasSuffix("\n") || value.hasSuffix("\r") {
            return String(value.dropLast())
        }
        return value
    }

    private static func lineSegments(in text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var index = text.unicodeScalars.startIndex

        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            current.append(String(scalar))
            let nextIndex = text.unicodeScalars.index(after: index)

            if scalar.value == 13 {
                if nextIndex < text.unicodeScalars.endIndex {
                    let next = text.unicodeScalars[nextIndex]
                    if next.value == 10 {
                        current.append(String(next))
                        index = text.unicodeScalars.index(after: nextIndex)
                    } else {
                        index = nextIndex
                    }
                } else {
                    index = nextIndex
                }
                segments.append(current)
                current = ""
                continue
            }

            if scalar.value == 10 {
                segments.append(current)
                current = ""
            }
            index = nextIndex
        }

        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private static func byteBoundedChunks(for text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0

        for character in text {
            let byteCount = String(character).utf8.count
            if currentBytes > 0, currentBytes + byteCount > inputChunkBytes {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += byteCount
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func withoutLineTerminators(_ segment: String) -> String {
        var scalars = Array(segment.unicodeScalars)
        while let last = scalars.last, last.value == 10 || last.value == 13 {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isWrapperEcho(_ line: String) -> Bool {
        line.contains("__jts_mcp_cmd=$(printf")
            || line.contains("__jts_mcp_start=$(printf")
            || line.contains("__jts_mcp_end=$(printf")
    }
}

nonisolated struct TerminalMCPBridgeDescriptor: Codable, Equatable {
    var socketPath: String
    var token: String
    var appPID: Int32
    var createdAt: Date
}

nonisolated struct TerminalMCPBridgeTerminal: Equatable {
    var terminalID: String
    var serverAlias: String
    var connectionType: String
    var displayName: String
    var mcpName: String
    var pid: Int32?
    var paneTitle: String
    var automationRecoveryRequired: Bool

    var dictionary: [String: Any] {
        [
            "terminalId": terminalID,
            "serverAlias": serverAlias,
            "connectionType": connectionType,
            "displayName": displayName,
            "mcpName": mcpName,
            "pid": pid ?? NSNull(),
            "paneTitle": paneTitle,
            "automationRecoveryRequired": automationRecoveryRequired
        ]
    }
}

@MainActor
struct TerminalMCPAttachedTerminal {
    var info: TerminalMCPBridgeTerminal
    var remoteSession: RemoteSession
    var processSession: InteractiveProcessSession
}

nonisolated enum TerminalMCPBridgeLaunchPolicy {
    static let userDefaultsKey = "terminalMCPBridgeEnabled.v1"
    static let enableEnvironmentKey = "JTS_TERMINAL_ENABLE_MCP_BRIDGE"
    static let disableEnvironmentKey = "JTS_TERMINAL_DISABLE_MCP_BRIDGE"

    static func shouldAutoStart(
        isUserEnabled: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = defaultIsDebugBuild
    ) -> Bool {
        if environment[disableEnvironmentKey] == "1" {
            return false
        }
        if environment[enableEnvironmentKey] == "1" {
            return true
        }
        return isUserEnabled || isDebugBuild
    }

    private static var defaultIsDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

nonisolated enum TerminalMCPBridgeRuntime {
    private static let maximumDescriptorBytes = 64 * 1_024

    static func descriptorURL(runtimeRoot: URL? = nil, fileManager: FileManager = .default) throws -> URL {
        try directory(runtimeRoot: runtimeRoot, fileManager: fileManager)
            .appendingPathComponent("bridge.json")
    }

    static func socketURL(runtimeRoot: URL? = nil, fileManager: FileManager = .default) throws -> URL {
        if let runtimeRoot {
            let securedRuntimeRoot = try directory(
                runtimeRoot: runtimeRoot,
                fileManager: fileManager
            )
            let candidate = securedRuntimeRoot.appendingPathComponent("bridge.sock")
            if isValidUnixSocketPath(candidate.path) {
                return candidate
            }
            return try shortFallbackSocketURL(fileManager: fileManager)
        }

        if let sandboxTemporaryDirectory = sandboxContainerTemporaryDirectory(
            fileManager: fileManager
        ) {
            let candidate = compactSocketURL(in: sandboxTemporaryDirectory)
            if isValidUnixSocketPath(candidate.path) {
                return candidate
            }
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("jts-terminal-mcp-\(getuid())", isDirectory: true)
        try PrivateFileSecurity.secureDirectory(at: directory, fileManager: fileManager)
        let nonce = UUID().uuidString.prefix(8)
        let candidate = directory.appendingPathComponent("bridge-\(getpid())-\(nonce).sock")
        if isValidUnixSocketPath(candidate.path) {
            return candidate
        }

        return try shortFallbackSocketURL(fileManager: fileManager)
    }

    static func imageHandoffDirectoryURL(
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        try directory(runtimeRoot: runtimeRoot, fileManager: fileManager)
            .appendingPathComponent("image-handoffs", isDirectory: true)
    }

    static func writeDescriptor(
        _ descriptor: TerminalMCPBridgeDescriptor,
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let url = try descriptorURL(runtimeRoot: runtimeRoot, fileManager: fileManager)
        let data = try JSONEncoder().encode(descriptor)
        guard data.count <= maximumDescriptorBytes else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        let stagedFile = try PrivateFileSecurity.createStagedFile(
            adjacentTo: url,
            fileManager: fileManager
        )
        defer {
            PrivateFileSecurity.removeStaging(
                stagedFile,
                fileManager: fileManager
            )
        }
        try stagedFile.handle.write(contentsOf: data)
        try stagedFile.handle.synchronize()
        try stagedFile.handle.close()
        try PrivateFileSecurity.installReplacing(stagedFile, at: url)
    }

    static func readDescriptor(runtimeRoot: URL? = nil, fileManager: FileManager = .default) throws -> TerminalMCPBridgeDescriptor {
        let url = try descriptorURL(runtimeRoot: runtimeRoot, fileManager: fileManager)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT {
                throw TerminalMCPBridgeError.descriptorMissing(url.path)
            }
            throw TerminalMCPBridgeError.invalidResponse
        }
        defer { _ = Darwin.close(descriptor) }
        do {
            try PrivateFileSecurity.verifyPrivateFileDescriptor(
                descriptor,
                path: url.path
            )
        } catch {
            throw TerminalMCPBridgeError.invalidResponse
        }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_size >= 0,
              fileStatus.st_size <= off_t(maximumDescriptorBytes) else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumDescriptorBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumDescriptorBytes else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        return try JSONDecoder().decode(TerminalMCPBridgeDescriptor.self, from: data)
    }

    static func removeRuntimeFiles(
        descriptor: TerminalMCPBridgeDescriptor?,
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        if let descriptor {
            try? fileManager.removeItem(atPath: descriptor.socketPath)
        }
        if let url = try? descriptorURL(runtimeRoot: runtimeRoot, fileManager: fileManager) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func directory(runtimeRoot: URL?, fileManager: FileManager) throws -> URL {
        if let runtimeRoot {
            try PrivateFileSecurity.secureDirectory(
                at: runtimeRoot,
                fileManager: fileManager
            )
            return runtimeRoot
        }

        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = supportDirectory.appendingPathComponent("JTS Terminal MCP Bridge", isDirectory: true)
        try PrivateFileSecurity.secureDirectory(at: directory, fileManager: fileManager)
        return directory
    }

    private static func shortFallbackSocketURL(fileManager: FileManager) throws -> URL {
        if let sandboxTemporaryDirectory = sandboxContainerTemporaryDirectory(
            fileManager: fileManager
        ) {
            let socketURL = compactSocketURL(in: sandboxTemporaryDirectory)
            if isValidUnixSocketPath(socketURL.path) {
                return socketURL
            }
        }

        // `/tmp` is a symlink to `/private/tmp` on macOS. The private-storage
        // helper intentionally rejects symlink mutation boundaries, so use the
        // canonical system path for this narrowly scoped short socket fallback.
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("jts-terminal-mcp-\(getuid())", isDirectory: true)
        try PrivateFileSecurity.secureDirectory(at: directory, fileManager: fileManager)

        let nonce = UUID().uuidString.prefix(8)
        let socketURL = directory.appendingPathComponent("bridge-\(getpid())-\(nonce).sock")
        if isValidUnixSocketPath(socketURL.path) {
            return socketURL
        }
        throw TerminalMCPBridgeError.socketPathTooLong(socketURL.path)
    }

    /// Sandboxed macOS apps may bind Unix sockets only inside their container.
    /// `FileManager.temporaryDirectory` can still resolve to the shared Darwin
    /// user-temp root, while the Application Support URL exposes the concrete
    /// container layout. Prefer the container's existing private `Data/tmp`
    /// directory and a compact filename so the path remains below `sun_path`.
    private static func sandboxContainerTemporaryDirectory(
        fileManager: FileManager
    ) -> URL? {
        guard let supportDirectory = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        guard let temporaryDirectory = sandboxContainerTemporaryDirectory(
            applicationSupportDirectory: supportDirectory
        ), (try? PrivateFileSecurity.verifyPrivateDirectory(at: temporaryDirectory)) != nil else {
            return nil
        }
        return temporaryDirectory
    }

    static func sandboxContainerTemporaryDirectory(
        applicationSupportDirectory supportDirectory: URL
    ) -> URL? {
        let libraryDirectory = supportDirectory.deletingLastPathComponent()
        let dataDirectory = libraryDirectory.deletingLastPathComponent()
        let containerDirectory = dataDirectory.deletingLastPathComponent()
        guard supportDirectory.lastPathComponent == "Application Support",
              libraryDirectory.lastPathComponent == "Library",
              dataDirectory.lastPathComponent == "Data",
              containerDirectory.deletingLastPathComponent().lastPathComponent == "Containers" else {
            return nil
        }
        return dataDirectory.appendingPathComponent("tmp", isDirectory: true)
    }

    private static func compactSocketURL(in directory: URL) -> URL {
        let nonce = UUID().uuidString.prefix(8)
        return directory.appendingPathComponent("jts-\(getpid())-\(nonce).sock")
    }

    private static func isValidUnixSocketPath(_ path: String) -> Bool {
        path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }
}

nonisolated struct TerminalMCPBridgeImageHandoffDescriptor: Codable, Equatable, Sendable {
    var fileName: String
    var byteCount: Int
    var sha256: String

    var dictionary: [String: Any] {
        [
            "fileName": fileName,
            "byteCount": byteCount,
            "sha256": sha256,
        ]
    }

    init(fileName: String, byteCount: Int, sha256: String) {
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    init?(dictionary: [String: Any]) {
        guard let fileName = dictionary["fileName"] as? String,
              let byteCount = Self.exactInt(dictionary["byteCount"]),
              let sha256 = dictionary["sha256"] as? String,
              Set(dictionary.keys) == Set(["fileName", "byteCount", "sha256"]) else {
            return nil
        }
        self.init(fileName: fileName, byteCount: byteCount, sha256: sha256)
    }

    private static func exactInt(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let candidate = number.int64Value
        guard number.compare(NSNumber(value: candidate)) == .orderedSame,
              candidate >= Int64(Int.min),
              candidate <= Int64(Int.max) else {
            return nil
        }
        return Int(candidate)
    }
}

nonisolated enum TerminalMCPBridgeImageHandoff {
    static let maximumPNGBytes = 160 * 1_024 * 1_024
    static let maximumOutstandingFiles = 4
    static let maximumOutstandingBytes = 512 * 1_024 * 1_024
    private static let orphanLifetime: TimeInterval = 10 * 60
    private static let quotaLockFileName = ".handoff-quota.lock"

    static func create(
        pngData: Data,
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> TerminalMCPBridgeImageHandoffDescriptor {
        guard !pngData.isEmpty, pngData.count <= maximumPNGBytes else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        let directoryDescriptor = try secureDirectoryDescriptor(
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
        defer { _ = Darwin.close(directoryDescriptor) }
        let quotaLockDescriptor = try lockQuota(in: directoryDescriptor)
        defer {
            _ = flock(quotaLockDescriptor, LOCK_UN)
            _ = Darwin.close(quotaLockDescriptor)
        }
        pruneOrphans(in: directoryDescriptor)
        guard quotaAllows(
            additionalByteCount: pngData.count,
            in: directoryDescriptor
        ) else {
            throw TerminalMCPBridgeError.socketFailure(
                "MCP image handoff quota exceeded."
            )
        }

        let fileName = "\(UUID().uuidString.lowercased()).png"
        let descriptor = fileName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw TerminalMCPBridgeError.socketFailure(String(cString: strerror(errno)))
        }

        var shouldRemove = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemove {
                fileName.withCString {
                    _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }
        do {
            try PrivateFileSecurity.securePrivateFileDescriptor(
                descriptor,
                path: fileName
            )
        } catch {
            throw TerminalMCPBridgeError.invalidResponse
        }
        try writeAll(pngData, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw TerminalMCPBridgeError.socketFailure(String(cString: strerror(errno)))
        }
        shouldRemove = false
        return TerminalMCPBridgeImageHandoffDescriptor(
            fileName: fileName,
            byteCount: pngData.count,
            sha256: digest(pngData)
        )
    }

    static func consume(
        _ handoff: TerminalMCPBridgeImageHandoffDescriptor,
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Data {
        guard isValidFileName(handoff.fileName),
              (1...maximumPNGBytes).contains(handoff.byteCount),
              isSHA256(handoff.sha256) else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        let directoryDescriptor = try secureDirectoryDescriptor(
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
        defer { _ = Darwin.close(directoryDescriptor) }
        let quotaLockDescriptor = try lockQuota(in: directoryDescriptor)

        // Claim the published name atomically before opening it. Only one
        // consumer can rename the source name, so concurrent readers cannot
        // both obtain a descriptor to the same handoff inode.
        let claimFileName = "\(handoff.fileName).claim"
        let claimed = handoff.fileName.withCString { sourceName in
            claimFileName.withCString { claimName in
                Darwin.renameat(
                    directoryDescriptor,
                    sourceName,
                    directoryDescriptor,
                    claimName
                )
            }
        }
        _ = flock(quotaLockDescriptor, LOCK_UN)
        _ = Darwin.close(quotaLockDescriptor)
        guard claimed == 0 else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        defer {
            claimFileName.withCString {
                _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
        }

        let descriptor = claimFileName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        defer { _ = Darwin.close(descriptor) }

        do {
            try PrivateFileSecurity.verifyPrivateFileDescriptor(
                descriptor,
                path: claimFileName
            )
        } catch {
            throw TerminalMCPBridgeError.invalidResponse
        }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_size == off_t(handoff.byteCount) else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        let data = try readAll(
            descriptor: descriptor,
            expectedByteCount: handoff.byteCount
        )
        guard digest(data).caseInsensitiveCompare(handoff.sha256) == .orderedSame else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        return data
    }

    static func remove(
        _ handoff: TerminalMCPBridgeImageHandoffDescriptor,
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        guard isValidFileName(handoff.fileName),
              let directoryDescriptor = try? secureDirectoryDescriptor(
                runtimeRoot: runtimeRoot,
                fileManager: fileManager
              ),
              let quotaLockDescriptor = try? lockQuota(in: directoryDescriptor) else {
            return
        }
        defer {
            _ = flock(quotaLockDescriptor, LOCK_UN)
            _ = Darwin.close(quotaLockDescriptor)
            _ = Darwin.close(directoryDescriptor)
        }
        for fileName in [handoff.fileName, "\(handoff.fileName).claim"] {
            fileName.withCString {
                _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
        }
    }

    static func removeAll(
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        guard let directoryDescriptor = try? secureDirectoryDescriptor(
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        ) else {
            return
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard let quotaLockDescriptor = try? lockQuota(in: directoryDescriptor) else {
            return
        }
        defer {
            _ = flock(quotaLockDescriptor, LOCK_UN)
            _ = Darwin.close(quotaLockDescriptor)
        }
        forEachHandoffEntry(in: directoryDescriptor) { fileName, _ in
            fileName.withCString {
                _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
        }
    }

    private static func secureDirectoryDescriptor(
        runtimeRoot: URL?,
        fileManager: FileManager
    ) throws -> Int32 {
        let directoryURL = try TerminalMCPBridgeRuntime.imageHandoffDirectoryURL(
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
        try PrivateFileSecurity.secureDirectory(
            at: directoryURL,
            fileManager: fileManager
        )
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        do {
            try PrivateFileSecurity.verifyPrivateDirectoryDescriptor(
                descriptor,
                path: directoryURL.path
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw TerminalMCPBridgeError.invalidResponse
        }
        return descriptor
    }

    private static func lockQuota(in directoryDescriptor: Int32) throws -> Int32 {
        let descriptor = quotaLockFileName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        do {
            try PrivateFileSecurity.securePrivateFileDescriptor(
                descriptor,
                path: quotaLockFileName
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw TerminalMCPBridgeError.invalidResponse
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR {
                continue
            }
            _ = Darwin.close(descriptor)
            throw TerminalMCPBridgeError.invalidResponse
        }
        return descriptor
    }

    private static func quotaAllows(
        additionalByteCount: Int,
        in directoryDescriptor: Int32
    ) -> Bool {
        var fileCount = 0
        var byteCount = 0
        var overflowed = false
        let enumerated = forEachHandoffEntry(in: directoryDescriptor) { _, fileStatus in
            guard fileStatus.st_size >= 0,
                  fileStatus.st_size <= off_t(maximumPNGBytes),
                  !overflowed else {
                overflowed = true
                return
            }
            let (updatedByteCount, didOverflow) = byteCount.addingReportingOverflow(
                Int(fileStatus.st_size)
            )
            overflowed = didOverflow
            byteCount = updatedByteCount
            fileCount += 1
        }
        guard enumerated,
              !overflowed,
              fileCount < maximumOutstandingFiles else {
            return false
        }
        let (projectedByteCount, didOverflow) = byteCount.addingReportingOverflow(
            additionalByteCount
        )
        return !didOverflow && projectedByteCount <= maximumOutstandingBytes
    }

    private static func pruneOrphans(in directoryDescriptor: Int32) {
        let cutoff = Date().addingTimeInterval(-orphanLifetime)
        forEachHandoffEntry(in: directoryDescriptor) { fileName, fileStatus in
            let modifiedAt = Date(
                timeIntervalSince1970: TimeInterval(fileStatus.st_mtimespec.tv_sec)
                    + TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            if modifiedAt < cutoff {
                fileName.withCString {
                    _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }
    }

    @discardableResult
    private static func forEachHandoffEntry(
        in directoryDescriptor: Int32,
        _ body: (String, stat) -> Void
    ) -> Bool {
        let duplicate = Darwin.openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard duplicate >= 0 else { return false }
        guard let directory = Darwin.fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            return false
        }
        defer { _ = Darwin.closedir(directory) }

        while let entry = Darwin.readdir(directory) {
            let fileName = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) {
                    String(cString: $0)
                }
            }
            guard isValidFileName(fileName) || isValidClaimFileName(fileName) else {
                continue
            }
            var fileStatus = stat()
            let status = fileName.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &fileStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard status == 0,
                  fileStatus.st_mode & S_IFMT == S_IFREG,
                  fileStatus.st_uid == geteuid() else {
                continue
            }
            body(fileName, fileStatus)
        }
        return true
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            throw TerminalMCPBridgeError.socketFailure(
                String(cString: strerror(written < 0 ? errno : EIO))
            )
        }
    }

    private static func readAll(
        descriptor: Int32,
        expectedByteCount: Int
    ) throws -> Data {
        var data = Data(count: expectedByteCount)
        var offset = 0
        while offset < expectedByteCount {
            let readCount = data.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedByteCount - offset
                )
            }
            if readCount > 0 {
                offset += readCount
                continue
            }
            if readCount < 0, errno == EINTR {
                continue
            }
            throw TerminalMCPBridgeError.invalidResponse
        }
        var trailingByte: UInt8 = 0
        guard Darwin.read(descriptor, &trailingByte, 1) == 0 else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        return data
    }

    private static func isValidFileName(_ value: String) -> Bool {
        guard value.hasSuffix(".png") else { return false }
        return UUID(uuidString: String(value.dropLast(4))) != nil
    }

    private static func isValidClaimFileName(_ value: String) -> Bool {
        guard value.hasSuffix(".png.claim") else { return false }
        return UUID(uuidString: String(value.dropLast(".png.claim".count))) != nil
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

nonisolated struct TerminalMCPBridgeClient {
    var runtimeRoot: URL?
    var fileManager: FileManager = .default

    func listOpenTerminals(
        clientID: String? = nil,
        deadlineUptimeMilliseconds: Int? = nil
    ) throws -> [[String: Any]] {
        var params: [String: Any] = [:]
        if let clientID { params["clientId"] = clientID }
        let result = try request(
            method: "list_open_terminals",
            params: params,
            deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
        )
        guard let root = result as? [String: Any],
              let terminals = root["terminals"] as? [[String: Any]] else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        return terminals
    }

    func executeTerminal(
        terminalID: String,
        command: String,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int,
        clientID: String? = nil
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "terminalId": terminalID,
            "command": command,
            "timeoutSeconds": timeoutSeconds,
            "maxOutputBytes": maxOutputBytes,
        ]
        if let clientID { params["clientId"] = clientID }
        let result = try request(
            method: "terminal_exec",
            params: params
        )
        guard let dictionary = result as? [String: Any] else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        return dictionary
    }

    func readTerminal(
        terminalID: String,
        maxOutputBytes: Int,
        clientID: String? = nil
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "terminalId": terminalID,
            "maxOutputBytes": maxOutputBytes,
        ]
        if let clientID { params["clientId"] = clientID }
        let result = try request(
            method: "terminal_read",
            params: params
        )
        guard let dictionary = result as? [String: Any] else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        return dictionary
    }

    func openTerminal(
        serverAlias: String,
        waitSeconds: TimeInterval,
        clientID: String? = nil
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "server": serverAlias,
            "waitSeconds": waitSeconds,
        ]
        if let clientID { params["clientId"] = clientID }
        let result = try request(
            method: "open_terminal",
            params: params
        )
        guard let dictionary = result as? [String: Any] else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        return dictionary
    }

    func invokeDeviceTool(_ toolName: String, targetID: String, arguments: [String: Any]) throws -> [String: Any] {
        let result = try request(method: "device_tool", params: ["tool": toolName, "targetId": targetID, "arguments": arguments])
        guard let value = result as? [String: Any] else { throw TerminalMCPBridgeError.invalidResponse }
        return value
    }

    func discoverDeviceRoutes(clientID: String, displayIdentity: String) throws -> [[String: Any]] {
        let result = try request(method: "device_discovery", params: ["_jtsClientID": clientID, "_jtsClientDisplayIdentity": displayIdentity])
        guard let value = result as? [String: Any], let routes = value["routes"] as? [[String: Any]] else { throw TerminalMCPBridgeError.invalidResponse }
        return routes
    }

    func invokeWindowsTool(
        _ toolName: String,
        targetID: String,
        arguments: [String: Any]
    ) throws -> [String: Any] {
        let result = try request(
            method: "windows_tool",
            params: [
                "tool": toolName,
                "targetId": targetID,
                "arguments": arguments,
            ]
        )
        guard var dictionary = result as? [String: Any] else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        if let rawHandoff = dictionary["pngHandoff"] {
            guard dictionary["pngBase64"] == nil,
                  let handoffDictionary = rawHandoff as? [String: Any],
                  let handoff = TerminalMCPBridgeImageHandoffDescriptor(
                      dictionary: handoffDictionary
                  ) else {
                throw TerminalMCPBridgeError.invalidResponse
            }
            dictionary.removeValue(forKey: "pngHandoff")
            dictionary["_jtsPNGData"] = try TerminalMCPBridgeImageHandoff.consume(
                handoff,
                runtimeRoot: runtimeRoot,
                fileManager: fileManager
            )
        }
        return dictionary
    }

    private func request(
        method: String,
        params: [String: Any],
        deadlineUptimeMilliseconds: Int? = nil
    ) throws -> Any {
        var lastError: Error?
        let retryLimit = method == "device_tool" ? 1 : 20
        for attempt in 0..<retryLimit {
            do {
                return try requestOnce(
                    method: method,
                    params: params,
                    deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
                )
            } catch TerminalMCPBridgeError.unauthorized where attempt < retryLimit - 1 {
                lastError = TerminalMCPBridgeError.unauthorized
                try sleepBeforeRetry(deadlineUptimeMilliseconds: deadlineUptimeMilliseconds)
            } catch TerminalMCPBridgeError.socketFailure(let message) where isTransientSocketFailure(message) && attempt < retryLimit - 1 {
                lastError = TerminalMCPBridgeError.socketFailure(message)
                try sleepBeforeRetry(deadlineUptimeMilliseconds: deadlineUptimeMilliseconds)
            } catch {
                throw error
            }
        }
        throw lastError ?? TerminalMCPBridgeError.invalidResponse
    }

    private func requestOnce(
        method: String,
        params: [String: Any],
        deadlineUptimeMilliseconds explicitDeadlineUptimeMilliseconds: Int?
    ) throws -> Any {
        let descriptor = try TerminalMCPBridgeRuntime.readDescriptor(
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
        guard processIsAlive(pid: descriptor.appPID) else {
            throw TerminalMCPBridgeError.guiNotRunning
        }

        var deadlineUptimeMilliseconds = explicitDeadlineUptimeMilliseconds
        var socketTimeoutMilliseconds = 1_820_000
#if ENABLE_RDP_2
        if method == "windows_tool",
           let arguments = params["arguments"] as? [String: Any],
           let windowsDeadlineUptimeMilliseconds = Self.integerValue(
               arguments["_jtsDeadlineUptimeMilliseconds"]
           ) {
            if let explicit = deadlineUptimeMilliseconds {
                deadlineUptimeMilliseconds = min(
                    explicit,
                    windowsDeadlineUptimeMilliseconds
                )
            } else {
                deadlineUptimeMilliseconds = windowsDeadlineUptimeMilliseconds
            }
        }
#endif
        if let deadlineUptimeMilliseconds {
            let remainingMilliseconds = deadlineUptimeMilliseconds
                - Int(ProcessInfo.processInfo.systemUptime * 1_000)
            guard remainingMilliseconds > 0 else {
                throw TerminalMCPBridgeError.deadlineExceeded
            }
            socketTimeoutMilliseconds = min(socketTimeoutMilliseconds, remainingMilliseconds)
        }

        let fd = try TerminalMCPBridgeSocket.connect(
            path: descriptor.socketPath,
            timeoutMilliseconds: socketTimeoutMilliseconds,
            deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
        )
        defer {
            Darwin.close(fd)
        }
        try TerminalMCPBridgeSocket.setTimeout(
            milliseconds: socketTimeoutMilliseconds,
            on: fd
        )
        let response: [String: Any]
        do {
            try TerminalMCPBridgeSocket.writeJSONLine([
                "token": descriptor.token,
                "method": method,
                "params": params
            ], to: fd, deadlineUptimeMilliseconds: deadlineUptimeMilliseconds)
            response = try TerminalMCPBridgeSocket.readJSONLine(
                from: fd,
                deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
            )
        } catch {
            if let deadlineUptimeMilliseconds,
               deadlineUptimeMilliseconds <= Int(ProcessInfo.processInfo.systemUptime * 1_000) {
                throw TerminalMCPBridgeError.deadlineExceeded
            }
            throw error
        }
        if response["ok"] as? Bool == true {
            return response["result"] ?? [:]
        }
        #if ENABLE_RDP_2
        if let error = response["windowsError"] as? [String: Any],
           let rawCode = error["code"] as? String,
           let code = WindowsMCPToolError.Code(rawValue: rawCode),
           let message = error["message"] as? String {
            throw WindowsMCPToolError(
                code: code,
                message: message,
                details: error["details"] as? [String: Any] ?? [:]
            )
        }
        #endif
        let message = (response["error"] as? String) ?? "MCP terminal bridge request failed."
        if message == TerminalMCPBridgeError.unauthorized.localizedDescription {
            throw TerminalMCPBridgeError.unauthorized
        }
        throw TerminalMCPBridgeError.bridgeError(message)
    }

    private func processIsAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func isTransientSocketFailure(_ message: String) -> Bool {
        message == "No such file or directory" || message == "Connection refused"
    }

    private func sleepBeforeRetry(
        deadlineUptimeMilliseconds: Int?
    ) throws {
        var delaySeconds = 0.05
        if let deadlineUptimeMilliseconds {
            let remainingMilliseconds = deadlineUptimeMilliseconds
                - Int(ProcessInfo.processInfo.systemUptime * 1_000)
            guard remainingMilliseconds > 0 else {
                throw TerminalMCPBridgeError.deadlineExceeded
            }
            delaySeconds = min(
                delaySeconds,
                TimeInterval(remainingMilliseconds) / 1_000
            )
        }
        Thread.sleep(forTimeInterval: delaySeconds)
    }
}

@MainActor
final class TerminalMCPBridgeServer: ObservableObject {
    private weak var terminalWorkspaceStore: TerminalWorkspaceStore?
    private var modelContext: ModelContext?
    private var descriptor: TerminalMCPBridgeDescriptor?
    private var listenFD: Int32 = -1
    private let runtimeRoot: URL?
    private let fileManager: FileManager
    private let acceptQueue = DispatchQueue(label: "com.lljts.JTSTerminal.mcp-terminal-bridge")
    private var terminationObserver: NSObjectProtocol?

    init(runtimeRoot: URL? = nil, fileManager: FileManager = .default) {
        self.runtimeRoot = runtimeRoot
        self.fileManager = fileManager
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if listenFD >= 0 {
            Darwin.close(listenFD)
        }
        TerminalMCPBridgeRuntime.removeRuntimeFiles(
            descriptor: descriptor,
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
        TerminalMCPBridgeImageHandoff.removeAll(
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
    }

    func start(
        terminalWorkspaceStore: TerminalWorkspaceStore,
        modelContext: ModelContext
    ) {
        self.terminalWorkspaceStore = terminalWorkspaceStore
        self.modelContext = modelContext
        guard listenFD < 0 else { return }

        do {
            TerminalMCPBridgeImageHandoff.removeAll(
                runtimeRoot: runtimeRoot,
                fileManager: fileManager
            )
            let socketURL = try TerminalMCPBridgeRuntime.socketURL(
                runtimeRoot: runtimeRoot,
                fileManager: fileManager
            )
            try? fileManager.removeItem(at: socketURL)
            let fd = try TerminalMCPBridgeSocket.listen(path: socketURL.path)
            let descriptor = TerminalMCPBridgeDescriptor(
                socketPath: socketURL.path,
                token: "\(UUID().uuidString)-\(UUID().uuidString)",
                appPID: getpid(),
                createdAt: Date()
            )
            try TerminalMCPBridgeRuntime.writeDescriptor(
                descriptor,
                runtimeRoot: runtimeRoot,
                fileManager: fileManager
            )
            self.listenFD = fd
            self.descriptor = descriptor
            acceptQueue.async { [weak self] in
                self?.acceptLoop(listenFD: fd)
            }
        } catch {
            fputs("JTS Terminal MCP bridge failed to start: \(error.localizedDescription)\n", stderr)
        }
    }

    func stop() {
        guard listenFD >= 0 else { return }
        let fd = listenFD
        listenFD = -1
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        TerminalMCPBridgeRuntime.removeRuntimeFiles(
            descriptor: descriptor,
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
        TerminalMCPBridgeImageHandoff.removeAll(
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
        descriptor = nil
    }

    private nonisolated func acceptLoop(listenFD: Int32) {
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                break
            }
            handleClientOnBackground(clientFD)
        }
    }

    private nonisolated func handleClientOnBackground(_ clientFD: Int32) {
        do {
            try TerminalMCPBridgeSocket.suppressSIGPIPE(on: clientFD)
            try TerminalMCPBridgeSocket.setTimeout(milliseconds: 1_820_000, on: clientFD)
            let request = try TerminalMCPBridgeSocket.readJSONLine(from: clientFD)
            Task { @MainActor [weak self] in
                let response = await self?.handle(request: request) ?? [
                    "ok": false,
                    "error": "JTS Terminal MCP terminal bridge is not running."
                ]
                do {
                    try TerminalMCPBridgeSocket.writeJSONLine(response, to: clientFD)
                } catch {
                    self?.removeUnpublishedImageHandoff(from: response)
                }
                Darwin.close(clientFD)
            }
        } catch {
            try? TerminalMCPBridgeSocket.writeJSONLine([
                "ok": false,
                "error": error.localizedDescription
            ], to: clientFD)
            Darwin.close(clientFD)
        }
    }

    private func removeUnpublishedImageHandoff(
        from response: [String: Any]
    ) {
        guard let result = response["result"] as? [String: Any],
              let rawHandoff = result["pngHandoff"] as? [String: Any],
              let handoff = TerminalMCPBridgeImageHandoffDescriptor(
                dictionary: rawHandoff
              ) else {
            return
        }
        TerminalMCPBridgeImageHandoff.remove(
            handoff,
            runtimeRoot: runtimeRoot,
            fileManager: fileManager
        )
    }

    private func handle(request: [String: Any]) async -> [String: Any] {
        guard request["token"] as? String == descriptor?.token else {
            return ["ok": false, "error": TerminalMCPBridgeError.unauthorized.localizedDescription]
        }
        guard let method = request["method"] as? String else {
            return ["ok": false, "error": "Missing MCP bridge method."]
        }

        let params = request["params"] as? [String: Any] ?? [:]
        do {
            switch method {
            case "list_open_terminals":
                let terminals = try authorizedOpenTerminals().map(\.info.dictionary)
                return ["ok": true, "result": ["terminals": terminals]]
            case "terminal_exec":
                return try await executeTerminal(params)
            case "terminal_read":
                return try readTerminal(params)
            case "open_terminal":
                return try await openTerminal(params)
            #if ENABLE_RDP_2
            case "windows_tool", "device_tool":
                do {
                    return try await (method == "device_tool" ? invokeDeviceTool(params) : invokeWindowsTool(params))
                } catch let failure as WindowsMCPToolError {
                    return [
                        "ok": false,
                        "error": failure.message,
                        "windowsError": [
                            "code": failure.code.rawValue,
                            "message": failure.message,
                            "details": failure.details,
                        ],
                    ]
                }
            case "device_discovery":
                return try await discoverDeviceRoutes(params)
            #endif
            default:
                return ["ok": false, "error": "Unsupported MCP bridge method: \(method)"]
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    #if ENABLE_RDP_2
    private func invokeDeviceTool(_ params: [String: Any]) async throws -> [String: Any] {
        guard AppReleasePolicy.includesNativeRDP, let modelContext,
              let raw = params["tool"] as? String, let tool = CompanionDeviceMCPTool(rawValue: raw),
              let rawID = params["targetId"] as? String, let id = UUID(uuidString: rawID),
              let arguments = params["arguments"] as? [String: Any],
              arguments["targetId"] as? String == rawID else { throw TerminalMCPBridgeError.invalidResponse }
        guard let target = try modelContext.fetch(FetchDescriptor<RemoteSession>()).first(where: {
            $0.targetID == id && $0.connectionType == .rdp && $0.mcpEnabled && $0.isConnectable
        }) else { throw WindowsMCPToolError(code: .targetNotFound, message: "No enabled Windows target matches targetId.") }
        let value = try await CompanionDeviceMCPHandler.shared.handle(tool: tool, target: target, arguments: arguments)
        return ["ok": true, "result": ["structuredContent": value]]
    }

    private func discoverDeviceRoutes(_ params: [String: Any]) async throws -> [String: Any] {
        guard AppReleasePolicy.includesNativeRDP, let modelContext,
              let clientID = params["_jtsClientID"] as? String, !clientID.isEmpty else { throw TerminalMCPBridgeError.unauthorized }
        var routes: [[String: Any]] = []
        for target in try modelContext.fetch(FetchDescriptor<RemoteSession>()) where target.connectionType == .rdp && target.mcpEnabled && target.isConnectable {
            let arguments: [String: Any] = ["targetId": target.targetID.uuidString.lowercased(), "action": "status",
                "_jtsClientID": clientID, "_jtsClientDisplayIdentity": params["_jtsClientDisplayIdentity"] as? String ?? clientID]
            do {
                var route = try await CompanionDeviceMCPHandler.shared.handle(tool: .status, target: target, arguments: arguments)
                if let saved = try await CompanionDesktopRuntime.shared.route(for: target) {
                    var desktop: [String: Any] = ["route": saved.effectiveDesktopRoute.rawValue,
                        "transport": saved.effectiveDesktopRoute == .companion ? "companion-desktop-relay" : "rdp",
                        "requiresRDP": saved.effectiveDesktopRoute != .companion,
                        "state": "disconnected", "ready": false]
                    if let active = CompanionDesktopRuntime.shared.sessions[target.targetID] {
                        desktop.merge(CompanionDesktopRuntime.shared.metadata(active)) { _, new in new }
                        desktop["ready"] = active.image != nil && active.status != "unavailable"
                    }
                    route["desktop"] = desktop
                }
                routes.append(route)
            } catch {
                routes.append(["targetId": target.targetID.uuidString.lowercased(), "ready": false, "state": "unavailable"])
            }
        }
        return ["ok": true, "result": ["routes": routes]]
    }

    private func invokeWindowsTool(_ params: [String: Any]) async throws -> [String: Any] {
        guard AppReleasePolicy.includesNativeRDP else {
            throw TerminalMCPBridgeError.bridgeError("Windows/RDP MCP tools are not included in this JTS Terminal release.")
        }
        guard let modelContext else {
            throw TerminalMCPBridgeError.bridgeError("JTS Terminal model context is not available.")
        }
        let toolName = try requiredString("tool", in: params)
        let rawTargetID = try requiredString("targetId", in: params)
        guard let tool = WindowsMCPToolName(rawValue: toolName),
              let targetID = UUID(uuidString: rawTargetID) else {
            throw TerminalMCPBridgeError.bridgeError("The Windows MCP tool or targetId is invalid.")
        }
        let descriptor = FetchDescriptor<RemoteSession>()
        guard let target = try modelContext.fetch(descriptor).first(where: {
            $0.targetID == targetID && $0.connectionType == .rdp && $0.mcpEnabled && $0.isConnectable
        }) else {
            throw WindowsMCPToolError(
                code: .targetNotFound,
                message: "The requested Windows target is not MCP-enabled or connectable."
            )
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let response = try await RDPDesktopRuntimeStore.shared.handleMCP(
            tool: tool,
            target: target,
            arguments: arguments
        ).validated(for: tool, arguments: arguments)
        var result: [String: Any] = ["structuredContent": response.structuredContent]
        if let text = response.text {
            result["text"] = text
        }
        if let pngData = response.pngData {
            result["pngHandoff"] = try TerminalMCPBridgeImageHandoff.create(
                pngData: pngData,
                runtimeRoot: runtimeRoot,
                fileManager: fileManager
            ).dictionary
        }
        return ["ok": true, "result": result]
    }
    #endif

    private func openTerminal(_ params: [String: Any]) async throws -> [String: Any] {
        guard let terminalWorkspaceStore else {
            throw TerminalMCPBridgeError.bridgeError("JTS Terminal workspace is not available.")
        }
        let alias = MCPAlias.normalized(try requiredString("server", in: params))
        let waitSeconds = min(max(TimeInterval(intValue(params["waitSeconds"]) ?? 20), 1), 60)
        let session = try authorizedSession(alias: alias)
        guard let opened = terminalWorkspaceStore.openPreferredTerminal(for: session) else {
            throw TerminalMCPBridgeError.bridgeError("Server '\(alias)' does not support an interactive terminal.")
        }
        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline, !opened.processSession.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }

        var terminal = opened.info.dictionary
        terminal["pid"] = opened.processSession.pid ?? NSNull()
        terminal["didStart"] = opened.didStart
        terminal["mcpControlAuthorized"] = session.mcpAlwaysAllowTerminalControl || opened.processSession.isMCPControlEnabled
        terminal["persistentMCPControl"] = session.mcpAlwaysAllowTerminalControl
        terminal["running"] = opened.processSession.isRunning
        terminal["automationRecoveryRequired"] =
            opened.processSession.requiresStructuredCommandRecovery

        return [
            "ok": true,
            "result": terminal
        ]
    }

    private func executeTerminal(_ params: [String: Any]) async throws -> [String: Any] {
        let terminalID = try requiredString("terminalId", in: params)
        let command = try requiredString("command", in: params)
        let clientID = params["clientId"] as? String
        let timeoutSeconds = boundedTimeout(params["timeoutSeconds"], defaultSeconds: 60)
        let maxBytes = boundedByteLimit(params["maxOutputBytes"], defaultBytes: 1_048_576)
        let attached = try attachedTerminal(id: terminalID)
        let started = Date()
        let result = try await attached.processSession.runMCPCommand(
            command: command,
            timeoutSeconds: timeoutSeconds,
            maxOutputBytes: maxBytes
        )
        let finished = Date()

        audit(
            tool: "jts_terminal_exec",
            clientID: clientID,
            session: attached.remoteSession,
            summary: command,
            exitCode: result.exitCode,
            truncated: result.truncated,
            started: started,
            finished: finished
        )

        return [
            "ok": true,
            "result": [
                "terminalId": terminalID,
                "serverAlias": attached.info.serverAlias,
                "connectionType": attached.info.connectionType,
                "exitCode": result.exitCode,
                "stdout": result.stdout,
                "truncated": result.truncated,
                "durationMs": result.durationMs,
                "timedOut": result.timedOut
            ]
        ]
    }

    private func readTerminal(_ params: [String: Any]) throws -> [String: Any] {
        let terminalID = try requiredString("terminalId", in: params)
        let maxBytes = boundedByteLimit(params["maxOutputBytes"], defaultBytes: 16_384)
        let attached = try attachedTerminal(id: terminalID)
        let tail = attached.processSession.recentTranscriptTail(maxBytes: maxBytes)
        return [
            "ok": true,
            "result": [
                "terminalId": terminalID,
                "serverAlias": attached.info.serverAlias,
                "connectionType": attached.info.connectionType,
                "text": tail.text,
                "truncated": tail.truncated
            ]
        ]
    }

    private func attachedTerminal(id terminalID: String) throws -> TerminalMCPAttachedTerminal {
        guard let attached = try authorizedOpenTerminals().first(where: { $0.info.terminalID == terminalID }) else {
            throw TerminalMCPBridgeError.bridgeError("Terminal '\(terminalID)' is not authorized for MCP control or is no longer running.")
        }
        return attached
    }

    private func authorizedOpenTerminals() throws -> [TerminalMCPAttachedTerminal] {
        guard let terminalWorkspaceStore, let modelContext else {
            return []
        }
        let descriptor = FetchDescriptor<RemoteSession>()
        let sessions = try modelContext.fetch(descriptor)
        return terminalWorkspaceStore.authorizedOpenTerminals(sessions: sessions)
    }

    private func authorizedSession(alias: String) throws -> RemoteSession {
        guard let modelContext else {
            throw TerminalMCPBridgeError.bridgeError("JTS Terminal model context is not available.")
        }
        let descriptor = FetchDescriptor<RemoteSession>()
        let sessions = try modelContext.fetch(descriptor)
        guard let session = sessions.first(where: {
            $0.mcpEnabled &&
                $0.isConnectable &&
                $0.effectiveMCPAlias == alias
        }) else {
            throw TerminalMCPBridgeError.bridgeError("Server '\(alias)' is not MCP-enabled or is not a connectable terminal profile.")
        }
        return session
    }

    private func audit(
        tool: String,
        clientID: String?,
        session: RemoteSession,
        summary _: String,
        exitCode: Int,
        truncated: Bool,
        started: Date,
        finished: Date
    ) {
        guard let modelContext else { return }
        MCPAuditRecordPolicy.purgeExpired(in: modelContext, now: finished)
        modelContext.insert(MCPAuditEntry(
            clientID: MCPAuditRecordPolicy.clientIdentifier(clientID),
            toolName: tool,
            serverAlias: session.effectiveMCPAlias,
            operationSummary: MCPAuditRecordPolicy.actionCategory(for: tool),
            exitCode: exitCode,
            outputTruncated: truncated,
            startedAt: started,
            finishedAt: finished
        ))
        try? modelContext.save()
    }

    private func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else {
            throw TerminalMCPBridgeError.bridgeError("Missing required bridge parameter: \(key)")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalMCPBridgeError.bridgeError("Missing required bridge parameter: \(key)")
        }
        return value
    }

    private func boundedTimeout(_ value: Any?, defaultSeconds: TimeInterval) -> TimeInterval {
        min(max(TimeInterval(intValue(value) ?? Int(defaultSeconds)), 1), 1_800)
    }

    private func boundedByteLimit(_ value: Any?, defaultBytes: Int) -> Int {
        min(max(intValue(value) ?? defaultBytes, 1), 16 * 1_024 * 1_024)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

nonisolated enum TerminalMCPBridgeSocket {
    static func listen(path: String) throws -> Int32 {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw TerminalMCPBridgeError.socketPathTooLong(path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TerminalMCPBridgeError.socketFailure(String(cString: strerror(errno)))
        }
        do {
            try suppressSIGPIPE(on: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        copy(path: path, into: &address)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TerminalMCPBridgeError.socketFailure(message)
        }

        guard Darwin.listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TerminalMCPBridgeError.socketFailure(message)
        }
        do {
            try PrivateFileSecurity.securePrivateSocket(
                at: URL(fileURLWithPath: path)
            )
        } catch {
            Darwin.close(fd)
            _ = path.withCString { Darwin.unlink($0) }
            throw TerminalMCPBridgeError.socketFailure(
                error.localizedDescription
            )
        }
        return fd
    }

    static func connect(
        path: String,
        timeoutMilliseconds: Int,
        deadlineUptimeMilliseconds explicitDeadlineUptimeMilliseconds: Int? = nil
    ) throws -> Int32 {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw TerminalMCPBridgeError.socketPathTooLong(path)
        }
        do {
            try PrivateFileSecurity.verifyPrivateSocket(
                at: URL(fileURLWithPath: path)
            )
        } catch {
            throw TerminalMCPBridgeError.socketFailure(
                error.localizedDescription
            )
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TerminalMCPBridgeError.socketFailure(String(cString: strerror(errno)))
        }
        do {
            try suppressSIGPIPE(on: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        copy(path: path, into: &address)

        let originalFlags = Darwin.fcntl(fd, F_GETFL)
        guard originalFlags >= 0,
              Darwin.fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TerminalMCPBridgeError.socketFailure(message)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0, errno != EINPROGRESS, errno != EAGAIN {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TerminalMCPBridgeError.socketFailure(message)
        }

        if connectResult != 0 {
            let deadlineUptimeMilliseconds = explicitDeadlineUptimeMilliseconds
                ?? Int(ProcessInfo.processInfo.systemUptime * 1_000)
                    + max(1, timeoutMilliseconds)
            while true {
                let remainingMilliseconds = deadlineUptimeMilliseconds
                    - Int(ProcessInfo.processInfo.systemUptime * 1_000)
                guard remainingMilliseconds > 0 else {
                    Darwin.close(fd)
                    throw TerminalMCPBridgeError.deadlineExceeded
                }
                var descriptor = pollfd(
                    fd: fd,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let pollResult = Darwin.poll(
                    &descriptor,
                    1,
                    Int32(min(remainingMilliseconds, Int(Int32.max)))
                )
                if pollResult == 0 {
                    Darwin.close(fd)
                    throw TerminalMCPBridgeError.deadlineExceeded
                }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    let message = String(cString: strerror(errno))
                    Darwin.close(fd)
                    throw TerminalMCPBridgeError.socketFailure(message)
                }

                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                guard Darwin.getsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &socketErrorLength
                ) == 0 else {
                    let message = String(cString: strerror(errno))
                    Darwin.close(fd)
                    throw TerminalMCPBridgeError.socketFailure(message)
                }
                guard socketError == 0 else {
                    let message = String(cString: strerror(socketError))
                    Darwin.close(fd)
                    throw TerminalMCPBridgeError.socketFailure(message)
                }
                break
            }
        }

        guard Darwin.fcntl(fd, F_SETFL, originalFlags) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TerminalMCPBridgeError.socketFailure(message)
        }
        return fd
    }

    static func setTimeout(milliseconds: Int, on fd: Int32) throws {
        let boundedMilliseconds = max(1, milliseconds)
        var timeout = timeval(
            tv_sec: boundedMilliseconds / 1_000,
            tv_usec: Int32((boundedMilliseconds % 1_000) * 1_000)
        )
        let receiveResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        let sendResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard receiveResult == 0, sendResult == 0 else {
            throw TerminalMCPBridgeError.socketFailure(String(cString: strerror(errno)))
        }
    }

    static func suppressSIGPIPE(on fd: Int32) throws {
        var enabled: Int32 = 1
        guard Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw TerminalMCPBridgeError.socketFailure(String(cString: strerror(errno)))
        }
    }

    static func writeJSONLine(
        _ object: [String: Any],
        to fd: Int32,
        deadlineUptimeMilliseconds: Int? = nil
    ) throws {
        try applyRemainingTimeout(
            deadlineUptimeMilliseconds: deadlineUptimeMilliseconds,
            to: fd
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try writeAll(
            line,
            to: fd,
            deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
        )
    }

    static func readJSONLine(
        from fd: Int32,
        deadlineUptimeMilliseconds: Int? = nil
    ) throws -> [String: Any] {
        let data = try readLine(
            from: fd,
            deadlineUptimeMilliseconds: deadlineUptimeMilliseconds
        )
        try ensureDeadlineRemaining(deadlineUptimeMilliseconds)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        try ensureDeadlineRemaining(deadlineUptimeMilliseconds)
        return object
    }

    private static func readLine(
        from fd: Int32,
        maxBytes: Int = 16 * 1_024 * 1_024,
        deadlineUptimeMilliseconds: Int? = nil
    ) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            try applyRemainingTimeout(
                deadlineUptimeMilliseconds: deadlineUptimeMilliseconds,
                to: fd
            )
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                if let newlineIndex = buffer[..<count].firstIndex(of: 0x0A) {
                    data.append(buffer, count: newlineIndex)
                    return data
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if deadlineUptimeMilliseconds != nil,
                      (errno == EAGAIN || errno == EWOULDBLOCK) {
                try ensureDeadlineRemaining(deadlineUptimeMilliseconds)
                continue
            } else {
                throw TerminalMCPBridgeError.socketFailure(String(cString: strerror(errno)))
            }
        }
        guard !data.isEmpty else {
            throw TerminalMCPBridgeError.invalidResponse
        }
        return data
    }

    private static func writeAll(
        _ data: Data,
        to fd: Int32,
        deadlineUptimeMilliseconds: Int? = nil
    ) throws {
        // A peer can legitimately close after its deadline while the GUI is
        // still preparing a response. Convert EPIPE into a Swift error rather
        // than allowing SIGPIPE to terminate either bridge process.
        try suppressSIGPIPE(on: fd)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                try applyRemainingTimeout(
                    deadlineUptimeMilliseconds: deadlineUptimeMilliseconds,
                    to: fd
                )
                let count = Darwin.send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if deadlineUptimeMilliseconds != nil,
                          (errno == EAGAIN || errno == EWOULDBLOCK) {
                    try ensureDeadlineRemaining(deadlineUptimeMilliseconds)
                    continue
                } else {
                    throw TerminalMCPBridgeError.socketFailure(String(cString: strerror(errno)))
                }
            }
        }
    }

    private static func applyRemainingTimeout(
        deadlineUptimeMilliseconds: Int?,
        to fd: Int32
    ) throws {
        guard let deadlineUptimeMilliseconds else { return }
        let remainingMilliseconds = deadlineUptimeMilliseconds
            - Int(ProcessInfo.processInfo.systemUptime * 1_000)
        guard remainingMilliseconds > 0 else {
            throw TerminalMCPBridgeError.deadlineExceeded
        }
        try setTimeout(milliseconds: remainingMilliseconds, on: fd)
    }

    private static func ensureDeadlineRemaining(
        _ deadlineUptimeMilliseconds: Int?
    ) throws {
        guard let deadlineUptimeMilliseconds else { return }
        guard deadlineUptimeMilliseconds > Int(ProcessInfo.processInfo.systemUptime * 1_000) else {
            throw TerminalMCPBridgeError.deadlineExceeded
        }
    }

    private static func copy(path: String, into address: inout sockaddr_un) {
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in rawBuffer.indices {
                rawBuffer[index] = 0
            }
            rawBuffer.copyBytes(from: Array(path.utf8).prefix(rawBuffer.count - 1))
        }
    }
}
