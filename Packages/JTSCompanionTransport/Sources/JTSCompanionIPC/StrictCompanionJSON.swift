import Foundation

/// Bounded, duplicate-aware object validation shared by endpoint IPC and relay bindings.
/// The depth scan runs before Foundation grammar parsing, including inside arrays.
public enum StrictCompanionJSON {
    public static func validate(_ data: Data, requiredKeys: Set<String>? = nil,
                                maximumBytes: Int = CompanionIPCLimits.frameBytes) throws {
        guard maximumBytes > 0, maximumBytes <= CompanionIPCLimits.frameBytes,
              !data.isEmpty, data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else {
            throw CompanionIPCError.invalidFrame
        }
        do {
            var scanner = Scanner(bytes: Array(data))
            let keys = try scanner.object(depth: 0)
            if let requiredKeys, keys != requiredKeys { throw CompanionIPCError.invalidFrame }
            scanner.whitespace()
            guard scanner.index == scanner.bytes.count,
                  (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw CompanionIPCError.invalidFrame
            }
        } catch { throw CompanionIPCError.invalidFrame }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func expect(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { throw CompanionIPCError.invalidFrame }
            index += 1
        }
        mutating func string() throws -> String {
            whitespace(); let start = index; try expect(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 {
                    guard index < bytes.count else { throw CompanionIPCError.invalidFrame }
                    index += 1
                } else if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
            }
            throw CompanionIPCError.invalidFrame
        }
        mutating func object(depth: Int) throws -> Set<String> {
            guard depth <= CompanionIPCLimits.maximumDepth else { throw CompanionIPCError.invalidFrame }
            try expect(123); whitespace(); var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return keys }
            while index < bytes.count {
                guard keys.insert(try string()).inserted else { throw CompanionIPCError.invalidFrame }
                try expect(58); try value(depth: depth + 1); whitespace()
                if index < bytes.count && bytes[index] == 125 { index += 1; return keys }
                try expect(44)
            }
            throw CompanionIPCError.invalidFrame
        }
        mutating func value(depth: Int) throws {
            guard depth <= CompanionIPCLimits.maximumDepth else { throw CompanionIPCError.invalidFrame }
            whitespace(); guard index < bytes.count else { throw CompanionIPCError.invalidFrame }
            switch bytes[index] {
            case 123: _ = try object(depth: depth)
            case 34: _ = try string()
            case 91:
                index += 1; whitespace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                while index < bytes.count {
                    try value(depth: depth + 1); whitespace()
                    if index < bytes.count && bytes[index] == 93 { index += 1; return }
                    try expect(44)
                }
                throw CompanionIPCError.invalidFrame
            default:
                let start = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw CompanionIPCError.invalidFrame }
            }
        }
    }
}
