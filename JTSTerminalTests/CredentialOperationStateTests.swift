import Foundation
import Testing
@testable import JTSTerminal

@Suite("Credential operation UI state")
struct CredentialOperationStateTests {
    private let sshTarget = CredentialTargetIdentity(
        connectionType: .ssh,
        account: "tester@example.test:22"
    )

    @Test("Password dirty state clears when input returns to its baseline")
    func passwordDirtyStateTracksBaseline() {
        #expect(!CredentialOperationPolicy.hasUnsavedInput(
            currentValue: "",
            baselineValue: ""
        ))
        #expect(CredentialOperationPolicy.hasUnsavedInput(
            currentValue: "replacement",
            baselineValue: "saved"
        ))
        #expect(!CredentialOperationPolicy.hasUnsavedInput(
            currentValue: "saved",
            baselineValue: "saved"
        ))
    }

    @Test("Policy rejects empty saves and every overlapping operation")
    func startPolicy() throws {
        var state = CredentialOperationState()

        #expect(!CredentialOperationPolicy.canStart(
            .save,
            supportsPasswordStorage: true,
            isConnectable: true,
            identityIsCurrent: true,
            passwordIsEmpty: true,
            hasUnsavedInput: true,
            savedCredentialPresence: .absent,
            operationState: state
        ))
        #expect(CredentialOperationPolicy.canStart(
            .save,
            supportsPasswordStorage: true,
            isConnectable: true,
            identityIsCurrent: true,
            passwordIsEmpty: false,
            hasUnsavedInput: true,
            savedCredentialPresence: .absent,
            operationState: state
        ))
        #expect(!CredentialOperationPolicy.canStart(
            .save,
            supportsPasswordStorage: true,
            isConnectable: true,
            identityIsCurrent: true,
            passwordIsEmpty: false,
            hasUnsavedInput: false,
            savedCredentialPresence: .present,
            operationState: state
        ))
        #expect(CredentialOperationPolicy.canStart(
            .check,
            supportsPasswordStorage: true,
            isConnectable: true,
            identityIsCurrent: true,
            passwordIsEmpty: false,
            hasUnsavedInput: false,
            savedCredentialPresence: .present,
            operationState: state
        ))
        #expect(CredentialOperationPolicy.canStart(
            .delete,
            supportsPasswordStorage: true,
            isConnectable: true,
            identityIsCurrent: true,
            passwordIsEmpty: false,
            hasUnsavedInput: false,
            savedCredentialPresence: .present,
            operationState: state
        ))
        #expect(!CredentialOperationPolicy.canStart(
            .delete,
            supportsPasswordStorage: true,
            isConnectable: true,
            identityIsCurrent: true,
            passwordIsEmpty: true,
            hasUnsavedInput: false,
            savedCredentialPresence: .absent,
            operationState: state
        ))
        #expect(!CredentialOperationPolicy.canStart(
            .check,
            supportsPasswordStorage: true,
            isConnectable: true,
            identityIsCurrent: false,
            passwordIsEmpty: true,
            hasUnsavedInput: false,
            savedCredentialPresence: .unknown,
            operationState: state
        ))
        #expect(!CredentialOperationPolicy.canStart(
            .check,
            supportsPasswordStorage: false,
            isConnectable: true,
            identityIsCurrent: true,
            passwordIsEmpty: true,
            hasUnsavedInput: false,
            savedCredentialPresence: .unknown,
            operationState: state
        ))
        #expect(!CredentialOperationPolicy.canStart(
            .delete,
            supportsPasswordStorage: true,
            isConnectable: false,
            identityIsCurrent: true,
            passwordIsEmpty: true,
            hasUnsavedInput: false,
            savedCredentialPresence: .unknown,
            operationState: state
        ))

        let startedRequest = state.begin(
            .save,
            target: sshTarget,
            identityGeneration: 1,
            inputRevision: 4
        )
        _ = try #require(startedRequest)
        #expect(!CredentialOperationPolicy.canStart(
            .delete,
            supportsPasswordStorage: true,
            isConnectable: true,
            identityIsCurrent: true,
            passwordIsEmpty: false,
            hasUnsavedInput: false,
            savedCredentialPresence: .present,
            operationState: state
        ))
        #expect(state.begin(
            .check,
            target: sshTarget,
            identityGeneration: 1,
            inputRevision: 4
        ) == nil)
    }

    @Test("Only the active request can complete and unlock actions")
    func completionTokenIsOneShot() throws {
        var state = CredentialOperationState()
        let startedRequest = state.begin(
            .check,
            target: sshTarget,
            identityGeneration: 2,
            inputRevision: 7
        )
        let request = try #require(startedRequest)
        let unrelated = CredentialOperationRequest(
            id: UUID(),
            kind: .check,
            target: sshTarget,
            identityGeneration: 2,
            inputRevision: 7
        )

        #expect(state.complete(
            unrelated,
            currentTarget: sshTarget,
            identityGeneration: 2,
            inputRevision: 7
        ) == nil)
        #expect(state.isRunning)
        #expect(state.complete(
            request,
            currentTarget: sshTarget,
            identityGeneration: 2,
            inputRevision: 7
        ) == .current)
        #expect(!state.isRunning)
        #expect(state.complete(
            request,
            currentTarget: sshTarget,
            identityGeneration: 2,
            inputRevision: 7
        ) == nil)
    }

    @Test("Identity generation rejects results even after target changes back")
    func identityGenerationRejectsStaleResult() throws {
        var state = CredentialOperationState()
        let startedRequest = state.begin(
            .check,
            target: sshTarget,
            identityGeneration: 9,
            inputRevision: 3
        )
        let request = try #require(startedRequest)

        #expect(state.complete(
            request,
            currentTarget: sshTarget,
            identityGeneration: 11,
            inputRevision: 3
        ) == .targetChanged)
        #expect(!state.isRunning)
    }

    @Test("Connection type participates in credential identity")
    func connectionTypeRejectsStaleResult() throws {
        var state = CredentialOperationState()
        let startedRequest = state.begin(
            .save,
            target: sshTarget,
            identityGeneration: 1,
            inputRevision: 1
        )
        let request = try #require(startedRequest)
        let rdpTarget = CredentialTargetIdentity(
            connectionType: .rdp,
            account: sshTarget.account
        )

        #expect(state.complete(
            request,
            currentTarget: rdpTarget,
            identityGeneration: 1,
            inputRevision: 1
        ) == .targetChanged)
    }

    @Test("A user edit prevents an async check from replacing the field")
    func inputRevisionRejectsStaleCheck() throws {
        var state = CredentialOperationState()
        let startedRequest = state.begin(
            .check,
            target: sshTarget,
            identityGeneration: 4,
            inputRevision: 12
        )
        let request = try #require(startedRequest)

        #expect(state.complete(
            request,
            currentTarget: sshTarget,
            identityGeneration: 4,
            inputRevision: 13
        ) == .inputChanged)
        #expect(!state.isRunning)
    }
}
