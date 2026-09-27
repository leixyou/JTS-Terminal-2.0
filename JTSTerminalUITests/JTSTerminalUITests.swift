//
//  JTSTerminalUITests.swift
//  JTSTerminalUITests
//
//  Created by tester on 2026/4/29.
//

import XCTest
import Darwin

final class JTSTerminalUITests: XCTestCase {
    private var app: XCUIApplication!
    private var smokeConfiguration: SmokeConfiguration?
    private var didLaunchApp = false

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        didLaunchApp = false
        app = try UITestTargetApplication.makeApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments +=
            UITestTargetApplication.deterministicLanguageLaunchArguments()
        app.launchEnvironment["JTS_TERMINAL_UI_TESTING"] = "1"
        app.launchEnvironment[
            "JTS_TERMINAL_UI_TEST_INITIAL_LANGUAGE"
        ] = "en"
        smokeConfiguration = try AppReviewSSHSmokeConfigurationEnvironment.loadIfAvailable()
    }

    override func tearDownWithError() throws {
        if didLaunchApp {
            XCTAssertTrue(
                UITestTargetApplication
                    .terminateApplicationLaunchedByThisTest(app),
                "The exact UI-test application launched by this test must terminate before the next test starts."
            )
        }
        didLaunchApp = false
        smokeConfiguration = nil
        app = nil
    }

    @MainActor
    private func launchTargetApplication() {
        didLaunchApp = true
        app.launch()
    }

    @MainActor
    func testLanguagePickerDefaultsToEnglishAndSwitchesToChinese() throws {
        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        XCTAssertTrue(
            app.buttons["New Server"].waitForExistence(timeout: 8),
            "JTS Terminal should default to English."
        )

        let languagePicker = app.buttons["toolbar-language-picker"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 8), "The toolbar should expose the language switcher.")
        languagePicker.click()

        let chineseOption = app.buttons["toolbar-language-option-zh-Hans"].firstMatch
        XCTAssertTrue(
            chineseOption.waitForExistence(timeout: 3),
            "The language popover should expose Simplified Chinese."
        )
        chineseOption.click()
        XCTAssertTrue(
            app.buttons["新建服务器"].waitForExistence(timeout: 5),
            "Switching to Simplified Chinese should update the main server action."
        )
    }

    @MainActor
    func testAppReviewSSHCredentialSmoke() throws {
        guard let configuration = smokeConfiguration,
              !configuration.host.isEmpty,
              !configuration.username.isEmpty else {
            throw XCTSkip("Use scripts/run_app_review_ssh_smoke.sh to run the formal App Review SSH smoke test.")
        }
        if let validationFailure = configuration.appReviewValidationFailure {
            XCTFail(validationFailure)
            return
        }

        applySmokeConfiguration(configuration)
        let smokeNonce = configuration.nonce

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        openServerProperties()
        guard let readyReport = waitForSmokeStatus(
            expectedNonce: smokeNonce,
            expectedPhase: "ready",
            timeout: 8
        ) else {
            return
        }
        XCTAssertNil(readyReport.exitCode, "The ready state must not claim a process exit code.")
        XCTAssertNil(readyReport.markerMatched, "The ready state must not claim a marker result.")
        XCTAssertNil(
            readyReport.credentialConsumed,
            "The ready state must not claim that the one-shot helper token was consumed."
        )
        app.buttons["test-ssh-connection-button"].click()
        waitForSuccessfulConnection(expectedNonce: smokeNonce)
    }

    @MainActor
    func testAppReviewSSHSmokeStatusSurfacePublishesNonceBoundReadyState() throws {
        let smokeNonce = UUID().uuidString
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_HOST"] = "example.invalid"
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_USER"] = "appreview"
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_NONCE"] = smokeNonce
        app.launchEnvironment["JTS_TERMINAL_UI_SYNTHETIC_SMOKE_STATUS"] = "1"
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_DISABLE_SSH_AUTOSTART"] = "1"

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        openServerProperties()
        guard let report = waitForSmokeStatus(
            expectedNonce: smokeNonce,
            expectedPhase: "ready",
            timeout: 8
        ) else {
            return
        }

        XCTAssertNil(report.exitCode)
        XCTAssertNil(report.markerMatched)
        XCTAssertNil(report.credentialConsumed)
        XCTAssertFalse(
            app.launchEnvironment.keys.contains(where: { $0.contains("PASSWORD") }),
            "Synthetic and formal UI smoke launches must not carry a password."
        )
    }

    @MainActor
    func testOpenInteractiveSSHWorkspaceRendersWithSyntheticProfile() throws {
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_SESSION_HOST"] = "example.invalid"
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_SESSION_USER"] = "ui-test"
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_DISABLE_SSH_AUTOSTART"] = "1"

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        openServerProperties()
        let openButton = app.buttons["open-interactive-ssh-button"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 8), "Open Interactive SSH button should be available in Server Properties.")
        XCTAssertTrue(waitUntilEnabled(openButton, timeout: 5), "Open Interactive SSH button should be enabled for the synthetic UI test profile.")
        scrollToHittable(openButton)
        openButton.click()

        let terminal = app.descendants(matching: .any)["swiftterm-pty-view"]
        let fallbackTerminal = app.descendants(matching: .any)["terminal-pty-view"]
        let paneNameButton = app.buttons["terminal-mcp-pane-name-button"]
        let paneControlToggle = app.switches["terminal-mcp-control-toggle"]
        let sshTab = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "SSH:")).firstMatch
        let deadline = Date().addingTimeInterval(8)

        while Date() < deadline {
            if terminal.exists || fallbackTerminal.exists || paneNameButton.exists || paneControlToggle.exists || sshTab.exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTAssertNotEqual(app.state, .notRunning, "JTS Terminal should still be running after opening the interactive SSH workspace.")
        XCTFail("Interactive SSH panel did not appear after clicking Open Interactive SSH.")
    }

    @MainActor
    func testMissingImportedSSHPasswordPromptsBeforeTestAndInteractiveLaunch() throws {
        let uniqueHost = "missing-password-\(UUID().uuidString.lowercased()).invalid"
        try applyImportedSSHProfileFixture(
            host: uniqueHost,
            username: "imported-user"
        )

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        openServerProperties()
        let testButton = serverPropertiesElement("test-ssh-connection-button")
        XCTAssertTrue(testButton.waitForExistence(timeout: 8))
        scrollToHittable(testButton)
        XCTAssertTrue(waitUntilEnabled(testButton, timeout: 5))
        XCTAssertTrue(waitUntilHittable(testButton, timeout: 3))
        testButton.click()

        let promptSheet = app.descendants(matching: .any)[
            "ssh-credential-prompt-sheet"
        ].firstMatch
        XCTAssertTrue(
            promptSheet.waitForExistence(timeout: 5),
            "Testing an imported profile without a saved password should open the credential sheet."
        )
        let passwordField = promptSheet.descendants(matching: .any)[
            "ssh-credential-prompt-password-field"
        ].firstMatch
        XCTAssertTrue(
            passwordField.waitForExistence(timeout: 5),
            "Testing an imported profile without a saved password should prompt before launching SSH."
        )
        let testOnceButton = promptSheet.buttons["ssh-credential-prompt-test-once-button"]
        let saveTestButton = promptSheet.buttons["ssh-credential-prompt-save-test-button"]
        let cancelTestButton = promptSheet.buttons["ssh-credential-prompt-cancel-button"]
        XCTAssertTrue(testOnceButton.waitForExistence(timeout: 3))
        XCTAssertTrue(saveTestButton.waitForExistence(timeout: 3))
        XCTAssertTrue(cancelTestButton.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(cancelTestButton, timeout: 3))
        cancelTestButton.click()
        XCTAssertTrue(
            waitUntilMissing(passwordField, timeout: 3),
            "Cancelling the password prompt should return to Server Properties without launching SSH."
        )

        let openButton = serverPropertiesElement("open-interactive-ssh-button")
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        scrollToHittable(openButton)
        XCTAssertTrue(waitUntilEnabled(openButton, timeout: 5))
        XCTAssertTrue(waitUntilHittable(openButton, timeout: 3))
        openButton.click()

        let startButton = app.buttons["terminal-start-button"].firstMatch
        XCTAssertTrue(
            startButton.waitForExistence(timeout: 8),
            "The imported SSH workspace should expose an explicit Start action when auto-start is disabled."
        )
        startButton.click()
        XCTAssertTrue(
            passwordField.waitForExistence(timeout: 5),
            "Starting an imported profile without a saved password should prompt before creating the PTY process."
        )
        XCTAssertTrue(promptSheet.buttons["ssh-credential-prompt-connect-once-button"].waitForExistence(timeout: 3))
        XCTAssertTrue(promptSheet.buttons["ssh-credential-prompt-save-connect-button"].waitForExistence(timeout: 3))
        let cancelConnectButton = promptSheet.buttons["ssh-credential-prompt-cancel-button"]
        XCTAssertTrue(cancelConnectButton.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(cancelConnectButton, timeout: 3))
        cancelConnectButton.click()
        XCTAssertTrue(waitUntilMissing(passwordField, timeout: 3))
        XCTAssertTrue(startButton.exists)
    }

    #if ENABLE_RDP_2
    @MainActor
    func testHostedRDPConnectedViewingShowsAIControlsWithoutLeaseCountdown() throws {
        try assertHostedRDPActivity(
            mode: .connectedViewing,
            expectedStatus: "AI Viewing"
        )
    }

    @MainActor
    func testHostedRDPConnectedControlShowsAIControlsWithoutLeaseCountdown() throws {
        try assertHostedRDPActivity(
            mode: .connectedControl,
            expectedStatus: "AI Control"
        )
    }

    @MainActor
    func testHostedRDPRemoteInputFocusReturnsToLocalUIWhenWindowDeactivates() throws {
        try applyImportedRDPProfileFixture(mode: .connectedControl)

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()
        openHostedRDPDesktop()

        let workspace = app.groups["rdp-desktop-workspace"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 8))

        var focusButton = hostedRDPInputFocusButton()
        XCTAssertTrue(
            focusButton.waitForExistence(timeout: 5),
            "A connected framebuffer must expose explicit remote-input focus."
        )
        XCTAssertTrue(waitUntilHittable(focusButton, timeout: 3))
        XCTAssertTrue(hostedRDPInputIsLocal())
        focusButton.click()

        XCTAssertTrue(
            waitUntil(timeout: 3, condition: hostedRDPInputIsRemote),
            "Focusing the framebuffer must expose an explicit release action."
        )

        focusButton = hostedRDPInputFocusButton()
        XCTAssertTrue(waitUntilHittable(focusButton, timeout: 3))
        focusButton.click()
        XCTAssertTrue(
            waitUntil(timeout: 3, condition: hostedRDPInputIsLocal),
            "The visible Release Input action must return focus to JTS Terminal."
        )

        focusButton = hostedRDPInputFocusButton()
        XCTAssertTrue(waitUntilHittable(focusButton, timeout: 3))
        focusButton.click()
        XCTAssertTrue(
            waitUntil(timeout: 3, condition: hostedRDPInputIsRemote),
            "Remote input must be focusable again after an explicit release."
        )

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 5),
            "Activating Finder must move the hosted JTS Terminal app to the background."
        )
        XCTAssertTrue(
            waitUntil(timeout: 3, condition: hostedRDPInputIsLocal),
            "Window deactivation must release remote input before JTS Terminal is reactivated."
        )

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(hostedRDPInputIsLocal())

        focusButton = hostedRDPInputFocusButton()
        XCTAssertTrue(waitUntilHittable(focusButton, timeout: 3))
        focusButton.click()
        XCTAssertTrue(
            waitUntil(timeout: 3, condition: hostedRDPInputIsRemote),
            "Remote input must remain focusable after application reactivation."
        )

        app.typeKey(.escape, modifierFlags: [.control, .command])
        XCTAssertTrue(
            waitUntil(timeout: 3, condition: hostedRDPInputIsLocal),
            "Control-Command-Escape must finish the test with local keyboard focus."
        )
    }

    @MainActor
    func testHostedRDPStoppingShowsAIControlsWithoutLeaseCountdown() throws {
        try assertHostedRDPActivity(
            mode: .connectedStopping,
            expectedStatus: "AI Control stopping"
        )
    }

    @MainActor
    func testHostedRDPNarrowLayoutKeepsCriticalControlsAndMovesSecondaryActions() throws {
        try applyImportedRDPProfileFixture(mode: .connectedControl)
        app.launchEnvironment["JTS_TERMINAL_UI_RDP_NARROW_WINDOW"] = "1"

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()
        openHostedRDPDesktop()

        let mainWindow = hostedRDPDesktopWindow()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 8))
        let corner = mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -280, dy: -160)))
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                mainWindow.frame.width <= 940 &&
                    mainWindow.frame.height <= 700
            },
            "The narrow fixture must settle at the supported minimum window instead of the preferred 1320-by-820-point layout."
        )

        let workspace = app.groups["rdp-desktop-workspace"].firstMatch
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 8),
            "The narrow fixture should open its Desktop workspace."
        )
        let overflowQuery = workspace.descendants(matching: .any).matching(
            identifier: "rdp-secondary-actions-menu"
        )
        let overflow = overflowQuery.firstMatch
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 5),
            "At the supported minimum width, Companion and display actions should move into More."
        )
        guard waitForActionableElement(in: overflowQuery, timeout: 5) != nil else {
            XCTFail("The More menu must remain reachable at the supported minimum width.")
            return
        }

        for (identifier, visibleTitle) in [
            ("rdp-take-control-button", "Take Control"),
            ("rdp-emergency-stop-button", "Emergency Stop"),
            ("rdp-disconnect-button", "Disconnect"),
        ] {
            let buttonQuery = app.buttons.matching(identifier: identifier)
            let firstButton = buttonQuery.firstMatch
            XCTAssertTrue(
                firstButton.waitForExistence(timeout: 5),
                "The narrow control bar must keep \(identifier) visible."
            )
            guard let button = waitForActionableElement(
                in: buttonQuery,
                timeout: 5
            ) else {
                XCTFail(
                    "The narrow control bar must keep \(visibleTitle) reachable."
                )
                return
            }
            XCTAssertTrue(
                button.label.localizedCaseInsensitiveContains(visibleTitle),
                "The narrow control bar must retain the visible '\(visibleTitle)' label."
            )
            XCTAssertTrue(
                mainWindow.frame.insetBy(dx: -1, dy: -1).contains(button.frame),
                "\(visibleTitle) must remain inside the supported narrow window."
            )
            XCTAssertTrue(
                workspace.frame.insetBy(dx: -1, dy: -1).contains(button.frame),
                "\(visibleTitle) must remain inside the RDP desktop workspace."
            )
        }

        XCTAssertEqual(
            workspace.buttons.matching(identifier: "rdp-ai-access-button").count,
            0,
            "Routine AI Access Management belongs in the top-level toolbar, not the desktop critical-control group."
        )
        let accessManagementButton = app.buttons[
            "rdp-ai-access-button"
        ].firstMatch
        XCTAssertTrue(
            accessManagementButton.waitForExistence(timeout: 5),
            "The top-level toolbar must keep AI Access Management reachable for RDP."
        )
        XCTAssertTrue(
            waitUntilHittable(accessManagementButton, timeout: 3),
            "AI Access Management must remain actionable at the supported minimum width."
        )
        XCTAssertTrue(
            mainWindow.frame.insetBy(dx: -1, dy: -1).contains(
                accessManagementButton.frame
            ),
            "AI Access Management must remain inside the supported narrow window."
        )

        // ViewThatFits may replace the workspace accessibility node while the
        // narrow control bar settles. Resolve the stable app-wide identifier,
        // then assert below that the resulting button is inside the workspace.
        let focusQuery = app.buttons.matching(
            identifier: "rdp-remote-input-focus-button"
        )
        let firstFocusButton = focusQuery.firstMatch
        XCTAssertTrue(
            firstFocusButton.waitForExistence(timeout: 5),
            "The narrow layout must keep remote-input focus visible."
        )
        guard let focusButton = waitForActionableElement(
            in: focusQuery,
            timeout: 5
        ) else {
            XCTFail("The narrow layout must keep remote-input focus reachable.")
            return
        }
        XCTAssertTrue(
            mainWindow.frame.insetBy(dx: -1, dy: -1).contains(focusButton.frame),
            "Remote-input focus must remain inside the supported narrow window."
        )
    }

    @MainActor
    func testHostedRDPPersistentGrantApprovalAndRevocation() throws {
        try applyImportedRDPProfileFixture(mode: .pendingPersistentGrant)

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()
        openHostedRDPDesktop()

        let workspace = app.groups["rdp-desktop-workspace"].firstMatch
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 8),
            "The imported RDP fixture should open its Desktop workspace."
        )
        let pendingAccessButtons = workspace.buttons.matching(
            identifier: "rdp-ai-pending-access-button"
        )
        XCTAssertEqual(
            pendingAccessButtons.count,
            1,
            "The Desktop workspace must show exactly one contextual entry for its pending AI request."
        )
        XCTAssertTrue(
            pendingAccessButtons.firstMatch.waitForExistence(timeout: 3),
            "The pending AI request must remain actionable from the Desktop workspace."
        )
        let accessButton = app.buttons["rdp-ai-access-button"].firstMatch
        XCTAssertTrue(accessButton.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilEnabled(accessButton, timeout: 3))
        XCTAssertTrue(
            waitUntilHittable(accessButton, timeout: 5),
            "AI Access must be reachable before opening the authorization panel."
        )
        accessButton.click()

        let pendingRow = app.descendants(matching: .any)[
            "rdp-ai-pending-request-row"
        ].firstMatch
        guard pendingRow.waitForExistence(timeout: 3) else {
            XCTFail(
                "The hosted pending-grant fixture was not seeded through ContentView."
            )
            return
        }

        XCTAssertTrue(
            pendingRow.staticTexts["Codex UI Fixture"].waitForExistence(timeout: 3),
            "The approval must identify the registered client."
        )
        let authorizationTarget = app.descendants(matching: .any)[
            "rdp-ai-authorization-target"
        ].firstMatch
        XCTAssertTrue(
            authorizationTarget.waitForExistence(timeout: 3),
            "The approval panel must show the actual Windows account and endpoint."
        )
        XCTAssertEqual(
            authorizationTarget.value as? String,
            "rdp://ui-test@\(HostedRDPFixtureMode.reservedHost):3389"
        )
        let alwaysAllowQuery = pendingRow.buttons.matching(
            identifier: "rdp-ai-always-allow-button"
        )
        XCTAssertTrue(alwaysAllowQuery.firstMatch.waitForExistence(timeout: 3))
        guard let alwaysAllow = waitForActionableElement(
            in: alwaysAllowQuery,
            timeout: 5
        ) else {
            XCTFail("The persistent approval action must be reachable.")
            return
        }
        XCTAssertEqual(
            alwaysAllow.label,
            "Always Allow & Consent",
            "Persistent access that sends target data externally must name both effects."
        )
        alwaysAllow.click()

        let activeRow = app.descendants(matching: .any)[
            "rdp-ai-active-grant-row"
        ].firstMatch
        XCTAssertTrue(
            activeRow.waitForExistence(timeout: 5),
            "Always Allow should replace the pending request with one active grant."
        )
        XCTAssertTrue(activeRow.staticTexts["Codex UI Fixture"].exists)
        XCTAssertTrue(
            activeRow.staticTexts["Access remains until revoked"].exists,
            "RDP access should be described as persistent instead of time leased."
        )
        assertNoControlLeaseCountdown(in: activeRow)

        let revokeQuery = activeRow.buttons.matching(
            identifier: "rdp-ai-revoke-button"
        )
        XCTAssertTrue(revokeQuery.firstMatch.waitForExistence(timeout: 3))
        guard let revoke = waitForActionableElement(
            in: revokeQuery,
            timeout: 5
        ) else {
            XCTFail("The persistent grant revocation action must be reachable.")
            return
        }
        revoke.click()
        XCTAssertTrue(
            waitUntilMissing(activeRow, timeout: 5),
            "Revoking the client should remove its active grant."
        )
    }

    @MainActor
    func testRDPAIAccessManagementFollowsSelectedChineseLanguage() throws {
        try applyImportedRDPProfileFixture(mode: .connectedViewing)

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        let languagePicker = app.buttons["toolbar-language-picker"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 8))
        languagePicker.click()
        let chineseOption = app.buttons["toolbar-language-option-zh-Hans"].firstMatch
        XCTAssertTrue(chineseOption.waitForExistence(timeout: 3))
        chineseOption.click()

        let accessButton = app.buttons["rdp-ai-access-button"].firstMatch
        XCTAssertTrue(accessButton.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(accessButton, timeout: 3))
        XCTAssertTrue(
            accessButton.label.hasPrefix("AI 访问"),
            "The top-level toolbar item must inherit the selected app language."
        )
        accessButton.click()

        XCTAssertTrue(
            app.radioButtons["访问"].waitForExistence(timeout: 3),
            "The sheet must inherit the selected app language."
        )
        XCTAssertTrue(app.radioButtons["审计"].exists)

        let emptyState = app.descendants(matching: .any)[
            "rdp-ai-empty-access-state"
        ].firstMatch
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 3),
            "A target with no grants should show one concise access state."
        )
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                emptyState.label.contains("直接使用")
                    || String(describing: emptyState.value).contains("直接使用")
            },
            "The empty state must explain that enabling MCP authorizes registered clients directly."
        )
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "临时控制")
            ).count,
            0,
            "Persistent RDP access must not be described as temporary control."
        )
    }

    @MainActor
    func testRDPServerMenuUsesOpenDesktopAndReturnsToDesktop() throws {
        try applyImportedRDPProfileFixture(mode: .connectedViewing)

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()
        openHostedRDPDesktop()

        let workspace = app.groups["rdp-desktop-workspace"].firstMatch
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 8),
            "The imported RDP fixture should initially open Desktop."
        )

        hostedRDPDesktopWindow().buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitUntilMissing(workspace, timeout: 5), "Closing hides the desktop window.")
        app.windows["com.lljts.JTSTerminal.main-window"].firstMatch.click()
        app.typeKey("5", modifierFlags: .command)

        let accessManagementButton = app.buttons[
            "rdp-ai-access-button"
        ].firstMatch
        XCTAssertTrue(
            accessManagementButton.waitForExistence(timeout: 5),
            "RDP should keep AI Access Management available from the top-level toolbar outside the Desktop workspace."
        )
        XCTAssertTrue(waitUntilHittable(accessManagementButton, timeout: 3))

        let serverMenu = app.menuBars.menuBarItems["Server"].firstMatch
        XCTAssertTrue(serverMenu.waitForExistence(timeout: 5))
        serverMenu.click()

        let openDesktop = app.menuItems["Open Desktop"].firstMatch
        XCTAssertTrue(
            openDesktop.waitForExistence(timeout: 3),
            "The selected RDP profile should expose Open Desktop in the Server menu."
        )
        XCTAssertTrue(waitUntilEnabled(openDesktop, timeout: 3))
        XCTAssertFalse(
            app.menuItems["Open Interactive Terminal"].exists,
            "An RDP profile must not be presented as an interactive terminal."
        )
        openDesktop.click()

        XCTAssertTrue(
            workspace.waitForExistence(timeout: 8),
            "Open Desktop should route the selected RDP profile back to its Desktop workspace."
        )
    }
    #endif

    @MainActor
    func testPasswordActionsRequireNewInputAndConfirmDeletion() throws {
        try applyImportedSSHProfileFixture(
            host: "credential-actions-\(UUID().uuidString.lowercased()).invalid",
            username: "imported-user"
        )

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()
        openServerProperties()

        let savePassword = app.buttons[
            "connection-save-password-button"
        ].firstMatch
        let passwordStatus = app.descendants(matching: .any)[
            "connection-password-status"
        ].firstMatch
        let passwordField = app.descendants(matching: .any)[
            "connection-password-field"
        ].firstMatch
        XCTAssertTrue(savePassword.waitForExistence(timeout: 5))
        XCTAssertTrue(passwordStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        assertAccessibilityText(
            of: passwordStatus,
            contains: "No saved password",
            timeout: 5,
            message: "The isolated fixture must start without a saved password."
        )
        XCTAssertFalse(
            savePassword.isEnabled,
            "A loaded or empty field with no user change must not offer a redundant password save."
        )

        let deletePassword = app.buttons[
            "connection-delete-password-button"
        ].firstMatch
        XCTAssertTrue(deletePassword.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitUntil(timeout: 3) { !deletePassword.isEnabled },
            "Delete must stay disabled when the vault check proves no password exists."
        )

        passwordField.click()
        passwordField.typeText("ui-test-password-2")
        XCTAssertTrue(
            waitUntilEnabled(savePassword, timeout: 3),
            "Typing a new password must enable Save."
        )
        savePassword.click()
        assertAccessibilityText(
            of: passwordStatus,
            contains: "Password saved to the local encrypted vault",
            timeout: 5,
            message: "The isolated vault must report a completed save."
        )
        XCTAssertFalse(
            savePassword.isEnabled,
            "A successfully saved unchanged value must not offer a redundant save."
        )
        XCTAssertTrue(waitUntilEnabled(deletePassword, timeout: 5))
        scrollToHittable(deletePassword)
        deletePassword.click()

        let confirmDelete = app.buttons[
            "connection-confirm-delete-password-button"
        ].firstMatch
        XCTAssertTrue(
            confirmDelete.waitForExistence(timeout: 3),
            "Deleting a saved password must require an explicit destructive confirmation."
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntilMissing(confirmDelete, timeout: 3),
            "Cancelling deletion must close the confirmation without changing the saved password."
        )
        XCTAssertTrue(waitUntilEnabled(deletePassword, timeout: 3))

        deletePassword.click()
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3))
        confirmDelete.click()
        assertAccessibilityText(
            of: passwordStatus,
            contains: "Saved password deleted for this server",
            timeout: 5,
            message: "The destructive action must remove the isolated saved password."
        )
        XCTAssertTrue(
            waitUntil(timeout: 3) { !deletePassword.isEnabled },
            "Delete must disable after the saved password is removed."
        )
    }

    @MainActor
    func testNewServerOpensPropertiesBeforeInteractiveWorkspace() throws {
        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        let addServerButton = app.buttons["add-server-button"]
        XCTAssertTrue(addServerButton.waitForExistence(timeout: 8), "The sidebar New Server button should be visible.")
        XCTAssertTrue(app.textFields["server-search-field"].waitForExistence(timeout: 8), "The sidebar search field should be visible before creating a server.")
        XCTAssertTrue(
            mainWindowContentExists(),
            "The main window should show a stable workspace or empty state before creating a server."
        )

        addServerButton.click()

        XCTAssertTrue(
            waitForServerPropertiesWindow(timeout: 5),
            "New Server should open Server Properties before entering the remote workspace."
        )
        XCTAssertTrue(
            app.buttons["add-server-button"].exists,
            "Creating a server should keep the sidebar content available behind Server Properties."
        )
        XCTAssertTrue(
            app.textFields["server-search-field"].exists,
            "Creating a server should not make the sidebar search disappear."
        )
        XCTAssertTrue(
            mainWindowContentExists(),
            "Creating a server should keep the main window content visible behind Server Properties."
        )
        XCTAssertTrue(
            serverPropertiesElement("session-host-field").waitForExistence(timeout: 5),
            "The new-server flow should land on the connection form so the host can be configured first."
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(
            waitForServerPropertiesWindow(timeout: 3),
            "Escape should close Server Properties like the Cancel button."
        )
    }

    @MainActor
    func testClosingNewServerPropertiesWithWindowControlDiscardsDraft() throws {
        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        let serverRows = app.buttons.matching(identifier: "server-row")
        let initialServerCount = serverRows.count
        let addServerButton = app.buttons["add-server-button"]
        XCTAssertTrue(addServerButton.waitForExistence(timeout: 8))
        addServerButton.click()

        XCTAssertTrue(
            waitForServerPropertiesWindow(timeout: 5),
            "New Server should open its properties window."
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                serverRows.count == initialServerCount + 1
            },
            "The transient server should exist while its properties window is open."
        )

        let closeButton = serverPropertiesWindow.buttons[
            XCUIIdentifierCloseWindow
        ].firstMatch
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: 3),
            "Server Properties should expose the standard macOS close control."
        )
        XCTAssertTrue(waitUntilHittable(closeButton, timeout: 3))
        closeButton.click()

        XCTAssertFalse(
            waitForServerPropertiesWindow(timeout: 3),
            "The standard close control should close Server Properties."
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                serverRows.count == initialServerCount
            },
            "Closing an unconfigured new-server window must discard its detached draft."
        )
    }

    @MainActor
    func testToolbarNewServerOpensPropertiesSheet() throws {
        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        let toolbarNewServerButton = app.buttons["toolbar-new-server-button"]
        XCTAssertTrue(toolbarNewServerButton.waitForExistence(timeout: 8), "The macOS toolbar should expose New Server.")
        toolbarNewServerButton.click()

        XCTAssertTrue(
            waitForServerPropertiesWindow(timeout: 5),
            "The toolbar New Server command should follow the same configure-first flow as the sidebar button."
        )
        XCTAssertTrue(
            serverPropertiesElement("session-host-field").waitForExistence(timeout: 5),
            "Toolbar-created servers should open the host configuration field immediately."
        )
    }

    @MainActor
    func testServerPropertiesShowsMCPClientRegistrationStatusOnly() throws {
        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        let addServerButton = app.buttons["add-server-button"]
        XCTAssertTrue(addServerButton.waitForExistence(timeout: 8), "The sidebar New Server button should be visible.")
        addServerButton.click()

        XCTAssertTrue(
            waitForServerPropertiesWindow(timeout: 5),
            "New Server should open Server Properties."
        )

        let mcpAccessSection = serverPropertiesElement("session-mcp-access-section")
        let registrationSection = serverPropertiesElement("mcp-client-registration-section")
        XCTAssertTrue(
            mcpAccessSection.waitForExistence(timeout: 5),
            "Server Properties should group MCP profile access controls into one section."
        )
        XCTAssertTrue(
            registrationSection.waitForExistence(timeout: 5),
            "MCP client status should be part of the AI / MCP Access section."
        )

        let accessFrame = mcpAccessSection.frame
        let registrationFrame = registrationSection.frame
        XCTAssertGreaterThanOrEqual(
            registrationFrame.minY,
            accessFrame.minY,
            "MCP client status should follow the profile access controls instead of interrupting connection fields."
        )
        XCTAssertLessThanOrEqual(
            registrationFrame.maxY,
            accessFrame.maxY,
            "MCP client status should stay inside the AI / MCP Access section."
        )

        scrollToElement(serverPropertiesElement("mcp-registration-status-claude"))

        XCTAssertTrue(
            serverPropertiesElement("mcp-registration-status-claude").waitForExistence(timeout: 5),
            "Server Properties should show Claude Desktop MCP registration status."
        )
        XCTAssertTrue(
            serverPropertiesElement("mcp-registration-status-codex").waitForExistence(timeout: 5),
            "Server Properties should show Codex Desktop MCP registration status."
        )
        XCTAssertTrue(
            serverPropertiesElement("mcp-registration-status-antigravity").waitForExistence(timeout: 5),
            "Server Properties should show Antigravity MCP registration status."
        )
        XCTAssertTrue(
            serverPropertiesElement("mcp-registration-status-cursor").waitForExistence(timeout: 5),
            "Server Properties should show Cursor MCP registration status."
        )
        XCTAssertFalse(
            serverPropertiesElement("mcp-register-claude-button").exists,
            "Client registration should be managed from the top-level MCP menu, not Server Properties."
        )
        XCTAssertFalse(
            serverPropertiesElement("mcp-register-codex-button").exists,
            "Client registration should be managed from the top-level MCP menu, not Server Properties."
        )
        XCTAssertFalse(
            serverPropertiesElement("mcp-register-antigravity-button").exists,
            "Client registration should be managed from the top-level MCP menu, not Server Properties."
        )
    }

    @MainActor
    func testMCPMenuShowsAllRegisteredClientsWithoutDuplicateConfigurationActions() throws {
        app.launchEnvironment[
            "JTS_TERMINAL_UI_TEST_INITIAL_LANGUAGE"
        ] = "zh-Hans"
        app.launchEnvironment[
            "JTS_TERMINAL_UI_MCP_REGISTRATION_FIXTURE"
        ] = "registered-all-endpoints"

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        let mcpMenu = app.menuBars.menuBarItems["MCP"].firstMatch
        XCTAssertTrue(
            mcpMenu.waitForExistence(timeout: 8),
            "The isolated 2.0 app should expose its top-level MCP menu."
        )
        mcpMenu.click()

        for clientName in [
            "Claude Desktop",
            "Claude CLI",
            "Cursor",
            "Codex Desktop",
            "Codex CLI",
            "Grok CLI",
            "Antigravity",
        ] {
            let registered = app.menuItems[
                "\(clientName) - 已注册"
            ].firstMatch
            XCTAssertTrue(
                registered.waitForExistence(timeout: 5),
                "\(clientName) should be shown as registered."
            )
            XCTAssertFalse(
                registered.isEnabled,
                "\(clientName) must not offer another configuration action."
            )
            XCTAssertFalse(
                app.menuItems["配置 \(clientName)"].exists,
                "\(clientName) must not expose a duplicate configuration action."
            )
        }
    }

    @MainActor
    func testMCPCanonicalConfigAccessSurvivesSandboxedRelaunch() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jts-mcp-powerbox-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let configurationURL = temporaryDirectory
            .appendingPathComponent("config.toml")
        try "model = \"ui-test-model\"\n".write(
            to: configurationURL,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        app.launchEnvironment[
            "JTS_TERMINAL_UI_RESET_MCP_REGISTRATION_STATE"
        ] = "1"
        app.launchEnvironment[
            "JTS_TERMINAL_UI_MCP_CANONICAL_CONFIG_PATH"
        ] = configurationURL.path
        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        openMCPMenu()
        let registrationAction = app.menuItems[
            "Configure Codex Desktop"
        ].firstMatch
        XCTAssertTrue(
            registrationAction.waitForExistence(timeout: 5),
            "The isolated app should expose one state-aware Codex configuration action."
        )
        registrationAction.click()

        let authorizationPanel = app.dialogs[
            "Allow JTS Terminal to Configure Codex Desktop"
        ].firstMatch
        XCTAssertTrue(
            authorizationPanel.waitForExistence(timeout: 5),
            "The sandbox should show one system authorization for the canonical directory."
        )
        XCTAssertFalse(
            authorizationPanel.textFields["saveAsNameTextField"].exists,
            "The flow must not ask the user to type or choose a configuration filename."
        )
        XCTAssertTrue(
            authorizationPanel.buttons["Allow"].waitForExistence(timeout: 5),
            "The canonical authorization should require only one Allow action."
        )
        authorizationPanel.buttons["Allow"].click()

        let completionButton = app.dialogs.buttons["OK"].firstMatch
        XCTAssertTrue(
            completionButton.waitForExistence(timeout: 5),
            "Registration should finish without a file picker, replace prompt, or second apply step."
        )
        XCTAssertFalse(app.dialogs.buttons["Replace"].exists)
        XCTAssertFalse(app.dialogs.buttons["Apply This Diff"].exists)
        completionButton.click()

        openMCPMenu()
        let registeredItem = app.menuItems[
            "Codex Desktop - Registered"
        ].firstMatch
        XCTAssertTrue(
            registeredItem.waitForExistence(timeout: 5),
            "The current launch should immediately show the canonical endpoint as registered."
        )
        XCTAssertFalse(registeredItem.isEnabled)

        let storedConfiguration = try String(
            contentsOf: configurationURL,
            encoding: .utf8
        )
        XCTAssertTrue(
            storedConfiguration.contains("model = \"ui-test-model\""),
            "Registration must preserve unrelated Codex configuration."
        )
        XCTAssertTrue(
            storedConfiguration.contains(
                "[mcp_servers.jts-terminal]"
            ),
            "Registration must install the reviewed jts-terminal section."
        )

        XCTAssertTrue(
            UITestTargetApplication
                .terminateApplicationLaunchedByThisTest(app),
            "The first isolated launch should terminate before bookmark recovery is tested."
        )
        didLaunchApp = false
        app.launchEnvironment.removeValue(
            forKey: "JTS_TERMINAL_UI_RESET_MCP_REGISTRATION_STATE"
        )

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()
        openMCPMenu()

        let relaunchedRegisteredItem = app.menuItems[
            "Codex Desktop - Registered"
        ].firstMatch
        XCTAssertTrue(
            relaunchedRegisteredItem.waitForExistence(timeout: 5),
            "The sandboxed app must restore the canonical-directory bookmark after relaunch."
        )
        XCTAssertFalse(
            relaunchedRegisteredItem.isEnabled,
            "A recovered registration must remain non-repeatable."
        )
        XCTAssertFalse(
            app.menuItems["Configure Codex Desktop"].exists,
            "Relaunch must not regress to a duplicate registration action."
        )
    }

    @MainActor
    func testSavingNewServerClosesPropertiesSheet() throws {
        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        app.activate()

        let addServerButton = app.buttons["add-server-button"]
        XCTAssertTrue(addServerButton.waitForExistence(timeout: 8), "The sidebar New Server button should be visible.")
        addServerButton.click()
        XCTAssertTrue(waitForServerPropertiesWindow(timeout: 5))

        let hostField = serverPropertiesElement("session-host-field")
        if !hostField.waitForExistence(timeout: 1) {
            scrollServerPropertiesToTop()
        }
        replaceText(in: hostField, with: smokeConfiguration?.host ?? "example.invalid")
        let usernameField = serverPropertiesElement("session-username-field")
        replaceText(
            in: usernameField,
            with: smokeConfiguration?.username ?? "ui-test"
        )
        usernameField.typeKey(.tab, modifierFlags: [])

        let saveButton = serverPropertiesElement("server-properties-save-button")
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitUntilEnabled(saveButton, timeout: 5),
            "Save should be enabled once the required SSH host is configured."
        )
        saveButton.click()

        XCTAssertFalse(
            waitForServerPropertiesWindow(timeout: 3),
            "Saving a valid server should close Server Properties."
        )
    }

    @MainActor
    private func openMCPMenu() {
        let menu = app.menuBars.menuBarItems["MCP"].firstMatch
        XCTAssertTrue(
            menu.waitForExistence(timeout: 5),
            "The 2.0 app should expose its top-level MCP menu."
        )
        menu.click()
    }

    private func waitForSuccessfulConnection(
        expectedNonce: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let report = waitForSmokeStatus(
            expectedNonce: expectedNonce,
            expectedPhase: "succeeded",
            timeout: 25,
            file: file,
            line: line
        ) else {
            return
        }

        XCTAssertEqual(
            report.exitCode,
            0,
            "SSH smoke reported success with a nonzero exit code.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            report.markerMatched,
            true,
            "SSH smoke must match the fixed remote command marker.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            report.credentialConsumed,
            true,
            "SSH smoke must prove the signed askpass helper unlinked its one-shot token.",
            file: file,
            line: line
        )
    }

    private var smokeStatusElements: XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                SmokeStatusReport.accessibilityIdentifierPrefix
            )
        )
    }

    private func waitForSmokeStatus(
        expectedNonce: String,
        expectedPhase: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SmokeStatusReport? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastPhase = "status unavailable"
        var sawDifferentNonce = false

        while Date() < deadline {
            for element in smokeStatusElements.allElementsBoundByIndex {
                guard let report = try? SmokeStatusReport.decode(from: element) else {
                    continue
                }
                guard report.nonce == expectedNonce else {
                    sawDifferentNonce = true
                    continue
                }
                lastPhase = report.phase
                if report.phase == expectedPhase {
                    return report
                }
                if report.phase == "failed" {
                    XCTFail(
                        "SSH authentication, host verification, connection, or remote marker validation failed in the UI smoke test.",
                        file: file,
                        line: line
                    )
                    return nil
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        if lastPhase == "status unavailable", sawDifferentNonce {
            lastPhase = "status was published only for a different nonce"
        }
        XCTFail(
            "Timed out waiting for nonce-bound SSH phase '\(expectedPhase)'. Last phase: \(lastPhase)",
            file: file,
            line: line
        )
        return nil
    }

    private func openServerProperties(file: StaticString = #filePath, line: UInt = #line) {
        let toolbarPropertiesButton = app.buttons["toolbar-server-properties-button"].firstMatch
        let propertiesButton: XCUIElement
        if toolbarPropertiesButton.waitForExistence(timeout: 8), toolbarPropertiesButton.isEnabled {
            propertiesButton = toolbarPropertiesButton
        } else {
            propertiesButton = app.buttons["server-properties-button"].firstMatch
        }
        XCTAssertTrue(propertiesButton.waitForExistence(timeout: 8), "Server properties button should be available in the sidebar.", file: file, line: line)
        XCTAssertTrue(waitUntilEnabled(propertiesButton, timeout: 5), "Server properties button should be enabled.", file: file, line: line)
        propertiesButton.click()
    }

    private var serverPropertiesWindow: XCUIElement {
        serverPropertiesWindowCandidates.first(where: { $0.exists }) ?? serverPropertiesWindowCandidates[0]
    }

    private var serverPropertiesWindowCandidates: [XCUIElement] {
        [
            app.windows["server-properties-window"].firstMatch,
            app.windows["Server Properties"].firstMatch,
            app.descendants(matching: .any)["server-properties-content"].firstMatch
        ]
    }

    private func waitForServerPropertiesWindow(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if serverPropertiesWindowCandidates.contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return serverPropertiesWindowCandidates.contains(where: { $0.exists })
    }

    private func mainWindowContentExists() -> Bool {
        app.descendants(matching: .any)["remote-workspace-content"].exists
            || app.descendants(matching: .any)["empty-workspace-content"].exists
    }

    private func serverPropertiesElement(_ identifier: String) -> XCUIElement {
        let scoped = serverPropertiesWindow.descendants(matching: .any)[identifier].firstMatch
        if scoped.exists {
            return scoped
        }
        return app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isEnabled
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isHittable
    }

    /// SwiftUI can replace accessibility nodes while `ViewThatFits`, `List`,
    /// or a sheet finishes layout. Re-resolve the identifier query on every
    /// pass instead of pinning the first transient node returned by XCUI.
    private func waitForActionableElement(
        in query: XCUIElementQuery,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = query.allElementsBoundByIndex.first(where: {
                $0.exists && $0.isEnabled && $0.isHittable
            }) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return query.allElementsBoundByIndex.first(where: {
            $0.exists && $0.isEnabled && $0.isHittable
        })
    }

    private func waitUntilMissing(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func assertAccessibilityText(
        of element: XCUIElement,
        contains expectedText: String,
        timeout: TimeInterval,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matched = waitUntil(timeout: timeout) {
            guard element.exists else { return false }
            if element.label.contains(expectedText) {
                return true
            }
            return (element.value as? String)?.contains(expectedText) == true
        }
        guard !matched else { return }

        let diagnostic: String
        if element.exists {
            let label = String(reflecting: element.label)
            let value = String(reflecting: element.value as? String)
            diagnostic = "label=\(label), value=\(value)"
        } else {
            diagnostic = "element missing"
        }
        XCTFail(
            "\(message) Expected accessibility label or value containing \(String(reflecting: expectedText)); observed \(diagnostic).",
            file: file,
            line: line
        )
    }

    #if ENABLE_RDP_2
    private func hostedRDPInputFocusButton() -> XCUIElement {
        app.buttons["rdp-remote-input-focus-button"].firstMatch
    }

    private func hostedRDPInputIsLocal() -> Bool {
        let button = hostedRDPInputFocusButton()
        return button.exists
            && button.label.localizedCaseInsensitiveContains("Focus remote input")
            && (button.value as? String) == "Keyboard focus is in JTS Terminal."
    }

    private func hostedRDPInputIsRemote() -> Bool {
        let button = hostedRDPInputFocusButton()
        return button.exists
            && button.label.localizedCaseInsensitiveContains("Release remote input")
            && (button.value as? String)?.hasPrefix("Remote input is active.") == true
    }
    #endif

    private func scrollToHittable(_ element: XCUIElement) {
        let scrollView = serverPropertiesWindow.scrollViews.firstMatch
        var attempts = 0
        while element.exists, !element.isHittable, scrollView.exists, attempts < 4 {
            scrollView.swipeUp()
            attempts += 1
        }
    }

    private func scrollToElement(_ element: XCUIElement) {
        let scrollView = app.scrollViews.firstMatch
        var attempts = 0
        while !element.exists, scrollView.waitForExistence(timeout: 1), attempts < 6 {
            scrollView.swipeUp()
            attempts += 1
        }
    }

    private func scrollServerPropertiesToTop() {
        let scrollView = serverPropertiesWindow.scrollViews.firstMatch
        guard scrollView.waitForExistence(timeout: 1) else { return }
        for _ in 0..<6 {
            scrollView.swipeDown()
        }
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        app.activate()
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(value)
    }

    private func applySmokeConfiguration(_ configuration: SmokeConfiguration) {
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_HOST"] = configuration.host
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_USER"] = configuration.username
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_CREDENTIAL_ACCOUNT"] = configuration.credentialAccount
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_KNOWN_HOSTS_FILE"] = configuration.knownHostsFilePath
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_KNOWN_HOSTS_SHA256"] = configuration.knownHostsSHA256
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_BROKER_PORT"] = String(configuration.brokerPort)
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_BROKER_CHALLENGE"] = configuration.brokerChallenge
        app.launchEnvironment["JTS_TERMINAL_UI_SMOKE_NONCE"] = configuration.nonce
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_DISABLE_SSH_AUTOSTART"] = "1"
    }

    private func applyImportedSSHProfileFixture(host: String, username: String) throws {
        let document: [String: Any] = [
            "version": 2,
            "exportedAt": "2026-07-17T00:00:00Z",
            "sessions": [[
                "id": UUID().uuidString,
                "name": "Imported SSH without password",
                "host": host,
                "username": username,
                "port": 22,
                "connectionType": "ssh",
                "identityFile": "",
                "jumpHost": "",
                "folder": "Imported",
                "enableX11Forwarding": false,
                "remotePath": "~",
                "mcpEnabled": false,
                "mcpAlwaysAllowTerminalControl": false,
                "mcpAlias": "",
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_IMPORTED_PROFILE_BASE64"] = data.base64EncodedString()
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_DISABLE_SSH_AUTOSTART"] = "1"
    }

    #if ENABLE_RDP_2
    @MainActor
    private func hostedRDPDesktopWindow() -> XCUIElement {
        let id = app.launchEnvironment["JTS_TERMINAL_UI_RDP_FIXTURE_TARGET_ID"] ?? "missing"
        return app.windows["jts.rdp.desktop.\(id)"].firstMatch
    }

    @MainActor
    private func openHostedRDPDesktop() {
        let open = app.buttons["rdp-open-window-button"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.click()
        XCTAssertTrue(hostedRDPDesktopWindow().waitForExistence(timeout: 8))
    }

    @MainActor
    private func assertHostedRDPActivity(
        mode: HostedRDPFixtureMode,
        expectedStatus: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try applyImportedRDPProfileFixture(mode: mode)

        launchTargetApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8), file: file, line: line)
        app.activate()
        openHostedRDPDesktop()

        let workspace = app.groups["rdp-desktop-workspace"].firstMatch
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 8),
            "The imported RDP fixture should open its Desktop workspace.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            app.buttons["rdp-disconnect-button"].waitForExistence(timeout: 5),
            "A connected fixture should expose Disconnect.",
            file: file,
            line: line
        )

        let status = app.staticTexts["rdp-ai-control-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(
            status.value as? String,
            expectedStatus,
            "Expected '\(expectedStatus)' but found '\(String(describing: status.value))'.",
            file: file,
            line: line
        )

        let identity = app.descendants(matching: .any)["rdp-ai-client-identity"].firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 5), file: file, line: line)
        let identityValue = identity.value as? String
        XCTAssertTrue(
            identityValue?.contains("Codex UI Fixture") == true,
            "The workspace must name the active AI client without truncating its accessibility value.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            identityValue?.contains(mode.expectedClientRolePrefix) == true,
            "The complete accessibility value must describe whether the client is viewing or controlling.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            identityValue?.contains("Authorization ID: ui-test-rdp-client-") == true,
            "The complete accessibility value must include the registered authorization identity.",
            file: file,
            line: line
        )

        for identifier in ["rdp-take-control-button", "rdp-emergency-stop-button"] {
            let button = app.buttons[identifier].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
            XCTAssertTrue(waitUntilEnabled(button, timeout: 3), file: file, line: line)
        }
        assertNoControlLeaseCountdown(in: workspace, file: file, line: line)
    }

    private func assertNoControlLeaseCountdown(
        in container: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbiddenText in PersistentRDPControlLeaseTextPolicy.forbiddenFragments {
            XCTAssertEqual(
                container.staticTexts.matching(
                    PersistentRDPControlLeaseTextPolicy.predicate(
                        for: forbiddenText
                    )
                ).count,
                0,
                "Persistent RDP access must not render a lease countdown ('\(forbiddenText)').",
                file: file,
                line: line
            )
        }
    }

    private func applyImportedRDPProfileFixture(
        mode: HostedRDPFixtureMode
    ) throws {
        let fixtureID = UUID()
        let targetID = UUID()
        let capabilities = [
            "discovery",
            "desktopObserve",
            "desktopControl",
            "commandExecution",
            "fileAccess",
            "destructiveOperations",
            "elevation",
            "structuredTasks",
        ]
        let document: [String: Any] = [
            "version": 2,
            "exportedAt": "2026-07-17T00:00:00Z",
            "sessions": [[
                "id": targetID.uuidString,
                "name": "Hosted RDP UI Fixture",
                "host": HostedRDPFixtureMode.reservedHost,
                "username": "ui-test",
                "port": 3_389,
                "connectionType": "RDP",
                "identityFile": "",
                "jumpHost": "",
                "folder": "UI Tests",
                "enableX11Forwarding": false,
                "remotePath": "~",
                "rdpProfile": [
                    "domain": "",
                    "desktopWidth": 1_280,
                    "desktopHeight": 720,
                    "certificateTrustMode": "systemOrPinned",
                    "clipboardEnabled": false,
                    "clipboardPreferenceSchemaVersion": 1,
                    "companionPolicy": "optional",
                    "persistentMCPControlEnabled": true,
                    "permissionPolicy": [
                        "maximumCapabilities": capabilities,
                        "controlLeaseCapabilities": [],
                        "controlIdleTimeoutSeconds": 900,
                        "requireExternalDataConsent": true,
                    ],
                ],
                "mcpEnabled": true,
                "mcpAlwaysAllowTerminalControl": false,
                "mcpAlias": "rdp-ui-fixture",
            ]],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        )
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_IMPORTED_PROFILE_BASE64"] =
            data.base64EncodedString()
        app.launchEnvironment["JTS_TERMINAL_UI_RDP_FIXTURE_ID"] =
            fixtureID.uuidString.lowercased()
        app.launchEnvironment["JTS_TERMINAL_UI_RDP_FIXTURE_TARGET_ID"] =
            targetID.uuidString.lowercased()
        app.launchEnvironment["JTS_TERMINAL_UI_RDP_FIXTURE_MODE"] = mode.rawValue
        app.launchEnvironment["JTS_TERMINAL_UI_GRANT_STORE_NAMESPACE"] =
            fixtureID.uuidString.lowercased()
    }
    #endif

}

enum PersistentRDPControlLeaseTextPolicy {
    static let forbiddenFragments = [
        "Control until",
        "Control lease",
        "Lease expires",
        "remaining",
    ]

    static func predicate(for forbiddenText: String) -> NSPredicate {
        NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            forbiddenText,
            forbiddenText
        )
    }
}

