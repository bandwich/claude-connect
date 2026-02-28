# Sync Reliability Phase 2: Sequence Numbers & iOS Resync

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Add sequence numbers to server→iOS messages and an iOS-initiated resync protocol, so the app can detect gaps and recover automatically without full history reloads.

**Architecture:** Server adds a `seq` field (derived from transcript line number) to every `assistant_response` and `user_message`. iOS tracks `lastReceivedSeq` and sends a `resync` request on reconnect instead of requesting full history. Server handles `resync` by replaying content from the requested sequence forward.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS), WebSocket protocol

**Risky Assumptions:** Transcript line numbers are stable enough to use as sequence numbers. Lines are append-only in normal operation (file truncation only on session reset). We verify in Task 1.

**Prerequisites:** Phase 1 must be complete (thread lock + reconciliation loop working).

---

### Task 1: Add sequence numbers to server messages

**Files:**
- Modify: `voice_server/ios_server.py` (TranscriptHandler — track line-based sequence numbers)
- Modify: `voice_server/ios_server.py` (VoiceServer.handle_content_response, handle_user_message — include seq)
- Test: `voice_server/tests/test_sync_integration.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_sync_integration.py`:

```python
class TestSequenceNumbers:
    """Tests for sequence number tracking on messages"""

    def test_extract_new_content_returns_line_numbers(self, tmp_path):
        """extract_new_content returns the starting line number of new content"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        async def content_callback(response):
            pass

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        # Write 3 lines
        with open(transcript_file, "a") as f:
            for i in range(3):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": [{"type": "text", "text": f"Msg {i}"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        blocks, user_texts, start_line = handler.extract_new_content_with_seq(str(transcript_file))
        assert start_line == 0  # Started from line 0
        assert len(blocks) == 3
        assert handler.processed_line_count == 3

        # Write 2 more
        with open(transcript_file, "a") as f:
            for i in range(2):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": [{"type": "text", "text": f"Msg {3+i}"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        blocks2, _, start_line2 = handler.extract_new_content_with_seq(str(transcript_file))
        assert start_line2 == 3  # Started from line 3
        assert len(blocks2) == 2

        loop.close()
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_sync_integration.py::TestSequenceNumbers -v`
Expected: FAIL — `AttributeError: 'TranscriptHandler' has no attribute 'extract_new_content_with_seq'`

**Step 3: Implement sequence tracking**

Add `extract_new_content_with_seq()` to `TranscriptHandler`:

```python
def extract_new_content_with_seq(self, filepath) -> tuple:
    """Like extract_new_content but also returns the starting line number.

    Returns:
        (content_blocks, user_texts, start_line_number)
    """
    start_line = self.processed_line_count
    blocks, user_texts = self.extract_new_content(filepath)
    return blocks, user_texts, start_line
```

Update `on_modified` to use `extract_new_content_with_seq` and pass seq to callbacks. Modify `handle_content_response` to accept and include `seq`:

```python
async def handle_content_response(self, response: AssistantResponse, seq: int = 0):
    """Send structured content to iOS clients"""
    message = response.model_dump()
    message["session_id"] = self.active_session_id
    message["seq"] = seq
    if self.current_branch:
        message["branch"] = self.current_branch

    for websocket in list(self.clients):
        try:
            await websocket.send(json.dumps(message))
        except Exception as e:
            print(f"Error sending content: {e}")
```

Similarly update `handle_user_message` to accept and include `seq`:

```python
async def handle_user_message(self, text: str, seq: int = 0):
    """Send user text message to iOS clients"""
    # ... existing echo dedup logic ...
    message = {
        "type": "user_message",
        "role": "user",
        "content": text,
        "timestamp": time.time(),
        "session_id": self.active_session_id,
        "seq": seq,
    }
    # ... rest unchanged
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_sync_integration.py::TestSequenceNumbers -v`
Expected: PASS

