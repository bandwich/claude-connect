//
//  E2EHappyPathTests.swift
//  ClaudeVoiceUITests
//
//  Happy path E2E tests
//

import XCTest

final class E2EHappyPathTests: E2ETestBase {

    /// Tests single turn and multiple turns in sequence
    func test_voice_conversation_flow() throws {
        navigateToTestSession()

        // Verify initial state
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

        // --- Test 1: Single conversation turn ---
        simulateConversationTurn(
            userInput: "Hello Claude",
            assistantResponse: "Hi! How can I help you today?"
        )

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")
        sleep(3) // Wait for audio
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should return to Idle")

        // --- Test 2: Multiple turns in sequence ---
        sleep(1)
        simulateConversationTurn(userInput: "Second message", assistantResponse: "Response two")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should speak response 2")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle after 2")

        sleep(1)
        simulateConversationTurn(userInput: "Third message", assistantResponse: "Response three")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should speak response 3")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle after 3")
    }
}
