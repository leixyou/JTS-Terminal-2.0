#if ENABLE_RDP_2
import Foundation

nonisolated struct WindowsMCPFileTransferPlan: Equatable, Sendable {
    static let maximumBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumBase64Characters = Int(((maximumBytes + 2) / 3) * 4)

    let operation: RemoteFileOperation
    let rootID: String
    let sourcePath: String
    let destinationPath: String?
    let content: Data?
    let offset: Int64
    let length: Int64
    let overwrite: Bool

    init(
        operation: RemoteFileOperation,
        rootID: String,
        path: String,
        arguments: [String: Any]
    ) throws {
        guard operation == .upload || operation == .download else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "A binary file transfer plan requires upload or download."
            )
        }
        self.operation = operation
        self.rootID = try Self.boundedPath(rootID, name: "rootId", maximumBytes: 64)
        sourcePath = try Self.boundedPath(path, name: "path")
        overwrite = arguments["overwrite"] as? Bool ?? false

        switch operation {
        case .upload:
            let destination = try Self.optionalBoundedPath(
                arguments["destinationPath"],
                name: "destinationPath"
            ) ?? sourcePath
            guard arguments["offset"] == nil, arguments["length"] == nil else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Atomic Windows uploads do not accept offset or length; provide the exact contentBase64 payload."
                )
            }
            guard let encoded = arguments["contentBase64"] as? String,
                  encoded.utf8.count <= Self.maximumBase64Characters,
                  let decoded = Data(base64Encoded: encoded),
                  Int64(decoded.count) <= Self.maximumBytes else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Windows upload contentBase64 is invalid or exceeds the 64 MiB MCP file limit."
                )
            }
            destinationPath = destination
            content = decoded
            offset = 0
            length = Int64(decoded.count)

        case .download:
            guard arguments["contentBase64"] == nil else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Windows downloads do not accept contentBase64."
                )
            }
            let requestedOffset = try Self.optionalInt64(arguments["offset"], name: "offset") ?? 0
            let requestedLength = try Self.optionalInt64(arguments["length"], name: "length")
                ?? Self.maximumBytes
            guard requestedOffset >= 0,
                  requestedLength >= 0,
                  requestedLength <= Self.maximumBytes else {
                throw WindowsMCPToolError(
                    code: .invalidArgument,
                    message: "Windows download offset must be nonnegative and length must be from 0 through 64 MiB."
                )
            }
            destinationPath = try Self.optionalBoundedPath(
                arguments["destinationPath"],
                name: "destinationPath"
            )
            content = nil
            offset = requestedOffset
            length = requestedLength

        case .list, .stat, .read, .write:
            preconditionFailure("Non-binary operations were rejected above.")
        }
    }

    private static func boundedPath(
        _ value: String,
        name: String,
        maximumBytes: Int = 32_768
    ) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\0"),
              value.utf8.count <= maximumBytes else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "\(name) must be a non-empty bounded value without NUL bytes."
            )
        }
        return value
    }

    private static func optionalBoundedPath(
        _ value: Any?,
        name: String
    ) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "\(name) must be a string."
            )
        }
        return try boundedPath(string, name: name)
    }

    private static func optionalInt64(_ value: Any?, name: String) throws -> Int64? {
        guard let value else { return nil }
        let parsed: Int64?
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            parsed = double.isFinite
                && double.rounded(.towardZero) == double
                && double >= Double(Int64.min)
                && double <= Double(Int64.max)
                ? Int64(double)
                : nil
        } else if let integer = value as? Int64 {
            parsed = integer
        } else if let integer = value as? Int {
            parsed = Int64(integer)
        } else if let string = value as? String {
            parsed = Int64(string)
        } else {
            parsed = nil
        }
        guard let parsed else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "\(name) must be a signed 64-bit integer."
            )
        }
        return parsed
    }
}

#endif
