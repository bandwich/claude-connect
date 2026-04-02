//
//  E2ENavigationTests.swift
//  ClaudeConnectUITests
//
//  Tier 1 E2E tests for app navigation flow.
//

import XCTest

final class E2ENavigationTests: E2ETestBase {

    /// Full navigation: projects → sessions → session → back
    func test_navigation_flow() throws {
        navigateToProjectsList()

        // Projects list visible
        let projectCell = app.cells.firstMatch
        XCTAssertTrue(projectCell.waitForExistence(timeout: 5), "Project should exist")

        // Settings accessible
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        tapByCoordinate(settingsButton)
        let settingsNavBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsNavBar.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // Navigate to project detail
        tapByCoordinate(projectCell)
        let newSessionButton = app.buttons["New Session"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 5), "Should show sessions list")

        // Sessions/Files tabs
        let filesTab = app.buttons["Files"]
        XCTAssertTrue(filesTab.exists || app.buttons["Sessions"].exists, "Segmented control should exist")

        // Back to projects — use navigateToProjectsList which handles multiple navigation patterns
        navigateToProjectsList()
        XCTAssertTrue(app.buttons["Add Project"].waitForExistence(timeout: 5), "Should return to projects")
    }
}
