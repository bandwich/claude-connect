//
//  E2EFullConversationFlowTests.swift
//  ClaudeVoiceUITests
//
//  Comprehensive E2E test with REAL Claude responses.
//  Uses one-word response prompts to minimize token usage.
//

import XCTest

final class E2EFullConversationFlowTests: E2ETestBase {

    /// Full conversation flow with real Claude responses
    func test_complete_conversation_flow() throws {
        navigateToTestSession(resume: true)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should start in Idle")

        // PHASE 1: Voice input → real Claude response → TTS
        print("📍 PHASE 1: Basic conversation turn")

        // Ask for one-word response to save tokens
        sendVoiceInput("Reply with only the word yes")
        XCTAssertTrue(verifyInputInTmux("Reply with only the word yes", timeout: 10), "Input should reach tmux")

        // Wait for real Claude response and TTS to complete
        XCTAssertTrue(waitForResponseCycle(timeout: 60), "First response cycle should complete")

        sleep(1)

        // PHASE 2: Another turn to verify multi-turn works
        print("📍 PHASE 2: Second conversation turn")

        sendVoiceInput("Reply with only the word no")
        XCTAssertTrue(verifyInputInTmux("Reply with only the word no", timeout: 10), "Second input should reach tmux")

        XCTAssertTrue(waitForResponseCycle(timeout: 60), "Second response cycle should complete")

        print("✅ Full conversation flow passed")
    }

    /// Permission flow test
    func test_permission_flow() throws {
        navigateToTestSession(resume: true)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should be Idle")

        // Inject permission request (simulates hook POST to server)
        let _ = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "echo test"
        )

        // Permission sheet should appear
        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear")
        XCTAssertTrue(app.navigationBars["Command"].exists, "Should show Command title")

        // Approve
        app.buttons["Allow"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss")

        print("✅ Permission flow works")
    }

    /// Resume existing session
    func test_resume_session() throws {
        let project = app.staticTexts[testProjectName]
        XCTAssertTrue(project.waitForExistence(timeout: 5), "Project should exist")
        project.tap()

        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist")
        sessionCell.tap()

        XCTAssertTrue(waitForSessionSyncComplete(timeout: 15), "Session should sync")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux should be running")

        // Verify we can send input
        sendVoiceInput("Reply with ok")
        XCTAssertTrue(verifyInputInTmux("Reply with ok", timeout: 10), "Input should reach tmux")

        print("✅ Resume session works")
    }
}
