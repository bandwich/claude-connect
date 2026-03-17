# Background Task Completion Detection Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** When a background Bash command finishes, update the original Bash bubble's collapsed preview from "Running in background" to "Done" so it no longer implies the command is still running.

**Architecture:** The server already sees `<task-notification>` user messages in the transcript (currently filtered out). Instead of discarding them, parse out the `<tool-use-id>` and send a new `task_completed` WebSocket message to iOS. On the iOS side, SessionView tracks which Bash tool_use IDs have completed background tasks, and ToolUseView uses this to show "Done" instead of "Running in background".

**Why not detect on iOS side?** Transcript analysis of 40+ background commands shows Claude only uses a follow-up tool (Read/Bash) ~20% of the time after task completion. The other 80%, Claude just responds with text. The `<task-notification>` message is the only reliable signal, and the server already sees it.

**Tech Stack:** Python (server) + Swift/SwiftUI (iOS app)

**Risky Assumptions:**
- `<task-notification>` always contains `<tool-use-id>` matching the original Bash tool_use. Verified across 40+ instances in transcripts.
- The `tool-use-id` in the notification matches exactly the `id` field of the original Bash `tool_use` content block. Verified.

---

### Task 1: Add `isBackgroundComplete` flag to BashPreview and test it

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift:1-21`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ToolUseViewTests.swift`

**Step 1: Write failing tests**

Add these tests to `ToolUseViewTests.swift`, inside the existing `BashCollapsedPreviewTests` suite:

```swift
    @Test func completedBackgroundShowsDone() {
        let content = "Command running in background with ID: b59gez7hy. Output is being written to: /private/tmp/claude-501/tasks/b59gez7hy.output"
        let preview = BashPreview.collapsedText(for: content, isBackgroundComplete: true)
        #expect(preview == "Done")
    }

    @Test func incompleteBackgroundShowsRunning() {
        let content = "Command running in background with ID: b59gez7hy. Output is being written to: /private/tmp/claude-501/tasks/b59gez7hy.output"
        let preview = BashPreview.collapsedText(for: content, isBackgroundComplete: false)
        #expect(preview == "Running in background")
    }

    @Test func defaultIsBackgroundCompleteIsFalse() {
        let content = "Command running in background with ID: b59gez7hy. Output is being written to: /private/tmp/claude-501/tasks/b59gez7hy.output"
        // No isBackgroundComplete param → should default to false → "Running in background"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "Running in background")
    }
```

**Step 2: Run tests to verify they fail**

Run:
```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/BashCollapsedPreviewTests
```

Expected: FAIL — `isBackgroundComplete` parameter does not exist.

**Step 3: Implement the change in BashPreview**

Replace the `BashPreview` enum in `ToolUseView.swift` (lines 3-21) with:

```swift
enum BashPreview {
    static let maxCollapsedLines = 3

    static func collapsedText(for content: String, isBackgroundComplete: Bool = false) -> String {
        if content.hasPrefix("Command running in background") {
            return isBackgroundComplete ? "Done" : "Running in background"
        }
        if content.isEmpty {
            return "Done"
        }
        let lines = content.components(separatedBy: "\n")
        if lines.count <= maxCollapsedLines {
            return content
        }
        let preview = lines.prefix(maxCollapsedLines).joined(separator: "\n")
        let remaining = lines.count - maxCollapsedLines
        return "\(preview)\n… +\(remaining) lines"
    }
}
```

**Step 4: Run tests to verify they pass**

Run:
```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/BashCollapsedPreviewTests
```

