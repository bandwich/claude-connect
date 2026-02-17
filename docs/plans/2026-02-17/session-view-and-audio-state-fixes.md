# Three Bugfixes + Scroll Gap Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix branch name hardcoded to "main", session history not loading without scroll, mic button getting stuck, and missing bottom gap in scroll view.

**Architecture:** Four independent fixes: (1) server sends git branch in connection_status, iOS reads it; (2) replace LazyVStack with VStack + add contentMargins for bottom gap; (3) AudioPlayer.stop() resets voice/output state, and completion handlers on every buffer ensure isPlaying accuracy.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS)

**Risky Assumptions:** `git branch --show-current` may not work if project dir isn't a git repo — we'll handle that by falling back to empty string.

---

### Task 1: Server sends git branch in connection_status

**Files:**
- Modify: `voice_server/ios_server.py:433-440` (send_connection_status)
- Test: `voice_server/tests/test_message_handlers.py`

**Step 1: Write the failing test**

Add to `test_message_handlers.py`:

```python
@pytest.mark.asyncio
async def test_connection_status_includes_branch(self, server):
    """connection_status should include branch field"""
    mock_ws = AsyncMock()
    server.tmux.session_exists = MagicMock(return_value=True)
    server.active_session_id = "test-session"

    await server.send_connection_status(mock_ws)

    response = json.loads(mock_ws.send.call_args[0][0])
    assert "branch" in response
    assert isinstance(response["branch"], str)
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py -k test_connection_status_includes_branch -v`
Expected: FAIL — "branch" not in response

**Step 3: Implement — add branch to send_connection_status**

In `voice_server/ios_server.py`, add a helper and modify `send_connection_status`:

```python
def _get_current_branch(self) -> str:
    """Get current git branch for the active session's working directory."""
    try:
        if self.active_session_id and self.active_folder_name:
            cwd = self.session_manager.get_session_cwd(
                self.active_folder_name, self.active_session_id
            )
            if cwd:
                result = subprocess.run(
                    ["git", "branch", "--show-current"],
                    cwd=cwd,
                    capture_output=True,
                    text=True,
                    timeout=2
                )
                if result.returncode == 0:
                    return result.stdout.strip()
    except Exception as e:
        print(f"[DEBUG] _get_current_branch error: {e}")
    return ""
```

Modify `send_connection_status`:

```python
async def send_connection_status(self, websocket):
    """Send connection status to a single client"""
    response = {
        "type": "connection_status",
        "connected": self.tmux.session_exists(),
        "active_session_id": self.active_session_id,
        "branch": self._get_current_branch()
    }
    await websocket.send(json.dumps(response))
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py -k test_connection_status_includes_branch -v`
Expected: PASS

**Step 5: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add git branch to connection_status message"
```

---

### Task 2: iOS reads branch from connection_status

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift:112-122` (ConnectionStatus)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift` (publish branch)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:18` (read branch)
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`

**Step 1: Write the failing test**

Add to `ClaudeVoiceTests.swift` in the `ConnectionStatusModelTests` suite:

```swift
@Test func testConnectionStatusDecodingWithBranch() throws {
    let json = """
    {
        "type": "connection_status",
        "connected": true,
        "active_session_id": "abc123",
        "branch": "feat/my-feature"
    }
    """.data(using: .utf8)!

    let status = try JSONDecoder().decode(ConnectionStatus.self, from: json)
    #expect(status.branch == "feat/my-feature")
}

@Test func testConnectionStatusDecodingWithoutBranch() throws {
    let json = """
    {
        "type": "connection_status",
        "connected": true,
        "active_session_id": "abc123"
    }
    """.data(using: .utf8)!

    let status = try JSONDecoder().decode(ConnectionStatus.self, from: json)
    #expect(status.branch == nil)
}
```

**Step 2: Run tests to verify they fail**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/ConnectionStatusModelTests`
Expected: FAIL — `ConnectionStatus` has no `branch` property

**Step 3: Implement**

In `Session.swift`, add `branch` to `ConnectionStatus`:

```swift
struct ConnectionStatus: Codable {
    let type: String
    let connected: Bool
    let activeSessionId: String?
    let branch: String?

    enum CodingKeys: String, CodingKey {
        case type
        case connected
        case activeSessionId = "active_session_id"
        case branch
    }
}
```

In `WebSocketManager.swift`, add a published property and update the handler. Add after `@Published var activeSessionId`:

```swift
@Published var branch: String? = nil
```

In the `handleMessage` method where `ConnectionStatus` is decoded (around line 419-425), add:

```swift
self.branch = connectionStatus.branch
```

In `SessionView.swift`, remove the hardcoded state variable:

```swift
// DELETE: @State private var branchName: String = "main"
```

Replace `branchName` usage in the nav bar (around line 129) with:

```swift
Text(webSocketManager.branch ?? "main")
```

**Step 4: Run tests to verify they pass**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/ConnectionStatusModelTests`
Expected: PASS

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift
git commit -m "feat: display current git branch in session view"
```

---

### Task 3: Fix session history not loading + bottom scroll gap

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:28-66` (ScrollView area)

**Step 1: Replace LazyVStack with VStack and add contentMargins**

In `SessionView.swift`, change the ScrollView block:

```swift
// BEFORE:
ScrollView {
    LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(items) { item in
            // ...
        }
    }
    .padding()
}

