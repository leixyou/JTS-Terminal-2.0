import Foundation
import JTSCompanionIPC

final class CompanionListener: NSObject, NSXPCListenerDelegate {
    private let lock = NSLock()
    private var connections: [UUID: CompanionConnectionBridge] = [:]
    private static let maximumConnections = 16

    private static var callerRequirement: String {
        #if DEBUG
        let identifier = "com.lljts.JTSTerminal.UITesting"
        #else
        let identifier = "com.lljts.JTSTerminal"
        #endif
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"YOURTEAMID\""
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Enforced in BOTH Debug and Release. Never use an environment/peer-supplied requirement.
        connection.setCodeSigningRequirement(Self.callerRequirement)
        let identifier = UUID()
        let bridge = CompanionConnectionBridge(connection: connection)
        lock.lock()
        guard connections.count < Self.maximumConnections else { lock.unlock(); return false }
        connections[identifier] = bridge
        lock.unlock()

        connection.exportedInterface = CompanionIPCInterface.make()
        connection.exportedObject = bridge
        connection.interruptionHandler = { [weak connection, weak bridge] in
            bridge?.invalidate()
            connection?.invalidate()
        }
        connection.invalidationHandler = { [weak self, weak bridge] in
            bridge?.invalidate()
            self?.remove(identifier)
        }
        connection.resume()
        return true
    }

    private func remove(_ identifier: UUID) {
        lock.lock()
        connections.removeValue(forKey: identifier)
        lock.unlock()
    }
}
