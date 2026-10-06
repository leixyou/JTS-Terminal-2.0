import Foundation

public enum RelayStationError: String, Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidInput, stationNotFound, stationAlreadyKnown, capacityReached
    case corruptState, missingState, operationInProgress, storageConflict, storageUnavailable
    public var description: String { "RelayStationError.\(rawValue)" }
    public var debugDescription: String { description }
}

/// A reusable relay origin. It contains no device identity, trust, or authorization.
public struct RelayStation: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let name, relayURL: String

    public init(id: UUID, name: String, relayURL: String) {
        self.id = id; self.name = name; self.relayURL = relayURL
    }

    public var description: String { "RelayStation (contents redacted)" }
    public var debugDescription: String { description }
}

public struct RelayStationSnapshot: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let stations: [RelayStation]
    public let defaultStationID: UUID?

    public init(stations: [RelayStation], defaultStationID: UUID?) {
        self.stations = stations; self.defaultStationID = defaultStationID
    }

    public var description: String { "RelayStationSnapshot (contents redacted)" }
    public var debugDescription: String { description }
}
