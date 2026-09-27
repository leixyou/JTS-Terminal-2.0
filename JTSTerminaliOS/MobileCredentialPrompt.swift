//
//  MobileCredentialPrompt.swift
//  JTSTerminaliOS
//

import SwiftUI

enum MobileCredentialPromptReason: String, Identifiable, Equatable, Sendable {
    case missing
    case authenticationFailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missing:
            return "Password Required"
        case .authenticationFailed:
            return "Update Password"
        }
    }

    var message: String {
        switch self {
        case .missing:
            return "This imported profile does not include credentials. Enter the SSH password to connect."
        case .authenticationFailed:
            return "The server rejected the saved credential. Enter the current SSH password and try again."
        }
    }
}

struct MobilePasswordPrompt: View {
    @Environment(\.dismiss) private var dismiss

    let profile: MobileServerProfile
    let reason: MobileCredentialPromptReason
    let onSave: (String) throws -> Void

    @State private var password = ""
    @State private var errorMessage: String?
    @FocusState private var passwordIsFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: profile.address)
                        .font(.callout)
                    Text(reason.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    SecureField("SSH password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($passwordIsFocused)
                        .privacySensitive()
                        .accessibilityIdentifier("mobile.credentialPasswordField")
                        .onSubmit(saveAndConnect)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Saved only in this iPhone's Keychain. Exported profiles never include passwords.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("mobile.credentialSaveError")
                    }
                }
            }
            .navigationTitle(reason.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Connect", action: saveAndConnect)
                        .disabled(password.isEmpty)
                        .accessibilityIdentifier("mobile.credentialSaveButton")
                }
            }
            .onAppear {
                passwordIsFocused = true
            }
        }
    }

    private func saveAndConnect() {
        guard !password.isEmpty else { return }

        do {
            try onSave(password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
