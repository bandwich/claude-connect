//
//  E2EConnectionTests.swift
//  ClaudeVoiceUITests
//
//  Connection and reconnection E2E tests
//

import XCTest

final class E2EConnectionTests: E2ETestBase {

    @MainActor
    func test_initial_connection_to_real_server() throws {
        // Already connected in setUp, just verify state
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should show Connected")
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Should be in Idle state")

        // Verify talk button is enabled
        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        XCTAssertTrue(talkButton.exists, "Talk button should exist")
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled")
    }

    @MainActor
    func test_reconnection_after_disconnect() throws {
        // Verify connected
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should be connected")

        // Disconnect
        disconnectFromServer()
        XCTAssertTrue(waitForConnectionState("Disconnected", timeout: 5), "Should show disconnected")

        // Reconnect
        connectToServer()
        XCTAssertTrue(waitForConnectionState("Connected", timeout: 10), "Should reconnect")

        // Verify clean state
        XCTAssertTrue(app.staticTexts["Idle"].exists, "Should be in idle state")

        // Verify functionality works after reconnect
        injectAssistantResponse("Test after reconnect")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should work after reconnect")
    }

    @MainActor
    func test_connection_failure_handling() throws {
        // Note: This test requires manually stopping the server
        // For now, we test that disconnection works properly

        // Verify connected
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Should be connected")

        // Disconnect
        disconnectFromServer()
        XCTAssertTrue(waitForConnectionState("Disconnected", timeout: 5), "Should show disconnected")

        // Verify talk button is disabled when disconnected
        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        if talkButton.exists {
            XCTAssertFalse(talkButton.isEnabled, "Talk button should be disabled when disconnected")
        }

        // Reconnect to restore state for other tests
        connectToServer()
        XCTAssertTrue(waitForConnectionState("Connected", timeout: 10), "Should reconnect")
    }
}
