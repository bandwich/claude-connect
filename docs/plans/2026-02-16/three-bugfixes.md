# Three Bug Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix three bugs: negative context percentage display, duplicate voice messages, and usage requests blocking the WebSocket message loop.

**Architecture:** All three are independent, isolated fixes. Bug 1 is a one-line clamp in SessionView. Bug 2 adds echo filtering in SessionView's `onUserMessage` callback. Bug 3 changes one `await` to `asyncio.create_task()` in the server's message handler.

**Tech Stack:** Swift/SwiftUI (iOS), Python/asyncio (server)

**Risky Assumptions:** Bug 2's text-matching filter assumes the server echoes back the exact same text the app sent. If the transcript watcher trims or reformats the text, the filter won't catch duplicates. We verify this manually.

---

### Task 1: Fix negative context percentage display

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:115`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`

**Step 1: Write the failing test**

Add to `ClaudeVoiceTests.swift`:

```swift
@Test func testContextPercentageClampedAtZero() {
    // When context_percentage > 100 (over-limit), remaining should show 0%, not negative
    let overLimit: Double = 120.0
    let displayed = Int(max(0, 100 - overLimit))
    #expect(displayed == 0, "Over-limit context should display 0%, not negative")

    let normalCase: Double = 60.0
    let normalDisplayed = Int(max(0, 100 - normalCase))
    #expect(normalDisplayed == 40, "Normal context should display correctly")

    let exactLimit: Double = 100.0
    let exactDisplayed = Int(max(0, 100 - exactLimit))
    #expect(exactDisplayed == 0, "Exact limit should display 0%")
}
```

**Step 2: Run test to verify it passes** (this tests the formula, not the UI)

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/ClaudeVoiceTests/testContextPercentageClampedAtZero 2>&1
```
Expected: PASS (the formula is correct; the bug is that SessionView doesn't use it)

**Step 3: Fix the display in SessionView**

In `SessionView.swift:115`, change:
```swift
// Before
Text("\(Int(100 - pct))%")

// After
Text("\(Int(max(0, 100 - pct)))%")
```

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift
git commit -m "fix: clamp context percentage display to 0% minimum"
```

---

### Task 2: Fix duplicate voice messages

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Add state tracking for last voice input**

In `SessionView.swift`, after line 20 (`permissionResolutions`), add:

```swift
@State private var lastVoiceInputText: String = ""
@State private var lastVoiceInputTime: Date = .distantPast
```

**Step 2: Set tracking in onFinalTranscription**

In the `onFinalTranscription` callback (line 276), add tracking before appending the message. Change:

```swift
// Before
speechRecognizer.onFinalTranscription = { text in
    currentTranscript = text

    let userMessage = SessionHistoryMessage(

// After
speechRecognizer.onFinalTranscription = { text in
    currentTranscript = text
    lastVoiceInputText = text
    lastVoiceInputTime = Date()

    let userMessage = SessionHistoryMessage(
```

**Step 3: Filter server echoes in onUserMessage**

In the `onUserMessage` callback (line 365), add echo filtering after the empty-text guard. Change:

```swift
// Before
guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

let userMsg = SessionHistoryMessage(

// After
guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

// Skip server echo of voice input we already added locally
if message.content == lastVoiceInputText &&
   Date().timeIntervalSince(lastVoiceInputTime) < 10 {
    lastVoiceInputText = ""  // Clear so only first echo is filtered
    return
}

let userMsg = SessionHistoryMessage(
```

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "fix: filter duplicate voice messages from server echo"
```

**Step 5: Manual verification**

> **Automated tests:** None — this bug requires real voice input + server transcript watcher interaction. Unit testing the filter logic in isolation would just test string equality, which is trivial.
>
> **Manual verification (REQUIRED before merge):**
> 1. Connect iOS app to server, open a session
> 2. Tap mic, speak a message, tap stop
> 3. Verify: exactly ONE user message bubble appears (not two)
> 4. Type a message in the terminal
> 5. Verify: the terminal-typed message still appears in the app (not filtered)
>
> **CHECKPOINT:** Must pass manual verification.

---

### Task 3: Fix usage requests blocking other WebSocket messages

**Files:**
- Modify: `voice_server/ios_server.py:1029-1030`
- Test: `voice_server/tests/test_ios_server.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_ios_server.py`:

```python
@pytest.mark.asyncio
async def test_usage_request_does_not_block_message_loop(self):
    """usage_request should not block other messages from being processed."""
    server = VoiceServer()

    # Create a slow usage handler that takes time
    usage_started = asyncio.Event()
    usage_can_finish = asyncio.Event()

    original_handler = server.handle_usage_request

    async def slow_usage_handler(websocket):
        usage_started.set()
        await usage_can_finish.wait()
        # Don't actually call the real handler

    server.handle_usage_request = slow_usage_handler

    mock_ws = AsyncMock()

    # Send usage_request - should return immediately (not block)
    usage_msg = json.dumps({"type": "usage_request"})

    with patch.object(server, 'handle_list_projects', new_callable=AsyncMock) as mock_list:
        # Send usage request first
        await server.handle_message(mock_ws, usage_msg)

        # Usage handler should have started (as background task)
        await asyncio.sleep(0.01)  # Let task start
        assert usage_started.is_set(), "Usage handler should have started"

        # Now send another message - it should NOT be blocked
        list_msg = json.dumps({"type": "list_projects"})
        await server.handle_message(mock_ws, list_msg)

        # list_projects should have been called even though usage is still running
        mock_list.assert_called_once()

    # Clean up background task
    usage_can_finish.set()
    await asyncio.sleep(0.01)
```

**Step 2: Run test to verify it fails**

Run:
```bash
cd voice_server/tests && python -m pytest test_ios_server.py::TestVoiceServer::test_usage_request_does_not_block_message_loop -v 2>&1
```
Expected: FAIL — currently `handle_message` awaits `handle_usage_request`, so `list_projects` can't be called while usage is in-flight.

**Step 3: Change await to asyncio.create_task**

In `ios_server.py:1029-1030`, change:

```python
# Before
            elif msg_type == 'usage_request':
                await self.handle_usage_request(websocket)

# After
            elif msg_type == 'usage_request':
                asyncio.create_task(self.handle_usage_request(websocket))
```

**Step 4: Run test to verify it passes**

Run:
```bash
cd voice_server/tests && python -m pytest test_ios_server.py::TestVoiceServer::test_usage_request_does_not_block_message_loop -v 2>&1
```
Expected: PASS

**Step 5: Run all server tests to check for regressions**

Run:
```bash
cd voice_server/tests && ./run_tests.sh 2>&1
```
Expected: All tests pass.

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_ios_server.py
git commit -m "fix: run usage requests as background task to avoid blocking WebSocket"
```

---

### Task 4: Build iOS app and run full test suite

**Step 1: Run iOS unit tests**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests 2>&1
```
Expected: All tests pass.

**Step 2: Build for device**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild -target ClaudeVoice -sdk iphoneos build 2>&1
```
Expected: BUILD SUCCEEDED

**CHECKPOINT:** All automated tests pass and app builds. Proceed to manual verification from Task 2 Step 5.
