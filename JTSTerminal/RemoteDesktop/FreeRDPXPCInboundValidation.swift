#if ENABLE_RDP_2
import CoreFoundation
import Foundation
import IOSurface

nonisolated struct FreeRDPValidatedDVCMessage: Sendable {
    let data: Data
    let connectionAttemptID: UUID
    let channelGeneration: UInt64
}

nonisolated struct FreeRDPValidatedClipboardText: Sendable {
    let data: Data
    let connectionAttemptID: UUID
    let isolationGeneration: UInt64
}

nonisolated enum FreeRDPXPCInboundValidation {
    static let maximumDVCBytes = 16 * 1024 * 1024
    static let maximumClipboardTextBytes = 4 * 1024 * 1024
    static let maximumFramebufferBytes = 256 * 1024 * 1024

    private static let stateKeys: Set<String> = [
        "sessionId", "connectionAttemptId", "phase", "stateRevision", "runtime", "runtimeVersion",
        "companionDVCConnected", "companionDVCGeneration", "companionInstallerClipboardReady",
        "code", "message", "certificate",
    ]
    private static let requiredStateKeys = stateKeys.subtracting([
        "code", "message", "certificate",
    ])
    private static let phases: Set<String> = [
        "connecting", "authenticating", "connected", "awaitingCertificateTrust",
        "failed", "closed",
    ]
    private static let surfaceKeys: Set<String> = [
        "sessionId", "connectionAttemptId", "frameId", "stateRevision", "width", "height", "bytesPerRow",
        "pixelFormat", "dirtyX", "dirtyY", "dirtyWidth", "dirtyHeight", "capturedAt", "surfaceSeed",
    ]
    private static let certificateKeys: Set<String> = [
        "sessionId", "connectionAttemptId", "host", "port", "commonName", "subject", "issuer", "sha256",
        "oldSha256", "changed", "hostMismatch", "pinnedMismatch", "flags",
    ]
    private static let requiredCertificateKeys = certificateKeys.subtracting(["flags"])

    static func state(_ raw: NSDictionary) -> [String: Any]? {
        guard let value = raw as? [String: Any],
              hasExactAllowedKeys(value, allowed: stateKeys, required: requiredStateKeys),
              let sessionID = boundedString(value["sessionId"], maximumLength: 128),
              UUID(uuidString: sessionID) != nil,
              let connectionAttemptID = boundedString(
                  value["connectionAttemptId"],
                  maximumLength: 36
              ),
              UUID(uuidString: connectionAttemptID) != nil,
              let phase = boundedString(value["phase"], maximumLength: 64),
              phases.contains(phase),
              integer(value["stateRevision"], minimum: 0, maximum: UInt64.max) != nil,
              boundedString(value["runtime"], maximumLength: 32) == "FreeRDP",
              boundedString(value["runtimeVersion"], maximumLength: 32) == "3.31.1",
              boolean(value["companionDVCConnected"]) != nil,
              integer(value["companionDVCGeneration"], minimum: 0, maximum: UInt64.max) != nil,
              boolean(value["companionInstallerClipboardReady"]) != nil,
              optionalString(value["code"], maximumLength: 128),
              optionalString(value["message"], maximumLength: 2_048)
        else { return nil }

        if let rawCertificate = value["certificate"] {
            guard phase == "awaitingCertificateTrust",
                  let dictionary = rawCertificate as? NSDictionary,
                  let validatedCertificate = certificate(dictionary),
                  validatedCertificate["sessionId"] as? String == sessionID,
                  validatedCertificate["connectionAttemptId"] as? String
                    == connectionAttemptID else {
                return nil
            }
        }
        return value
    }

    static func surfaceMetadata(_ raw: NSDictionary, surface: IOSurface? = nil) -> [String: Any]? {
        guard let value = raw as? [String: Any],
              hasExactAllowedKeys(value, allowed: surfaceKeys, required: surfaceKeys),
              validUUIDString(value["sessionId"], maximumLength: 128),
              validUUIDString(value["connectionAttemptId"], maximumLength: 36),
              validUUIDString(value["frameId"], maximumLength: 64),
              integer(value["stateRevision"], minimum: 0, maximum: UInt64.max) != nil,
              let width = integer(value["width"], minimum: 640, maximum: 7_680),
              let height = integer(value["height"], minimum: 480, maximum: 4_320),
              let bytesPerRow = integer(
                  value["bytesPerRow"],
                  minimum: width * 4,
                  maximum: UInt64(maximumFramebufferBytes)
              ),
              boundedString(value["pixelFormat"], maximumLength: 16) == "BGRA32",
              let dirtyX = integer(value["dirtyX"], minimum: 0, maximum: width - 1),
              let dirtyY = integer(value["dirtyY"], minimum: 0, maximum: height - 1),
              let dirtyWidth = integer(value["dirtyWidth"], minimum: 1, maximum: width),
              let dirtyHeight = integer(value["dirtyHeight"], minimum: 1, maximum: height),
              dirtyX + dirtyWidth <= width,
              dirtyY + dirtyHeight <= height,
              bytesPerRow <= UInt64(maximumFramebufferBytes) / height,
              finiteNumber(value["capturedAt"], minimum: 1) != nil,
              surfaceSeed(in: value) != nil
        else { return nil }

        if let surface {
            let allocationSize = IOSurfaceGetAllocSize(surface)
            guard allocationSize > 0,
                  allocationSize <= maximumFramebufferBytes,
                  IOSurfaceGetWidth(surface) == width,
                  IOSurfaceGetHeight(surface) == height,
                  IOSurfaceGetBytesPerRow(surface) == bytesPerRow
            else { return nil }
        }
        return value
    }

    static func surfaceSeed(in metadata: [String: Any]) -> UInt32? {
        guard let value = integer(
            metadata["surfaceSeed"],
            minimum: 0,
            maximum: UInt64(UInt32.max)
        ) else {
            return nil
        }
        return UInt32(value)
    }

    static func frameCopy(pixels: NSData, metadata: NSDictionary) -> [String: Any]? {
        guard let value = surfaceMetadata(metadata),
              let width = integer(value["width"], minimum: 640, maximum: 7_680),
              let height = integer(value["height"], minimum: 480, maximum: 4_320),
              let bytesPerRow = integer(
                  value["bytesPerRow"],
                  minimum: width * 4,
                  maximum: UInt64(maximumFramebufferBytes)
              ),
              height <= UInt64.max / bytesPerRow,
              pixels.length == Int(bytesPerRow * height),
              pixels.length <= maximumFramebufferBytes
        else { return nil }
        return value
    }

    static func certificate(_ raw: NSDictionary) -> [String: Any]? {
        guard let value = raw as? [String: Any],
              hasExactAllowedKeys(
                  value,
                  allowed: certificateKeys,
                  required: requiredCertificateKeys
              ),
              validUUIDString(value["sessionId"], maximumLength: 128),
              validUUIDString(value["connectionAttemptId"], maximumLength: 36),
              boundedString(value["host"], maximumLength: 255) != nil,
              integer(value["port"], minimum: 1, maximum: UInt64(UInt16.max)) != nil,
              boundedString(value["commonName"], maximumLength: 1_024) != nil,
              boundedString(value["subject"], maximumLength: 4_096) != nil,
              boundedString(value["issuer"], maximumLength: 4_096) != nil,
              validFingerprint(value["sha256"]),
              validOptionalFingerprint(value["oldSha256"]),
              let changed = boolean(value["changed"]),
              boolean(value["hostMismatch"]) != nil,
              let pinnedMismatch = boolean(value["pinnedMismatch"]),
              !pinnedMismatch || changed,
              value["flags"] == nil || integer(
                  value["flags"], minimum: 0, maximum: UInt64(UInt32.max)
              ) != nil
        else { return nil }
        return value
    }

    static func dvcMessage(
        _ message: NSData,
        metadata rawMetadata: NSDictionary
    ) -> FreeRDPValidatedDVCMessage? {
        let allowedKeys: Set<String> = [
            "sessionId", "connectionAttemptId", "companionDVCGeneration",
        ]
        guard message.length > 0,
              message.length <= maximumDVCBytes,
              let metadata = rawMetadata as? [String: Any],
              hasExactAllowedKeys(metadata, allowed: allowedKeys, required: allowedKeys),
              validUUIDString(metadata["sessionId"], maximumLength: 128),
              let rawAttemptID = boundedString(
                  metadata["connectionAttemptId"],
                  maximumLength: 36
              ),
              let connectionAttemptID = UUID(uuidString: rawAttemptID),
              let channelGeneration = integer(
                  metadata["companionDVCGeneration"],
                  minimum: 1,
                  maximum: UInt64.max
              ) else {
            return nil
        }
        return FreeRDPValidatedDVCMessage(
            data: message as Data,
            connectionAttemptID: connectionAttemptID,
            channelGeneration: channelGeneration
        )
    }

    static func clipboardText(
        _ text: NSData,
        metadata rawMetadata: NSDictionary
    ) -> FreeRDPValidatedClipboardText? {
        let allowedKeys: Set<String> = [
            "sessionId", "connectionAttemptId", "clipboardIsolationGeneration",
        ]
        guard text.length <= maximumClipboardTextBytes,
              let metadata = rawMetadata as? [String: Any],
              hasExactAllowedKeys(metadata, allowed: allowedKeys, required: allowedKeys),
              validUUIDString(metadata["sessionId"], maximumLength: 128),
              let rawAttemptID = boundedString(
                  metadata["connectionAttemptId"],
                  maximumLength: 36
              ),
              let connectionAttemptID = UUID(uuidString: rawAttemptID),
              let isolationGeneration = integer(
                  metadata["clipboardIsolationGeneration"],
                  minimum: 0,
                  maximum: UInt64.max
              ),
              (try? RDPTextClipboardCodec.decode(text as Data)) != nil else {
            return nil
        }
        return FreeRDPValidatedClipboardText(
            data: text as Data,
            connectionAttemptID: connectionAttemptID,
            isolationGeneration: isolationGeneration
        )
    }

    static func estimatedByteCost(of value: [String: Any]) -> Int {
        min(maximumFramebufferBytes, 256 + estimatedPropertyListByteCost(value))
    }

    private static func estimatedPropertyListByteCost(_ raw: Any) -> Int {
        if let string = raw as? String {
            return min(maximumFramebufferBytes, string.utf8.count)
        }
        if let data = raw as? NSData {
            return min(maximumFramebufferBytes, data.length)
        }
        if let dictionary = raw as? [String: Any] {
            return dictionary.reduce(into: 128) { total, entry in
                total = min(
                    maximumFramebufferBytes,
                    total + entry.key.utf8.count + estimatedPropertyListByteCost(entry.value)
                )
            }
        }
        if let array = raw as? [Any] {
            return array.reduce(into: 64) { total, element in
                total = min(
                    maximumFramebufferBytes,
                    total + estimatedPropertyListByteCost(element)
                )
            }
        }
        return MemoryLayout<UInt64>.size
    }

    private static func hasExactAllowedKeys(
        _ value: [String: Any],
        allowed: Set<String>,
        required: Set<String>
    ) -> Bool {
        let keys = Set(value.keys)
        return keys.isSubset(of: allowed) && required.isSubset(of: keys)
    }

    private static func boundedString(_ raw: Any?, maximumLength: Int) -> String? {
        guard let value = raw as? String,
              value.utf16.count <= maximumLength,
              !value.contains("\0")
        else { return nil }
        return value
    }

    private static func optionalString(_ raw: Any?, maximumLength: Int) -> Bool {
        raw == nil || boundedString(raw, maximumLength: maximumLength) != nil
    }

    private static func validUUIDString(_ raw: Any?, maximumLength: Int) -> Bool {
        guard let value = boundedString(raw, maximumLength: maximumLength) else { return false }
        return UUID(uuidString: value) != nil
    }

    private static func validFingerprint(_ raw: Any?) -> Bool {
        guard let value = boundedString(raw, maximumLength: 64), value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) ||
                (65...70).contains(scalar.value) ||
                (97...102).contains(scalar.value)
        }
    }

    private static func validOptionalFingerprint(_ raw: Any?) -> Bool {
        guard let value = boundedString(raw, maximumLength: 64) else { return false }
        return value.isEmpty || validFingerprint(value)
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func integer(
        _ raw: Any?,
        minimum: UInt64,
        maximum: UInt64
    ) -> UInt64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value,
              value >= Double(minimum), value <= Double(maximum)
        else { return nil }
        return number.uint64Value
    }

    private static func finiteNumber(_ raw: Any?, minimum: Double) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= minimum
        else { return nil }
        return number.doubleValue
    }
}

