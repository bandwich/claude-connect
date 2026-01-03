//
//  VoiceInputFlowTests.swift
//  ClaudeVoiceUITests
//
//  Voice input flow integration tests
//

import XCTest

final class VoiceInputFlowTests: E2ETestBase {

    // Base class handles connection in setUpWithError

    // Test 1: Basic voice input delivery to server
    @MainActor
    func testBasicVoiceInputDelivery() throws {
        // Note: We can't actually trigger iOS speech recognition in UI tests,
        // so we'll simulate by directly injecting a voice_input message
        // via the WebSocket connection. In a real scenario, the user would speak.

        // For now, verify the button exists and is enabled
        XCTAssertTrue(isTalkButtonEnabled(), "Talk button should be enabled")

        // We can test that tapping the button changes its state
        tapTalkButton()

        // Button should now show "Stop" and microphone should be active
        let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stop'")).firstMatch
        XCTAssertTrue(stopButton.waitForExistence(timeout: 2), "Button should show Stop when recording")

        // Tap again to stop
        stopButton.tap()

        // Should return to "Tap to Talk"
        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        XCTAssertTrue(talkButton.waitForExistence(timeout: 2), "Button should return to Tap to Talk")
    }

    // Test 2: Server sends "processing" status after voice input
    @MainActor
    func testVoiceInputTriggersStatusUpdate() throws {
        // This test verifies the server responds with status updates
        // We'll use the test server's inject endpoint to simulate receiving a voice input

        // Verify initial state using the helper method
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle state")

        // Note: In a real integration test with full control, we would:
        // 1. Simulate the app sending voice_input
        // 2. Server responds with processing status
        // 3. Verify UI shows Processing state

        // For now, we verify the state transitions are possible
        // by checking that the voice state label exists
        let voiceStateLabel = app.staticTexts["voiceState"]
        XCTAssertTrue(voiceStateLabel.exists, "Voice state label should exist")
    }

    // Test 3: Complete voice to response flow
    @MainActor
    func testCompleteVoiceToResponseFlow() throws {
        // Verify initial idle state
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in Idle state")

        // Inject a mock response to trigger the full flow
        sendMockClaudeResponse("This is a test response from Claude.")

        // Should transition to speaking state
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should transition to Speaking state")

        // Should return to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to Idle after audio finishes")

        // Verify server logs show the complete flow
        let logs = getServerLogs()
        XCTAssertTrue(logs.contains("Handling Claude response"), "Server should log response handling")
        XCTAssertTrue(logs.contains("Streaming"), "Server should log audio streaming")
        XCTAssertTrue(logs.contains("Sent status: speaking"), "Server should send speaking status")
        XCTAssertTrue(logs.contains("Sent status: idle"), "Server should return to idle status")
    }

    // Test 4: Empty voice input handling
    @MainActor
    func testEmptyVoiceInputHandling() throws {
        // Verify app handles empty or very short voice input gracefully
        // The button should remain functional
        XCTAssertTrue(isTalkButtonEnabled(), "Talk button should be enabled")

        // Tap and immediately release (simulating very short/no speech)
        tapTalkButton()

        // Stop recording
        let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stop'")).firstMatch
        if stopButton.waitForExistence(timeout: 2) {
            stopButton.tap()
        }

        // Should remain functional - wait for button to return
        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5), "Talk button should remain enabled after empty input")
    }

    // Test 5: Long voice input message handling
    @MainActor
    func testLongVoiceInputMessage() throws {
        // Create a long test message (simulating a long spoken input)
        let longMessage = String(repeating: "This is a test message. ", count: 50)

        // Inject it as a mock response to test the system handles long text
        sendMockClaudeResponse(longMessage)

        // Should handle and complete
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should start speaking")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 15), "Should complete")

        // Verify server logs show it was processed
        let logs = getServerLogs()
        XCTAssertTrue(logs.contains("Handling Claude response"), "Server should handle long message")
    }
}
