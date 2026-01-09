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

        let projectLabelPrefix = testProjectName + ","
        let projectButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", projectLabelPrefix)).firstMatch
        XCTAssertTrue(projectButton.waitForExistence(timeout: 5), "Project should exist")

        // Settings accessible - use regular tap, wait for button to be hittable
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")

        // Wait a moment for UI to settle, then tap
        sleep(1)
        settingsButton.tap()

        // Settings sheet uses navigationTitle which creates a navigation bar
        let settingsNavBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsNavBar.waitForExistence(timeout: 5), "Settings sheet should appear")
        app.buttons["Done"].tap()

        // PHASE 2: Sessions list
        print("📍 PHASE 2: Sessions list")

        projectButton.tap()
        // Custom nav bar doesn't create standard NavigationBar - look for New Session button instead
        let newSessionButton = app.buttons["New Session"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 5), "Should navigate to sessions list")

        // Session exists
        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist")

        // PHASE 3: Session view
        print("📍 PHASE 3: Session view")

        // Use coordinate tap to avoid XCTest idle-wait timeout (SessionView has continuous SwiftUI updates)
        tapByCoordinate(sessionCell)

        // Wait for sync (uses HTTP-based verification to avoid XCTest idle-wait issues)
        XCTAssertTrue(waitForSessionSyncComplete(timeout: 15), "Session should sync")

        // Skip UI element checks in SessionView - SwiftUI re-renders block XCTest
        // The HTTP-based sync check above verifies the session is working

        // PHASE 4: Back navigation
        print("📍 PHASE 4: Back navigation")

        // Use coordinate tap for back button to avoid idle-wait issues
        let backButton = app.buttons.element(boundBy: 0)
        tapByCoordinate(backButton)

        // Give time for navigation, then verify we're back
        sleep(2)
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 5), "Should return to sessions list")

        app.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Add Project"].waitForExistence(timeout: 5), "Should return to projects list")

        print("✅ Navigation flow passed")
    }
}
