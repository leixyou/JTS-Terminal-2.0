import Foundation
import JTSCompanionTransport

enum CompanionRuntimeErrors: Error {
    case alreadyOpened, timedOut, closed, invalidSession, replayed

    static func code(_ error: Error) -> String {
        if error is CancellationError { return "REQUEST_CANCELLED" }
        switch error {
        case Self.alreadyOpened: return "CONNECTION_ALREADY_OPENED"
        case Self.timedOut: return "CONNECTION_TIMED_OUT"
        case Self.closed: return "CONNECTION_CLOSED"
        case Self.invalidSession: return "SESSION_REJECTED"
        case Self.replayed: return "REQUEST_REPLAY_REJECTED"
        case CompanionTransportError.operationInProgress: return "OPERATION_IN_PROGRESS"
        case CompanionTransportError.tlsPeerRejected: return "PEER_IDENTITY_REJECTED"
        case CompanionTransportError.tlsHandshakeFailed: return "TLS_HANDSHAKE_FAILED"
        case CompanionTransportError.invalidEndpoint: return "RELAY_ADDRESS_REJECTED"
        case CompanionTransportError.invalidIdentity: return "IDENTITY_REJECTED"
        case CompanionTransportError.remote: return "RELAY_REJECTED"
        case CompanionControlError.timedOut: return "REQUEST_TIMED_OUT"
        case CompanionTransportError.connectionClosed: return "CONNECTION_CLOSED"
        default: return "REQUEST_FAILED"
        }
    }
}
