//
//  E2EPermissionTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for permission prompt UI
//  Tests are consolidated to minimize navigation overhead
//

import XCTest

final class E2EPermissionTests: E2ETestBase {

    // MARK: - Bash Permission Tests (Consolidated)

    /// Tests bash permission flow: display, Allow action, and Deny action
    /// Consolidated to avoid repeated navigation to session view
    func test_bash_permission_complete_flow() throws {
        // Navigate once for all bash tests
        navigateToTestSession()

        // --- Test 1: Verify bash permission UI elements ---
        var requestId = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "npm install express"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear")

        // Verify Command title
        XCTAssertTrue(app.navigationBars["Command"].exists, "Should show Command title")

        // Verify command text is displayed
        let commandText = app.staticTexts["npm install express"]
        XCTAssertTrue(commandText.waitForExistence(timeout: 2), "Should show command text")

        // Verify both buttons exist
        XCTAssertTrue(app.buttons["Allow"].exists, "Allow button should exist")
        XCTAssertTrue(app.buttons["Deny"].exists, "Deny button should exist")

        // --- Test 2: Verify Allow dismisses sheet ---
        app.buttons["Allow"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after Allow")

        // --- Test 3: Verify Deny dismisses sheet ---
        // Inject another permission request
        requestId = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "rm -rf /"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear again")
        app.buttons["Deny"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after Deny")
    }
}