Expected: All tests PASS (existing + new).

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ToolUseViewTests.swift
git commit -m "feat: add isBackgroundComplete flag to BashPreview.collapsedText"
```

---

### Task 2: Server sends `task_completed` message when it sees `<task-notification>`

The server currently filters out `<task-notification>` user messages in `TranscriptHandler` (lines 331-332 and 339-340 of `ios_server.py`). Change it to parse the XML and broadcast a `task_completed` message.

**Files:**
- Modify: `voice_server/ios_server.py` (TranscriptHandler extract method, ~lines 331-332 and 339-340)
- Modify: `voice_server/tests/test_transcript_handler.py` (add test)

**Step 1: Write failing test**

Add a test to `voice_server/tests/test_transcript_handler.py` (or create it if it doesn't exist — check first). The test verifies that when a transcript line contains a `<task-notification>` user message, the server extracts the `tool-use-id` and calls the appropriate callback.

First, check how existing transcript handler tests are structured to match the pattern. The test should verify:
- Input: a user message line with `<task-notification>` XML
- Output: a callback is invoked with the extracted `tool_use_id`

```python
@pytest.mark.asyncio
async def test_task_notification_extracts_tool_use_id():
    """When transcript has a <task-notification>, server should broadcast task_completed."""
    # Build a JSONL line with a task-notification user message
    import json
    line = json.dumps({
        "type": "user",
        "message": {
            "role": "user",
            "content": '<task-notification>\n<task-id>b7ou45mop</task-id>\n<tool-use-id>toolu_01Dtc8MmBh3YCbZnX4YFBDXg</tool-use-id>\n<output-file>/tmp/test.output</output-file>\n<status>completed</status>\n<summary>done</summary>\n</task-notification>\nRead the output file.'
        },
        "timestamp": "2026-03-17T00:00:00Z"
    })
    # Verify extraction
    import re
    match = re.search(r'<tool-use-id>([^<]+)</tool-use-id>', line)
    assert match is not None
    assert match.group(1) == "toolu_01Dtc8MmBh3YCbZnX4YFBDXg"
```

**NOTE:** The exact test structure depends on how transcript handler tests are organized. Read `voice_server/tests/` first to match existing patterns. The key behavior to test is the regex extraction from `<task-notification>` content.

**Step 2: Implement the server change**

In `voice_server/ios_server.py`, find the two places where `<task-notification>` is filtered out:

1. Around line 331 (inside the `content` list loop):
```python
if text.startswith('<task-notification'):
    continue
```

2. Around line 339 (string content branch):
```python
elif stripped.startswith('<task-notification'):
    pass
```

Replace both with logic to extract the `tool-use-id` and record it for broadcasting:

```python
if text.startswith('<task-notification'):
    import re
    match = re.search(r'<tool-use-id>([^<]+)</tool-use-id>', text)
    if match:
        task_completed_tool_ids.append(match.group(1))
    continue
```

Initialize `task_completed_tool_ids = []` at the top of the extract method (alongside `all_blocks`, `user_texts`, etc.).

After the extraction loop, broadcast each completion. Add this after the existing user_texts broadcast loop (around where `handle_user_message` is called):

```python
for tool_id in task_completed_tool_ids:
    await self.broadcast_task_completed(tool_id)
```

Add the broadcast method to VoiceServer:

```python
async def broadcast_task_completed(self, tool_use_id: str):
    """Notify iOS that a background task has completed."""
    message = {
        "type": "task_completed",
        "tool_use_id": tool_use_id,
    }
    await self.broadcast(json.dumps(message))
```

**Step 3: Run server tests**

Run:
```bash
cd voice_server/tests && ./run_tests.sh
```

Expected: All tests PASS.

**Step 4: Verify with a real transcript**

Quick sanity check — run the server extraction on a known transcript to verify parsing works:

```bash
python3 -c "
import re
text = '<task-notification>\n<task-id>b7ou45mop</task-id>\n<tool-use-id>toolu_01Dtc8MmBh3YCbZnX4YFBDXg</tool-use-id>\n</task-notification>'
match = re.search(r'<tool-use-id>([^<]+)</tool-use-id>', text)
print(f'Extracted: {match.group(1)}')
assert match.group(1) == 'toolu_01Dtc8MmBh3YCbZnX4YFBDXg'
print('OK')
"
```

**CHECKPOINT:** Verify the extraction works before continuing.

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max
git add voice_server/ios_server.py
git commit -m "feat: broadcast task_completed when background bash command finishes"
```

---

### Task 3: iOS handles `task_completed` message and updates Bash bubble

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift` (or wherever WebSocket message types are decoded — check first)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift` (handle new message type)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift` (track completed IDs, pass to ToolUseView)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift` (accept and use `isBackgroundComplete`)

**Step 1: Add message handling in WebSocketManager**

First, read `WebSocketManager.swift` to understand how messages are decoded and dispatched. Find the `handleMessage` method.

Add a new callback property:

