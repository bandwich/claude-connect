//
//  E2ESessionViewTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for session view with message history and voice input
//

import XCTest

final class E2ESessionViewTests: E2ETestBase {

    /// Navigate to a specific session for testing
    private func navigateToSession1() {
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        let navTitle = app.navigationBars["e2e_test_project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5))

        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()
    }

    /// Tests session view UI: message history, voice controls, settings access
    func test_session_view_ui_elements() throws {
        navigateToSession1()

        // --- Test 1: Shows message history ---
        let userMessage = app.staticTexts["Hello Claude"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5), "Should show user message")

        let assistantMessage = app.staticTexts["Hi! How can I help?"]
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5), "Should show assistant message")

        // --- Test 2: Shows voice controls ---
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5), "Should show talk button")

        // --- Test 3: Settings accessible ---
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")

        settingsButton.tap()

        let settingsTitle = app.staticTexts["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings view")

        app.buttons["Done"].tap()
    }

    /// Test voice input from session view
    func test_session_view_voice_input() throws {
        navigateToSession1()

        sleep(1) // Wait for view to settle

        // Simulate conversation turn
        simulateConversationTurn(
            userInput: "Follow up question",
            assistantResponse: "Here's my follow up answer"
        )

        // Should transition to speaking
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")

        // Should return to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to Idle")
    }
}
