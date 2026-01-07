//
//  E2ESessionFlowTests.swift
//  ClaudeVoiceUITests
//
//  Comprehensive session sync test covering all sync scenarios.
//  IMPORTANT: These tests verify REAL behavior - tmux sessions must actually start.
//

import XCTest

final class E2ESessionFlowTests: E2ETestBase {

    /// Complete session sync flow test
    /// Tests: Connect status -> Session sync -> Tmux verification -> Active indicators -> New session -> Switch sessions
    func test_complete_session_sync_flow() throws {
        // ============================================================
        // PHASE 1: Connection Status on Connect
        // ============================================================
        print("Phase 1: Connection status")

        // After connection (setUp), should be able to see projects
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should see test project")

        // ============================================================
        // PHASE 2: Session Sync Flow
        // ============================================================
        print("Phase 2: Session sync")

        project1.tap()

        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()

        // Should show synced indicator
        let syncedIndicator = app.images["Synced"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "Should show synced indicator")

        // CRITICAL: Verify tmux session is actually running on server
        // This ensures the sync actually started a real tmux session, not just updated UI
        sleep(2)  // Wait for tmux to start
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux session should be running after sync")
        print("✓ Verified: tmux session is running")

        // Talk button should be enabled when synced
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled after sync")

        // ============================================================
        // PHASE 3: Active Session Indicator in List
        // ============================================================
        print("Phase 3: Active session indicator")

        // Go back to sessions list
        app.navigationBars.buttons.firstMatch.tap()

        // The session should show active indicator
        let activeIndicator = app.images["Active session"]
        XCTAssertTrue(activeIndicator.waitForExistence(timeout: 5), "Should show active indicator")

        // ============================================================
        // PHASE 4: Switch Sessions
        // ============================================================
        print("Phase 4: Switch sessions")

        // Tap second session
        let session2 = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2.waitForExistence(timeout: 5))
        session2.tap()

        // Should sync to new session
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "Should sync new session")

        // Verify tmux session is still running (session switch)
        sleep(2)
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux session should still be running after switch")
        print("✓ Verified: tmux session running after session switch")

        // Go back - only session2 should have active indicator
        app.navigationBars.buttons.firstMatch.tap()

        let activeIndicators = app.images.matching(NSPredicate(format: "label == %@", "Active session"))
        XCTAssertEqual(activeIndicators.count, 1, "Only one session should show active indicator")

        // ============================================================
        // PHASE 5: New Session Flow
        // ============================================================
        print("Phase 5: New session")

        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        // New session should sync
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "New session should show synced")

        // Verify tmux session is running for new session
        sleep(2)
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux session should be running for new session")
        print("✓ Verified: tmux session running for new session")

        // Talk button should be enabled
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled for new session")

        print("✅ Complete session sync flow test passed!")
    }
}
