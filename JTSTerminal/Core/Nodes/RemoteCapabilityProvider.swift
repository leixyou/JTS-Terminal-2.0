#if ENABLE_RDP_2
import Foundation

/// Capabilities are intentionally transport-neutral so SSH, local shells, RDP,
/// and future remote transports can share one authorization and MCP surface.
nonisolated enum RemoteCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case discovery
    case desktopObserve
    case desktopControl
    case commandExecution
    case fileAccess
    case clipboard
    case destructiveOperations
    case elevation
    case structuredTasks
}

nonisolated struct RemoteTargetDescriptor: Codable, Equatable, Sendable {
    var targetID: UUID
    var alias: String
    var name: String
    var connectionType: RemoteConnectionType
    var address: String
    var configuredCapabilities: Set<RemoteCapability>
}

extension RemoteSession {
    var remoteTargetDescriptor: RemoteTargetDescriptor {
        let capabilities: Set<RemoteCapability>
        switch connectionType {
        case .ssh:
            capabilities = [.discovery, .commandExecution, .fileAccess]
        case .localShell:
            capabilities = [.discovery, .commandExecution]
        case .macDesktop:
            capabilities = []
        case .rdp:
            capabilities = mcpPermissionPolicy.maximumCapabilities
        }

        return RemoteTargetDescriptor(
            targetID: targetID,
            alias: effectiveMCPAlias,
            name: name,
            connectionType: connectionType,
            address: address,
            configuredCapabilities: capabilities
        )
    }
}

protocol RemoteCapabilityProvider {
    var providerIdentifier: String { get }

    func supports(target: RemoteTargetDescriptor) -> Bool
    func capabilities(for target: RemoteTargetDescriptor) -> Set<RemoteCapability>
}

protocol DesktopProvider: RemoteCapabilityProvider {
    func openDesktop(
        target: RemoteTargetDescriptor,
        request: DesktopOpenRequest
    ) async throws -> RDPDesktopSessionState

    func desktopState(sessionID: UUID) async throws -> RDPDesktopSessionState
    func observeDesktop(sessionID: UUID) async throws -> DesktopFrame

    func performDesktopAction(
        sessionID: UUID,
        request: DesktopActionRequest
    ) async throws -> RDPDesktopSessionState

    func closeDesktop(sessionID: UUID) async throws
}

protocol CommandProvider: RemoteCapabilityProvider {
    func executeCommand(
        target: RemoteTargetDescriptor,
        request: RemoteCommandRequest
    ) async throws -> RemoteCommandResult
}

protocol FileProvider: RemoteCapabilityProvider {
    func performFileOperation(
        target: RemoteTargetDescriptor,
        request: RemoteFileOperationRequest
    ) async throws -> RemoteFileOperationResult
}

protocol TaskProvider: RemoteCapabilityProvider {
    func performTaskOperation(
        target: RemoteTargetDescriptor,
        request: RemoteTaskOperationRequest
    ) async throws -> RemoteTaskOperationResult
}

nonisolated struct RemoteCommandRequest: Codable, Equatable, Sendable {
    var command: String
    var workingDirectory: String?
    var deadlineMilliseconds: Int?
    var idempotencyKey: String?
}

nonisolated struct RemoteCommandResult: Codable, Equatable, Sendable {
    var exitCode: Int
    var standardOutput: String
    var standardError: String
    var durationMilliseconds: Int
    var outputTruncated: Bool
}

nonisolated enum RemoteFileOperation: String, CaseIterable, Codable, Sendable {
    case list
    case stat
    case read
    case write
    case upload
    case download
}

nonisolated struct RemoteFileOperationRequest: Codable, Equatable, Sendable {
    var operation: RemoteFileOperation
    var path: String
    var destinationPath: String?
    var contentBase64: String?
    var offset: Int64?
    var length: Int?
    var overwrite: Bool
    var deadlineMilliseconds: Int?
    var idempotencyKey: String?
}

nonisolated struct RemoteFileOperationResult: Codable, Equatable, Sendable {
    var operation: RemoteFileOperation
    var path: String
    var metadataJSON: Data?
    var contentBase64: String?
    var bytesTransferred: Int64?
    var sha256: String?
}

nonisolated enum RemoteTaskAction: String, CaseIterable, Codable, Sendable {
    case doctor
    case submit
    case status
    case cancel
    case collect
}

nonisolated struct RemoteTaskOperationRequest: Codable, Equatable, Sendable {
    var action: RemoteTaskAction
    var jobID: String?
    var bundle: Data?
    var deadlineMilliseconds: Int?
    var idempotencyKey: String?
}

nonisolated struct RemoteTaskOperationResult: Codable, Equatable, Sendable {
    var action: RemoteTaskAction
    var jobID: String?
    var status: String
    var resultBundle: Data?
    var sha256: String?
    var detailsJSON: Data?
}

#endif
