import Foundation
import Testing
@testable import JTSMacCompanion

struct CompanionHostSettingsTests {
    @Test func preferencesPersistWithoutDeviceCredentials() {
        let name = "JTSMacCompanion.settings-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompanionHostSettingsStore(defaults: defaults)
        let settings = CompanionHostSettings(host: "192.168.1.5", port: 50123,
            allowRemoteControl: false, automaticSharing: true, sharingPaused: true)
        store.save(settings)
        #expect(store.load(availableAddresses: ["192.168.1.5"]) == settings)
        let values = defaults.dictionary(forKey: "companion.host.preferences.v1")!
        #expect(Set(values.keys) == ["host", "port", "allowRemoteControl", "automaticSharing", "sharingPaused"])
    }

    @Test func freshInstallRequiresOptInAndUsesAvailableAddress() {
        let name = "JTSMacCompanion.settings-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CompanionHostSettingsStore(defaults: defaults).load(availableAddresses: ["10.1.1.2"])
        #expect(settings.host == "10.1.1.2")
        #expect(!settings.automaticSharing)
        #expect(!settings.sharingPaused)
    }

    @Test func changedNetworkAndInvalidPortHaveSafeDefaults() {
        let name = "JTSMacCompanion.settings-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompanionHostSettingsStore(defaults: defaults)
        store.save(CompanionHostSettings(host: "10.1.1.2", port: -1))
        let settings = store.load(availableAddresses: ["10.2.2.3"])
        #expect(settings.host == "10.2.2.3")
        #expect(settings.port == 49871)
    }
}