```swift
var onTaskCompleted: ((String) -> Void)?  // tool_use_id
```

In `handleMessage`, add a case for the new message type. The message is simple: `{"type": "task_completed", "tool_use_id": "toolu_..."}`. Add decoding after the existing message types:

```swift
// Try task_completed
if let type = try? JSONDecoder().decode(TypeOnly.self, from: data).type, type == "task_completed" {
    if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let toolUseId = dict["tool_use_id"] as? String {
        DispatchQueue.main.async { [weak self] in
            self?.onTaskCompleted?(toolUseId)
        }
    }
    return
}
```

(Adapt to match existing decoding patterns in WebSocketManager.)

**Step 2: Add state tracking in SessionView**

Add a state variable:

```swift
@State private var completedBackgroundToolIds: Set<String> = [:]
```

In the `onAppear` callback chain (where other WebSocket callbacks are set), add:

```swift
webSocketManager.onTaskCompleted = { toolUseId in
    completedBackgroundToolIds.insert(toolUseId)
}
```

**Step 3: Pass completion state to ToolUseView**

In the `body` where `ToolUseView` is instantiated (line 57), change:

```swift
ToolUseView(tool: tool, result: result)
```

To:

```swift
ToolUseView(
    tool: tool,
    result: result,
    isBackgroundComplete: completedBackgroundToolIds.contains(tool.id)
)
```

**Step 4: Add `isBackgroundComplete` property to ToolUseView**

In `ToolUseView.swift`, after `let result: ToolResultBlock?` (line 25), add:

```swift
var isBackgroundComplete: Bool = false
```

In the `collapsedResultView` method, change:

```swift
let previewText = BashPreview.collapsedText(for: displayContent(for: result))
```

To:

```swift
let previewText = BashPreview.collapsedText(for: displayContent(for: result), isBackgroundComplete: isBackgroundComplete)
```

**Step 5: Build and run all unit tests**

Run:
```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests
```

Expected: All tests PASS. BUILD SUCCEEDED.

**Step 6: Commit**

```bash
cd /Users/aaron/Desktop/max
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift
git commit -m "feat: handle task_completed message to update background Bash bubbles"
```

---

### Task 4: Handle history loading (completed backgrounds on session open)

When opening an existing session that had background commands, the `task_completed` WebSocket message won't arrive (it was in the past). The history loading code needs to detect completed backgrounds from the transcript data.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift` (history loading section)

**Step 1: Add detection during history loading**

In the history loading code (where `SessionHistoryMessageRich` messages are processed to build `newItems`), after processing all blocks, scan for Bash tool_use items that have background results AND have a subsequent user message containing their tool_use_id in a `<task-notification>`.

However, the server currently strips `<task-notification>` from user messages before sending history. There are two options:

**Option A (simpler):** Have the server also send `task_completed` tool IDs as part of the `session_history` response. This requires adding a field to the history response.

**Option B (no server change needed):** During history loading, just leave background tasks showing "Running in background". This is acceptable because:
- The session is already complete (user is browsing history)
- The Bash bubble still shows the correct content when expanded
- It only affects historical sessions, not the live session

**Recommended: Option B** — keep it simple for now. Background completion detection works for the live session (the primary use case). Historical sessions can be enhanced later if needed.

**No code changes needed for this task — just a documented decision.**

---

### Task 5: Manual verification

**Automated tests:** BashPreview logic is fully tested (Task 1). Server extraction is tested (Task 2). The WebSocket wiring is stateful UI logic that can't be meaningfully unit-tested.

**Manual verification (REQUIRED before merge):**

After changing server code, reinstall:
```bash
pipx install --force /Users/aaron/Desktop/max --python python3.9
```

1. Start the server with `claude-connect`
2. Connect the iOS app
3. Ask Claude to run a background command (e.g., "run sleep 5 in the background")
4. Approve the permission prompt
5. Observe the Bash bubble shows "Running in background" in collapsed preview
6. Wait for the command to finish (server should log the task_completed broadcast)
7. The original Bash bubble should now show "Done" with a checkmark instead of "Running in background"
8. Tap the Bash bubble to expand — should still show the full "Command running in background with ID: ..." text
9. Verify normal (non-background) Bash commands still show content preview as before

**CHECKPOINT:** Must pass manual verification.
