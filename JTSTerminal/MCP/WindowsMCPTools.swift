#if ENABLE_RDP_2
import CryptoKit
import Foundation
import ImageIO
import zlib

nonisolated enum WindowsMCPToolName: String, CaseIterable {
    case listTargets = "jts_list_targets"
    case openDesktop = "jts_open_desktop"
    case desktopStatus = "jts_desktop_status"
    case companionPairing = "jts_companion_pairing"
    case desktopObserve = "jts_desktop_observe"
    case desktopUIA = "jts_desktop_uia"
    case desktopAction = "jts_desktop_action"
    case windowsExec = "jts_windows_exec"
    case windowsFiles = "jts_windows_files"
    case windowsTask = "jts_windows_task"
    case closeDesktop = "jts_close_desktop"

    static var activeCases: [WindowsMCPToolName] {
        AppReleasePolicy.includesNativeRDP ? allCases : []
    }

    var requiresCompanion: Bool {
        switch self {
        case .windowsExec, .windowsFiles, .windowsTask, .desktopUIA:
            return true
        case .listTargets, .openDesktop, .desktopStatus, .companionPairing, .desktopObserve,
             .desktopAction, .closeDesktop:
            return false
        }
    }
}

/// Pairing management uses the existing device desktop-control grant. It does
/// not accept client-selected identities, grants, consent flags, or raw input.
nonisolated struct WindowsMCPCompanionPairingRequest {
    enum Action: String, CaseIterable { case status, confirm, revoke }

    static let defaultDeadlineMilliseconds = 30_000
    static let deadlineRange = 100...120_000
    let action: Action
    let targetID: UUID
    let sessionID: UUID
    let deadlineMilliseconds: Int

    init(_ arguments: [String: Any]) throws {
        let allowed: Set<String> = [
            "targetId", "sessionId", "action", "deadlineMs",
            "_jtsClientID", "_jtsClientDisplayIdentity", "_jtsDeadlineUptimeMilliseconds",
        ]
        guard Set(arguments.keys).isSubset(of: allowed),
              let rawAction = arguments["action"] as? String,
              let action = Action(rawValue: rawAction),
              let target = arguments["targetId"] as? String,
              let targetID = UUID(uuidString: target),
              let session = arguments["sessionId"] as? String,
              let sessionID = UUID(uuidString: session) else {
            throw WindowsMCPToolError(code: .invalidArgument,
                message: "jts_companion_pairing requires targetId and sessionId UUIDs, action status, confirm or revoke, and only supported arguments.")
        }
        self.action = action
        self.targetID = targetID
        self.sessionID = sessionID
        if let value = arguments["deadlineMs"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let deadline = Int(number.stringValue),
                  Self.deadlineRange.contains(deadline) else {
                throw WindowsMCPToolError(code: .invalidArgument,
                    message: "Pairing deadlineMs must be an exact integer from 100 through 120000 milliseconds.")
            }
            deadlineMilliseconds = deadline
        } else {
            deadlineMilliseconds = Self.defaultDeadlineMilliseconds
        }
    }
}

struct WindowsMCPRuntimeAvailability: Equatable, Sendable {
    var desktopRuntimeAvailable: Bool
    var companionAvailable: Bool
    var reason: String?

    static let unavailable = WindowsMCPRuntimeAvailability(
        desktopRuntimeAvailable: false,
        companionAvailable: false,
        reason: "The native RDP runtime is not connected to the MCP control plane in this build."
    )
}

struct WindowsMCPToolResponse {
    var structuredContent: [String: Any]
    var text: String?
    var pngData: Data?

    init(
        structuredContent: [String: Any],
        text: String? = nil,
        pngData: Data? = nil
    ) {
        self.structuredContent = structuredContent
        self.text = text
        self.pngData = pngData
    }

    func mcpResult() throws -> [String: Any] {
        let renderedText: String
        if let text {
            renderedText = text
        } else {
            let data = try JSONSerialization.data(withJSONObject: structuredContent, options: [.sortedKeys])
            renderedText = String(decoding: data, as: UTF8.self)
        }

        var content: [[String: Any]] = [["type": "text", "text": renderedText]]
        if let pngData, !pngData.isEmpty {
            content.append([
                "type": "image",
                "data": pngData.base64EncodedString(),
                "mimeType": "image/png",
            ])
        }
        return [
            "content": content,
            "structuredContent": structuredContent,
            "isError": false,
        ]
    }

