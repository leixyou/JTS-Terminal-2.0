#if ENABLE_RDP_2
import Foundation

nonisolated enum RDPCompanionPolicy: String, CaseIterable, Codable, Sendable {
    case optional
    case required
}

nonisolated enum RDPCertificateTrustMode: String, CaseIterable, Codable, Sendable {
    /// Require normal platform trust or a user-approved pinned fingerprint.
    case systemOrPinned
    /// Require the exact persisted SHA-256 fingerprint.
    case pinnedOnly
}

nonisolated struct RDPConnectionProfile: Codable, Equatable, Sendable {
    static let defaultWidth = 1_920
    static let defaultHeight = 1_080
    static let currentClipboardPreferenceSchemaVersion = 1

    var domain: String
    var desktopWidth: Int
    var desktopHeight: Int
    var certificateTrustMode: RDPCertificateTrustMode
    var pinnedCertificateSHA256: String?
    var clipboardEnabled: Bool
    private var clipboardPreferenceSchemaVersion: Int
    var companionPolicy: RDPCompanionPolicy
    var persistentMCPControlEnabled: Bool
    var permissionPolicy: RemoteTargetPermissionPolicy

    private enum CodingKeys: String, CodingKey {
        case domain
        case desktopWidth
        case desktopHeight
        case certificateTrustMode
        case pinnedCertificateSHA256
        case clipboardEnabled
        case clipboardPreferenceSchemaVersion
        case companionPolicy
        case persistentMCPControlEnabled
        case permissionPolicy
    }

    init(
        domain: String = "",
        desktopWidth: Int = defaultWidth,
        desktopHeight: Int = defaultHeight,
        certificateTrustMode: RDPCertificateTrustMode = .systemOrPinned,
        pinnedCertificateSHA256: String? = nil,
        clipboardEnabled: Bool = true,
        companionPolicy: RDPCompanionPolicy = .optional,
        persistentMCPControlEnabled: Bool = true,
        permissionPolicy: RemoteTargetPermissionPolicy = .rdpDefault
    ) {
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.desktopWidth = min(max(desktopWidth, 640), 7_680)
        self.desktopHeight = min(max(desktopHeight, 480), 4_320)
        self.certificateTrustMode = certificateTrustMode
        self.pinnedCertificateSHA256 = Self.normalizedFingerprint(pinnedCertificateSHA256)
        self.clipboardEnabled = clipboardEnabled
        self.clipboardPreferenceSchemaVersion =
            Self.currentClipboardPreferenceSchemaVersion
        self.companionPolicy = companionPolicy
        self.persistentMCPControlEnabled = persistentMCPControlEnabled
        // Human-user clipboard redirection is a transport preference, not an
        // MCP capability. Keep clipboard outside the grant surface even when
        // the RDP text channel is enabled for the interactive desktop.
        let maximumCapabilities = permissionPolicy.maximumCapabilities.intersection(
            RemoteTargetPermissionPolicy.rdp2ReleaseCapabilities
        )
        // RDP access is persistent per registered client and exact target,
        // matching SSH. Imported legacy profiles must not restore the removed
        // idle control lease or create renewal approvals after reconnect.
        self.permissionPolicy = RemoteTargetPermissionPolicy(
            maximumCapabilities: maximumCapabilities,
            controlLeaseCapabilities: [],
            controlIdleTimeoutSeconds: permissionPolicy.controlIdleTimeoutSeconds,
            requireExternalDataConsent: permissionPolicy.requireExternalDataConsent
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let clipboardPreferenceSchemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .clipboardPreferenceSchemaVersion
        )
        // Earlier 2.0 builds encoded clipboardEnabled=false while providing
        // no user control and forcibly discarded true during decoding. A
        // missing version therefore describes the old implementation, not an
        // intentional opt-out. Migrate it once to the new default. Once the
        // version key is written, an explicit false remains stable.
        let clipboardEnabled = clipboardPreferenceSchemaVersion == nil
            ? true
            : try container.decodeIfPresent(
                Bool.self,
                forKey: .clipboardEnabled
            ) ?? true
        self.init(
            domain: try container.decodeIfPresent(String.self, forKey: .domain) ?? "",
            desktopWidth: try container.decodeIfPresent(Int.self, forKey: .desktopWidth) ?? Self.defaultWidth,
            desktopHeight: try container.decodeIfPresent(Int.self, forKey: .desktopHeight) ?? Self.defaultHeight,
            certificateTrustMode: try container.decodeIfPresent(RDPCertificateTrustMode.self, forKey: .certificateTrustMode) ?? .systemOrPinned,
            pinnedCertificateSHA256: try container.decodeIfPresent(String.self, forKey: .pinnedCertificateSHA256),
            clipboardEnabled: clipboardEnabled,
            companionPolicy: try container.decodeIfPresent(RDPCompanionPolicy.self, forKey: .companionPolicy) ?? .optional,
            persistentMCPControlEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .persistentMCPControlEnabled
            ) ?? true,
            permissionPolicy: try container.decodeIfPresent(RemoteTargetPermissionPolicy.self, forKey: .permissionPolicy) ?? .rdpDefault
        )
    }

    static func normalizedFingerprint(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .uppercased()
            .filter { $0.isHexDigit }
        return normalized.count == 64 ? normalized : nil
    }

    func validateForConnection() throws {
        if certificateTrustMode == .pinnedOnly, pinnedCertificateSHA256 == nil {
            throw RDPProfileValidationError.missingPinnedCertificate
        }
    }
}

