import Foundation
import JTSCompanionIPC

public enum CompanionClientError: Error, Equatable, Sendable {
    case invalidRequest, invalidReply, busy, notConnected, timedOut, cancelled, interrupted, invalidated, unavailable
    case remote(String)
}

/// Mockable callback boundary. Implementations must never replay a request; invalidation
/// closes the entire transport generation. The actor owns deadlines and correlation.
public protocol CompanionIPCTransport: AnyObject, Sendable {
    func start(onFailure: @escaping @Sendable (CompanionClientError) -> Void) throws
    func send(_ request: Data, reply: @escaping @Sendable (Result<Data, CompanionClientError>) -> Void)
    func invalidate()
}

public enum CompanionHelperIdentity {
    public static let serviceName = "com.lljts.JTSTerminal.CompanionTransportService"
    public static let teamIdentifier = "YOURTEAMID"
    public static let signingRequirement = "anchor apple generic and identifier \"com.lljts.JTSTerminal.CompanionTransportService\" and certificate leaf[subject.OU] = \"YOURTEAMID\""
}

/// Foundation XPC is thread-safe; this lock protects only this wrapper's ownership.
/// There is intentionally no Debug/ad-hoc/unsigned bypass of helper authentication.
final class XPCCompanionIPCTransport: CompanionIPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    func start(onFailure: @escaping @Sendable (CompanionClientError) -> Void) throws {
        let next = NSXPCConnection(serviceName: CompanionHelperIdentity.serviceName)
        next.remoteObjectInterface = CompanionIPCInterface.make()
        next.setCodeSigningRequirement(CompanionHelperIdentity.signingRequirement)
        next.interruptionHandler = { onFailure(.interrupted) }
        next.invalidationHandler = { onFailure(.invalidated) }
        lock.lock()
        guard connection == nil else { lock.unlock(); next.invalidate(); throw CompanionClientError.busy }
        connection = next; lock.unlock()
        next.resume()
    }

    func send(_ request: Data, reply: @escaping @Sendable (Result<Data, CompanionClientError>) -> Void) {
        lock.lock(); let current = connection; lock.unlock()
        guard let current else { reply(.failure(.invalidated)); return }
        guard let remote = current.remoteObjectProxyWithErrorHandler({ _ in reply(.failure(.unavailable)) })
            as? CompanionTransportServiceProtocol else { reply(.failure(.unavailable)); return }
        remote.perform(request, withReply: { reply(.success($0)) })
    }

    func invalidate() {
        lock.lock(); let old = connection; connection = nil; lock.unlock()
        old?.invalidationHandler = nil; old?.interruptionHandler = nil; old?.invalidate()
    }
    deinit { invalidate() }
}
