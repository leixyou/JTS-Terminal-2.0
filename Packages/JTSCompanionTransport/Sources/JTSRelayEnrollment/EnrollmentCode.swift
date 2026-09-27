import CryptoKit
import Foundation
import JTSCompanionIPC

public enum EnrollmentError: Error, Equatable, Sendable {
    case invalidCode, invalidMessage, invalidIdentity, invalidResponse, expired, changed, capacity, busy
    case remote(String)
}

/// Only explicit presentation exposes the bearer code. Persist it in the encrypted vault.
public struct EnrollmentCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let invitationId: String
    public let relayOrigin: String
    private let secret: Data
    public var description: String { "EnrollmentCode (secret omitted)" }
    public var debugDescription: String { description }

    public init(relayOrigin: String, invitationId: String = UUID().uuidString.lowercased(), secret: Data? = nil) throws {
        self.relayOrigin = try EnrollmentWire.origin(relayOrigin)
        guard EnrollmentWire.validID(invitationId) else { throw EnrollmentError.invalidCode }
        self.invitationId = invitationId
        self.secret = secret ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard self.secret.count == 32 else { throw EnrollmentError.invalidCode }
    }

    public init(_ text: String) throws {
        guard text.utf8.count <= 4096, let url = URLComponents(string: text), url.scheme == "jts-pair",
              url.host == "enroll", url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.fragment == nil, let items = url.queryItems, items.count == 3,
              Set(items.map(\.name)) == ["relay", "id", "key"], items.allSatisfy({ $0.value != nil }) else {
            throw EnrollmentError.invalidCode
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        let key = values["key"]!
        guard key.count == 43, key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let decoded = Data(base64Encoded: key.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="), Self.urlKey(decoded) == key else {
            throw EnrollmentError.invalidCode
        }
        try self.init(relayOrigin: values["relay"]!, invitationId: values["id"]!, secret: decoded)
    }

    public var presentation: String {
        var url = URLComponents(); url.scheme = "jts-pair"; url.host = "enroll"
        url.queryItems = [URLQueryItem(name: "relay", value: relayOrigin), URLQueryItem(name: "id", value: invitationId),
                         URLQueryItem(name: "key", value: Self.urlKey(secret))]
        return url.string!
    }
    public var claimToken: Data { key("relay-claim").withUnsafeBytes { Data($0) } }
    public var claimTokenHash: String { EnrollmentWire.hash(claimToken) }

    public func sealOffer(_ plaintext: Data) throws -> Data { try seal(plaintext, purpose: "offer", offer: nil) }
    public func openOffer(_ sealed: Data) throws -> Data { try open(sealed, purpose: "offer", offer: nil) }
    public func sealResponse(_ plaintext: Data, offer: Data) throws -> Data { try seal(plaintext, purpose: "response", offer: offer) }
    public func openResponse(_ sealed: Data, offer: Data) throws -> Data { try open(sealed, purpose: "response", offer: offer) }

    private func key(_ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("JTS-PAIR-1\n\(invitationId)".utf8), info: Data(purpose.utf8), outputByteCount: 32)
    }
    private func aad(_ purpose: String, _ offer: Data?) -> Data {
        Data(("JTS-PAIR-1\n\(invitationId)\n\(purpose)" + (offer.map { "\n" + EnrollmentWire.hash($0) } ?? "")).utf8)
    }
    private func seal(_ plaintext: Data, purpose: String, offer: Data?) throws -> Data {
        guard plaintext.count <= 8192 - 28 else { throw EnrollmentError.invalidMessage }
        return try AES.GCM.seal(plaintext, using: key(purpose), authenticating: aad(purpose, offer)).combined!
    }
    private func open(_ sealed: Data, purpose: String, offer: Data?) throws -> Data {
        guard (28...8192).contains(sealed.count) else { throw EnrollmentError.invalidMessage }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key(purpose), authenticating: aad(purpose, offer)) }
        catch { throw EnrollmentError.invalidMessage }
    }
    private static func urlKey(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum EnrollmentWire {
    public static func origin(_ value: String) throws -> String {
        guard value.utf8.count <= 2048, var url = URLComponents(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.path == "" || url.path == "/", url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw EnrollmentError.invalidCode }
        url.host = host.lowercased(); url.path = ""; if url.port == 443 { url.port = nil }
        guard let result = url.string else { throw EnrollmentError.invalidCode }; return result
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func validID(_ value: String) -> Bool {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { return false }
        return value != "00000000-0000-0000-0000-000000000000"
    }
    static func base64(_ value: String, maximum: Int = 8192) throws -> Data {
        guard value.utf8.count <= (maximum + 2) / 3 * 4, let data = Data(base64Encoded: value),
              data.count <= maximum, data.base64EncodedString() == value else { throw EnrollmentError.invalidMessage }
        return data
    }
    static func object(_ data: Data, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        try StrictCompanionJSON.validate(data, maximumBytes: 32768)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else {
            throw EnrollmentError.invalidMessage
        }
        return object
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
