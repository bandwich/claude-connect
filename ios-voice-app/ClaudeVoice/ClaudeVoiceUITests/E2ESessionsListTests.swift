//
//  E2ESessionsListTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for sessions list navigation
//

import XCTest

final class E2ESessionsListTests: E2ETestBase {

    
    func test_tap_project_shows_sessions() throws {
        // Wait for projects to load
        let project1 = app.staticTexts["e2e-test-project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should show project1")

        // Tap project
        project1.tap()

        // Should show sessions list with project name as title
        let navTitle = app.navigationBars["e2e-test-project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should navigate to sessions list")

        // Should show session titles (first user message)
        let session1Title = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1Title.waitForExistence(timeout: 5), "Should show session 1 title")

        let session2Title = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2Title.waitForExistence(timeout: 5), "Should show session 2 title")
    }

    
    func test_sessions_show_message_counts() throws {
        // Navigate to project1
        let project1 = app.staticTexts["e2e-test-project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        // Session 1 has 2 messages, Session 2 has 3 messages
        let count2 = app.staticTexts["2 messages"]
        XCTAssertTrue(count2.waitForExistence(timeout: 5), "Should show message count")
    }

    
    func test_back_navigation_returns_to_projects() throws {
        // Navigate to sessions
        let project1 = app.staticTexts["e2e-test-project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        // Wait for sessions list
        let navTitle = app.navigationBars["e2e-test-project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5))

        // Tap back
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        backButton.tap()

        // Should return to projects list
        let projectsTitle = app.navigationBars["Projects"]
        XCTAssertTrue(projectsTitle.waitForExistence(timeout: 5), "Should return to projects list")
    }
}