    func validated(
        for tool: WindowsMCPToolName,
        arguments: [String: Any]
    ) throws -> WindowsMCPToolResponse {
        if tool == .desktopObserve {
            try validateDesktopObservation(arguments: arguments)
            return self
        }
        if tool == .companionPairing {
            let request = try WindowsMCPCompanionPairingRequest(arguments)
            guard structuredContent["ok"] as? Bool == true,
                  Self.uuid(structuredContent["targetId"]) == request.targetID,
                  Self.uuid(structuredContent["sessionId"]) == request.sessionID,
                  structuredContent["action"] as? String == request.action.rawValue,
                  let state = structuredContent["state"] as? String, !state.isEmpty else {
                throw WindowsMCPToolError(code: .runtimeFailure,
                    message: "Companion pairing result did not match the requested target, session, action and state.")
            }
            return self
        }
        if tool.requiresCompanion {
            try validateCompanionProvenance(arguments: arguments)
            if tool == .desktopUIA {
                try validateUIAObservation(arguments: arguments)
            }
            if tool != .windowsTask {
                guard structuredContent["ok"] as? Bool == true else {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "Windows Companion returned a non-success result for \(tool.rawValue)."
                    )
                }
            }
        }
        guard tool == .windowsTask else { return self }
        guard let rawAction = arguments["action"] as? String,
              let action = RemoteTaskAction(rawValue: rawAction) else {
            throw WindowsMCPToolError(
                code: .invalidArgument,
                message: "jts_windows_task action is invalid."
            )
        }
        guard structuredContent["ok"] is Bool,
              action == .doctor || structuredContent["ok"] as? Bool == true else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: "Windows task runtime returned a success result without ok=true."
            )
        }
        guard let state = structuredContent["state"] as? String, !state.isEmpty else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: "Windows task runtime returned no structured state."
            )
        }
        if action != .doctor {
            guard let requestedJobID = arguments["jobId"] as? String,
                  !requestedJobID.isEmpty,
                  let returnedJobID = structuredContent["jobId"] as? String,
                  returnedJobID == requestedJobID else {
                throw WindowsMCPToolError(
                    code: .runtimeFailure,
                    message: "Windows task runtime returned a jobId that did not match the \(action.rawValue) request.",
                    details: [
                        "machineCode": "COMPANION_JOB_ID_MISMATCH",
                        "action": action.rawValue,
                    ]
                )
            }
        }
        if action == .collect {
            guard let bundle = structuredContent["bundleBase64"] as? String, !bundle.isEmpty,
                  let bundleData = Data(base64Encoded: bundle),
                  let sha256 = structuredContent["bundleSha256"] as? String,
                  sha256.count == 64,
                  sha256.allSatisfy(\.isHexDigit) else {
                throw WindowsMCPToolError(
                    code: .runtimeFailure,
                    message: "Windows task collect returned an invalid bundleBase64 or bundleSha256."
                )
            }
            let actualSHA256 = SHA256.hash(data: bundleData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualSHA256.caseInsensitiveCompare(sha256) == .orderedSame else {
                throw WindowsMCPToolError(
                    code: .runtimeFailure,
                    message: "Windows task collect bundle SHA-256 verification failed."
                )
            }
        }
        return self
    }

    private func validateCompanionProvenance(arguments: [String: Any]) throws {
        guard let targetID = Self.uuid(structuredContent["targetId"]),
              let requestedTargetID = Self.uuid(arguments["targetId"]),
              targetID == requestedTargetID else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: "Windows Companion response targetId did not match the requested target."
            )
        }
        guard let sessionID = Self.uuid(structuredContent["sessionId"]),
              let requestedSessionID = Self.uuid(arguments["sessionId"]),
              sessionID == requestedSessionID else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: "Windows Companion response sessionId did not match the requested desktop session."
            )
        }
        guard let proof = structuredContent["transportProof"] as? [String: Any],
              let channel = proof["channel"] as? String,
              ["companion-dvc", "companion-desktop-relay"].contains(channel) else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: "Windows Companion response did not prove execution over companion-dvc."
            )
        }
        if channel == "companion-desktop-relay" {
            guard Self.uuid(proof["desktopGrantId"]) != nil, Self.uuid(proof["pairingId"]) != nil,
                  Self.uuid(structuredContent["sessionGeneration"]) != nil,
                  Self.exactInt(structuredContent["windowsSessionId"]) != nil,
                  structuredContent["requiresRDP"] as? Bool == false else {
                throw WindowsMCPToolError(code: .runtimeFailure, message: "Native Companion provenance is incomplete.")
            }
        }
    }

    private func validateDesktopObservation(arguments: [String: Any]) throws {
        guard let pngData,
              let pngDimensions = Self.pngDimensions(pngData),
              let targetID = Self.uuid(structuredContent["targetId"]),
              let requestedTargetID = Self.uuid(arguments["targetId"]),
              targetID == requestedTargetID,
              let sessionID = Self.uuid(structuredContent["sessionId"]),
              let requestedSessionID = Self.uuid(arguments["sessionId"]),
              sessionID == requestedSessionID,
              Self.uuid(structuredContent["frameId"]) != nil,
              Self.exactUInt64(structuredContent["stateRevision"]) != nil,
              let pixelWidth = Self.exactInt(structuredContent["pixelWidth"]),
              let pixelHeight = Self.exactInt(structuredContent["pixelHeight"]),
              pixelWidth > 0,
              pixelHeight > 0,
              pngDimensions.width == pixelWidth,
              pngDimensions.height == pixelHeight,
              structuredContent["mimeType"] as? String == "image/png",
              let capturedAt = structuredContent["capturedAt"] as? String,
              Self.iso8601Date(capturedAt) != nil else {
            throw WindowsMCPToolError(
                code: .runtimeFailure,
                message: "Desktop observation returned invalid PNG content or mismatched structured metadata."
            )
        }
    }

    private static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        guard data.count >= 57,
              data.count <= TerminalMCPBridgeImageHandoff.maximumPNGBytes,
              Array(data.prefix(signature.count)) == signature else {
            return nil
        }

        var offset = signature.count
        var width: Int?
        var height: Int?
        var colorType: UInt8?
        var sawPalette = false
        var sawImageData = false
        var imageDataEnded = false

        while offset < data.count {
            guard let lengthValue = bigEndianUInt32(data, offset: offset),
                  UInt64(lengthValue) <= UInt64(Int.max),
                  data.count - offset >= 12 else {
                return nil
            }
            let length = Int(lengthValue)
            let typeOffset = offset + 4
            let payloadOffset = typeOffset + 4
            guard length <= data.count - payloadOffset - 4 else {
                return nil
            }
            let crcOffset = payloadOffset + length
            let endOffset = crcOffset + 4
            let typeBytes = Array(data[typeOffset..<payloadOffset])
            guard typeBytes.count == 4,
                  typeBytes.allSatisfy(Self.isPNGChunkLetter),
                  Self.isASCIIUppercase(typeBytes[2]),
                  let expectedCRC = bigEndianUInt32(data, offset: crcOffset),
                  crc32(data[typeOffset..<crcOffset]) == expectedCRC else {
                return nil
            }
            let type = String(decoding: typeBytes, as: UTF8.self)

            switch type {
            case "IHDR":
                guard offset == signature.count,
                      width == nil,
                      length == 13,
                      let widthValue = bigEndianUInt32(data, offset: payloadOffset),
                      let heightValue = bigEndianUInt32(data, offset: payloadOffset + 4),
                      widthValue > 0,
                      heightValue > 0,
                      widthValue <= 7_680,
                      heightValue <= 4_320,
                      UInt64(widthValue) * UInt64(heightValue) <= 33_177_600,
                      isValidPNGPixelFormat(
                        bitDepth: data[payloadOffset + 8],
                        colorType: data[payloadOffset + 9]
                      ),
                      data[payloadOffset + 10] == 0,
                      data[payloadOffset + 11] == 0,
                      data[payloadOffset + 12] <= 1 else {
                    return nil
                }
                width = Int(widthValue)
                height = Int(heightValue)
                colorType = data[payloadOffset + 9]

            case "PLTE":
                guard width != nil,
                      !sawPalette,
                      !sawImageData,
                      (3...768).contains(length),
                      length.isMultiple(of: 3),
                      colorType != 0,
                      colorType != 4 else {
                    return nil
                }
                sawPalette = true

            case "IDAT":
                guard width != nil,
                      !imageDataEnded,
                      colorType != 3 || sawPalette else {
                    return nil
                }
                sawImageData = true

            case "IEND":
                guard width != nil,
                      sawImageData,
                      length == 0,
                      endOffset == data.count else {
                    return nil
                }
                guard let width, let height,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) == 1,
                      CGImageSourceGetType(source) as String? == "public.png",
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      image.width == width,
                      image.height == height else {
                    return nil
                }
                return (width, height)

            default:
                guard width != nil,
                      !Self.isASCIIUppercase(typeBytes[0]) else {
                    return nil
                }
                if sawImageData {
                    imageDataEnded = true
                }
            }
            offset = endOffset
        }
        return nil
    }

    private static func isValidPNGPixelFormat(bitDepth: UInt8, colorType: UInt8) -> Bool {
        switch colorType {
        case 0:
            return [1, 2, 4, 8, 16].contains(bitDepth)
        case 2, 4, 6:
            return [8, 16].contains(bitDepth)
        case 3:
            return [1, 2, 4, 8].contains(bitDepth)
        default:
            return false
        }
    }

    nonisolated private static func isPNGChunkLetter(_ byte: UInt8) -> Bool {
        isASCIIUppercase(byte) || (0x61...0x7a).contains(byte)
    }

    nonisolated private static func isASCIIUppercase(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte)
    }

    private static func crc32(_ bytes: Data.SubSequence) -> UInt32 {
        bytes.withUnsafeBytes { buffer in
            var checksum = zlib.crc32(0, nil, 0)
            guard let baseAddress = buffer.baseAddress else {
                return UInt32(checksum)
            }
            var offset = 0
            while offset < buffer.count {
                let chunkLength = min(buffer.count - offset, Int(uInt.max))
                checksum = zlib.crc32(
                    checksum,
                    baseAddress
                        .advanced(by: offset)
                        .assumingMemoryBound(to: Bytef.self),
                    uInt(chunkLength)
                )
                offset += chunkLength
            }
            return UInt32(checksum)
        }
    }

    private static func bigEndianUInt32(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let value = value as? String else { return nil }
        return UUID(uuidString: value)
    }

    private static func exactInt(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let candidate = number.int64Value
        guard number.compare(NSNumber(value: candidate)) == .orderedSame,
              candidate >= Int64(Int.min),
              candidate <= Int64(Int.max) else {
            return nil
        }
        return Int(candidate)
    }

    private static func exactUInt64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int {
            return value >= 0 ? UInt64(value) : nil
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let candidate = number.uint64Value
        guard number.compare(NSNumber(value: candidate)) == .orderedSame else {
            return nil
        }
        return candidate
    }

    private static func iso8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