// AFTER:
ScrollView {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(items) { item in
            // ...
        }
    }
    .padding()
}
.contentMargins(.bottom, 20, for: .scrollContent)
```

That's it — two changes: `LazyVStack` → `VStack`, and `.contentMargins(.bottom, 20, for: .scrollContent)` on the ScrollView.

**Step 2: Verify manually**

- Open a session with history — it should load immediately without needing a scroll gesture
- New messages should have a visible gap between the last message and the divider above the mic
- Manual scrolling should also show the gap at the bottom

**Automated tests:** None — this is a visual/rendering fix. The LazyVStack issue is a SwiftUI layout timing bug that can't be reliably reproduced in unit tests.

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "fix: session history loading and bottom scroll gap"
```

---

### Task 4: Fix mic button getting stuck (AudioPlayer state management)

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/AudioPlayer.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`

This task fixes two bugs:
- **Bug A:** `stop()` doesn't call `onPlaybackFinished`, leaving voiceState/outputState stuck at `.speaking`
- **Bug B:** Completion handler only on predicted-last buffer; if fewer chunks arrive, `isPlaying` stuck true

**Step 1: Guard audio engine setup in tests**

`AudioPlayer.init()` calls `setupAudioEngine()` which runs `audioEngine.start()`. This may fail in unit test processes with no audio hardware. The existing `isRunningUITests` guard only skips `setupAudioSession`, not `setupAudioEngine`. Extend the guard to also skip engine setup:

In `AudioPlayer.swift`, modify `init()`:

```swift
override init() {
    super.init()
    if !isRunningUITests {
        setupAudioEngine()
        setupAudioSession()
    }
}
```

Also update `isRunningUITests` to detect both UI tests and unit tests:

```swift
private var isRunningUITests: Bool {
    return NSClassFromString("XCTestCase") != nil
}
```

(This already checks for XCTestCase, so it covers unit tests too — the guard just needs to also wrap `setupAudioEngine()`.)

**Step 2: Write failing tests**

Add a new test suite to `ClaudeVoiceTests.swift`:

```swift
@Suite("AudioPlayer State Tests")
struct AudioPlayerStateTests {

    @Test func testStopCallsOnPlaybackFinished() {
        let player = AudioPlayer()
        var callbackCalled = false
        player.onPlaybackFinished = { callbackCalled = true }

        // Simulate that player was playing
        player.isPlaying = true
        player.stop()

        #expect(player.isPlaying == false)
        #expect(callbackCalled == true)
    }

    @Test func testStopWhenNotPlayingDoesNotCallCallback() {
        let player = AudioPlayer()
        var callbackCalled = false
        player.onPlaybackFinished = { callbackCalled = true }

        player.stop()

        #expect(player.isPlaying == false)
        #expect(callbackCalled == false)
    }
}
```

**Step 3: Run tests to verify they fail**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/AudioPlayerStateTests`
Expected: FAIL — `testStopCallsOnPlaybackFinished` fails because `stop()` doesn't call the callback

**Step 4: Implement Fix A — stop() calls onPlaybackFinished when playing**

In `AudioPlayer.swift`, modify `stop()`:

```swift
func stop() {
    let wasPlaying = isPlaying

    playerNode.stop()
    interruptionDelay?.cancel()
    interruptionDelay = nil
    pendingChunks = []

    receivedChunks = 0
    scheduledChunks = 0
    completedChunks = 0
    expectedChunks = 0
    isPlaying = false

    print("AudioPlayer: Stopped")
    logToFile("⏹ AudioPlayer: Stopped")

    if wasPlaying {
        onPlaybackFinished?()
    }
}
```

**Step 5: Implement Fix B — completion handler on every buffer**

Add a new property to `AudioPlayer`:

```swift
private var completedChunks = 0
```

Reset `completedChunks = 0` in these three places:
1. `receiveAudioChunk` new-message interruption block (line 85 area, alongside `receivedChunks = 0`)
2. `handlePlaybackFinished` (alongside the other counter resets)
3. `stop()` (already shown above in Fix A)

Modify `scheduleAudioBuffer` to attach a completion handler to every buffer:

```swift
private func scheduleAudioBuffer(_ buffer: AVAudioPCMBuffer, isLastChunk: Bool) {
    playerNode.scheduleBuffer(buffer) { [weak self] in
        DispatchQueue.main.async {
            guard let self = self else { return }
            self.completedChunks += 1
            if self.completedChunks == self.expectedChunks && self.receivedChunks == self.expectedChunks {
                self.handlePlaybackFinished()
            }
        }
    }
}
```

Remove the `isLastChunk` parameter from both the function signature and the call site (in `processChunk`), since every buffer now has a completion handler.

Also reset `completedChunks = 0` in `handlePlaybackFinished` and in the new-message branch of `receiveAudioChunk` (line 85 area, alongside the other resets).

**Step 6: Run tests to verify they pass**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/AudioPlayerStateTests`
Expected: PASS

**Step 7: Run full test suite**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests`
Expected: All tests PASS

**Step 8: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/AudioPlayer.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift
git commit -m "fix: mic button stuck by ensuring AudioPlayer state cleanup"
```

---

### Task 5: Run server tests + final verification

**Step 1: Run server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests PASS

**Step 2: Run iOS unit tests**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests`
Expected: All tests PASS

**CHECKPOINT:** All tests must pass before proceeding.

**Step 3: Manual verification**

1. Start server (`claude-connect`), connect iOS app
2. Open an existing session — verify:
   - Branch name shows correctly (not hardcoded "main")
   - Session history loads immediately without needing to scroll
   - Gap visible between last message and mic area divider
3. Send a voice message, let TTS play, then verify mic re-enables
4. During TTS playback, navigate away and back — verify mic isn't stuck

**Step 4: Final commit if any adjustments needed, then done**
