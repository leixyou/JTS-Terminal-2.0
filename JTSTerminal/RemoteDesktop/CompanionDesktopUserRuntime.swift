#if ENABLE_RDP_2
import Foundation
import JTSCompanionClient

@MainActor
extension CompanionDesktopRuntime {
    /// User commands use their own encrypted lane. Long commands and file
    /// results cannot hold the frame exchange or lend authority to a new session.
    func userRequest(_ operation: String, session: CompanionDesktopSession,
                     body: [String: DesktopJSONValue]) async throws -> CompanionDesktopEnvelope {
        guard !session.userBusy, sessions[session.target.targetID] === session,
              let grant = session.binding.desktopGrantID else { throw failure("DESKTOP_USER_BUSY") }
        session.userBusy = true; defer { session.userBusy = false }
        let generation = session.generation, windowsSession = session.windowsSessionID
        do {
            if session.userGeneration != generation {
                await session.userClient.close()
                let configuration = try await CompanionDevicesModel.shared.relayConfiguration(
                    deviceID: session.binding.deviceID, grantID: session.binding.grantID)
                try await session.userClient.open(configuration: configuration, grantID: grant)
                let bound = try await session.userClient.request("bindUserSession", body: [
                    "generation": .string(generation.uuidString.lowercased()), "sessionId": .integer(Int64(windowsSession))],
                    expectedGeneration: generation, expectedSessionId: windowsSession)
                guard bound.generation == generation, bound.sessionId == windowsSession,
                      session.generation == generation, sessions[session.target.targetID] === session else {
                    throw CompanionDesktopError.sessionChanged
                }
                session.userGeneration = generation
            }
            let result = try await session.userClient.request(operation, body: body,
                expectedGeneration: generation, expectedSessionId: windowsSession)
            guard result.generation == generation, result.sessionId == windowsSession,
                  session.generation == generation, sessions[session.target.targetID] === session else {
                throw CompanionDesktopError.sessionChanged
            }
            return result
        } catch {
            await session.userClient.close(); session.userGeneration = nil
            throw error
        }
    }
}
#endif
