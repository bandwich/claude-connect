---
status: completed
created: 2026-04-01
completed: 2026-04-02
branch: feature/e2e-test-rewrite
---

# E2E Test Rewrite — Phase 2: Test Suites

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Write the actual E2E test suites using the test server infrastructure from Phase 1. Delete all old E2E test files and replace with fresh suites that use HTTP injection for fast, deterministic testing.

**Architecture:** Each test suite connects to the test server, navigates the iOS app to the right screen, injects content via HTTP endpoints, and verifies the app renders it correctly. Tests use XCUITest with the coordinate-based tapping and HTTP verification patterns from E2ETestBase.

**Prerequisites:** Phase 1 must be complete — test server with injection endpoints, E2ETestBase with helpers, runner script with `--fast` mode.

**Tech Stack:** Swift (XCUITest), test server (Python, from Phase 1)

**Risky Assumptions:** XCUITest element queries may not find injected content if the WebSocket message format is slightly wrong. Debug by comparing test server output to real server output.

---

### Task 1: Connection + Conversation Tests

Delete old test files and create new ones for connection lifecycle and conversation rendering.

**Files:**
- Delete: `ios/ClaudeConnect/ClaudeConnectUITests/E2EConnectionTests.swift`
- Delete: `ios/ClaudeConnect/ClaudeConnectUITests/E2EErrorHandlingTests.swift`
- Delete: `ios/ClaudeConnect/ClaudeConnectUITests/E2EFullConversationFlowTests.swift`
- Create: `ios/ClaudeConnect/ClaudeConnectUITests/E2EConnectionTests.swift`
- Create: `ios/ClaudeConnect/ClaudeConnectUITests/E2EConversationTests.swift`

**Step 1: Read current UI to verify accessibility identifiers**

Before writing tests, read SessionView.swift and SettingsView.swift to confirm accessibility identifiers like `connectionStatus`, `settingsButton`, `permissionCard`, etc. still exist and match what the tests will query.

**Step 2: Write E2EConnectionTests**

```swift
import XCTest

final class E2EConnectionTests: E2ETestBase {

    /// App connects to test server and shows projects
    func test_connects_and_shows_projects() throws {
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

        app.buttons["Disconnect"].tap()
        sleep(2)
        XCTAssertEqual(statusLabel.label, "Disconnected")

        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))

        app.buttons["Done"].tap()

        let notConnectedText = app.staticTexts["Not Connected"]
        XCTAssertTrue(notConnectedText.waitForExistence(timeout: 5))
    }
}
```

**Step 3: Write E2EConversationTests**

```swift
import XCTest

final class E2EConversationTests: E2ETestBase {

    /// Injected text response appears in conversation
    func test_text_response_renders() throws {
        navigateToTestSession()
        injectTextResponse("Hello, this is a test response from Claude.")

        let responseText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'test response from Claude'")
        ).firstMatch
        XCTAssertTrue(responseText.waitForExistence(timeout: 10), "Response text should appear")
    }

    /// Tool use block renders with correct structure
    func test_tool_use_renders() throws {
        navigateToTestSession()
        injectToolUse(
            name: "Read",
            input: ["file_path": "/tmp/test.txt"],
            result: "file contents here"
        )

        let toolBlock = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Read'")
        ).firstMatch
        XCTAssertTrue(toolBlock.waitForExistence(timeout: 10), "Tool use block should appear")
    }

    /// Multiple content blocks render in sequence
    func test_multiple_blocks_render() throws {
        navigateToTestSession()

        injectContentBlocks([["type": "text", "text": "Let me check that file."]])
        sleep(1)

        let firstText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'check that file'")
        ).firstMatch
        XCTAssertTrue(firstText.waitForExistence(timeout: 10))

        let toolId = UUID().uuidString
        injectContentBlocks([
            ["type": "tool_use", "id": toolId, "name": "Bash", "input": ["command": "ls -la"]],
            ["type": "tool_result", "tool_use_id": toolId, "content": "total 8\ndrwxr-xr-x  2 user  staff  64 Apr  1 12:00 ."]
        ])
        sleep(1)

        let toolBlock = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Bash'")
        ).firstMatch
        XCTAssertTrue(toolBlock.waitForExistence(timeout: 10), "Bash tool block should appear")
    }
}
```

