//
//  E2EErrorHandlingTests.swift
//  ClaudeVoiceUITests
//
//  Error handling E2E tests
//

import XCTest

final class E2EErrorHandlingTests: E2ETestBase {

    @MainActor
    func test_malformed_message_handling() throws {
        // Send valid message first
        injectAssistantResponse("Valid message")
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

        // Should still be connected and functional
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should remain connected")

        // Send another valid message
        injectAssistantResponse("Another valid message")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work after error")
    }

    @MainActor
    func test_server_error_during_processing() throws {
        // Inject a response with very long text (may cause processing issues)
        let longText = String(repeating: "Very long message. ", count: 1000)
        injectAssistantResponse(longText)

        // Should either handle it or show error, but not crash
        sleep(5)

        // App should still be running
        XCTAssertTrue(app.exists, "App should not crash")

        // Try to recover with normal message
        injectAssistantResponse("Normal message")
        sleep(2)

        let hasValidState = app.staticTexts["Idle"].exists ||
                           app.staticTexts["Speaking"].exists ||
                           app.staticTexts["Connected"].exists
        XCTAssertTrue(hasValidState, "Should be in valid state")
    }

    @MainActor
    func test_empty_voice_input() throws {
        // Send empty voice input
        sendVoiceInput("")

        sleep(2)

        // Should remain in idle or return to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in idle state")

        // Should still be functional
        injectAssistantResponse("Test after empty input")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work")
    }
}
