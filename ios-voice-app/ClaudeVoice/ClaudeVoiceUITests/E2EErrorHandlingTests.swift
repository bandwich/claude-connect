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

        // Inject a response with moderately long text (tests handling without blocking server)
        let longText = String(repeating: "Very long message. ", count: 20)
        simulateConversationTurn(userInput: "Send long response", assistantResponse: longText)

        // Should either handle it or show error, but not crash
        sleep(5)

        // App should still be running
        XCTAssertTrue(app.exists, "App should not crash")

        // Try to recover with normal message
        simulateConversationTurn(userInput: "Send normal response", assistantResponse: "Normal message")
        sleep(2)

        let hasValidState = waitForVoiceState("Idle", timeout: 5) || waitForVoiceState("Speaking", timeout: 5)
        XCTAssertTrue(hasValidState, "Should be in valid state")
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