nonisolated struct WindowsMCPToolError: LocalizedError {
    enum Code: String, Sendable {
        case invalidArgument = "INVALID_ARGUMENT"
        case targetNotFound = "TARGET_NOT_FOUND"
        case desktopRuntimeUnavailable = "DESKTOP_RUNTIME_UNAVAILABLE"
        case companionRequired = "COMPANION_REQUIRED"
        case stateConflict = "STATE_CONFLICT"
        case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
        case deadlineExceeded = "DEADLINE_EXCEEDED"
        case sensitiveInteractionActive = "SENSITIVE_INTERACTION_ACTIVE"
        case permissionDenied = "PERMISSION_DENIED"
        case runtimeFailure = "RUNTIME_FAILURE"
    }

    var code: Code
    var message: String
    var details: [String: Any]

    init(code: Code, message: String, details: [String: Any] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    var errorDescription: String? { "\(code.rawValue): \(message)" }

    func mcpResult() -> [String: Any] {
        var error: [String: Any] = [
            "code": code.rawValue,
            "message": message,
        ]
        if !details.isEmpty {
            error["details"] = details
        }
        let structured: [String: Any] = [
            "ok": false,
            "code": code.rawValue,
            "message": message,
            "error": error,
        ]
        let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])
        let text = data.map { String(decoding: $0, as: UTF8.self) }
            ?? "{\"error\":{\"code\":\"\(code.rawValue)\"}}"
        return [
            "content": [["type": "text", "text": text]],
            "structuredContent": structured,
            "isError": true,
        ]
    }

    static let desktopRuntimeUnavailable = WindowsMCPToolError(
        code: .desktopRuntimeUnavailable,
        message: "The native RDP desktop runtime is unavailable. This build cannot open, observe, or control a Windows desktop."
    )

    static let companionRequired = WindowsMCPToolError(
        code: .companionRequired,
        message: "Windows Companion is required for UI Automation, PowerShell, files, and structured tasks. The desktop remains visual-only until Companion is paired on the RDP dynamic virtual channel."
    )

    static let desktopNotOpen = WindowsMCPToolError(
        code: .stateConflict,
        message: "Open and connect this RDP desktop in JTS Terminal before using Windows Companion tools.",
        details: [
            "machineCode": "RDP_DESKTOP_NOT_OPEN",
            "retryable": true,
        ]
    )

    static func desktopNotConnected(phase: RDPConnectionPhase) -> WindowsMCPToolError {
        WindowsMCPToolError(
            code: .stateConflict,
            message: "The RDP desktop is \(phase.rawValue), not connected. Wait for the visible desktop to connect before using Windows Companion tools.",
            details: [
                "machineCode": "RDP_DESKTOP_NOT_CONNECTED",
                "phase": phase.rawValue,
                "retryable": true,
            ]
        )
    }
}

