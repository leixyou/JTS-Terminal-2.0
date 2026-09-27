//
//  TerminalBroadcastModels.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/28.
//

import Foundation

enum TerminalBroadcastPolicy {
    static let minimumTargetCount = 2
    static let maximumTargetCount = 16
    static let timeoutSeconds: TimeInterval = 60
    static let maximumOutputBytesPerPane = 64 * 1_024
}

enum TerminalBroadcastAvailability: Equatable {
    case ready
    case notStarted
    case transitioning
    case notReady
    case busy
    case processChanged
    case recoveryRequired

    var isEligible: Bool {
        self == .ready
    }
}

@MainActor
struct TerminalBroadcastTarget: Identifiable {
    let id: UUID
    let profileName: String
    let address: String
    let paneTitle: String
    let kind: TerminalWorkspaceState.Kind
    let reviewedPID: pid_t?
    let reviewedGeneration: UUID?
    let processSession: InteractiveProcessSession?

    var availability: TerminalBroadcastAvailability {
        guard let processSession,
              processSession.isRunning,
              processSession.executionGeneration != nil else {
            return .notStarted
        }
        guard processSession.executionGeneration == reviewedGeneration else {
            return .processChanged
        }
        if processSession.isSSHStartPending ||
            processSession.isReconnectScheduled ||
            processSession.pendingSSHCredentialPrompt != nil {
            return .transitioning
        }
        if processSession.requiresStructuredCommandRecovery {
            return .recoveryRequired
        }
        if processSession.isStructuredCommandBusy {
            return .busy
        }
        return processSession.isBroadcastReady ? .ready : .notReady
    }
}

struct TerminalBroadcastPaneResult: Identifiable, Equatable {
    enum Status: Equatable {
        case queued
        case running
        case succeeded
        case nonZeroExit
        case timedOut
        case notSent
        case disconnected
        case partialSend
        case cancelled
        case failed
    }

    let id: UUID
    let profileName: String
    let paneTitle: String
    let status: Status
    let exitCode: Int?
    let stdout: String
    let truncated: Bool
    let durationMs: Int
    let errorMessage: String?
    let didWriteCommandBytes: Bool
}