nonisolated enum FreeRDPXPCInboundAdmission: Equatable, Sendable {
    case accepted
    case firstRejection
    case rejected
}

nonisolated final class FreeRDPXPCInboundLimiter: @unchecked Sendable {
    static let defaultMaximumPendingCallbacks = 64
    static let defaultMaximumPendingBytes = 320 * 1024 * 1024

    private let lock = NSLock()
    private let maximumPendingCallbacks: Int
    private let maximumPendingBytes: Int
    private var pendingCallbacks = 0
    private var pendingBytes = 0
    private var rejected = false

    init(
        maximumPendingCallbacks: Int = defaultMaximumPendingCallbacks,
        maximumPendingBytes: Int = defaultMaximumPendingBytes
    ) {
        precondition(maximumPendingCallbacks > 0)
        precondition(maximumPendingBytes > 0)
        self.maximumPendingCallbacks = maximumPendingCallbacks
        self.maximumPendingBytes = maximumPendingBytes
    }

    var pendingCount: Int {
        lock.withLock { pendingCallbacks }
    }

    var pendingByteCount: Int {
        lock.withLock { pendingBytes }
    }

    var hasRejectedInput: Bool {
        lock.withLock { rejected }
    }

    func admit(byteCost: Int) -> FreeRDPXPCInboundAdmission {
        lock.withLock {
            guard !rejected else { return .rejected }
            guard byteCost >= 0,
                  byteCost <= maximumPendingBytes,
                  pendingCallbacks < maximumPendingCallbacks,
                  pendingBytes <= maximumPendingBytes - byteCost
            else {
                rejected = true
                return .firstRejection
            }
            pendingCallbacks += 1
            pendingBytes += byteCost
            return .accepted
        }
    }

    func reject() -> FreeRDPXPCInboundAdmission {
        lock.withLock {
            guard !rejected else { return .rejected }
            rejected = true
            return .firstRejection
        }
    }

    func complete(byteCost: Int) {
        lock.withLock {
            pendingCallbacks = max(0, pendingCallbacks - 1)
            pendingBytes = max(0, pendingBytes - max(0, byteCost))
        }
    }
}
#endif