**Step 4: Run tests**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EConnectionTests
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EConversationTests
```

**CHECKPOINT:** Both suites pass. If conversation tests fail, compare the test server's WebSocket output format to the real server's — the content block format may not match exactly.

**Step 5: Commit**

```bash
git commit -m "feat: add E2E connection and conversation tests"
```

---

### Task 2: Permission + Question Tests

**Files:**
- Delete: `ios/ClaudeConnect/ClaudeConnectUITests/E2EPermissionTests.swift`
- Create: `ios/ClaudeConnect/ClaudeConnectUITests/E2EPermissionTests.swift`
- Create: `ios/ClaudeConnect/ClaudeConnectUITests/E2EQuestionTests.swift`

**Step 1: Read PermissionCardView.swift and question prompt UI**

Verify accessibility identifiers for permission cards (`permissionCard`, `permissionResolved`, `permissionOption1`, etc.) and question prompts (`questionCard`). Check how question options are rendered.

**Step 2: Write E2EPermissionTests**

```swift
import XCTest

final class E2EPermissionTests: E2ETestBase {

    func test_bash_permission_card() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "bash", toolName: "Bash", command: "npm install express"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5))
        XCTAssertTrue(app.staticTexts["Bash command"].exists)
        XCTAssertTrue(app.staticTexts["npm install express"].waitForExistence(timeout: 2))

        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3))
    }

    func test_permission_deny() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "bash", toolName: "Bash", command: "rm -rf /"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5))
        app.buttons["permissionOption2"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3))
    }

    func test_edit_permission_card() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "edit", toolName: "Edit",
            filePath: "src/utils.ts", oldContent: "const foo = 1;", newContent: "const foo = 2;"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5))
        XCTAssertTrue(app.staticTexts["Edit file"].exists)
        XCTAssertTrue(app.staticTexts["src/utils.ts"].waitForExistence(timeout: 2))

        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3))
    }

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
        XCTAssertTrue(app.buttons["permissionOption1"].exists, "Yes")
        XCTAssertTrue(app.buttons["permissionOption2"].exists, "Always-allow")
        XCTAssertTrue(app.buttons["permissionOption3"].exists, "No")

        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3))
    }
}
```

**Step 3: Write E2EQuestionTests**

```swift
import XCTest

final class E2EQuestionTests: E2ETestBase {

    func test_question_with_options() throws {
        navigateToTestSession()

        let _ = injectQuestionPrompt(
            question: "Which approach should I use?",
            options: ["Option A", "Option B", "Option C"]
        )

        let questionCard = app.otherElements["questionCard"]
        XCTAssertTrue(questionCard.waitForExistence(timeout: 5))

        let questionText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Which approach'")
        ).firstMatch
        XCTAssertTrue(questionText.waitForExistence(timeout: 3))

        let optionA = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Option A'")
        ).firstMatch
        XCTAssertTrue(optionA.waitForExistence(timeout: 3))
        optionA.tap()

        sleep(2)
        XCTAssertFalse(questionCard.exists, "Card should dismiss after answer")
    }

    func test_question_without_options() throws {
        navigateToTestSession()

        let _ = injectQuestionPrompt(
            question: "What should I name this variable?",
            options: []
        )

        let questionCard = app.otherElements["questionCard"]
        XCTAssertTrue(questionCard.waitForExistence(timeout: 5))

        let questionText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'name this variable'")
        ).firstMatch
        XCTAssertTrue(questionText.waitForExistence(timeout: 3))
    }
}
```

**Step 4: Run tests**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EPermissionTests
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EQuestionTests
```

**CHECKPOINT:** Both suites pass.

**Step 5: Commit**

```bash
git commit -m "feat: add E2E permission and question tests"
```

---

### Task 3: Navigation + Session + File Browser Tests

**Files:**
- Delete: `ios/ClaudeConnect/ClaudeConnectUITests/E2ENavigationFlowTests.swift`
- Delete: `ios/ClaudeConnect/ClaudeConnectUITests/E2ESessionFlowTests.swift`
- Delete: `ios/ClaudeConnect/ClaudeConnectUITests/E2EFileBrowserTests.swift`
- Create: `ios/ClaudeConnect/ClaudeConnectUITests/E2ENavigationTests.swift`
- Create: `ios/ClaudeConnect/ClaudeConnectUITests/E2ESessionTests.swift`
- Create: `ios/ClaudeConnect/ClaudeConnectUITests/E2EFileBrowserTests.swift`

**Step 1: Read navigation views for current structure**

Read ProjectsListView.swift and ProjectDetailView.swift to verify navigation patterns, button labels, and accessibility identifiers.

**Step 2: Write E2ENavigationTests**

