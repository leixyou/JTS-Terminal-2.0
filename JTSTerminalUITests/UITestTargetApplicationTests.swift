import Darwin
import Foundation
import XCTest

final class UITestTargetApplicationTests: XCTestCase {
    func testOnlyFormalProductionSmokeUsesDeterministicLanguageArgument() {
        XCTAssertEqual(
            UITestTargetApplication.deterministicLanguageLaunchArguments(
                environment: [:]
            ),
            []
        )
        XCTAssertEqual(
            UITestTargetApplication.deterministicLanguageLaunchArguments(
                environment: [
                    UITestTargetApplication.formalProductionIdentityKey: "1",
                ]
            ),
            ["-appLanguage.v1", "en"]
        )
        XCTAssertEqual(
            UITestTargetApplication.deterministicLanguageLaunchArguments(
                environment: [
                    UITestTargetApplication.formalProductionIdentityKey: "0",
                ]
            ),
            []
        )
    }

    func testResolvesOwnedIsolatedApplicationFromBuiltProductsDirectory() throws {
        try withApplicationFixture(bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier) {
            productsURL, applicationURL in
            let descriptor = try UITestTargetApplication.resolveDescriptor(
                environment: [
                    UITestTargetApplication.builtProductsDirectoriesKey:
                        productsURL.path
                ]
            )

            XCTAssertEqual(descriptor.bundleURL, applicationURL)
            XCTAssertEqual(
                descriptor.bundleIdentifier,
                UITestTargetApplication.isolatedBundleIdentifier
            )
            XCTAssertTrue(descriptor.usesIsolatedIdentity)
        }
    }

    func testProductionIdentityRequiresExplicitFormalSmokeMode() throws {
        try withApplicationFixture(bundleIdentifier: UITestTargetApplication.productionBundleIdentifier) {
            productsURL, _ in
            XCTAssertThrowsError(
                try UITestTargetApplication.resolveDescriptor(
                    environment: [
                        UITestTargetApplication.builtProductsDirectoriesKey:
                            productsURL.path
                    ]
                )
            ) { error in
                XCTAssertEqual(
                    error as? UITestTargetApplicationError,
                    .productionIdentityRequiresFormalSmoke
                )
            }
        }
    }

    func testFormalSmokeAcceptsOnlyProductionIdentityWithCompleteRouting() throws {
        try withApplicationFixture(bundleIdentifier: UITestTargetApplication.productionBundleIdentifier) {
            productsURL, _ in
            let descriptor = try UITestTargetApplication.resolveDescriptor(
                environment: formalSmokeEnvironment(productsURL: productsURL)
            )
            XCTAssertFalse(descriptor.usesIsolatedIdentity)
            XCTAssertEqual(
                descriptor.bundleIdentifier,
                UITestTargetApplication.productionBundleIdentifier
            )
        }
    }

    func testFormalSmokeRejectsIsolatedIdentity() throws {
        try withApplicationFixture(bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier) {
            productsURL, _ in
            XCTAssertThrowsError(
                try UITestTargetApplication.resolveDescriptor(
                    environment: formalSmokeEnvironment(productsURL: productsURL)
                )
            ) { error in
                XCTAssertEqual(
                    error as? UITestTargetApplicationError,
                    .formalSmokeRequiresProductionIdentity
                )
            }
        }
    }

    func testFormalSmokeRejectsMissingOrEmptyRoutingValues() throws {
        let routingKeys = [
            AppReviewSSHSmokeConfigurationEnvironment.hostKey,
            AppReviewSSHSmokeConfigurationEnvironment.usernameKey,
            AppReviewSSHSmokeConfigurationEnvironment.credentialAccountKey,
            AppReviewSSHSmokeConfigurationEnvironment.knownHostsFileKey,
            AppReviewSSHSmokeConfigurationEnvironment.knownHostsSHA256Key,
            AppReviewSSHSmokeConfigurationEnvironment.brokerPortKey,
            AppReviewSSHSmokeConfigurationEnvironment.challengeKey,
            AppReviewSSHSmokeConfigurationEnvironment.nonceKey,
        ]

        try withApplicationFixture(bundleIdentifier: UITestTargetApplication.productionBundleIdentifier) {
            productsURL, _ in
            for key in routingKeys {
                var missingEnvironment = formalSmokeEnvironment(
                    productsURL: productsURL
                )
                missingEnvironment.removeValue(forKey: key)
                assertIncompleteFormalSmokeRouting(
                    environment: missingEnvironment,
                    key: key,
                    variant: "missing"
                )

                var emptyEnvironment = formalSmokeEnvironment(
                    productsURL: productsURL
                )
                emptyEnvironment[key] = ""
                assertIncompleteFormalSmokeRouting(
                    environment: emptyEnvironment,
                    key: key,
                    variant: "empty"
                )
            }
        }
    }

