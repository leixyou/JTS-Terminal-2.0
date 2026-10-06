#if ENABLE_RDP_2
import Foundation

nonisolated enum WindowsMCPCredentialFillRequest {
    static func validate(_ arguments: [String: Any]) throws {
        let allowed: Set<String> = ["targetId", "sessionId", "action", "expectedStateRevision", "expectedFrameId", "credentialRef", "purpose", "deadlineMs"]
        guard Set(arguments.keys).isSubset(of: allowed),
              let reference = arguments["credentialRef"] as? String, (1...128).contains(reference.utf8.count),
              !reference.contains(where: { $0.isNewline || $0 == "\0" }),
              let purpose = arguments["purpose"] as? String, ["login", "elevation"].contains(purpose),
              let frame = arguments["expectedFrameId"] as? String, UUID(uuidString: frame) != nil,
              let revision = arguments["expectedStateRevision"] as? NSNumber,
              CFGetTypeID(revision) != CFBooleanGetTypeID(), UInt64(revision.stringValue) != nil else {
            throw WindowsMCPToolError(code: .invalidArgument, message: "fillCredential accepts a target-bound credentialRef, login/elevation purpose and fresh observed frame; password parameters are forbidden.")
        }
    }
}
#endif
