# E2E Permission Tests & Test Suite Optimization

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Add E2E tests for permission UI components and optimize the test suite from ~750s by consolidating tests that share setup flows.

**Architecture:** New E2EPermissionTests.swift with consolidated tests. Optimization via combining tests that share navigation/setup into single tests that verify multiple behaviors. Each test class targets one "flow" and tests multiple assertions within that flow.

**Tech Stack:** Swift/XCTest/XCUITest

**Key Optimization Principle:** Instead of 3 tests that each navigate to a session and test one button, write 1 test that navigates once and tests all 3 buttons sequentially.

---

## Part 1: E2E Permission Tests

### Task 1: Add Helper Method for Injecting Permission Requests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`

### Step 1: Add injectPermissionRequest helper method

Add after `simulateConversationTurn` method (around line 352):

```swift
// MARK: - Permission Request Helpers

func injectPermissionRequest(
    promptType: String,
    toolName: String,
    command: String? = nil,
    description: String? = nil,
    filePath: String? = nil,
    oldContent: String? = nil,
    newContent: String? = nil,
    questionText: String? = nil,
    questionOptions: [String]? = nil
) -> String {
    let requestId = UUID().uuidString

    var payload: [String: Any] = [
        "type": "permission_request",
        "request_id": requestId,
        "prompt_type": promptType,
        "tool_name": toolName,
        "timestamp": Date().timeIntervalSince1970
    ]

    if command != nil || description != nil {
        var toolInput: [String: Any] = [:]
        if let cmd = command { toolInput["command"] = cmd }
        if let desc = description { toolInput["description"] = desc }
        payload["tool_input"] = toolInput
    }

    if filePath != nil || oldContent != nil || newContent != nil {
        var context: [String: Any] = [:]
        if let fp = filePath { context["file_path"] = fp }
        if let old = oldContent { context["old_content"] = old }
        if let new = newContent { context["new_content"] = new }
        payload["context"] = context
    }

    if let text = questionText {
        var question: [String: Any] = ["text": text]
        if let opts = questionOptions {
            question["options"] = opts
        }
        payload["question"] = question
    }

    // Send via WebSocket
    let expectation = XCTestExpectation(description: "Send permission request")

    let url = URL(string: "ws://\(testServerHost):\(testServerPort)")!
    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()

    if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        task.send(.string(jsonString)) { error in
            task.cancel(with: .goingAway, reason: nil)
            expectation.fulfill()
        }
    }

    wait(for: [expectation], timeout: 5.0)
    sleep(1) // Wait for WebSocket message delivery and UI update

    return requestId
}

func waitForPermissionSheet(timeout: TimeInterval = 5.0) -> Bool {
    // Permission sheet has navigation title based on type
    let sheetTitles = ["Command", "Edit", "New File", "Question", "Agent"]
    for title in sheetTitles {
        if app.navigationBars[title].waitForExistence(timeout: timeout / Double(sheetTitles.count)) {
            return true
        }
    }
    return false
}

func waitForPermissionSheetDismissed(timeout: TimeInterval = 3.0) -> Bool {
    let sheetTitles = ["Command", "Edit", "New File", "Question", "Agent"]
    // Wait briefly, then check none exist
    sleep(1)
    for title in sheetTitles {
        if app.navigationBars[title].exists {
            return false
        }
    }
    return true
}
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift
git commit -m "feat: add permission request injection helpers to E2ETestBase"
```

---

### Task 2: Create E2EPermissionTests with Consolidated Bash Test

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift`

### Step 1: Create the test file with consolidated bash test

One test covers: sheet appears, shows command, shows buttons, Allow works, Deny works.

```swift
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
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift
git commit -m "test: add consolidated E2E test for bash permission flow"
```

---

### Task 3: Add Consolidated Edit Permission Test

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift`

### Step 1: Add consolidated edit permission test

Add after the bash test:

```swift
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
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift
git commit -m "test: add consolidated E2E test for edit permission with DiffView"
```

---

### Task 4: Add Consolidated Question Permission Tests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift`

### Step 1: Add consolidated question tests (text input and options in one test each)

Add after the edit test:

```swift
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
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift
git commit -m "test: add consolidated E2E tests for question permissions"
```

---

