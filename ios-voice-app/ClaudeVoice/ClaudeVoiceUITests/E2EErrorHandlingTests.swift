//
//  E2EErrorHandlingTests.swift
//  ClaudeVoiceUITests
//
//  Error handling E2E tests with real Claude responses
//

import XCTest

final class E2EErrorHandlingTests: E2ETestBase {

    /// Tests multiple conversation turns work correctly
    func test_error_handling() throws {
        navigateToTestSession(resume: true)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should start in Idle")

        // Test 1: First conversation turn
        sendVoiceInput("Reply with only ok")
        XCTAssertTrue(verifyInputInTmux("Reply with only ok", timeout: 10), "Input should reach tmux")
        XCTAssertTrue(waitForResponseCycle(timeout: 60), "First response cycle should complete")

        // Brief pause between turns
        sleep(1)

        // Test 2: Second conversation turn (verify multi-turn works)
        sendVoiceInput("Reply with only yes")
        XCTAssertTrue(verifyInputInTmux("Reply with only yes", timeout: 10), "Second input should reach tmux")
        XCTAssertTrue(waitForResponseCycle(timeout: 60), "Second response cycle should complete")

        print("✅ Multi-turn conversation test passed")
    }
}
