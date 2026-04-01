---
status: superseded-by-v2
created: 2026-04-01
branch: feature/fix-ios-unit-tests
---

# Fix iOS Unit Tests

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Get iOS unit tests green, fix the one real bug, add coverage for untested features, and update docs so tests are part of the iOS dev workflow.

**Architecture:** All changes are in the test target and docs. One source change: `isTailscaleIP` visibility from `private` to `internal` so `@testable import` can reach it. Tests use Swift Testing framework (`import Testing`, `@Suite`, `@Test`, `#expect`).

**Tech Stack:** Swift Testing, XCTest (build runner), xcodebuild CLI

**Risky Assumptions:** The 7 flaky failures are all caused by parallel simulator clones, not intermittent real bugs. We verify this in Task 1 by running the full suite with parallel disabled — should be 1 failure (AgentInfo), not 7.

---

### Task 1: Disable parallel testing and verify flaky failures are gone

**Files:**
- Modify: `CLAUDE.md` (unit test command)
- Modify: `tests/TESTS.md` (unit test commands)

**Step 1: Add `-parallel-testing-enabled NO` to the unit test commands in CLAUDE.md**

The unit test command in CLAUDE.md (under "### Testing") currently reads:
```bash
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests
```

Change to:
```bash
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```

**Step 2: Add `-parallel-testing-enabled NO` to all unit test commands in tests/TESTS.md**

There are multiple xcodebuild commands in TESTS.md for unit tests (Quick Start section, iOS Unit Tests section, Running Specific Tests section). Add `-parallel-testing-enabled NO` to each one that uses `-only-testing:ClaudeConnectTests` or runs individual test classes.

**Step 3: Run full unit test suite with parallel disabled**

Run with `run_in_background: true` (per CLAUDE.md critical rules — no piping, no timeout):
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```

Then check results with `tail` on the output file.

Expected: Only `testAgentInfoTruncatesLongDescription` fails. All other 6 previously-flaky tests should pass.

**CHECKPOINT:** If more than 1 test fails, the flakiness theory is wrong — debug before proceeding.

**Step 4: Commit**

```bash
git add CLAUDE.md tests/TESTS.md
git commit -m "fix: disable parallel testing for iOS unit tests"
```

---

### Task 2: Fix the AgentInfo truncation test

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnectTests/ClaudeVoiceTests.swift:1167`

**Step 1: Fix the assertion**

The test at line 1167:
```swift
#expect(agent.displayDescription.count <= 60) // "Explore: " + 50 + "..."
```

The actual value is `"Explore: "` (9) + 50 chars + `"..."` (3) = 62. Change to:
```swift
#expect(agent.displayDescription.count <= 63) // "Explore: " (9) + 50 + "..." (3)
```

**Step 2: Run the test to verify it passes**

Run:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests/AgentGroupTests/testAgentInfoTruncatesLongDescription \
  -parallel-testing-enabled NO
```

Expected: `testAgentInfoTruncatesLongDescription` passed

**Step 3: Run full suite to confirm all green**

Run:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```

Expected: All tests pass, 0 failures.

**CHECKPOINT:** Full suite must be green before adding new tests.

**Step 4: Commit**

```bash
git add ios/ClaudeConnect/ClaudeConnectTests/ClaudeVoiceTests.swift
git commit -m "fix: correct AgentInfo truncation test assertion (62 chars, not 60)"
```

---

### Task 3: Add isTailscaleIP tests

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnect/Services/WebSocketManager.swift:952` (change `private` to `internal`)
- Create: `ios/ClaudeConnect/ClaudeConnectTests/TailscaleIPTests.swift`

**Step 1: Write the failing tests**

Create `ios/ClaudeConnect/ClaudeConnectTests/TailscaleIPTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeConnect

@Suite("Tailscale IP Detection Tests")
struct TailscaleIPTests {

    // MARK: - Valid Tailscale CGNAT IPs (100.64.0.0/10 = 100.64.0.0 – 100.127.255.255)

