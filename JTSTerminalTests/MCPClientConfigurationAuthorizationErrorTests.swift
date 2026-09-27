import Darwin
import Foundation
import Testing
@testable import JTSTerminal

struct MCPClientConfigurationAuthorizationErrorTests {
    @Test func privateFilePermissionFailuresRequireAuthorization() {
        for code in [EACCES, EPERM] {
            let error = PrivateFileSecurityError.operationFailed(
                path: "/Users/example/.codex/config.toml",
                code: code
            )

            #expect(
                MCPClientConfigurationAuthorizationErrorClassifier
                    .requiresAuthorization(error)
            )
        }
    }

    @Test func privateFileNonPermissionFailuresDoNotRequireAuthorization() {
        let operationFailure = PrivateFileSecurityError.operationFailed(
            path: "/Users/example/.codex/config.toml",
            code: EIO
        )
        let insecureObject = PrivateFileSecurityError.insecureObject(
            path: "/Users/example/.codex/config.toml"
        )

        #expect(
            !MCPClientConfigurationAuthorizationErrorClassifier
                .requiresAuthorization(operationFailure)
        )
        #expect(
            !MCPClientConfigurationAuthorizationErrorClassifier
                .requiresAuthorization(insecureObject)
        )
    }

    @Test func posixAndCocoaPermissionFailuresRequireAuthorization() {
        let posix = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES)
        )
        let cocoa = CocoaError(.fileWriteNoPermission)

        #expect(
            MCPClientConfigurationAuthorizationErrorClassifier
                .requiresAuthorization(posix)
        )
        #expect(
            MCPClientConfigurationAuthorizationErrorClassifier
                .requiresAuthorization(cocoa)
        )
    }

    @Test func nestedNSErrorChainsRemainSupported() {
        let permissionFailure = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EPERM)
        )
        let underlying = NSError(
            domain: "com.jts-terminal.tests.configuration",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: permissionFailure]
        )
        let detailed = NSError(
            domain: "com.jts-terminal.tests.configuration",
            code: 2,
            userInfo: [
                "NSDetailedErrorsKey": [
                    NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EIO)
                    ),
                    permissionFailure,
                ],
            ]
        )

        #expect(
            MCPClientConfigurationAuthorizationErrorClassifier
                .requiresAuthorization(underlying)
        )
        #expect(
            MCPClientConfigurationAuthorizationErrorClassifier
                .requiresAuthorization(detailed)
        )
    }

    @Test func unrelatedNSErrorChainsDoNotRequireAuthorization() {
        let unrelated = NSError(
            domain: "com.jts-terminal.tests.configuration",
            code: 3,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOENT)
                ),
                "NSDetailedErrorsKey": [
                    NSError(
                        domain: NSCocoaErrorDomain,
                        code: CocoaError.fileNoSuchFile.rawValue
                    ),
                ],
            ]
        )

        #expect(
            !MCPClientConfigurationAuthorizationErrorClassifier
                .requiresAuthorization(unrelated)
        )
    }
}
