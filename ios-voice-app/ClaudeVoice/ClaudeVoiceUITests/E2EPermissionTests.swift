//
//  E2EPermissionTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for inline permission card UI
//  Tests are consolidated to minimize navigation overhead
//

import XCTest

final class E2EPermissionTests: E2ETestBase {

    // MARK: - Bash Permission Tests

    /// Tests bash permission inline card: display, allow with suggestions, deny
    func test_bash_permission_inline_card() throws {
        navigateToTestSession()

        // Inject bash permission with a suggestion
        let _ = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "npm install express",
            permissionSuggestions: [
                [
                    "type": "addRules",
                    "rules": [["toolName": "Bash", "ruleContent": "npm install:*"]],
                    "behavior": "allow",
                    "destination": "localSettings"
                ]
            ]
        )

        // Card should appear inline (not as a sheet)
        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify type label
        XCTAssertTrue(app.staticTexts["Bash command"].exists, "Should show 'Bash command' label")

        // Verify command is shown
        XCTAssertTrue(app.staticTexts["npm install express"].waitForExistence(timeout: 2), "Should show command")

        // Verify options: Yes, always-allow, No
        XCTAssertTrue(app.buttons["permissionOption1"].exists, "Option 1 (Yes) should exist")
        XCTAssertTrue(app.buttons["permissionOption2"].exists, "Option 2 (always allow) should exist")
        XCTAssertTrue(app.buttons["permissionOption3"].exists, "Option 3 (No) should exist")

        // Tap Yes
        app.buttons["permissionOption1"].tap()

        // Card should collapse
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse after response")
    }

    func test_bash_permission_deny() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "rm -rf /"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Without suggestions: only Yes (1) and No (2)
        XCTAssertTrue(app.buttons["permissionOption2"].exists, "Option 2 (No) should exist")
        app.buttons["permissionOption2"].tap()

        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse after deny")
    }

    // MARK: - Edit Permission Tests

    func test_edit_permission_inline_card() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "edit",
            toolName: "Edit",
            filePath: "src/utils.ts",
            oldContent: "const foo = 1;",
            newContent: "const foo = 2;"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify type label
        XCTAssertTrue(app.staticTexts["Edit file"].exists, "Should show 'Edit file' label")

        // Verify file path
        XCTAssertTrue(app.staticTexts["src/utils.ts"].waitForExistence(timeout: 2), "Should show file path")

        // Tap Yes to approve
        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")
    }

    // MARK: - Question Permission Tests

    func test_question_options_inline() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "question",
            toolName: "AskUserQuestion",
            questionText: "Which database?",
            questionOptions: ["PostgreSQL", "SQLite"]
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify question text
        XCTAssertTrue(app.staticTexts["Which database?"].waitForExistence(timeout: 2))

        // Verify options (numbered)
        XCTAssertTrue(app.buttons["permissionOption1"].exists, "Option 1 should exist")
        XCTAssertTrue(app.buttons["permissionOption2"].exists, "Option 2 should exist")

        // Tap option
        app.buttons["permissionOption2"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")
    }

    func test_question_text_input() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "question",
            toolName: "AskUserQuestion",
            questionText: "What should the function be named?"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify question text
        XCTAssertTrue(app.staticTexts["What should the function be named?"].waitForExistence(timeout: 2))

        // Verify text field exists
        let textField = app.textFields.firstMatch
        XCTAssertTrue(textField.exists, "Text field should exist")

        // Type and submit
        textField.tap()
        textField.typeText("calculateTotal")

        let sendButton = app.buttons["Send"]
        XCTAssertTrue(sendButton.exists, "Send button should exist")
        sendButton.tap()

        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse after submit")
    }

    // MARK: - Write Permission Tests

    func test_write_permission_inline_card() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "write",
            toolName: "Write",
            filePath: "src/newFile.ts",
            oldContent: "",
            newContent: "export function newHelper() {\n  return 'hello';\n}"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify type label
        XCTAssertTrue(app.staticTexts["Create file"].exists, "Should show 'Create file' label")

        // Verify file path
        XCTAssertTrue(app.staticTexts["src/newFile.ts"].waitForExistence(timeout: 2), "Should show file path")

        // Approve
        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")
    }

    // MARK: - Task Permission Tests

    func test_task_permission_inline_card() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "task",
            toolName: "Task",
            description: "Search codebase for authentication patterns"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify type label
        XCTAssertTrue(app.staticTexts["Agent"].exists, "Should show 'Agent' label")

        // Allow
        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")
    }
}
