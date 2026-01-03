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
        // Tap project1
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        // Wait for sessions list
        let navTitle = app.navigationBars["e2e_test_project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5))

        // Tap first session
        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()
    }

    
    func test_tap_session_shows_message_history() throws {
        navigateToSession1()

        // Should show session view with messages
        let userMessage = app.staticTexts["Hello Claude"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5), "Should show user message")

        let assistantMessage = app.staticTexts["Hi! How can I help?"]
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5), "Should show assistant message")
    }

    
    func test_session_view_shows_voice_controls() throws {
        navigateToSession1()

        // Should have talk button
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5), "Should show talk button")

        // Should have voice indicator
        let voiceIndicator = app.otherElements["VoiceIndicator"]
        XCTAssertTrue(voiceIndicator.waitForExistence(timeout: 5), "Should show voice indicator")
    }

    
    func test_voice_input_from_session_view() throws {
        navigateToSession1()

        // Wait for view to settle
        sleep(1)

        // Simulate conversation turn using the session's transcript
        simulateConversationTurn(
            userInput: "Follow up question",
            assistantResponse: "Here's my follow up answer"
        )

        // Should transition to speaking
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")

        // Should return to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to Idle")
    }

    
    func test_settings_accessible_from_session_view() throws {
        navigateToSession1()

        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")

        settingsButton.tap()

        let settingsTitle = app.staticTexts["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings view")

        app.buttons["Done"].tap()
    }
}
