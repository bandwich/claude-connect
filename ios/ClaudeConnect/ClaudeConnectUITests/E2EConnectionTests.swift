//
//  E2EConnectionTests.swift
//  ClaudeConnectUITests
//
//  Tier 1 E2E tests for connection lifecycle using test server.
//

import XCTest

final class E2EConnectionTests: E2ETestBase {

    /// App connects to test server and shows projects
    func test_connects_and_shows_projects() throws {
        // App auto-connects in setUp, test server returns mock projects
        let anyProjectCell = app.cells.firstMatch
        XCTAssertTrue(anyProjectCell.waitForExistence(timeout: 10), "Should show project list after connect")
    }

    /// Settings shows Connected status
    func test_settings_shows_connected() throws {
        openSettings()
        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(statusLabel.label, "Connected")
        app.buttons["Done"].tap()
    }

    /// Disconnect flow shows correct states
    func test_disconnect_flow() throws {
        openSettings()
        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertEqual(statusLabel.label, "Connected")

        // Disconnect
        app.buttons["Disconnect"].tap()
        sleep(2)
        XCTAssertEqual(statusLabel.label, "Disconnected")

        // Connect button appears
        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))

        app.buttons["Done"].tap()

        // Main view shows Not Connected
        let notConnectedText = app.staticTexts["Not Connected"]
        XCTAssertTrue(notConnectedText.waitForExistence(timeout: 5))
    }
}