nonisolated enum RDPProfileValidationError: LocalizedError, Equatable {
    case missingPinnedCertificate

    var errorDescription: String? {
        "Pinned-only RDP certificate trust requires a valid SHA-256 fingerprint."
    }
}

nonisolated enum RDPConnectionProfileCodec {
    static func encode(_ profile: RDPConnectionProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(profile)
    }

    static func decode(_ data: Data?) -> RDPConnectionProfile {
        guard let data,
              let profile = try? JSONDecoder().decode(RDPConnectionProfile.self, from: data) else {
            return RDPConnectionProfile()
        }
        return profile
    }
}

nonisolated enum DesktopRuntimeAvailability: String, Codable, Equatable, Sendable {
    case unavailable
    case starting
    case available
}

nonisolated enum RDPConnectionPhase: String, Codable, Equatable, Sendable {
    case closed
    case connecting
    case awaitingCertificateTrust
    case authenticating
    case connected
    case reconnecting
    case failed
}

nonisolated enum WindowsCompanionAvailability: String, Codable, Equatable, Sendable {
    case unknown
    case missing
    case incompatible
    case pairingRequired
    case ready
}

nonisolated struct WindowsCompanionState: Codable, Equatable, Sendable {
    var availability: WindowsCompanionAvailability
    var protocolVersion: Int?
    var companionVersion: String?
    var reason: String?

    static let unknown = WindowsCompanionState(availability: .unknown)
    static let missing = WindowsCompanionState(
        availability: .missing,
        reason: "Windows Companion is not connected on the RDP dynamic virtual channel."
    )
}

nonisolated struct RDPDesktopSessionState: Codable, Equatable, Sendable {
    var sessionID: UUID
    var targetID: UUID
    var phase: RDPConnectionPhase
    var runtimeAvailability: DesktopRuntimeAvailability
    var companion: WindowsCompanionState
    var stateRevision: UInt64
    var latestFrameID: UUID?
    var remotePixelWidth: Int?
    var remotePixelHeight: Int?
    var connectedAt: Date?
    var reconnectAttempt: Int?
    var reconnectMaximumAttempts: Int?
    var reconnectScheduledAt: Date?
    var lastErrorCode: String?
    var lastErrorMessage: String?
}

nonisolated struct DesktopOpenRequest: Codable, Equatable, Sendable {
    var deadlineMilliseconds: Int?
    /// Internal same-host monotonic deadline propagated by the stdio MCP
    /// process so GUI startup and bridge time consume the original budget.
    var deadlineUptimeMilliseconds: UInt64?
    /// Internal authorization identity used to scope MCP idempotency keys.
    var clientID: String?
    var idempotencyKey: String?
    var requestedPixelWidth: Int?
    var requestedPixelHeight: Int?
    /// Nil preserves the pre-existing foreground-open behavior.
    var activateWindow: Bool?
}

nonisolated struct DesktopFrameMetadata: Codable, Equatable, Sendable {
    var frameID: UUID
    var sessionID: UUID
    var stateRevision: UInt64
    var pixelWidth: Int
    var pixelHeight: Int
    var capturedAt: Date
    var mimeType: String

    init(
        frameID: UUID = UUID(),
        sessionID: UUID,
        stateRevision: UInt64,
        pixelWidth: Int,
        pixelHeight: Int,
        capturedAt: Date = Date(),
        mimeType: String = "image/png"
    ) {
        self.frameID = frameID
        self.sessionID = sessionID
        self.stateRevision = stateRevision
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capturedAt = capturedAt
        self.mimeType = mimeType
    }

    func contains(_ point: DesktopPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < pixelWidth && point.y < pixelHeight
    }
}

nonisolated struct DesktopFrame: Codable, Equatable, Sendable {
    var metadata: DesktopFrameMetadata
    var pngData: Data
}

nonisolated struct DesktopPoint: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
}

nonisolated enum DesktopMouseButton: String, CaseIterable, Codable, Hashable, Sendable {
    case left
    case middle
    case right
}

nonisolated enum DesktopActionKind: String, CaseIterable, Codable, Sendable {
    case movePointer
    case click
    case doubleClick
    case mouseDown
    case mouseUp
    case scroll
    case keyDown
    case keyUp
    case keyChord
    case typeText
    case semanticInvoke
    case semanticSetValue
    case semanticSelect
    case wait

    var requiresCoordinate: Bool {
        switch self {
        case .movePointer, .click, .doubleClick, .mouseDown, .mouseUp, .scroll:
            return true
        case .keyDown, .keyUp, .keyChord, .typeText, .semanticInvoke,
             .semanticSetValue, .semanticSelect, .wait:
            return false
        }
    }

    var requiresSelector: Bool {
        switch self {
        case .semanticInvoke, .semanticSetValue, .semanticSelect, .wait:
            return true
        default:
            return false
        }
    }
}

