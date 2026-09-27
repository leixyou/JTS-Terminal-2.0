//
//  JTSTerminalUITestsLaunchTests.swift
//  JTSTerminalUITests
//
//  Created by tester on 2026/4/29.
//

import XCTest

final class JTSTerminalUITestsLaunchTests: XCTestCase {
    private var app: XCUIApplication!
    private var didLaunchApp = false

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        didLaunchApp = false
        app = try UITestTargetApplication.makeApplication()
    }

    override func tearDownWithError() throws {
        if didLaunchApp {
            XCTAssertTrue(
                UITestTargetApplication
                    .terminateApplicationLaunchedByThisTest(app),
                "The exact UI-test application launched by this test must terminate before the next launch configuration starts."
            )
        }
        didLaunchApp = false
        app = nil
    }

    @MainActor
    func testLaunch() throws {
        app.launchEnvironment["JTS_TERMINAL_UI_TESTING"] = "1"
        app.launchEnvironment["JTS_TERMINAL_UI_TEST_INITIAL_LANGUAGE"] = "en"
        didLaunchApp = true
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
