//
//  E2EConnectionTests.swift
//  ClaudeVoiceUITests
//
//  Connection and reconnection E2E tests
//

import XCTest

final class E2EConnectionTests: E2ETestBase {

    func test_initial_connection_to_real_server() throws {
        // Connection is established in setUp, verify via settings
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")
        settingsButton.tap()

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5), "Should show connection status")
        XCTAssertEqual(statusLabel.label, "Connected", "Should be connected")

        app.buttons["Done"].tap()

        // Navigate to session and verify voice controls work
        navigateToTestSession()
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in Idle state")

        // Verify talk button exists
        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        XCTAssertTrue(talkButton.exists, "Talk button should exist")
    }

    func test_reconnection_after_disconnect() throws {
        // Verify connected via settings
        let settingsButton = app.buttons["gearshape.fill"]
        settingsButton.tap()

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(statusLabel.label, "Connected", "Should be connected")

        // Disconnect
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
        disconnectButton.tap()

        // Wait for disconnection
        let predicate = NSPredicate(format: "label == %@", "Disconnected")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: statusLabel)
        XCTWaiter().wait(for: [expectation], timeout: 5)

        // Reconnect
        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.tap()

        // Wait for reconnection
        let reconnectPredicate = NSPredicate(format: "label == %@", "Connected")
        let reconnectExpectation = XCTNSPredicateExpectation(predicate: reconnectPredicate, object: statusLabel)
        let result = XCTWaiter().wait(for: [reconnectExpectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Should reconnect")

        app.buttons["Done"].tap()

        // Navigate to session and verify voice works after reconnect
        navigateToTestSession()
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in idle state")

        simulateConversationTurn(userInput: "Test", assistantResponse: "Test after reconnect")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should work after reconnect")
    }

    func test_connection_failure_handling() throws {
        // Open settings to check status
        let settingsButton = app.buttons["gearshape.fill"]
        settingsButton.tap()

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(statusLabel.label, "Connected", "Should be connected")

        // Disconnect
        let disconnectButton = app.buttons["Disconnect"]
        disconnectButton.tap()

        // Wait for disconnection
        let predicate = NSPredicate(format: "label == %@", "Disconnected")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: statusLabel)
        XCTWaiter().wait(for: [expectation], timeout: 5)

        app.buttons["Done"].tap()

        // When disconnected, main view should show "Not Connected"
        let notConnectedText = app.staticTexts["Not Connected"]
        XCTAssertTrue(notConnectedText.waitForExistence(timeout: 5), "Should show Not Connected")

        // Reconnect via settings for other tests
        settingsButton.tap()
        let connectButton = app.buttons["Connect"]
        connectButton.tap()

        let reconnectPredicate = NSPredicate(format: "label == %@", "Connected")
        let reconnectExpectation = XCTNSPredicateExpectation(predicate: reconnectPredicate, object: statusLabel)
        XCTWaiter().wait(for: [reconnectExpectation], timeout: 10)

        app.buttons["Done"].tap()
    }
}