nonisolated struct DesktopActionRequest: Codable, Equatable, Sendable {
    var action: DesktopActionKind
    var expectedStateRevision: UInt64
    var expectedFrameID: UUID?
    var selector: String?
    var point: DesktopPoint?
    var mouseButton: DesktopMouseButton?
    var scrollDeltaX: Int?
    var scrollDeltaY: Int?
    var key: String?
    var keyChord: [String]?
    var text: String?
    var deadlineMilliseconds: Int?
    var idempotencyKey: String?

    func validate(against frame: DesktopFrameMetadata) throws {
        guard expectedStateRevision == frame.stateRevision else {
            throw DesktopActionValidationError.staleState(
                expected: expectedStateRevision,
                current: frame.stateRevision
            )
        }

        if action.requiresCoordinate {
            guard expectedFrameID == frame.frameID else {
                throw DesktopActionValidationError.staleFrame(
                    expected: expectedFrameID,
                    current: frame.frameID
                )
            }
            guard let point else {
                throw DesktopActionValidationError.missingCoordinate
            }
            guard frame.contains(point) else {
                throw DesktopActionValidationError.coordinateOutOfBounds(
                    point: point,
                    width: frame.pixelWidth,
                    height: frame.pixelHeight
                )
            }
        }

        if action.requiresSelector {
            guard selector?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw DesktopActionValidationError.missingSelector
            }
        }
    }
}

/// Rebinds input that came directly from the visible local desktop surface to
/// the newest frame observed by the app. Coordinate actions are only eligible
/// when the frame the user actually saw used the same pixel coordinate space;
/// a resize remains a real stale-frame conflict instead of risking a click at
/// a different Windows location.
nonisolated enum RDPManualDesktopActionResolver {
    static func rebind(
        _ request: DesktopActionRequest,
        observedFrame: DesktopFrameMetadata?,
        latestFrame: DesktopFrameMetadata
    ) throws -> DesktopActionRequest {
        guard let expectedFrameID = request.expectedFrameID,
              let observedFrame,
              observedFrame.frameID == expectedFrameID,
              observedFrame.sessionID == latestFrame.sessionID else {
            if request.action.requiresCoordinate {
                throw DesktopActionValidationError.unobservedCoordinateFrame(
                    expected: request.expectedFrameID
                )
            }
            throw DesktopActionValidationError.unobservedManualFrame(
                expected: request.expectedFrameID
            )
        }
        if request.action.requiresCoordinate {
            guard observedFrame.pixelWidth == latestFrame.pixelWidth,
                  observedFrame.pixelHeight == latestFrame.pixelHeight else {
                throw DesktopActionValidationError.coordinateSpaceChanged(
                    expectedWidth: observedFrame.pixelWidth,
                    expectedHeight: observedFrame.pixelHeight,
                    currentWidth: latestFrame.pixelWidth,
                    currentHeight: latestFrame.pixelHeight
                )
            }
        }

        var rebound = request
        rebound.expectedStateRevision = latestFrame.stateRevision
        rebound.expectedFrameID = latestFrame.frameID
        return rebound
    }
}

nonisolated enum DesktopActionValidationError: LocalizedError, Equatable {
    case staleState(expected: UInt64, current: UInt64)
    case staleFrame(expected: UUID?, current: UUID)
    case unobservedCoordinateFrame(expected: UUID?)
    case unobservedManualFrame(expected: UUID?)
    case coordinateSpaceChanged(
        expectedWidth: Int,
        expectedHeight: Int,
        currentWidth: Int,
        currentHeight: Int
    )
    case missingCoordinate
    case coordinateOutOfBounds(point: DesktopPoint, width: Int, height: Int)
    case missingSelector

    var errorDescription: String? {
        switch self {
        case .staleState(let expected, let current):
            return "Desktop state changed (expected revision \(expected), current \(current)). Observe again before acting."
        case .staleFrame(let expected, let current):
            return "Desktop frame changed (expected \(expected?.uuidString ?? "none"), current \(current.uuidString)). Observe again before using coordinates."
        case .unobservedCoordinateFrame(let expected):
            return "The local pointer event references a desktop frame that is no longer available (\(expected?.uuidString ?? "none")). Move the pointer and try again."
        case .unobservedManualFrame(let expected):
            return "The local keyboard event references a desktop frame that is no longer available (\(expected?.uuidString ?? "none")). Try again on the current desktop."
        case .coordinateSpaceChanged(let expectedWidth, let expectedHeight, let currentWidth, let currentHeight):
            return "The remote desktop resized from \(expectedWidth)x\(expectedHeight) to \(currentWidth)x\(currentHeight) before the local pointer event could be sent. Try again on the current frame."
        case .missingCoordinate:
            return "This desktop action requires raw framebuffer coordinates."
        case .coordinateOutOfBounds(let point, let width, let height):
            return "Desktop coordinate (\(point.x), \(point.y)) is outside the \(width)x\(height) remote framebuffer."
        case .missingSelector:
            return "This semantic desktop action requires a UI Automation selector."
        }
    }
}

#endif