#if ENABLE_RDP_2
private enum HostedRDPFixtureMode: String {
    case connectedViewing = "connected-viewing"
    case connectedControl = "connected-control"
    case connectedStopping = "connected-stopping"
    case pendingPersistentGrant = "pending-persistent-grant"

    static let reservedHost = "rdp-ui.example.invalid"

    var expectedClientRolePrefix: String {
        switch self {
        case .connectedViewing, .pendingPersistentGrant:
            "Viewing:"
        case .connectedControl, .connectedStopping:
            "Control:"
        }
    }
}
#endif

struct SmokeConfiguration {
    let host: String
    let username: String
    let credentialAccount: String
    let knownHostsFilePath: String
    let knownHostsSHA256: String
    let brokerPort: UInt16
    let brokerChallenge: String
    let nonce: String

    var appReviewValidationFailure: String? {
        guard username == "appreview" else {
            return "Formal App Review SSH smoke requires the appreview username."
        }
        guard credentialAccount == "\(username)@\(host):22" else {
            return "Formal App Review SSH smoke credential account does not match the target."
        }

        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty,
              normalizedHost != "localhost",
              !normalizedHost.hasSuffix(".localhost"),
              !normalizedHost.hasSuffix(".local"),
              Self.resolvesExclusivelyToGlobalAddresses(normalizedHost) else {
            return "Formal App Review SSH smoke requires a globally routable target."
        }

        return nil
    }

