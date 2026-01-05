//
//  E2EProjectsListTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for projects list functionality
//

import XCTest

final class E2EProjectsListTests: E2ETestBase {

    /// Tests projects list: loads on connect, shows session counts, settings accessible
    func test_projects_list_complete_flow() throws {
        // --- Test 1: Projects load on connect ---
        // After connecting (done in setUp), projects list should load
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should show project1")

        let project2 = app.staticTexts["e2e_test_project2"]
        XCTAssertTrue(project2.waitForExistence(timeout: 5), "Should show project2")

        // --- Test 2: Session counts are shown ---
        // Project 1 has 2 sessions
        let count2 = app.staticTexts["2"]
        XCTAssertTrue(count2.exists, "Should show session count 2 for project1")

        // --- Test 3: Settings button works ---
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")

        settingsButton.tap()

        let settingsTitle = app.staticTexts["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings view")

        // Dismiss settings
        app.buttons["Done"].tap()
    }
}
