//
//  E2EConnectionTests.swift
//  ClaudeVoiceUITests
//
//  Connection and reconnection E2E tests
//

import XCTest

final class E2EConnectionTests: E2ETestBase {

    /// Tests connection and voice controls
    func test_connection_and_voice_controls() throws {
        // --- Test 1: Verify connected via settings ---
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")
        settingsButton.tap()

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5), "Should show connection status")
        XCTAssertEqual(statusLabel.label, "Connected", "Should be connected")

        app.buttons["Done"].tap()

        // --- Test 2: Navigate to session and verify voice controls ---
        navigateToTestSession()
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in Idle state")

        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        XCTAssertTrue(talkButton.exists, "Talk button should exist")
    }

    /// Tests disconnect, reconnect, and disconnect handling
    func test_reconnection_flow() throws {
        // --- Setup: Open settings ---
        let settingsButton = app.buttons["gearshape.fill"]
        settingsButton.tap()

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(statusLabel.label, "Connected", "Should start connected")

        // --- Test 1: Disconnect ---
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
        disconnectButton.tap()

        let disconnectPredicate = NSPredicate(format: "label == %@", "Disconnected")
        let disconnectExpectation = XCTNSPredicateExpectation(predicate: disconnectPredicate, object: statusLabel)
        XCTWaiter().wait(for: [disconnectExpectation], timeout: 5)

        // --- Test 2: Verify disconnected state in main view ---
        app.buttons["Done"].tap()

        let notConnectedText = app.staticTexts["Not Connected"]
        XCTAssertTrue(notConnectedText.waitForExistence(timeout: 5), "Should show Not Connected")

        // --- Test 3: Reconnect ---
        settingsButton.tap()

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
