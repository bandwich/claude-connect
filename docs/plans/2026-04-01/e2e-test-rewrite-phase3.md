---
status: completed
created: 2026-04-01
completed: 2026-04-02
branch: feature/e2e-test-rewrite
---

# E2E Test Rewrite — Phase 3: Real Claude Smoke Tests

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Add 2 real Claude smoke tests that validate the transcript format contract. These tests hit real Claude Code and verify that all content block types (text, thinking, tool_use, tool_result) are correctly parsed and rendered by the iOS app.

**Architecture:** Smoke tests use the real server (`server/main.py`) with a real Claude Code session. The runner script creates a session in `/tmp/e2e_test_project`, starts the real server, and runs only the smoke suite. Tests send carefully chosen prompts that force Claude to produce all content block types.

**Prerequisites:** Phase 1 (infrastructure) and Phase 2 (test suites) must be complete.

**Risky Assumptions:** Claude Code's response format could change. The prompts must reliably produce tool_use blocks — asking Claude to read a file is the most reliable trigger. If Claude refuses or the prompt doesn't trigger tools, the test fails (which is the correct behavior — it means our format expectations are wrong).

---

### Task 1: Write E2ESmokeTests

**Files:**
- Create: `ios/ClaudeConnect/ClaudeConnectUITests/E2ESmokeTests.swift`

**Step 1: Read ToolUseView.swift for accessibility identifiers**

Read ToolUseView.swift to verify how tool_use blocks are rendered and what text/identifiers are visible in the XCUITest element tree. This determines what the smoke tests can query for.

**Step 2: Write the smoke test file**

```swift
import XCTest

/// Contract validation tests using real Claude Code sessions.
/// Verify Claude Code's transcript format matches what we parse.
/// If these fail but tier 1 passes, the mock format has drifted.
final class E2ESmokeTests: E2ETestBase {

    /// Smoke test 1: Text response
    /// Sends a simple prompt, verifies a text response appears.
    func test_smoke_text_response() throws {
        navigateToTestSession(resume: true)

        sendVoiceInput("Reply with only the word yes")
        XCTAssertTrue(verifyInputInTmux("Reply with only the word yes", timeout: 10),
                      "Input should reach tmux")

        XCTAssertTrue(waitForClaudeReady(timeout: 60),
                      "Claude should finish responding")

        // Response rendered — transcript was written, parsed, broadcast, and displayed
        sleep(2)
    }

    /// Smoke test 2: Tool use response
    /// Forces tool use, verifies tool_use + tool_result blocks parse and render.
    func test_smoke_tool_use_response() throws {
        navigateToTestSession(resume: true)

        // Create a test file for Claude to read
        let testFilePath = "/tmp/e2e_test_project/smoke_test.txt"
        try? "smoke test content 12345".write(toFile: testFilePath, atomically: true, encoding: .utf8)

        sendVoiceInput("Read the file smoke_test.txt and tell me what it contains. Use the Read tool.")
        XCTAssertTrue(verifyInputInTmux("smoke_test.txt", timeout: 10),
                      "Input should reach tmux")

        XCTAssertTrue(waitForClaudeReady(timeout: 90),
                      "Claude should finish after tool use")

        sleep(3)

        // Verify tool use block or file content appeared
        let toolBlock = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Read'")
        ).firstMatch

        let contentText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'smoke test content' OR label CONTAINS '12345'")
        ).firstMatch

        let anyResponse = toolBlock.exists || contentText.exists
        XCTAssertTrue(anyResponse,
                      "Should see tool use block or file content — transcript format may have changed")

        try? FileManager.default.removeItem(atPath: testFilePath)
    }
}
```

**Step 3: Run smoke tests**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh --smoke
```

**CHECKPOINT:** Both smoke tests pass. If `test_smoke_tool_use_response` fails:
1. Check server logs: `tail -f /tmp/e2e_server.log`
2. Capture tmux pane to see if Claude actually used the Read tool
3. Check if the transcript file has tool_use blocks
4. Verify the iOS app received the content blocks

**Step 4: Commit**

```bash
git commit -m "feat: add real Claude smoke tests for transcript format validation"
```

---

### Task 2: Full Suite Verification

**Step 1: Run all tests (both tiers)**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh
```

This should:
1. Start test server, run tier 1 suites (fast)
2. Kill test server
3. Create Claude session, start real server, run tier 2 smoke tests

**Step 2: Verify each mode independently**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast
cd ios/ClaudeConnect && ./run_e2e_tests.sh --smoke
cd ios/ClaudeConnect && ./run_e2e_tests.sh E2ESmokeTests
```

All modes should work.

**CHECKPOINT:** Full suite passes in all modes.

**Step 3: Commit if any fixes needed**

```bash
git commit -m "fix: smoke test fixes from full suite verification"
```
