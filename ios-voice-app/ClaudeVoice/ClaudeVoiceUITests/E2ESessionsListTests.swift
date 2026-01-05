//
//  E2ESessionsListTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for sessions list navigation
//

import XCTest

final class E2ESessionsListTests: E2ETestBase {

    /// Tests sessions list: tap project shows sessions, message counts, back navigation
    func test_sessions_list_complete_flow() throws {
        // --- Test 1: Tap project shows sessions ---
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should show project1")

        project1.tap()

        // Should show sessions list with project name as title
        let navTitle = app.navigationBars["e2e_test_project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should navigate to sessions list")

        // Should show session titles (first user message)
        let session1Title = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1Title.waitForExistence(timeout: 5), "Should show session 1 title")

        let session2Title = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2Title.waitForExistence(timeout: 5), "Should show session 2 title")

        // --- Test 2: Sessions show message counts ---
        let count2 = app.staticTexts["2 messages"]
        XCTAssertTrue(count2.waitForExistence(timeout: 5), "Should show message count")

        // --- Test 3: Back navigation returns to projects ---
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        backButton.tap()

        let projectsTitle = app.navigationBars["Projects"]
        XCTAssertTrue(projectsTitle.waitForExistence(timeout: 5), "Should return to projects list")
    }
}
