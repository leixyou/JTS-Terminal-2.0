import Foundation

/// Application-owned binding metadata. The signed transport helper supplies the
/// controller identity and proof; caller-selected public IDs alone grant nothing.
public struct CompanionIPCDesktopAuthorization: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["targetBinding", "pairingID", "controlGrantID", "desktopGrantID", "issuedAtUnixSeconds", "expiresAtUnixSeconds"]
    public let targetBinding: String
    public let pairingID, controlGrantID, desktopGrantID: UUID
    public let issuedAtUnixSeconds, expiresAtUnixSeconds: Int64

    public init(targetBinding: String, pairingID: UUID, controlGrantID: UUID,
                desktopGrantID: UUID, issuedAtUnixSeconds: Int64, expiresAtUnixSeconds: Int64) {
        self.targetBinding = targetBinding; self.pairingID = pairingID
        self.controlGrantID = controlGrantID; self.desktopGrantID = desktopGrantID
        self.issuedAtUnixSeconds = issuedAtUnixSeconds; self.expiresAtUnixSeconds = expiresAtUnixSeconds
    }
    public func validate() throws {
        guard targetBinding.utf8.count == 64, targetBinding.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }), Set([pairingID, controlGrantID, desktopGrantID]).count == 3,
            (1...253_402_300_799).contains(issuedAtUnixSeconds), expiresAtUnixSeconds > issuedAtUnixSeconds,
            (1...253_402_300_799).contains(expiresAtUnixSeconds) else { throw CompanionIPCError.invalidPayload }
        for id in [pairingID, controlGrantID, desktopGrantID] { try CompanionIPCPayloadValidation.id(id) }
    }
}
