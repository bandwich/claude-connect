//
//  E2EHappyPathTests.swift
//  ClaudeVoiceUITests
//
//  Happy path E2E tests
//

import XCTest

final class E2EHappyPathTests: E2ETestBase {

    func test_complete_voice_conversation_flow() throws {
        // Navigate to session view first (voice controls are there)
        navigateToTestSession()

        // Verify initial state
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

        // Simulate complete conversation turn
        simulateConversationTurn(
            userInput: "Hello Claude",
            assistantResponse: "Hi! How can I help you today?"
        )

        // Should transition to speaking
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")

        // Should return to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to Idle")
    }

    func test_multiple_conversation_turns() throws {
        // Navigate to session view first
        navigateToTestSession()

        // Define conversation turns
        let turns = [
            ("First message", "Response one"),
            ("Second message", "Response two"),
            ("Third message", "Response three")
        ]

        // Verify initial state
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

        // Execute each turn
        for (index, (input, response)) in turns.enumerated() {
            simulateConversationTurn(userInput: input, assistantResponse: response)
            XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Turn \(index + 1): Should speak")
            XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Turn \(index + 1): Should return to idle")
        }
    }
}