### Task 5: Add Task/Agent Permission Test

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift`

### Step 1: Add task permission test

Add after the question tests:

```swift
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
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift
git commit -m "test: add consolidated E2E test for task/agent permission"
```

---

### Task 6: Update Test Runner to Include Permission Tests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/run_e2e_tests.sh`

### Step 1: Add E2EPermissionTests to the test list

Add after line 76 (`-only-testing:ClaudeVoiceUITests/E2EVSCodeConnectionTests \`):

```bash
    -only-testing:ClaudeVoiceUITests/E2EPermissionTests \
```

### Step 2: Commit

```bash
git add ios-voice-app/ClaudeVoice/run_e2e_tests.sh
git commit -m "test: add E2EPermissionTests to test runner"
```

---

## Part 2: Test Suite Optimization (Consolidate Existing Tests)

### Task 7: Consolidate E2EProjectsListTests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EProjectsListTests.swift`

### Step 1: Consolidate 3 tests into 1

Replace the entire file content:

```swift
//
//  E2EProjectsListTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for projects list functionality (consolidated)
//

import XCTest

final class E2EProjectsListTests: E2ETestBase {

    /// Consolidated test: projects load, show counts, settings accessible
    func test_projects_list_complete_flow() throws {
        // --- Test 1: Projects load on connect ---
        // After connecting (done in setUp), projects list should load
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should show project1")

        let project2 = app.staticTexts["e2e_test_project2"]
        XCTAssertTrue(project2.waitForExistence(timeout: 5), "Should show project2")

        // --- Test 2: Session counts are shown ---
        // Project 1 has 2 sessions
        let count2 = app.staticTexts["2"]
        XCTAssertTrue(count2.exists, "Should show session count 2 for project1")

        // --- Test 3: Settings button works ---
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")

        settingsButton.tap()

        let settingsTitle = app.staticTexts["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings view")

        // Dismiss settings
        app.buttons["Done"].tap()
    }
}
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EProjectsListTests.swift
git commit -m "refactor: consolidate E2EProjectsListTests from 3 tests to 1"
```

---

### Task 8: Consolidate E2ESessionsListTests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionsListTests.swift`

### Step 1: Consolidate 3 tests into 1

Replace the entire file content:

```swift
//
//  E2ESessionsListTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for sessions list navigation (consolidated)
//

import XCTest

final class E2ESessionsListTests: E2ETestBase {

    /// Consolidated test: tap project shows sessions, message counts, back navigation
    func test_sessions_list_complete_flow() throws {
        // --- Test 1: Tap project shows sessions ---
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should show project1")

        project1.tap()

        // Should show sessions list with project name as title
        let navTitle = app.navigationBars["e2e_test_project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should navigate to sessions list")

        // Should show session titles (first user message)
        let session1Title = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1Title.waitForExistence(timeout: 5), "Should show session 1 title")

        let session2Title = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2Title.waitForExistence(timeout: 5), "Should show session 2 title")

        // --- Test 2: Sessions show message counts ---
        let count2 = app.staticTexts["2 messages"]
        XCTAssertTrue(count2.waitForExistence(timeout: 5), "Should show message count")

        // --- Test 3: Back navigation returns to projects ---
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        backButton.tap()

        let projectsTitle = app.navigationBars["Projects"]
        XCTAssertTrue(projectsTitle.waitForExistence(timeout: 5), "Should return to projects list")
    }
}
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionsListTests.swift
git commit -m "refactor: consolidate E2ESessionsListTests from 3 tests to 1"
```

---

### Task 9: Consolidate E2ESessionViewTests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionViewTests.swift`

### Step 1: Consolidate 4 tests into 2

Replace the entire file content:

```swift
//
//  E2ESessionViewTests.swift
//  ClaudeVoiceUITests
//
//  E2E tests for session view with message history and voice input (consolidated)
//

import XCTest

final class E2ESessionViewTests: E2ETestBase {

    /// Navigate to a specific session for testing
    private func navigateToSession1() {
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5))
        project1.tap()

        let navTitle = app.navigationBars["e2e_test_project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5))

        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()
    }

    /// Consolidated test: message history, voice controls, settings access
    func test_session_view_ui_elements() throws {
        navigateToSession1()

        // --- Test 1: Shows message history ---
        let userMessage = app.staticTexts["Hello Claude"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5), "Should show user message")

        let assistantMessage = app.staticTexts["Hi! How can I help?"]
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5), "Should show assistant message")

        // --- Test 2: Shows voice controls ---
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5), "Should show talk button")

        // --- Test 3: Settings accessible ---
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")

        settingsButton.tap()

        let settingsTitle = app.staticTexts["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings view")

        app.buttons["Done"].tap()
    }

    /// Test voice input from session view
    func test_session_view_voice_input() throws {
        navigateToSession1()

        sleep(1) // Wait for view to settle

        // Simulate conversation turn
        simulateConversationTurn(
            userInput: "Follow up question",
            assistantResponse: "Here's my follow up answer"
        )

        // Should transition to speaking
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")

        // Should return to idle
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to Idle")
    }
}
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionViewTests.swift
git commit -m "refactor: consolidate E2ESessionViewTests from 4 tests to 2"
```

---

### Task 10: Consolidate E2EConnectionTests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift`

### Step 1: Consolidate 3 tests into 2

Replace the entire file content:

```swift
//
//  E2EConnectionTests.swift
//  ClaudeVoiceUITests
//
//  Connection and reconnection E2E tests (consolidated)
//

import XCTest

final class E2EConnectionTests: E2ETestBase {

    /// Consolidated test: initial connection, voice controls work
    func test_connection_and_voice_controls() throws {
        // --- Test 1: Verify connected via settings ---
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")
        settingsButton.tap()

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5), "Should show connection status")
        XCTAssertEqual(statusLabel.label, "Connected", "Should be connected")

        app.buttons["Done"].tap()

        // --- Test 2: Navigate to session and verify voice controls ---
        navigateToTestSession()
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in Idle state")

        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        XCTAssertTrue(talkButton.exists, "Talk button should exist")
    }

    /// Consolidated test: disconnect, reconnect, disconnect handling
    func test_reconnection_flow() throws {
        // --- Setup: Open settings ---
        let settingsButton = app.buttons["gearshape.fill"]
        settingsButton.tap()

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(statusLabel.label, "Connected", "Should start connected")

        // --- Test 1: Disconnect ---
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
        disconnectButton.tap()

        let disconnectPredicate = NSPredicate(format: "label == %@", "Disconnected")
        let disconnectExpectation = XCTNSPredicateExpectation(predicate: disconnectPredicate, object: statusLabel)
        XCTWaiter().wait(for: [disconnectExpectation], timeout: 5)

        // --- Test 2: Verify disconnected state in main view ---
        app.buttons["Done"].tap()

        let notConnectedText = app.staticTexts["Not Connected"]
        XCTAssertTrue(notConnectedText.waitForExistence(timeout: 5), "Should show Not Connected")

        // --- Test 3: Reconnect ---
        settingsButton.tap()

        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.tap()

        let reconnectPredicate = NSPredicate(format: "label == %@", "Connected")
        let reconnectExpectation = XCTNSPredicateExpectation(predicate: reconnectPredicate, object: statusLabel)
        let result = XCTWaiter().wait(for: [reconnectExpectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Should reconnect")

        app.buttons["Done"].tap()

        // --- Test 4: Verify voice works after reconnect ---
        navigateToTestSession()
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in idle state")

        simulateConversationTurn(userInput: "Test", assistantResponse: "Test after reconnect")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should work after reconnect")
    }
}
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift
git commit -m "refactor: consolidate E2EConnectionTests from 3 tests to 2"
```

---

### Task 11: Consolidate E2EHappyPathTests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EHappyPathTests.swift`

### Step 1: Consolidate 2 tests into 1

Replace the entire file content:

```swift
//
//  E2EHappyPathTests.swift
//  ClaudeVoiceUITests
//
//  Happy path E2E tests (consolidated)
//

import XCTest

final class E2EHappyPathTests: E2ETestBase {

    /// Consolidated test: single turn and multiple turns in sequence
    func test_voice_conversation_flow() throws {
        navigateToTestSession()

        // Verify initial state
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

        // --- Test 1: Single conversation turn ---
        simulateConversationTurn(
            userInput: "Hello Claude",
            assistantResponse: "Hi! How can I help you today?"
        )

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should enter Speaking state")
        sleep(3) // Wait for audio
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should return to Idle")

        // --- Test 2: Multiple turns in sequence ---
        sleep(1)
        simulateConversationTurn(userInput: "Second message", assistantResponse: "Response two")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should speak response 2")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle after 2")

        sleep(1)
        simulateConversationTurn(userInput: "Third message", assistantResponse: "Response three")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should speak response 3")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle after 3")
    }
}
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EHappyPathTests.swift
git commit -m "refactor: consolidate E2EHappyPathTests from 2 tests to 1"
```

---

### Task 12: Consolidate E2EErrorHandlingTests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EErrorHandlingTests.swift`

### Step 1: Consolidate 3 tests into 1

Replace the entire file content:

```swift
//
//  E2EErrorHandlingTests.swift
//  ClaudeVoiceUITests
//
//  Error handling E2E tests (consolidated)
//

import XCTest

final class E2EErrorHandlingTests: E2ETestBase {

    /// Consolidated test: malformed messages, long responses, empty input
    func test_error_handling_complete_flow() throws {
        navigateToTestSession()

        // --- Test 1: Malformed message handling ---
        // Send valid conversation turn first
        simulateConversationTurn(userInput: "Test message", assistantResponse: "Valid message")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should handle valid message")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle")

        // Inject malformed JSON
        if let transcriptPath = transcriptPath {
            let fileHandle = FileHandle(forWritingAtPath: transcriptPath)
            if let handle = fileHandle {
                handle.seekToEndOfFile()
                handle.write("THIS IS NOT JSON\n".data(using: .utf8)!)
                handle.closeFile()
            }
        }

        sleep(2)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should remain in idle state after malformed JSON")

        // Verify still functional
        simulateConversationTurn(userInput: "Another test", assistantResponse: "Another valid message")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work after error")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle")

        // --- Test 2: Empty voice input ---
        sendVoiceInput("")
        sleep(2)
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should be in idle state after empty input")

        // Verify still functional
        simulateConversationTurn(userInput: "Final test", assistantResponse: "Final response")
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Should still work after empty input")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 10), "Should return to idle")

        // --- Test 3: Moderately long response ---
        let longText = String(repeating: "Message. ", count: 5)
        simulateConversationTurn(userInput: "Send long response", assistantResponse: longText)
        sleep(8)
        XCTAssertTrue(app.exists, "App should not crash with long response")

        let stateLabel = app.staticTexts["voiceState"]
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 10), "Voice state should exist")
        let validStates = ["Idle", "Speaking", "Processing", "Listening"]
        XCTAssertTrue(validStates.contains(stateLabel.label), "Should be in valid state")
    }
}
```

### Step 2: Build to verify

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build-for-testing \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EErrorHandlingTests.swift
git commit -m "refactor: consolidate E2EErrorHandlingTests from 3 tests to 1"
```

---

### Task 13: Run Full E2E Suite and Measure Improvement

### Step 1: Run full test suite

```bash
cd ios-voice-app/ClaudeVoice && time ./run_e2e_tests.sh 2>&1 | tee /tmp/final_timing.log
```

### Step 2: Count tests before and after

Before consolidation: ~22 tests across 7 files
After consolidation: ~12 tests across 8 files (including new permission tests)

### Step 3: Verify all tests pass

Expected: All E2E tests pass

---

## Summary

### Test Count Changes

| File | Before | After |
|------|--------|-------|
| E2EProjectsListTests | 3 | 1 |
| E2ESessionsListTests | 3 | 1 |
| E2ESessionViewTests | 4 | 2 |
| E2EConnectionTests | 3 | 2 |
| E2EHappyPathTests | 2 | 1 |
| E2EErrorHandlingTests | 3 | 1 |
| E2EVSCodeConnectionTests | 5 | 5 (unchanged - complex flows) |
| **E2EPermissionTests** | 0 | **5 (new)** |
| **Total** | **23** | **18** |

### Optimization Impact

Each test requires:
- App launch (~5-10s)
- Server connection (~3-5s)
- Navigation to test location (~2-5s)

Reducing from 23 to 18 tests saves ~5 full setup cycles = **~50-100s saved**

### Files Created
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift`

### Files Modified
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EProjectsListTests.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionsListTests.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionViewTests.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EHappyPathTests.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EErrorHandlingTests.swift`
- `ios-voice-app/ClaudeVoice/run_e2e_tests.sh`

---

**Plan complete and saved to `docs/plans/2026-01-05-e2e-permission-tests-optimization.md`.**

When ready to implement, run /execute-plan which will:
- Create feature branch
- Commit design and plan docs to the branch
- Execute tasks in batches with checkpoints
- Merge back to dev when complete
