//
//  E2EConnectionTests.swift
//  ClaudeVoiceUITests
//
//  Connection and reconnection E2E tests
//

import XCTest

final class E2EConnectionTests: E2ETestBase {

    /// Tests that connection failure to unreachable host shows error state
    func test_connection_failure_shows_error() throws {
        // --- Setup: Open settings and disconnect if connected ---
        openSettings()
        sleep(1)

        // Disconnect if we're connected
        let disconnectButton = app.buttons["Disconnect"]
        if disconnectButton.exists {
            disconnectButton.tap()
            sleep(2)
        }

        // --- Test: Try to connect to unreachable IP ---
        let serverIPField = app.textFields["Server IP Address"]
        XCTAssertTrue(serverIPField.waitForExistence(timeout: 5), "IP field should exist")
        serverIPField.tap()
        sleep(1)

        // Clear existing text and enter unreachable IP
        serverIPField.press(forDuration: 1.0)  // Long press to select all
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
        }
        serverIPField.typeText("10.255.255.1")

        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 3), "Connect button should exist")
        connectButton.tap()

        // --- Verify: Should show error state (not stuck on Connecting) ---
        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5), "Status label should exist")

        // Wait for either error or connection failure - should NOT stay on "Connecting..." forever
        let errorPredicate = NSPredicate(format: "label CONTAINS[c] 'error' OR label CONTAINS[c] 'failed' OR label == 'Disconnected'")
        let errorExpectation = XCTNSPredicateExpectation(predicate: errorPredicate, object: statusLabel)
        let result = XCTWaiter().wait(for: [errorExpectation], timeout: 15)

        // If still "Connecting..." after 15 seconds, that's the bug
        if result != .completed {
            let currentStatus = statusLabel.label
            XCTFail("Connection should fail with error, but status is: '\(currentStatus)'")
        }

        // --- Verify: Connect button should be available again ---
        XCTAssertTrue(connectButton.waitForExistence(timeout: 3), "Connect button should reappear after failure")
        XCTAssertTrue(connectButton.isEnabled, "Connect button should be enabled after failure")

        // --- Cleanup: Restore valid IP for subsequent tests ---
        serverIPField.tap()
        sleep(1)
        serverIPField.press(forDuration: 1.0)
        let selectAllCleanup = app.menuItems["Select All"]
        if selectAllCleanup.waitForExistence(timeout: 2) {
            selectAllCleanup.tap()
        }
        serverIPField.typeText(testServerHost)
        connectButton.tap()

        let reconnectPredicate = NSPredicate(format: "label == %@", "Connected")
        let reconnectExpectation = XCTNSPredicateExpectation(predicate: reconnectPredicate, object: statusLabel)
        XCTWaiter().wait(for: [reconnectExpectation], timeout: 10)

        app.buttons["Done"].tap()
    }

    /// Tests connection and voice controls
    func test_connection_and_voice_controls() throws {
        // --- Test 1: Verify connected via settings ---
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")
        tapByCoordinate(settingsButton)

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5), "Should show connection status")
        XCTAssertEqual(statusLabel.label, "Connected", "Should be connected")

        app.buttons["Done"].tap()

        // --- Test 2: Navigate to session and verify voice controls ---
        navigateToTestSession(resume: true)  // Resume pre-created session
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should be in Idle state")

        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        XCTAssertTrue(talkButton.exists, "Talk button should exist")
    }

    /// Tests disconnect, reconnect, and disconnect handling
    func test_reconnection_flow() throws {
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

        // --- Test 2: Verify disconnected state in main view ---
        app.buttons["Done"].tap()

        let notConnectedText = app.staticTexts["Not Connected"]
        XCTAssertTrue(notConnectedText.waitForExistence(timeout: 5), "Should show Not Connected")

        // --- Test 3: Reconnect ---
        tapByCoordinate(settingsButton)

        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.tap()

        let reconnectPredicate = NSPredicate(format: "label == %@", "Connected")
        let reconnectExpectation = XCTNSPredicateExpectation(predicate: reconnectPredicate, object: statusLabel)
        let result = XCTWaiter().wait(for: [reconnectExpectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Should reconnect")

        app.buttons["Done"].tap()

        // --- Test 4: Verify voice works after reconnect ---
        navigateToTestSession(resume: true)  // Resume existing session to use watched transcript
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in idle state")

        // Send voice input - real Claude responds, wait for full cycle to complete
        sendVoiceInput("Reply with only the word ok")
        XCTAssertTrue(verifyInputInTmux("Reply with only the word ok", timeout: 10), "Input should reach tmux")
        XCTAssertTrue(waitForResponseCycle(timeout: 60), "Response cycle should complete after reconnect")
    }
}
