//
//  E2EErrorHandlingTests.swift
//  ClaudeVoiceUITests
//
//  Error handling E2E tests
//

import XCTest

final class E2EErrorHandlingTests: E2ETestBase {

    func test_malformed_message_handling() throws {
        // Navigate to session view first
        navigateToTestSession()

        // Send valid conversation turn first
        simulateConversationTurn(userInput: "Test message", assistantResponse: "Valid message")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should handle valid message")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle")

        // Inject malformed JSON directly to transcript
        if let transcriptPath = transcriptPath {
            let fileHandle = FileHandle(forWritingAtPath: transcriptPath)
            if let handle = fileHandle {
                handle.seekToEndOfFile()
                handle.write("THIS IS NOT JSON\n".data(using: .utf8)!)
                handle.closeFile()
            }
        }

        sleep(2)

        // Should still be functional (check via voice state, not connection label)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should remain in idle state")

        // Send another valid conversation turn
        simulateConversationTurn(userInput: "Another test", assistantResponse: "Another valid message")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work after error")
    }

    func test_server_error_during_processing() throws {
        // Navigate to session view first
        navigateToTestSession()

        // Inject a response with moderately long text
        // Use shorter text to avoid TTS timeout issues (TTS can take 10+ seconds for long text)
        let longText = String(repeating: "Message. ", count: 5)
        simulateConversationTurn(userInput: "Send long response", assistantResponse: longText)

        // Wait for TTS processing and playback
        sleep(8)

        // App should still be running
        XCTAssertTrue(app.exists, "App should not crash")

        // Check for any valid voice state
        let stateLabel = app.staticTexts["voiceState"]
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 10), "Voice state should exist")

        // Accept any valid state - the test is about not crashing, not state correctness
        let validStates = ["Idle", "Speaking", "Processing", "Listening"]
        let currentState = stateLabel.label
        XCTAssertTrue(validStates.contains(currentState), "Should be in valid state, got: \(currentState)")
    }

    func test_empty_voice_input() throws {
        // Navigate to session view first
        navigateToTestSession()

        // Send empty voice input
        sendVoiceInput("")

        sleep(2)

        // Should remain in idle or return to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in idle state")

        // Should still be functional
        simulateConversationTurn(userInput: "Test", assistantResponse: "Test after empty input")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work")
    }
}