    private static func resolvesExclusivelyToGlobalAddresses(_ host: String) -> Bool {
        var result: UnsafeMutablePointer<addrinfo>?
        guard Darwin.getaddrinfo(host, nil, nil, &result) == 0, let result else {
            return false
        }
        defer { Darwin.freeaddrinfo(result) }

        var foundAddress = false
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let entry = current {
            defer { current = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            switch Int32(entry.pointee.ai_family) {
            case AF_INET:
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
                guard isGlobalIPv4(bytes) else { return false }
                foundAddress = true
            case AF_INET6:
                let ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
                guard isGlobalIPv6(bytes) else { return false }
                foundAddress = true
            default:
                continue
            }
        }
        return foundAddress
    }

    private static func isGlobalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        let third = bytes[2]
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 0 && (third == 0 || third == 2) { return false }
        if first == 192 && second == 168 { return false }
        if first == 198 && (second == 18 || second == 19 || (second == 51 && third == 100)) {
            return false
        }
        if first == 203 && second == 0 && third == 113 { return false }
        return true
    }

    private static func isGlobalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isGlobalIPv4(Array(bytes[12...15]))
        }
        guard (bytes[0] & 0xe0) == 0x20 else { return false }
        if bytes[0] == 0x20,
           bytes[1] == 0x01,
           bytes[2] == 0x0d,
           bytes[3] == 0xb8 {
            return false
        }
        return true
    }
}

