//
//  JTSTerminaliOSUITests.swift
//  JTSTerminaliOSUITests
//
//  Created by Codex on 2026/6/26.
//

import XCTest

final class JTSTerminaliOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsJtsTerminalShell() throws {
        let app = cleanApp()
        app.launch()

        XCTAssertTrue(app.navigationBars["JTS Terminal"].waitForExistence(timeout: 5))
    }

    func testCreateServerAndExerciseTerminalAndFilesFailureStates() throws {
        let app = cleanApp()
        app.launch()

        createPasswordServer(
            app: app,
            host: "127.0.0.1",
            port: 22,
            username: "tester",
            password: "wrong-password"
        )
        openWorkspace(app: app, address: "tester@127.0.0.1:22")

        let headerDisclosure = app.buttons["mobile.workspaceHeaderDisclosure"]
        XCTAssertTrue(headerDisclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["mobile.workspaceRemotePath"].exists)
        headerDisclosure.tap()
        XCTAssertFalse(app.staticTexts["mobile.workspaceRemotePath"].exists)
        XCTAssertTrue(app.buttons["mobile.terminalConnectButton"].exists)
        headerDisclosure.tap()
        XCTAssertTrue(app.staticTexts["mobile.workspaceRemotePath"].waitForExistence(timeout: 2))

        app.buttons["mobile.terminalConnectButton"].tap()
        // A local sshd presents its host key before authentication; leave it
        // untrusted so the failure state below is still exercised.
        respondToHostKeyPromptIfPresented(app: app, trust: false)
        XCTAssertTrue(app.staticTexts["mobile.terminalStatus"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["mobile.terminalStatus"].label, "Failed")
        XCTAssertTrue(app.staticTexts["mobile.terminalError"].exists)
        XCTAssertTrue(isExpectedConnectionFailure(app.staticTexts["mobile.terminalError"].label))

        openFilesTab(app: app)
        XCTAssertTrue(app.textFields["mobile.filesRemotePathField"].waitForExistence(timeout: 5))
        respondToHostKeyPromptIfPresented(app: app, trust: false)
        XCTAssertTrue(app.staticTexts["mobile.filesError"].waitForExistence(timeout: 15))
        XCTAssertTrue(isExpectedConnectionFailure(app.staticTexts["mobile.filesError"].label))
        XCTAssertTrue(app.staticTexts["No Files Loaded"].exists)
    }

    func testMissingCredentialPromptsForPassword() throws {
        let app = cleanApp()
        app.launch()

        createPasswordServer(
            app: app,
            host: "127.0.0.1",
            port: 22,
            username: "tester",
            password: nil
        )
        openWorkspace(app: app, address: "tester@127.0.0.1:22")

        app.buttons["mobile.terminalConnectButton"].tap()

        let passwordField = app.secureTextFields["mobile.credentialPasswordField"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Password Required"].exists)
        XCTAssertFalse(app.buttons["mobile.credentialSaveButton"].isEnabled)

        passwordField.tap()
        passwordField.typeText("replacement-password")
        XCTAssertTrue(app.buttons["mobile.credentialSaveButton"].isEnabled)
    }

    func testConnectsToFixtureAndListsRemoteFiles() throws {
        let fixture = try FixtureServerConfiguration.fromEnvironment()
        let app = configuredApp(connectTimeout: "8", extraArguments: fixture.launchArguments)
        app.launch()

        openWorkspace(app: app, address: "\(fixture.username)@\(fixture.host):\(fixture.port)")

        app.buttons["mobile.terminalConnectButton"].tap()
        respondToHostKeyPromptIfPresented(app: app, trust: true, timeout: 15)
        let passwordField = app.secureTextFields["mobile.credentialPasswordField"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Update Password"].exists)
        attachScreenshot(named: "01-update-password-prompt")
        passwordField.tap()
        passwordField.typeText(fixture.password)
        app.buttons["mobile.credentialSaveButton"].tap()

        let terminalStatusElement = app.staticTexts["mobile.terminalStatus"]
        XCTAssertTrue(terminalStatusElement.waitForExistence(timeout: 15))
        let settledState = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR label == %@", "Connected", "Failed"),
            object: terminalStatusElement
        )
        let settledResult = XCTWaiter.wait(for: [settledState], timeout: 20)
        let terminalStatus = terminalStatusElement.label
        XCTAssertEqual(
            settledResult,
            .completed,
            "Expected SSH connection to settle, got \(terminalStatus)"
        )
        if terminalStatus != "Connected" {
            let errorMessage = app.staticTexts["mobile.terminalError"].exists
                ? app.staticTexts["mobile.terminalError"].label
                : "No terminal error label"
            XCTFail("Expected fixture SSH connection to be Connected, got \(terminalStatus): \(errorMessage)")
            return
        }
        attachScreenshot(named: "02-terminal-connected")

        returnToServerList(app: app, workspaceTitle: fixture.name)
        openWorkspace(app: app, address: "\(fixture.username)@\(fixture.host):\(fixture.port)")

        let resumedStatus = app.staticTexts["mobile.terminalStatus"]
        XCTAssertTrue(resumedStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(resumedStatus.label, "Connected")
        XCTAssertFalse(app.secureTextFields["mobile.credentialPasswordField"].exists)

        let retainedTerminal = app.textViews["mobile.terminalTestingSurface"]
        XCTAssertTrue(retainedTerminal.waitForExistence(timeout: 5))
        let retainedText = (retainedTerminal.value as? String) ?? retainedTerminal.label
        XCTAssertFalse(retainedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        attachScreenshot(named: "03-session-resumed")

        openFilesTab(app: app)
        XCTAssertTrue(app.textFields["mobile.filesRemotePathField"].waitForExistence(timeout: 5))

        let fixtureFile = app.staticTexts[fixture.expectedFileName]
        if !fixtureFile.waitForExistence(timeout: 12),
           app.buttons["mobile.filesRefreshButton"].exists {
            app.buttons["mobile.filesRefreshButton"].tap()
        }
        XCTAssertTrue(fixtureFile.waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["mobile.filesError"].exists)
        attachScreenshot(named: "04-sftp-readme-visible")
    }

    func testImportsMacExportedProfilesFromDocuments() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This smoke test requires a Mac export staged in a physical device's app Documents directory.")
        #else
        let environment = ProcessInfo.processInfo.environment
        let fileName = environment["JTS_IOS_IMPORT_PROFILE_FILE"] ?? "jts-terminal-mac-sessions.json"
        let expectedProfileName = environment["JTS_IOS_IMPORT_EXPECTED_PROFILE"] ?? "clip"

        let app = XCUIApplication()
        app.launchArguments = [
            "-mobile-ui-testing-terminal",
            "-mobile-import-profile-file",
            fileName
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts[expectedProfileName].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["localshell"].exists)
        #endif
    }

    private func cleanApp(connectTimeout: String = "2", extraArguments: [String] = []) -> XCUIApplication {
        configuredApp(
            connectTimeout: connectTimeout,
            extraArguments: ["-reset-mobile-state"] + extraArguments
        )
    }

    private func configuredApp(
        connectTimeout: String = "2",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mobile-ui-testing-terminal",
            "-mobile-ssh-timeout",
            connectTimeout
        ] + extraArguments
        return app
    }

    private func createPasswordServer(
        app: XCUIApplication,
        host: String,
        port: Int,
        username: String,
        password: String?,
        remotePath: String = "~"
    ) {
        XCTAssertTrue(app.buttons["mobile.newServerButton"].waitForExistence(timeout: 5))
        app.buttons["mobile.newServerButton"].tap()

        XCTAssertTrue(app.textFields["mobile.serverHostField"].waitForExistence(timeout: 5))
        app.textFields["mobile.serverHostField"].tap()
        app.textFields["mobile.serverHostField"].typeText(host)

        app.textFields["mobile.serverUsernameField"].tap()
        app.textFields["mobile.serverUsernameField"].typeText(username)

        if port != 22 {
            let portField = app.textFields["mobile.serverPortField"]
            XCTAssertTrue(portField.waitForExistence(timeout: 5))
            portField.replaceText(with: "\(port)")
        }

        if remotePath != "~" {
            app.textFields["mobile.serverRemotePathField"].replaceText(with: remotePath)
        }

        if let password {
            app.secureTextFields["mobile.serverPasswordField"].tap()
            app.secureTextFields["mobile.serverPasswordField"].typeText(password)
        }

        app.buttons["mobile.saveServerButton"].tap()
    }

    private func openWorkspace(app: XCUIApplication, address: String) {
        let addressText = app.staticTexts.matching(identifier: address).firstMatch
        XCTAssertTrue(addressText.waitForExistence(timeout: 5))
        if !app.buttons["mobile.terminalConnectButton"].waitForExistence(timeout: 2) {
            let serverRowID = "mobile.serverRow.\(address)"
            let serverButton = app.buttons.matching(identifier: serverRowID).firstMatch
            if serverButton.waitForExistence(timeout: 2) {
                serverButton.tap()
            } else if app.cells.matching(identifier: serverRowID).firstMatch.waitForExistence(timeout: 2) {
                app.cells.matching(identifier: serverRowID).firstMatch.tap()
            } else {
                let serverCell = app.cells.containing(.staticText, identifier: address).firstMatch
                if serverCell.waitForExistence(timeout: 2) {
                    serverCell.tap()
                } else {
                    addressText.tap()
                }
            }
            XCTAssertTrue(app.buttons["mobile.terminalConnectButton"].waitForExistence(timeout: 5))
        }
    }

    private func openFilesTab(app: XCUIApplication) {
        let workspacePicker = app.segmentedControls["mobile.workspacePicker"]
        if workspacePicker.waitForExistence(timeout: 2) {
            let filesCoordinate = workspacePicker.coordinate(
                withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)
            )
            filesCoordinate.tap()
            if !app.textFields["mobile.filesRemotePathField"].waitForExistence(timeout: 2) {
                filesCoordinate.tap()
            }
            return
        }

        let tabBarButton = app.tabBars.buttons["Files"]
        if tabBarButton.waitForExistence(timeout: 2) {
            tabBarButton.tap()
            return
        }

        let floatingTabButton = app.buttons["Files"].firstMatch
        XCTAssertTrue(floatingTabButton.waitForExistence(timeout: 5))
        floatingTabButton.tap()
    }

    private func returnToServerList(app: XCUIApplication, workspaceTitle: String) {
        let navigationBar = app.navigationBars[workspaceTitle]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
        let backButton = navigationBar.buttons.firstMatch
        XCTAssertTrue(backButton.exists)
        backButton.tap()
        XCTAssertTrue(app.navigationBars["JTS Terminal"].waitForExistence(timeout: 5))
    }

    private func isExpectedConnectionFailure(_ message: String) -> Bool {
        message.contains("Cannot reach") ||
            message.contains("Connection timed out") ||
            message.contains("Authentication failed") ||
            message.contains("Network path") ||
            message.contains("Verify the host key")
    }

    /// First connections to an SSH endpoint ask the user to verify its host
    /// key fingerprint. Trust it for fixture flows, or cancel to keep the
    /// connection failing.
    private func respondToHostKeyPromptIfPresented(
        app: XCUIApplication,
        trust: Bool,
        timeout: TimeInterval = 5
    ) {
        let alert = app.alerts["Verify Host Key"]
        guard alert.waitForExistence(timeout: timeout) else { return }
        attachScreenshot(named: "host-key-verification")
        alert.buttons[trust ? "Trust and Connect" : "Cancel"].tap()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct FixtureServerConfiguration {
    let name: String
    let host: String
    let port: Int
    let username: String
    let password: String
    let remotePath: String
    let expectedFileName: String

    var launchArguments: [String] {
        [
            "-mobile-seed-name", name,
            "-mobile-seed-host", host,
            "-mobile-seed-port", "\(port)",
            "-mobile-seed-username", username,
            "-mobile-seed-password", "jts-ui-test-invalid-password",
            "-mobile-seed-remote-path", remotePath,
        ]
    }

    static func fromEnvironment() throws -> FixtureServerConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["JTS_IOS_E2E_HOST"],
              let portValue = environment["JTS_IOS_E2E_PORT"],
              let port = Int(portValue),
              let username = environment["JTS_IOS_E2E_USERNAME"],
              let password = environment["JTS_IOS_E2E_PASSWORD"] else {
            throw XCTSkip("Set JTS_IOS_E2E_* with scripts/run_ios_e2e_fixture_test.sh.")
        }

        return FixtureServerConfiguration(
            name: environment["JTS_IOS_E2E_NAME"] ?? "Fixture Server",
            host: host,
            port: port,
            username: username,
            password: password,
            remotePath: environment["JTS_IOS_E2E_REMOTE_PATH"] ?? "/",
            expectedFileName: environment["JTS_IOS_E2E_EXPECTED_FILE"] ?? "fixture.txt"
        )
    }
}

private extension XCUIElement {
    func replaceText(with text: String) {
        tap()
        if let currentValue = value as? String,
           !currentValue.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        }
        typeText(text)
    }
}
