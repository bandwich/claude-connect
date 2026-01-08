//
//  E2ENavigationFlowTests.swift
//  ClaudeVoiceUITests
//
//  Tests app navigation with real projects and sessions.
//

import XCTest

final class E2ENavigationFlowTests: E2ETestBase {

    /// Complete navigation flow test
    func test_navigation_flow() throws {
        // Ensure we start from projects list
        navigateToProjectsList()

        // PHASE 1: Projects list
        print("📍 PHASE 1: Projects list")

        let project = app.staticTexts[testProjectName]
        XCTAssertTrue(project.waitForExistence(timeout: 5), "Project should exist")

        // Settings accessible
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.exists, "Settings button should exist")
        settingsButton.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // PHASE 2: Sessions list
        print("📍 PHASE 2: Sessions list")

        project.tap()
        let navTitle = app.navigationBars[testProjectName]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should navigate to sessions list")

        // Session exists
        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist")

        // PHASE 3: Session view
        print("📍 PHASE 3: Session view")

        sessionCell.tap()

        // Wait for sync
        XCTAssertTrue(waitForSessionSyncComplete(timeout: 15), "Session should sync")

        // Voice controls visible
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 10), "Talk button should exist")

        // Settings accessible from session view
        settingsButton.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // PHASE 4: Back navigation
        print("📍 PHASE 4: Back navigation")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should return to sessions list")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5), "Should return to projects list")

        print("✅ Navigation flow passed")
    }
}
