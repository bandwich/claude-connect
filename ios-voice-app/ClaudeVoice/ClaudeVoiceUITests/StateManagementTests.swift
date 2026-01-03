//
//  StateManagementTests.swift
//  ClaudeVoiceUITests
//
//  State management integration tests
//

import XCTest

final class StateManagementTests: E2ETestBase {

    // Base class handles connection in setUpWithError

    // Test 1: Voice state transitions through full cycle
    @MainActor
    func testVoiceStateTransitions() throws {
        // Start in Idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

        // Trigger response
        sendMockClaudeResponse("Testing state transitions.")

        // Should transition to Speaking
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should transition to Speaking")

        // Should return to Idle after audio completes
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to Idle")

        // Verify server logs show state progression
        let logs = getServerLogs()
        XCTAssertTrue(logs.contains("Sent status: idle"), "Should have idle status")
        XCTAssertTrue(logs.contains("Sent status: speaking"), "Should have speaking status")
    }

    // Test 2: Connection state resilience
    @MainActor
    func testConnectionStateResilience() throws {
        // Verify connected
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should be connected")

        // Disconnect
        disconnectFromServer()

        // Should show disconnected
        XCTAssertTrue(waitForConnectionState("Disconnected", timeout: 5), "Should show disconnected")

        // Talk button should be disabled
        XCTAssertFalse(isTalkButtonEnabled(), "Talk button should be disabled when disconnected")

        // Reconnect
        connectToTestServer()

        // Should reconnect
        XCTAssertTrue(waitForConnectionState("Connected", timeout: 5), "Should reconnect")

        // Talk button should be enabled again
        XCTAssertTrue(isTalkButtonEnabled(), "Talk button should be enabled when reconnected")
    }

    // Test 3: UI state reflects server state
    @MainActor
    func testUIStateReflectsServerState() throws {
        // Idle state - gray indicator (implicitly tested by label)
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Should show Idle label")

        // Trigger speaking state
        sendMockClaudeResponse("Testing UI state reflection.")

        // Speaking state - should show Speaking label
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should show Speaking label")

        // Wait for completion
        sleep(3)

        // Back to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should show Idle label again")
    }

    // Test 4: Concurrent state updates
    @MainActor
    func testConcurrentStateUpdates() throws {
        // Send multiple rapid responses
        sendMockClaudeResponse("First response.")
        sleep(1)
        sendMockClaudeResponse("Second response.")

        // App should handle state updates without crashing
        sleep(5)

        // Should eventually settle to a stable state
        let hasStableState = app.staticTexts["Idle"].exists || app.staticTexts["Speaking"].exists
        XCTAssertTrue(hasStableState, "Should have a stable state")

        // Verify no crashes or UI inconsistencies
        XCTAssertTrue(app.exists, "App should still be running")
    }

    // Test 5: State after server restart
    @MainActor
    func testStateAfterServerRestart() throws {
        // This test verifies app behavior when server becomes unavailable
        // Note: We can't actually restart the server mid-test without complex orchestration

        // Verify current connected state
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should be connected initially")

        // Manually disconnect to simulate server unavailability
        disconnectFromServer()

        // Should show disconnected
        XCTAssertTrue(waitForConnectionState("Disconnected", timeout: 5), "Should detect disconnection")

        // Voice state should reset to idle
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Voice state should be Idle when disconnected")

        // Reconnect (simulates server coming back)
        connectToTestServer()

        // Should reconnect and reset properly
        XCTAssertTrue(waitForConnectionState("Connected", timeout: 5), "Should reconnect")
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Should reset to Idle state")
    }

    // Test 6: Button disabled during audio playback
    @MainActor
    func testButtonDisabledDuringAudioPlayback() throws {
        // Verify button is initially enabled
        XCTAssertTrue(isTalkButtonEnabled(), "Button should be enabled initially")

        // Trigger audio playback
        sendMockClaudeResponse("Testing button state during playback.")

        // Wait for speaking state
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should start speaking")

        // Button should be disabled during playback
        sleep(1)
        XCTAssertFalse(isTalkButtonEnabled(), "Button should be disabled during audio playback")

        // Wait for audio to finish
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Audio should complete")

        // Button should be enabled again
        sleep(1)
        XCTAssertTrue(isTalkButtonEnabled(), "Button should be re-enabled after playback")
    }

    // Test 9: Server idle ignored during playback (RACE CONDITION TEST)
    @MainActor
    func testServerIdleIgnoredDuringPlayback() throws {
        // This test validates the race condition protection in WebSocketManager.swift:236-241
        // Real server behavior: sends "idle" immediately after last chunk is sent,
        // but device still has buffered chunks playing for several more seconds

        // Start in Idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

        // Trigger audio playback
        sendMockClaudeResponse("Testing race condition protection with longer response.")

        // Wait for Speaking state (audio has started)
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should transition to Speaking")

        // Give audio a moment to buffer and start playing
        sleep(1)

        // Verify we're still speaking
        XCTAssertTrue(app.staticTexts["Speaking"].exists, "Should still be Speaking before injecting idle")

        // CRITICAL TEST: Manually send "idle" status while audio is still playing
        // This simulates the real server behavior where it sends "idle" after sending
        // all chunks, but before the device finishes playing buffered audio
        sendStatus("idle", message: "Premature idle (simulating race condition)")

        // Wait a moment for the status message to be received
        sleep(1)

        // ASSERT: App should STAY in Speaking state (race condition protection working)
        // The isPlayingAudio flag should prevent premature transition to idle
        XCTAssertTrue(app.staticTexts["Speaking"].exists,
                     "Should IGNORE premature idle and stay in Speaking while audio plays")

        // Verify we're definitely still in Speaking (double check)
        let voiceStateLabel = app.staticTexts["voiceState"]
        XCTAssertEqual(voiceStateLabel.label, "Speaking",
                      "Voice state should still be Speaking (not Idle)")

        // Now wait for audio to ACTUALLY finish playing
        // The onPlaybackFinished callback should trigger the real transition to Idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10),
                     "Should transition to Idle ONLY after audio finishes playing")

        // Verify Talk button is re-enabled
        sleep(1)
        XCTAssertTrue(isTalkButtonEnabled(), "Talk button should be enabled after legitimate idle")

        // Verify server logs show the race condition was detected
        let logs = getServerLogs()
        XCTAssertTrue(logs.contains("Injecting status: idle"),
                     "Server should have logged the manual idle injection")
    }
}