private enum SmokeStatusReportDecodingError: Error {
    case invalidAccessibilityIdentifier
    case missingPayload
}

private struct SmokeStatusReport: Decodable {
    static let accessibilityIdentifierPrefix = "app-review-ssh-smoke-status.v1."

    let phase: String
    let nonce: String
    let exitCode: Int?
    let markerMatched: Bool?
    let credentialConsumed: Bool?

    static func decode(from element: XCUIElement) throws -> Self {
        if let report = try? decode(accessibilityIdentifier: element.identifier) {
            return report
        }

        for candidate in [element.value as? String, element.label] {
            guard let candidate,
                  let data = candidate.data(using: .utf8),
                  let report = try? JSONDecoder().decode(Self.self, from: data) else {
                continue
            }
            return report
        }
        throw SmokeStatusReportDecodingError.missingPayload
    }

    static func decode(accessibilityIdentifier identifier: String) throws -> Self {
        guard identifier.hasPrefix(accessibilityIdentifierPrefix) else {
            throw SmokeStatusReportDecodingError.invalidAccessibilityIdentifier
        }
        let payload = String(identifier.dropFirst(accessibilityIdentifierPrefix.count))
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !payload.isEmpty,
              payload.unicodeScalars.allSatisfy(allowedCharacters.contains),
              payload.count % 4 != 1 else {
            throw SmokeStatusReportDecodingError.invalidAccessibilityIdentifier
        }

        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64) else {
            throw SmokeStatusReportDecodingError.invalidAccessibilityIdentifier
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
