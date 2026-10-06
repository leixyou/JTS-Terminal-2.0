import Foundation

struct CompanionEncryptedRecord {
    var account: String
    var wrappedKey: Data
    var nonce: Data
    var ciphertext: Data
    var tag: Data
    var algorithm: String
    var createdAt: String
    var updatedAt: String
}

enum CompanionVaultError: LocalizedError, Equatable {
    case accountAlreadyExists
    case recordChanged
    case database(String)
    case crypto(String)
    case boundary(String)

    var errorDescription: String? {
        switch self {
        case .accountAlreadyExists:
            return "A credential record already exists. It was not replaced."
        case .recordChanged:
            return "The credential record changed or is missing. It was not replaced."
        case .database(let message):
            return "Credential database error: \(message)"
        case .crypto(let message):
            return "Credential vault encryption error: \(message)"
        case .boundary(let message):
            return "Credential vault security boundary error: \(message)"
        }
    }
}

