---
status: completed
completed: 2026-04-01
created: 2026-04-01
branch: feature/fix-ios-unit-tests
---

# Fix iOS Unit Tests (Revised)

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Get iOS unit tests to 0 failures by fixing 6 real issues discovered during the first attempt, then add coverage for untested features.

**Architecture:** Fix AudioPlayer crash by guarding all engine operations behind `isRunningUITests` (same pattern already used in `init()`). Fix WebSocketManager reconnect tests by not calling `connect(url:)` (which triggers async pre-checks) — instead set `currentURL` directly. Fix AgentInfo assertion math. Add new test files for Tailscale IP and SessionCleared. Update docs.

**Tech Stack:** Swift Testing, XCTest (build runner), xcodebuild CLI

**Risky Assumptions:** The `isRunningUITests` guard (`NSClassFromString("XCTestCase") != nil`) works in Swift Testing context. Verified: Swift Testing runs inside xctest bundle, so XCTestCase class is available. The guard already prevents `setupAudioEngine()` in init — we just need to extend it to runtime operations.

**Prior work on this branch:** Task 1 from v1 plan is done — parallel testing disabled in CLAUDE.md and TESTS.md, iPhone 17 destination set. Uncommitted changes: AgentInfo assertion fix, isTailscaleIP visibility change, TailscaleIPTests.swift created.

---

### Task 1: Fix AudioPlayer crash in tests