**Step 5: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All PASS

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_sync_integration.py
git commit -m "feat: add sequence numbers to server messages for gap detection"
```

---

### Task 2: Add resync handler to server

**Files:**
- Modify: `voice_server/ios_server.py` (add handle_resync, add to message dispatch)
- Test: `voice_server/tests/test_sync_integration.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_sync_integration.py`:

```python
class TestResyncHandler:
    """Tests for the server-side resync message handler"""

    @pytest.mark.asyncio
    async def test_resync_replays_from_sequence(self, tmp_path):
        """resync request replays all content from the given sequence number"""
        from voice_server.ios_server import VoiceServer
        from unittest.mock import AsyncMock, patch

        # Create transcript with 10 lines
        transcript_file = tmp_path / "session.jsonl"
        with open(transcript_file, "w") as f:
            for i in range(10):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": [{"type": "text", "text": f"Msg {i}"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        # Patch VoiceServer.__init__ to avoid side effects (tmux, http server, etc.)
        with patch.object(VoiceServer, '__init__', lambda self: None):
            server = VoiceServer()
            server.transcript_path = str(transcript_file)

        # Mock websocket
        ws = AsyncMock()
        sent_messages = []
        async def capture_send(data):
            sent_messages.append(json.loads(data))
        ws.send = capture_send

        # Request resync from line 7 (should get lines 7, 8, 9)
        await server.handle_resync(ws, {"from_seq": 7})

        # Should have received messages with content from lines 7-9
        assert len(sent_messages) >= 1
        resync_msg = sent_messages[0]
        assert resync_msg["type"] == "resync_response"
        assert resync_msg["from_seq"] == 7
        assert len(resync_msg["messages"]) == 3  # lines 7, 8, 9
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_sync_integration.py::TestResyncHandler -v`
Expected: FAIL — `AttributeError: 'VoiceServer' has no attribute 'handle_resync'`

**Step 3: Implement handle_resync**

Add to `VoiceServer`:

```python
async def handle_resync(self, websocket, data):
    """Handle resync request — replay content from a given sequence number.

    The client sends from_seq (a transcript line number). We re-read the
    transcript from that line forward and send the content as a resync_response.
    """
    from_seq = data.get("from_seq", 0)
    print(f"[RESYNC] Client requested resync from seq {from_seq}")

    if not self.transcript_path or not os.path.exists(self.transcript_path):
        await websocket.send(json.dumps({
            "type": "resync_response",
            "from_seq": from_seq,
            "messages": []
        }))
        return

    messages = []
    with open(self.transcript_path, 'r') as f:
        lines = f.readlines()

    for line_num, line in enumerate(lines):
        if line_num < from_seq:
            continue
        try:
            entry = json.loads(line.strip())
            msg = entry.get('message', {})
            role = msg.get('role') or entry.get('role')
            content = msg.get('content', entry.get('content', ''))

            messages.append({
                "seq": line_num,
                "role": role,
                "content": content,
                "timestamp": entry.get('timestamp', 0)
            })
        except json.JSONDecodeError:
            continue

    await websocket.send(json.dumps({
        "type": "resync_response",
        "from_seq": from_seq,
        "messages": messages
    }))
    print(f"[RESYNC] Sent {len(messages)} messages from seq {from_seq}")
```

Add to the message dispatch in `handle_client`:

```python
elif msg_type == 'resync':
    await self.handle_resync(websocket, data)
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_sync_integration.py::TestResyncHandler -v`
Expected: PASS

**Step 5: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All PASS

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_sync_integration.py
git commit -m "feat: add resync handler for client-initiated gap recovery"
```

---

