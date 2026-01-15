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

        // Find and tap test project (Button with label "projectName, path")
        let projectLabelPrefix = testProjectName + ","
        let projectButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", projectLabelPrefix)).firstMatch
        XCTAssertTrue(projectButton.waitForExistence(timeout: 5), "Test project should exist")
        projectButton.tap()

        // Resume existing session
        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist")
        // Use coordinate tap to avoid XCTest idle-wait timeout (SessionView has continuous SwiftUI updates)
        tapByCoordinate(sessionCell)

        // Wait for session sync to complete (voiceState visible)
        XCTAssertTrue(waitForSessionSyncComplete(timeout: 20), "Session sync should complete")

        // Verify tmux is running (waitForSessionSyncComplete already checks this)
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux session should be running")

        // Verify context indicator appears (server broadcasts initial context on session switch)
        let contextIndicator = app.otherElements["contextIndicator"]
        XCTAssertTrue(contextIndicator.waitForExistence(timeout: 10), "Context indicator should appear in session header")

        // Go back - use coordinate tap to avoid idle-wait issues
        let backButton = app.buttons.element(boundBy: 0)
        tapByCoordinate(backButton)
        sleep(2)

        // Start new session
        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        // Use coordinate tap to avoid XCTest idle-wait timeout (SessionView has continuous SwiftUI updates)
        tapByCoordinate(newButton)

        // New session should sync (may take longer as it kills old session first)
        XCTAssertTrue(waitForSessionSyncComplete(timeout: 20), "New session should sync")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux should be running for new session")

        print("✅ Session sync flow passed")
    }

    /// Test switching between sessions
    func test_session_switching() throws {
        // Ensure we start from projects list
        navigateToProjectsList()

        // Find and tap test project (Button with label "projectName, path")
        let projectLabelPrefix = testProjectName + ","
        let projectButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", projectLabelPrefix)).firstMatch
        XCTAssertTrue(projectButton.waitForExistence(timeout: 5), "Test project should exist")
        projectButton.tap()

        // Create a new session first
        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        // Use coordinate tap to avoid XCTest idle-wait timeout (SessionView has continuous SwiftUI updates)
        tapByCoordinate(newButton)

        XCTAssertTrue(waitForSessionSyncComplete(timeout: 20), "New session should sync")

        // Go back to sessions list - use coordinate tap to avoid idle-wait issues
        let backButton = app.buttons.element(boundBy: 0)
        tapByCoordinate(backButton)
        sleep(2)  // Give more time for UI to settle

        // Now there should be multiple sessions - tap another one
        let sessions = app.cells
        // Note: sessions.count may trigger idle wait, but we're back on sessions list now
        XCTAssertTrue(sessions.count >= 2, "Should have at least 2 sessions")

        // Tap the second session (index 1) - this will switch sessions
        // Use coordinate tap to avoid XCTest idle-wait timeout (SessionView has continuous SwiftUI updates)
        tapByCoordinate(sessions.element(boundBy: 1))

        // Session switching needs extra time (kills old tmux, starts new one)
        XCTAssertTrue(waitForSessionSyncComplete(timeout: 25), "Switched session should sync")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux should be running after switch")

        print("✅ Session switching passed")
    }
}
