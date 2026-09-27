//
//  JTSTerminaliOSApp.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import SwiftUI

@main
struct JTSTerminaliOSApp: App {
    @StateObject private var sessionStore: MobileSessionStore

    init() {
        let resetState = ProcessInfo.processInfo.arguments.contains("-reset-mobile-state")
        if resetState {
            MobileCredentialStore.deleteAllStoredSecrets()
        }
        let store = MobileSessionStore(resetPersistentState: resetState)
        #if DEBUG
        if let seededProfile = MobileSeededProfile(arguments: ProcessInfo.processInfo.arguments) {
            var profile = seededProfile.profile
            if let existingProfile = store.profiles.first(where: { $0.account == profile.account }) {
                profile.id = existingProfile.id
            }
            if seededProfile.clearsStoredPassword {
                MobileCredentialStore.delete(for: profile, kind: .password)
            } else if let password = seededProfile.password {
                try? MobileCredentialStore.save(password, for: profile, kind: .password)
            }
            store.upsertSeeded(profile)
        }
        MobileDebugProfileImporter.importProfiles(
            arguments: ProcessInfo.processInfo.arguments,
            into: store
        )
        #endif
        _sessionStore = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(sessionStore)
        }
    }
}

#if DEBUG
private struct MobileSeededProfile {
    let profile: MobileServerProfile
    let password: String?
    let clearsStoredPassword: Bool

    init?(arguments: [String]) {
        guard let host = Self.value(after: "-mobile-seed-host", in: arguments),
              let username = Self.value(after: "-mobile-seed-username", in: arguments),
              let portValue = Self.value(after: "-mobile-seed-port", in: arguments),
              let port = Int(portValue) else {
            return nil
        }

        self.profile = MobileServerProfile(
            name: Self.value(after: "-mobile-seed-name", in: arguments) ?? "Fixture Server",
            host: host,
            username: username,
            port: port,
            remotePath: Self.value(after: "-mobile-seed-remote-path", in: arguments) ?? "/"
        )
        self.password = Self.value(after: "-mobile-seed-password", in: arguments)
        self.clearsStoredPassword = arguments.contains("-mobile-seed-clear-password")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}

private enum MobileDebugProfileImporter {
    @MainActor
    static func importProfiles(arguments: [String], into store: MobileSessionStore) {
        guard let fileName = value(after: "-mobile-import-profile-file", in: arguments),
              let documentsDirectory = FileManager.default.urls(
                  for: .documentDirectory,
                  in: .userDomainMask
              ).first else {
            return
        }

        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        let fileURL = documentsDirectory.appendingPathComponent(safeFileName)
        guard let data = try? Data(contentsOf: fileURL),
              let profiles = try? MobileServerProfileCodec.decode(data) else {
            return
        }
        store.importProfiles(profiles)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}
#endif
