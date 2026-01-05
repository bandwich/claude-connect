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

    // MARK: - Edit Permission Tests (Consolidated)

    /// Tests edit permission flow: DiffView display, file path, Approve action
    func test_edit_permission_complete_flow() throws {
        navigateToTestSession()

        // --- Test 1: Verify edit permission shows DiffView ---
        let _ = injectPermissionRequest(
            promptType: "edit",
            toolName: "Edit",
            filePath: "src/utils.ts",
            oldContent: "const foo = 1;\nconst bar = 2;",
            newContent: "const foo = 2;\nconst bar = 2;\nconst baz = 3;"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear")

        // Verify Edit title
        XCTAssertTrue(app.navigationBars["Edit"].exists, "Should show Edit title")

        // Verify file path is shown
        let filePath = app.staticTexts["src/utils.ts"]
        XCTAssertTrue(filePath.waitForExistence(timeout: 2), "Should show file path")

        // Verify diff content is visible (look for the actual content)
        // DiffView shows lines with +/- prefixes
        let hasContent = app.staticTexts["const foo = 1;"].exists ||
                        app.staticTexts["const foo = 2;"].exists ||
                        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'foo'")).count > 0
        XCTAssertTrue(hasContent, "Should show diff content")

        // Verify Approve and Reject buttons
        XCTAssertTrue(app.buttons["Approve"].exists, "Approve button should exist")
        XCTAssertTrue(app.buttons["Reject"].exists, "Reject button should exist")

        // --- Test 2: Verify Approve dismisses sheet ---
        app.buttons["Approve"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after Approve")

        // --- Test 3: Verify Reject dismisses sheet ---
        let _ = injectPermissionRequest(
            promptType: "edit",
            toolName: "Edit",
            filePath: "test.ts",
            oldContent: "old",
            newContent: "new"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear again")
        app.buttons["Reject"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after Reject")
    }
}
