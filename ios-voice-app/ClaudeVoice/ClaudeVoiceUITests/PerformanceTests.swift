//
//  PerformanceTests.swift
//  ClaudeVoiceUITests
//
//  Performance and timing integration tests
//

import XCTest

final class PerformanceTests: E2ETestBase {

    // Base class handles connection in setUpWithError

    // Test 1: End-to-end latency (response injection to audio playback)
    @MainActor
    func testEndToEndLatency() throws {
        // Measure time from sending response to speaking state
        let startTime = Date()

        sendMockClaudeResponse("Testing end-to-end latency.")

        // Wait for speaking state
        let didStartSpeaking = waitForVoiceState("Speaking", timeout: 10)
        let latency = Date().timeIntervalSince(startTime)

        XCTAssertTrue(didStartSpeaking, "Should start speaking")

        // Latency should be under 3 seconds (target)
        print("End-to-end latency: \(latency)s")
        XCTAssertLessThan(latency, 5.0, "Latency should be under 5 seconds (target: 3s)")

        // Wait for completion
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete")
    }

    // Test 2: Audio streaming latency (first chunk to playback start)
    @MainActor
    func testAudioStreamingLatency() throws {
        // This measures buffering delay
        let startTime = Date()

        sendMockClaudeResponse("Testing streaming latency.")

        // Wait for speaking state (when playback starts)
        let didStartSpeaking = waitForVoiceState("Speaking", timeout: 10)
        let streamLatency = Date().timeIntervalSince(startTime)

        XCTAssertTrue(didStartSpeaking, "Should start speaking")

        print("Audio streaming latency: \(streamLatency)s")

        // Should start playing within reasonable time
        XCTAssertLessThan(streamLatency, 3.0, "Streaming latency should be under 3 seconds")

        // Complete
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should complete")
    }

    // Test 3: Multiple sequential interactions (no message loss)
    @MainActor
    func testMultipleSequentialInteractions() throws {
        // Test 5 sequential voice interactions
        let iterations = 5

        for i in 1...iterations {
            print("Interaction \(i)/\(iterations)")

            // Send response
            sendMockClaudeResponse("Response number \(i).")

            // Should enter speaking state
            XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10),
                         "Iteration \(i): Should start speaking")

            // Should complete and return to idle
            XCTAssertTrue(waitForVoiceState("Idle", timeout: 10),
                         "Iteration \(i): Should return to idle")
        }

        // Verify all interactions were logged
        let logs = getServerLogs()
        let speakingCount = logs.components(separatedBy: "Sent status: speaking").count - 1
        XCTAssertGreaterThanOrEqual(speakingCount, iterations,
                                    "All \(iterations) interactions should be logged")

        // App should still be connected and functional
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should still be connected")
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Should be in idle state")
    }
}
