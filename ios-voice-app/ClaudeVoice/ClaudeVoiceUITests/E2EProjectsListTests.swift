//
//  E2EProjectsListTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for projects list functionality
//

import XCTest

final class E2EProjectsListTests: E2ETestBase {

    func test_projects_list_loads_on_connect() throws {
        // After connecting (done in setUp), projects list should load
        // Wait for projects to appear
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should show project1")

        let project2 = app.staticTexts["e2e_test_project2"]
        XCTAssertTrue(project2.waitForExistence(timeout: 5), "Should show project2")
    }

    func test_projects_list_shows_session_counts() throws {
        // Project 1 has 2 sessions, Project 2 has 1 session
        let project1Row = app.buttons.containing(.staticText, identifier: "e2e_test_project1").firstMatch
        XCTAssertTrue(project1Row.waitForExistence(timeout: 5), "Should find project1 row")

        // Look for session count badge "2"
        let count2 = app.staticTexts["2"]
        XCTAssertTrue(count2.exists, "Should show session count 2 for project1")
    }

    func test_settings_button_opens_settings() throws {
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")

        settingsButton.tap()

        let settingsTitle = app.staticTexts["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings view")

        // Dismiss
        app.buttons["Done"].tap()
    }
}
