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
        // Find and tap test project
        let project = app.staticTexts[testProjectName]
        XCTAssertTrue(project.waitForExistence(timeout: 5), "Test project should exist")
        project.tap()

        // Resume existing session
        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist")
        sessionCell.tap()

        // Should sync and show synced indicator
        let syncedIndicator = app.images["Synced"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 15), "Should show synced indicator")

        // Verify tmux is running
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux session should be running")

        // Talk button should be enabled
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled")

        // Go back and verify active indicator
        app.navigationBars.buttons.firstMatch.tap()
        let activeIndicator = app.images["Active session"]
        XCTAssertTrue(activeIndicator.waitForExistence(timeout: 5), "Should show active indicator")

        // Start new session
        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        // New session should sync
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 15), "New session should sync")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux should be running for new session")

        print("✅ Session sync flow passed")
    }

    /// Test switching between sessions
    func test_session_switching() throws {
        let project = app.staticTexts[testProjectName]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()

        // Create a new session first
        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        XCTAssertTrue(waitForSessionSyncComplete(timeout: 15), "New session should sync")

        // Go back
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)

        // Now there should be multiple sessions - tap another one
        let sessions = app.cells
        XCTAssertTrue(sessions.count >= 2, "Should have at least 2 sessions")

        // Tap the second session (index 1)
        sessions.element(boundBy: 1).tap()

        XCTAssertTrue(waitForSessionSyncComplete(timeout: 15), "Switched session should sync")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux should be running after switch")

        print("✅ Session switching passed")
    }
}
