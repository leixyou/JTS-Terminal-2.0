#if ENABLE_RDP_2
import Foundation
import Combine
import JTSCompanionClient

@MainActor
extension CompanionDesktopRuntime {
    func installStreamHandler(_ session: CompanionDesktopSession) async {
        await session.client.setEventHandler { @MainActor [weak self, weak session] value in
            guard let self, let session, self.sessions[session.target.targetID] === session else { return }
            guard session.accept(value) else { return }
            guard value.kind == "frame" else { self.objectWillChange.send(); return }
            do {
                let observed = try CompanionDesktopObservation(value)
                session.image = try session.decoder.decode(observed); session.latest = observed
                session.errorCode = nil
            } catch {
                session.errorCode = self.safeCode(error); session.image = nil; session.latest = nil
                session.status = "connecting"
                session.remoteState["status"] = .string("connecting")
                session.observations.removeAll(); session.uiaObservations.removeAll()
                // Retire the damaged stream; next reconnect recreates encoder
                // and decoder. Actions from the old frame cannot survive it.
                await session.client.close(); session.streaming = false
            }
            self.objectWillChange.send()
        }
    }
    func enableStream(_ session: CompanionDesktopSession) async {
        do {
            _ = try await session.client.request("startStream", expectedGeneration: session.generation,
                expectedSessionId: session.windowsSessionID)
            session.streaming = true
        } catch {
            // Compatible candidates can still expose explicit snapshot/error
            // states. This does not certify their streaming performance.
            session.streaming = false
            session.errorCode = safeCode(error)
        }
    }
}
#endif
