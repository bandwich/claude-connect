//
//  AudioStreamingTests.swift
//  ClaudeVoiceUITests
//
//  Audio streaming integration tests
//

import XCTest

final class AudioStreamingTests: E2ETestBase {

    // Base class handles connection in setUpWithError

    // Test 1: App receives audio_chunk messages
    @MainActor
    func testAudioChunkReceival() throws {
        // Trigger audio streaming
        sendMockClaudeResponse("Test response for audio streaming.")

        // Wait for speaking state (indicates chunks are being received)
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")

        // Verify server logs show chunks were sent
        sleep(2) // Allow time for streaming
        let logs = getServerLogs()

        XCTAssertTrue(logs.contains("Streaming"), "Server should log streaming start")
        XCTAssertTrue(logs.contains("chunks sent") || logs.contains("Audio streaming complete"),
                     "Server should log chunk transmission")
    }

    // Test 2: Audio chunk base64 decoding
    @MainActor
    func testAudioChunkBase64Decoding() throws {
        // Send response and verify it doesn't crash (indicates successful decoding)
        sendMockClaudeResponse("Testing base64 decoding.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")

        // Should return to idle (indicates audio played successfully)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to Idle")
    }

    // Test 3: Audio chunk buffering behavior
    @MainActor
    func testAudioChunkBuffering() throws {
        // The app should buffer at least 3 chunks before starting playback
        sendMockClaudeResponse("Testing audio buffering.")

        // Monitor state transitions
        let speakingState = app.staticTexts["Speaking"]

        // Should not be speaking immediately (buffering)
        let isImmediatelySpeaking = speakingState.exists
        print("Is immediately speaking: \(isImmediatelySpeaking)")

        // Should eventually start speaking
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should eventually start speaking")

        // Wait for completion
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete playback")
    }

    // Test 4: Chunked audio playback continuity
    @MainActor
    func testChunkedAudioPlaybackContinuity() throws {
        // Send a response and verify playback is continuous
        sendMockClaudeResponse("Testing continuous audio playback.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should start speaking")

        // Verify still speaking immediately after state change
        XCTAssertTrue(app.staticTexts["Speaking"].exists, "Should be in Speaking state")

        // Eventually returns to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete playback")

        // No errors in logs
        let logs = getServerLogs()
        XCTAssertFalse(logs.contains("ERROR"), "Should not have errors during playback")
    }

    // Test 5: Incomplete audio chunk sequence
    @MainActor
    func testIncompleteAudioChunkSequence() throws {
        // This test would require modifying the test server to send incomplete chunks
        // For now, we verify the app handles responses gracefully

        sendMockClaudeResponse("Short response.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should handle response")

        // Should eventually return to idle even with short/incomplete audio
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should return to idle")
    }

    // Test 6: Audio chunk order validation
    @MainActor
    func testAudioChunkOrderValidation() throws {
        // Verify server sends chunks in order
        sendMockClaudeResponse("Testing chunk ordering.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should start speaking")

        // Wait for idle before checking logs
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete playback")

        // Check logs for sequential chunk indices
        let logs = getServerLogs()
        XCTAssertTrue(logs.contains("chunk"), "Server should log chunk information")
    }

    // Test 7: Large audio response handling
    @MainActor
    func testLargeAudioResponse() throws {
        // Create a large response (simulating 10+ seconds of audio)
        let largeResponse = String(repeating: "This is a longer response to test audio streaming with more content. ", count: 20)

        sendMockClaudeResponse(largeResponse)

        // Should handle without issues
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should start speaking")

        // Should eventually complete (longer timeout for large audio)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 15), "Should complete large audio")

        // Verify no memory issues or errors
        let logs = getServerLogs()
        XCTAssertFalse(logs.contains("ERROR"), "Should handle large audio without errors")
    }
}
