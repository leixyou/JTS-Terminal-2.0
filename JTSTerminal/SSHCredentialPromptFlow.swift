//
//  SSHCredentialPromptFlow.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/17.
//

import Foundation

/// Non-secret metadata for a connection-time credential decision.
///
/// Password text deliberately never becomes part of this value. The UI keeps
/// it in a local `SecureField` binding and hands it directly to the one-shot
/// askpass broker only after the user chooses a connection action.
struct SSHCredentialPromptDescriptor: Identifiable, Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case passwordOrKeyAgent
        case jumpHostManualOnly
    }

    enum Reason: Equatable, Sendable {
        case missingSavedPassword
        case rejectedSavedPassword
    }

    let id: UUID
    let credentialAccount: String
    let displayLabel: String
    let mode: Mode
    let reason: Reason

    init(
        id: UUID,
        credentialAccount: String,
        displayLabel: String,
        mode: Mode,
        reason: Reason = .missingSavedPassword
    ) {
        self.id = id
        self.credentialAccount = credentialAccount
        self.displayLabel = displayLabel
        self.mode = mode
        self.reason = reason
    }

    var allowsPasswordSubmission: Bool {
        mode == .passwordOrKeyAgent
    }
}

enum SSHCredentialPromptChoice: Equatable, Sendable {
    case cancel
    case connectOnce
    case saveAndConnect
    case useKeyOrAgent
}

enum SSHCredentialValidationError: LocalizedError, Equatable, Sendable {
    case empty
    case tooLarge(maximumBytes: Int)
    case containsUnsupportedCharacters

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter an SSH password before connecting."
        case .tooLarge(let maximumBytes):
            return "The SSH password is larger than the supported \(maximumBytes)-byte limit."
        case .containsUnsupportedCharacters:
            return "The SSH password cannot contain a null byte or a line break."
        }
    }
}

struct SSHCredentialInputAdvisory: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case matchingASCIIQuote
        case matchingASCIISingleQuote
        case matchingCurlyDoubleQuote
        case matchingCurlySingleQuote
        case leadingOrTrailingWhitespace
        case nonASCIIPunctuation
    }

    let kind: Kind
    let utf8ByteCount: Int
}

enum SSHCredentialPromptPolicy {
    static func descriptor(
        id: UUID,
        credentialAccount: String,
        displayLabel: String,
        jumpHost: String,
        reason: SSHCredentialPromptDescriptor.Reason = .missingSavedPassword
    ) -> SSHCredentialPromptDescriptor {
        SSHCredentialPromptDescriptor(
            id: id,
            credentialAccount: credentialAccount,
            displayLabel: displayLabel,
            mode: jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .passwordOrKeyAgent
                : .jumpHostManualOnly,
            reason: reason
        )
    }

    static func validationError(
        for secret: String,
        maximumBytes: Int = SSHCredentialAskpass.maximumSecretBytes
    ) -> SSHCredentialValidationError? {
        let bytes = secret.utf8
        guard !bytes.isEmpty else { return .empty }
        guard bytes.count <= maximumBytes else {
            return .tooLarge(maximumBytes: maximumBytes)
        }
        guard !bytes.contains(0),
              !bytes.contains(10),
              !bytes.contains(13) else {
            return .containsUnsupportedCharacters
        }
        return nil
    }

    nonisolated static func inputAdvisory(for secret: String) -> SSHCredentialInputAdvisory? {
        guard !secret.isEmpty else { return nil }

        let byteCount = secret.utf8.count
        let characters = Array(secret)
        guard let first = characters.first,
              let last = characters.last else {
            return nil
        }

        if characters.count >= 2 {
            switch (String(first), String(last)) {
            case ("\"", "\""):
                return SSHCredentialInputAdvisory(
                    kind: .matchingASCIIQuote,
                    utf8ByteCount: byteCount
                )
            case ("'", "'"):
                return SSHCredentialInputAdvisory(
                    kind: .matchingASCIISingleQuote,
                    utf8ByteCount: byteCount
                )
            case ("“", "”"):
                return SSHCredentialInputAdvisory(
                    kind: .matchingCurlyDoubleQuote,
                    utf8ByteCount: byteCount
                )
            case ("‘", "’"):
                return SSHCredentialInputAdvisory(
                    kind: .matchingCurlySingleQuote,
                    utf8ByteCount: byteCount
                )
            default:
                break
            }
        }

        if first.isWhitespace || last.isWhitespace {
            return SSHCredentialInputAdvisory(
                kind: .leadingOrTrailingWhitespace,
                utf8ByteCount: byteCount
            )
        }

        if secret.unicodeScalars.contains(where: isNonASCIIPunctuation) {
            return SSHCredentialInputAdvisory(
                kind: .nonASCIIPunctuation,
                utf8ByteCount: byteCount
            )
        }

        return nil
    }

    nonisolated private static func isNonASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x7F && CharacterSet.punctuationCharacters.contains(scalar)
    }
}

/// A termination-time snapshot of signed AskPass credential delivery.
///
/// `helperCompletedResponse` means the signed helper authenticated to the
/// private broker, received the one-shot secret, wrote the complete response
/// to stdout for OpenSSH, and acknowledged that write. It does not claim the
/// remote server accepted the password.
enum SSHCredentialDeliveryState: Equatable, Sendable {
    case notApplicable
    case helperNotCompleted
    case helperCompletedResponse

    static func snapshot(
        context: SSHCredentialAskpass.LaunchContext?
    ) -> SSHCredentialDeliveryState {
        guard let context else { return .notApplicable }
        return context.credentialConsumed
            ? .helperCompletedResponse
            : .helperNotCompleted
    }
}
