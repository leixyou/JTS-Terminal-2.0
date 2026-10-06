import Foundation

/// Nonsecret safety preferences survive a vault write failure. They contain
/// no device identity, invitation, grant or key.
struct NativeRelayHostPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var paused: Bool { defaults.bool(forKey: "nativeSystemSharing.paused") }
    var pendingRevocation: Bool { defaults.bool(forKey: "nativeSystemSharing.pendingLocalRevocation") }
    func pause() { defaults.set(true, forKey: "nativeSystemSharing.paused") }
    func beginRevocation() { pause(); defaults.set(true, forKey: "nativeSystemSharing.pendingLocalRevocation") }
    func revocationPersisted() { defaults.removeObject(forKey: "nativeSystemSharing.pendingLocalRevocation") }
    func resumeExplicitly() { defaults.removeObject(forKey: "nativeSystemSharing.paused") }

    func applying(to configuration: NativeRelayHostConfiguration) -> NativeRelayHostConfiguration {
        var value = configuration
        if pendingRevocation {
            value.trust = nil
            value.attempt = nil
            value.attemptApproved = false
            value.claimSubmitted = false
            value.enabled = false
        }
        if paused { value.enabled = false }
        return value
    }
}
