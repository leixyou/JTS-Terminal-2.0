import Foundation

/// Only non-secret host preferences live in UserDefaults. Device credentials
/// and authorized clients continue to be stored in CompanionIdentityStore.
struct CompanionHostSettings: Equatable {
    var host: String
    var port = 49871
    var allowRemoteControl = true
    var automaticSharing = false
    var sharingPaused = false

    init(host: String, port: Int = 49871, allowRemoteControl: Bool = true,
         automaticSharing: Bool = false, sharingPaused: Bool = false) {
        self.host = host
        self.port = port
        self.allowRemoteControl = allowRemoteControl
        self.automaticSharing = automaticSharing
        self.sharingPaused = sharingPaused
    }
}

struct CompanionHostSettingsStore {
    private let defaults: UserDefaults
    private let key = "companion.host.preferences.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(availableAddresses: [String]) -> CompanionHostSettings {
        let fallback = availableAddresses.first ?? "127.0.0.1"
        guard let values = defaults.dictionary(forKey: key) else { return CompanionHostSettings(host: fallback) }
        let savedHost = values["host"] as? String ?? fallback
        let savedPort = values["port"] as? Int ?? 49871
        return CompanionHostSettings(
            host: availableAddresses.contains(savedHost) ? savedHost : fallback,
            port: (1024...65535).contains(savedPort) ? savedPort : 49871,
            allowRemoteControl: values["allowRemoteControl"] as? Bool ?? true,
            automaticSharing: values["automaticSharing"] as? Bool ?? false,
            sharingPaused: values["sharingPaused"] as? Bool ?? false)
    }

    func save(_ settings: CompanionHostSettings) {
        defaults.set(["host": settings.host, "port": settings.port,
                      "allowRemoteControl": settings.allowRemoteControl,
                      "automaticSharing": settings.automaticSharing,
                      "sharingPaused": settings.sharingPaused], forKey: key)
    }
}
