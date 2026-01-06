//
//  E2EVSCodeFlowTests.swift
//  ClaudeVoiceUITests
//
//  Comprehensive VSCode sync test covering all sync scenarios
//  Replaces: E2EVSCodeConnectionTests (5 separate tests)
//

import XCTest

final class E2EVSCodeFlowTests: E2ETestBase {

    /// Complete VSCode sync flow test
    /// Tests: Connect status → Session sync → Active indicators → New session → Switch sessions
    func test_complete_vscode_sync_flow() throws {
        // ============================================================
        // PHASE 1: VSCode Status on Connect
        // ============================================================
        print("📍 PHASE 1: VSCode connection status")

        // After connection (setUp), should be able to see projects
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should see test project")

        // ============================================================
        // PHASE 2: Session Sync Flow
        // ============================================================
        print("📍 PHASE 2: Session sync")

        project1.tap()

        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()

        // Should show synced indicator
        let syncedIndicator = app.images["Synced with VSCode"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "Should show synced indicator")

        // Talk button should be enabled when synced
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled after sync")

        // ============================================================
        // PHASE 3: Active Session Indicator in List
        // ============================================================
        print("📍 PHASE 3: Active session indicator")

        // Go back to sessions list
        app.navigationBars.buttons.firstMatch.tap()

        // The session should show active indicator
        let activeIndicator = app.images["Active in VSCode"]
        XCTAssertTrue(activeIndicator.waitForExistence(timeout: 5), "Should show active indicator")

        // ============================================================
        // PHASE 4: Switch Sessions
        // ============================================================
        print("📍 PHASE 4: Switch sessions")

        // Tap second session
        let session2 = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2.waitForExistence(timeout: 5))
        session2.tap()

        // Should sync to new session
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "Should sync new session")

        // Go back - only session2 should have active indicator
        app.navigationBars.buttons.firstMatch.tap()

        let activeIndicators = app.images.matching(NSPredicate(format: "label == %@", "Active in VSCode"))
        XCTAssertEqual(activeIndicators.count, 1, "Only one session should show active indicator")

        // ============================================================
        // PHASE 5: New Session Flow
        // ============================================================
        print("📍 PHASE 5: New session")

        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        // New session should sync
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "New session should show synced")

        // Talk button should be enabled
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled for new session")

        print("✅ Complete VSCode sync flow test passed!")
    }
}
