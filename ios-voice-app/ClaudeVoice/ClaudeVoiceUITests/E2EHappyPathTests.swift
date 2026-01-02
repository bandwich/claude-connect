//
//  E2EHappyPathTests.swift
//  ClaudeVoiceUITests
//
//  Happy path E2E tests
//

import XCTest

final class E2EHappyPathTests: E2ETestBase {

    @MainActor
    func test_complete_voice_conversation_flow() throws {
        // Verify initial state
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

        // Simulate complete conversation turn
        simulateConversationTurn(
            userInput: "Hello Claude",
            assistantResponse: "Hi! How can I help you today?"
        )

        // Should transition to speaking
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")

        // Wait for audio to complete
        sleep(3)

        // Should return to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should return to Idle")
    }

    @MainActor
    func test_multiple_conversation_turns() throws {
        // Turn 1
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")
        simulateConversationTurn(userInput: "First message", assistantResponse: "Response one")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should speak response 1")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle after 1")

        // Turn 2
        sleep(1)
        simulateConversationTurn(userInput: "Second message", assistantResponse: "Response two")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should speak response 2")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle after 2")

        // Turn 3
        sleep(1)
        simulateConversationTurn(userInput: "Third message", assistantResponse: "Response three")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should speak response 3")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle after 3")

        // Verify still connected
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should still be connected")
    }
}
