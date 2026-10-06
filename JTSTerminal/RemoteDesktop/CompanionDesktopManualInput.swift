#if ENABLE_RDP_2
import Foundation
import JTSCompanionClient

@MainActor
extension CompanionDesktopRuntime {
    func enqueueManualInput(_ body: [String: DesktopJSONValue], session: CompanionDesktopSession) {
        guard sessions[session.target.targetID] === session else { return }
        if body["kind"]?.stringValue == "pointerMove", session.manualInputs.last?.body["kind"]?.stringValue == "pointerMove" {
            session.manualInputs.removeLast()
        }
        guard session.manualInputs.count < 64 else {
            // Closing releases the broker's held-key journal. Never silently
            // lose a button-up in an overflowing input queue.
            Task { await close(targetID: session.target.targetID) }; return
        }
        session.manualInputs.append((session.generation, body, Date()))
        guard session.manualTask == nil else { return }
        session.manualTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            defer { session.manualTask = nil; session.pollingPaused = false }
            session.pollingPaused = true
            while !Task.isCancelled, self.sessions[session.target.targetID] === session, !session.manualInputs.isEmpty {
                let pending = session.manualInputs.removeFirst()
                guard pending.generation == session.generation, Date().timeIntervalSince(pending.queuedAt) < 2 else {
                    await self.close(targetID: session.target.targetID); return
                }
                do {
                    while session.busy { try await Task.sleep(for: .milliseconds(5)) }
                    try Task.checkCancellation()
                    let observation = try await self.observe(session)
                    guard observation.generation == pending.generation else { throw CompanionDesktopError.sessionChanged }
                    var payload = pending.body
                    payload["observationID"] = .string(observation.observationID.uuidString.lowercased())
                    _ = try await self.request("action", session: session, body: payload)
                } catch {
                    session.errorCode = self.safeCode(error)
                    await self.close(targetID: session.target.targetID); return
                }
            }
        }
    }
}
#endif
