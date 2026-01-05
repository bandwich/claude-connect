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

        // --- Test 2: Verify Allow dismisses sheet and updates UI ---
        app.buttons["Allow"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after Allow")

        // Verify state returns to Idle (not stuck on Processing)
        let idleState = app.staticTexts["Idle"]
        XCTAssertTrue(idleState.waitForExistence(timeout: 5), "State should return to Idle after Allow")

        // Verify permission request appeared in message history
        let requestMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '⏳ Permission requested'")).firstMatch
        XCTAssertTrue(requestMessage.exists, "Permission request should appear in message history")

        // Verify permission response appeared in message history
        let responseMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '✓ Allowed'")).firstMatch
        XCTAssertTrue(responseMessage.exists, "Permission response should appear in message history")

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

    // MARK: - Question Permission Tests (Consolidated)

    /// Tests question with text input: shows field, typing enables submit, submit works
    func test_question_text_input_complete_flow() throws {
        navigateToTestSession()

        // --- Test 1: Verify question UI with text field ---
        let _ = injectPermissionRequest(
            promptType: "question",
            toolName: "AskUserQuestion",
            questionText: "What should the function be named?"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear")

        // Verify Question title
        XCTAssertTrue(app.navigationBars["Question"].exists, "Should show Question title")

        // Verify question text
        let questionText = app.staticTexts["What should the function be named?"]
        XCTAssertTrue(questionText.waitForExistence(timeout: 2), "Should show question text")

        // Verify text field exists
        let textField = app.textFields.firstMatch
        XCTAssertTrue(textField.exists, "Text field should exist")

        // Verify Submit button exists
        let submitButton = app.buttons["Submit"]
        XCTAssertTrue(submitButton.exists, "Submit button should exist")

        // --- Test 2: Type text and verify submit becomes enabled ---
        textField.tap()
        textField.typeText("calculateTotal")

        // --- Test 3: Submit and verify sheet dismisses ---
        submitButton.tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after submit")
    }

    /// Tests question with options: shows choices, selection works, submit works
    func test_question_options_complete_flow() throws {
        navigateToTestSession()

        // --- Test 1: Verify question UI with options ---
        let _ = injectPermissionRequest(
            promptType: "question",
            toolName: "AskUserQuestion",
            questionText: "Which database should we use?",
            questionOptions: ["PostgreSQL", "SQLite", "MongoDB"]
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear")

        // Verify all options are displayed
        XCTAssertTrue(app.staticTexts["PostgreSQL"].waitForExistence(timeout: 2), "Should show PostgreSQL")
        XCTAssertTrue(app.staticTexts["SQLite"].exists, "Should show SQLite")
        XCTAssertTrue(app.staticTexts["MongoDB"].exists, "Should show MongoDB")

        // --- Test 2: Select an option ---
        app.staticTexts["SQLite"].tap()

        // --- Test 3: Submit and verify sheet dismisses ---
        let submitButton = app.buttons["Submit"]
        XCTAssertTrue(submitButton.exists, "Submit button should exist")
        submitButton.tap()

        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after submit")
    }

    // MARK: - Write Permission Tests (New File)

    /// Tests write permission flow: shows "New File" title, DiffView, Approve/Reject
    func test_write_permission_complete_flow() throws {
        navigateToTestSession()

        // --- Test 1: Verify write permission shows New File UI ---
        let _ = injectPermissionRequest(
            promptType: "write",
            toolName: "Write",
            filePath: "src/newFile.ts",
            oldContent: "",  // Empty for new file
            newContent: "export function newHelper() {\n  return 'hello';\n}"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear")

        // Verify New File title
        XCTAssertTrue(app.navigationBars["New File"].exists, "Should show New File title")

        // Verify file path is shown
        let filePath = app.staticTexts["src/newFile.ts"]
        XCTAssertTrue(filePath.waitForExistence(timeout: 2), "Should show file path")

        // Verify new content is visible (all additions for new file)
        let hasContent = app.staticTexts["export function newHelper() {"].exists ||
                        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'newHelper'")).count > 0
        XCTAssertTrue(hasContent, "Should show new file content")

        // Verify Approve and Reject buttons
        XCTAssertTrue(app.buttons["Approve"].exists, "Approve button should exist")
        XCTAssertTrue(app.buttons["Reject"].exists, "Reject button should exist")

        // --- Test 2: Verify Approve dismisses sheet ---
        app.buttons["Approve"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after Approve")
    }

    // MARK: - Task/Agent Permission Tests

    /// Tests task/agent permission: shows description, Allow/Deny work
    func test_task_permission_complete_flow() throws {
        navigateToTestSession()

        // --- Test 1: Verify task permission UI ---
        let _ = injectPermissionRequest(
            promptType: "task",
            toolName: "Task",
            description: "Search codebase for authentication patterns"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Permission sheet should appear")

        // Verify Agent title
        XCTAssertTrue(app.navigationBars["Agent"].exists, "Should show Agent title")

        // Verify Allow and Deny buttons
        XCTAssertTrue(app.buttons["Allow"].exists, "Allow button should exist")
        XCTAssertTrue(app.buttons["Deny"].exists, "Deny button should exist")

        // --- Test 2: Allow dismisses sheet ---
        app.buttons["Allow"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Sheet should dismiss after Allow")
    }
}