    func testIsolatedModeRejectsCompleteOrPartialFormalSmokeRouting() throws {
        try withApplicationFixture(bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier) {
            productsURL, _ in
            var completeRouting = formalSmokeEnvironment(
                productsURL: productsURL
            )
            completeRouting.removeValue(
                forKey: UITestTargetApplication.formalProductionIdentityKey
            )
            assertFormalSmokeRoutingRequiresMarker(
                environment: completeRouting,
                variant: "complete"
            )

            let partialRouting: [String: String] = [
                UITestTargetApplication.builtProductsDirectoriesKey:
                    productsURL.path,
                AppReviewSSHSmokeConfigurationEnvironment.hostKey: "8.8.8.8",
            ]
            assertFormalSmokeRoutingRequiresMarker(
                environment: partialRouting,
                variant: "partial"
            )
        }
    }

    func testRejectsEveryNonExactFormalSmokeMarkerForEitherIdentity() throws {
        let bundleIdentifiers = [
            UITestTargetApplication.isolatedBundleIdentifier,
            UITestTargetApplication.productionBundleIdentifier,
        ]
        let invalidMarkers = ["", "0", "true", " 1", "1 "]

        for bundleIdentifier in bundleIdentifiers {
            try withApplicationFixture(bundleIdentifier: bundleIdentifier) {
                productsURL, _ in
                for marker in invalidMarkers {
                    var environment = formalSmokeEnvironment(
                        productsURL: productsURL
                    )
                    environment[
                        UITestTargetApplication.formalProductionIdentityKey
                    ] = marker

                    XCTAssertThrowsError(
                        try UITestTargetApplication.resolveDescriptor(
                            environment: environment
                        ),
                        "Expected marker \(String(reflecting: marker)) to fail for \(bundleIdentifier)"
                    ) { error in
                        XCTAssertEqual(
                            error as? UITestTargetApplicationError,
                            .invalidFormalSmokeMode
                        )
                    }
                }
            }
        }
    }

    func testRejectsUnexpectedIdentity() throws {
        try withApplicationFixture(bundleIdentifier: "com.example.Untrusted") {
            productsURL, _ in
            XCTAssertThrowsError(
                try UITestTargetApplication.resolveDescriptor(
                    environment: [
                        UITestTargetApplication.builtProductsDirectoriesKey:
                            productsURL.path
                    ]
                )
            ) { error in
                XCTAssertEqual(
                    error as? UITestTargetApplicationError,
                    .unexpectedBundleIdentifier("com.example.Untrusted")
                )
            }
        }
    }

    func testRejectsGroupWritableBuiltProductBoundary() throws {
        try withApplicationFixture(
            bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier
        ) { productsURL, applicationURL in
            XCTAssertEqual(Darwin.chmod(applicationURL.path, 0o775), 0)

            XCTAssertThrowsError(
                try UITestTargetApplication.resolveDescriptor(
                    environment: [
                        UITestTargetApplication.builtProductsDirectoriesKey:
                            productsURL.path
                    ]
                )
            ) { error in
                guard let targetError = error as? UITestTargetApplicationError,
                      case .unsafeTargetApplication = targetError else {
                    return XCTFail(
                        "Expected a writable-boundary rejection, got \(error)"
                    )
                }
            }
        }
    }

