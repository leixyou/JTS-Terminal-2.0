#if ENABLE_RDP_2
import Foundation
import JTSCompanionClient
import Testing
@testable import JTSTerminal

@MainActor struct CompanionDesktopUserRequestTests {
    @Test func nativeUserDefaultRootMatchesInstalledPolicyWithoutChangingDVCDefault() throws {
        let command: [String: Any] = ["command": "Get-Location"]
        #expect(try WindowsPowerShellExecutionPlan(arguments: command).rootID == "default")
        let native = try CompanionDesktopRuntime.userOperationBody(tool: .windowsExec, arguments: command)
        #expect(native["rootId"]?.stringValue == "shared")
        let files = try CompanionDesktopRuntime.userOperationBody(tool: .windowsFiles,
            arguments: ["operation": "read", "path": "result.txt"])
        #expect(files["rootId"]?.stringValue == "shared")
    }
    @Test func explicitRootsArePreservedForWindowsSandboxValidation() throws {
        for tool in [WindowsMCPToolName.windowsExec, .windowsFiles] {
            let args: [String: Any] = tool == .windowsExec
                ? ["command": "Get-Location", "rootId": "configured-user-root"]
                : ["operation": "stat", "path": "result.txt", "rootId": "configured-user-root"]
            let request = try CompanionDesktopRuntime.userOperationBody(tool: tool, arguments: args)
            #expect(request["rootId"]?.stringValue == "configured-user-root")
        }
    }
}
#endif
