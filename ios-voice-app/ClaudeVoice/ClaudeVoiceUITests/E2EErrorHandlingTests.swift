//
//  E2EErrorHandlingTests.swift
//  ClaudeVoiceUITests
//
//  Error handling E2E tests with real Claude responses
//

import XCTest

final class E2EErrorHandlingTests: E2ETestBase {

    /// Tests error handling with real flows
    func test_error_handling() throws {
        navigateToTestSession(resume: true)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should start in Idle")

        // Test 1: Normal conversation works
        sendVoiceInput("Reply with only ok")
        XCTAssertTrue(verifyInputInTmux("Reply with only ok", timeout: 10), "Input should reach tmux")
        XCTAssertTrue(waitForResponseCycle(timeout: 60), "Response cycle should complete")

        // Test 2: Empty input handling
        sendVoiceInput("")
        sleep(2)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should remain Idle after empty input")

        // Test 3: App still functional after edge case
        sendVoiceInput("Reply with only yes")
        XCTAssertTrue(verifyInputInTmux("Reply with only yes", timeout: 10), "Input should still work")
        XCTAssertTrue(waitForResponseCycle(timeout: 60), "Response cycle should still complete")

        print("✅ Error handling test passed")
    }
}
