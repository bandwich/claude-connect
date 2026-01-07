//
//  E2EErrorHandlingTests.swift
//  ClaudeVoiceUITests
//
//  Error handling E2E tests
//

import XCTest

final class E2EErrorHandlingTests: E2ETestBase {

    /// Tests malformed messages, long responses, empty input
    func test_error_handling_complete_flow() throws {
        navigateToTestSession()

        // --- Test 1: Malformed message handling ---
        // Send valid conversation turn first (real flow)
        sendVoiceInput("Test message")
        sleep(1)
        injectAssistantResponse("Valid message")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should handle valid message")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle")

        // Inject malformed JSON
        if let transcriptPath = transcriptPath {
            let fileHandle = FileHandle(forWritingAtPath: transcriptPath)
            if let handle = fileHandle {
                handle.seekToEndOfFile()
                handle.write("THIS IS NOT JSON\n".data(using: .utf8)!)
                handle.closeFile()
            }
        }

        sleep(2)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should remain in idle state after malformed JSON")

        // Verify still functional (real flow)
        sendVoiceInput("Another test")
        sleep(1)
        injectAssistantResponse("Another valid message")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work after error")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle")

        // --- Test 2: Empty voice input ---
        sendVoiceInput("")
        sleep(2)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in idle state after empty input")

        // Verify still functional (real flow)
        sendVoiceInput("Final test")
        sleep(1)
        injectAssistantResponse("Final response")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work after empty input")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle")

        // --- Test 3: Moderately long response ---
        let longText = String(repeating: "Message. ", count: 5)
        sendVoiceInput("Send long response")
        sleep(1)
        injectAssistantResponse(longText)
        sleep(8)
        XCTAssertTrue(app.exists, "App should not crash with long response")

        let stateLabel = app.staticTexts["voiceState"]
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 10), "Voice state should exist")
        let validStates = ["Idle", "Speaking", "Processing", "Listening"]
        XCTAssertTrue(validStates.contains(stateLabel.label), "Should be in valid state")
    }
}
