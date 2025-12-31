//
//  ConnectionTests.swift
//  ClaudeVoiceUITests
//
//  Connection and setup integration tests
//

import XCTest

final class ConnectionTests: IntegrationTestBase {

    // Test 1: Server starts up successfully
    @MainActor
    func testServerStartupAndDiscovery() throws {
        // Server should be running (started manually before tests)
        // Verify server logs contain startup message
        let logs = getServerLogs()
        XCTAssertTrue(logs.contains("Server listening") || logs.contains("READY"), "Server should log startup message")
        XCTAssertTrue(logs.contains("Control server started") || logs.contains("Control server"), "Control server should be started")
    }

    // Test 2: Initial connection flow works
    @MainActor
    func testInitialConnectionFlow() throws {
        // Connect to the test server
        connectToTestServer()

        // Verify we received "Connected" status
        let connectedLabel = app.staticTexts["Connected"]
        XCTAssertTrue(connectedLabel.exists, "Should show Connected status")

        // Verify voice state is idle
        let idleLabel = app.staticTexts["Idle"]
        XCTAssertTrue(idleLabel.exists, "Voice state should be Idle")

        // Verify Talk button is enabled
        XCTAssertTrue(isTalkButtonEnabled(), "Talk button should be enabled when connected")

        // Check server logs
        let logs = getServerLogs()
        XCTAssertTrue(logs.contains("Client connected"), "Server should log client connection")
        XCTAssertTrue(logs.contains("Sent status: idle"), "Server should send idle status")
    }

    // Test 3: Connection with invalid IP shows error
    @MainActor
    func testConnectionWithInvalidIP() throws {
        // Tap settings
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        // Enter invalid IP
        let serverIPField = app.textFields["Server IP Address"]
        XCTAssertTrue(serverIPField.waitForExistence(timeout: 5))
        serverIPField.tap()
        serverIPField.typeText("192.168.999.999")

        // Tap connect
        let connectButton = app.buttons["Connect"]
        connectButton.tap()

        // Wait a moment for connection attempt
        sleep(3)

        // Should show error or disconnected state
        let errorState = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Error' OR label CONTAINS 'Disconnected'")).firstMatch
        XCTAssertTrue(errorState.exists, "Should show error or disconnected state")

        // Close settings
        let doneButton = app.buttons["Done"]
        doneButton.tap()

        // Talk button should be disabled
        XCTAssertFalse(isTalkButtonEnabled(), "Talk button should be disabled when not connected")
    }

    // Test 4: Multiple connection/disconnection cycles
    @MainActor
    func testMultipleConnectionAttempts() throws {
        // First connection
        connectToTestServer()
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should be connected")

        // Disconnect
        disconnectFromServer()
        sleep(1)

        // Verify disconnected
        let disconnectedLabel = app.staticTexts["Disconnected"]
        XCTAssertTrue(disconnectedLabel.waitForExistence(timeout: 5), "Should show disconnected")

        // Reconnect
        connectToTestServer()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5), "Should reconnect successfully")

        // Verify state is reset to idle
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Voice state should be reset to Idle")

        // Do one more cycle
        disconnectFromServer()
        sleep(1)
        XCTAssertTrue(app.staticTexts["Disconnected"].exists, "Should be disconnected again")

        connectToTestServer()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5), "Should reconnect again")
    }
}