    func testRejectsMissingAndSymlinkedTargetApplication() throws {
        XCTAssertThrowsError(
            try UITestTargetApplication.resolveDescriptor(environment: [:])
        ) { error in
            XCTAssertEqual(
                error as? UITestTargetApplicationError,
                .missingBuiltProductsDirectories
            )
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let productsURL = root.appendingPathComponent("Products", isDirectory: true)
        let realApplicationURL = root
            .appendingPathComponent("Real.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: productsURL,
            withIntermediateDirectories: true
        )
        try createApplication(
            at: realApplicationURL,
            bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier
        )
        try FileManager.default.createSymbolicLink(
            at: productsURL.appendingPathComponent("JTS Terminal.app"),
            withDestinationURL: realApplicationURL
        )

        XCTAssertThrowsError(
            try UITestTargetApplication.resolveDescriptor(
                environment: [
                    UITestTargetApplication.builtProductsDirectoriesKey:
                        productsURL.path
                ]
            )
        ) { error in
            guard let targetError = error as? UITestTargetApplicationError,
                  case .unsafeTargetApplication = targetError else {
                return XCTFail("Expected an unsafe target application, got \(error)")
            }
        }
    }

    func testRejectsWritableNestedApplicationBoundary() throws {
        try withApplicationFixture(
            bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier
        ) { productsURL, applicationURL in
            let contentsURL = applicationURL
                .appendingPathComponent("Contents", isDirectory: true)
            XCTAssertEqual(Darwin.chmod(contentsURL.path, 0o775), 0)
            assertUnsafeTargetApplication(productsURL: productsURL)
        }

        try withApplicationFixture(
            bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier
        ) { productsURL, applicationURL in
            let frameworksURL = applicationURL
                .appendingPathComponent("Contents/Frameworks", isDirectory: true)
            try FileManager.default.createDirectory(
                at: frameworksURL,
                withIntermediateDirectories: false
            )
            XCTAssertEqual(Darwin.chmod(frameworksURL.path, 0o777), 0)
            assertUnsafeTargetApplication(productsURL: productsURL)
        }
    }

    func testRejectsSymlinkedNestedApplicationBoundary() throws {
        try withApplicationFixture(
            bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier
        ) { productsURL, applicationURL in
            let macOSURL = applicationURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
            let movedMacOSURL = productsURL.deletingLastPathComponent()
                .appendingPathComponent("Moved-MacOS", isDirectory: true)
            try FileManager.default.moveItem(at: macOSURL, to: movedMacOSURL)
            try FileManager.default.createSymbolicLink(
                at: macOSURL,
                withDestinationURL: movedMacOSURL
            )
            assertUnsafeTargetApplication(productsURL: productsURL)
        }
    }

    func testPersistentRDPLeasePredicateMatchesAccessibilityValueOnly() {
        let predicate = PersistentRDPControlLeaseTextPolicy.predicate(
            for: "Control until"
        )

        XCTAssertTrue(predicate.evaluate(with: [
            "label": "",
            "value": "Control until 17:30",
        ]))
        XCTAssertTrue(
            PersistentRDPControlLeaseTextPolicy.predicate(
                for: "Lease expires"
            ).evaluate(with: [
                "label": "Lease expires soon",
                "value": "",
            ])
        )
        XCTAssertFalse(predicate.evaluate(with: [
            "label": "Persistent access",
            "value": "Until revoked",
        ]))
    }

    func testIsolatedIdentityIgnoresProductionButRejectsIsolatedOrExactPath() {
        let targetURL = URL(fileURLWithPath: "/tmp/Products/JTS Terminal.app")
        let descriptor = UITestTargetApplicationDescriptor(
            bundleURL: targetURL,
            executableURL: targetURL
                .appendingPathComponent("Contents/MacOS/JTS Terminal"),
            bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier
        )
        let production = UITestRunningApplicationIdentity(
            bundleIdentifier: UITestTargetApplication.productionBundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/JTS Terminal.app"),
            isGUIApplication: true
        )
        XCTAssertFalse(
            UITestTargetApplication.hasConflictingRunningApplication(
                descriptor: descriptor,
                runningApplications: [production]
            )
        )

        let isolatedElsewhere = UITestRunningApplicationIdentity(
            bundleIdentifier: UITestTargetApplication.isolatedBundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/tmp/Old/JTS Terminal.app"),
            isGUIApplication: true
        )
        XCTAssertTrue(
            UITestTargetApplication.hasConflictingRunningApplication(
                descriptor: descriptor,
                runningApplications: [isolatedElsewhere]
            )
        )

        let exactPathWrongIdentity = UITestRunningApplicationIdentity(
            bundleIdentifier: "com.example.Wrong",
            bundleURL: targetURL,
            isGUIApplication: false
        )
        XCTAssertTrue(
            UITestTargetApplication.hasConflictingRunningApplication(
                descriptor: descriptor,
                runningApplications: [exactPathWrongIdentity]
            )
        )
    }

    func testProductionIdentityRetainsExistingGUIProtection() {
        let targetURL = URL(fileURLWithPath: "/tmp/Products/JTS Terminal.app")
        let descriptor = UITestTargetApplicationDescriptor(
            bundleURL: targetURL,
            executableURL: targetURL
                .appendingPathComponent("Contents/MacOS/JTS Terminal"),
            bundleIdentifier: UITestTargetApplication.productionBundleIdentifier
        )
        let installedGUI = UITestRunningApplicationIdentity(
            bundleIdentifier: UITestTargetApplication.productionBundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/JTS Terminal.app"),
            isGUIApplication: true
        )
        XCTAssertTrue(
            UITestTargetApplication.hasConflictingRunningApplication(
                descriptor: descriptor,
                runningApplications: [installedGUI]
            )
        )
    }

    private func withApplicationFixture(
        bundleIdentifier: String,
        body: (URL, URL) throws -> Void
    ) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let productsURL = root.appendingPathComponent("Products", isDirectory: true)
        let applicationURL = productsURL
            .appendingPathComponent("JTS Terminal.app", isDirectory: true)
        try createApplication(
            at: applicationURL,
            bundleIdentifier: bundleIdentifier
        )
        try body(productsURL, applicationURL)
    }

