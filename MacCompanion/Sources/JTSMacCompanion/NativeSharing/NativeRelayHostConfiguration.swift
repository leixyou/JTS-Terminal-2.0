import CryptoKit
import Foundation
import JTSCompanionTransport
import JTSRelayEnrollment

struct NativeRelayHostTrust: Codable, Equatable {
    let name: String
    let authorization: EnrollmentHostAuthorization
    var relayOrigin: String { authorization.relayOrigin }
    var controllerSPKI: Data { authorization.controllerSPKI }
    var controllerDeviceID: String { authorization.controllerDeviceID }
    var pairingID: UUID { authorization.pairingID }
    var rdpGrantID: UUID { authorization.rdpGrantID }

    init(name: String, authorization: EnrollmentHostAuthorization) {
        self.name = name
        self.authorization = authorization
    }

    func validate(hostID: String) throws {
        try authorization.validate()
        guard (1...128).contains(name.utf8.count),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: relayOrigin), try RelayEndpoint(url).canonicalOrigin == relayOrigin,
              RelayIdentity.deviceID(publicKeySPKI: controllerSPKI) == controllerDeviceID,
              controllerDeviceID != hostID else { throw CompanionStoreError.invalidIdentity }
        _ = try PairedCompanionDevice(publicKeySPKI: controllerSPKI, allowedLanes: [.rdp])
    }
}

/// This entire record is encrypted: the private identity, invitation retry
/// state and local authorization never appear in preferences or exports.
struct NativeRelayHostConfiguration: Codable {
    let version: Int
    let privateKey: Data
    var trust: NativeRelayHostTrust?
    var attempt: EnrollmentHostAttempt?
    var attemptApproved = false
    var claimSubmitted = false
    var controllerName = "我的管理电脑"
    var enabled = false
    var revocations: [NativeRelayHostRevocation] = []

    init() {
        version = 1
        privateKey = P256.Signing.PrivateKey().rawRepresentation
    }

    var identity: RelayIdentity { get throws { RelayIdentity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: privateKey)) } }

    func validate() throws {
        guard version == 1, privateKey.count == 32, !enabled || trust != nil,
              !attemptApproved || attempt != nil, !claimSubmitted || attempt != nil else { throw CompanionStoreError.invalidIdentity }
        let identity = try identity
        try trust?.validate(hostID: identity.deviceID)
        guard revocations.count <= 64,
              Set(revocations.map(\.request.revocationId)).count == revocations.count else {
            throw CompanionStoreError.invalidIdentity
        }
        for record in revocations {
            try record.validate(host: identity)
            guard trust?.authorization != record.authorization else { throw CompanionStoreError.invalidIdentity }
        }
        if let attempt {
            try attempt.validate()
            guard attempt.enrollment.verifiedClaim?.peerSPKIBase64 == identity.publicKeySPKI.base64EncodedString(), trust == nil else {
                throw CompanionStoreError.invalidIdentity
            }
        }
    }
}

struct NativeRelayHostStore {
    private let vault: CompanionCredentialVault
    init(allowAuthenticationUI: Bool = false) { vault = CompanionCredentialVault(allowAuthenticationUI: allowAuthenticationUI) }
    init(vault: CompanionCredentialVault) { self.vault = vault }

    func load() throws -> NativeRelayHostConfiguration? {
        guard let secret = try vault.read(account: "native-relay-host.v1") else { return nil }
        let value = try JSONDecoder().decode(NativeRelayHostConfiguration.self, from: Data(secret.utf8))
        try value.validate()
        return value
    }

    func save(_ configuration: NativeRelayHostConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        try vault.save(secret: String(decoding: data, as: UTF8.self), account: "native-relay-host.v1")
    }

    func create(_ configuration: NativeRelayHostConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        try vault.create(secret: String(decoding: data, as: UTF8.self), account: "native-relay-host.v1")
    }
}
