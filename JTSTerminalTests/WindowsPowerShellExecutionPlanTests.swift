#if ENABLE_RDP_2
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct WindowsPowerShellExecutionPlanTests {
    @Test func currentUserPlanMatchesCompanionBoundsAndDefaults() throws {
        let plan = try WindowsPowerShellExecutionPlan(arguments: [
            "command": "Get-ChildItem",
            "idempotencyKey": "current-user-1",
        ])

        #expect(plan.script == "Get-ChildItem")
        #expect(plan.rootID == "default")
        #expect(plan.workingDirectory == ".")
        #expect(plan.timeoutMilliseconds == 60_000)
        #expect(plan.maximumOutputBytes == 128 * 1_024)
        #expect(!plan.requiresElevation)
        #expect(plan.elevationScopes.isEmpty)

        let parameters = plan.currentUserParameters
        #expect(parameters["script"] as? String == "Get-ChildItem")
        #expect(parameters["rootId"] as? String == "default")
        #expect(parameters["workingDirectory"] as? String == ".")
        #expect(parameters["timeoutMilliseconds"] as? Int == 60_000)
        #expect(parameters["maximumOutputBytes"] as? Int == 128 * 1_024)
        #expect(parameters["requiresElevation"] as? Bool == false)
        #expect(parameters["elevationLeaseId"] == nil)
        #expect(parameters["elevationActionId"] == nil)
    }

    @Test func malformedOrAmbiguousExecutionArgumentsFailClosed() {
        let explicitScope: [[String: Any]] = [[
            "rootId": "workspace",
            "relativePath": "build",
            "access": "readWrite",
        ]]
        let invalidArguments: [[String: Any]] = [
            ["command": "Get-Date", "deadlineMs": true],
            ["command": "Get-Date", "maxOutputBytes": 131_073],
            ["command": "Get-Date", "requiresElevation": 1],
            ["command": "Get-Date", "elevationDataScopes": explicitScope],
            [
                "command": "Get-Date",
                "requiresElevation": true,
                "elevationDataScopes": explicitScope,
            ],
            [
                "command": "Get-Date",
                "requiresElevation": true,
                "idempotencyKey": "elevated-1",
            ],
            ["command": "Get-Date", "idempotencyKey": String(repeating: "a", count: 129)],
            ["command": String(repeating: "😀", count: 32_769)],
        ]

        for arguments in invalidArguments {
            do {
                _ = try WindowsPowerShellExecutionPlan(arguments: arguments)
                Issue.record("Expected an invalid PowerShell execution plan to be rejected")
            } catch let error as WindowsMCPToolError {
                #expect(error.code == .invalidArgument)
            } catch {
                Issue.record("Expected WindowsMCPToolError, got \(error)")
            }
        }
    }

    @Test func elevatedPlanBuildsExactActionBoundLeaseRequestAndExecution() throws {
        let plan = try WindowsPowerShellExecutionPlan(arguments: [
            "command": "Get-ChildItem -Force",
            "rootId": "workspace",
            "cwd": "build",
            "deadlineMs": 120_000,
            "maxOutputBytes": 4_096,
            "requiresElevation": true,
            "elevationDurationMs": 180_000,
            "elevationDataScopes": [[
                "rootId": "workspace",
                "relativePath": "build",
                "access": "readWrite",
            ]],
            "idempotencyKey": String(repeating: "x", count: 128),
        ])

        let request = plan.elevationRequestParameters
        let execution = try #require(request["execution"] as? [String: Any])
        let scopes = try #require(request["dataScopes"] as? [[String: Any]])
        #expect(request["durationMilliseconds"] as? Int == 180_000)
        #expect(execution["script"] as? String == "Get-ChildItem -Force")
        #expect(execution["rootId"] as? String == "workspace")
        #expect(execution["workingDirectory"] as? String == "build")
        #expect(execution["requiresElevation"] as? Bool == true)
        #expect(execution["elevationLeaseId"] == nil)
        #expect(scopes.count == 1)
        #expect(scopes.first?["rootId"] as? String == "workspace")
        #expect(scopes.first?["relativePath"] as? String == "build")
        #expect(scopes.first?["access"] as? String == "readWrite")

        let requestKey = try #require(plan.derivedIdempotencyKey(suffix: ":elevation-request"))
        let executionKey = try #require(plan.derivedIdempotencyKey(suffix: ":elevation-execute"))
        #expect(requestKey != executionKey)
        #expect(requestKey.utf16.count <= 128)
        #expect(executionKey.utf16.count <= 128)

        let now = Date(timeIntervalSince1970: 1_784_096_400)
        let leaseID = UUID()
        let grant = try WindowsPowerShellExecutionPlan.elevationGrant(from: [
            "leaseId": leaseID.uuidString,
            "issuedAt": Self.iso8601(now.addingTimeInterval(-1)),
            "expiresAt": Self.iso8601(now.addingTimeInterval(179)),
            "actions": [[
                "actionId": "powershell-action-1",
                "kind": 0,
                "payloadSha256": String(repeating: "ab", count: 32),
                "displaySummary": "Approved PowerShell",
            ]],
        ], now: now)

        #expect(grant.leaseID == leaseID)
        #expect(grant.actionID == "powershell-action-1")
        #expect(grant.payloadSHA256 == String(repeating: "AB", count: 32))
        let elevated = plan.elevatedExecutionParameters(grant: grant)
        #expect(elevated["requiresElevation"] as? Bool == true)
        #expect(elevated["elevationLeaseId"] as? String == leaseID.uuidString.lowercased())
        #expect(elevated["elevationActionId"] as? String == "powershell-action-1")
    }

    @Test func elevationGrantRejectsExpiredMultipleOrNonASCIIActions() throws {
        let now = Date(timeIntervalSince1970: 1_784_096_400)
        let baseAction: [String: Any] = [
            "actionId": "powershell-action-1",
            "kind": "ApprovedPowerShell",
            "payloadSha256": String(repeating: "A", count: 64),
        ]
        let invalidGrants: [[String: Any]] = [
            [
                "leaseId": UUID().uuidString,
                "issuedAt": Self.iso8601(now.addingTimeInterval(-120)),
                "expiresAt": Self.iso8601(now.addingTimeInterval(-1)),
                "actions": [baseAction],
            ],
            [
                "leaseId": UUID().uuidString,
                "issuedAt": Self.iso8601(now),
                "expiresAt": Self.iso8601(now.addingTimeInterval(60)),
                "actions": [baseAction, baseAction],
            ],
            [
                "leaseId": UUID().uuidString,
                "issuedAt": Self.iso8601(now),
                "expiresAt": Self.iso8601(now.addingTimeInterval(60)),
                "actions": [[
                    "actionId": "powershell-action-1",
                    "kind": 0,
                    "payloadSha256": String(repeating: "Ａ", count: 64),
                ]],
            ],
        ]

        for grant in invalidGrants {
            do {
                _ = try WindowsPowerShellExecutionPlan.elevationGrant(from: grant, now: now)
                Issue.record("Expected an invalid elevation grant to be rejected")
            } catch let error as WindowsMCPToolError {
                #expect(error.code == .runtimeFailure)
            } catch {
                Issue.record("Expected WindowsMCPToolError, got \(error)")
            }
        }
    }

    @Test func windowsExecSchemaPublishesElevationContract() throws {
        let definition = try #require(WindowsMCPToolRegistry.definitions.first(where: {
            $0["name"] as? String == WindowsMCPToolName.windowsExec.rawValue
        }))
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let required = try #require(schema["required"] as? [String])

        #expect(properties["requiresElevation"] != nil)
        #expect(properties["elevationDurationMs"] != nil)
        #expect(properties["elevationDataScopes"] != nil)
        #expect(properties["maxOutputBytes"] != nil)
        #expect(required.contains("targetId"))
        #expect(required.contains("command"))
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
#endif
