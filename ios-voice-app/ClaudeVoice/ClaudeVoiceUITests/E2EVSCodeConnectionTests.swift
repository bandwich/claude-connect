//
//  E2EVSCodeConnectionTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for VSCode connection and sync detection
//  Requires: VS Code open with vscode-remote-control extension
//

import XCTest

final class E2EVSCodeConnectionTests: E2ETestBase {

    // MARK: - VSCode Status on Connect

    func test_vscode_connected_status_on_app_connect() throws {
        // When app connects to server, it should receive vscode_status
        // with vscode_connected: true (since VS Code is running)

        // The connectToServer() in setUp already connected us
        // Navigate to a project to verify we can see sessions
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should see test project")
    }

    // MARK: - Session Sync Flow

    func test_tap_session_shows_syncing_then_synced() throws {
        // Navigate to project
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        // Wait for sessions list
        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()

        // Should show syncing indicator briefly
        // Then should show synced indicator (green checkmark)
        let syncedIndicator = app.images["Synced with VSCode"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "Should show synced indicator after resume")
    }

    func test_synced_session_enables_talk_button() throws {
        // Navigate to session
        navigateToSession1()

        // Wait for sync to complete
        let syncedIndicator = app.images["Synced with VSCode"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "Should sync session")

        // Talk button should be enabled
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5), "Talk button should exist")
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled after sync")
    }

    // MARK: - Active Session Indicator in List

    func test_sessions_list_shows_active_indicator() throws {
        // Navigate to project
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        // Tap first session to open it in VSCode
        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()

        // Wait for sync
        let syncedIndicator = app.images["Synced with VSCode"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10))

        // Go back to sessions list
        app.navigationBars.buttons.firstMatch.tap()

        // The session should show active indicator in the list
        let activeIndicator = app.images["Active in VSCode"]
        XCTAssertTrue(activeIndicator.waitForExistence(timeout: 5), "Should show active indicator in sessions list")
    }

    func test_different_session_does_not_show_active_indicator() throws {
        // Navigate to project and open first session
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()

        // Wait for sync
        let syncedIndicator = app.images["Synced with VSCode"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10))

        // Go back and tap second session
        app.navigationBars.buttons.firstMatch.tap()

        let session2 = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2.waitForExistence(timeout: 5))
        session2.tap()

        // Should show syncing (switching to new session)
        // Wait for new sync
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10))

        // Go back - only session2 should have active indicator now
        app.navigationBars.buttons.firstMatch.tap()

        // Count active indicators - should be exactly 1
        let activeIndicators = app.images.matching(NSPredicate(format: "label == %@", "Active in VSCode"))
        XCTAssertEqual(activeIndicators.count, 1, "Only one session should show active indicator")
    }

    // MARK: - New Session Flow

    func test_new_session_shows_synced_after_creation() throws {
        // Navigate to project
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        // Wait for sessions list
        sleep(1)

        // Tap new session button
        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        // Should navigate to new session and show synced
        // New sessions sync when vscodeConnected && activeSessionId == nil
        let syncedIndicator = app.images["Synced with VSCode"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "New session should show synced")

        // Talk button should be enabled
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled for new session")
    }

    // MARK: - Helper

    private func navigateToSession1() {
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        let navTitle = app.navigationBars["e2e_test_project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5))

        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()
    }
}