The crash: `AudioPlayer.init()` skips `setupAudioEngine()` when `isRunningUITests` is true, but `receiveAudioChunk()` → `processChunk()` → `startPlayback()` still accesses `audioEngine` and `playerNode`, causing an NSException. Two crashing tests: `testChunkCountingLogic` (AudioPlayerTests) and `testAudioBufferingWithMultipleChunks` (EndToEndFlowTests).

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnect/Services/AudioPlayer.swift`

**Step 1: Add `isRunningUITests` guard to `receiveAudioChunk`**

At the top of `receiveAudioChunk` (line 71), before any engine access, add an early return:

```swift
func receiveAudioChunk(_ chunk: AudioChunkMessage) {
    // Skip audio processing in test environment (no AVAudioEngine)
    guard !isRunningUITests else {
        receivedChunks += 1
        expectedChunks = chunk.totalChunks
        if receivedChunks >= minBufferChunks { isPlaying = true }
        if receivedChunks == expectedChunks { handlePlaybackFinished() }
        return
    }
```

This preserves the counter logic (so tests checking `isPlaying` and `onPlaybackFinished` still work) without touching AVAudioEngine.

**Step 2: Add guard to `stop()` method**

Find the `stop()` method and add the same guard at the top. The engine-less path just resets state:

```swift
func stop() {
    guard !isRunningUITests else {
        isPlaying = false
        receivedChunks = 0
        scheduledChunks = 0
        completedChunks = 0
        expectedChunks = 0
        pendingChunks = []
        interruptionDelay?.cancel()
        interruptionDelay = nil
        return
    }
```

**Step 3: Run AudioPlayerTests to verify no crash**

Run with `run_in_background: true`:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests/AudioPlayerTests \
  -parallel-testing-enabled NO
```

Expected: All AudioPlayerTests pass, no crash.

**Step 4: Commit**

```bash
git add ios/ClaudeConnect/ClaudeConnect/Services/AudioPlayer.swift
git commit -m "fix: guard AudioPlayer engine operations in test environment"
```

---

### Task 2: Fix WebSocketManager reconnect tests

The 4 failing tests call `connect(url:)` to set `currentURL`, then manually change `connectionState`, then call `reconnectIfNeeded()`. Problem: `connect(url:)` triggers `connectToURL()` which starts an async pre-check Task that races with the test — it overwrites `connectionState` back to `.connecting` or `.error`.

Fix: Don't use `connect(url:)` in these tests. Instead, set `currentURL` directly (it's internal access) and set `shouldReconnect` to simulate a stored connection.

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnectTests/WebSocketManagerTests.swift:570-625`

**Step 1: Fix `reconnectIfNeededStartsWhenDisconnectedWithURL`**

Replace:
```swift
@Test func reconnectIfNeededStartsWhenDisconnectedWithURL() {
    let manager = WebSocketManager()
    // Simulate a previous connection that stored the URL
    manager.connect(url: "ws://192.168.1.1:8765")
    // The connect sets currentURL internally via connectToURL
    // Now simulate iOS killing the connection (sets disconnected without clearing URL)
    manager.connectionState = .disconnected

    manager.reconnectIfNeeded()

    #expect(manager.isReconnecting == true)
    #expect(manager.connectionState == .connecting)
}
```

With:
```swift
@Test func reconnectIfNeededStartsWhenDisconnectedWithURL() {
    let manager = WebSocketManager()
    // Simulate a stored URL from a previous connection (without triggering async connect)
    manager.currentURL = URL(string: "ws://192.168.1.1:8765")
    manager.connectionState = .disconnected

    manager.reconnectIfNeeded()

    #expect(manager.isReconnecting == true)
    #expect(manager.connectionState == .connecting)
}
```

**Step 2: Fix `reconnectIfNeededStartsWhenErrorWithURL`**

Same pattern — replace `manager.connect(url:)` + manual state change with direct `currentURL` assignment:
```swift
@Test func reconnectIfNeededStartsWhenErrorWithURL() {
    let manager = WebSocketManager()
    manager.currentURL = URL(string: "ws://192.168.1.1:8765")
    manager.connectionState = .error("Connection lost")

    manager.reconnectIfNeeded()

    #expect(manager.isReconnecting == true)
    #expect(manager.connectionState == .connecting)
}
```

**Step 3: Fix `foregroundReconnectUsesThreeMaxRetries`**

```swift
@Test func foregroundReconnectUsesThreeMaxRetries() {
    let manager = WebSocketManager()
    manager.currentURL = URL(string: "ws://192.168.1.1:8765")
    manager.connectionState = .disconnected

    manager.reconnectIfNeeded()

    #expect(manager.isReconnecting == true)
    #expect(manager.foregroundMaxRetries == 3)
}
```

**Step 4: Fix `reconnectIfNeededSkipsAfterExplicitDisconnect`**

The test verifies that `disconnect()` clears `currentURL` so `reconnectIfNeeded()` has nothing to reconnect to:
```swift
@Test func reconnectIfNeededSkipsAfterExplicitDisconnect() {
    let manager = WebSocketManager()
    // Simulate a stored connection
    manager.currentURL = URL(string: "ws://192.168.1.1:8765")
    manager.connectedURL = "ws://192.168.1.1:8765"

    // Explicit disconnect clears currentURL
    manager.disconnect()

    manager.reconnectIfNeeded()

    // disconnect() cleared the URL, so nothing to reconnect to
    #expect(manager.isReconnecting == false)
    #expect(manager.connectionState == .disconnected)
}
```

**Step 5: Change `currentURL` from `private` to `internal`**

`currentURL` is `private var currentURL: URL?` at line 73 of `WebSocketManager.swift`. Change to:
```swift
var currentURL: URL?
```

This is required for `@testable import` to access it from tests.

**Step 6: Run the reconnect tests**

Run with `run_in_background: true`:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests/WebSocketManagerTests \
  -parallel-testing-enabled NO
```

Expected: All WebSocketManagerTests pass.

**Step 7: Commit**

```bash
git add ios/ClaudeConnect/ClaudeConnectTests/WebSocketManagerTests.swift \
        ios/ClaudeConnect/ClaudeConnect/Services/WebSocketManager.swift
git commit -m "fix: WebSocketManager reconnect tests avoid async connect race"
```

---

### Task 3: Fix AgentInfo test + commit existing new tests

The AgentInfo truncation assertion, isTailscaleIP visibility change, and TailscaleIPTests.swift were already prepared in the previous attempt. This task commits them and verifies.

**Files:**
- Already modified: `ios/ClaudeConnect/ClaudeConnectTests/ClaudeVoiceTests.swift:1167`
- Already modified: `ios/ClaudeConnect/ClaudeConnect/Services/WebSocketManager.swift:952`
- Already created: `ios/ClaudeConnect/ClaudeConnectTests/TailscaleIPTests.swift`

**Step 1: Verify the changes are in place**

```bash
cd /Users/aaron/Desktop/max && grep "count <= 63" ios/ClaudeConnect/ClaudeConnectTests/ClaudeVoiceTests.swift
# Expected: #expect(agent.displayDescription.count <= 63)

grep "func isTailscaleIP" ios/ClaudeConnect/ClaudeConnect/Services/WebSocketManager.swift
# Expected: func isTailscaleIP (no "private" prefix)

ls ios/ClaudeConnect/ClaudeConnectTests/TailscaleIPTests.swift
# Expected: file exists
```

**Step 2: Run TailscaleIPTests**

Run with `run_in_background: true`:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests/TailscaleIPTests \
  -parallel-testing-enabled NO
```

Expected: All 9 tests pass.

**Step 3: Commit all three changes together**

```bash
git add ios/ClaudeConnect/ClaudeConnectTests/ClaudeVoiceTests.swift \
        ios/ClaudeConnect/ClaudeConnect/Services/WebSocketManager.swift \
        ios/ClaudeConnect/ClaudeConnectTests/TailscaleIPTests.swift
git commit -m "fix: AgentInfo test assertion + add isTailscaleIP tests"
```

---

### Task 4: Add SessionClearedMessage tests

**Files:**
- Create: `ios/ClaudeConnect/ClaudeConnectTests/SessionClearedTests.swift`

**Step 1: Create the test file**

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

**Step 2: Run the tests**

Run with `run_in_background: true`:
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

### Task 5: Update iOS CLAUDE.md, run full suite, commit docs

**Files:**
- Modify: `ios/ClaudeConnect/CLAUDE.md`
- Modify: `CLAUDE.md` (already has parallel flag from Task 1 v1)
- Modify: `tests/TESTS.md` (already has parallel flag from Task 1 v1)

**Step 1: Add testing section to iOS CLAUDE.md**

Append to the end of `ios/ClaudeConnect/CLAUDE.md`:

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
Test files are in `ClaudeConnectTests/`. New `.swift` files added to that directory are automatically included in the test target (Xcode 16+ file-based membership).
```

**Step 2: Run full test suite**

Run with `run_in_background: true`:
```bash
cd ios/ClaudeConnect && xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```

Expected: All tests pass (~81 total), 0 failures.

**CHECKPOINT:** All tests must pass. If any fail, debug before committing.

**Step 3: Commit docs**

```bash
git add CLAUDE.md tests/TESTS.md ios/ClaudeConnect/CLAUDE.md
git commit -m "docs: update iOS test commands and add testing instructions"
```
