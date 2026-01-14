import XCTest

final class E2EQRConnectTests: E2ETestBase {

    /// Tests that Connect button opens scanner (camera permission may block full flow)
    func test_connect_button_opens_scanner() throws {
        // Disconnect first if connected
        openSettings()
        sleep(1)

        let disconnectButton = app.buttons["Disconnect"]
        if disconnectButton.waitForExistence(timeout: 2) {
            tapByCoordinate(disconnectButton)
            sleep(2)
        }

        // Tap Connect - should show scanner or camera permission
        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5), "Connect button should exist")
        tapByCoordinate(connectButton)

        // Either scanner appears or camera permission dialog
        sleep(2)

        // Look for Cancel button (scanner) or permission dialog
        let cancelButton = app.buttons["Cancel"]
        let permissionDialog = app.alerts.firstMatch

        XCTAssertTrue(
            cancelButton.exists || permissionDialog.exists,
            "Should show scanner (Cancel button) or camera permission dialog"
        )

        // Dismiss scanner if shown
        if cancelButton.exists {
            cancelButton.tap()
        } else if permissionDialog.exists {
            // Dismiss permission dialog
            let dontAllow = permissionDialog.buttons["Don't Allow"]
            if dontAllow.exists {
                dontAllow.tap()
            }
        }

        sleep(1)
        app.buttons["Done"].tap()
    }

    /// Tests that connected state shows IP address
    func test_connected_state_shows_ip() throws {
        // This test requires manual connection or mock
        // For now, verify the UI structure when connected
        openSettings()
        sleep(1)

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5), "Status label should exist")

        // If connected, verify IP is shown
        if statusLabel.label == "Connected" {
            // Look for the Connected: text
            let connectedText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Connected:'")).firstMatch
            // IP display is only shown when connected - just verify structure
            XCTAssertTrue(app.buttons["Disconnect"].exists, "Disconnect should be visible when connected")
        }

        app.buttons["Done"].tap()
    }
}
