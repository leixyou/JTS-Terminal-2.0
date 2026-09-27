import CoreFoundation
import CryptoKit
import Foundation
import JTSCompanionIPC

enum CompanionFileContract {
    static let frameLimit = 98_304
    static let fileLimit = 10 * 1024 * 1024 * 1024

    static func parameters(_ operation: CompanionFileOperation, bytes: Data) throws -> [String: Any] {
        let fields: Set<String>
        switch operation {
        case .roots: fields = []
        case .list: fields = ["rootId", "path", "offset", "limit"]
        case .stat: fields = ["rootId", "path", "includeSha256"]
        case .read: fields = ["rootId", "path", "offset", "maximumBytes"]
        case .beginWrite: fields = ["transferId", "rootId", "path", "totalBytes", "sha256", "overwrite"]
        case .writeChunk: fields = ["transferId", "offset", "dataBase64", "final"]
        case .commitWrite: fields = ["transferId"]
        case .mkdir, .remove: fields = ["rootId", "path"]
        case .move: fields = ["rootId", "path", "destinationPath", "overwrite"]
        }
        do {
            try StrictCompanionJSON.validate(bytes, requiredKeys: fields, maximumBytes: frameLimit)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CompanionClientError.invalidRequest }
            for key in fields {
                let valid: Bool
                switch key {
                case "rootId": valid = text(object[key], maximum: 64)
                case "path", "destinationPath": valid = text(object[key], maximum: 1024)
                case "offset": valid = number(object[key], within: 0...(operation == .list ? 10_000 : fileLimit))
                case "totalBytes": valid = number(object[key], within: 0...fileLimit)
                case "limit": valid = number(object[key], within: 1...100)
                case "maximumBytes": valid = number(object[key], within: 1...32768)
                case "includeSha256", "overwrite", "final": valid = boolean(object[key]) != nil
                case "transferId": valid = uuid(object[key])
                case "sha256": valid = sha(object[key])
                case "dataBase64": valid = data(object[key]).map { $0.count <= 32768 } == true
                default: valid = false
                }
                guard valid else { throw CompanionClientError.invalidRequest }
            }
            return object
        } catch { throw CompanionClientError.invalidRequest }
    }

    static func validate(_ value: [String: Any], operation: CompanionFileOperation, parameters: [String: Any]) throws {
        var valid = false
        switch operation {
        case .roots:
            if Set(value.keys) == ["roots"], let roots = value["roots"] as? [[String: Any]], roots.count <= 64 {
                valid = roots.allSatisfy {
                    Set($0.keys) == ["id", "name", "readOnly", "maximumFileBytes"]
                        && text($0["id"], maximum: 64) && text($0["name"], maximum: 256)
                        && boolean($0["readOnly"]) != nil && number($0["maximumFileBytes"], within: 1...fileLimit)
                } && Set(roots.compactMap { $0["id"] as? String }).count == roots.count
            }
        case .list:
            if Set(value.keys) == ["entries", "nextOffset"], let entries = value["entries"] as? [[String: Any]],
               let limit = integer(parameters["limit"]), let offset = integer(parameters["offset"]) {
                valid = entries.count <= limit && entries.allSatisfy(entry)
                    && (value["nextOffset"] is NSNull || integer(value["nextOffset"]) == offset + entries.count && !entries.isEmpty)
            }
        case .stat, .mkdir, .move, .commitWrite:
            valid = entry(value)
            if operation == .stat, boolean(parameters["includeSha256"]) == true,
               boolean(value["isDirectory"]) == false { valid = valid && sha(value["sha256"]) }
        case .read:
            if Set(value.keys) == ["dataBase64", "nextOffset", "eof", "size", "sha256"],
               let bytes = data(value["dataBase64"]), let maximum = integer(parameters["maximumBytes"]),
               let offset = integer(parameters["offset"]), let next = integer(value["nextOffset"]),
               let size = integer(value["size"]), let eof = boolean(value["eof"]) {
                valid = bytes.count <= maximum && next == offset + bytes.count && (0...fileLimit).contains(size)
                    && next <= size && eof == (next == size) && (eof || !bytes.isEmpty)
                    && value["sha256"] as? String == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
        case .beginWrite:
            valid = Set(value.keys) == ["transferId", "nextOffset", "totalBytes", "sha256"]
                && value["transferId"] as? String == parameters["transferId"] as? String
                && integer(value["totalBytes"]) == integer(parameters["totalBytes"])
                && value["sha256"] as? String == parameters["sha256"] as? String
                && number(value["nextOffset"], within: 0...(integer(parameters["totalBytes"]) ?? 0))
        case .writeChunk:
            valid = Set(value.keys) == ["transferId", "nextOffset"]
                && value["transferId"] as? String == parameters["transferId"] as? String
                && integer(value["nextOffset"]) == (integer(parameters["offset"]) ?? -1) + (data(parameters["dataBase64"])?.count ?? -1)
        case .remove:
            valid = Set(value.keys) == ["removed"] && boolean(value["removed"]) == true
        }
        guard valid else { throw CompanionClientError.invalidReply }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func number(_ value: Any?, within range: ClosedRange<Int>) -> Bool {
        integer(value).map(range.contains) == true
    }
    private static func text(_ value: Any?, maximum: Int) -> Bool {
        guard let text = value as? String else { return false }
        return (1...maximum).contains(text.utf8.count) && !text.contains("\0")
    }
    private static func uuid(_ value: Any?) -> Bool {
        guard let text = value as? String, let id = UUID(uuidString: text) else { return false }
        return id.uuidString.lowercased() == text && text != "00000000-0000-0000-0000-000000000000"
    }
    private static func sha(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func data(_ value: Any?) -> Data? {
        guard let text = value as? String, let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else { return nil }
        return bytes
    }
    private static func entry(_ value: [String: Any]) -> Bool {
        Set(value.keys) == ["name", "path", "isDirectory", "size", "modifiedAtUnixMilliseconds", "sha256"]
            && text(value["name"], maximum: 4096) && text(value["path"], maximum: 4096)
            && boolean(value["isDirectory"]) != nil && number(value["size"], within: 0...fileLimit)
            && number(value["modifiedAtUnixMilliseconds"], within: -11_644_473_600_000...253_402_300_799_999)
            && (value["sha256"] is NSNull || sha(value["sha256"]))
    }
}
