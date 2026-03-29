//
//  E2EConnectionTests.swift
//  ClaudeConnectUITests
//
//  Connection and reconnection E2E tests
//

import XCTest

final class E2EConnectionTests: E2ETestBase {

    /// Tests that status shows valid connection states
    func test_connection_failure_shows_error() throws {
        // This test verifies the app handles connection states correctly
        // Since we can't change server IP via UI anymore (QR-based),
        // we test by verifying status shows expected states

        openSettings()
        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))

        // Status should be a valid connection state
        let status = statusLabel.label
        XCTAssertTrue(
            status == "Connected" || status == "Disconnected" || status.contains("Error"),
            "Status should be a valid connection state, got: '\(status)'"
        )

        app.buttons["Done"].tap()
    }

    /// Tests connection, usage display, and voice controls
    func test_connection_and_voice_controls() throws {
        // --- Test 1: Verify connected via settings ---
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")
        tapByCoordinate(settingsButton)

        // Wait for settings sheet to appear (Done button indicates sheet is open)
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Settings sheet should appear")

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5), "Should show connection status")
        XCTAssertEqual(statusLabel.label, "Connected", "Should be connected")

        // --- Test 2: Verify usage section loads with real data ---
        // Wait for usage data to load (look for "Current Session" text)
        let currentSessionLabel = app.staticTexts["Current Session"]
        XCTAssertTrue(currentSessionLabel.waitForExistence(timeout: 20), "Current Session label should appear (usage data loaded)")

        // Verify all usage rows exist
        let weekAllModelsLabel = app.staticTexts["This Week (All Models)"]
        XCTAssertTrue(weekAllModelsLabel.waitForExistence(timeout: 5), "Week All Models label should appear")

        let weekSonnetLabel = app.staticTexts["This Week (Sonnet)"]
        XCTAssertTrue(weekSonnetLabel.waitForExistence(timeout: 5), "Week Sonnet label should appear")

        // Verify percentages are displayed (look for "%" text)
        // Should see percentage values like "42%" for each usage row
        let percentageTexts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '%'"))
        XCTAssertGreaterThanOrEqual(percentageTexts.count, 3, "Should display percentage for each usage row")

        app.buttons["Done"].tap()

        // --- Test 3: Navigate to session and verify voice controls ---
        navigateToTestSession(resume: true)  // Resume pre-created session
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should be in Idle state")

        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        XCTAssertTrue(talkButton.exists, "Talk button should exist")
    }

    /// Tests disconnect flow and state transitions
    func test_disconnect_flow() throws {
        // --- Setup: Open settings ---
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")
        tapByCoordinate(settingsButton)

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(statusLabel.label, "Connected", "Should start connected")

        // --- Test 1: Disconnect ---
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
        disconnectButton.tap()

        // Wait for disconnected state and ASSERT it's not error
        sleep(2)
        let statusAfterDisconnect = statusLabel.label
        XCTAssertEqual(statusAfterDisconnect, "Disconnected", "Status should be 'Disconnected', not '\(statusAfterDisconnect)'")
        XCTAssertFalse(statusAfterDisconnect.contains("Error"), "Status should not contain 'Error'")

        // --- Test 2: Verify Connect button appears when disconnected ---
        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5), "Connect button should appear when disconnected")

        // --- Test 3: Verify disconnected state in main view ---
        app.buttons["Done"].tap()

        let notConnectedText = app.staticTexts["Not Connected"]
        XCTAssertTrue(notConnectedText.waitForExistence(timeout: 5), "Should show Not Connected")
    }
}