### Task 3: iOS — Add seq tracking to WebSocketManager

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift` (add seq field to message structs)

**Step 1: Add seq field to message models**

In `Message.swift`, add `seq` to the relevant response structs. Find the struct used for `assistant_response` decoding and add:

```swift
var seq: Int?
```

Do the same for `user_message` decoding.

**Step 2: Track lastReceivedSeq in WebSocketManager**

Add to `WebSocketManager`:

```swift
@Published var lastReceivedSeq: Int = 0
```

In the message handler where `assistant_response` and `user_message` are decoded, update:

```swift
if let seq = decodedMessage.seq, seq > lastReceivedSeq {
    lastReceivedSeq = seq
}
```

**Step 3: Send resync on reconnect instead of full history**

Replace the `requestSessionHistory` call in the reconnect handler with:

```swift
func requestResync() {
    let message: [String: Any] = [
        "type": "resync",
        "from_seq": lastReceivedSeq
    ]
    sendJSON(message)
}
```

In the reconnect flow (where `requestSessionHistory` is currently called), call `requestResync()` instead — but only if `lastReceivedSeq > 0` (meaning we had a prior connection). For the first connection, still use `requestSessionHistory`.

**Step 4: Handle resync_response**

Add a new case to the message handler:

```swift
// Decode resync_response
if let resyncResponse = try? decoder.decode(ResyncResponse.self, from: data) {
    // Process each message and update items via the existing onAssistantResponse / onUserMessage callbacks
    // The seq-based dedup in SessionView will prevent duplicates
    onResyncReceived?(resyncResponse.messages)
}
```

**Step 5: Build and verify**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios-voice-app/
git commit -m "feat: add sequence tracking and resync protocol to iOS WebSocketManager"
```

---

### Task 4: iOS — Sequence-based dedup in SessionView

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Update ConversationItem IDs to use sequence numbers**

In `SessionView.swift`, where `ConversationItem` cases produce IDs, change text message IDs from timestamp-based to seq-based:

Find the `ConversationItem` enum (or wherever `.textMessage` produces its `id`). Update:

```swift
// Old: "text-\(msg.timestamp)"
// New: "text-\(msg.seq ?? msg.timestamp)"
```

**Step 2: Update the onAssistantResponse handler to use seq for dedup**

In the `setupView()` callback where live `assistant_response` messages are appended to `items`, check seq:

```swift
webSocketManager.onAssistantResponse = { response in
    // Skip if we already have this seq
    if let seq = response.seq, seq <= self.lastProcessedSeq {
        return
    }
    if let seq = response.seq {
        self.lastProcessedSeq = seq
    }
    // ... existing item-building logic
}
```

**Step 3: Update reconnect flow in SessionView**

In the `.onChange(of: webSocketManager.connectionState)` handler, replace `requestSessionHistory` with `requestResync()` when `lastReceivedSeq > 0`:

```swift
.onChange(of: webSocketManager.connectionState) { _, newState in
    if case .connected = newState, !session.isNewSession {
        if webSocketManager.lastReceivedSeq > 0 {
            webSocketManager.requestResync()
        } else {
            webSocketManager.requestSessionHistory(folderName: project.folderName, sessionId: session.id)
        }
        syncSession()
    }
}
```

**Step 4: Build and verify**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add ios-voice-app/
git commit -m "feat: use sequence-based dedup in SessionView to eliminate duplicates"
```

---

### Task 5: Manual end-to-end verification

**Step 1: Reinstall server and build iOS app**

Run:
```bash
pipx install --force /Users/aaron/Desktop/max
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```

Install on device if testing on real device.

**Step 2: Test sync reliability**

1. Start server, connect iOS app
2. Open a session in the app, interact from the terminal
3. Verify: all messages appear in the app (text, tool use + results, user messages)
4. Verify: AskUserQuestion shows the question content AND the answer
5. Verify: no "Running..." stuck states
6. Disconnect/reconnect the app — verify resync fills in any gaps

**CHECKPOINT:** All 5 checks must pass. If any fail, debug using server logs (`[RECONCILE]`, `[RESYNC]` prefixes) and fix before considering Phase 2 complete.

**Step 3: Run full test suites**

Run server tests and iOS build to verify nothing is broken.

**Step 4: Commit any fixes**

```bash
git commit -m "fix: address issues found during manual sync verification"
```
