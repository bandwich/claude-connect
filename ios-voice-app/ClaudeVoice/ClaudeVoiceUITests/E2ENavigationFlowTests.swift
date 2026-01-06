//
//  E2ENavigationFlowTests.swift
//  ClaudeVoiceUITests
//
//  Comprehensive navigation test covering the entire app navigation flow
//  Replaces: E2EProjectsListTests, E2ESessionsListTests, E2ESessionViewTests
//

import XCTest

final class E2ENavigationFlowTests: E2ETestBase {

    /// Complete navigation flow test
    /// Tests: Projects list → Sessions list → Session view → Settings → Back navigation
    func test_complete_navigation_flow() throws {
        // ============================================================
        // PHASE 1: Projects List
        // ============================================================
        print("📍 PHASE 1: Projects list")

        // Projects should load after connection (setUp connects)
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should show project1")

        let project2 = app.staticTexts["e2e_test_project2"]
        XCTAssertTrue(project2.waitForExistence(timeout: 5), "Should show project2")

        // Session counts visible
        let count2 = app.staticTexts["2"]
        XCTAssertTrue(count2.exists, "Should show session count")

        // Settings accessible from projects list
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.exists, "Settings button should exist")
        settingsButton.tap()

        let settingsTitle = app.staticTexts["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings")
        app.buttons["Done"].tap()

        // ============================================================
        // PHASE 2: Sessions List
        // ============================================================
        print("📍 PHASE 2: Sessions list")

        project1.tap()

        let navTitle = app.navigationBars["e2e_test_project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should navigate to sessions list")

        // Sessions show titles (first user message)
        let session1Title = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1Title.waitForExistence(timeout: 5), "Should show session 1 title")

        let session2Title = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2Title.waitForExistence(timeout: 5), "Should show session 2 title")

        // Message counts visible
        let messageCount = app.staticTexts["2 messages"]
        XCTAssertTrue(messageCount.waitForExistence(timeout: 5), "Should show message count")

        // ============================================================
        // PHASE 3: Session View
        // ============================================================
        print("📍 PHASE 3: Session view")

        session1Title.tap()

        // Message history visible
        let userMessage = app.staticTexts["Hello Claude"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5), "Should show user message")

        let assistantMessage = app.staticTexts["Hi! How can I help?"]
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5), "Should show assistant message")

        // Voice controls visible
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5), "Should show talk button")

        // Settings accessible from session view
        settingsButton.tap()
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings from session")
        app.buttons["Done"].tap()

        // ============================================================
        // PHASE 4: Back Navigation
        // ============================================================
        print("📍 PHASE 4: Back navigation")

        // Back to sessions list
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        backButton.tap()

        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should return to sessions list")

        // Back to projects list
        backButton.tap()

        let projectsTitle = app.navigationBars["Projects"]
        XCTAssertTrue(projectsTitle.waitForExistence(timeout: 5), "Should return to projects list")

        print("✅ Complete navigation flow test passed!")
    }
}