    @Test func tailscaleLowerBound() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.64.0.0") == true)
    }

    @Test func tailscaleUpperBound() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.127.255.255") == true)
    }

    @Test func tailscaleMidRange() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.100.1.1") == true)
    }

    // MARK: - Non-Tailscale IPs

    @Test func localNetworkIP() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("192.168.1.42") == false)
    }

    @Test func justBelowRange() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.63.255.255") == false)
    }

    @Test func justAboveRange() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.128.0.0") == false)
    }

    @Test func nonIPString() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("not-an-ip") == false)
    }

    @Test func emptyString() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("") == false)
    }

    @Test func localhostIP() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("127.0.0.1") == false)
    }
}
```

**Step 2: Change `isTailscaleIP` from `private` to `internal`**

In `WebSocketManager.swift` line 952, change:
```swift
private func isTailscaleIP(_ host: String) -> Bool {
```
to:
```swift
func isTailscaleIP(_ host: String) -> Bool {
```

**Step 3: Add the new test file to the Xcode project**

The project uses file system-based target membership (objectVersion 77 = Xcode 16+). New files in the ClaudeConnectTests directory are automatically included — no pbxproj edit needed. Verify by building:

```bash
cd ios/ClaudeConnect && xcodebuild build-for-testing -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

**Step 4: Run the new tests**

Run:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests/TailscaleIPTests \
  -parallel-testing-enabled NO
```

Expected: All 9 tests pass.

**Step 5: Commit**

```bash
git add ios/ClaudeConnect/ClaudeConnect/Services/WebSocketManager.swift \
        ios/ClaudeConnect/ClaudeConnectTests/TailscaleIPTests.swift
git commit -m "test: add isTailscaleIP unit tests"
```

---

### Task 4: Add SessionClearedMessage tests

**Files:**
- Create: `ios/ClaudeConnect/ClaudeConnectTests/SessionClearedTests.swift`

**Step 1: Write the tests**

Create `ios/ClaudeConnect/ClaudeConnectTests/SessionClearedTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeConnect

@Suite("SessionClearedMessage Tests")
struct SessionClearedTests {

    @Test func decodesValidMessage() throws {
        let json = """
        {
            "type": "session_cleared",
            "session_id": "abc-123"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(SessionClearedMessage.self, from: json)
        #expect(message.type == "session_cleared")
        #expect(message.sessionId == "abc-123")
    }

    @Test func failsWithoutSessionId() {
        let json = """
        {
            "type": "session_cleared"
        }
        """.data(using: .utf8)!

        #expect(throws: Error.self) {
            try JSONDecoder().decode(SessionClearedMessage.self, from: json)
        }
    }

    @Test func callbackFiresWithSessionId() {
        let manager = WebSocketManager()
        var receivedId: String?

        manager.onSessionCleared = { sessionId in
            receivedId = sessionId
        }

        manager.onSessionCleared?("new-session-456")

        #expect(receivedId == "new-session-456")
    }
}
```

**Step 2: Run the new tests**

Run:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests/SessionClearedTests \
  -parallel-testing-enabled NO
```

Expected: All 3 tests pass.

**Step 3: Commit**

```bash
git add ios/ClaudeConnect/ClaudeConnectTests/SessionClearedTests.swift
git commit -m "test: add SessionClearedMessage unit tests"
```

---

### Task 5: Update iOS CLAUDE.md and run full suite

**Files:**
- Modify: `ios/ClaudeConnect/CLAUDE.md`

**Step 1: Add testing instructions to iOS CLAUDE.md**

Add this section at the end of the file:

```markdown

## Testing

After modifying Swift code, run iOS unit tests to check for regressions:

```bash
cd ios/ClaudeConnect
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```

Tests use Swift Testing framework (`import Testing`, `@Suite`, `@Test`, `#expect`).
Test files are in `ClaudeConnectTests/`. New `.swift` files added to that directory are automatically included in the test target.
```

**Step 2: Run full test suite to confirm everything is green**

Run:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```

Expected: All tests pass (previous ~69 + 12 new = ~81), 0 failures.

**CHECKPOINT:** All tests must pass. If any fail, debug before committing.

**Step 3: Commit**

```bash
git add ios/ClaudeConnect/CLAUDE.md
git commit -m "docs: add iOS unit test instructions to CLAUDE.md"
```