nonisolated enum WindowsMCPDesktopActionRequestParser {
    private static let actionPayloadFields: Set<String> = [
        "expectedFrameId",
        "selector",
        "x",
        "y",
        "button",
        "scrollDeltaX",
        "scrollDeltaY",
        "key",
        "keys",
        "text",
    ]

    private static let supportedControlTypes: Set<String> = [
        "button",
        "calendar",
        "checkbox",
        "combobox",
        "custom",
        "dataitem",
        "document",
        "edit",
        "group",
        "hyperlink",
        "image",
        "list",
        "listitem",
        "menu",
        "menuitem",
        "pane",
        "progressbar",
        "radiobutton",
        "scrollbar",
        "slider",
        "spinner",
        "splitbutton",
        "statusbar",
        "tab",
        "tabitem",
        "table",
        "text",
        "thumb",
        "titlebar",
        "toolbar",
        "tree",
        "treeitem",
        "window",
    ]

    static func parse(_ arguments: [String: Any]) throws -> DesktopActionRequest {
        guard let rawAction = nonemptyString(arguments["action"]),
              let action = DesktopActionKind(rawValue: rawAction),
              let expectedStateRevision = exactUInt64(arguments["expectedStateRevision"]) else {
            throw invalid(
                "jts_desktop_action requires a valid action and exact non-negative expectedStateRevision."
            )
        }
        try validatePayloadFields(arguments, for: action)
        if let raw = arguments["expectedUiaObservationId"] {
            guard action.requiresSelector, let text = raw as? String, UUID(uuidString: text) != nil else {
                throw invalid("expectedUiaObservationId requires a UUID and a semantic action.")
            }
        }
        if arguments["idempotencyKey"] != nil,
           !action.requiresSelector {
            throw invalid(
                "idempotencyKey is supported only for semantic desktop actions handled by Windows Companion."
            )
        }

        let expectedFrameID: UUID?
        if arguments["expectedFrameId"] != nil {
            guard let rawFrameID = nonemptyString(arguments["expectedFrameId"]),
                  let parsedFrameID = UUID(uuidString: rawFrameID) else {
                throw invalid("expectedFrameId must be a desktop frame UUID.")
            }
            expectedFrameID = parsedFrameID
        } else {
            expectedFrameID = nil
        }

        let point: DesktopPoint?
        switch (arguments["x"], arguments["y"]) {
        case (nil, nil):
            point = nil
        case let (rawX?, rawY?):
            guard let x = exactInt(rawX), let y = exactInt(rawY) else {
                throw invalid("x and y must be exact integer framebuffer coordinates.")
            }
            point = DesktopPoint(x: x, y: y)
        default:
            throw invalid("x and y must be supplied together.")
        }

        let selector = try optionalBoundedString(
            arguments["selector"],
            name: "selector",
            maximumCharacters: 32_768
        )
        if action.requiresCoordinate {
            guard expectedFrameID != nil, point != nil else {
                throw invalid(
                    "Coordinate desktop actions require expectedFrameId plus exact x and y framebuffer coordinates."
                )
            }
            guard selector == nil else {
                throw invalid(
                    "Coordinate and selector modes cannot be mixed. Use a semantic action when a UI Automation selector is available."
                )
            }
        }
        if action.requiresSelector {
            guard selector != nil else {
                throw invalid("Semantic desktop actions require a non-empty UI Automation selector.")
            }
            guard point == nil, expectedFrameID == nil else {
                throw invalid("Semantic selector actions cannot include coordinate-frame input.")
            }
            try validateSelector(selector!, requiresMutationIdentity: action != .wait)
        }

        let mouseButton: DesktopMouseButton?
        if arguments["button"] != nil {
            guard let rawButton = nonemptyString(arguments["button"]),
                  let parsedButton = DesktopMouseButton(rawValue: rawButton) else {
                throw invalid("button must be a supported mouse button.")
            }
            mouseButton = parsedButton
        } else {
            mouseButton = nil
        }

        let scrollDeltaY = try optionalExactInt(arguments["scrollDeltaY"], name: "scrollDeltaY")
        if action == .scroll {
            guard let scrollDeltaY,
                  scrollDeltaY != 0,
                  (-32_767...32_767).contains(scrollDeltaY) else {
                throw invalid("scroll requires scrollDeltaY between -32,767 and 32,767, excluding zero.")
            }
        }

        let key = try optionalBoundedString(
            arguments["key"],
            name: "key",
            maximumCharacters: 64
        )
        if action == .keyDown || action == .keyUp {
            guard key != nil else {
                throw invalid("\(action.rawValue) requires a non-empty key.")
            }
        }

        let keyChord = try optionalStringArray(
            arguments["keys"],
            name: "keys",
            maximumCount: 32,
            maximumCharacters: 64
        )
        if action == .keyChord {
            guard let keyChord, !keyChord.isEmpty else {
                throw invalid("keyChord requires one to thirty-two non-empty keys.")
            }
        }

        let text = try optionalBoundedString(
            arguments["text"],
            name: "text",
            maximumCharacters: 32_768,
            allowEmpty: action == .typeText || action == .semanticSetValue
        )
        if action == .typeText || action == .semanticSetValue {
            guard text != nil else {
                throw invalid("\(action.rawValue) requires an explicit text value.")
            }
        }

        return DesktopActionRequest(
            action: action,
            expectedStateRevision: expectedStateRevision,
            expectedFrameID: expectedFrameID,
            selector: selector,
            point: point,
            mouseButton: mouseButton,
            scrollDeltaX: nil,
            scrollDeltaY: scrollDeltaY,
            key: key,
            keyChord: keyChord,
            text: text,
            deadlineMilliseconds: try optionalExactInt(arguments["deadlineMs"], name: "deadlineMs"),
            idempotencyKey: try optionalBoundedString(
                arguments["idempotencyKey"],
                name: "idempotencyKey",
                maximumCharacters: 256
            )
        )
    }

    private static func validatePayloadFields(
        _ arguments: [String: Any],
        for action: DesktopActionKind
    ) throws {
        let allowed: Set<String>
        switch action {
        case .movePointer:
            allowed = ["expectedFrameId", "x", "y"]
        case .click, .doubleClick, .mouseDown, .mouseUp:
            allowed = ["expectedFrameId", "x", "y", "button"]
        case .scroll:
            allowed = ["expectedFrameId", "x", "y", "scrollDeltaY"]
        case .keyDown, .keyUp:
            allowed = ["key"]
        case .keyChord:
            allowed = ["keys"]
        case .typeText:
            allowed = ["text"]
        case .semanticInvoke, .semanticSelect, .wait:
            allowed = ["selector"]
        case .semanticSetValue:
            allowed = ["selector", "text"]
        }

        let unexpected = actionPayloadFields
            .intersection(arguments.keys)
            .subtracting(allowed)
            .sorted()
        guard unexpected.isEmpty else {
            throw invalid(
                "\(action.rawValue) does not accept desktop action field(s): \(unexpected.joined(separator: ", "))."
            )
        }
    }

    private static func optionalExactInt(_ value: Any?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let parsed = exactInt(value) else {
            throw invalid("\(name) must be an exact integer.")
        }
        return parsed
    }

    static func validateSelector(
        _ selector: String,
        requiresMutationIdentity: Bool
    ) throws {
        guard let data = selector.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !dictionary.isEmpty,
              Set(dictionary.keys).isSubset(of: Set([
                  "automationId",
                  "name",
                  "controlType",
                  "processId",
              ])) else {
            throw invalid("UI Automation selectors must be a non-empty JSON object with supported fields.")
        }

        let automationID = try selectorString(dictionary, key: "automationId")
        let name = try selectorString(dictionary, key: "name")
        let controlType = try selectorString(dictionary, key: "controlType")
        let processID: Int?
        if let rawProcessID = dictionary["processId"] {
            // JSON booleans also bridge to Swift Int; the Companion DTO accepts
            // only a JSON integer for processId.
            guard let number = rawProcessID as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let parsedProcessID = Int(number.stringValue),
                  (1...Int(Int32.max)).contains(parsedProcessID) else {
                throw invalid("UI Automation selector processId must be an integer from 1 through \(Int32.max).")
            }
            processID = parsedProcessID
        } else {
            processID = nil
        }

        if let controlType,
           !supportedControlTypes.contains(controlType.lowercased()) {
            throw invalid("UI Automation selector controlType is not supported.")
        }
        guard automationID != nil || name != nil || controlType != nil || processID != nil else {
            throw invalid("At least one UI Automation selector field is required.")
        }
        guard !requiresMutationIdentity || processID != nil else {
            throw invalid(
                "UI Automation mutations require a JSON selector with an explicit positive processId."
            )
        }
        guard !requiresMutationIdentity || automationID != nil || name != nil else {
            throw invalid(
                "UI Automation mutations require automationId or name in addition to processId."
            )
        }
    }

    private static func selectorString(
        _ dictionary: [String: Any],
        key: String
    ) throws -> String? {
        guard let value = dictionary[key] else { return nil }
        guard let string = value as? String,
              !string.contains("\0"),
              string.utf16.count <= 4_096,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid(
                "UI Automation selector \(key) must be a non-empty string of at most 4,096 characters."
            )
        }
        return string
    }

    private static func optionalBoundedString(
        _ value: Any?,
        name: String,
        maximumCharacters: Int,
        allowEmpty: Bool = false
    ) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String,
              !string.contains("\0"),
              string.utf16.count <= maximumCharacters,
              allowEmpty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid(
                "\(name) must contain \(allowEmpty ? "at most" : "1 to") \(maximumCharacters) characters and no NUL byte."
            )
        }
        return string
    }

    private static func optionalStringArray(
        _ value: Any?,
        name: String,
        maximumCount: Int,
        maximumCharacters: Int
    ) throws -> [String]? {
        guard let value else { return nil }
        guard let values = value as? [Any],
              values.count <= maximumCount else {
            throw invalid("\(name) must contain at most \(maximumCount) strings.")
        }
        return try values.map { value in
            guard let string = try optionalBoundedString(
                value,
                name: name,
                maximumCharacters: maximumCharacters
            ) else {
                throw invalid("\(name) contains an invalid key.")
            }
            return string
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func exactInt(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let candidate = number.int64Value
        guard number.compare(NSNumber(value: candidate)) == .orderedSame,
              candidate >= Int64(Int.min),
              candidate <= Int64(Int.max) else {
            return nil
        }
        return Int(candidate)
    }

    private static func exactUInt64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int {
            return value >= 0 ? UInt64(value) : nil
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let candidate = number.uint64Value
        guard number.compare(NSNumber(value: candidate)) == .orderedSame else {
            return nil
        }
        return candidate
    }

    private static func invalid(_ message: String) -> WindowsMCPToolError {
        WindowsMCPToolError(code: .invalidArgument, message: message)
    }
}

@MainActor
struct WindowsMCPToolDispatcher {
    typealias Handler = (
        _ tool: WindowsMCPToolName,
        _ target: RemoteSession,
        _ arguments: [String: Any]
    ) async throws -> WindowsMCPToolResponse

    var availability: WindowsMCPRuntimeAvailability
    private var handler: Handler

    init(
        availability: WindowsMCPRuntimeAvailability,
        handler: @escaping Handler
    ) {
        self.availability = availability
        self.handler = handler
    }

    func invoke(
        tool: WindowsMCPToolName,
        target: RemoteSession,
        arguments: [String: Any]
    ) async throws -> WindowsMCPToolResponse {
        try await handler(tool, target, arguments)
    }

    static let unavailable = WindowsMCPToolDispatcher(availability: .unavailable) { tool, _, _ in
        if tool.requiresCompanion {
            throw WindowsMCPToolError.companionRequired
        }
        throw WindowsMCPToolError.desktopRuntimeUnavailable
    }

    static func guiBridge(
        client: TerminalMCPBridgeClient
    ) -> WindowsMCPToolDispatcher {
        WindowsMCPToolDispatcher(
            availability: WindowsMCPRuntimeAvailability(
                desktopRuntimeAvailable: true,
                companionAvailable: false,
                reason: "Desktop availability is resolved by the visible JTS Terminal GUI; Companion availability is reported per open RDP session."
            )
        ) { tool, target, arguments in
            do {
                let result = try client.invokeWindowsTool(
                    tool.rawValue,
                    targetID: target.targetID.uuidString.lowercased(),
                    arguments: arguments
                )
                guard let structured = result["structuredContent"] as? [String: Any] else {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "The JTS Terminal GUI returned no structured Windows tool result."
                    )
                }
                let pngData: Data?
                if let directData = result["_jtsPNGData"] as? Data {
                    pngData = directData
                } else if let encoded = result["pngBase64"] as? String {
                    guard let decoded = Data(base64Encoded: encoded), !decoded.isEmpty else {
                        throw WindowsMCPToolError(
                            code: .runtimeFailure,
                            message: "The JTS Terminal GUI returned invalid PNG bridge data."
                        )
                    }
                    pngData = decoded
                } else {
                    pngData = nil
                }
                if tool == .desktopObserve, pngData == nil {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "The JTS Terminal GUI returned no PNG bridge data for desktop observation."
                    )
                }
                return WindowsMCPToolResponse(
                    structuredContent: structured,
                    text: result["text"] as? String,
                    pngData: pngData
                )
            } catch let failure as WindowsMCPToolError {
                throw failure
            } catch {
                let bridgeDeadlineElapsed = {
                    guard let bridgeError = error as? TerminalMCPBridgeError else {
                        return false
                    }
                    if case .deadlineExceeded = bridgeError {
                        return true
                    }
                    return false
                }()
                if tool == .openDesktop,
                   bridgeDeadlineElapsed || (
                       Self.integer(arguments["_jtsDeadlineUptimeMilliseconds"])
                           .map { $0 <= Int(ProcessInfo.processInfo.systemUptime * 1_000) }
                           ?? false
                   ) {
                    throw WindowsMCPToolError(
                        code: .deadlineExceeded,
                        message: "The desktop open request deadline elapsed while waiting for the visible GUI.",
                        details: [
                            "machineCode": "RDP_OPEN_DEADLINE_EXCEEDED",
                            "retryable": true,
                        ]
                    )
                }
                if tool == .desktopObserve,
                   error is TerminalMCPBridgeError {
                    throw WindowsMCPToolError(
                        code: .runtimeFailure,
                        message: "The visible JTS Terminal GUI returned an invalid desktop image handoff."
                    )
                }
                throw WindowsMCPToolError(
                    code: .desktopRuntimeUnavailable,
                    message: "The visible JTS Terminal GUI bridge is unavailable: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

enum WindowsMCPToolRegistry {
    static var definitions: [[String: Any]] {
        guard AppReleasePolicy.includesNativeRDP else { return [] }
        return [
            tool(
                .listTargets,
                "List MCP-enabled JTS Terminal targets and distinguish configured capabilities from live desktop and Companion availability.",
                properties: [:]
            ),
            tool(
                .openDesktop,
                "Open a visible Windows desktop using the target's saved RDP or Companion route. Companion desktop uses the encrypted relay and does not require Windows RDP. Returns the actual transport, Windows session, execution identity and available capabilities. Existing RDP profiles retain their route.",
                properties: commonProperties.merging([
                    "deadlineMs": integerSchema(
                        "Total desktop-open budget in milliseconds. Defaults to 10,000.",
                        minimum: DesktopOpenRequestPolicy.minimumDeadlineMilliseconds,
                        maximum: DesktopOpenRequestPolicy.maximumDeadlineMilliseconds
                    ),
                    "idempotencyKey": stringSchema(
                        "Optional caller-generated key scoped to the MCP client and target. Reuse with different effective dimensions fails.",
                        minimumLength: 1,
                        maximumLength: DesktopOpenRequestPolicy.maximumIdempotencyKeyCharacters
                    ),
                    "requestedWidth": integerSchema("Optional remote framebuffer width in pixels."),
                    "requestedHeight": integerSchema("Optional remote framebuffer height in pixels."),
                    "activate": booleanSchema("Bring the desktop window to the foreground. Defaults to true; false opens/reuses it without activating the Mac app."),
                ]) { _, new in new },
                required: ["targetId"]
            ),
            tool(
                .desktopStatus,
                "Read connection, framebuffer, state revision, and Companion status for an open desktop session.",
                properties: commonProperties,
                required: ["targetId", "sessionId"]
            ),
            tool(
                .companionPairing,
                "Manage Companion pairing for an existing desktop. The device's existing AI desktop-control authorization includes delegated pairing; no separate approval is requested. status returns public enrollment metadata, confirm uses the formally enrolled device delegation, and revoke invalidates that delegation. Works before Companion pairing completes and never types into a human confirmation prompt.",
                properties: [
                    "targetId": stringSchema("Stable target UUID from jts_list_targets."),
                    "sessionId": stringSchema("Current desktop session UUID from jts_open_desktop."),
                    "action": stringEnumSchema(WindowsMCPCompanionPairingRequest.Action.allCases.map(\.rawValue), "Pairing management action."),
                    "deadlineMs": integerSchema("Operation deadline in milliseconds. Defaults to 30000.",
                        minimum: WindowsMCPCompanionPairingRequest.deadlineRange.lowerBound,
                        maximum: WindowsMCPCompanionPairingRequest.deadlineRange.upperBound),
                ],
                required: ["targetId", "sessionId", "action"]
            ),
            tool(
                .desktopObserve,
                "Capture the current remote framebuffer as image/png with frameId, raw pixel dimensions, and stateRevision metadata.",
                properties: commonProperties,
                required: ["targetId", "sessionId"]
            ),
            tool(
                .desktopUIA,
                "Read a bounded UI Automation tree or find controls in the existing paired desktop. Requires desktop observation and structural-data consent. Use observationId as expectedUiaObservationId in subsequent semantic actions; it checks session freshness, not element identity or mutation permission. Re-observe after takeover, reconnect or expiry. Runtime IDs are informational; selectors use processId, automationId, name and controlType. Bounds are Windows screen coordinates, not framebuffer coordinates.",
                properties: commonProperties.filter { $0.key != "idempotencyKey" }.merging([
                    "operation": stringEnumSchema(["snapshot", "find"], "Read operation."),
                    "maximumDepth": integerSchema("Snapshot depth, default 4.", minimum: 1, maximum: 10),
                    "maximumNodes": integerSchema("Snapshot node limit, default 200.", minimum: 1, maximum: 1_000),
                    "maximumResults": integerSchema("Find result limit, default 50.", minimum: 1, maximum: 500),
                    "selector": stringSchema("Required for find only: a JSON object containing at least one of processId (positive integer), automationId, name or controlType. Maximum UTF-8 size: 16384 bytes. Snapshot rejects selector and maximumResults; find rejects maximumDepth and maximumNodes."),
                    "deadlineMs": integerSchema("Read deadline, default 10000 milliseconds.", minimum: 100, maximum: 30_000),
                    "expectedStateRevision": integerSchema("Optional exact non-negative desktop state revision for conflict detection.", minimum: 0),
                ]) { _, new in new },
                required: ["targetId", "sessionId", "operation"]
            ),
            tool(
                .desktopAction,
                "Perform a semantic UI Automation action or a frame-bound raw keyboard/mouse action. Coordinate actions require expectedFrameId and raw remote framebuffer coordinates.",
                properties: commonProperties.merging([
                    "action": stringEnumSchema(DesktopActionKind.allCases.map(\.rawValue) + ["fillCredential"], "Desktop action kind. fillCredential is available only through the native Companion desktop."),
                    "credentialRef": stringSchema("Target-bound encrypted-vault credential reference returned in desktop status; never a password."),
                    "purpose": stringEnumSchema(["login", "elevation"], "Purpose of a native secure-desktop credential fill."),
                    "idempotencyKey": stringSchema(
                        "Optional caller-generated key for semantic Windows Companion actions only. Raw keyboard and mouse actions reject it because they are not replay-deduplicated.",
                        minimumLength: 1,
                        maximumLength: 256
                    ),
                    "expectedFrameId": stringSchema("Required frame UUID for coordinate actions."),
                    "expectedUiaObservationId": stringSchema("UIA observation UUID for semantic actions, valid for 60 seconds in the same caller/session/control generation. A valid observation tolerates framebuffer repaints; the current unique selector and mutation permission are still checked. Without it, expectedStateRevision must match the current frame."),
                    "selector": stringSchema("JSON UI Automation selector. Mutations require positive processId plus automationId or name; wait may use a broader selector."),
                    "x": integerSchema("Raw remote framebuffer x coordinate."),
                    "y": integerSchema("Raw remote framebuffer y coordinate."),
                    "button": stringEnumSchema(DesktopMouseButton.allCases.map(\.rawValue), "Mouse button."),
                    "scrollDeltaY": integerSchema("Vertical scroll delta."),
                    "key": stringSchema("Key identifier for keyDown or keyUp."),
                    "keys": arraySchema(items: stringSchema("Key identifier."), description: "Key chord identifiers."),
                    "text": stringSchema("Text or semantic value. This value must never be written to audit logs."),
                ]) { _, new in new },
                required: ["targetId", "sessionId", "action", "expectedStateRevision"]
            ),
            tool(
                .windowsExec,
                "Execute bounded PowerShell directly through Companion in the current user of an open desktop. Returns the execution identity. Companion desktop uses a separate API channel from video; RDP uses DVC. Elevated execution requires the existing elevation grant and a supported action-bound lease. Requests are never converted to terminal keystrokes.",
                properties: commonProperties.merging([
                    "command": stringSchema("PowerShell script to execute."),
                    "rootId": stringSchema("Configured Companion file-root identifier used to constrain the working directory."),
                    "cwd": stringSchema("Optional Windows working directory."),
                    "maxOutputBytes": integerSchema("Optional stdout/stderr byte limit from 1,024 through 131,072 bytes."),
                    "requiresElevation": booleanSchema("Request the signed interactive UAC broker. Defaults to false."),
                    "elevationDurationMs": integerSchema("Action-bound elevation lease duration from 1 through 900,000 milliseconds. The lease is released immediately after this command."),
                    "elevationDataScopes": arraySchema(
                        items: [
                            "type": "object",
                            "properties": [
                                "rootId": stringSchema("Configured Companion file-root identifier."),
                                "relativePath": stringSchema("Existing directory inside the configured root."),
                                "access": stringEnumSchema(["read", "readWrite"], "Allowed access inside this scope."),
                            ],
                            "required": ["rootId", "relativePath", "access"],
                            "additionalProperties": false,
                        ],
                        description: "One to sixteen explicit scopes required when requiresElevation=true."
                    ),
                ]) { _, new in new },
                required: ["targetId", "sessionId", "command"]
            ),
            tool(
                .windowsFiles,
                "Perform a bounded file operation directly through Companion in the current user of an open desktop. Returns the execution identity. Paths remain subject to existing Companion root and traversal policy.",
                properties: commonProperties.merging([
                    "operation": stringEnumSchema(RemoteFileOperation.allCases.map(\.rawValue), "File operation."),
                    "rootId": stringSchema("Configured Companion file-root identifier."),
                    "path": stringSchema("Windows source path."),
                    "destinationPath": stringSchema("Optional destination path for upload or download."),
                    "contentBase64": stringSchema("Optional base64 content for writes."),
                    "offset": integerSchema("Optional byte offset."),
                    "length": integerSchema("Optional maximum byte count."),
                    "overwrite": booleanSchema("Whether an existing destination may be replaced."),
                ]) { _, new in new },
                required: ["targetId", "sessionId", "operation", "path"]
            ),
            tool(
                .windowsTask,
                "Run a whitelisted structured worker operation directly through Companion in the current user of an open desktop. Returns the actual transport and execution identity, jobId when applicable, and bundleBase64/bundleSha256 for collect. Arbitrary task shell fields are rejected.",
                properties: commonProperties.merging([
                    "action": stringEnumSchema(RemoteTaskAction.allCases.map(\.rawValue), "Worker action."),
                    "jobId": stringSchema("Job identifier for submit, status, cancel, or collect."),
                    "bundleBase64": stringSchema("Signed input bundle for submit."),
                ]) { _, new in new },
                required: ["targetId", "sessionId", "action"]
            ),
            tool(
                .closeDesktop,
                "Close the target's desktop and cancel its in-flight AI operations. Persistent device access remains until explicitly revoked.",
                properties: commonProperties,
                required: ["targetId", "sessionId"]
            ),
        ]
    }

    private static let commonProperties: [String: Any] = [
        "targetId": stringSchema("Stable target UUID from jts_list_targets."),
        "sessionId": stringSchema("Desktop session UUID from jts_open_desktop."),
        "deadlineMs": integerSchema("Optional operation deadline budget in milliseconds."),
        "idempotencyKey": stringSchema("Optional caller-generated idempotency key."),
        "expectedStateRevision": integerSchema("Expected desktop state revision for conflict detection."),
    ]

    private static func tool(
        _ name: WindowsMCPToolName,
        _ description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        [
            "name": name.rawValue,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
        ]
    }

    private static func stringSchema(
        _ description: String,
        minimumLength: Int? = nil,
        maximumLength: Int? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let minimumLength { schema["minLength"] = minimumLength }
        if let maximumLength { schema["maxLength"] = maximumLength }
        return schema
    }

    private static func integerSchema(
        _ description: String,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        return schema
    }

    private static func booleanSchema(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func stringEnumSchema(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }

    private static func arraySchema(items: [String: Any], description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }
}

#endif
