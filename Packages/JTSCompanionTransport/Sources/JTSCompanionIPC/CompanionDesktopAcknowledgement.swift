import Foundation

public struct CompanionDesktopAcknowledgement: CompanionIPCPayload {
    public static let requiredKeys: Set<String> = ["version", "desktopGrantId", "pairingId", "targetBinding", "companionDeviceId", "controllerDeviceId", "proofSha256", "committedAtUnixSeconds", "signatureBase64"]
    public let version: Int
    public let desktopGrantId, pairingId, targetBinding, companionDeviceId, controllerDeviceId, proofSha256: String
    public let committedAtUnixSeconds: Int64
    public let signatureBase64: String
    public func validate() throws {
        guard version == 1, (1...253_402_300_799).contains(committedAtUnixSeconds),
              let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              signature.base64EncodedString() == signatureBase64 else { throw CompanionIPCError.invalidPayload }
        for value in [targetBinding, companionDeviceId, controllerDeviceId, proofSha256] {
            guard value.utf8.count == 64, value.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw CompanionIPCError.invalidPayload }
        }
        for value in [desktopGrantId, pairingId] {
            guard let id = UUID(uuidString: value), value == id.uuidString.lowercased() else { throw CompanionIPCError.invalidPayload }
            try CompanionIPCPayloadValidation.id(id)
        }
    }
}
