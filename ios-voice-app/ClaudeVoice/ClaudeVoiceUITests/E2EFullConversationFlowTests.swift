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
        // Skip waitForVoiceState - uses UI elements blocked by SwiftUI re-renders
        // navigateToTestSession already verifies session is ready via HTTP

        // PHASE 1: Voice input → real Claude response → TTS
        print("📍 PHASE 1: Basic conversation turn")

        // Ask for one-word response to save tokens
        sendVoiceInput("Reply with only the word yes")
        XCTAssertTrue(verifyInputInTmux("Reply with only the word yes", timeout: 10), "Input should reach tmux")

        // Wait for Claude to process and be ready again (uses HTTP-based tmux check)
        XCTAssertTrue(waitForClaudeReady(timeout: 60), "Claude should be ready after first response")

        sleep(1)

        // PHASE 2: Another turn to verify multi-turn works
        print("📍 PHASE 2: Second conversation turn")

        sendVoiceInput("Reply with only the word no")
        XCTAssertTrue(verifyInputInTmux("Reply with only the word no", timeout: 10), "Second input should reach tmux")

        XCTAssertTrue(waitForClaudeReady(timeout: 60), "Claude should be ready after second response")

        print("✅ Full conversation flow passed")
    }

    /// Permission flow test
    func test_permission_flow() throws {
        navigateToTestSession(resume: true)
        // Skip waitForVoiceState - navigateToTestSession already verifies session is ready

        // Inject permission request (simulates hook POST to server)
        let _ = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "echo test"
        )

        // Permission card should appear inline
        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Approve
        app.buttons["permissionOption1"].tap()  // "Yes"
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")

        print("✅ Permission flow works")
    }

    /// Resume existing session
    func test_resume_session() throws {
        // Ensure we start from projects list
        navigateToProjectsList()

        // Find and tap test project (Button with label "projectName, path")
        let projectLabelPrefix = testProjectName + ","
        let projectButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", projectLabelPrefix)).firstMatch
        XCTAssertTrue(projectButton.waitForExistence(timeout: 5), "Project should exist")
        projectButton.tap()

        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist")
        // Use coordinate tap to avoid XCTest idle-wait timeout (SessionView has continuous SwiftUI updates)
        tapByCoordinate(sessionCell)

        XCTAssertTrue(waitForSessionSyncComplete(timeout: 15), "Session should sync")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux should be running")

        // Verify we can send input
        sendVoiceInput("Reply with ok")
        XCTAssertTrue(verifyInputInTmux("Reply with ok", timeout: 10), "Input should reach tmux")

        print("✅ Resume session works")
    }
}
