//
//  E2EPermissionTests.swift
//  ClaudeConnectUITests
//
//  Tier 1 E2E tests for inline permission card UI.
//

import XCTest

final class E2EPermissionTests: E2ETestBase {

    /// Bash permission card appears with correct content
    func test_bash_permission_card() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "bash", toolName: "Bash", command: "npm install express"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")
        XCTAssertTrue(app.staticTexts["Bash command"].exists, "Should show 'Bash command' label")
        XCTAssertTrue(app.staticTexts["npm install express"].waitForExistence(timeout: 2), "Should show command")

        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")
    }

    /// Permission deny works
    func test_permission_deny() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "bash", toolName: "Bash", command: "rm -rf /"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5))
        // Without suggestions: Yes (1) and No (2)
        app.buttons["permissionOption2"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse after deny")
    }

    /// Edit permission shows file path
    func test_edit_permission_card() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "edit", toolName: "Edit",
            filePath: "src/utils.ts", oldContent: "const foo = 1;", newContent: "const foo = 2;"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5))
        XCTAssertTrue(app.staticTexts["Edit file"].exists, "Should show 'Edit file' label")
        XCTAssertTrue(app.staticTexts["src/utils.ts"].waitForExistence(timeout: 2), "Should show file path")

        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3))
    }

    /// Permission with suggestion shows extra option
    func test_permission_with_suggestion() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "bash", toolName: "Bash", command: "npm install express",
            permissionSuggestions: [[
                "type": "addRules",
                "rules": [["toolName": "Bash", "ruleContent": "npm install:*"]],
                "behavior": "allow", "destination": "localSettings"
            ]]
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5))
        XCTAssertTrue(app.buttons["permissionOption1"].exists, "Yes should exist")
        XCTAssertTrue(app.buttons["permissionOption2"].exists, "Always-allow should exist")
        XCTAssertTrue(app.buttons["permissionOption3"].exists, "No should exist")

        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3))
    }
}
