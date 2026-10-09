//
//  MobileServerEditor.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct MobileServerEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MobileServerProfile
    @State private var portText: String
    @State private var password = ""
    @State private var privateKeyPassphrase = ""
    @State private var importedPrivateKey: String?
    @State private var hasStoredPrivateKey = false
    @State private var removesStoredPrivateKey = false
    @State private var keyStatus = "No private key imported"
    @State private var isImportingPrivateKey = false
    @State private var errorMessage: String?

    let onSave: (MobileServerProfile) -> Void

    init(profile: MobileServerProfile, onSave: @escaping (MobileServerProfile) -> Void) {
        _draft = State(initialValue: profile)
        _portText = State(initialValue: "\(profile.port)")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("mobile.serverNameField")
                    TextField("Host", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("mobile.serverHostField")
                    TextField("Username", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mobile.serverUsernameField")
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                            .accessibilityIdentifier("mobile.serverPortField")
                    }
                    TextField("Remote path", text: $draft.remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mobile.serverRemotePathField")
                }

                Section {
                    SecureField("SSH password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("mobile.serverPasswordField")

                    Button {
                        isImportingPrivateKey = true
                    } label: {
                        Label("Import OpenSSH Private Key", systemImage: "key")
                    }

                    Text(keyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if importedPrivateKey != nil || (hasStoredPrivateKey && !removesStoredPrivateKey) {
                        Button(role: .destructive) {
                            removePrivateKey()
                        } label: {
                            Label("Remove Private Key", systemImage: "trash")
                        }
                    }

                    SecureField("Private key passphrase", text: $privateKeyPassphrase)
                        .textContentType(.password)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Clear a field and save to remove that saved value. Secrets stay in this device's Keychain and are never exported.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(draft.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("mobile.cancelServerButton")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!draft.isConnectable)
                    .accessibilityIdentifier("mobile.saveServerButton")
                }
            }
            .onAppear(perform: loadStoredCredentialState)
            .onChange(of: portText) { _, newValue in
                draft.port = Int(newValue) ?? 0
            }
            .fileImporter(
                isPresented: $isImportingPrivateKey,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handlePrivateKeyImport(result)
            }
        }
    }

    private func loadStoredCredentialState() {
        if let storedPassword = try? MobileCredentialStore.read(for: draft, kind: .password) {
            password = storedPassword
        }
        if let storedPassphrase = try? MobileCredentialStore.read(for: draft, kind: .privateKeyPassphrase) {
            privateKeyPassphrase = storedPassphrase
        }
        if let storedKey = try? MobileCredentialStore.read(for: draft, kind: .privateKey),
           !storedKey.isEmpty {
            hasStoredPrivateKey = true
            keyStatus = "Private key is saved for this server"
        }
    }

    private func removePrivateKey() {
        importedPrivateKey = nil
        removesStoredPrivateKey = hasStoredPrivateKey
        draft.identityFile = ""
        keyStatus = hasStoredPrivateKey
            ? "The saved private key will be removed when you save"
            : "No private key imported"
    }

    private func handlePrivateKeyImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let stopAccess = url.startAccessingSecurityScopedResource()
            defer {
                if stopAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let key = try String(contentsOf: url, encoding: .utf8)
            // The SSH client parses the OpenSSH container format only. Reject
            // PEM keys here instead of failing later at connection time.
            guard key.contains("BEGIN OPENSSH PRIVATE KEY") else {
                errorMessage = key.contains("PRIVATE KEY")
                    ? "This key uses the older PEM format. Convert it with \"ssh-keygen -p -f <key>\" and import it again."
                    : "Choose an OpenSSH private key file."
                return
            }
            importedPrivateKey = key
            removesStoredPrivateKey = false
            draft.identityFile = url.lastPathComponent
            keyStatus = "Ready to save \(url.lastPathComponent)"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            // Store passwords exactly as typed; leading or trailing spaces are
            // part of the secret. An empty field removes the saved value.
            if password.isEmpty {
                MobileCredentialStore.delete(for: draft, kind: .password)
            } else {
                try MobileCredentialStore.save(password, for: draft, kind: .password)
            }
            if let importedPrivateKey {
                try MobileCredentialStore.save(importedPrivateKey, for: draft, kind: .privateKey)
            } else if removesStoredPrivateKey {
                MobileCredentialStore.delete(for: draft, kind: .privateKey)
            }
            if privateKeyPassphrase.isEmpty {
                MobileCredentialStore.delete(for: draft, kind: .privateKeyPassphrase)
            } else {
                try MobileCredentialStore.save(privateKeyPassphrase, for: draft, kind: .privateKeyPassphrase)
            }
            onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
