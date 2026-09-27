//
//  MobileSessionStore.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import Foundation
import Combine

@MainActor
final class MobileSessionStore: ObservableObject {
    @Published private(set) var profiles: [MobileServerProfile] = []
    @Published var selectedProfileID: MobileServerProfile.ID?

    private let userDefaults: UserDefaults
    private var sessions: [MobileServerProfile.ID: MobileServerSession] = [:]
    private static let storageKey = "jts-terminal-ios.server-profiles"

    init(userDefaults: UserDefaults = .standard, resetPersistentState: Bool = false) {
        self.userDefaults = userDefaults
        if resetPersistentState {
            userDefaults.removeObject(forKey: Self.storageKey)
        }
        load()
        selectedProfileID = profiles.first?.id
    }

    var selectedProfile: MobileServerProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    func upsert(_ profile: MobileServerProfile) {
        var profile = profile
        profile.touch()

        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            endSession(id: profile.id)
            profiles[index] = profile
        } else {
            profiles.insert(profile, at: 0)
        }

        selectedProfileID = profile.id
        persist()
    }

    func delete(_ profile: MobileServerProfile) {
        endSession(id: profile.id)
        profiles.removeAll { $0.id == profile.id }
        MobileCredentialStore.deleteAll(for: profile)
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
        }
        persist()
    }

    func importProfiles(_ importedProfiles: [MobileServerProfile]) {
        for profile in importedProfiles {
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                endSession(id: profile.id)
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
        }
        selectedProfileID = importedProfiles.first?.id ?? selectedProfileID
        persist()
    }

    func session(for profile: MobileServerProfile) -> MobileServerSession {
        if let session = sessions[profile.id] {
            return session
        }

        let session = MobileServerSession(profile: profile)
        sessions[profile.id] = session
        return session
    }

    func hasSession(for profile: MobileServerProfile) -> Bool {
        sessions[profile.id] != nil
    }

    func endSession(for profile: MobileServerProfile) {
        endSession(id: profile.id)
    }

    #if DEBUG
    func upsertSeeded(_ profile: MobileServerProfile) {
        let duplicateIDs = profiles
            .filter { $0.account == profile.account && $0.id != profile.id }
            .map(\.id)
        duplicateIDs.forEach { endSession(id: $0) }
        profiles.removeAll { $0.account == profile.account && $0.id != profile.id }
        upsert(profile)
    }
    #endif

    func exportData() throws -> Data {
        try MobileServerProfileCodec.encode(profiles)
    }

    private func load() {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([MobileServerProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private func endSession(id: MobileServerProfile.ID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.disconnect()
        objectWillChange.send()
    }
}