```swift
import XCTest

final class E2ENavigationTests: E2ETestBase {

    func test_navigation_flow() throws {
        navigateToProjectsList()

        // Projects list visible
        let projectCell = app.cells.firstMatch
        XCTAssertTrue(projectCell.waitForExistence(timeout: 5))

        // Settings accessible
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        tapByCoordinate(settingsButton)
        let settingsNavBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsNavBar.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // Navigate to project detail
        tapByCoordinate(projectCell)
        let newSessionButton = app.buttons["New Session"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 5))

        // Sessions/Files tabs
        let filesTab = app.buttons["Files"]
        XCTAssertTrue(filesTab.exists || app.buttons["Sessions"].exists)

        // Back to projects
        let backButton = app.buttons.element(boundBy: 0)
        tapByCoordinate(backButton)
        sleep(1)
        XCTAssertTrue(app.buttons["Add Project"].waitForExistence(timeout: 5))
    }
}
```

**Step 3: Write E2ESessionTests**

```swift
import XCTest

final class E2ESessionTests: E2ETestBase {

    func test_open_session() throws {
        navigateToTestSession()
        // navigateToTestSession already verifies the session loaded
    }

    func test_navigate_back_from_session() throws {
        navigateToProjectsList()
        let projectCell = app.cells.firstMatch
        XCTAssertTrue(projectCell.waitForExistence(timeout: 5))
        tapByCoordinate(projectCell)

        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5))
        tapByCoordinate(sessionCell)
        sleep(2)

        let backButton = app.buttons.element(boundBy: 0)
        tapByCoordinate(backButton)
        sleep(2)

        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
    }
}
```

**Step 4: Write E2EFileBrowserTests**

```swift
import XCTest

final class E2EFileBrowserTests: E2ETestBase {

    func test_files_tab_shows_listing() throws {
        navigateToProjectsList()

        let projectCell = app.cells.firstMatch
        XCTAssertTrue(projectCell.waitForExistence(timeout: 5))
        tapByCoordinate(projectCell)

        let filesTab = app.buttons["Files"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()
        sleep(2)

        // Should see at least one file entry from mock data
        let fileEntry = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '.'")
        ).firstMatch
        XCTAssertTrue(fileEntry.waitForExistence(timeout: 5), "Should show file entries")
    }

    func test_view_file_contents() throws {
        navigateToProjectsList()

        let projectCell = app.cells.firstMatch
        XCTAssertTrue(projectCell.waitForExistence(timeout: 5))
        tapByCoordinate(projectCell)

        let filesTab = app.buttons["Files"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()
        sleep(2)

        let fileButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '.'")
        ).firstMatch

        if fileButton.waitForExistence(timeout: 5) {
            fileButton.tap()
            sleep(2)

            // Verify not stuck on Loading
            let loadingText = app.staticTexts["Loading..."]
            let startTime = Date()
            while loadingText.exists && Date().timeIntervalSince(startTime) < 10 {
                usleep(500000)
            }
            XCTAssertFalse(loadingText.exists, "File should finish loading")
        }
    }
}
```

**Step 5: Run all tier 1 tests**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast
```

**CHECKPOINT:** All 7 tier 1 suites pass.

**Step 6: Commit**

```bash
git commit -m "feat: add E2E navigation, session, and file browser tests"
```

---

### Task 4: Run Full Tier 1 Suite and Fix Issues

**Step 1: Run all tier 1 tests end-to-end**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast
```

**Step 2: Fix any failures**

If tests fail:
1. Check `/tmp/e2e_server.log` for test server errors
2. Check `/tmp/e2e_test.log` for XCUITest failures
3. Compare test server WebSocket messages to real server format
4. Fix and re-run

**Step 3: Verify test isolation**

Run individual suites to verify each passes independently:

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EConnectionTests
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EConversationTests
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EPermissionTests
```

**CHECKPOINT:** All suites pass both individually and together.

**Step 4: Commit fixes if any**

```bash
git commit -m "fix: E2E test fixes from full suite run"
```

---

### Task 5: Update Documentation

**Files:**
- Modify: `tests/TESTS.md`
- Modify: `CLAUDE.md`

**Step 1: Update TESTS.md E2E section**

Replace the E2E section with the two-tier architecture:
- Tier 1 (test server): 7 suites, what each tests, `--fast` mode
- Tier 2 (smoke): 1 suite, what it tests, `--smoke` mode (coming in Phase 3)
- Updated commands

**Step 2: Update CLAUDE.md commands section**

Add the new E2E modes:

```bash
# E2E tests - all (test server + real Claude)
cd ios/ClaudeConnect && ./run_e2e_tests.sh

# E2E tests - fast (test server only, ~2 min)
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast

# E2E tests - smoke (real Claude only, ~3 min)
cd ios/ClaudeConnect && ./run_e2e_tests.sh --smoke

# Specific suite
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EPermissionTests
```

**Step 3: Commit**

```bash
git commit -m "docs: update test documentation for two-tier E2E architecture"
```
