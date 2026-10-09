//
//  MobileKnownHosts.swift
//  JTSTerminaliOS
//

import Crypto
import Foundation
import NIO
@preconcurrency import NIOSSH

/// A server host key that the user has not trusted yet, or that no longer
/// matches the key trusted earlier for the same endpoint.
struct MobileHostKeyChallenge: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case unknown
        case changed(previousFingerprint: String)
    }

    let host: String
    let port: Int
    let openSSHPublicKey: String
    let fingerprint: String
    let kind: Kind

    var id: String { "\(MobileKnownHostsStore.endpoint(host: host, port: port))|\(openSSHPublicKey)" }

    var endpointDescription: String { "\(host):\(port)" }

    var keyAlgorithm: String {
        openSSHPublicKey.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "ssh"
    }

    var isChangedKey: Bool {
        if case .changed = kind { return true }
        return false
    }
}

/// Trust-on-first-use store for SSH host keys. A key is only accepted after
/// the user confirmed its fingerprint; a different key for the same endpoint
/// is rejected until the user explicitly replaces the saved one.
enum MobileKnownHostsStore {
    static let storageKey = "jts-terminal-ios.known-hosts.v1"

    enum Decision: Equatable {
        case trusted
        case untrusted(MobileHostKeyChallenge)
    }

    static func endpoint(host: String, port: Int) -> String {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return "[\(normalizedHost)]:\(port)"
    }

    static func trustedKey(
        host: String,
        port: Int,
        defaults: UserDefaults = .standard
    ) -> String? {
        storedKeys(defaults: defaults)[endpoint(host: host, port: port)]
    }

    static func evaluate(
        host: String,
        port: Int,
        presentedKey: String,
        defaults: UserDefaults = .standard
    ) -> Decision {
        let presentedKey = normalizedKey(presentedKey)
        let fingerprint = fingerprint(openSSHPublicKey: presentedKey) ?? presentedKey
        guard let trustedKey = trustedKey(host: host, port: port, defaults: defaults) else {
            return .untrusted(MobileHostKeyChallenge(
                host: host,
                port: port,
                openSSHPublicKey: presentedKey,
                fingerprint: fingerprint,
                kind: .unknown
            ))
        }

        guard normalizedKey(trustedKey) == presentedKey else {
            return .untrusted(MobileHostKeyChallenge(
                host: host,
                port: port,
                openSSHPublicKey: presentedKey,
                fingerprint: fingerprint,
                kind: .changed(
                    previousFingerprint: self.fingerprint(openSSHPublicKey: trustedKey) ?? trustedKey
                )
            ))
        }

        return .trusted
    }

    static func trust(_ challenge: MobileHostKeyChallenge, defaults: UserDefaults = .standard) {
        var keys = storedKeys(defaults: defaults)
        keys[endpoint(host: challenge.host, port: challenge.port)] = normalizedKey(challenge.openSSHPublicKey)
        defaults.set(keys, forKey: storageKey)
    }

    static func forget(host: String, port: Int, defaults: UserDefaults = .standard) {
        var keys = storedKeys(defaults: defaults)
        keys.removeValue(forKey: endpoint(host: host, port: port))
        defaults.set(keys, forKey: storageKey)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    /// OpenSSH-style `SHA256:` fingerprint of the key blob, without padding.
    static func fingerprint(openSSHPublicKey: String) -> String? {
        let parts = normalizedKey(openSSHPublicKey).split(separator: " ")
        guard parts.count >= 2,
              let blob = Data(base64Encoded: String(parts[1])) else {
            return nil
        }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func normalizedKey(_ key: String) -> String {
        key.split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .joined(separator: " ")
    }

    private static func storedKeys(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}

/// Validates the server key against `MobileKnownHostsStore` and records the
/// rejected key, so the caller can ask the user to verify it.
final class MobileHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var recordedChallenge: MobileHostKeyChallenge?

    init(host: String, port: Int, defaults: UserDefaults = .standard) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.defaults = defaults
    }

    var rejectedChallenge: MobileHostKeyChallenge? {
        lock.lock()
        defer { lock.unlock() }
        return recordedChallenge
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presentedKey = String(openSSHPublicKey: hostKey)
        switch MobileKnownHostsStore.evaluate(
            host: host,
            port: port,
            presentedKey: presentedKey,
            defaults: defaults
        ) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .untrusted(let challenge):
            lock.lock()
            recordedChallenge = challenge
            lock.unlock()
            validationCompletePromise.fail(MobileNativeSSHError.hostKeyNotTrusted(challenge))
        }
    }
}
