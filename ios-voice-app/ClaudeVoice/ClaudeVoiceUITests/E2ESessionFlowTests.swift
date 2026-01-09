//
//  E2ESessionFlowTests.swift
//  ClaudeVoiceUITests
//
//  Tests real session sync flow with actual tmux sessions.
//

import XCTest

final class E2ESessionFlowTests: E2ETestBase {

    /// Complete session sync flow
    func test_session_sync_flow() throws {
        // Ensure we start from projects list
        navigateToProjectsList()

        // Find and tap test project
        let project = app.staticTexts[testProjectName]
        XCTAssertTrue(project.waitForExistence(timeout: 5), "Test project should exist")
        project.tap()

        // Resume existing session
        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist")
        sessionCell.tap()

        // Wait for session sync to complete (voiceState visible)
        XCTAssertTrue(waitForSessionSyncComplete(timeout: 20), "Session sync should complete")

        // Verify tmux is running
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux session should be running")

        // Talk button should be enabled
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled")

        // Go back
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)

        // Start new session
        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        // New session should sync (may take longer as it kills old session first)
        XCTAssertTrue(waitForSessionSyncComplete(timeout: 20), "New session should sync")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux should be running for new session")

        print("✅ Session sync flow passed")
    }

    /// Test switching between sessions
    func test_session_switching() throws {
        // Ensure we start from projects list
        navigateToProjectsList()

        let project = app.staticTexts[testProjectName]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()

        // Create a new session first
        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        XCTAssertTrue(waitForSessionSyncComplete(timeout: 20), "New session should sync")

        // Go back to sessions list
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)  // Give more time for UI to settle

        // Now there should be multiple sessions - tap another one
        let sessions = app.cells
        XCTAssertTrue(sessions.count >= 2, "Should have at least 2 sessions")

        // Tap the second session (index 1) - this will switch sessions
        sessions.element(boundBy: 1).tap()

        // Session switching needs extra time (kills old tmux, starts new one)
        XCTAssertTrue(waitForSessionSyncComplete(timeout: 25), "Switched session should sync")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux should be running after switch")

        print("✅ Session switching passed")
    }
}
