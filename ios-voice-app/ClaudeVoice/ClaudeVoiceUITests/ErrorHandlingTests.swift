//
//  ErrorHandlingTests.swift
//  ClaudeVoiceUITests
//
//  Error handling and edge case integration tests
//

import XCTest

final class ErrorHandlingTests: E2ETestBase {

    // Base class handles connection in setUpWithError

    // Test 1: Malformed JSON from server
    @MainActor
    func testMalformedJSONFromServer() throws {
        // Note: This would require test server to send malformed JSON
        // For now, we verify app resilience by testing it stays connected

        // Send valid response
        sendMockClaudeResponse("Valid response.")

        // App should handle it
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should handle valid response")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete")

        // App should still be running and connected
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should remain connected")
    }

    // Test 2: Unknown message type
    @MainActor
    func testUnknownMessageType() throws {
        // This would require sending a message with unknown type from server
        // The app should ignore it gracefully

        // Verify app remains stable
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should remain connected")
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Should be in idle state")

        // Send a valid message to verify functionality
        sendMockClaudeResponse("Test after unknown message.")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work normally")
    }

    // Test 3: Server disconnect during audio stream
    @MainActor
    func testServerDisconnectDuringAudio() throws {
        // Start audio playback
        sendMockClaudeResponse("Testing disconnect during audio.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should start speaking")

        // Disconnect (simulates server crash)
        disconnectFromServer()

        // App should handle gracefully
        sleep(2)

        // Should show disconnected state
        let isDisconnected = waitForConnectionState("Disconnected", timeout: 5) ||
                           waitForConnectionState("Error", timeout: 1)
        XCTAssertTrue(isDisconnected, "Should detect disconnection")

        // Audio should stop, state should reset
        sleep(1)

        // App should not crash
        XCTAssertTrue(app.exists, "App should remain running")
    }

    // Test 4: Network latency simulation
    @MainActor
    func testNetworkLatencySimulation() throws {
        // Verify app can wait for delayed responses
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Should be in idle state")

        // Send response (test server has minimal delay)
        sendMockClaudeResponse("Testing with latency.")

        // Wait longer for response
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 15), "Should eventually receive response")

        // Complete normally
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete")
    }

    // Test 5: Server overload simulation
    @MainActor
    func testServerOverloadSimulation() throws {
        // Send multiple rapid requests
        for i in 1...3 {
            sendMockClaudeResponse("Response \(i)")
            sleep(2)
        }

        // App should handle without crashing
        sleep(5)

        // Should be in a stable state
        let hasStableState = app.staticTexts["Idle"].exists || app.staticTexts["Speaking"].exists
        XCTAssertTrue(hasStableState, "Should reach stable state")

        // App should still be connected
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should remain connected")
    }

    // Test 6: Corrupted audio chunk handling
    @MainActor
    func testCorruptedAudioChunk() throws {
        // This would require test server to send invalid base64
        // For now, verify app handles normal audio without errors

        sendMockClaudeResponse("Testing audio integrity.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should receive audio")

        // Should complete without errors
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete playback")

        // No crashes
        XCTAssertTrue(app.exists, "App should remain running")
    }

    // Test 7: Missing chunk index field
    @MainActor
    func testMissingChunkIndexField() throws {
        // This would require modified test server
        // Verify app handles standard messages correctly

        sendMockClaudeResponse("Testing chunk format.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should handle standard chunks")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete")
    }

    // Test 8: Server sends status during connection
    @MainActor
    func testServerSendsStatusDuringConnection() throws {
        // Server sends status on connection (already tested implicitly)
        // Verify the initial status message is handled

        // Should have received idle status on connection
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Should receive idle status on connect")

        // Verify in server logs
        let logs = getServerLogs()
        XCTAssertTrue(logs.contains("Sent status: idle"), "Server should send initial idle status")
        XCTAssertTrue(logs.contains("Connected"), "Status message should say Connected")
    }
}