    private func formalSmokeEnvironment(
        productsURL: URL
    ) -> [String: String] {
        [
            UITestTargetApplication.builtProductsDirectoriesKey:
                productsURL.path,
            UITestTargetApplication.formalProductionIdentityKey: "1",
            AppReviewSSHSmokeConfigurationEnvironment.hostKey: "8.8.8.8",
            AppReviewSSHSmokeConfigurationEnvironment.usernameKey: "appreview",
            AppReviewSSHSmokeConfigurationEnvironment.credentialAccountKey:
                "appreview@8.8.8.8:22",
            AppReviewSSHSmokeConfigurationEnvironment.knownHostsFileKey:
                "/private/tmp/known_hosts",
            AppReviewSSHSmokeConfigurationEnvironment.knownHostsSHA256Key:
                String(repeating: "a", count: 64),
            AppReviewSSHSmokeConfigurationEnvironment.brokerPortKey: "49152",
            AppReviewSSHSmokeConfigurationEnvironment.challengeKey:
                String(repeating: "c", count: 32),
            AppReviewSSHSmokeConfigurationEnvironment.nonceKey:
                String(repeating: "n", count: 32),
        ]
    }

    private func assertIncompleteFormalSmokeRouting(
        environment: [String: String],
        key: String,
        variant: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try UITestTargetApplication.resolveDescriptor(
                environment: environment
            ),
            "Expected \(variant) formal routing key \(key) to fail",
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? UITestTargetApplicationError,
                .incompleteFormalSmokeRouting,
                file: file,
                line: line
            )
        }
    }

    private func assertFormalSmokeRoutingRequiresMarker(
        environment: [String: String],
        variant: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try UITestTargetApplication.resolveDescriptor(
                environment: environment
            ),
            "Expected \(variant) formal routing without the marker to fail",
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? UITestTargetApplicationError,
                .formalSmokeRoutingRequiresMarker,
                file: file,
                line: line
            )
        }
    }

    private func assertUnsafeTargetApplication(
        productsURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try UITestTargetApplication.resolveDescriptor(
                environment: [
                    UITestTargetApplication.builtProductsDirectoriesKey:
                        productsURL.path
                ]
            ),
            file: file,
            line: line
        ) { error in
            guard let targetError = error as? UITestTargetApplicationError,
                  case .unsafeTargetApplication = targetError else {
                return XCTFail(
                    "Expected an unsafe nested application boundary, got \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "JTS-UI-Target-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func createApplication(
        at applicationURL: URL,
        bundleIdentifier: String
    ) throws {
        let contentsURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
        let executableDirectoryURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executableDirectoryURL,
            withIntermediateDirectories: true
        )
        let propertyList: [String: Any] = [
            kCFBundleIdentifierKey as String: bundleIdentifier,
            kCFBundleExecutableKey as String: "JTS Terminal",
        ]
        let propertyListData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try propertyListData.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )
        let executableURL = executableDirectoryURL
            .appendingPathComponent("JTS Terminal")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: executableURL.path,
                contents: Data("fixture".utf8)
            )
        )
        XCTAssertEqual(Darwin.chmod(executableURL.path, 0o700), 0)
    }
}
