# Three Bug Fixes: Context %, Duplicate Messages, Usage Blocking

## Bug 1: Negative Context Percentage

**Problem:** SessionView line 115 displays `100 - pct` but `pct` can exceed 100 when context is over-limit, showing negative remaining percentage.

**Fix:** Clamp to 0 in the display:
```swift
Text("\(Int(max(0, 100 - pct)))%")
```

Single line change in `SessionView.swift:115`.

## Bug 2: Duplicate Voice Messages

**Problem:** When the user stops recording, two identical user messages appear:
1. `onFinalTranscription` in SessionView (line 284) immediately appends a local `.textMessage`
2. The server's transcript watcher detects the same text in the Claude session transcript and broadcasts a `user_message` back, which `onUserMessage` (line 365) appends again

**Fix:** Filter server echoes in `onUserMessage`. Track the last voice input text + timestamp. When a `user_message` arrives from the server with matching text within a short window (e.g., 10 seconds), skip it.

In `SessionView.swift`:
- Add `@State private var lastVoiceInputText: String = ""` and `@State private var lastVoiceInputTime: Date = .distantPast`
- Set them in `onFinalTranscription` before appending
- In `onUserMessage`, skip if `message.content == lastVoiceInputText && Date().timeIntervalSince(lastVoiceInputTime) < 10`

## Bug 3: Usage Requests Block Other Requests

**Problem:** `handle_usage_request` in `ios_server.py` is `await`ed directly in `handle_message`. Since `check_usage()` spawns a tmux session, starts Claude Code, waits for it to load, sends `/usage`, and polls for output (up to ~25 seconds), the entire WebSocket message loop is blocked. No other messages (list_projects, voice_input, etc.) can be processed until it completes.

**Fix:** Fire usage fetch as a background task using `asyncio.create_task()`. The cached response is still sent immediately (already handled). The fresh fetch runs in the background and sends results when ready.

In `ios_server.py`, change:
```python
# Before
elif msg_type == 'usage_request':
    await self.handle_usage_request(websocket)

# After
elif msg_type == 'usage_request':
    asyncio.create_task(self.handle_usage_request(websocket))
```

This is safe because:
- `handle_usage_request` already sends cached first (instant), then fetches fresh
- The fresh fetch uses its own tmux session, no shared state conflicts
- If it fails, error handling is already inside `check_usage()`

## Risk Assessment

**Riskiest assumption:** The duplicate message filter (Bug 2) relies on text matching. If the server echoes slightly different text (trimmed, reformatted), the filter won't catch it.

**Verification:**
- Bug 1: Open a session with >100% context usage, confirm it shows "0%" not negative
- Bug 2: Record and send a voice message, confirm only one message appears in the conversation. Also send a message from the terminal and confirm it still shows up (not filtered)
- Bug 3: Tap usage in settings, then immediately navigate to projects — projects should load without waiting for usage to finish

## Files Changed

1. `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift` — Bugs 1 and 2
2. `voice_server/ios_server.py` — Bug 3
